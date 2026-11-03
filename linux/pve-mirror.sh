#!/usr/bin/env bash
#
# @file pve-mirror.sh
# @brief Unattended deploy and update of local Linux distribution mirrors
#   in a Proxmox LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing) with a
#   separate data volume (MIRROR_STORAGE, MIRROR_DISK_GB, mounted at
#   /srv/mirror and left out of backups):
#
#   * debmirror for the APT archives: Debian, Debian security, Ubuntu and
#     Proxmox VE (only MIRROR_ARCH, no sources), signatures checked with
#     the official keyrings;
#   * rsync for anything given as "name=rsync://..." in MIRROR_RSYNC (Arch
#     Linux by default; add CachyOS, Termux and others once you know their
#     rsync addresses and sizes);
#   * nginx serving /srv/mirror with directory listings on port 80;
#   * a daily timer (MIRROR_SCHEDULE). It is enabled, but nothing is
#     downloaded during setup: first measure with
#       pct exec <id> -- mirror-sync --measure
#     then start with: pct exec <id> -- systemctl start mirror-sync
#
#   An empty list switches that mirror off, e.g. MIRROR_UBUNTU="".
#
#   How to run (the data volume is required for a new container):
#     MIRROR_STORAGE=backup MIRROR_DISK_GB=800 bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-mirror.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="mirror"
PERSISTED_SETTINGS=(
  MIRROR_HOST MIRROR_ARCH MIRROR_DEBIAN MIRROR_DEBIAN_SECURITY MIRROR_UBUNTU
  MIRROR_PROXMOX MIRROR_RSYNC MIRROR_SCHEDULE
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
MIRROR_STORAGE="${MIRROR_STORAGE:-}"
MIRROR_DISK_GB="${MIRROR_DISK_GB:-}"
MIRROR_HOST="${MIRROR_HOST-mirror.yandex.ru}"
MIRROR_ARCH="${MIRROR_ARCH-amd64}"
MIRROR_DEBIAN="${MIRROR_DEBIAN-trixie trixie-updates}"
MIRROR_DEBIAN_SECURITY="${MIRROR_DEBIAN_SECURITY-trixie-security}"
MIRROR_UBUNTU="${MIRROR_UBUNTU-resolute resolute-updates resolute-security}"
MIRROR_PROXMOX="${MIRROR_PROXMOX-trixie}"
MIRROR_RSYNC="${MIRROR_RSYNC-archlinux=rsync://mirror.yandex.ru/archlinux/}"
MIRROR_SCHEDULE="${MIRROR_SCHEDULE:-*-*-* 03:30}"
CT_CORES="${CT_CORES:-2}"
CT_MEMORY="${CT_MEMORY:-1024}"
CT_DISK_GB="${CT_DISK_GB:-8}"
CT_DESCRIPTION="Linux distribution mirrors"
ct_defaults

# Keyrings the host may have for the Proxmox archive, newest layout first.
PROXMOX_KEYRINGS=(
  /usr/share/keyrings/proxmox-archive-keyring.gpg
  /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg
)

# ---- Hooks ----

service_usage() {
  cat << EOF

Mirror (environment):
  MIRROR_STORAGE    storage for the data volume, new CT only (required)
  MIRROR_DISK_GB    size of the data volume, GiB, new CT only (required)
  remembered:
  MIRROR_HOST       APT mirror for Debian and Ubuntu     [$MIRROR_HOST]
  MIRROR_ARCH       architectures, comma separated        [$MIRROR_ARCH]
  MIRROR_DEBIAN     Debian dists                         [$MIRROR_DEBIAN]
  MIRROR_DEBIAN_SECURITY  Debian security dists          [$MIRROR_DEBIAN_SECURITY]
  MIRROR_UBUNTU     Ubuntu dists                         [$MIRROR_UBUNTU]
  MIRROR_PROXMOX    Proxmox VE dists (pve-no-subscription) [$MIRROR_PROXMOX]
  MIRROR_RSYNC      "name=rsync://host/path/" words      [$MIRROR_RSYNC]
  MIRROR_SCHEDULE   systemd OnCalendar of the sync       [$MIRROR_SCHEDULE]
EOF
}

service_preflight() {
  local pair
  for pair in $MIRROR_RSYNC; do
    [[ "$pair" =~ ^[a-z0-9_-]+=rsync://[^[:space:]]+/$ ]] \
      || die "MIRROR_RSYNC entry must be name=rsync://host/path/ : $pair"
  done
  [[ -z "$EXISTING_ID" ]] || return 0
  [[ -n "$MIRROR_STORAGE" && -n "$MIRROR_DISK_GB" ]] \
    || die "a new mirror needs MIRROR_STORAGE and MIRROR_DISK_GB (see --help)"
  [[ "$MIRROR_DISK_GB" =~ ^[0-9]+$ ]] || die "MIRROR_DISK_GB must be a number"
  pvesm status --storage "$MIRROR_STORAGE" > /dev/null 2>&1 \
    || die "storage '$MIRROR_STORAGE' not found"
}

# @description Mount the data volume, kept out of vzdump backups.
service_create_args() {
  printf '%s\n' --mp0 "$MIRROR_STORAGE:$MIRROR_DISK_GB,mp=/srv/mirror,backup=0"
}

# @description Print the Proxmox archive keyring of the host as base64.
# @stdout Base64, empty when the host has none.
proxmox_keyring() {
  local file
  for file in "${PROXMOX_KEYRINGS[@]}"; do
    [[ -s "$file" ]] || continue
    base64 -w0 "$file"
    return 0
  done
}

service_exports() {
  local name
  for name in "${PERSISTED_SETTINGS[@]}"; do
    export_var "$name" "${!name}"
  done
  export_var PROXMOX_KEYRING_B64 "$(proxmox_keyring)"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'Web       : http://%s/\n' "$ip"
  printf 'Measure   : pct exec %s -- mirror-sync --measure\n' "$GUEST_ID"
  printf 'Sync now  : pct exec %s -- systemctl start mirror-sync\n' "$GUEST_ID"
  printf 'Progress  : pct exec %s -- journalctl -fu mirror-sync\n' "$GUEST_ID"
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
write_settings() {
  local name
  {
    printf '# Managed by pve-mirror.sh, rewritten on every run.\n'
    for name in MIRROR_HOST MIRROR_ARCH MIRROR_DEBIAN MIRROR_DEBIAN_SECURITY \
      MIRROR_UBUNTU MIRROR_PROXMOX MIRROR_RSYNC; do
      printf '%s=%q\n' "$name" "${!name}"
    done
  } | write_file /etc/mirror-sync.conf 644
  if [[ -n "$PROXMOX_KEYRING_B64" ]]; then
    base64 -d <<< "$PROXMOX_KEYRING_B64" \
      | write_file /usr/share/keyrings/proxmox-archive-keyring.gpg 644
  fi
}

write_sync_script() {
  write_file /usr/local/sbin/mirror-sync 755 << 'EOF'
#!/bin/bash
# Managed by pve-mirror.sh: sync all mirrors, or show their sizes with
# --measure (nothing is downloaded then).
set -uo pipefail
. /etc/mirror-sync.conf
ROOT=/srv/mirror
MEASURE=0
[[ "${1:-}" == "--measure" ]] && MEASURE=1
FAILED=()

exec 9> /run/lock/mirror-sync.lock
flock -n 9 || { echo "mirror-sync is already running"; exit 0; }

# APT archive: name host root "dists" sections keyring
apt_mirror() {
  local name=$1 host=$2 root=$3 dists=$4 sections=$5 keyring=$6
  [[ -n "$dists" && -n "$host" ]] || return 0
  echo "== $name: $dists"
  local -a extra=()
  ((MEASURE)) && extra+=(--dry-run)
  [[ -s "$keyring" ]] || { echo "keyring $keyring missing, skipping $name"; FAILED+=("$name"); return 0; }
  debmirror --nosource --method=http --host="$host" --root="$root" \
    --dist="${dists// /,}" --section="$sections" --arch="$MIRROR_ARCH" \
    --keyring="$keyring" --rsync-extra=none --diff=none --i18n \
    --ignore-small-errors --timeout=600 "${extra[@]}" "$ROOT/$name" \
    || FAILED+=("$name")
}

# rsync tree: name url
rsync_mirror() {
  local name=$1 url=$2
  echo "== $name: $url"
  if ((MEASURE)); then
    rsync -rtlH --dry-run --stats --no-motd --timeout=600 "$url" /var/empty/ \
      | grep -E 'Number of files|Total file size' || FAILED+=("$name")
    return 0
  fi
  mkdir -p "$ROOT/$name"
  rsync -rtlH --safe-links --delete-delay --delay-updates --no-motd \
    --timeout=600 --contimeout=60 "$url" "$ROOT/$name/" || FAILED+=("$name")
}

apt_mirror debian "$MIRROR_HOST" debian "$MIRROR_DEBIAN" \
  main,contrib,non-free,non-free-firmware /usr/share/keyrings/debian-archive-keyring.gpg
apt_mirror debian-security "$MIRROR_HOST" debian-security "$MIRROR_DEBIAN_SECURITY" \
  main,contrib,non-free,non-free-firmware /usr/share/keyrings/debian-archive-keyring.gpg
apt_mirror ubuntu "$MIRROR_HOST" ubuntu "$MIRROR_UBUNTU" \
  main,restricted,universe,multiverse /usr/share/keyrings/ubuntu-archive-keyring.gpg
apt_mirror proxmox download.proxmox.com debian/pve "$MIRROR_PROXMOX" \
  pve-no-subscription /usr/share/keyrings/proxmox-archive-keyring.gpg

for pair in $MIRROR_RSYNC; do
  rsync_mirror "${pair%%=*}" "${pair#*=}"
done

if ((${#FAILED[@]})); then
  echo "FAILED: ${FAILED[*]}"
  exit 1
fi
((MEASURE)) || date -u '+%F %T UTC' > "$ROOT/LAST_SYNC"
echo "All mirrors are in sync"
EOF
}

write_units() {
  write_file /etc/systemd/system/mirror-sync.service 644 << 'EOF'
# Managed by pve-mirror.sh, rewritten on every run.
[Unit]
Description=Sync the Linux distribution mirrors
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mirror-sync
TimeoutStartSec=infinity
Nice=10
IOSchedulingClass=idle
EOF
  write_file /etc/systemd/system/mirror-sync.timer 644 << EOF
# Managed by pve-mirror.sh, rewritten on every run.
[Unit]
Description=Sync the Linux distribution mirrors daily

[Timer]
OnCalendar=$MIRROR_SCHEDULE
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable mirror-sync.timer > /dev/null 2>&1
  systemctl restart mirror-sync.timer
}

write_web() {
  write_file /etc/nginx/sites-available/mirror.conf 644 << 'EOF'
# Managed by pve-mirror.sh, rewritten on every run.
server {
    listen 80 default_server;
    server_name _;
    root /srv/mirror;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    location ~ /\. { deny all; }
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/mirror.conf /etc/nginx/sites-enabled/mirror.conf
  nginx -t > /dev/null 2>&1 || { nginx -t; exit 1; }
  systemctl enable nginx > /dev/null 2>&1
  systemctl reload-or-restart nginx
}

main() {
  upgrade_os
  apt_install debmirror rsync gpgv nginx debian-archive-keyring ubuntu-keyring
  mountpoint -q /srv/mirror || warn "/srv/mirror is not a separate volume"
  write_settings
  write_sync_script
  write_units
  write_web
  log "Free space: $(df -h --output=avail /srv/mirror | tail -n 1 | tr -d ' ')"
  log "Next sync: $(systemctl show mirror-sync.timer -p NextElapseUSecRealtime --value)"
}
SCRIPT
}

guest_main "$@"
