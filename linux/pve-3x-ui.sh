#!/usr/bin/env bash
#
# @file pve-3x-ui.sh
# @brief Unattended deploy and update of the 3x-ui panel in a Proxmox LXC.
# @description
#   Runs on a Proxmox VE host as root and needs no answers:
#
#   * No container named $CT_HOSTNAME yet: downloads the latest Debian
#     template, creates an unprivileged container, installs 3x-ui with the
#     official installer in non-interactive mode and saves the generated
#     credentials on the host.
#   * Container already exists: snapshots it, upgrades Debian packages and
#     re-runs the official installer, which replaces the binaries and keeps
#     the panel settings, database, inbounds and clients.
#
#   How to run:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-3x-ui.sh)
#
#   With settings (all optional, see --help):
#     CT_IP=192.168.11.50/24 CT_GW=192.168.11.1 bash pve-3x-ui.sh
#
#   Secrets are masked in the output and the log (mode 600). They are saved
#   under $STATE_DIR (mode 600).

set -euo pipefail

# ---- Settings (environment overrides) ----

CT_HOSTNAME="${CT_HOSTNAME:-xui}"
CT_ID="${CT_ID:-}"
CT_STORAGE="${CT_STORAGE:-}"
CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-}"
CT_DEBIAN="${CT_DEBIAN:-13}"
CT_DISK_GB="${CT_DISK_GB:-8}"
CT_CORES="${CT_CORES:-1}"
CT_MEMORY="${CT_MEMORY:-1024}"
CT_SWAP="${CT_SWAP:-512}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"
CT_GW="${CT_GW:-}"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-3}"
FORCE="${FORCE:-0}"
XUI_VERSION="${XUI_VERSION:-}"
XUI_INSTALLER_URL="${XUI_INSTALLER_URL:-https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh}"

# The host may be reached through the PVE web shell, which starts without
# $HOME, so the state paths are absolute on purpose.
STATE_DIR="/root/pve-3x-ui"
LOG_FILE="/var/log/pve-3x-ui.log"
LOCK_FILE="/run/lock/pve-3x-ui.lock"
SNAPSHOT_PREFIX="xui_"
NETWORK_TIMEOUT=120

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
pve-3x-ui.sh - deploy or update 3x-ui in a Proxmox LXC, unattended.

Usage:
  pve-3x-ui.sh [--auto | --install | --update | --help]

Modes:
  --auto     install if the container does not exist, update otherwise
             (default)
  --install  only create a new container, fail if it already exists
  --update   only update an existing container, fail if it is missing

Environment (all optional):
  CT_HOSTNAME          hostname, also used to find the CT again  [xui]
  CT_ID                ID for a new container               [next free]
  CT_STORAGE           storage for the root disk                 [auto]
  CT_TEMPLATE_STORAGE  storage for templates                     [auto]
  CT_DEBIAN            Debian major version of the template        [13]
  CT_DISK_GB           root disk size, GiB                          [8]
  CT_CORES             CPU cores                                    [1]
  CT_MEMORY            RAM, MiB                                  [1024]
  CT_SWAP              swap, MiB                                  [512]
  CT_BRIDGE            network bridge                           [vmbr0]
  CT_IP                "dhcp" or CIDR, e.g. 192.168.11.50/24     [dhcp]
  CT_GW                gateway, required with a static CT_IP
  KEEP_SNAPSHOTS       update snapshots to keep                     [3]
  FORCE                1 = reinstall 3x-ui even if it is up to date [0]
  XUI_VERSION          3x-ui release tag, e.g. v3.7.0          [latest]
  XUI_*                any other XUI_* variable goes to the official
                       installer (XUI_PANEL_PORT, XUI_USERNAME, ...)

Secrets are saved under /root/pve-3x-ui/ct-<ID>/ (mode 600).
Log: /var/log/pve-3x-ui.log
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
  for tool in pct pveam pvesh pvesm; do
    command -v "$tool" > /dev/null && continue
    die "'$tool' not found, this script must run on a Proxmox VE host"
  done
}

# @description Stop if another copy of the script is already running.
take_lock() {
  exec 9> "$LOCK_FILE"
  flock -n 9 && return 0
  die "another pve-3x-ui.sh is already running"
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

# @description Print the newest standard Debian template available.
# @stdout Template file name.
latest_template() {
  pveam update > /dev/null 2>&1 \
    || warn "pveam update failed, using the cached list"
  pveam available --section system \
    | awk '{ print $2 }' \
    | { grep -E "^debian-${CT_DEBIAN}-standard_" || true; } \
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

# @description Run a command inside the container.
# @arg $@ string Command and arguments.
ct_exec() {
  pct exec "$CT_ID" -- env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

# @description Start the container unless it is already running.
ensure_running() {
  pct status "$CT_ID" | grep -q 'running' && return 0
  log "Starting container $CT_ID"
  pct start "$CT_ID"
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

# @description Print the IPv4 address of eth0 inside the container.
# @stdout Address without the prefix length.
ct_address() {
  { ct_exec ip -4 -o addr show dev eth0 2> /dev/null || true; } \
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
    --description "3x-ui, managed by pve-3x-ui.sh" \
    --tags 3x-ui \
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
  password="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  printf 'root:%s\n' "$password" | pct exec "$CT_ID" -- chpasswd
  save_secret "root-password" "$password"
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

# ---- Inside the container ----

# @description Upgrade Debian packages, keeping local config files.
upgrade_os() {
  log "Upgrading Debian packages"
  ct_exec apt-get update -q
  ct_exec apt-get -y -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    full-upgrade
  ct_exec apt-get -y -q install curl ca-certificates openssl
  ct_exec apt-get -y -q autoremove
  ok "Debian packages are up to date"
}

# @description Print every XUI_* variable of this shell as NAME=value,
#   one per line, for the official installer.
# @stdout Lines of NAME=value.
xui_env() {
  local name
  for name in $(compgen -e | grep '^XUI_' || true); do
    case "$name" in
      XUI_VERSION | XUI_INSTALLER_URL) continue ;;
    esac
    printf '%s=%s\n' "$name" "${!name}"
  done
}

# @description Install or update 3x-ui with the official installer.
#   On an existing panel the installer keeps settings and database.
install_xui() {
  local -a env_args=(XUI_NONINTERACTIVE=1 "XUI_SSL_MODE=${XUI_SSL_MODE:-none}")
  local line
  while IFS= read -r line; do
    env_args+=("$line")
  done < <(xui_env)

  log "Running the official 3x-ui installer ${XUI_VERSION:-(latest)}"
  ct_exec curl -fsSL --retry 3 -o /root/xui-install.sh "$XUI_INSTALLER_URL"
  ct_exec env "${env_args[@]}" bash /root/xui-install.sh \
    ${XUI_VERSION:+"$XUI_VERSION"} < /dev/null | mask_secrets
  ct_exec rm -f /root/xui-install.sh

  ct_exec systemctl is-active --quiet x-ui || die "x-ui is not running"
  ok "3x-ui is installed and running"
}

# @description Hide credentials that the official installer prints, so they
#   reach neither the terminal nor the log. They are kept in
#   /etc/x-ui/install-result.env and copied to $STATE_DIR instead.
# @stdin Installer output.
# @stdout The same output with secret values replaced by ***.
mask_secrets() {
  local keys='Username|Password|API Token|WebBasePath|Access URL'
  sed -u -E "s/((${keys})[^:]*:[[:space:]]*).*/\1***\x1b[0m/"
}

# @description Print the latest 3x-ui release tag, empty when unknown.
#   Uses the release redirect, which has no API rate limit.
# @stdout Tag such as v3.7.0.
latest_xui_tag() {
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 \
    --max-time 30 https://github.com/MHSanaei/3x-ui/releases/latest \
    2> /dev/null || true)"
  [[ "$url" == */tag/* ]] || return 0
  printf '%s' "${url##*/tag/}"
}

# @description Print the installed 3x-ui version, empty when unknown.
# @stdout Version such as 3.7.0.
installed_xui_version() {
  ct_exec /usr/local/x-ui/x-ui -v 2> /dev/null || true
}

# @description Install 3x-ui unless the target version is already there.
#   FORCE=1 reinstalls anyway.
update_xui_if_needed() {
  local current target
  current="$(installed_xui_version)"
  target="${XUI_VERSION:-$(latest_xui_tag)}"
  if [[ "$FORCE" == "1" || -z "$current" || -z "$target" ]]; then
    install_xui
    return 0
  fi
  if [[ "${current#v}" != "${target#v}" ]]; then
    log "3x-ui $current -> $target"
    install_xui
    return 0
  fi
  ok "3x-ui $current is already the target version, nothing to update"
}

# ---- State on the host ----

# @description Save a secret under the container's state folder.
# @arg $1 string File name.
# @arg $2 string Content.
save_secret() {
  local dir="$STATE_DIR/ct-$CT_ID"
  install -d -m 700 "$STATE_DIR" "$dir"
  (umask 077 && printf '%s\n' "$2" > "$dir/$1")
}

# @description Copy the installer's credentials file to the host.
#   It only exists after the first install, so absence is fine.
save_panel_credentials() {
  local result
  result="$(ct_exec cat /etc/x-ui/install-result.env 2> /dev/null || true)"
  [[ -n "$result" ]] || return 0
  save_secret "install-result.env" "$result"
  ok "Panel credentials saved"
}

# @description Print a value from the saved credentials file.
# @arg $1 string Variable name (XUI_PANEL_PORT, ...).
# @stdout Value, empty when unknown.
saved_value() {
  local file="$STATE_DIR/ct-$CT_ID/install-result.env"
  [[ -f "$file" ]] || return 0
  # Values are written with printf %q, so sourcing in a subshell is safe.
  # shellcheck disable=SC1090
  (source "$file" && printf '%s' "${!1:-}")
}

# @description Print the final summary without secrets.
print_summary() {
  local ip port path
  ip="$(ct_address)"
  port="$(saved_value XUI_PANEL_PORT)"
  path="$(saved_value XUI_WEB_BASE_PATH)"

  printf '\n========== 3x-ui ==========\n'
  printf 'Container : %s (%s)\n' "$CT_ID" "$CT_HOSTNAME"
  printf 'Address   : %s\n' "${ip:-unknown}"
  printf 'MAC       : %s\n' "$(ct_mac)"
  if [[ -n "$port" ]]; then
    printf 'Panel     : http://%s:%s/%s\n' "$ip" "$port" "$path"
  fi
  printf 'Secrets   : %s/ct-%s/\n' "$STATE_DIR" "$CT_ID"
  printf 'Show them : cat %s/ct-%s/install-result.env\n' "$STATE_DIR" "$CT_ID"
  printf '===========================\n'
  ct_uses_dhcp || return 0
  warn "The CT uses DHCP: reserve its address for the MAC above on the router"
}

# ---- Actions ----

# ID of the container that already has $CT_HOSTNAME, empty when none.
EXISTING_ID=""

# @description Create a container and install 3x-ui into it.
action_install() {
  [[ -z "$EXISTING_ID" ]] || die "CT $EXISTING_ID ($CT_HOSTNAME) already exists"
  check_network_settings
  create_ct
  set_root_password
  wait_for_network
  upgrade_os
  install_xui
  save_panel_credentials
}

# @description Update Debian and 3x-ui in the existing container.
action_update() {
  [[ -n "$EXISTING_ID" ]] || die "no container named '$CT_HOSTNAME' to update"
  CT_ID="$EXISTING_ID"
  log "Updating CT $CT_ID ($CT_HOSTNAME)"
  snapshot_ct
  ensure_running
  wait_for_network
  upgrade_os
  update_xui_if_needed
  save_panel_credentials
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
  log "pve-3x-ui.sh started $(date '+%F %T'), mode $mode"

  EXISTING_ID="$(find_ct_by_hostname "$CT_HOSTNAME")"
  "${ACTIONS[$mode]}"
  print_summary
  ok "Done. Log: $LOG_FILE"
}

main "$@"
