# shellcheck shell=bash
#
# @file pve-ct.sh
# @brief Shared code of the pve-*.sh scripts that manage an LXC container.
# @description
#   Sourced by a guest script after it set SERVICE and PERSISTED_SETTINGS
#   (see lib/pve-common.sh for the flow and the hooks). Creates an
#   unprivileged Debian container from the newest standard template, finds
#   it again by hostname, runs commands in it with "pct exec".
#
#   Container settings (environment, all optional):
#   CT_HOSTNAME, CT_ID, CT_STORAGE, CT_TEMPLATE_STORAGE, CT_DEBIAN,
#   CT_DISK_GB, CT_CORES, CT_MEMORY, CT_SWAP, CT_BRIDGE, CT_IP, CT_GW,
#   KEEP_SNAPSHOTS. A guest script sets its own defaults for the sizes
#   before calling ct_defaults.

# Variables here are shared with the other libraries and scripts.
# shellcheck disable=SC2034,SC2153
pve_source pve-common.sh

GUEST_TOOL="pct"
GUEST_KIND="CT"
NETWORK_TIMEOUT=120

# @description Fill the container settings that the environment and the
#   guest script left empty.
ct_defaults() {
  CT_HOSTNAME="${CT_HOSTNAME:-$SERVICE}"
  CT_ID="${CT_ID:-}"
  CT_STORAGE="${CT_STORAGE:-}"
  CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-}"
  CT_DEBIAN="${CT_DEBIAN:-13}"
  CT_DISK_GB="${CT_DISK_GB:-8}"
  CT_CORES="${CT_CORES:-1}"
  CT_MEMORY="${CT_MEMORY:-512}"
  CT_SWAP="${CT_SWAP:-512}"
  CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
  CT_IP="${CT_IP:-dhcp}"
  CT_GW="${CT_GW:-}"
  CT_DESCRIPTION="${CT_DESCRIPTION:-$SERVICE}"
  KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-3}"
  GUEST_ID="$CT_ID"
}

# @description Print the container part of the usage text.
guest_usage() {
  cat << EOF
Container (environment, all optional):
  CT_HOSTNAME          hostname, also used to find the CT    [$CT_HOSTNAME]
  CT_ID                ID for a new container                [next free]
  CT_STORAGE           storage for the root disk                  [auto]
  CT_TEMPLATE_STORAGE  storage for templates                      [auto]
  CT_DEBIAN            Debian major version of the template  [$CT_DEBIAN]
  CT_DISK_GB           root disk size, GiB                   [$CT_DISK_GB]
  CT_CORES             CPU cores                             [$CT_CORES]
  CT_MEMORY            RAM, MiB                              [$CT_MEMORY]
  CT_SWAP              swap, MiB                             [$CT_SWAP]
  CT_BRIDGE            network bridge                        [$CT_BRIDGE]
  CT_IP                "dhcp" or CIDR, e.g. 192.168.11.60/24 [$CT_IP]
  CT_GW                gateway, required with a static CT_IP
  KEEP_SNAPSHOTS       update snapshots to keep              [$KEEP_SNAPSHOTS]
EOF
}

# @description Stop unless the Proxmox container tools are available.
guest_require_tools() {
  require_commands pct pveam pvesh pvesm
}

# @description Validate the network settings of a new container.
guest_check_network() {
  [[ "$CT_IP" == "dhcp" ]] && return 0
  [[ -n "$CT_GW" ]] || die "CT_GW is required with a static CT_IP"
  require_free_address "${CT_IP%/*}"
}

# ---- Lookup ----

# @description Print the ID of the container with the given hostname.
# @arg $1 string Hostname.
# @stdout Container ID, empty when none.
find_ct_by_hostname() {
  pct list | awk -v name="$1" 'NR > 1 && $NF == name { print $1; exit }'
}

# @description Print the ID of this service's container.
# @stdout Container ID, empty when none.
guest_find() {
  find_ct_by_hostname "$CT_HOSTNAME"
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

# @description Print the newest standard Debian template for the host
#   architecture. PVE 9 also lists arm64 templates, and "arm64" sorts after
#   "amd64", so the architecture filter is required.
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

# ---- Running things inside ----

# @description Run a command inside a container.
# @arg $1 int Container ID.
# @arg $@ string Command and arguments.
ct_exec_in() {
  local id="$1"
  shift
  pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

# @description Run a command inside this service's container.
# @arg $@ string Command and arguments.
ct_exec() {
  ct_exec_in "$GUEST_ID" "$@"
}

# @description Run the setup script from stdin inside the container.
guest_exec_script() {
  ct_exec bash -s
}

# @description Print the IPv4 address of eth0 inside a container.
# @arg $1 int Container ID.
# @stdout Address without the prefix length, empty when unknown.
ct_address_of() {
  { ct_exec_in "$1" ip -4 -o addr show dev eth0 2> /dev/null || true; } \
    | awk '{ split($4, a, "/"); print a[1]; exit }'
}

# @description Print the IPv4 address of this service's container.
# @stdout Address, empty when unknown.
guest_address() {
  ct_address_of "$GUEST_ID"
}

# @description Print the IPv4 address of the host on $CT_BRIDGE.
# @stdout Address without the prefix length.
host_address() {
  ip -4 -o addr show dev "$CT_BRIDGE" \
    | awk '{ split($4, a, "/"); print a[1]; exit }'
}

# ---- Lifecycle ----

# @description Create and start a new unprivileged container. Extra
#   "pct create" arguments come from service_create_args, one per line.
guest_create() {
  local storage="${CT_STORAGE:-$(pick_storage rootdir)}"
  local tpl_storage="${CT_TEMPLATE_STORAGE:-$(pick_storage vztmpl)}"
  [[ -n "$storage" ]] || die "no storage accepts container disks (rootdir)"
  [[ -n "$tpl_storage" ]] || die "no storage accepts templates (vztmpl)"

  local template
  template="$(latest_template)"
  [[ -n "$template" ]] || die "no debian-${CT_DEBIAN}-standard template found"
  ensure_template "$tpl_storage" "$template"

  GUEST_ID="${CT_ID:-$(pvesh get /cluster/nextid)}"
  local net="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
  [[ -n "$CT_GW" ]] && net+=",gw=${CT_GW}"
  local -a extra=()
  mapfile -t extra < <(service_create_args)

  log "Creating CT $GUEST_ID ($CT_HOSTNAME) on $storage"
  pct create "$GUEST_ID" "$tpl_storage:vztmpl/$template" \
    --hostname "$CT_HOSTNAME" \
    --description "$CT_DESCRIPTION, managed by pve-$SERVICE.sh" \
    --tags "$SERVICE" \
    --unprivileged 1 \
    --features nesting=1 \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --rootfs "$storage:$CT_DISK_GB" \
    --net0 "$net" \
    --timezone host \
    --onboot 1 \
    "${extra[@]}"
  ok "Container $GUEST_ID created"
}

# @description Start the container unless it is already running. The lock
#   descriptor is closed for pct, which may leave processes behind.
# @exitcode 1 The container does not run after the start attempt.
guest_ensure_running() {
  pct status "$GUEST_ID" | grep -q 'running' && return 0
  log "Starting container $GUEST_ID"
  pct start "$GUEST_ID" 9>&- || true
  pct status "$GUEST_ID" | grep -q 'running' && return 0
  die "CT $GUEST_ID does not start, see: pct start $GUEST_ID --debug"
}

# @description Reboot the container when a hook changed its config.
guest_restart_if_needed() {
  [[ "$GUEST_NEEDS_RESTART" == "1" ]] || return 0
  log "Restarting CT $GUEST_ID to apply the new config"
  pct reboot "$GUEST_ID" 9>&-
  GUEST_NEEDS_RESTART=0
}

# @description Set a container option unless it already has that value,
#   and remember that a restart is needed.
# @arg $1 string Option name (dev0, mp0, ...).
# @arg $2 string Value.
ct_set_option() {
  local current
  current="$(pct config "$GUEST_ID" | awk -v key="$1:" '$1 == key { print $2 }')"
  # PVE may drop the optional "path=" key when it stores the value.
  [[ "${current#path=}" == "${2#path=}" ]] && return 0
  pct set "$GUEST_ID" "--$1" "$2"
  GUEST_NEEDS_RESTART=1
  ok "CT option $1 set to $2"
}

# @description Give the new container a random root password saved on the
#   host. The password goes through stdin, never through arguments.
guest_after_create() {
  local password
  password="$(openssl rand -hex 12)"
  printf 'root:%s\n' "$password" | pct exec "$GUEST_ID" -- chpasswd
  save_secret "ct-$GUEST_ID-root-password" "$password"
  ok "Root password set and saved"
}

# @description Wait until the container resolves names.
# @exitcode 1 Network is not up within $NETWORK_TIMEOUT seconds.
guest_wait_ready() {
  local waited=0
  log "Waiting for network inside the container"
  until ct_exec getent hosts deb.debian.org > /dev/null 2>&1; do
    ((waited += 3))
    ((waited < NETWORK_TIMEOUT)) || die "no network in CT $GUEST_ID"
    sleep 3
  done
  ok "Network is up"
}

# @description Print the container part of the summary.
guest_summary() {
  local mac
  mac="$(pct config "$GUEST_ID" | grep -oE 'hwaddr=[0-9A-Fa-f:]+' | cut -d= -f2 || true)"
  printf 'Container : %s (%s)\n' "$GUEST_ID" "$CT_HOSTNAME"
  printf 'Address   : %s\n' "$(guest_address || true)"
  printf 'MAC       : %s\n' "$mac"
  pct config "$GUEST_ID" | grep -q '^net0:.*ip=dhcp' || return 0
  printf 'Note      : DHCP, reserve the address for this MAC on the router\n'
}
