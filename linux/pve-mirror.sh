#!/usr/bin/env bash
#
# @file pve-mirror.sh
# @brief Unattended deploy and update of local Linux distribution mirrors
#   in a Proxmox LXC container, synced from the official sources.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing) with a
#   separate data volume (MIRROR_STORAGE, MIRROR_DISK_GB, mounted at
#   /srv/mirror and left out of backups):
#
#   * debmirror for the APT archives: Debian and Debian security from
#     deb.debian.org, Ubuntu from archive.ubuntu.com, Proxmox VE from
#     download.proxmox.com (only MIRROR_ARCH, no sources), signatures
#     checked with the official keyrings;
#   * rsync for anything given as "name=rsync://..." in MIRROR_RSYNC. Arch
#     Linux is "archlinux=auto": the best complete rsync mirror is picked
#     from the official Arch mirror list on every sync. Add CachyOS, Termux
#     and others once you know their rsync addresses and sizes;
#   * nginx serving /srv/mirror with directory listings on port 80;
#   * a daily timer (MIRROR_SCHEDULE). It is enabled, but nothing is
#     downloaded during setup: first measure with
#       pct exec <id> -- mirror-sync --measure
#     then start with: pct exec <id> -- systemctl start mirror-sync
#
#   Only official sources are used by default. When one fails (blocked,
#   down), the mirror stays as it was, the official source is retried on
#   the next sync, and an alert goes to Prometheus and Grafana from the
#   monitoring container ($MIRROR_MONITOR_CT). A fallback is used only when
#   you name one in MIRROR_FALLBACK, e.g.
#     MIRROR_FALLBACK="debian=https://ftp.de.debian.org archlinux=rsync://host/archlinux/"
#   Any host or URL containing a word of MIRROR_DENY is never used, not
#   even when picked automatically.
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
  MIRROR_DEBIAN_HOST MIRROR_UBUNTU_HOST MIRROR_PROXMOX_HOST MIRROR_ARCH
  MIRROR_DEBIAN MIRROR_DEBIAN_SECURITY MIRROR_UBUNTU MIRROR_PROXMOX
  MIRROR_RSYNC MIRROR_FALLBACK MIRROR_DENY MIRROR_SCHEDULE MIRROR_MONITOR_CT
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
MIRROR_DEBIAN_HOST="${MIRROR_DEBIAN_HOST:-https://deb.debian.org}"
MIRROR_UBUNTU_HOST="${MIRROR_UBUNTU_HOST:-https://archive.ubuntu.com}"
# Proxmox documents its archive over plain HTTP; signatures are checked.
MIRROR_PROXMOX_HOST="${MIRROR_PROXMOX_HOST:-http://download.proxmox.com}"
MIRROR_ARCH="${MIRROR_ARCH-amd64}"
MIRROR_DEBIAN="${MIRROR_DEBIAN-trixie trixie-updates}"
MIRROR_DEBIAN_SECURITY="${MIRROR_DEBIAN_SECURITY-trixie-security}"
MIRROR_UBUNTU="${MIRROR_UBUNTU-resolute resolute-updates resolute-security}"
MIRROR_PROXMOX="${MIRROR_PROXMOX-trixie}"
MIRROR_RSYNC="${MIRROR_RSYNC-archlinux=auto}"
MIRROR_FALLBACK="${MIRROR_FALLBACK-}"
MIRROR_DENY="${MIRROR_DENY-yandex mail.ru vk.com vk.ru vkontakte rambler}"
MIRROR_SCHEDULE="${MIRROR_SCHEDULE:-*-*-* 03:30}"
MIRROR_MONITOR_CT="${MIRROR_MONITOR_CT:-monitor}"
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

# ---- Checks ----

# @description True when the host or URL contains a word of MIRROR_DENY.
# @arg $1 string Host or URL.
denied() {
  local word
  for word in $MIRROR_DENY; do
    [[ "$1" == *"$word"* ]] && return 0
  done
  return 1
}

# @description Fail on malformed lists and on denied sources.
check_sources() {
  local pair source
  for pair in $MIRROR_RSYNC; do
    [[ "$pair" =~ ^[a-z0-9_-]+=(rsync://[^[:space:]]+/|auto)$ ]] \
      || die "MIRROR_RSYNC entry must be name=rsync://host/path/ or archlinux=auto: $pair"
    [[ "${pair#*=}" != "auto" || "${pair%%=*}" == "archlinux" ]] \
      || die "only archlinux can be picked automatically: $pair"
  done
  for pair in $MIRROR_FALLBACK; do
    [[ "$pair" =~ ^[a-z0-9_-]+=(https?://[A-Za-z0-9.-]+|rsync://[^[:space:]]+/)$ ]] \
      || die "MIRROR_FALLBACK entry must be name=https://host or name=rsync://host/path/: $pair"
  done
  for source in "$MIRROR_DEBIAN_HOST" "$MIRROR_UBUNTU_HOST" "$MIRROR_PROXMOX_HOST" \
    $MIRROR_RSYNC $MIRROR_FALLBACK; do
    denied "$source" && die "$source matches MIRROR_DENY ($MIRROR_DENY)"
  done
  return 0
}

# ---- Alerts in the monitoring container ----

# @description Print the setup for the monitoring container: scrape the
#   node_exporter of the mirror and add the mirror alert rules.
# @arg $1 string Address of the mirror container.
# @stdout Bash code.
monitor_setup() {
  printf "set -e\ncat > /etc/prometheus/scrape.d/mirror.yml << 'YML'\n"
  cat << EOF
# Managed by pve-mirror.sh, rewritten on every run.
scrape_configs:
  - job_name: mirror
    static_configs:
      - targets: ['$1:9100']
EOF
  printf "YML\ncat > /etc/prometheus/rules.d/mirror.yml << 'YML'\n"
  cat << 'EOF'
# Managed by pve-mirror.sh, rewritten on every run.
groups:
  - name: mirror
    rules:
      - alert: MirrorOfficialSourceFailed
        expr: mirror_primary_up == 0
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.mirror }}: the official source failed on the last sync (blocked or down)"
          description: "The mirror keeps its last copy. Name a fallback in MIRROR_FALLBACK and run pve-mirror.sh to use one."

      - alert: MirrorOnFallback
        expr: mirror_fallback_used == 1
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.mirror }} was synced from the fallback, not the official source"

      - alert: MirrorStale
        expr: time() - mirror_last_success_timestamp_seconds > 3 * 86400
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.mirror }} has not been synced for {{ $value | humanizeDuration }}"

      - alert: MirrorSyncNotRunning
        expr: time() - mirror_sync_finished_timestamp_seconds > 2 * 86400
        labels:
          severity: warning
        annotations:
          summary: "mirror-sync has not finished for {{ $value | humanizeDuration }}, check its timer"
EOF
  cat << 'EOF'
YML
if ! promtool check config /etc/prometheus/prometheus.yml > /dev/null; then
  rm -f /etc/prometheus/scrape.d/mirror.yml /etc/prometheus/rules.d/mirror.yml
  echo "[!] promtool rejected the mirror config, removed it" >&2
  exit 1
fi
systemctl reload prometheus || systemctl restart prometheus
EOF
}

# @description Register the mirror in the monitoring container, if there
#   is one and it runs.
register_with_monitor() {
  local monitor ip
  monitor="$(find_ct_by_hostname "$MIRROR_MONITOR_CT")"
  if [[ -z "$monitor" ]]; then
    warn "No '$MIRROR_MONITOR_CT' container: no alerts for the mirror until pve-monitoring.sh runs and this script runs again"
    return 0
  fi
  if ! pct status "$monitor" | grep -q running; then
    warn "CT $monitor ($MIRROR_MONITOR_CT) is stopped, mirror alerts not updated"
    return 0
  fi
  ip="$(guest_address)"
  [[ -n "$ip" ]] || { warn "Mirror address unknown, alerts not set up"; return 0; }
  if monitor_setup "$ip" | ct_exec_in "$monitor" bash -s; then
    ok "Mirror alerts added to Prometheus in CT $monitor"
  else
    warn "Could not add the mirror alerts to CT $monitor"
  fi
}

# ---- Hooks ----

service_usage() {
  cat << EOF

Mirror (environment):
  MIRROR_STORAGE      storage for the data volume, new CT only (required)
  MIRROR_DISK_GB      size of the data volume, GiB, new CT only (required)
  remembered:
  MIRROR_DEBIAN_HOST  Debian archive                [$MIRROR_DEBIAN_HOST]
  MIRROR_UBUNTU_HOST  Ubuntu archive                [$MIRROR_UBUNTU_HOST]
  MIRROR_PROXMOX_HOST Proxmox VE archive            [$MIRROR_PROXMOX_HOST]
  MIRROR_ARCH         architectures, comma separated [$MIRROR_ARCH]
  MIRROR_DEBIAN       Debian dists                  [$MIRROR_DEBIAN]
  MIRROR_DEBIAN_SECURITY  Debian security dists     [$MIRROR_DEBIAN_SECURITY]
  MIRROR_UBUNTU       Ubuntu dists                  [$MIRROR_UBUNTU]
  MIRROR_PROXMOX      Proxmox VE dists              [$MIRROR_PROXMOX]
  MIRROR_RSYNC        "name=rsync://host/path/" words, archlinux=auto
                      [$MIRROR_RSYNC]
  MIRROR_FALLBACK     "name=https://host" or "name=rsync://host/path/"
                      words, used only when the official source fails
                      [$MIRROR_FALLBACK]
  MIRROR_DENY         words of hosts never to use   [$MIRROR_DENY]
  MIRROR_SCHEDULE     systemd OnCalendar of the sync [$MIRROR_SCHEDULE]
  MIRROR_MONITOR_CT   monitoring CT for the alerts  [$MIRROR_MONITOR_CT]
EOF
}

service_preflight() {
  check_sources
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

service_after_setup() {
  register_with_monitor
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'Web       : http://%s/\n' "$ip"
  printf 'Sources   : official only%s\n' "${MIRROR_FALLBACK:+, fallback: $MIRROR_FALLBACK}"
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
    for name in MIRROR_DEBIAN_HOST MIRROR_UBUNTU_HOST MIRROR_PROXMOX_HOST \
      MIRROR_ARCH MIRROR_DEBIAN MIRROR_DEBIAN_SECURITY MIRROR_UBUNTU \
      MIRROR_PROXMOX MIRROR_RSYNC MIRROR_FALLBACK MIRROR_DENY; do
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
# Managed by pve-mirror.sh: sync all mirrors from their official sources,
# or show their sizes with --measure (nothing is downloaded then). When an
# official source fails, the fallback from MIRROR_FALLBACK is tried, if
# there is one. The outcome goes to node_exporter for the alerts.
set -uo pipefail
. /etc/mirror-sync.conf
ROOT=/srv/mirror
STATE=/var/lib/mirror-sync
METRICS=/var/lib/prometheus/node-exporter/mirror.prom
ARCH_STATUS=https://archlinux.org/mirrors/status/json/
MEASURE=0
[[ "${1:-}" == "--measure" ]] && MEASURE=1
FAILED=()
declare -A PRIMARY_UP=() FALLBACK_USED=()

exec 9> /run/lock/mirror-sync.lock
flock -n 9 || { echo "mirror-sync is already running"; exit 0; }
mkdir -p "$STATE"

# True when the host or URL contains a word of MIRROR_DENY.
denied() {
  local word
  for word in $MIRROR_DENY; do
    [[ "$1" == *"$word"* ]] && return 0
  done
  return 1
}

# Prints the fallback of a mirror from MIRROR_FALLBACK, empty when none.
fallback_of() {
  local pair
  for pair in $MIRROR_FALLBACK; do
    [[ "${pair%%=*}" == "$1" ]] || continue
    printf '%s' "${pair#*=}"
    return 0
  done
}

# Prints the best-scored complete rsync mirror of the official Arch list
# that is not denied, empty when the list cannot be read.
arch_official() {
  local url
  curl -fsSL --max-time 120 "$ARCH_STATUS" 2> /dev/null \
    | jq -r '.urls[]
        | select(.protocol == "rsync" and .active and .completion_pct == 1 and .score != null)
        | "\(.score) \(.url)"' \
    | sort -g \
    | while read -r _ url; do
      denied "$url" && continue
      printf '%s' "$url"
      break
    done
}

# Remembers a successful sync of a mirror.
mark_synced() {
  ((MEASURE)) || date +%s > "$STATE/$1"
}

# Syncs a mirror from the official source, then from its fallback:
# sync_with NAME SOURCE RUNNER [RUNNER ARGS...]. The runner gets
# NAME SOURCE ARGS...
sync_with() {
  local name=$1 source=$2 run=$3 fallback
  shift 3
  PRIMARY_UP[$name]=0
  FALLBACK_USED[$name]=0
  if [[ -n "$source" ]] && ! denied "$source" && "$run" "$name" "$source" "$@"; then
    PRIMARY_UP[$name]=1
    mark_synced "$name"
    return 0
  fi
  echo "!! $name: the official source ${source:-(none)} failed"
  fallback="$(fallback_of "$name")"
  if [[ -n "$fallback" ]] && ! denied "$fallback"; then
    echo "!! $name: trying the fallback $fallback"
    if "$run" "$name" "$fallback" "$@"; then
      FALLBACK_USED[$name]=1
      mark_synced "$name"
      return 0
    fi
  fi
  FAILED+=("$name")
}

# debmirror once: NAME SCHEME://HOST ROOT DISTS SECTIONS KEYRING.
apt_run() {
  local name=$1 source=$2 root=$3 dists=$4 sections=$5 keyring=$6
  local method="${source%%://*}" host="${source#*://}"
  local -a extra=()
  ((MEASURE)) && extra+=(--dry-run)
  echo "== $name: $dists from $source"
  [[ -s "$keyring" ]] || { echo "keyring $keyring missing"; return 1; }
  debmirror --nosource --method="$method" --host="$host" --root="$root" \
    --dist="${dists// /,}" --section="$sections" --arch="$MIRROR_ARCH" \
    --keyring="$keyring" --rsync-extra=none --diff=none --i18n \
    --ignore-small-errors --timeout=600 "${extra[@]}" "$ROOT/$name"
}

# APT archive: NAME SOURCE ROOT DISTS SECTIONS KEYRING; empty DISTS is off.
apt_mirror() {
  [[ -n "$4" ]] || return 0
  sync_with "$1" "$2" apt_run "${@:3}"
}

# rsync once: NAME URL.
rsync_run() {
  local name=$1 url=$2 stats
  echo "== $name: $url"
  if ((MEASURE)); then
    stats="$(rsync -rtlH --dry-run --stats --no-motd --timeout=600 "$url" /var/empty/)" \
      || return 1
    grep -E 'Number of files|Total file size' <<< "$stats"
    return 0
  fi
  mkdir -p "$ROOT/$name"
  rsync -rtlH --safe-links --delete-delay --delay-updates --no-motd \
    --timeout=600 --contimeout=60 "$url" "$ROOT/$name/"
}

# Prints the metrics for the node_exporter textfile collector.
metrics() {
  local name file
  echo '# HELP mirror_primary_up 1 when the official source worked on the last sync.'
  echo '# TYPE mirror_primary_up gauge'
  for name in "${!PRIMARY_UP[@]}"; do
    printf 'mirror_primary_up{mirror="%s"} %s\n' "$name" "${PRIMARY_UP[$name]}"
  done
  echo '# HELP mirror_fallback_used 1 when the last sync used the fallback.'
  echo '# TYPE mirror_fallback_used gauge'
  for name in "${!FALLBACK_USED[@]}"; do
    printf 'mirror_fallback_used{mirror="%s"} %s\n' "$name" "${FALLBACK_USED[$name]}"
  done
  echo '# HELP mirror_last_success_timestamp_seconds Time of the last successful sync.'
  echo '# TYPE mirror_last_success_timestamp_seconds gauge'
  for file in "$STATE"/*; do
    [[ -f "$file" ]] || continue
    printf 'mirror_last_success_timestamp_seconds{mirror="%s"} %s\n' \
      "${file##*/}" "$(< "$file")"
  done
  echo '# HELP mirror_sync_finished_timestamp_seconds Time mirror-sync last finished.'
  echo '# TYPE mirror_sync_finished_timestamp_seconds gauge'
  printf 'mirror_sync_finished_timestamp_seconds %s\n' "$(date +%s)"
}

apt_mirror debian "$MIRROR_DEBIAN_HOST" debian "$MIRROR_DEBIAN" \
  main,contrib,non-free,non-free-firmware /usr/share/keyrings/debian-archive-keyring.gpg
apt_mirror debian-security "$MIRROR_DEBIAN_HOST" debian-security "$MIRROR_DEBIAN_SECURITY" \
  main,contrib,non-free,non-free-firmware /usr/share/keyrings/debian-archive-keyring.gpg
apt_mirror ubuntu "$MIRROR_UBUNTU_HOST" ubuntu "$MIRROR_UBUNTU" \
  main,restricted,universe,multiverse /usr/share/keyrings/ubuntu-archive-keyring.gpg
apt_mirror proxmox "$MIRROR_PROXMOX_HOST" debian/pve "$MIRROR_PROXMOX" \
  pve-no-subscription /usr/share/keyrings/proxmox-archive-keyring.gpg

for pair in $MIRROR_RSYNC; do
  name="${pair%%=*}"
  url="${pair#*=}"
  [[ "$url" == "auto" ]] && url="$(arch_official)"
  sync_with "$name" "$url" rsync_run
done

if ((!MEASURE)); then
  metrics > "$METRICS.tmp" && mv -f "$METRICS.tmp" "$METRICS"
fi
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
  apt_install debmirror rsync gpgv nginx curl jq liblwp-protocol-https-perl \
    debian-archive-keyring ubuntu-keyring prometheus-node-exporter
  systemctl enable --now prometheus-node-exporter > /dev/null 2>&1
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
