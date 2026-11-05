#!/usr/bin/env bash
#
# @file pve-monitoring.sh
# @brief Unattended deploy and update of Prometheus monitoring for Proxmox.
# @description
#   Runs on a Proxmox VE host as root and needs no answers.
#
#   On the host:
#   * installs prometheus-node-exporter with the Debian collectors, which
#     export SMART attributes of every disk (smartmon timer) and ZFS state;
#   * creates the read-only user prometheus@pve (role PVEAuditor) with an
#     API token for the Proxmox exporter.
#
#   In an unprivileged LXC container ($CT_HOSTNAME, created when missing):
#   * Prometheus with alert rules (target down, ZFS pool, SMART errors,
#     full filesystems, stopped guests, failed probes);
#   * Alertmanager, sending to Telegram when TG_BOT_TOKEN and TG_CHAT_ID
#     are set;
#   * blackbox exporter, probing the 3x-ui container (Xray and the panel);
#   * scraping of OpenWrt routers listed in OPENWRT_TARGETS (set them up
#     with openwrt/prometheus-node-exporter.sh) plus the "OpenWrt"
#     dashboard;
#   * prometheus-pve-exporter from PyPI;
#   * Grafana with provisioned data source and dashboards, including an
#     own "PVE overview" dashboard set as the home page (skipped with a
#     warning when its repository is unreachable).
#
#   Running it again updates everything: snapshot of the container, Debian
#   packages, the PVE exporter and the generated configs. Settings given
#   once (routers, Telegram, ...) are remembered in $SETTINGS_FILE.
#
#   How to run:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-monitoring.sh)
#
#   With settings (all optional, see --help):
#     CT_IP=192.168.11.51/24 CT_GW=192.168.11.1 bash pve-monitoring.sh
#
#   Your own scrape configs go to /etc/prometheus/scrape.d/*.yml and rules to
#   /etc/prometheus/rules.d/*.yml inside the container; the script never
#   touches them. Secrets are saved under $STATE_DIR (mode 600).

set -euo pipefail

# ---- Settings (environment > saved > default) ----

# The host may be reached through the PVE web shell, which starts without
# $HOME, so the state paths are absolute on purpose.
STATE_DIR="/root/pve-monitoring"
SETTINGS_FILE="$STATE_DIR/settings.env"

# Settings that are remembered between runs, so an update without any
# variables keeps the router targets, Telegram and the rest.
PERSISTED_SETTINGS=(
  RETENTION XUI_HOSTNAME XUI_PROBE_PORTS OPENWRT_TARGETS
  TG_BOT_TOKEN TG_CHAT_ID GRAFANA GRAFANA_APT_URL GRAFANA_DASHBOARDS
)

# @description Load saved settings for variables that are not set in the
#   environment. A variable set to an empty value still wins, so
#   "TG_BOT_TOKEN= bash pve-monitoring.sh" turns Telegram off.
load_settings() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  local name value
  while IFS='=' read -r name value; do
    [[ " ${PERSISTED_SETTINGS[*]} " == *" $name "* ]] || continue
    [[ -z "${!name+x}" ]] || continue
    # Values are written with printf %q by save_settings.
    eval "$name=$value"
  done < "$SETTINGS_FILE"
}

load_settings

CT_HOSTNAME="${CT_HOSTNAME:-monitor}"
CT_ID="${CT_ID:-}"
CT_STORAGE="${CT_STORAGE:-}"
CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-}"
CT_DEBIAN="${CT_DEBIAN:-13}"
CT_DISK_GB="${CT_DISK_GB:-20}"
CT_CORES="${CT_CORES:-2}"
CT_MEMORY="${CT_MEMORY:-2048}"
CT_SWAP="${CT_SWAP:-512}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"
CT_GW="${CT_GW:-}"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-3}"
RETENTION="${RETENTION:-30d}"
XUI_HOSTNAME="${XUI_HOSTNAME:-vpn}"
# The 3x-ui container was renamed from "xui"; follow saved settings along.
[[ "$XUI_HOSTNAME" != "xui" ]] || XUI_HOSTNAME="vpn"
XUI_PROBE_PORTS="${XUI_PROBE_PORTS:-443}"
OPENWRT_TARGETS="${OPENWRT_TARGETS:-}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
GRAFANA="${GRAFANA:-1}"
GRAFANA_APT_URL="${GRAFANA_APT_URL:-https://apt.grafana.com}"
GRAFANA_DASHBOARDS="${GRAFANA_DASHBOARDS:-1860 10347}"

LOG_FILE="/var/log/pve-monitoring.log"
LOCK_FILE="/run/lock/pve-monitoring.lock"
SNAPSHOT_PREFIX="mon_"
NETWORK_TIMEOUT=120
PVE_USER="prometheus@pve"
PVE_TOKEN_NAME="monitoring"

# ---- Output helpers ----

# @description Print an info line.
# @arg $@ string Message.
log() {
  printf '[*] %s\n' "$*"
}

# @description Print a success line.
# @arg $@ string Message.
ok() {
  printf '[+] %s\n' "$*"
}

# @description Print a warning line to stderr.
# @arg $@ string Message.
warn() {
  printf '[!] %s\n' "$*" >&2
}

# @description Print an error and stop the script.
# @arg $@ string Message.
# @exitcode 1 Always.
die() {
  printf '[x] ERROR: %s\n' "$*" >&2
  exit 1
}

# @description Print usage information.
usage() {
  cat << 'EOF'
pve-monitoring.sh - deploy or update Prometheus monitoring on Proxmox VE.

Usage:
  pve-monitoring.sh [--auto | --install | --update | --help]

Modes:
  --auto     install if the container does not exist, update otherwise
             (default)
  --install  only create a new container, fail if it already exists
  --update   only update an existing container, fail if it is missing

Environment (all optional):
  CT_HOSTNAME          hostname, also used to find the CT again [monitor]
  CT_ID                ID for a new container               [next free]
  CT_STORAGE           storage for the root disk                 [auto]
  CT_TEMPLATE_STORAGE  storage for templates                     [auto]
  CT_DEBIAN            Debian major version of the template        [13]
  CT_DISK_GB           root disk size, GiB                         [20]
  CT_CORES             CPU cores                                    [2]
  CT_MEMORY            RAM, MiB                                  [2048]
  CT_SWAP              swap, MiB                                  [512]
  CT_BRIDGE            network bridge                           [vmbr0]
  CT_IP                "dhcp" or CIDR, e.g. 192.168.11.51/24     [dhcp]
  CT_GW                gateway, required with a static CT_IP
  KEEP_SNAPSHOTS       update snapshots to keep                     [3]
  RETENTION            how long Prometheus keeps data             [30d]
  XUI_HOSTNAME         3x-ui container to probe, if it exists     [vpn]
  XUI_PROBE_PORTS      Xray ports to probe, space separated       [443]
  OPENWRT_TARGETS      OpenWrt exporters, "ip:port" words        [none]
                       (see openwrt/prometheus-node-exporter.sh)
  TG_BOT_TOKEN         Telegram bot token for alerts             [none]
  TG_CHAT_ID           Telegram chat ID for alerts               [none]
  GRAFANA              1 = install Grafana, 0 = skip                [1]
  GRAFANA_APT_URL      Grafana APT repository   [https://apt.grafana.com]
  GRAFANA_DASHBOARDS   grafana.com dashboard IDs          [1860 10347]

RETENTION, XUI_*, OPENWRT_TARGETS, TG_* and GRAFANA* are remembered in
/root/pve-monitoring/settings.env, so later runs need no variables; set one
to an empty value to clear it.

Secrets are saved under /root/pve-monitoring/ (mode 600).
Log: /var/log/pve-monitoring.log
EOF
}

# ---- Guards ----

# @description Stop unless running as root.
require_root() {
  [[ "$(id -u)" -eq 0 ]] && return 0
  die "run me as root"
}

# @description Stop unless the Proxmox tools are available.
require_pve() {
  local tool
  for tool in pct pveam pvesh pvesm pveum; do
    command -v "$tool" > /dev/null && continue
    die "'$tool' not found, this script must run on a Proxmox VE host"
  done
}

# @description Stop if another copy of the script is already running.
take_lock() {
  exec 9> "$LOCK_FILE"
  flock -n 9 && return 0
  die "another pve-monitoring.sh is already running"
}

# @description Validate the network settings of a new container.
# @exitcode 1 Static IP without gateway, or the address is already in use.
check_network_settings() {
  [[ "$CT_IP" == "dhcp" ]] && return 0
  [[ -n "$CT_GW" ]] || die "CT_GW is required with a static CT_IP"

  local address="${CT_IP%/*}"
  ping -c 1 -W 1 "$address" > /dev/null 2>&1 || return 0
  die "$address already answers ping, pick another CT_IP"
}

# ---- Proxmox helpers ----

# @description Print the ID of the container with the given hostname.
# @arg $1 string Hostname.
# @stdout Container ID, empty when none.
find_ct_by_hostname() {
  pct list | awk -v name="$1" 'NR > 1 && $NF == name { print $1; exit }'
}

# @description Print the active storage with the most free space that
#   accepts the given content type.
# @arg $1 string Content type (rootdir, vztmpl, ...).
# @stdout Storage name.
pick_storage() {
  pvesm status --content "$1" --enabled 1 2> /dev/null \
    | awk 'NR > 1 && $3 == "active" { print $6, $1 }' \
    | sort -rn \
    | awk 'NR == 1 { print $2 }'
}

# @description Print the newest standard Debian template available for the
#   host architecture. PVE 9 also lists arm64 templates, and "arm64" sorts
#   after "amd64", so the architecture filter is required.
# @stdout Template file name.
latest_template() {
  local arch
  arch="$(dpkg --print-architecture)"
  pveam update > /dev/null 2>&1 \
    || warn "pveam update failed, using the cached list"
  pveam available --section system \
    | awk '{ print $2 }' \
    | { grep -E "^debian-${CT_DEBIAN}-standard_.*_${arch}\.tar\." || true; } \
    | sort -V \
    | tail -n 1
}

# @description Download the template unless it is already present.
# @arg $1 string Template storage.
# @arg $2 string Template file name.
ensure_template() {
  if pveam list "$1" | grep -qF "$1:vztmpl/$2"; then
    ok "Template already present: $2"
    return 0
  fi
  log "Downloading template $2 to $1"
  pveam download "$1" "$2"
}

# @description Run a command inside a container.
# @arg $1 int Container ID.
# @arg $@ string Command and arguments.
ct_exec_in() {
  local id="$1"
  shift
  pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

# @description Run a command inside the monitoring container.
# @arg $@ string Command and arguments.
ct_exec() {
  ct_exec_in "$CT_ID" "$@"
}

# @description Start the container unless it is already running.
# @exitcode 1 The container does not run after the start attempt.
ensure_running() {
  pct status "$CT_ID" | grep -q 'running' && return 0
  log "Starting container $CT_ID"
  pct start "$CT_ID" || true
  pct status "$CT_ID" | grep -q 'running' && return 0
  die "CT $CT_ID does not start, see: pct start $CT_ID --debug"
}

# @description Wait until the container resolves names and reaches GitHub.
# @exitcode 1 Network is not up within $NETWORK_TIMEOUT seconds.
wait_for_network() {
  local waited=0
  log "Waiting for network inside the container"
  until ct_exec getent hosts github.com > /dev/null 2>&1; do
    ((waited += 3))
    ((waited < NETWORK_TIMEOUT)) || die "no network in CT $CT_ID"
    sleep 3
  done
  ok "Network is up"
}

# @description Print the IPv4 address of eth0 inside a container.
# @arg $1 int Container ID.
# @stdout Address without the prefix length, empty when unknown.
ct_address_of() {
  { ct_exec_in "$1" ip -4 -o addr show dev eth0 2> /dev/null || true; } \
    | awk '{ split($4, a, "/"); print a[1]; exit }'
}

# @description Print the MAC address of net0.
# @stdout MAC address.
ct_mac() {
  pct config "$CT_ID" | grep -oE 'hwaddr=[0-9A-Fa-f:]+' | cut -d= -f2 || true
}

# @description Succeed when net0 of the container gets its address by DHCP.
ct_uses_dhcp() {
  pct config "$CT_ID" | grep -q '^net0:.*ip=dhcp'
}

# ---- Container lifecycle ----

# @description Create and start a new unprivileged container.
create_ct() {
  local storage="${CT_STORAGE:-$(pick_storage rootdir)}"
  local tpl_storage="${CT_TEMPLATE_STORAGE:-$(pick_storage vztmpl)}"
  [[ -n "$storage" ]] || die "no storage accepts container disks (rootdir)"
  [[ -n "$tpl_storage" ]] || die "no storage accepts templates (vztmpl)"

  local template
  template="$(latest_template)"
  [[ -n "$template" ]] || die "no debian-${CT_DEBIAN}-standard template found"
  ensure_template "$tpl_storage" "$template"

  CT_ID="${CT_ID:-$(pvesh get /cluster/nextid)}"
  local net="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
  [[ -n "$CT_GW" ]] && net+=",gw=${CT_GW}"

  log "Creating CT $CT_ID ($CT_HOSTNAME) on $storage"
  pct create "$CT_ID" "$tpl_storage:vztmpl/$template" \
    --hostname "$CT_HOSTNAME" \
    --description "Prometheus monitoring, managed by pve-monitoring.sh" \
    --tags monitoring \
    --unprivileged 1 \
    --features nesting=1 \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --rootfs "$storage:$CT_DISK_GB" \
    --net0 "$net" \
    --timezone host \
    --onboot 1 \
    --start 1
  ok "Container $CT_ID created"
}

# @description Give the container a random root password, saved on the
#   host. The password goes through stdin, never through arguments.
set_root_password() {
  local password
  password="$(openssl rand -hex 12)"
  printf 'root:%s\n' "$password" | pct exec "$CT_ID" -- chpasswd
  save_secret "ct-$CT_ID-root-password" "$password"
  ok "Root password set and saved"
}

# @description Snapshot the container and keep only the newest ones.
#   Storages without snapshot support only produce a warning.
snapshot_ct() {
  local name
  name="${SNAPSHOT_PREFIX}$(date +%Y%m%d_%H%M%S)"
  if ! pct snapshot "$CT_ID" "$name" --description "before update" \
    > /dev/null 2>&1; then
    warn "Snapshot failed (storage without snapshots?), continuing"
    return 0
  fi
  ok "Snapshot $name created"
  prune_snapshots
}

# @description Delete update snapshots beyond $KEEP_SNAPSHOTS.
prune_snapshots() {
  local old
  pct listsnapshot "$CT_ID" \
    | { grep -oE "\b${SNAPSHOT_PREFIX}[0-9]{8}_[0-9]{6}\b" || true; } \
    | sort -u \
    | head -n "-$KEEP_SNAPSHOTS" \
    | while read -r old; do
      if pct delsnapshot "$CT_ID" "$old"; then
        log "Old snapshot $old removed"
      else
        warn "Could not remove old snapshot $old"
      fi
    done
}

# ---- State on the host ----

# @description Save a secret under $STATE_DIR.
# @arg $1 string File name.
# @arg $2 string Content.
save_secret() {
  install -d -m 700 "$STATE_DIR"
  (umask 077 && printf '%s\n' "$2" > "$STATE_DIR/$1")
}

# @description Remember the persisted settings for the next run. The file
#   also holds TG_BOT_TOKEN, so it is created with mode 600.
save_settings() {
  local name
  install -d -m 700 "$STATE_DIR"
  # The redirection is inside the subshell, so the umask applies to it;
  # chmod also fixes a file that already existed with wider permissions.
  (
    umask 077
    {
      printf '# Managed by pve-monitoring.sh; edit or delete to reset.\n'
      for name in "${PERSISTED_SETTINGS[@]}"; do
        printf '%s=%q\n' "$name" "${!name}"
      done
    } > "$SETTINGS_FILE"
  )
  chmod 600 "$SETTINGS_FILE"
}

# @description Print a saved secret, empty when missing.
# @arg $1 string File name.
# @stdout Content without the trailing newline.
read_secret() {
  [[ -s "$STATE_DIR/$1" ]] || return 0
  head -n 1 "$STATE_DIR/$1"
}

# @description Print a secret, generating and saving a random one first
#   when it does not exist yet.
# @arg $1 string File name.
# @stdout Secret.
secret_or_new() {
  local value
  value="$(read_secret "$1")"
  if [[ -z "$value" ]]; then
    value="$(openssl rand -hex 12)"
    save_secret "$1" "$value"
  fi
  printf '%s' "$value"
}

# ---- Host side ----

# @description Install the node exporter and the Debian collectors on the
#   host. The smartmon collector exports SMART attributes of all disks.
setup_host_exporters() {
  log "Installing exporters on the PVE host"
  apt-get update -q > /dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    prometheus-node-exporter prometheus-node-exporter-collectors \
    smartmontools > /dev/null
  systemctl enable --now prometheus-node-exporter > /dev/null 2>&1
  local timer
  for timer in prometheus-node-exporter-smartmon.timer \
    prometheus-node-exporter-nvme.timer; do
    systemctl enable --now "$timer" > /dev/null 2>&1 \
      || warn "Could not enable $timer"
  done
  ok "node_exporter is running on the host (port 9100)"
}

# @description Make sure the read-only PVE user and its API token exist.
#   The token value is only shown once, so it is kept in $STATE_DIR and
#   the token is recreated when that copy is lost.
ensure_pve_token() {
  pveum user add "$PVE_USER" \
    --comment "Prometheus exporter, managed by pve-monitoring.sh" \
    > /dev/null 2>&1 || true
  pveum acl modify / --users "$PVE_USER" --roles PVEAuditor
  [[ -n "$(read_secret pve-token)" ]] && return 0

  log "Creating API token $PVE_USER!$PVE_TOKEN_NAME"
  pveum user token remove "$PVE_USER" "$PVE_TOKEN_NAME" > /dev/null 2>&1 \
    || true
  local value
  value="$(pveum user token add "$PVE_USER" "$PVE_TOKEN_NAME" \
    --privsep 0 --comment "pve-monitoring.sh" --output-format json \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["value"])')"
  [[ -n "$value" ]] || die "could not create the PVE API token"
  save_secret pve-token "$value"
  ok "PVE API token created and saved"
}

# @description Print the IPv4 address of the host on $CT_BRIDGE.
# @stdout Address without the prefix length.
host_address() {
  ip -4 -o addr show dev "$CT_BRIDGE" \
    | awk '{ split($4, a, "/"); print a[1]; exit }'
}

# @description Print the 3x-ui probe targets as "ip:port" words, empty when
#   the 3x-ui container is missing or stopped.
# @stdout Space separated targets.
xui_targets() {
  local id ip panel_port port
  id="$(find_ct_by_hostname "$XUI_HOSTNAME")"
  [[ -n "$id" ]] || return 0
  pct status "$id" | grep -q 'running' || return 0
  ip="$(ct_address_of "$id")"
  [[ -n "$ip" ]] || return 0
  panel_port="$(ct_exec_in "$id" /usr/local/x-ui/x-ui setting -show true \
    2> /dev/null | grep -Eo 'port: [0-9]+' | head -n 1 | awk '{ print $2 }' \
    || true)"
  for port in $XUI_PROBE_PORTS $panel_port; do
    printf '%s:%s ' "$ip" "$port"
  done
}

# ---- Inside the container ----

# @description Print the setup script that runs inside the container.
#   Settings and secrets are prepended as "export" lines by
#   run_container_setup, so they travel through stdin and never show up in
#   process arguments.
# @stdout Bash script.
container_script() {
  cat << 'SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }

# Installs packages, keeping local config files on upgrades.
apt_install() {
  apt-get install -y -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@" > /dev/null
}

# Writes stdin to a file atomically: write_file PATH MODE OWNER:GROUP.
write_file() {
  install -d "$(dirname "$1")"
  cat > "$1.tmp"
  chmod "$2" "$1.tmp"
  chown "$3" "$1.tmp"
  mv -f "$1.tmp" "$1"
}

# Prints a YAML list of quoted targets from space separated words.
yaml_targets() {
  local t
  for t in $1; do
    printf "'%s', " "$t"
  done | sed 's/, $//'
}

upgrade_os() {
  log "Upgrading Debian packages"
  apt-get update -q > /dev/null
  apt-get full-upgrade -y -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold > /dev/null
  apt_install curl ca-certificates jq python3-venv \
    prometheus prometheus-alertmanager prometheus-blackbox-exporter
  apt-get autoremove -y -q > /dev/null
  ok "Debian packages and Prometheus are up to date"
}

setup_pve_exporter() {
  log "Installing prometheus-pve-exporter from PyPI"
  [[ -x /opt/pve-exporter/bin/pip ]] || python3 -m venv /opt/pve-exporter
  /opt/pve-exporter/bin/pip install -q --upgrade pip prometheus-pve-exporter

  # The PVE API uses its self-signed certificate inside the LAN.
  write_file /etc/prometheus/pve.yml 640 root:prometheus << EOF
default:
  user: ${PVE_USER}
  token_name: ${PVE_TOKEN_NAME}
  token_value: ${PVE_TOKEN_VALUE}
  verify_ssl: false
EOF

  write_file /etc/systemd/system/prometheus-pve-exporter.service \
    644 root:root << 'EOF'
[Unit]
Description=Prometheus exporter for Proxmox VE
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
ExecStart=/opt/pve-exporter/bin/pve_exporter --config.file=/etc/prometheus/pve.yml --web.listen-address=127.0.0.1:9221
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable prometheus-pve-exporter > /dev/null 2>&1
  systemctl restart prometheus-pve-exporter
  ok "pve-exporter $(/opt/pve-exporter/bin/pip show prometheus-pve-exporter \
    | awk '/^Version:/ { print $2 }') is running"
}

write_prometheus_config() {
  log "Writing Prometheus configuration"
  install -d -o prometheus -g prometheus \
    /etc/prometheus/scrape.d /etc/prometheus/rules.d

  write_file /etc/default/prometheus 644 root:root << EOF
# Managed by pve-monitoring.sh, rewritten on every run.
ARGS="--storage.tsdb.retention.time=${RETENTION}"
EOF

  local xray_job=""
  if [[ -n "$XUI_TARGETS" ]]; then
    xray_job="
  - job_name: 3x-ui
    metrics_path: /probe
    params:
      module: [tcp_connect]
    static_configs:
      - targets: [$(yaml_targets "$XUI_TARGETS")]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115"
  fi

  local openwrt_job=""
  if [[ -n "$OPENWRT_TARGETS" ]]; then
    openwrt_job="
  - job_name: openwrt
    static_configs:
      - targets: [$(yaml_targets "$OPENWRT_TARGETS")]"
  fi

  write_file /etc/prometheus/prometheus.yml 644 root:root << EOF
# Managed by pve-monitoring.sh, rewritten on every run.
# Own scrape configs: /etc/prometheus/scrape.d/*.yml
# Own alert rules:    /etc/prometheus/rules.d/*.yml
global:
  scrape_interval: 30s
  evaluation_interval: 30s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['localhost:9093']

rule_files:
  - /etc/prometheus/rules/pve-monitoring.yml
  - /etc/prometheus/rules.d/*.yml

scrape_config_files:
  - /etc/prometheus/scrape.d/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: alertmanager
    static_configs:
      - targets: ['localhost:9093']

  - job_name: pve-host
    static_configs:
      - targets: ['${HOST_IP}:9100']

  - job_name: pve
    metrics_path: /pve
    params:
      module: [default]
      cluster: ['1']
      node: ['1']
    static_configs:
      - targets: ['${HOST_IP}']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9221
${xray_job}
${openwrt_job}
EOF

  write_file /etc/prometheus/rules/pve-monitoring.yml 644 root:root << 'EOF'
# Managed by pve-monitoring.sh, rewritten on every run.
groups:
  - name: pve-monitoring
    rules:
      - alert: TargetDown
        expr: up == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.job }} on {{ $labels.instance }} is down"

      - alert: ProbeFailed
        expr: probe_success == 0
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} ({{ $labels.job }}) does not answer"

      - alert: ZfsPoolNotOnline
        expr: node_zfs_zpool_state{state!="online"} > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "ZFS pool {{ $labels.zpool }} is {{ $labels.state }}"

      - alert: SmartUnhealthy
        expr: smartmon_device_smart_healthy == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "SMART reports {{ $labels.disk }} as failing"

      # The Debian smartmon collector exports one metric per attribute,
      # e.g. smartmon_reported_uncorrect_raw_value{disk, smart_id, type}.
      - alert: SmartErrorsGrowing
        expr: >-
          increase({__name__=~"smartmon_(reallocated_sector_ct|current_pending_sector|offline_uncorrectable|reported_uncorrect)_raw_value"}[1h]) > 0
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.disk }}: SMART {{ $labels.smart_id }} grew by {{ $value }} in 1h"

      - alert: FilesystemAlmostFull
        expr: >-
          node_filesystem_avail_bytes{fstype=~"ext4|xfs|zfs"}
          / node_filesystem_size_bytes{fstype=~"ext4|xfs|zfs"} < 0.10
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.mountpoint }} has less than 10% free"

      - alert: GuestDown
        expr: pve_up{id=~"(lxc|qemu)/.+"} == 0 and on(id) pve_onboot_status == 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.id }} should run on boot but is stopped"
EOF
  promtool check config /etc/prometheus/prometheus.yml > /dev/null
  ok "Prometheus configuration is valid"
}

write_alertmanager_config() {
  log "Writing Alertmanager configuration"
  # "null" would be parsed as a YAML null, so the silent receiver is "none".
  local receiver="none" telegram=""
  if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
    receiver="telegram"
    telegram="
  - name: telegram
    telegram_configs:
      - bot_token: '${TG_BOT_TOKEN}'
        chat_id: ${TG_CHAT_ID}
        send_resolved: true"
  fi

  write_file /etc/prometheus/alertmanager.yml 640 root:prometheus << EOF
# Managed by pve-monitoring.sh, rewritten on every run.
route:
  receiver: ${receiver}
  group_by: [alertname, instance]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h

receivers:
  - name: none${telegram}
EOF
  amtool check-config /etc/prometheus/alertmanager.yml > /dev/null
  if [[ "$receiver" == "telegram" ]]; then
    ok "Alerts go to Telegram"
    return 0
  fi
  warn "TG_BOT_TOKEN/TG_CHAT_ID not set: alerts only show in Alertmanager"
}

restart_prometheus_stack() {
  local unit
  for unit in prometheus prometheus-alertmanager \
    prometheus-blackbox-exporter; do
    systemctl enable "$unit" > /dev/null 2>&1
    systemctl restart "$unit"
  done
  ok "Prometheus, Alertmanager and blackbox exporter restarted"
}

setup_grafana() {
  [[ "$GRAFANA" == "1" ]] || return 0
  log "Installing Grafana from $GRAFANA_APT_URL"
  install -d -m 755 /etc/apt/keyrings
  if ! curl -fsSL --max-time 30 -o /etc/apt/keyrings/grafana.asc.new \
    "$GRAFANA_APT_URL/gpg.key"; then
    rm -f /etc/apt/keyrings/grafana.asc.new
    warn "Grafana repository unreachable (blocked?), skipping Grafana."
    warn "Set GRAFANA_APT_URL to a mirror or GRAFANA=0."
    return 0
  fi
  mv -f /etc/apt/keyrings/grafana.asc.new /etc/apt/keyrings/grafana.asc
  write_file /etc/apt/sources.list.d/grafana.sources 644 root:root << EOF
Types: deb
URIs: ${GRAFANA_APT_URL}
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/grafana.asc
EOF

  local first=0
  dpkg -s grafana > /dev/null 2>&1 || first=1
  if ! { apt-get update -q > /dev/null && apt_install grafana; }; then
    warn "Grafana could not be installed, skipping it"
    return 0
  fi

  write_file /etc/grafana/provisioning/datasources/pve-monitoring.yml \
    640 root:grafana << 'EOF'
# Managed by pve-monitoring.sh, rewritten on every run.
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
EOF
  write_file /etc/grafana/provisioning/dashboards/pve-monitoring.yml \
    640 root:grafana << 'EOF'
# Managed by pve-monitoring.sh, rewritten on every run.
apiVersion: 1
providers:
  - name: pve-monitoring
    folder: PVE
    type: file
    options:
      path: /var/lib/grafana/dashboards/pve-monitoring
EOF
  fetch_dashboards
  write_overview_dashboard
  set_home_dashboard

  # The admin password from the environment only applies when Grafana
  # creates its database, so it is set before the first start only and
  # removed from the file afterwards.
  if [[ "$first" == "1" ]]; then
    printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD" \
      >> /etc/default/grafana-server
  fi
  systemctl enable grafana-server > /dev/null 2>&1
  systemctl restart grafana-server
  for _ in $(seq 30); do
    curl -fs http://localhost:3000/api/health > /dev/null && break
    sleep 2
  done
  sed -i '/^GF_SECURITY_ADMIN_PASSWORD=/d' /etc/default/grafana-server
  if [[ "$first" == "1" ]]; then
    ok "Grafana installed, admin password set"
    return 0
  fi
  ok "Grafana updated, admin password unchanged"
}

write_overview_dashboard() {
  # Generated from a Python description of the panels; one panel per line.
  # The PromQL was checked against a live PVE 9 host (metric names of the
  # Debian smartmon/nvme collectors and of prometheus-pve-exporter 3.x).
  write_file /var/lib/grafana/dashboards/pve-monitoring/overview.json \
    644 grafana:grafana << 'EOF'
{"uid":"pve-overview","title":"PVE — обзор","tags":["pve","pve-monitoring"],"description":"Managed by pve-monitoring.sh, rewritten on every run. Copy it before editing.","timezone":"browser","refresh":"30s","time":{"from":"now-6h","to":"now"},"schemaVersion":39,"editable":true,"panels":[
{"id":1,"type":"stat","title":"CPU хоста","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":0,"w":4,"h":4},"fieldConfig":{"defaults":{"unit":"percent","decimals":0,"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":70},{"color":"red","value":90}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"100 - avg(rate(node_cpu_seconds_total{job=\"pve-host\",mode=\"idle\"}[$__rate_interval])) * 100","legendFormat":""}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":2,"type":"stat","title":"ОЗУ хоста","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":4,"y":0,"w":4,"h":4},"fieldConfig":{"defaults":{"unit":"percent","decimals":0,"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":80},{"color":"red","value":95}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"(1 - node_memory_MemAvailable_bytes{job=\"pve-host\"} / node_memory_MemTotal_bytes{job=\"pve-host\"}) * 100","legendFormat":""}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":3,"type":"stat","title":"Аптайм хоста","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":8,"y":0,"w":4,"h":4},"fieldConfig":{"defaults":{"unit":"s","decimals":0,"thresholds":{"mode":"absolute","steps":[{"color":"blue","value":null}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"time() - node_boot_time_seconds{job=\"pve-host\"}","legendFormat":""}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":4,"type":"stat","title":"ZFS-пулы","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":12,"y":0,"w":4,"h":4},"fieldConfig":{"defaults":{"thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"green","value":1}]},"color":{"mode":"thresholds"},"mappings":[{"type":"value","options":{"1":{"text":"ONLINE","color":"green","index":0},"0":{"text":"НЕ ONLINE","color":"red","index":1}}}]},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"node_zfs_zpool_state{state=\"online\"}","legendFormat":"{{zpool}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value_and_name"}},
{"id":5,"type":"stat","title":"3x-ui (порты)","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":16,"y":0,"w":4,"h":4},"fieldConfig":{"defaults":{"thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"green","value":1}]},"color":{"mode":"thresholds"},"mappings":[{"type":"value","options":{"1":{"text":"UP","color":"green","index":0},"0":{"text":"DOWN","color":"red","index":1}}}]},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"probe_success{job=\"3x-ui\"}","legendFormat":"{{instance}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value_and_name"}},
{"id":6,"type":"stat","title":"Активные оповещения","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":20,"y":0,"w":4,"h":4},"fieldConfig":{"defaults":{"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"red","value":1}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"count(ALERTS{alertstate=\"firing\"}) or vector(0)","legendFormat":""}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":7,"type":"timeseries","title":"CPU хоста","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":4,"w":8,"h":8},"fieldConfig":{"defaults":{"unit":"percent","min":0,"max":100},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"100 - avg(rate(node_cpu_seconds_total{job=\"pve-host\",mode=\"idle\"}[$__rate_interval])) * 100","legendFormat":"CPU"}],"options":{"legend":{"displayMode":"list","placement":"bottom"},"tooltip":{"mode":"multi"}}},
{"id":8,"type":"timeseries","title":"ОЗУ хоста","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":8,"y":4,"w":8,"h":8},"fieldConfig":{"defaults":{"unit":"bytes","min":0},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"node_memory_MemTotal_bytes{job=\"pve-host\"} - node_memory_MemAvailable_bytes{job=\"pve-host\"}","legendFormat":"занято"},{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"B","expr":"node_zfs_arc_size{job=\"pve-host\"}","legendFormat":"ZFS ARC"}],"options":{"legend":{"displayMode":"list","placement":"bottom"},"tooltip":{"mode":"multi"}}},
{"id":9,"type":"timeseries","title":"Сеть (nic0)","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":16,"y":4,"w":8,"h":8},"fieldConfig":{"defaults":{"unit":"bps","min":0},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"rate(node_network_receive_bytes_total{job=\"pve-host\",device=\"nic0\"}[$__rate_interval]) * 8","legendFormat":"приём"},{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"B","expr":"rate(node_network_transmit_bytes_total{job=\"pve-host\",device=\"nic0\"}[$__rate_interval]) * 8","legendFormat":"передача"}],"options":{"legend":{"displayMode":"list","placement":"bottom"},"tooltip":{"mode":"multi"}}},
{"id":10,"type":"stat","title":"SMART: 5 / 187 / 197 / 198 (должно быть 0)","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":12,"w":12,"h":8},"fieldConfig":{"defaults":{"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"red","value":1}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"{__name__=~\"smartmon_(reallocated_sector_ct|current_pending_sector|offline_uncorrectable|reported_uncorrect)_raw_value\"}","legendFormat":"{{disk}} #{{smart_id}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value_and_name","orientation":"horizontal"}},
{"id":11,"type":"gauge","title":"Износ NVMe","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":12,"y":12,"w":4,"h":8},"fieldConfig":{"defaults":{"unit":"percent","min":0,"max":100,"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":80},{"color":"red","value":100}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"nvme_percentage_used_ratio * 100","legendFormat":"{{device}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]}}},
{"id":12,"type":"stat","title":"Температура дисков","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":16,"y":12,"w":4,"h":8},"fieldConfig":{"defaults":{"unit":"celsius","thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":50},{"color":"red","value":60}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"smartmon_temperature_celsius_raw_value or smartmon_airflow_temperature_cel_raw_value","legendFormat":"{{disk}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value_and_name","orientation":"horizontal"}},
{"id":13,"type":"bargauge","title":"Заполнение ФС хоста","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":20,"y":12,"w":4,"h":8},"fieldConfig":{"defaults":{"unit":"percent","min":0,"max":100,"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":80},{"color":"red","value":90}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"100 - node_filesystem_avail_bytes{job=\"pve-host\",fstype=~\"ext4|xfs|zfs\"} / node_filesystem_size_bytes{job=\"pve-host\",fstype=~\"ext4|xfs|zfs\"} * 100","legendFormat":"{{mountpoint}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"orientation":"horizontal","displayMode":"gradient"}},
{"id":14,"type":"stat","title":"Контейнеры и ВМ","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":20,"w":6,"h":8},"fieldConfig":{"defaults":{"thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"green","value":1}]},"color":{"mode":"thresholds"},"mappings":[{"type":"value","options":{"1":{"text":"работает","color":"green","index":0},"0":{"text":"остановлен","color":"red","index":1}}}]},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"pve_up{id=~\"(lxc|qemu)/.+\"} * on(id) group_left(name) pve_guest_info","legendFormat":"{{name}} ({{id}})"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value_and_name","orientation":"horizontal"}},
{"id":15,"type":"timeseries","title":"CPU гостей","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":6,"y":20,"w":9,"h":8},"fieldConfig":{"defaults":{"unit":"percent","min":0},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"pve_cpu_usage_ratio{id=~\"(lxc|qemu)/.+\"} * on(id) group_left(name) pve_guest_info * 100","legendFormat":"{{name}}"}],"options":{"legend":{"displayMode":"list","placement":"bottom"},"tooltip":{"mode":"multi"}}},
{"id":16,"type":"timeseries","title":"ОЗУ гостей","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":15,"y":20,"w":9,"h":8},"fieldConfig":{"defaults":{"unit":"bytes","min":0},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"pve_memory_usage_bytes{id=~\"(lxc|qemu)/.+\"} * on(id) group_left(name) pve_guest_info","legendFormat":"{{name}}"}],"options":{"legend":{"displayMode":"list","placement":"bottom"},"tooltip":{"mode":"multi"}}},
{"id":17,"type":"stat","title":"Гости без бэкапа","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":28,"w":6,"h":8},"fieldConfig":{"defaults":{"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":1}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"count(pve_not_backed_up_info) or vector(0)","legendFormat":""}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":18,"type":"timeseries","title":"Дисковый ввод-вывод хоста","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":6,"y":28,"w":18,"h":8},"fieldConfig":{"defaults":{"unit":"Bps","min":0},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"rate(node_disk_read_bytes_total{job=\"pve-host\",device=~\"sd[a-z]+|nvme[0-9]+n[0-9]+\"}[$__rate_interval])","legendFormat":"{{device}} чтение"},{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"B","expr":"rate(node_disk_written_bytes_total{job=\"pve-host\",device=~\"sd[a-z]+|nvme[0-9]+n[0-9]+\"}[$__rate_interval])","legendFormat":"{{device}} запись"}],"options":{"legend":{"displayMode":"list","placement":"bottom"},"tooltip":{"mode":"multi"}}},
{"id":19,"type":"stat","title":"Роутер","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":36,"w":4,"h":4},"fieldConfig":{"defaults":{"thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"green","value":1}]},"color":{"mode":"thresholds"},"mappings":[{"type":"value","options":{"1":{"text":"UP","color":"green","index":0},"0":{"text":"DOWN","color":"red","index":1}}}]},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"up{job=\"openwrt\"}","legendFormat":"{{instance}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value_and_name"}},
{"id":20,"type":"stat","title":"Аптайм роутера","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":4,"y":36,"w":4,"h":4},"fieldConfig":{"defaults":{"unit":"s","decimals":0,"thresholds":{"mode":"absolute","steps":[{"color":"blue","value":null}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"time() - node_boot_time_seconds{job=\"openwrt\"}","legendFormat":"{{instance}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":21,"type":"stat","title":"Нагрузка роутера (1 мин)","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":8,"y":36,"w":4,"h":4},"fieldConfig":{"defaults":{"decimals":2,"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":2},{"color":"red","value":4}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"node_load1{job=\"openwrt\"}","legendFormat":"{{instance}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":22,"type":"stat","title":"ОЗУ роутера","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":12,"y":36,"w":4,"h":4},"fieldConfig":{"defaults":{"unit":"percent","decimals":0,"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":80},{"color":"red","value":90}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"(1 - node_memory_MemAvailable_bytes{job=\"openwrt\"} / node_memory_MemTotal_bytes{job=\"openwrt\"}) * 100","legendFormat":"{{instance}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":23,"type":"stat","title":"Клиенты Wi-Fi","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":16,"y":36,"w":4,"h":4},"fieldConfig":{"defaults":{"thresholds":{"mode":"absolute","steps":[{"color":"blue","value":null}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"sum by (instance) (wifi_stations{job=\"openwrt\"})","legendFormat":"{{instance}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":24,"type":"stat","title":"Conntrack роутера","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":20,"y":36,"w":4,"h":4},"fieldConfig":{"defaults":{"unit":"percent","decimals":0,"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":70},{"color":"red","value":90}]},"color":{"mode":"thresholds"}},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"node_nf_conntrack_entries{job=\"openwrt\"} / node_nf_conntrack_entries_limit{job=\"openwrt\"} * 100","legendFormat":"{{instance}}"}],"options":{"reduceOptions":{"calcs":["lastNotNull"]},"colorMode":"background","graphMode":"none","textMode":"value"}},
{"id":25,"type":"timeseries","title":"Трафик WAN роутера","datasource":{"type":"prometheus","uid":"prometheus"},"gridPos":{"x":0,"y":40,"w":24,"h":8},"fieldConfig":{"defaults":{"unit":"bps","min":0},"overrides":[]},"targets":[{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"A","expr":"rate(node_network_receive_bytes_total{job=\"openwrt\",device=~\".*wan.*\"}[$__rate_interval]) * 8","legendFormat":"{{device}} приём"},{"datasource":{"type":"prometheus","uid":"prometheus"},"refId":"B","expr":"rate(node_network_transmit_bytes_total{job=\"openwrt\",device=~\".*wan.*\"}[$__rate_interval]) * 8","legendFormat":"{{device}} передача"}],"options":{"legend":{"displayMode":"list","placement":"bottom"},"tooltip":{"mode":"multi"}}}
]}
EOF
  ok "Dashboard pve-overview: PVE overview (home page)"
}

set_home_dashboard() {
  local file=/etc/default/grafana-server
  local path=/var/lib/grafana/dashboards/pve-monitoring/overview.json
  sed -i '/^GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/d' "$file"
  printf 'GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=%s\n' "$path" >> "$file"
}

fetch_dashboards() {
  local dir=/var/lib/grafana/dashboards/pve-monitoring id
  install -d -o grafana -g grafana "$dir"
  for id in $GRAFANA_DASHBOARDS; do
    # Literal ${DS_PROMETHEUS}: the grafana.com import placeholder.
    # shellcheck disable=SC2016
    if curl -fsSL --max-time 60 \
      "https://grafana.com/api/dashboards/${id}/revisions/latest/download" \
      | sed 's/\${DS_PROMETHEUS}/prometheus/g' > "$dir/$id.json.tmp" \
      && jq -e '.title' "$dir/$id.json.tmp" > /dev/null; then
      mv -f "$dir/$id.json.tmp" "$dir/$id.json"
      chown grafana:grafana "$dir/$id.json"
      ok "Dashboard $id: $(jq -r '.title' "$dir/$id.json")"
    else
      rm -f "$dir/$id.json.tmp"
      warn "Dashboard $id could not be downloaded, skipped"
    fi
  done
}

show_targets() {
  for _ in $(seq 30); do
    curl -fs http://localhost:9090/-/ready > /dev/null && break
    sleep 2
  done
  # Give every job one scrape interval to report its first result.
  sleep 35
  log "Scrape targets:"
  curl -fs http://localhost:9090/api/v1/targets \
    | jq -r '.data.activeTargets[]
      | "    \(.health)\t\(.labels.job)\t\(.labels.instance)"' \
    || warn "Prometheus API did not answer"
}

upgrade_os
setup_pve_exporter
write_prometheus_config
write_alertmanager_config
restart_prometheus_stack
setup_grafana
show_targets
SCRIPT
}

# @description Print the grafana.com dashboards to provision: the
#   configured ones plus "OpenWrt" (11147) when routers are monitored.
# @stdout Space separated dashboard IDs.
dashboards_to_fetch() {
  local ids="$GRAFANA_DASHBOARDS"
  [[ -n "$OPENWRT_TARGETS" && " $ids " != *" 11147 "* ]] && ids+=" 11147"
  printf '%s' "$ids"
}

# @description Run the container setup with settings and secrets passed
#   through stdin.
run_container_setup() {
  local grafana_password=""
  [[ "$GRAFANA" == "1" ]] && grafana_password="$(secret_or_new grafana-admin-password)"

  local -A vars=(
    [HOST_IP]="$(host_address)"
    [XUI_TARGETS]="$(xui_targets)"
    [RETENTION]="$RETENTION"
    [PVE_USER]="$PVE_USER"
    [PVE_TOKEN_NAME]="$PVE_TOKEN_NAME"
    [PVE_TOKEN_VALUE]="$(read_secret pve-token)"
    [TG_BOT_TOKEN]="$TG_BOT_TOKEN"
    [TG_CHAT_ID]="$TG_CHAT_ID"
    [GRAFANA]="$GRAFANA"
    [GRAFANA_APT_URL]="$GRAFANA_APT_URL"
    [GRAFANA_DASHBOARDS]="$(dashboards_to_fetch)"
    [OPENWRT_TARGETS]="$OPENWRT_TARGETS"
    [GRAFANA_ADMIN_PASSWORD]="$grafana_password"
  )
  [[ -n "${vars[HOST_IP]}" ]] || die "no IPv4 address on $CT_BRIDGE"
  [[ -n "${vars[XUI_TARGETS]}" ]] \
    || warn "No running '$XUI_HOSTNAME' container, 3x-ui is not probed"

  local name
  {
    for name in "${!vars[@]}"; do
      printf 'export %s=%q\n' "$name" "${vars[$name]}"
    done
    container_script
  } | ct_exec bash -s
}

# ---- Summary ----

# @description Print the final summary without secrets.
print_summary() {
  local ip
  ip="$(ct_address_of "$CT_ID")"
  printf '\n========== monitoring ==========\n'
  printf 'Container    : %s (%s)\n' "$CT_ID" "$CT_HOSTNAME"
  printf 'Address      : %s\n' "${ip:-unknown}"
  printf 'MAC          : %s\n' "$(ct_mac)"
  printf 'Prometheus   : http://%s:9090\n' "$ip"
  printf 'Alertmanager : http://%s:9093\n' "$ip"
  if [[ "$GRAFANA" == "1" ]]; then
    printf 'Grafana      : http://%s:3000  (user admin)\n' "$ip"
    printf 'Password     : cat %s/grafana-admin-password\n' "$STATE_DIR"
  fi
  printf 'Secrets      : %s/\n' "$STATE_DIR"
  printf '================================\n'
  ct_uses_dhcp || return 0
  warn "The CT uses DHCP: reserve its address for the MAC above on the router"
}

# ---- Actions ----

# ID of the container that already has $CT_HOSTNAME, empty when none.
EXISTING_ID=""

# @description Create the container and set up monitoring in it.
action_install() {
  [[ -z "$EXISTING_ID" ]] || die "CT $EXISTING_ID ($CT_HOSTNAME) already exists"
  check_network_settings
  setup_host_exporters
  ensure_pve_token
  create_ct
  # "pct create --start 1" succeeds even when the start itself fails.
  ensure_running
  set_root_password
  wait_for_network
  run_container_setup
}

# @description Update the host exporters and everything in the container.
action_update() {
  [[ -n "$EXISTING_ID" ]] || die "no container named '$CT_HOSTNAME' to update"
  CT_ID="$EXISTING_ID"
  log "Updating CT $CT_ID ($CT_HOSTNAME)"
  setup_host_exporters
  ensure_pve_token
  snapshot_ct
  ensure_running
  wait_for_network
  run_container_setup
}

# @description Pick install or update depending on whether the CT exists.
action_auto() {
  if [[ -n "$EXISTING_ID" ]]; then
    action_update
  else
    action_install
  fi
}

# Command-line flag -> action (lookup table instead of if/elif chains).
declare -A ACTIONS=(
  [--auto]=action_auto
  [--install]=action_install
  [--update]=action_update
)

# ---- Main ----

# @description Entry point.
# @arg $1 string Mode flag, see usage.
main() {
  local mode="${1:---auto}"
  if [[ "$mode" == "--help" || "$mode" == "-h" ]]; then
    usage
    return 0
  fi
  [[ -n "${ACTIONS[$mode]+x}" ]] || { usage >&2; die "unknown mode: $mode"; }

  require_root
  require_pve
  take_lock
  (umask 077 && : >> "$LOG_FILE")
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "pve-monitoring.sh started $(date '+%F %T'), mode $mode"

  EXISTING_ID="$(find_ct_by_hostname "$CT_HOSTNAME")"
  "${ACTIONS[$mode]}"
  save_settings
  print_summary
  ok "Done. Log: $LOG_FILE"
}

main "$@"
