#!/usr/bin/env bash
#
# @file pve-share.sh
# @brief Unattended deploy and update of a file server (copyparty) in a
#   Proxmox LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing) with the
#   files on a separate volume (SHARE_STORAGE, SHARE_DISK_GB, mounted at
#   /srv/share). The volume is included in backups: with Proxmox Backup
#   Server only changed blocks are sent each night.
#
#   * copyparty (from PyPI) on port 3923: browser up- and downloads with
#     resume, WebDAV, search, thumbnails, share links;
#   * accounts with generated passwords, in groups:
#     - SHARE_ADMIN: full control of the pool and the inbox;
#     - SHARE_FAMILY: personal logins plus one shared family login, read
#       and write the pool;
#     - SHARE_FRIENDS: read the pool;
#   * volumes:
#     - /pool   shared, SHARE_POOL_GB at most;
#     - /home/<login>  one per login, only its owner gets in,
#       SHARE_HOME_GB at most;
#     - /inbox  every login can drop files in, only the admin sees them.
#
#   Rights in copyparty belong to a volume and every subfolder inside it
#   inherits them. A volume mounted inside another one does not inherit
#   anything: it replaces the rights completely, so it must list everyone.
#
#   Running it again snapshots the container, upgrades Debian and
#   copyparty, adds new logins and rewrites the config. A renamed login
#   gets a new, empty home: move the old folder by hand.
#
#   How to run (the data volume is required for a new container):
#     SHARE_STORAGE=tank bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-share.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="share"
PERSISTED_SETTINGS=(
  SHARE_ADMIN SHARE_FAMILY SHARE_FRIENDS SHARE_POOL_GB SHARE_HOME_GB
)

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
SHARE_FAMILY="${SHARE_FAMILY-fam1 fam2 fam3 family}"
SHARE_FRIENDS="${SHARE_FRIENDS-friend1 friend2}"
SHARE_POOL_GB="${SHARE_POOL_GB:-100}"
SHARE_HOME_GB="${SHARE_HOME_GB:-5}"
SHARE_STORAGE="${SHARE_STORAGE:-}"
CT_DISK_GB="${CT_DISK_GB:-8}"
CT_MEMORY="${CT_MEMORY:-1024}"
CT_CORES="${CT_CORES:-2}"
CT_DESCRIPTION="File server (copyparty)"
ct_defaults

# @description Print all logins: admin, family, friends.
# @stdout Space separated logins.
all_logins() {
  # Word splitting is intended: one login per word.
  # shellcheck disable=SC2086
  printf '%s ' "$SHARE_ADMIN" $SHARE_FAMILY $SHARE_FRIENDS
}

# Room for the pool, every home and 10% for the index and slack.
SHARE_DISK_GB="${SHARE_DISK_GB:-$(((SHARE_POOL_GB + SHARE_HOME_GB * $(wc -w <<< "$(all_logins)")) * 11 / 10))}"

# ---- Hooks ----

service_usage() {
  cat << EOF

Share (environment):
  SHARE_STORAGE   storage for the data volume, new CT only (required)
  SHARE_DISK_GB   size of the data volume, GiB, new CT only
                                     [pool + homes + 10% = $SHARE_DISK_GB]
  remembered:
  SHARE_ADMIN     admin login                         [$SHARE_ADMIN]
  SHARE_FAMILY    family logins, read-write pool      [$SHARE_FAMILY]
  SHARE_FRIENDS   friend logins, read-only pool       [$SHARE_FRIENDS]
  SHARE_POOL_GB   limit of the shared pool, GiB       [$SHARE_POOL_GB]
  SHARE_HOME_GB   limit of each personal folder, GiB  [$SHARE_HOME_GB]
EOF
}

service_preflight() {
  local name
  for name in $(all_logins); do
    [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] \
      || die "bad login '$name': use a-z, 0-9, '_' and '-'"
  done
  [[ "$(all_logins | tr ' ' '\n' | sed '/^$/d' | sort | uniq -d)" == "" ]] \
    || die "a login appears twice in SHARE_ADMIN/FAMILY/FRIENDS"
  [[ "$SHARE_POOL_GB" =~ ^[0-9]+$ && "$SHARE_HOME_GB" =~ ^[0-9]+$ ]] \
    || die "SHARE_POOL_GB and SHARE_HOME_GB must be numbers"
  [[ -z "$EXISTING_ID" ]] || return 0
  [[ -n "$SHARE_STORAGE" ]] || die "a new share needs SHARE_STORAGE (see --help)"
  pvesm status --storage "$SHARE_STORAGE" > /dev/null 2>&1 \
    || die "storage '$SHARE_STORAGE' not found"
}

# @description Mount the data volume; it is backed up with the container.
service_create_args() {
  printf '%s\n' --mp0 "$SHARE_STORAGE:$SHARE_DISK_GB,mp=/srv/share,backup=1"
}

# @description Print "login:password" lines, creating new passwords on the
#   host.
# @stdout One line per login.
all_credentials() {
  local name
  for name in $(all_logins); do
    printf '%s:%s\n' "$name" "$(secret_or_new "users/$name")"
  done
}

service_exports() {
  export_var SHARE_ADMIN "$SHARE_ADMIN"
  export_var SHARE_FAMILY "$SHARE_FAMILY"
  export_var SHARE_FRIENDS "$SHARE_FRIENDS"
  export_var SHARE_POOL_GB "$SHARE_POOL_GB"
  export_var SHARE_HOME_GB "$SHARE_HOME_GB"
  export_var SHARE_CREDENTIALS "$(all_credentials)"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'Web       : http://%s:3923/\n' "$ip"
  printf 'WebDAV    : http://%s:3923/  (same logins)\n' "$ip"
  printf 'Logins    : ls %s/users/   (password: cat users/<login>)\n' "$STATE_DIR"
  printf 'Volumes   : /pool %sG, /home/<login> %sG each, /inbox\n' \
    "$SHARE_POOL_GB" "$SHARE_HOME_GB"
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
VENV=/opt/copyparty
DATA=/srv/share

setup_copyparty() {
  apt_install python3-venv python3-pil
  [[ -x "$VENV/bin/pip" ]] || python3 -m venv --system-site-packages "$VENV"
  log "Installing or upgrading copyparty from PyPI"
  "$VENV/bin/pip" install --quiet --upgrade pip copyparty
  id copyparty > /dev/null 2>&1 \
    || useradd --system --home-dir /var/lib/copyparty --shell /usr/sbin/nologin copyparty
  install -d -m 750 -o copyparty -g copyparty /var/lib/copyparty
  install -d -m 750 -o copyparty -g copyparty \
    "$DATA" "$DATA/pool" "$DATA/home" "$DATA/inbox"
  ok "copyparty $("$VENV/bin/pip" show copyparty | awk '/^Version/ { print $2 }')"
}

# Prints a comma separated list from space separated words.
csv() {
  # shellcheck disable=SC2086 # one word per element
  printf '%s\n' $1 | paste -sd, - | sed 's/,/, /g'
}

write_config() {
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
    [[ -z "$SHARE_FAMILY" ]] || printf '  family: %s\n' "$(csv "$SHARE_FAMILY")"
    [[ -z "$SHARE_FRIENDS" ]] || printf '  friends: %s\n' "$(csv "$SHARE_FRIENDS")"
    printf '\n[/pool]\n  %s/pool\n  accs:\n    A: %s\n' "$DATA" "$SHARE_ADMIN"
    [[ -z "$SHARE_FAMILY" ]] || printf '    rwmd: @family\n'
    [[ -z "$SHARE_FRIENDS" ]] || printf '    r: @friends\n'
    printf '  flags:\n    vmaxb: %sg\n' "$SHARE_POOL_GB"
    cat << EOF

[/home/\${u}]
  $DATA/home/\${u}
  accs:
    rwmd: \${u}
  flags:
    vmaxb: ${SHARE_HOME_GB}g

[/inbox]
  $DATA/inbox
  accs:
    w: @acct
    A: $SHARE_ADMIN
EOF
  } | write_file /etc/copyparty/copyparty.conf 600 copyparty:copyparty
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
ExecStart=$VENV/bin/copyparty -c /etc/copyparty/copyparty.conf
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
  setup_copyparty
  write_config
  write_unit
  sleep 4
  log "copyparty: $(systemctl is-active copyparty), $(printf '%s\n' "$SHARE_CREDENTIALS" | grep -c .) logins"
}
SCRIPT
}

guest_main "$@"
