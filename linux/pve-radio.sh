#!/usr/bin/env bash
#
# @file pve-radio.sh
# @brief Unattended deploy and update of an internet radio (Icecast +
#   Liquidsoap) in a Proxmox LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing):
#
#   * Icecast on port 8000 with generated passwords;
#   * Liquidsoap playing /srv/radio/music in random order (new files are
#     picked up on the fly; silence while the folder is empty) as one
#     channel in two formats: MP3 (/radio.mp3) for players and games, and
#     Ogg Vorbis (/radio.ogg);
#   * CORS allowed, so a web page on another host can embed the stream.
#
#   Copy music in with, for example:
#     pct push <id> song.mp3 /srv/radio/music/song.mp3
#   The DFPWM stream for CC:Tweaked speakers in Minecraft is a later step.
#
#   How to run:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-radio.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="radio"
PERSISTED_SETTINGS=(RADIO_NAME RADIO_BITRATE)

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
RADIO_NAME="${RADIO_NAME:-Home radio}"
RADIO_BITRATE="${RADIO_BITRATE:-128}"
CT_DISK_GB="${CT_DISK_GB:-16}"
CT_MEMORY="${CT_MEMORY:-512}"
CT_DESCRIPTION="Internet radio (Icecast + Liquidsoap)"
ct_defaults

# ---- Hooks ----

service_usage() {
  cat << EOF

Radio (environment, remembered):
  RADIO_NAME     station name shown to listeners      [$RADIO_NAME]
  RADIO_BITRATE  MP3 bitrate, kbit/s                  [$RADIO_BITRATE]
EOF
}

service_preflight() {
  [[ "$RADIO_BITRATE" =~ ^(64|96|128|160|192|256|320)$ ]] \
    || die "RADIO_BITRATE must be one of 64 96 128 160 192 256 320"
  [[ "$RADIO_NAME" =~ ^[^\"\<\>\&]+$ ]] \
    || die "RADIO_NAME must not contain quotes, < > or &"
}

service_exports() {
  export_var RADIO_NAME "$RADIO_NAME"
  export_var RADIO_BITRATE "$RADIO_BITRATE"
  export_var SOURCE_PASSWORD "$(secret_or_new source-password)"
  export_var RELAY_PASSWORD "$(secret_or_new relay-password)"
  export_var ADMIN_PASSWORD "$(secret_or_new admin-password)"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'MP3       : http://%s:8000/radio.mp3\n' "$ip"
  printf 'Ogg       : http://%s:8000/radio.ogg\n' "$ip"
  printf 'Admin     : http://%s:8000/admin/  (user admin)\n' "$ip"
  printf 'Password  : cat %s/admin-password\n' "$STATE_DIR"
  printf 'Music     : pct push %s <file> /srv/radio/music/<file>\n' "$GUEST_ID"
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
MUSIC=/srv/radio/music

setup_icecast() {
  # Skip the package's own questions; the config is written below.
  echo 'icecast2 icecast2/icecast-setup boolean false' | debconf-set-selections
  apt_install icecast2
  local ip
  ip="$(ip -4 -o addr show dev eth0 | awk '{ split($4, a, "/"); print a[1]; exit }')"
  write_file /etc/icecast2/icecast.xml 640 icecast2:icecast << EOF
<!-- Managed by pve-radio.sh, rewritten on every run. -->
<icecast>
  <location>Home</location>
  <admin>admin@localhost</admin>
  <limits>
    <clients>100</clients>
    <sources>4</sources>
    <queue-size>524288</queue-size>
    <client-timeout>30</client-timeout>
    <header-timeout>15</header-timeout>
    <source-timeout>10</source-timeout>
    <burst-on-connect>1</burst-on-connect>
    <burst-size>65535</burst-size>
  </limits>
  <authentication>
    <source-password>$SOURCE_PASSWORD</source-password>
    <relay-password>$RELAY_PASSWORD</relay-password>
    <admin-user>admin</admin-user>
    <admin-password>$ADMIN_PASSWORD</admin-password>
  </authentication>
  <hostname>$ip</hostname>
  <listen-socket>
    <port>8000</port>
  </listen-socket>
  <http-headers>
    <header name="Access-Control-Allow-Origin" value="*" />
  </http-headers>
  <fileserve>1</fileserve>
  <paths>
    <basedir>/usr/share/icecast2</basedir>
    <logdir>/var/log/icecast2</logdir>
    <webroot>/usr/share/icecast2/web</webroot>
    <adminroot>/usr/share/icecast2/admin</adminroot>
    <alias source="/" destination="/status.xsl"/>
  </paths>
  <logging>
    <accesslog>access.log</accesslog>
    <errorlog>error.log</errorlog>
    <loglevel>3</loglevel>
    <logsize>10000</logsize>
  </logging>
  <security>
    <chroot>0</chroot>
  </security>
</icecast>
EOF
  [[ ! -f /etc/default/icecast2 ]] \
    || sed -i 's/^ENABLE=.*/ENABLE=true/' /etc/default/icecast2
  systemctl enable icecast2 > /dev/null 2>&1
  systemctl restart icecast2
}

setup_liquidsoap() {
  apt_install liquidsoap
  id radio > /dev/null 2>&1 \
    || useradd --system --home-dir /srv/radio --shell /usr/sbin/nologin radio
  install -d -m 755 -o radio -g radio /srv/radio
  install -d -m 2775 -o radio -g radio "$MUSIC"

  write_file /etc/radio/radio.liq 644 << EOF
# Managed by pve-radio.sh, rewritten on every run.
settings.log.stdout.set(true)
settings.log.file.set(false)

password = environment.get("ICECAST_SOURCE_PASSWORD")
station = environment.get("RADIO_NAME")

music = playlist(mode="randomize", reload_mode="watch", "$MUSIC")
radio = mksafe(music)

output.icecast(%mp3(bitrate=$RADIO_BITRATE), host="127.0.0.1", port=8000,
  password=password, mount="radio.mp3", name=station, radio)
output.icecast(%vorbis(quality=0.4), host="127.0.0.1", port=8000,
  password=password, mount="radio.ogg", name=station, radio)
EOF
  printf 'ICECAST_SOURCE_PASSWORD=%s\nRADIO_NAME="%s"\n' "$SOURCE_PASSWORD" "$RADIO_NAME" \
    | write_file /etc/radio/radio.env 600

  write_file /etc/systemd/system/radio.service 644 << 'EOF'
# Managed by pve-radio.sh, rewritten on every run.
[Unit]
Description=Radio stream (Liquidsoap)
After=icecast2.service
Wants=icecast2.service

[Service]
User=radio
EnvironmentFile=/etc/radio/radio.env
ExecStart=/usr/bin/liquidsoap /etc/radio/radio.liq
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  runuser -u radio -- liquidsoap --check /etc/radio/radio.liq > /dev/null
  systemctl daemon-reload
  systemctl enable radio > /dev/null 2>&1
  systemctl restart radio
}

main() {
  upgrade_os
  setup_icecast
  setup_liquidsoap
  sleep 5
  log "Services: $(systemctl is-active icecast2 radio | tr '\n' ' ')"
  log "Mounts: $(curl -fsS http://127.0.0.1:8000/status-json.xsl | grep -o '"listenurl":"[^"]*"' | tr '\n' ' ')"
}
SCRIPT
}

guest_main "$@"
