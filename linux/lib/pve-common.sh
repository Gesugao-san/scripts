# shellcheck shell=bash
#
# @file pve-common.sh
# @brief Shared host-side code of the pve-*.sh guest scripts.
# @description
#   Sourced by lib/pve-ct.sh and lib/pve-vm.sh, never run directly. A guest
#   script sets SERVICE and PERSISTED_SETTINGS, sources one of those two
#   libraries, defines its hooks and calls guest_main. The flow is the same
#   for every service:
#
#   * install: create the guest, start it, wait for it, run the setup;
#   * update: snapshot the guest, start it, wait for it, run the setup.
#
#   The setup is a bash script streamed into the guest through stdin:
#   "export" lines with settings and secrets, the shared prelude
#   (guest_prelude), the service script (service_script) and "main". Secrets
#   never show up in process arguments on the host.
#
#   Hooks a service script can define (all optional except service_script):
#
#   | Hook                | When                                          |
#   |---------------------|-----------------------------------------------|
#   | service_usage       | --help, after the common options              |
#   | service_preflight   | before anything changes                       |
#   | service_host_setup  | on the host, before the guest starts          |
#   | service_create_args | extra "pct/qm create" arguments, one per line |
#   | service_after_create| once, right after the guest was created       |
#   | service_exports     | settings and secrets for the guest setup      |
#   | service_script      | the setup run inside the guest (required)     |
#   | service_summary     | extra lines of the final summary              |
#
#   A line "@@secret NAME VALUE" printed by the guest setup is saved as
#   $STATE_DIR/NAME on the host and not shown or logged.

# Variables here are shared with the other libraries and scripts.
# shellcheck disable=SC2034,SC2153
[[ -n "${SERVICE:-}" ]] || {
  printf '[x] ERROR: SERVICE must be set before sourcing pve-common.sh\n' >&2
  exit 1
}

# The host may be reached through the PVE web shell, which starts without
# $HOME, so the state paths are absolute on purpose.
STATE_DIR="/root/pve-$SERVICE"
SETTINGS_FILE="$STATE_DIR/settings.env"
LOG_FILE="/var/log/pve-$SERVICE.log"
LOCK_FILE="/run/lock/pve-$SERVICE.lock"
SNAPSHOT_PREFIX="${SERVICE//-/_}_"

# ID of the guest that already exists under the service name, empty if none.
EXISTING_ID=""
# Set to 1 by a hook that changed the guest config while it was running.
GUEST_NEEDS_RESTART=0

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

# ---- Default hooks (null objects, overridden by the service script) ----

service_usage() { :; }
service_preflight() { :; }
service_host_setup() { :; }
service_create_args() { :; }
service_after_create() { :; }
service_exports() { :; }
service_summary() { :; }

# ---- Settings (environment > saved > default) ----

# @description Load saved settings for variables that are not set in the
#   environment. A variable set to an empty value still wins, so an empty
#   value clears a saved one.
guest_load_settings() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  local name value
  while IFS='=' read -r name value; do
    [[ " ${PERSISTED_SETTINGS[*]} " == *" $name "* ]] || continue
    [[ -z "${!name+x}" ]] || continue
    # Values are written with printf %q by save_settings.
    eval "$name=$value"
  done < "$SETTINGS_FILE"
}

# @description Remember the persisted settings for the next run. The file
#   may hold tokens, so it is created with mode 600.
save_settings() {
  local name
  install -d -m 700 "$STATE_DIR"
  (
    umask 077
    {
      printf '# Managed by pve-%s.sh; edit or delete to reset.\n' "$SERVICE"
      for name in "${PERSISTED_SETTINGS[@]}"; do
        printf '%s=%q\n' "$name" "${!name}"
      done
    } > "$SETTINGS_FILE"
  )
  chmod 600 "$SETTINGS_FILE"
}

# ---- Secrets on the host ----

# @description Save a secret under $STATE_DIR with mode 600.
# @arg $1 string File name (may contain one subdirectory level).
# @arg $2 string Content.
save_secret() {
  install -d -m 700 "$(dirname "$STATE_DIR/$1")"
  (umask 077 && printf '%s\n' "$2" > "$STATE_DIR/$1")
}

# @description Print a saved secret, empty when missing.
# @arg $1 string File name.
# @stdout First line of the file.
read_secret() {
  [[ -s "$STATE_DIR/$1" ]] || return 0
  head -n 1 "$STATE_DIR/$1"
}

# @description Print a secret, generating and saving a random one first
#   when it does not exist yet. The value has upper case, lower case and
#   digits, which satisfies the usual password rules.
# @arg $1 string File name.
# @stdout Secret.
secret_or_new() {
  local value
  value="$(read_secret "$1")"
  if [[ -z "$value" ]]; then
    value="Pv$(openssl rand -hex 12)"
    save_secret "$1" "$value"
  fi
  printf '%s' "$value"
}

# @description Print an "export" line for the guest setup.
# @arg $1 string Variable name.
# @arg $2 string Value.
# @stdout Shell line.
export_var() {
  printf 'export %s=%q\n' "$1" "$2"
}

# @description Pass the guest setup output through, saving "@@secret"
#   lines on the host instead of printing them.
filter_setup_output() {
  local line name value
  while IFS= read -r line; do
    if [[ "$line" == "@@secret "* ]]; then
      read -r _ name value <<< "$line"
      save_secret "$name" "$value"
      continue
    fi
    printf '%s\n' "$line"
  done
}

# ---- Guards ----

# @description Stop unless running as root.
require_root() {
  [[ "$(id -u)" -eq 0 ]] && return 0
  die "run me as root"
}

# @description Stop unless the given commands exist.
# @arg $@ string Command names.
require_commands() {
  local tool
  for tool in "$@"; do
    command -v "$tool" > /dev/null && continue
    die "'$tool' not found, this script must run on a Proxmox VE host"
  done
}

# @description Stop if another copy of the script is already running. The
#   lock lives on file descriptor 9; commands that start long-lived
#   processes (VMs) must close it with "9>&-".
take_lock() {
  exec 9> "$LOCK_FILE"
  flock -n 9 && return 0
  die "another pve-$SERVICE.sh is already running"
}

# @description Fail when an address already answers ping.
# @arg $1 string IPv4 address.
require_free_address() {
  ping -c 1 -W 1 "$1" > /dev/null 2>&1 || return 0
  die "$1 already answers ping, pick another address"
}

# ---- Snapshots (the same for pct and qm) ----

# @description Snapshot the guest and keep only the newest update
#   snapshots. Storages without snapshot support only produce a warning.
snapshot_guest() {
  local name
  name="${SNAPSHOT_PREFIX}$(date +%Y%m%d_%H%M%S)"
  if ! "$GUEST_TOOL" snapshot "$GUEST_ID" "$name" --description "before update" \
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
  "$GUEST_TOOL" listsnapshot "$GUEST_ID" \
    | { grep -oE "\b${SNAPSHOT_PREFIX}[0-9]{8}_[0-9]{6}\b" || true; } \
    | sort -u \
    | head -n "-$KEEP_SNAPSHOTS" \
    | while read -r old; do
      if "$GUEST_TOOL" delsnapshot "$GUEST_ID" "$old"; then
        log "Old snapshot $old removed"
      else
        warn "Could not remove old snapshot $old"
      fi
    done
}

# ---- Inside the guest ----

# @description Print the prelude shared by every guest setup: strict mode,
#   output helpers and package helpers.
# @stdout Bash code.
guest_prelude() {
  cat << 'PRELUDE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }

# Installs packages, keeping local config files on upgrades.
apt_install() {
  apt-get install -y -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@" > /dev/null
}

# Updates the package lists and upgrades the whole system.
upgrade_os() {
  log "Upgrading Debian packages"
  apt-get update -q > /dev/null
  apt-get full-upgrade -y -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold > /dev/null
  ok "Debian packages are up to date"
}

# Writes stdin to a file atomically: write_file PATH MODE [OWNER].
write_file() {
  install -d "$(dirname "$1")"
  cat > "$1.tmp"
  chmod "$2" "$1.tmp"
  [[ -z "${3:-}" ]] || chown "$3" "$1.tmp"
  mv -f "$1.tmp" "$1"
}

# Hands a secret to the host, which saves it instead of printing it.
emit_secret() {
  printf '@@secret %s %s\n' "$1" "$2"
}

# Prints the tag of the latest GitHub release of OWNER/REPO, empty on error.
latest_github_tag() {
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 \
    "https://github.com/$1/releases/latest" || true)"
  [[ "$url" == */tag/* ]] || return 0
  printf '%s' "${url##*/tag/}"
}
PRELUDE
}

# @description Run the guest setup: exports, prelude, service script and
#   its main, streamed through stdin.
guest_run_setup() {
  {
    service_exports
    guest_prelude
    service_script
    # The script arrives on stdin: give its commands /dev/null instead, so
    # nothing can swallow the rest of it.
    printf '\nmain < /dev/null\n'
  } | guest_exec_script | filter_setup_output
}

# ---- Summary ----

# @description Print the final summary without secrets.
print_summary() {
  printf '\n========== %s ==========\n' "$SERVICE"
  guest_summary
  service_summary
  printf 'Secrets   : %s/\n' "$STATE_DIR"
  printf '==========%s============\n' "${SERVICE//?/=}"
}

# ---- Actions ----

# @description Create the guest and run the setup in it.
action_install() {
  [[ -z "$EXISTING_ID" ]] || die "$GUEST_KIND $EXISTING_ID ($SERVICE) already exists"
  service_preflight
  guest_check_network
  service_host_setup
  guest_create
  guest_ensure_running
  guest_after_create
  service_after_create
  guest_restart_if_needed
  guest_wait_ready
  guest_run_setup
}

# @description Snapshot the guest and run the setup again, which updates it.
action_update() {
  [[ -n "$EXISTING_ID" ]] || die "no $GUEST_KIND for '$SERVICE' to update"
  GUEST_ID="$EXISTING_ID"
  log "Updating $GUEST_KIND $GUEST_ID ($SERVICE)"
  service_preflight
  snapshot_guest
  service_host_setup
  guest_ensure_running
  guest_restart_if_needed
  guest_wait_ready
  guest_run_setup
}

# @description Pick install or update depending on whether the guest exists.
action_auto() {
  if [[ -n "$EXISTING_ID" ]]; then
    action_update
  else
    action_install
  fi
}

# Command-line flag -> action (lookup table instead of if/elif chains).
# Global on purpose: this file is sourced from inside a function.
declare -gA ACTIONS=(
  [--auto]=action_auto
  [--install]=action_install
  [--update]=action_update
)

# @description Print usage information.
usage() {
  cat << EOF
pve-$SERVICE.sh - deploy or update $SERVICE on Proxmox VE.

Usage:
  pve-$SERVICE.sh [--auto | --install | --update | --help]

Modes:
  --auto     install if the $GUEST_KIND does not exist, update otherwise
             (default)
  --install  only create a new $GUEST_KIND, fail if it already exists
  --update   only update an existing $GUEST_KIND, fail if it is missing

EOF
  guest_usage
  service_usage
  cat << EOF

Settings given once are remembered in $SETTINGS_FILE.
Secrets are saved under $STATE_DIR/ (mode 600).
Log: $LOG_FILE
EOF
}

# @description Entry point shared by all guest scripts.
# @arg $1 string Mode flag, see usage.
guest_main() {
  local mode="${1:---auto}"
  if [[ "$mode" == "--help" || "$mode" == "-h" ]]; then
    usage
    return 0
  fi
  [[ -n "${ACTIONS[$mode]+x}" ]] || { usage >&2; die "unknown mode: $mode"; }

  require_root
  guest_require_tools
  take_lock
  (umask 077 && : >> "$LOG_FILE")
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "pve-$SERVICE.sh started $(date '+%F %T'), mode $mode"

  EXISTING_ID="$(guest_find)"
  "${ACTIONS[$mode]}"
  save_settings
  print_summary
  ok "Done. Log: $LOG_FILE"
}
