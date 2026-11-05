#!/usr/bin/env bash
#
# @file pve-smarthome.sh
# @brief Unattended deploy and update of Home Assistant (Container
#   installation) in a Proxmox VM.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. Creates a
#   Debian 13 VM from the cloud image (see lib/pve-vm.sh) and runs the
#   official Home Assistant container in Docker there, with host networking
#   and the config in /srv/homeassistant. A VM rather than an LXC container,
#   because Docker inside LXC breaks on some updates.
#
#   This is the "Container" installation: there is no add-on store. Brokers
#   and bridges run as their own guests instead (MQTT: pve-mqtt.sh, login
#   "homeassistant" reads everything).
#
#   Running it again snapshots the VM, upgrades Debian, pulls the image
#   (HA_VERSION, "stable" by default) and restarts Home Assistant only when
#   the image changed. Create the owner account in the browser yourself.
#
#   The image comes from ghcr.io; if pulling stalls, that host may need to
#   go through your proxy.
#
#   How to run:
#     VM_IP=192.168.11.53/24 VM_GW=192.168.11.1 bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-smarthome.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="smarthome"
PERSISTED_SETTINGS=(VM_IP VM_GW VM_DNS HA_VERSION HA_TZ)

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

pve_source pve-vm.sh

# ---- Settings (environment > saved > default) ----

guest_load_settings
HA_VERSION="${HA_VERSION:-stable}"
HA_TZ="${HA_TZ:-$(timedatectl show -p Timezone --value 2> /dev/null || echo UTC)}"
VM_NAME="${VM_NAME:-smarthome}"
VM_CORES="${VM_CORES:-2}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_DISK_GB="${VM_DISK_GB:-32}"
VM_DESCRIPTION="Home Assistant (Container) in Docker"
vm_defaults

# ---- Hooks ----

service_usage() {
  cat << EOF

Home Assistant (environment, remembered):
  HA_VERSION  image tag: stable, beta or a version like 2026.10.1  [$HA_VERSION]
  HA_TZ       time zone                                 [$HA_TZ]
EOF
}

service_preflight() {
  [[ "$HA_VERSION" =~ ^[a-z0-9.]+$ ]] || die "bad HA_VERSION '$HA_VERSION'"
  [[ -z "$EXISTING_ID" && -z "$VM_IP" ]] && die "VM_IP is required for a new VM"
  return 0
}

service_exports() {
  export_var HA_VERSION "$HA_VERSION"
  export_var HA_TZ "$HA_TZ"
}

service_summary() {
  printf 'Web       : http://%s:8123  (create the owner account there)\n' \
    "$(guest_address)"
  printf 'Config    : /srv/homeassistant in the VM\n'
  printf 'MQTT      : login "homeassistant" from pve-mqtt.sh (read-only)\n'
}

# ---- Inside the VM ----

service_script() {
  cat << 'SCRIPT'
IMAGE="ghcr.io/home-assistant/home-assistant"
CONFIG=/srv/homeassistant

write_unit() {
  write_file /etc/systemd/system/homeassistant.service 644 << EOF
# Managed by pve-smarthome.sh, rewritten on every run.
[Unit]
Description=Home Assistant (container)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
ExecStartPre=-/usr/bin/docker rm -f homeassistant
ExecStart=/usr/bin/docker run --rm --name homeassistant --privileged \\
  --network host -e TZ=$HA_TZ \\
  -v $CONFIG:/config -v /run/dbus:/run/dbus:ro \\
  $IMAGE:$HA_VERSION
ExecStop=/usr/bin/docker stop homeassistant
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable homeassistant > /dev/null 2>&1
}

# Pulls the image; restarts Home Assistant only when the image changed or
# it is not running.
update_and_start() {
  local before after
  before="$(docker image inspect -f '{{.Id}}' "$IMAGE:$HA_VERSION" 2> /dev/null || true)"
  log "Pulling $IMAGE:$HA_VERSION"
  docker pull -q "$IMAGE:$HA_VERSION" > /dev/null
  after="$(docker image inspect -f '{{.Id}}' "$IMAGE:$HA_VERSION")"
  if [[ "$before" != "$after" ]] || ! systemctl is-active -q homeassistant; then
    systemctl restart homeassistant
    ok "Home Assistant (re)started on the new image"
  else
    ok "Home Assistant image is current"
  fi
  docker image prune -f > /dev/null
}

wait_for_web() {
  for _ in $(seq 1 90); do
    curl -fsS -o /dev/null http://127.0.0.1:8123/manifest.json 2> /dev/null && return 0
    sleep 2
  done
  warn "Home Assistant does not answer yet; first start can take a few minutes"
}

main() {
  upgrade_os
  apt_install docker.io qemu-guest-agent curl
  systemctl enable --now docker qemu-guest-agent > /dev/null 2>&1
  install -d -m 755 "$CONFIG"
  write_unit
  update_and_start
  wait_for_web
  log "Home Assistant: $(systemctl is-active homeassistant)"
}
SCRIPT
}

guest_main "$@"
