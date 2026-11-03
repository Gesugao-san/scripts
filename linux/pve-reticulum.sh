#!/usr/bin/env bash
#
# @file pve-reticulum.sh
# @brief Unattended deploy and update of a Reticulum transport node with an
#   LXMF propagation node in a Proxmox LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing):
#
#   * rnsd (Reticulum, from PyPI in /opt/reticulum) as a transport node:
#     routes between all its interfaces;
#   * interfaces: AutoInterface (LAN discovery, e.g. Sideband on phones in
#     the home Wi-Fi), a TCP server on RNS_TCP_PORT for other nodes and
#     clients, I2P through the SAM bridge of the "$I2P_HOSTNAME" container
#     when it exists (see pve-i2p.sh), and an RNode LoRa radio when
#     RNODE_DEVICE is set;
#   * lxmd as an LXMF propagation node: messages for peers that are offline
#     wait here and are delivered when they come back.
#
#   RNODE_DEVICE is a USB serial device of the host, best given by its
#   stable name: /dev/serial/by-id/usb-... It is passed into the container
#   (the container restarts once when that changes). The radio settings
#   default to 869.1 MHz, 125 kHz, 14 dBm (25 mW): check the rules of your
#   country before transmitting.
#
#   Identities live in /var/lib/reticulum/storage and /var/lib/lxmd inside
#   the container and survive updates.
#
#   How to run:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-reticulum.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="reticulum"
PERSISTED_SETTINGS=(
  RNS_TCP_PORT RNS_NODE_NAME RNS_I2P_PEERS I2P_HOSTNAME RNODE_DEVICE
  RNODE_FREQUENCY RNODE_BANDWIDTH RNODE_TXPOWER RNODE_SF RNODE_CR
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
RNS_TCP_PORT="${RNS_TCP_PORT:-4242}"
RNS_NODE_NAME="${RNS_NODE_NAME:-Home node}"
RNS_I2P_PEERS="${RNS_I2P_PEERS:-}"
I2P_HOSTNAME="${I2P_HOSTNAME:-i2p}"
RNODE_DEVICE="${RNODE_DEVICE:-}"
RNODE_FREQUENCY="${RNODE_FREQUENCY:-869100000}"
RNODE_BANDWIDTH="${RNODE_BANDWIDTH:-125000}"
RNODE_TXPOWER="${RNODE_TXPOWER:-14}"
RNODE_SF="${RNODE_SF:-8}"
RNODE_CR="${RNODE_CR:-5}"
CT_DISK_GB="${CT_DISK_GB:-8}"
CT_MEMORY="${CT_MEMORY:-512}"
CT_DESCRIPTION="Reticulum transport node and LXMF propagation node"
ct_defaults

# ---- Hooks ----

service_usage() {
  cat << EOF

Reticulum (environment, remembered):
  RNS_TCP_PORT     TCP server port for nodes and clients   [$RNS_TCP_PORT]
  RNS_NODE_NAME    name of the LXMF propagation node       [$RNS_NODE_NAME]
  RNS_I2P_PEERS    I2P b32 addresses of nodes to connect      [none]
  I2P_HOSTNAME     container with the SAM bridge           [$I2P_HOSTNAME]
  RNODE_DEVICE     USB serial of an RNode, /dev/serial/by-id/... [none]
  RNODE_FREQUENCY  Hz                                      [$RNODE_FREQUENCY]
  RNODE_BANDWIDTH  Hz                                      [$RNODE_BANDWIDTH]
  RNODE_TXPOWER    dBm                                     [$RNODE_TXPOWER]
  RNODE_SF         spreading factor                        [$RNODE_SF]
  RNODE_CR         coding rate                             [$RNODE_CR]
EOF
}

service_preflight() {
  [[ -z "$RNODE_DEVICE" || -c "$RNODE_DEVICE" ]] \
    || die "RNODE_DEVICE '$RNODE_DEVICE' is not a character device on this host"
  [[ "$RNS_NODE_NAME" =~ ^[[:print:]]+$ && "$RNS_NODE_NAME" != *[][]* ]] \
    || die "RNS_NODE_NAME must be one printable line without brackets"
}

# @description Pass the RNode through to the container when one is set.
service_host_setup() {
  [[ -n "$RNODE_DEVICE" && -n "$GUEST_ID" ]] || return 0
  pct status "$GUEST_ID" > /dev/null 2>&1 || return 0
  ct_set_option dev0 "path=$RNODE_DEVICE,mode=0666"
}

# @description The device can only be passed once the container exists.
service_after_create() {
  service_host_setup
}

# @description Print "ip:7656" of the SAM bridge, empty when there is none.
# @stdout SAM address.
sam_address() {
  local id ip
  id="$(find_ct_by_hostname "$I2P_HOSTNAME")"
  [[ -n "$id" ]] || return 0
  ip="$(ct_address_of "$id")"
  [[ -n "$ip" ]] || return 0
  printf '%s:7656' "$ip"
}

service_exports() {
  local sam
  sam="$(sam_address)"
  [[ -n "$sam" ]] \
    || warn "No running '$I2P_HOSTNAME' container: I2P interface disabled"
  export_var I2P_SAM "$sam"
  export_var RNS_TCP_PORT "$RNS_TCP_PORT"
  export_var RNS_NODE_NAME "$RNS_NODE_NAME"
  export_var RNS_I2P_PEERS "$RNS_I2P_PEERS"
  export_var RNODE_DEVICE "$RNODE_DEVICE"
  export_var RNODE_FREQUENCY "$RNODE_FREQUENCY"
  export_var RNODE_BANDWIDTH "$RNODE_BANDWIDTH"
  export_var RNODE_TXPOWER "$RNODE_TXPOWER"
  export_var RNODE_SF "$RNODE_SF"
  export_var RNODE_CR "$RNODE_CR"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'TCP       : %s:%s  (TCPClientInterface target for others)\n' \
    "$ip" "$RNS_TCP_PORT"
  printf 'Status    : pct exec %s -- rnstatus\n' "$GUEST_ID"
  printf 'LXMF node : pct exec %s -- lxmd-status  (hash for Sideband)\n' "$GUEST_ID"
  [[ -n "$(sam_address)" ]] || return 0
  printf 'I2P       : allow this CT in pve-i2p.sh (default: by hostname)\n'
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
VENV=/opt/reticulum
RNS_DIR=/var/lib/reticulum
LXMD_DIR=/var/lib/lxmd

setup_python() {
  apt_install python3-venv python3-dev build-essential
  [[ -x "$VENV/bin/pip" ]] || python3 -m venv "$VENV"
  log "Installing or upgrading rns and lxmf from PyPI"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet --upgrade rns lxmf
  ok "rns $("$VENV/bin/pip" show rns | awk '/^Version/ { print $2 }'), lxmf $("$VENV/bin/pip" show lxmf | awk '/^Version/ { print $2 }')"
}

setup_user() {
  id reticulum > /dev/null 2>&1 \
    || useradd --system --home-dir "$RNS_DIR" --shell /usr/sbin/nologin reticulum
  usermod -a -G dialout reticulum
  install -d -m 750 -o reticulum -g reticulum "$RNS_DIR" "$LXMD_DIR"
}

# Prints the I2P interface section, nothing without a SAM bridge.
i2p_interface() {
  [[ -n "$I2P_SAM" ]] || return 0
  printf '  [[I2P]]\n    type = I2PInterface\n    enabled = yes\n    connectable = yes\n'
  [[ -z "$RNS_I2P_PEERS" ]] || printf '    peers = %s\n' "${RNS_I2P_PEERS// /, }"
}

# Prints the RNode section, nothing without a device.
rnode_interface() {
  [[ -n "$RNODE_DEVICE" ]] || return 0
  cat << EOF
  [[RNode LoRa]]
    type = RNodeInterface
    enabled = yes
    port = $RNODE_DEVICE
    frequency = $RNODE_FREQUENCY
    bandwidth = $RNODE_BANDWIDTH
    txpower = $RNODE_TXPOWER
    spreadingfactor = $RNODE_SF
    codingrate = $RNODE_CR
EOF
}

write_configs() {
  {
    cat << EOF
# Managed by pve-reticulum.sh, rewritten on every run.
[reticulum]
  enable_transport = yes
  share_instance = yes
  panic_on_interface_error = no

[logging]
  loglevel = 4

[interfaces]
  [[Default Interface]]
    type = AutoInterface
    enabled = yes
  [[TCP Server]]
    type = TCPServerInterface
    enabled = yes
    listen_ip = 0.0.0.0
    listen_port = $RNS_TCP_PORT
EOF
    i2p_interface
    rnode_interface
  } | write_file "$RNS_DIR/config" 640 reticulum:reticulum

  write_file "$LXMD_DIR/config" 640 reticulum:reticulum << EOF
# Managed by pve-reticulum.sh, rewritten on every run.
[propagation]
  enable_node = yes
  node_name = $RNS_NODE_NAME
  announce_interval = 360
  autopeer = yes
  autopeer_maxdepth = 6

[lxmf]
  display_name = $RNS_NODE_NAME
  announce_at_start = yes

[logging]
  loglevel = 4
EOF
}

write_units() {
  local sam_env=""
  [[ -z "$I2P_SAM" ]] || sam_env="Environment=I2P_SAM_ADDRESS=$I2P_SAM"
  write_file /etc/systemd/system/rnsd.service 644 << EOF
# Managed by pve-reticulum.sh, rewritten on every run.
[Unit]
Description=Reticulum Network Stack daemon
After=network-online.target
Wants=network-online.target

[Service]
User=reticulum
$sam_env
ExecStart=$VENV/bin/rnsd --config $RNS_DIR --service
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  write_file /etc/systemd/system/lxmd.service 644 << EOF
# Managed by pve-reticulum.sh, rewritten on every run.
[Unit]
Description=LXMF propagation node
After=rnsd.service
Requires=rnsd.service

[Service]
User=reticulum
ExecStartPre=/bin/sleep 5
ExecStart=$VENV/bin/lxmd --config $LXMD_DIR --rnsconfig $RNS_DIR --propagation-node --service
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  # Handy commands for root, pointed at the shared instance.
  local tool
  for tool in rnstatus rnpath rnprobe rnid; do
    printf '#!/bin/sh\nexec runuser -u reticulum -- %s/bin/%s --config %s "$@"\n' \
      "$VENV" "$tool" "$RNS_DIR" | write_file "/usr/local/bin/$tool" 755
  done
  printf '#!/bin/sh\nexec runuser -u reticulum -- %s/bin/lxmd --config %s --rnsconfig %s --status "$@"\n' \
    "$VENV" "$LXMD_DIR" "$RNS_DIR" | write_file /usr/local/bin/lxmd-status 755
}

main() {
  upgrade_os
  setup_python
  setup_user
  write_configs
  write_units
  systemctl daemon-reload
  systemctl enable rnsd lxmd > /dev/null 2>&1
  systemctl restart rnsd
  systemctl restart lxmd
  sleep 8
  log "Services: $(systemctl is-active rnsd lxmd | tr '\n' ' ')"
  rnstatus 2> /dev/null | head -n 20 || warn "rnstatus gave no answer yet"
}
SCRIPT
}

guest_main "$@"
