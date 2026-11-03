#!/usr/bin/env bash
#
# @file pve-dns.sh
# @brief Unattended deploy and update of a recursive DNS resolver (Unbound)
#   with home names in a Proxmox LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing):
#
#   * Unbound as a validating recursive resolver: it asks the root servers
#     itself, without Yandex, Google or the provider;
#   * a local zone (DNS_ZONE, "lan" by default) with the host, every
#     running container and every VM with the guest agent, found
#     automatically on each run, plus DNS_HOSTS given by hand;
#   * stale answers are served for up to a week when upstream is gone;
#   * a fallback watchdog: every 2 minutes it checks three root servers;
#     when none answers (an isolated national network), Unbound forwards to
#     DNS_FALLBACK (the router by default) with relaxed DNSSEC, and goes
#     back to recursion when the roots answer again.
#
#   Only networks in DNS_ALLOW may query. The router keeps handing out its
#   own DNS: Podkop on OpenWrt relies on it, so point clients or the router
#   here only after checking that Podkop still works.
#
#   How to run:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-dns.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="dns"
PERSISTED_SETTINGS=(DNS_ZONE DNS_HOSTS DNS_ALLOW DNS_FALLBACK DNS_AUTO_HOSTS)

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
DNS_ZONE="${DNS_ZONE:-lan}"
DNS_HOSTS="${DNS_HOSTS:-}"
DNS_ALLOW="${DNS_ALLOW:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
DNS_FALLBACK="${DNS_FALLBACK:-$(ip -4 route show default | awk '{ print $3; exit }')}"
DNS_AUTO_HOSTS="${DNS_AUTO_HOSTS:-1}"
CT_DISK_GB="${CT_DISK_GB:-4}"
CT_MEMORY="${CT_MEMORY:-256}"
CT_DESCRIPTION="Unbound recursive DNS with home names"
ct_defaults

# ---- Hooks ----

service_usage() {
  cat << EOF

DNS (environment, remembered):
  DNS_ZONE        local zone for home names              [$DNS_ZONE]
  DNS_HOSTS       extra names, "name=ip" words              [${DNS_HOSTS:-none}]
  DNS_ALLOW       networks allowed to query              [$DNS_ALLOW]
  DNS_FALLBACK    resolvers used when the roots are unreachable
                                                         [$DNS_FALLBACK]
  DNS_AUTO_HOSTS  1 = add the host, containers and VMs   [$DNS_AUTO_HOSTS]
EOF
}

service_preflight() {
  [[ "$DNS_ZONE" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)*$ ]] || die "bad DNS_ZONE '$DNS_ZONE'"
  [[ -n "$DNS_FALLBACK" ]] || die "DNS_FALLBACK is empty and no default route found"
  local pair
  for pair in $DNS_HOSTS; do
    [[ "$pair" =~ ^[a-z0-9-]+=[0-9.]+$ ]] || die "DNS_HOSTS entry must be name=ip: $pair"
  done
}

# @description Print the first IPv4 address of a VM from its guest agent.
# @arg $1 int VM ID.
# @stdout Address, empty when the agent does not answer.
vm_address_of() {
  qm guest cmd "$1" network-get-interfaces 2> /dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for iface in data:
    if iface.get("name") == "lo":
        continue
    for addr in iface.get("ip-addresses", []):
        if addr.get("ip-address-type") == "ipv4":
            print(addr["ip-address"])
            sys.exit(0)
' || true
}

# @description Print "name=ip" words for the host, the running containers
#   and the running VMs with a guest agent.
# @stdout Space separated pairs.
auto_hosts() {
  [[ "$DNS_AUTO_HOSTS" == "1" ]] || return 0
  local id name ip
  ip="$(host_address)"
  [[ -z "$ip" ]] || printf '%s=%s ' "$(hostname -s)" "$ip"
  while read -r id name; do
    ip="$(ct_address_of "$id")"
    [[ -z "$ip" ]] || printf '%s=%s ' "$name" "$ip"
  done < <(pct list | awk 'NR > 1 && $2 == "running" { print $1, $NF }')
  while read -r id name; do
    ip="$(vm_address_of "$id")"
    [[ -z "$ip" ]] || printf '%s=%s ' "$name" "$ip"
  done < <(qm list 2> /dev/null | awk 'NR > 1 && $3 == "running" { print $1, $2 }')
}

service_exports() {
  export_var DNS_ZONE "$DNS_ZONE"
  export_var DNS_RECORDS "$(auto_hosts) $DNS_HOSTS"
  export_var DNS_ALLOW "$DNS_ALLOW"
  export_var DNS_FALLBACK "$DNS_FALLBACK"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'Resolver  : %s:53  (test: dig @%s pve.%s)\n' "$ip" "$ip" "$DNS_ZONE"
  printf 'Fallback  : %s, when the root servers are unreachable\n' "$DNS_FALLBACK"
  printf 'Note      : check Podkop before pointing the router here\n'
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
CONF_DIR=/etc/unbound/unbound.conf.d
FALLBACK_CONF=$CONF_DIR/zz-pve-dns-fallback.conf

write_unbound_config() {
  local net pair name
  # One address per name, the last one wins (hand-made DNS_HOSTS come last).
  local -A records=()
  for pair in $DNS_RECORDS; do
    records["${pair%%=*}"]="${pair#*=}"
  done
  {
    printf '# Managed by pve-dns.sh, rewritten on every run.\nserver:\n'
    printf '  interface: 0.0.0.0\n  port: 53\n  do-ip6: no\n'
    printf '  access-control: 127.0.0.0/8 allow\n'
    for net in $DNS_ALLOW; do
      printf '  access-control: %s allow\n' "$net"
    done
    printf '  hide-identity: yes\n  hide-version: yes\n'
    printf '  qname-minimisation: yes\n  prefetch: yes\n'
    printf '  serve-expired: yes\n  serve-expired-ttl: 604800\n'
    printf '  private-domain: "%s"\n' "$DNS_ZONE"
    printf '  local-zone: "%s." static\n' "$DNS_ZONE"
    for name in "${!records[@]}"; do
      printf '  local-data: "%s.%s. 300 IN A %s"\n' "$name" "$DNS_ZONE" "${records[$name]}"
      printf '  local-data-ptr: "%s %s.%s"\n' "${records[$name]}" "$name" "$DNS_ZONE"
    done
  } | write_file "$CONF_DIR/pve-dns.conf" 644
}

write_watchdog() {
  write_file /usr/local/sbin/dns-fallback-check 755 << EOF
#!/bin/sh
# Managed by pve-dns.sh: forward to the fallback resolvers while no root
# server answers, recurse again when one does.
set -u
FALLBACK_CONF=$FALLBACK_CONF
roots_answer() {
  for root in 198.41.0.4 193.0.14.129 199.7.83.42; do
    dig +time=3 +tries=1 +norecurse @\$root . SOA > /dev/null 2>&1 && return 0
  done
  return 1
}
if roots_answer; then
  [ -f "\$FALLBACK_CONF" ] || exit 0
  rm -f "\$FALLBACK_CONF"
  logger -t dns-fallback "root servers answer again, back to recursion"
else
  [ -f "\$FALLBACK_CONF" ] && exit 0
  {
    printf 'server:\n  val-permissive-mode: yes\n'
    printf 'forward-zone:\n  name: "."\n'
    for addr in $DNS_FALLBACK; do printf '  forward-addr: %s\n' "\$addr"; done
  } > "\$FALLBACK_CONF"
  logger -t dns-fallback "no root server answers, forwarding to $DNS_FALLBACK"
fi
unbound-checkconf > /dev/null && systemctl restart unbound
EOF
  write_file /etc/systemd/system/dns-fallback-check.service 644 << 'EOF'
[Unit]
Description=Switch Unbound between recursion and fallback forwarding

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dns-fallback-check
EOF
  write_file /etc/systemd/system/dns-fallback-check.timer 644 << 'EOF'
[Unit]
Description=Check the DNS root servers every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
}

main() {
  upgrade_os
  apt_install unbound dnsutils
  write_unbound_config
  write_watchdog
  # The trust anchor normally appears on the first start; checkconf needs it.
  [[ -f /var/lib/unbound/root.key ]] \
    || /usr/libexec/unbound-helper root_trust_anchor_update || true
  unbound-checkconf > /dev/null
  systemctl daemon-reload
  systemctl enable unbound dns-fallback-check.timer > /dev/null 2>&1
  systemctl restart unbound
  systemctl start dns-fallback-check.timer
  /usr/local/sbin/dns-fallback-check || true
  sleep 1
  log "Unbound: $(systemctl is-active unbound), $(grep -c 'IN A' "$CONF_DIR/pve-dns.conf") home names"
  log "Test: $(dig +short @127.0.0.1 deb.debian.org A | tail -n 1)"
}
SCRIPT
}

guest_main "$@"
