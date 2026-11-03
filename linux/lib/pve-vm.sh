# shellcheck shell=bash
#
# @file pve-vm.sh
# @brief Shared code of the pve-*.sh scripts that manage a Debian VM.
# @description
#   Sourced by a guest script after it set SERVICE and PERSISTED_SETTINGS
#   (see lib/pve-common.sh for the flow and the hooks). Creates a VM from
#   the Debian cloud image (checksum verified) with cloud-init, a static IP
#   and a dedicated SSH key of this host, and runs the setup over SSH.
#   Use a VM instead of a container when the service needs Docker.
#
#   VM settings (environment): VM_IP and VM_GW are required for a new VM;
#   VM_NAME, VM_ID, VM_STORAGE, VM_CORES, VM_MEMORY, VM_DISK_GB, VM_BRIDGE,
#   VM_DNS, KEEP_SNAPSHOTS are optional. A guest script sets its own
#   defaults for the sizes before calling vm_defaults, and should list VM_IP,
#   VM_GW and VM_DNS in PERSISTED_SETTINGS.

# Variables here are shared with the other libraries and scripts.
# shellcheck disable=SC2034,SC2153
pve_source pve-common.sh

GUEST_TOOL="qm"
GUEST_KIND="VM"
IMAGE_BASE="https://cloud.debian.org/images/cloud/trixie/latest"
IMAGE_NAME="debian-13-genericcloud-amd64.qcow2"
IMAGE_DIR="/var/lib/vz/import"
VM_USER="pve"
SSH_TIMEOUT=300

# @description Fill the VM settings that the environment and the guest
#   script left empty.
vm_defaults() {
  VM_NAME="${VM_NAME:-$SERVICE}"
  VM_ID="${VM_ID:-}"
  VM_STORAGE="${VM_STORAGE:-}"
  VM_CORES="${VM_CORES:-2}"
  VM_MEMORY="${VM_MEMORY:-2048}"
  VM_DISK_GB="${VM_DISK_GB:-32}"
  VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
  VM_IP="${VM_IP:-}"
  VM_GW="${VM_GW:-}"
  VM_DNS="${VM_DNS:-}"
  VM_DESCRIPTION="${VM_DESCRIPTION:-$SERVICE}"
  KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-3}"
  GUEST_ID="$VM_ID"
}

# @description Print the VM part of the usage text.
guest_usage() {
  cat << EOF
VM (environment):
  VM_IP          static address, CIDR, required for a new VM
  VM_GW          gateway, required for a new VM
  VM_DNS         DNS server                                [host default]
  VM_NAME        VM name, also used to find it again       [$VM_NAME]
  VM_ID          ID for a new VM                           [next free]
  VM_STORAGE     storage for the disk                      [auto]
  VM_CORES       CPU cores                                 [$VM_CORES]
  VM_MEMORY      RAM, MiB                                  [$VM_MEMORY]
  VM_DISK_GB     disk size, GiB                            [$VM_DISK_GB]
  VM_BRIDGE      network bridge                            [$VM_BRIDGE]
  KEEP_SNAPSHOTS update snapshots to keep                  [$KEEP_SNAPSHOTS]
EOF
}

# @description Stop unless the Proxmox VM tools are available.
guest_require_tools() {
  require_commands qm pvesh pvesm
}

# @description Validate the network settings of a new VM.
guest_check_network() {
  [[ -n "$VM_IP" && "$VM_IP" == */* ]] \
    || die "VM_IP is required in CIDR form, e.g. 192.168.11.53/24"
  [[ -n "$VM_GW" ]] || die "VM_GW is required"
  require_free_address "${VM_IP%/*}"
}

# @description Print the ID of the VM with $VM_NAME.
# @stdout VM ID, empty when none.
guest_find() {
  qm list | awk -v name="$VM_NAME" 'NR > 1 && $2 == name { print $1; exit }'
}

# @description Print the VM address without the prefix length.
# @stdout IPv4 address.
guest_address() {
  printf '%s' "${VM_IP%/*}"
}

# @description Print the active storage with the most free space that
#   accepts VM disks.
# @stdout Storage name.
pick_vm_storage() {
  pvesm status --content images --enabled 1 2> /dev/null \
    | awk 'NR > 1 && $3 == "active" { print $6, $1 }' \
    | sort -rn \
    | awk 'NR == 1 { print $2 }'
}

# ---- SSH ----

# @description Create the SSH key this host uses to reach the VM.
ensure_ssh_key() {
  install -d -m 700 "$STATE_DIR"
  [[ -f "$STATE_DIR/id_ed25519" ]] && return 0
  ssh-keygen -q -t ed25519 -N '' -C "pve-$SERVICE@$(hostname)" \
    -f "$STATE_DIR/id_ed25519"
  ok "SSH key for the VM created"
}

# @description Run a command in the VM over SSH as root (through sudo).
# @arg $@ string Remote command.
vm_ssh() {
  ssh -i "$STATE_DIR/id_ed25519" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$STATE_DIR/known_hosts" \
    "$VM_USER@$(guest_address)" sudo "$@"
}

# @description Run the setup script from stdin inside the VM.
guest_exec_script() {
  vm_ssh bash -s
}

# ---- Lifecycle ----

# @description Download the Debian cloud image unless the current one is
#   already there, and verify its SHA-512 checksum.
ensure_image() {
  local sums expected
  install -d "$IMAGE_DIR"
  sums="$(curl -fsSL --retry 3 "$IMAGE_BASE/SHA512SUMS")" \
    || die "cannot download $IMAGE_BASE/SHA512SUMS"
  expected="$(awk -v f="$IMAGE_NAME" '$2 == f { print $1 }' <<< "$sums")"
  [[ -n "$expected" ]] || die "$IMAGE_NAME is not listed in SHA512SUMS"

  if [[ -f "$IMAGE_DIR/$IMAGE_NAME" ]] \
    && sha512sum "$IMAGE_DIR/$IMAGE_NAME" | grep -q "^$expected "; then
    ok "Cloud image already present: $IMAGE_NAME"
    return 0
  fi
  log "Downloading $IMAGE_NAME"
  curl -fL --retry 3 -o "$IMAGE_DIR/$IMAGE_NAME.part" "$IMAGE_BASE/$IMAGE_NAME"
  sha512sum "$IMAGE_DIR/$IMAGE_NAME.part" | grep -q "^$expected " \
    || die "checksum mismatch for $IMAGE_NAME"
  mv -f "$IMAGE_DIR/$IMAGE_NAME.part" "$IMAGE_DIR/$IMAGE_NAME"
  ok "Cloud image downloaded and verified"
}

# @description Create the VM from the cloud image. Extra "qm create"
#   arguments come from service_create_args, one per line.
guest_create() {
  local storage="${VM_STORAGE:-$(pick_vm_storage)}"
  [[ -n "$storage" ]] || die "no storage accepts VM disks (images)"
  ensure_image
  ensure_ssh_key

  GUEST_ID="${VM_ID:-$(pvesh get /cluster/nextid)}"
  local -a extra=()
  mapfile -t extra < <(service_create_args)
  [[ -n "$VM_DNS" ]] && extra+=(--nameserver "$VM_DNS")

  log "Creating VM $GUEST_ID ($VM_NAME) on $storage"
  qm create "$GUEST_ID" \
    --name "$VM_NAME" \
    --description "$VM_DESCRIPTION, managed by pve-$SERVICE.sh" \
    --tags "$SERVICE" \
    --ostype l26 \
    --cpu host \
    --cores "$VM_CORES" \
    --memory "$VM_MEMORY" \
    --scsihw virtio-scsi-single \
    --scsi0 "$storage:0,import-from=$IMAGE_DIR/$IMAGE_NAME,discard=on,iothread=1" \
    --ide2 "$storage:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1 \
    --net0 "virtio,bridge=$VM_BRIDGE" \
    --ciuser "$VM_USER" \
    --sshkeys "$STATE_DIR/id_ed25519.pub" \
    --ipconfig0 "ip=$VM_IP,gw=$VM_GW" \
    --ciupgrade 0 \
    --onboot 1 \
    "${extra[@]}"
  qm resize "$GUEST_ID" scsi0 "${VM_DISK_GB}G"
  # A recreated VM gets new host keys; forget the old ones for this IP.
  ssh-keygen -R "$(guest_address)" -f "$STATE_DIR/known_hosts" \
    > /dev/null 2>&1 || true
  ok "VM $GUEST_ID created"
}

# @description Start the VM unless it is already running. The kvm process
#   outlives the script, so it must not inherit the lock descriptor.
guest_ensure_running() {
  qm status "$GUEST_ID" | grep -q 'running' && return 0
  log "Starting VM $GUEST_ID"
  qm start "$GUEST_ID" 9>&-
}

# @description Reboot the VM when a hook changed its config.
guest_restart_if_needed() {
  [[ "$GUEST_NEEDS_RESTART" == "1" ]] || return 0
  log "Rebooting VM $GUEST_ID to apply the new config"
  qm reboot "$GUEST_ID" 9>&-
  GUEST_NEEDS_RESTART=0
}

# @description Nothing to do for a VM: access is by SSH key only.
guest_after_create() { :; }

# @description Wait until the VM answers SSH and cloud-init is finished.
# @exitcode 1 No SSH within $SSH_TIMEOUT seconds.
guest_wait_ready() {
  local waited=0
  ensure_ssh_key
  log "Waiting for SSH on $(guest_address)"
  until vm_ssh true > /dev/null 2>&1; do
    ((waited += 5))
    ((waited < SSH_TIMEOUT)) || die "no SSH to $(guest_address) after ${SSH_TIMEOUT}s"
    sleep 5
  done
  vm_ssh cloud-init status --wait > /dev/null 2>&1 || true
  ok "VM is reachable"
}

# @description Print the VM part of the summary.
guest_summary() {
  printf 'VM        : %s (%s)\n' "$GUEST_ID" "$VM_NAME"
  printf 'Address   : %s\n' "$(guest_address)"
  printf 'SSH       : ssh -i %s/id_ed25519 %s@%s\n' \
    "$STATE_DIR" "$VM_USER" "$(guest_address)"
}
