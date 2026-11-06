#!/usr/bin/env bash
#
# @file pve-share.sh
# @brief Unattended deploy and update of a file server (copyparty) in a
#   Proxmox LXC container, with access by groups of people.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing) with the
#   files on a separate volume (SHARE_STORAGE, SHARE_DISK_GB, mounted at
#   /srv/share). The volume is backed up with the container; Proxmox Backup
#   Server sends only changed blocks each night.
#
#   People and their groups live in /root/pve-share/people.conf on the host,
#   one line per login: "login group group ...". A template with placeholder
#   logins is written on the first run. Passwords are generated on the host
#   (users/<login>, mode 600). Groups:
#
#     family friends lovers mods admins contacts work-<organisation>
#
#   SHARE_ADMIN (the owner) is not listed there and gets everything.
#
#   | Folder                  | Writes          | Reads                       |
#   |-------------------------|-----------------|-----------------------------|
#   | /public                 | owner           | everyone, even anonymous    |
#   | /media                  | owner           | family friends lovers mods  |
#   |                         |                 | admins ("own people")       |
#   | /family                 | family          | family; never mods/admins   |
#   | /friends                | friends         | friends lovers mods admins  |
#   | /lovers                 | owner           | lovers; never mods/admins   |
#   | /work/<org>/common      | owner           | that organisation           |
#   | /work/<org>/<login>     | that login      | that login                  |
#   | /contacts/common        | owner           | contacts                    |
#   | /contacts/<login>       | that login      | that login                  |
#   | /inbox                  | every login     | owner                       |
#
#   "never" is a subtraction: someone in family and in mods stays out of
#   /family. Organisations do not see each other. Personal folders appear
#   on the login's first visit and hold SHARE_PERSONAL_GB at most; the
#   inbox holds SHARE_INBOX_GB.
#
#   Rights in copyparty belong to a volume and every subfolder inside it
#   inherits them; a volume mounted inside another one replaces them.
#   Anyone with root on the host or a console in the container can still
#   read every file: encrypt on the devices (Cryptomator, Syncthing
#   untrusted mode) what must stay private even from them.
#
#   How to run (the data volume is required for a new container):
#     SHARE_STORAGE=tank bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-share.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="share"
PERSISTED_SETTINGS=(SHARE_ADMIN SHARE_PERSONAL_GB SHARE_INBOX_GB)

# ---- Shared library ----

SCRIPTS_REF="${SCRIPTS_REF:-master}"

# @description Source a shared library from lib/ next to this script, or
#   from GitHub at $SCRIPTS_REF when the script itself came from a pipe.
# @arg $1 string Library file name.
pve_source() {
  local dir url code
  dir="$(dirname "${BASH_SOURCE[0]}")"
  if [[ -f "$dir/lib/$1" ]]; then
    # shellcheck source=/dev/null
    source "$dir/lib/$1"
    return 0
  fi
  url="https://raw.githubusercontent.com/Gesugao-san/scripts/$SCRIPTS_REF/linux/lib/$1"
  code="$(curl -fsSL --retry 3 "$url")" \
    || { printf '[x] ERROR: cannot download %s\n' "$url" >&2; exit 1; }
  # shellcheck source=/dev/null
  source <(printf '%s\n' "$code")
}

pve_source pve-ct.sh

# ---- Settings (environment > saved > default) ----

guest_load_settings
SHARE_ADMIN="${SHARE_ADMIN:-gesu}"
SHARE_PERSONAL_GB="${SHARE_PERSONAL_GB:-5}"
SHARE_INBOX_GB="${SHARE_INBOX_GB:-10}"
SHARE_STORAGE="${SHARE_STORAGE:-}"
SHARE_DISK_GB="${SHARE_DISK_GB:-150}"
CT_DISK_GB="${CT_DISK_GB:-8}"
CT_MEMORY="${CT_MEMORY:-1024}"
CT_CORES="${CT_CORES:-2}"
CT_DESCRIPTION="File server (copyparty)"
ct_defaults

PEOPLE_FILE="$STATE_DIR/people.conf"

# Groups a login may belong to; work-<organisation> is checked separately.
KNOWN_GROUPS=" family friends lovers mods admins contacts "

# Logins that would clash with folder names.
RESERVED_LOGINS=" common public media inbox "

# ---- People ----

# @description Write the people file with placeholder logins, once.
ensure_people_file() {
  [[ -f "$PEOPLE_FILE" ]] && return 0
  install -d -m 700 "$STATE_DIR"
  (umask 077 && cat > "$PEOPLE_FILE") << 'EOF'
# People of the file server, one login per line: login group group ...
# Groups: family friends lovers mods admins contacts work-<organisation>
# Rename the placeholders before anyone stores files: a personal folder
# follows the login name. Run pve-share.sh again after every change.
fam1        family
fam2        family
family      family
friend1     friends
friend2     friends
lover1      lovers
mod1        friends mods
admin1      friends admins
worker1     work-kadr26
contact1    contacts
EOF
  ok "People file created with placeholders: $PEOPLE_FILE"
}

# @description Print the people file without comments and blank lines.
# @stdout "login group ..." lines.
people_lines() {
  sed -e 's/#.*//' -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' "$PEOPLE_FILE" \
    | sed '/^$/d'
}

# @description Fail on bad logins, unknown groups or duplicates.
check_people() {
  local login groups group
  while read -r login groups; do
    [[ "$login" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] \
      || die "people.conf: bad login '$login' (a-z, 0-9, '_', '-')"
    [[ "$RESERVED_LOGINS" != *" $login "* ]] \
      || die "people.conf: '$login' is reserved, pick another login"
    [[ "$login" != "$SHARE_ADMIN" ]] \
      || die "people.conf: the owner '$login' must not be listed"
    [[ -n "$groups" ]] || die "people.conf: '$login' has no group"
    for group in $groups; do
      [[ "$KNOWN_GROUPS" == *" $group "* || "$group" =~ ^work-[a-z0-9]+$ ]] \
        || die "people.conf: unknown group '$group' for '$login'"
    done
  done < <(people_lines)
  local dupes
  dupes="$(people_lines | awk '{ print $1 }' | sort | uniq -d)"
  [[ -z "$dupes" ]] || die "people.conf: listed twice: $dupes"
}

# @description Print "login:password" for the owner and every person,
#   creating passwords on the host when they are new.
# @stdout One line per login.
all_credentials() {
  local login _
  printf '%s:%s\n' "$SHARE_ADMIN" "$(secret_or_new "users/$SHARE_ADMIN")"
  while read -r login _; do
    printf '%s:%s\n' "$login" "$(secret_or_new "users/$login")"
  done < <(people_lines)
}

# ---- Hooks ----

service_usage() {
  cat << EOF

Share (environment):
  SHARE_STORAGE      storage for the data volume, new CT only (required)
  SHARE_DISK_GB      size of the data volume, GiB, new CT only [$SHARE_DISK_GB]
  remembered:
  SHARE_ADMIN        owner login, full rights          [$SHARE_ADMIN]
  SHARE_PERSONAL_GB  limit of each personal folder, GiB [$SHARE_PERSONAL_GB]
  SHARE_INBOX_GB     limit of the inbox, GiB            [$SHARE_INBOX_GB]

People and groups: $PEOPLE_FILE
EOF
}

service_preflight() {
  [[ "$SHARE_ADMIN" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "bad SHARE_ADMIN"
  [[ "$SHARE_PERSONAL_GB" =~ ^[0-9]+$ && "$SHARE_INBOX_GB" =~ ^[0-9]+$ ]] \
    || die "SHARE_PERSONAL_GB and SHARE_INBOX_GB must be numbers"
  ensure_people_file
  check_people
  [[ -z "$EXISTING_ID" ]] || return 0
  [[ -n "$SHARE_STORAGE" ]] || die "a new share needs SHARE_STORAGE (see --help)"
  pvesm status --storage "$SHARE_STORAGE" > /dev/null 2>&1 \
    || die "storage '$SHARE_STORAGE' not found"
}

# @description Mount the data volume; it is backed up with the container.
service_create_args() {
  printf '%s\n' --mp0 "$SHARE_STORAGE:$SHARE_DISK_GB,mp=/srv/share,backup=1"
}

service_exports() {
  export_var SHARE_ADMIN "$SHARE_ADMIN"
  export_var SHARE_PERSONAL_GB "$SHARE_PERSONAL_GB"
  export_var SHARE_INBOX_GB "$SHARE_INBOX_GB"
  export_var SHARE_PEOPLE "$(people_lines)"
  export_var SHARE_CREDENTIALS "$(all_credentials)"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'Web       : http://%s:3923/   (WebDAV on the same address)\n' "$ip"
  printf 'People    : %s (%s logins)\n' "$PEOPLE_FILE" "$(people_lines | wc -l)"
  printf 'Passwords : %s/users/<login>\n' "$STATE_DIR"
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
VENV=/opt/copyparty
DATA=/srv/share
CONF=/etc/copyparty/copyparty.conf

# Members of every group, filled by load_people: MEMBERS[group]="a b c".
declare -A MEMBERS=()

load_people() {
  local login groups group
  while read -r login groups; do
    [[ -n "$login" ]] || continue
    for group in $groups; do
      MEMBERS[$group]+="${MEMBERS[$group]:+ }$login"
    done
  done <<< "$SHARE_PEOPLE"
}

# Prints "@a, @b" for the groups that have members; with -, prints
# ", -@a, -@b" to subtract them instead.
groups_list() {
  local sign="" group out=""
  if [[ "$1" == "-" ]]; then
    sign="-"
    shift
  fi
  for group in "$@"; do
    [[ -n "${MEMBERS[$group]:-}" ]] || continue
    out+="${out:+, }${sign}@$group"
  done
  [[ -z "$sign" || -z "$out" ]] || out=", $out"
  printf '%s' "$out"
}

# Prints "PERM: WHO" when WHO is not empty; nothing otherwise, so groups
# without members drop out. A subtraction alone grants nothing.
acc() {
  [[ -n "$2" ]] || return 0
  printf '%s: %s%s' "$1" "$2" "${3:-}"
}

# Prints a volume: volume URL PATH, then "perm: who" lines (empty ones are
# skipped), then "flag:" lines.
volume() {
  local url="$1" path="$2"
  shift 2
  printf '\n[%s]\n  %s\n  accs:\n' "$url" "$path"
  local line
  for line in "$@"; do
    [[ -n "$line" && "$line" != flag:* ]] || continue
    printf '    %s\n' "$line"
  done
  local flags=()
  for line in "$@"; do
    [[ "$line" == flag:* ]] && flags+=("${line#flag:}")
  done
  ((${#flags[@]})) || return 0
  printf '  flags:\n'
  printf '    %s\n' "${flags[@]}"
}

write_config() {
  local owner="$SHARE_ADMIN" org deny_staff
  deny_staff="$(groups_list - mods admins)"
  {
    cat << EOF
# Managed by pve-share.sh, rewritten on every run.
[global]
  e2dsa         # index the files; quotas need it
  p: 3923
  no-robots
  theme: 2

[accounts]
EOF
    printf '%s\n' "$SHARE_CREDENTIALS" | sed 's/^\([^:]*\):/  \1: /'
    printf '\n[groups]\n'
    for group in "${!MEMBERS[@]}"; do
      printf '  %s: %s\n' "$group" "${MEMBERS[$group]// /, }"
    done | sort

    volume /public "$DATA/public" "r: *" "A: $owner"
    volume /media "$DATA/media" \
      "$(acc r "$(groups_list family friends lovers mods admins)")" "A: $owner"
    volume /family "$DATA/family" \
      "$(acc rwmd "$(groups_list family)" "$deny_staff")" "A: $owner"
    volume /friends "$DATA/friends" \
      "$(acc rwmd "$(groups_list friends)")" \
      "$(acc r "$(groups_list lovers mods admins)")" "A: $owner"
    volume /lovers "$DATA/lovers" \
      "$(acc r "$(groups_list lovers)" "$deny_staff")" "A: $owner"

    for org in $(printf '%s\n' "${!MEMBERS[@]}" | grep '^work-' | sort); do
      volume "/work/${org#work-}/common" "$DATA/work/${org#work-}/common" \
        "r: @$org" "A: $owner"
      volume "/work/${org#work-}/\${u%+$org}" "$DATA/work/${org#work-}/\${u}" \
        "rwmd: \${u}" "A: $owner" "flag:vmaxb: ${SHARE_PERSONAL_GB}g"
    done

    if [[ -n "${MEMBERS[contacts]:-}" ]]; then
      volume /contacts/common "$DATA/contacts/common" "r: @contacts" "A: $owner"
      volume "/contacts/\${u%+contacts}" "$DATA/contacts/\${u}" \
        "rwmd: \${u}" "A: $owner" "flag:vmaxb: ${SHARE_PERSONAL_GB}g"
    fi

    volume /inbox "$DATA/inbox" "w: @acct" "A: $owner" \
      "flag:vmaxb: ${SHARE_INBOX_GB}g"
  } | write_file "$CONF" 600 copyparty:copyparty
}

setup_copyparty() {
  apt_install python3-venv python3-pil
  [[ -x "$VENV/bin/pip" ]] || python3 -m venv --system-site-packages "$VENV"
  log "Installing or upgrading copyparty from PyPI"
  "$VENV/bin/pip" install --quiet --upgrade pip copyparty
  id copyparty > /dev/null 2>&1 \
    || useradd --system --home-dir /var/lib/copyparty --shell /usr/sbin/nologin copyparty
  install -d -m 750 -o copyparty -g copyparty /var/lib/copyparty /etc/copyparty
  local dir
  for dir in "" public media family friends lovers inbox work contacts; do
    install -d -m 750 -o copyparty -g copyparty "$DATA/$dir"
  done
  ok "copyparty $("$VENV/bin/pip" show copyparty | awk '/^Version/ { print $2 }')"
}

write_unit() {
  write_file /etc/systemd/system/copyparty.service 644 << EOF
# Managed by pve-share.sh, rewritten on every run.
[Unit]
Description=copyparty file server
After=network-online.target
Wants=network-online.target

[Service]
User=copyparty
WorkingDirectory=/var/lib/copyparty
ExecStart=$VENV/bin/copyparty -c $CONF
Restart=always
RestartSec=5s
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$DATA /var/lib/copyparty

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable copyparty > /dev/null 2>&1
  systemctl restart copyparty
}

main() {
  upgrade_os
  mountpoint -q "$DATA" || warn "$DATA is not a separate volume"
  load_people
  setup_copyparty
  write_config
  write_unit
  sleep 4
  log "copyparty: $(systemctl is-active copyparty), $(printf '%s\n' "$SHARE_CREDENTIALS" | grep -c .) logins"
}
SCRIPT
}

guest_main "$@"
