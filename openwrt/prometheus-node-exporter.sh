#!/bin/sh
#
# @file prometheus-node-exporter.sh
# @brief Install or update prometheus-node-exporter-lua on OpenWrt.
# @description
#   Unattended and idempotent, for the whole router fleet:
#
#   * works with both package managers: apk (OpenWrt 25+) and opkg;
#   * installs the Lua node exporter with the OpenWrt, Wi-Fi, Wi-Fi
#     stations, netstat and NAT traffic collectors, or upgrades them when
#     they are already there;
#   * makes it listen on the LAN interface only (port 9100, no IPv6), so
#     Prometheus in the LAN can scrape it and the WAN side cannot;
#   * checks that the metrics endpoint answers.
#
#   Everything goes to the router's own overlay; external storage such as
#   a USB flash drive is not used, so routers without one are fine.
#
#   Run on the router:
#     sh prometheus-node-exporter.sh
#   or from another Linux machine in the LAN:
#     curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/openwrt/prometheus-node-exporter.sh | ssh root@192.168.11.1 sh -s
#
#   Settings (environment):
#     EXPORTER_INTERFACE  OpenWrt interface to listen on   [lan]
#     EXPORTER_PORT       TCP port                         [9100]

set -eu

EXPORTER_INTERFACE="${EXPORTER_INTERFACE:-lan}"
EXPORTER_PORT="${EXPORTER_PORT:-9100}"
SERVICE="prometheus-node-exporter-lua"
PACKAGES="prometheus-node-exporter-lua
prometheus-node-exporter-lua-openwrt
prometheus-node-exporter-lua-wifi
prometheus-node-exporter-lua-wifi_stations
prometheus-node-exporter-lua-netstat
prometheus-node-exporter-lua-nat_traffic"
# Free overlay space below this many KiB only produces a warning.
MIN_FREE_KIB=1024

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

# ---- Guards ----

# @description Stop unless running on OpenWrt as root.
require_openwrt() {
  [ "$(id -u)" -eq 0 ] || die "run me as root"
  [ -f /etc/openwrt_release ] || die "this is not OpenWrt"
  command -v uci > /dev/null || die "uci not found"
}

# @description Warn when the overlay is almost full; package installation
#   may still fit, so this is not fatal.
check_overlay_space() {
  free_kib="$(df -k /overlay 2> /dev/null | awk 'NR == 2 { print $4 }')"
  [ -n "$free_kib" ] || return 0
  [ "$free_kib" -ge "$MIN_FREE_KIB" ] && return 0
  warn "only ${free_kib} KiB free on /overlay, installation may fail"
}

# ---- Package manager ----

# @description Print the package manager of this router: apk or opkg.
# @stdout apk or opkg.
package_manager() {
  if command -v apk > /dev/null; then
    echo apk
    return 0
  fi
  command -v opkg > /dev/null || die "neither apk nor opkg found"
  echo opkg
}

# @description Install the packages, or upgrade them when present.
# @arg $1 string Package manager (apk or opkg).
install_packages() {
  # Word splitting of $PACKAGES is intended: one package per word.
  # shellcheck disable=SC2086
  case "$1" in
    apk)
      apk update > /dev/null
      apk add --upgrade $PACKAGES > /dev/null
      ;;
    opkg)
      opkg update > /dev/null
      opkg install $PACKAGES > /dev/null
      opkg upgrade $PACKAGES > /dev/null 2>&1 || true
      ;;
  esac
  ok "Packages installed or up to date ($1)"
}

# ---- Configuration ----

# @description Stop unless $EXPORTER_INTERFACE exists, before installing
#   anything.
require_interface() {
  uci -q get "network.$EXPORTER_INTERFACE" > /dev/null && return 0
  die "no interface '$EXPORTER_INTERFACE' in /etc/config/network"
}

# @description Make the exporter listen on $EXPORTER_INTERFACE:$EXPORTER_PORT.
configure_exporter() {
  uci set "$SERVICE.main.listen_interface=$EXPORTER_INTERFACE"
  uci set "$SERVICE.main.listen_port=$EXPORTER_PORT"
  uci set "$SERVICE.main.listen_ipv6=0"
  uci commit "$SERVICE"
  "/etc/init.d/$SERVICE" enable
  "/etc/init.d/$SERVICE" restart
  ok "Exporter listens on '$EXPORTER_INTERFACE', port $EXPORTER_PORT"
}

# @description Print the IPv4 address of $EXPORTER_INTERFACE.
# @stdout Address without the prefix length.
interface_address() {
  # ipaddr can be "192.168.1.1", "192.168.1.1/24" or a list; take the first.
  uci -q get "network.$EXPORTER_INTERFACE.ipaddr" \
    | awk '{ split($1, a, "/"); print a[1] }'
}

# @description Check that the metrics endpoint answers.
# @exitcode 1 No metrics within 10 seconds.
check_endpoint() {
  address="$(interface_address)"
  [ -n "$address" ] || die "no IPv4 address on '$EXPORTER_INTERFACE'"
  url="http://$address:$EXPORTER_PORT/metrics"
  for _ in 1 2 3 4 5; do
    if wget -q -O - "$url" 2> /dev/null | grep -q '^node_load1'; then
      ok "Metrics available at $url"
      return 0
    fi
    sleep 2
  done
  die "$url does not answer"
}

# ---- Main ----

# @description Entry point.
main() {
  require_openwrt
  require_interface
  check_overlay_space
  install_packages "$(package_manager)"
  configure_exporter
  check_endpoint
}

main "$@"
