#!/usr/bin/env bash
#
# @file pve-torrent.sh
# @brief Unattended deploy and update of a BitTorrent client (Tixati) in a
#   Proxmox LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. Tixati is a
#   GTK3 program without a headless mode, so in an unprivileged container
#   ($CT_HOSTNAME, created when missing) it runs on a virtual display:
#
#   | Unit                  | What                                      |
#   |-----------------------|-------------------------------------------|
#   | tixati-display        | Xvnc (TigerVNC) on :1, VNC on localhost   |
#   | tixati-wm             | Openbox, so dialogs can be moved          |
#   | tixati                | Tixati as user "tixati", restarted always |
#   | tixati-novnc          | noVNC on 6080: the full GUI in a browser  |
#
#   Downloads live in /srv/torrents inside the container: either a host
#   folder (TORRENT_PATH, e.g. on a separate disk) or a new volume
#   (TORRENT_STORAGE, TORRENT_DISK_GB) left out of backups.
#
#   The .deb comes from tixati.com and is checked against its GPG
#   signature. The key fingerprint is saved on the first run and must
#   match on every later one (trust on first use): compare it once with
#   the Release Verification page of support.tixati.com. Each run installs
#   the newest version from tixati.com/linux, falling back to
#   TORRENT_VERSION when the page cannot be read.
#
#   Tixati keeps its settings in its own binary files, so the rest is done
#   once in the GUI through noVNC: download folder /srv/torrents, a fixed
#   incoming port, the Web Interface with a password. After that the GUI is
#   only needed for RSS and categories: TORRENT_GUI=off stops noVNC.
#   Nothing is forwarded on the router: without the incoming port Tixati
#   only connects out, slower but fine. Neither noVNC nor the Web
#   Interface has TLS: keep them in the LAN or behind the VPN.
#
#   How to run (a new container needs TORRENT_PATH or TORRENT_STORAGE):
#     TORRENT_PATH=/mnt/hdd1/torrents bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-torrent.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="torrent"
PERSISTED_SETTINGS=(
  TORRENT_PATH TORRENT_STORAGE TORRENT_DISK_GB TORRENT_VERSION
  TORRENT_GUI TORRENT_SCREEN
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
TORRENT_PATH="${TORRENT_PATH:-}"
TORRENT_STORAGE="${TORRENT_STORAGE:-}"
TORRENT_DISK_GB="${TORRENT_DISK_GB:-500}"
TORRENT_VERSION="${TORRENT_VERSION:-3.44-1}"
TORRENT_GUI="${TORRENT_GUI:-on}"
TORRENT_SCREEN="${TORRENT_SCREEN:-1600x900}"
CT_DISK_GB="${CT_DISK_GB:-8}"
CT_MEMORY="${CT_MEMORY:-1024}"
CT_CORES="${CT_CORES:-2}"
CT_DESCRIPTION="BitTorrent client (Tixati)"
ct_defaults

DATA_IN_CT="/srv/torrents"
# Fixed so the owner of a host folder is known: an unprivileged container
# shifts IDs by 100000 on the host.
TIXATI_UID=1000
TIXATI_HOST_ID=$((100000 + TIXATI_UID))
NOVNC_PORT=6080

# ---- Data mount ----

# @description Print the mp0 value for a host folder (bind mount).
data_mount_path() {
  printf '%s,mp=%s' "$TORRENT_PATH" "$DATA_IN_CT"
}

# @description Print the mp0 value for a new volume, kept out of backups:
#   downloads can be fetched again.
data_mount_volume() {
  printf '%s:%s,mp=%s,backup=0' "$TORRENT_STORAGE" "$TORRENT_DISK_GB" \
    "$DATA_IN_CT"
}

# Data source -> mp0 printer (lookup table instead of if/elif chains).
declare -A DATA_MOUNTS=(
  [path]=data_mount_path
  [volume]=data_mount_volume
)

# @description Print which data source the settings ask for.
# @stdout "path", "volume" or empty.
data_source() {
  [[ -z "$TORRENT_PATH" ]] || { printf 'path'; return 0; }
  [[ -z "$TORRENT_STORAGE" ]] || { printf 'volume'; return 0; }
}

# @description Create the host folder and hand it to the container's
#   "tixati" user. Only the folder itself changes owner, never what is
#   already inside.
prepare_host_folder() {
  [[ "$(data_source)" == "path" ]] || return 0
  install -d "$TORRENT_PATH"
  [[ "$(stat -c %u "$TORRENT_PATH")" == "$TIXATI_HOST_ID" ]] && return 0
  chown "$TIXATI_HOST_ID:$TIXATI_HOST_ID" "$TORRENT_PATH"
  ok "$TORRENT_PATH now belongs to tixati of the container ($TIXATI_HOST_ID)"
}

# @description Print the VNC password, generating it on the first run.
#   VNC uses only 8 characters, so a longer one would be cut silently.
# @stdout Password.
vnc_password() {
  local value
  value="$(read_secret vnc-password)"
  if [[ -z "$value" ]]; then
    value="$(openssl rand -base64 6)"
    save_secret vnc-password "$value"
  fi
  printf '%s' "$value"
}

# ---- Hooks ----

service_usage() {
  cat << EOF

Torrent (environment, remembered):
  TORRENT_PATH     host folder for downloads (bind mount)  [${TORRENT_PATH:-none}]
  TORRENT_STORAGE  or a storage for a new volume        [${TORRENT_STORAGE:-none}]
  TORRENT_DISK_GB  size of that volume, GiB               [$TORRENT_DISK_GB]
  TORRENT_VERSION  version when tixati.com is unreadable  [$TORRENT_VERSION]
  TORRENT_GUI      noVNC on port $NOVNC_PORT, "on" or "off"     [$TORRENT_GUI]
  TORRENT_SCREEN   size of the virtual display            [$TORRENT_SCREEN]
EOF
}

service_preflight() {
  [[ "$TORRENT_GUI" == "on" || "$TORRENT_GUI" == "off" ]] \
    || die "TORRENT_GUI must be on or off"
  [[ "$TORRENT_SCREEN" =~ ^[0-9]+x[0-9]+$ ]] \
    || die "TORRENT_SCREEN must look like 1600x900"
  [[ "$TORRENT_VERSION" =~ ^[0-9.]+-[0-9]+$ ]] \
    || die "TORRENT_VERSION must look like 3.44-1"
  [[ -z "$TORRENT_PATH" || "$TORRENT_PATH" == /* ]] \
    || die "TORRENT_PATH must be an absolute path"
  [[ -z "$TORRENT_PATH" || -z "$TORRENT_STORAGE" ]] \
    || die "set TORRENT_PATH or TORRENT_STORAGE, not both"
  [[ -z "$EXISTING_ID" ]] || return 0
  [[ -n "$(data_source)" ]] \
    || die "a new container needs TORRENT_PATH or TORRENT_STORAGE (see --help)"
  [[ -z "$TORRENT_STORAGE" ]] && return 0
  [[ "$TORRENT_DISK_GB" =~ ^[0-9]+$ ]] || die "TORRENT_DISK_GB must be a number"
  pvesm status --storage "$TORRENT_STORAGE" > /dev/null 2>&1 \
    || die "storage '$TORRENT_STORAGE' not found"
}

# @description Prepare the host folder; on updates also bring a changed
#   TORRENT_PATH into the container. A volume is never touched again.
service_host_setup() {
  prepare_host_folder
  [[ -n "$EXISTING_ID" && "$(data_source)" == "path" ]] || return 0
  guest_ensure_running
  ct_set_option mp0 "$(data_mount_path)"
}

service_create_args() {
  printf '%s\n' --mp0 "$("${DATA_MOUNTS[$(data_source)]}")"
}

service_exports() {
  export_var DATA_IN_CT "$DATA_IN_CT"
  export_var TIXATI_UID "$TIXATI_UID"
  export_var TIXATI_FALLBACK_VERSION "$TORRENT_VERSION"
  export_var TIXATI_KEY_FPR "$(read_secret tixati-key-fpr)"
  export_var TORRENT_GUI "$TORRENT_GUI"
  export_var TORRENT_SCREEN "$TORRENT_SCREEN"
  export_var NOVNC_PORT "$NOVNC_PORT"
  export_var VNC_PASSWORD "$(vnc_password)"
}

service_summary() {
  local ip origin
  ip="$(guest_address || true)"
  case "$(data_source)" in
    path) origin="$TORRENT_PATH" ;;
    volume) origin="volume on $TORRENT_STORAGE" ;;
    *) origin="mp0 of the CT" ;;
  esac
  printf 'Downloads : %s -> %s\n' "$origin" "$DATA_IN_CT"
  if [[ "$TORRENT_GUI" == "on" ]]; then
    printf 'GUI       : http://%s:%s/vnc.html\n' "$ip" "$NOVNC_PORT"
    printf 'Password  : cat %s/vnc-password\n' "$STATE_DIR"
  else
    printf 'GUI       : off (TORRENT_GUI=on to get it back)\n'
  fi
  printf 'Key       : cat %s/tixati-key-fpr (compare with tixati.com)\n' \
    "$STATE_DIR"
  printf 'First run : in the GUI set the folder %s, a fixed port,\n' \
    "$DATA_IN_CT"
  printf '            and enable the Web Interface with a password\n'
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
TIXATI_HOME=/home/tixati
UNIT_DIR=/etc/systemd/system
TIXATI_CHANGED=0

fail() {
  printf '[x] ERROR: %s\n' "$*" >&2
  exit 1
}

ensure_user() {
  id tixati > /dev/null 2>&1 && return 0
  getent passwd "$TIXATI_UID" > /dev/null && fail "uid $TIXATI_UID is taken"
  groupadd --gid "$TIXATI_UID" tixati
  useradd --uid "$TIXATI_UID" --gid "$TIXATI_UID" --create-home \
    --home-dir "$TIXATI_HOME" --shell /usr/sbin/nologin tixati
  ok "User tixati created"
}

# Prints the newest version listed on tixati.com/linux, or the fallback.
latest_version() {
  local found
  found="$(curl -fsSL --retry 3 https://www.tixati.com/linux 2> /dev/null \
    | grep -oE 'tixati_[0-9.]+-[0-9]+_amd64\.deb' \
    | sed -E 's/^tixati_(.*)_amd64\.deb$/\1/' \
    | sort -V | tail -n 1 || true)"
  if [[ -z "$found" ]]; then
    warn "Cannot read tixati.com/linux, using $TIXATI_FALLBACK_VERSION"
    found="$TIXATI_FALLBACK_VERSION"
  fi
  printf '%s' "$found"
}

# Checks the signature; the key must match the fingerprint saved on the
# first run. A new fingerprint is handed to the host.
verify_package() {
  local dir="$1" deb="$2" gnupg="$1/gnupg" fpr
  install -d -m 700 "$gnupg"
  curl -fsSL --retry 3 -o "$dir/tixati.key" https://www.tixati.com/tixati.key
  gpg --homedir "$gnupg" --quiet --import "$dir/tixati.key" 2> /dev/null
  fpr="$(gpg --homedir "$gnupg" --with-colons --fingerprint \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ -n "$fpr" ]] || fail "no key in tixati.key"
  if [[ -z "$TIXATI_KEY_FPR" ]]; then
    emit_secret tixati-key-fpr "$fpr"
    warn "Tixati key seen for the first time: $fpr"
  elif [[ "$fpr" != "$TIXATI_KEY_FPR" ]]; then
    fail "Tixati key changed: $fpr, saved $TIXATI_KEY_FPR"
  fi
  gpg --homedir "$gnupg" --quiet --verify "$dir/$deb.asc" "$dir/$deb" \
    2> /dev/null || fail "bad signature on $deb"
  ok "Signature of $deb is good"
}

install_tixati() {
  local version installed deb dir
  version="$(latest_version)"
  installed="$(dpkg-query -W -f '${Version}' tixati 2> /dev/null || true)"
  if [[ "$installed" == "$version" ]]; then
    ok "Tixati $installed is current"
    return 0
  fi
  log "Installing Tixati $version (now: ${installed:-none})"
  deb="tixati_${version}_amd64.deb"
  dir="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$dir/$deb" "https://download.tixati.com/$deb"
  curl -fsSL --retry 3 -o "$dir/$deb.asc" "https://download.tixati.com/$deb.asc"
  verify_package "$dir" "$deb"
  # _apt reads the package from a 0700 mktemp folder otherwise.
  chmod 755 "$dir"
  chmod 644 "$dir/$deb"
  apt_install "$dir/$deb"
  rm -rf "$dir"
  [[ -x /usr/bin/tixati ]] || fail "/usr/bin/tixati missing after install"
  TIXATI_CHANGED=1
  ok "Tixati $version installed"
}

write_vnc_password() {
  install -d -m 700 -o tixati -g tixati "$TIXATI_HOME/.vnc"
  printf '%s\n' "$VNC_PASSWORD" | vncpasswd -f \
    | write_file "$TIXATI_HOME/.vnc/passwd" 600 tixati:tixati
}

prepare_data() {
  mountpoint -q "$DATA_IN_CT" || warn "$DATA_IN_CT is not mounted"
  install -d "$DATA_IN_CT"
  chown tixati:tixati "$DATA_IN_CT" 2> /dev/null \
    || warn "cannot chown $DATA_IN_CT, the host owns it"
  runuser -u tixati -- test -w "$DATA_IN_CT" \
    || warn "tixati cannot write to $DATA_IN_CT"
}

write_units() {
  # Xvnc is Type=simple: "started" does not mean the X socket is there.
  # "$$" is the systemd escape for "$".
  local wait_x="/bin/sh -c 'for i in \$\$(seq 1 50); do [ -S /tmp/.X11-unix/X1 ] && exit 0; sleep 0.2; done; exit 1'"

  write_file "$UNIT_DIR/tixati-display.service" 644 << EOF
# Managed by pve-torrent.sh, rewritten on every run.
[Unit]
Description=Virtual X display :1 for Tixati (TigerVNC)
After=network.target

[Service]
User=tixati
ExecStart=/usr/bin/Xvnc :1 -geometry $TORRENT_SCREEN -depth 24 \\
  -rfbauth $TIXATI_HOME/.vnc/passwd -SecurityTypes VncAuth \\
  -localhost -nolisten tcp -AlwaysShared
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  write_file "$UNIT_DIR/tixati-wm.service" 644 << EOF
# Managed by pve-torrent.sh, rewritten on every run.
[Unit]
Description=Openbox on display :1
Requires=tixati-display.service
After=tixati-display.service
PartOf=tixati-display.service

[Service]
User=tixati
Environment=DISPLAY=:1
ExecStartPre=$wait_x
ExecStart=/usr/bin/openbox
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  # Restart=always: closing the window in noVNC exits with code 0, and
  # Tixati must come back anyway. "systemctl stop" is not affected.
  write_file "$UNIT_DIR/tixati.service" 644 << EOF
# Managed by pve-torrent.sh, rewritten on every run.
[Unit]
Description=Tixati BitTorrent client on display :1
Requires=tixati-display.service
After=tixati-display.service tixati-wm.service network-online.target
Wants=network-online.target
PartOf=tixati-display.service

[Service]
User=tixati
WorkingDirectory=$TIXATI_HOME
Environment=DISPLAY=:1
Environment=NO_AT_BRIDGE=1
ExecStartPre=$wait_x
ExecStart=/usr/bin/dbus-run-session -- /usr/bin/tixati
Restart=always
RestartSec=5
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

  write_file "$UNIT_DIR/tixati-novnc.service" 644 << EOF
# Managed by pve-torrent.sh, rewritten on every run.
[Unit]
Description=noVNC access to the Tixati display (port $NOVNC_PORT)
Requires=tixati-display.service
After=tixati-display.service

[Service]
User=tixati
ExecStart=/usr/bin/websockify --web /usr/share/novnc $NOVNC_PORT localhost:5901
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

# Starts what is stopped; Tixati is restarted only after an upgrade, so an
# update run does not break the transfers for nothing.
start_units() {
  systemctl enable --now tixati-display tixati-wm tixati > /dev/null 2>&1
  ((TIXATI_CHANGED == 0)) || systemctl restart tixati
  if [[ "$TORRENT_GUI" == "on" ]]; then
    systemctl enable --now tixati-novnc > /dev/null 2>&1
  else
    systemctl disable --now tixati-novnc > /dev/null 2>&1 || true
  fi
}

main() {
  upgrade_os
  apt_install ca-certificates curl gnupg dbus \
    tigervnc-standalone-server tigervnc-tools openbox novnc websockify \
    fonts-dejavu-core
  ensure_user
  install_tixati
  write_vnc_password
  prepare_data
  write_units
  start_units
  sleep 3
  log "Tixati: $(systemctl is-active tixati || true)," \
    "display: $(systemctl is-active tixati-display || true)," \
    "noVNC: $(systemctl is-active tixati-novnc || true)"
}
SCRIPT
}

guest_main "$@"
