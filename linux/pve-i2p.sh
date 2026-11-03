#!/usr/bin/env bash
#
# @file pve-i2p.sh
# @brief Unattended deploy and update of an I2P router (i2pd) in a Proxmox
#   LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing):
#
#   * i2pd from Debian with the SAM bridge (7656), HTTP proxy (4444),
#     SOCKS proxy (4447) and the web console (7070, password protected);
#   * nftables inside the container: SAM and the proxies answer only the
#     clients in I2P_CLIENTS and the containers named in I2P_CLIENT_HOSTS
#     (by default "reticulum"), the console only the networks in
#     I2P_CONSOLE_ALLOW. SAM has no password, so this list is the guard;
#   * transit traffic limited by I2P_BANDWIDTH and I2P_SHARE;
#   * a fixed router port (I2P_PORT, picked once at random), so it can be
#     forwarded on the router later. Nothing is forwarded by this script:
#     without it i2pd works "firewalled", slower but fine;
#   * reseeding through I2P_RESEED_PROXY when reseed servers are blocked,
#     or from a file copied into the container (I2P_RESEED_FILE).
#
#   Run it again after creating a new client container: its address is
#   looked up again and added to the guard.
#
#   How to run:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-i2p.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="i2p"
PERSISTED_SETTINGS=(
  I2P_CLIENTS I2P_CLIENT_HOSTS I2P_CONSOLE_ALLOW I2P_BANDWIDTH I2P_SHARE
  I2P_PORT I2P_RESEED_PROXY I2P_RESEED_FILE
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
I2P_CLIENTS="${I2P_CLIENTS:-}"
I2P_CLIENT_HOSTS="${I2P_CLIENT_HOSTS:-reticulum}"
I2P_CONSOLE_ALLOW="${I2P_CONSOLE_ALLOW:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
I2P_BANDWIDTH="${I2P_BANDWIDTH:-256}"
I2P_SHARE="${I2P_SHARE:-50}"
I2P_PORT="${I2P_PORT:-$((20000 + RANDOM % 20000))}"
I2P_RESEED_PROXY="${I2P_RESEED_PROXY:-}"
I2P_RESEED_FILE="${I2P_RESEED_FILE:-}"
CT_DISK_GB="${CT_DISK_GB:-4}"
CT_MEMORY="${CT_MEMORY:-512}"
CT_DESCRIPTION="I2P router (i2pd)"
ct_defaults

# ---- Hooks ----

service_usage() {
  cat << EOF

I2P (environment, remembered):
  I2P_CLIENTS        IPs allowed to use SAM and the proxies   [${I2P_CLIENTS:-none}]
  I2P_CLIENT_HOSTS   CT hostnames allowed the same way    [$I2P_CLIENT_HOSTS]
  I2P_CONSOLE_ALLOW  networks allowed to open the console [$I2P_CONSOLE_ALLOW]
  I2P_BANDWIDTH      bandwidth limit, KB/s                  [$I2P_BANDWIDTH]
  I2P_SHARE          share of it for transit, %             [$I2P_SHARE]
  I2P_PORT           router port (UDP+TCP) for forwarding   [random, fixed]
  I2P_RESEED_PROXY   proxy for reseeding, e.g. http://host:port      [none]
  I2P_RESEED_FILE    reseed .su3/.zip already in the CT, path        [none]
EOF
}

service_preflight() {
  [[ "$I2P_PORT" =~ ^[0-9]+$ ]] || die "I2P_PORT must be a number"
  ((I2P_PORT > 1024 && I2P_PORT < 65536)) || die "I2P_PORT must be 1025..65535"
  [[ "$I2P_BANDWIDTH" =~ ^[0-9]+$ ]] || die "I2P_BANDWIDTH must be KB/s"
  [[ "$I2P_SHARE" =~ ^[0-9]+$ ]] || die "I2P_SHARE must be a number"
  ((I2P_SHARE <= 100)) || die "I2P_SHARE must be 0..100"
}

# @description Print the allowed client IPs: I2P_CLIENTS plus the running
#   containers named in I2P_CLIENT_HOSTS.
# @stdout Space separated IPv4 addresses.
client_addresses() {
  local name id ip
  # Word splitting is intended: one address per word.
  # shellcheck disable=SC2086
  printf '%s ' $I2P_CLIENTS
  for name in $I2P_CLIENT_HOSTS; do
    id="$(find_ct_by_hostname "$name")"
    [[ -n "$id" ]] || { warn "No container '$name' yet, run me again later"; continue; }
    ip="$(ct_address_of "$id")"
    [[ -n "$ip" ]] || { warn "Container '$name' has no address (stopped?)"; continue; }
    printf '%s ' "$ip"
  done
}

service_exports() {
  export_var I2P_ALLOWED "$(client_addresses)"
  export_var I2P_CONSOLE_ALLOW "$I2P_CONSOLE_ALLOW"
  export_var I2P_BANDWIDTH "$I2P_BANDWIDTH"
  export_var I2P_SHARE "$I2P_SHARE"
  export_var I2P_PORT "$I2P_PORT"
  export_var I2P_RESEED_PROXY "$I2P_RESEED_PROXY"
  export_var I2P_RESEED_FILE "$I2P_RESEED_FILE"
  export_var CONSOLE_PASSWORD "$(secret_or_new console-password)"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'SAM       : %s:7656  (for Reticulum: I2P_SAM_ADDRESS)\n' "$ip"
  printf 'Proxies   : http://%s:4444  socks5://%s:4447\n' "$ip" "$ip"
  printf 'Console   : http://%s:7070  (user admin)\n' "$ip"
  printf 'Password  : cat %s/console-password\n' "$STATE_DIR"
  printf 'Router    : port %s UDP+TCP (forward it for better speed)\n' "$I2P_PORT"
  printf 'Allowed   : %s\n' "$(client_addresses 2> /dev/null)"
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
# Prints an nftables set body from space separated words, "" when empty.
nft_set() {
  local words
  # shellcheck disable=SC2086 # one element per word
  words="$(printf '%s\n' $1 | paste -sd, -)"
  printf '%s' "${words//,/, }"
}

write_i2pd_config() {
  local reseed=""
  [[ -z "$I2P_RESEED_PROXY" ]] || reseed+="proxy = $I2P_RESEED_PROXY"$'\n'
  [[ -z "$I2P_RESEED_FILE" ]] || reseed+="file = $I2P_RESEED_FILE"$'\n'
  write_file /etc/i2pd/i2pd.conf 640 root:i2pd << EOF
# Managed by pve-i2p.sh, rewritten on every run.
loglevel = warn
ipv4 = true
ipv6 = false
port = $I2P_PORT
bandwidth = $I2P_BANDWIDTH
share = $I2P_SHARE

[ntcp2]
enabled = true

[ssu2]
enabled = true

[http]
enabled = true
address = 0.0.0.0
port = 7070
auth = true
user = admin
pass = $CONSOLE_PASSWORD
strictheaders = false

[httpproxy]
enabled = true
address = 0.0.0.0
port = 4444

[socksproxy]
enabled = true
address = 0.0.0.0
port = 4447

[sam]
enabled = true
address = 0.0.0.0
port = 7656

[reseed]
verify = true
$reseed
[limits]
transittunnels = 2000
EOF
}

write_guard() {
  local clients console
  clients="$(nft_set "$I2P_ALLOWED")"
  console="$(nft_set "$I2P_CONSOLE_ALLOW")"
  {
    printf '#!/usr/sbin/nft -f\n# Managed by pve-i2p.sh, rewritten on every run.\n'
    printf 'flush ruleset\n\ntable inet i2p_guard {\n  chain input {\n'
    printf '    type filter hook input priority 0; policy accept;\n'
    printf '    iif "lo" accept\n'
    # SAM streams (7656) and datagrams (7655), HTTP and SOCKS proxies.
    [[ -z "$clients" ]] \
      || printf '    meta l4proto { tcp, udp } th dport { 7655, 7656, 4444, 4447 } ip saddr { %s } accept\n' "$clients"
    printf '    meta l4proto { tcp, udp } th dport { 7655, 7656, 4444, 4447 } drop\n'
    [[ -z "$console" ]] \
      || printf '    tcp dport 7070 ip saddr { %s } accept\n' "$console"
    printf '    tcp dport 7070 drop\n  }\n}\n'
  } | write_file /etc/nftables.conf 755
  if nft -c -f /etc/nftables.conf && systemctl enable --now nftables > /dev/null 2>&1 \
    && systemctl restart nftables; then
    ok "Guard active: SAM and proxies for [${clients:-nobody}]"
  else
    warn "nftables could not be loaded; SAM is open to the whole network!"
  fi
}

main() {
  upgrade_os
  apt_install i2pd nftables
  write_i2pd_config
  write_guard
  systemctl enable i2pd > /dev/null 2>&1
  systemctl restart i2pd
  sleep 3
  log "i2pd: $(systemctl is-active i2pd), version $(i2pd --version 2> /dev/null | head -n 1)"
}
SCRIPT
}

guest_main "$@"
