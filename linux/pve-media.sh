#!/usr/bin/env bash
#
# @file pve-media.sh
# @brief Unattended deploy and update of a media server (Jellyfin) in a
#   Proxmox LXC container, fed from the media folder of the file server.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. Needs the file
#   server from pve-share.sh: its /media folder is mounted read-only into
#   this container at /srv/media, so films are uploaded and deleted through
#   copyparty only and Jellyfin cannot change them.
#
#   Libraries are made from the subfolders that exist:
#
#   | Folder in share | Library  | Type    |
#   |-----------------|----------|---------|
#   | /media/films    | Фильмы   | movies  |
#   | /media/series   | Сериалы  | tvshows |
#   | /media/music    | Музыка   | music   |
#
#   Accounts follow the file server: the owner (SHARE_ADMIN) becomes the
#   Jellyfin administrator, and every login of /root/pve-share/people.conf
#   in one of MEDIA_GROUPS gets a viewer account with the same password as
#   in share. A login removed from people.conf is disabled, not deleted, so
#   its watch history stays. Passwords changed later in Jellyfin are kept.
#
#   The Intel iGPU (/dev/dri/renderD128) is passed into the container when
#   the host has it, and Jellyfin is set to Intel QSV on the first run:
#   hardware decoding of H.264, HEVC 8-bit, MPEG-2 and VC-1, which every
#   Intel iGPU since Skylake handles. Newer chips can do more (HEVC 10-bit,
#   VP9, AV1): tick them in Dashboard > Playback > Transcoding.
#
#   Posters and descriptions are kept by Jellyfin in its own folder, never
#   next to the films. Jellyfin must not be opened to the internet
#   directly: use the VPN or the reverse proxy.
#
#   How to run (after pve-share.sh):
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-media.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="media"
PERSISTED_SETTINGS=(MEDIA_SHARE_CT MEDIA_PATH MEDIA_GROUPS MEDIA_GPU)

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
MEDIA_SHARE_CT="${MEDIA_SHARE_CT:-share}"
MEDIA_PATH="${MEDIA_PATH:-}"
MEDIA_GROUPS="${MEDIA_GROUPS:-family friends lovers mods admins}"
MEDIA_GPU="${MEDIA_GPU:-auto}"
CT_DISK_GB="${CT_DISK_GB:-16}"
CT_MEMORY="${CT_MEMORY:-2048}"
CT_CORES="${CT_CORES:-4}"
CT_DESCRIPTION="Media server (Jellyfin)"
ct_defaults

SHARE_STATE="/root/pve-share"
MEDIA_IN_CT="/srv/media"

# Filled by service_preflight.
MEDIA_SOURCE=""
MEDIA_FILES_GID=""
MEDIA_GPU_DEVICE=""
MEDIA_OWNER=""

# ---- The file server ----

# @description Print a remembered setting of pve-share.sh.
# @arg $1 string Setting name.
# @stdout Value, empty when unknown.
share_setting() {
  [[ -f "$SHARE_STATE/settings.env" ]] || return 0
  sed -n "s/^$1=//p" "$SHARE_STATE/settings.env" | tail -n 1
}

# @description Print the host folder behind /media of the share container:
#   its data volume (mp0) must be a directory, as on ZFS or a dir storage.
# @stdout Absolute host path.
share_media_path() {
  local id volume path
  id="$(find_ct_by_hostname "$MEDIA_SHARE_CT")"
  [[ -n "$id" ]] || die "no '$MEDIA_SHARE_CT' container, run pve-share.sh first or set MEDIA_PATH"
  volume="$(pct config "$id" | awk '$1 == "mp0:" { split($2, a, ","); print a[1] }')"
  [[ -n "$volume" ]] || die "CT $id ($MEDIA_SHARE_CT) has no data volume mp0"
  path="$(pvesm path "$volume")"
  [[ -d "$path" ]] || die "$volume is not a directory on the host ($path), set MEDIA_PATH"
  printf '%s/media' "$path"
}

# @description Print the group ID of the media folder as the containers
#   see it (unprivileged containers shift IDs by 100000 on the host).
# @arg $1 string Host path.
# @stdout Group ID inside a container.
files_gid_of() {
  local gid
  gid="$(stat -c %g "$1")"
  ((gid >= 100000 && gid < 165536)) \
    || die "$1 belongs to host group $gid, not to an unprivileged container"
  printf '%s' "$((gid - 100000))"
}

# @description Print "login:password" of every person of people.conf who
#   is in one of MEDIA_GROUPS. People without a share password yet are
#   skipped with a warning.
# @stdout One line per login.
viewer_credentials() {
  local login groups group password
  [[ -f "$SHARE_STATE/people.conf" ]] || return 0
  while read -r login groups; do
    [[ -n "$login" ]] || continue
    for group in $groups; do
      [[ " $MEDIA_GROUPS " == *" $group "* ]] || continue
      password="$(head -n 1 "$SHARE_STATE/users/$login" 2> /dev/null || true)"
      if [[ -z "$password" ]]; then
        warn "$login has no share password yet, run pve-share.sh first"
        break
      fi
      printf '%s:%s\n' "$login" "$password"
      break
    done
  done < <(sed -e 's/#.*//' "$SHARE_STATE/people.conf")
}

# ---- Container options ----

# @description Mount the media folder read-only and pass the iGPU render
#   node with the container's own "render" group. Needs a running CT.
configure_ct() {
  ct_set_option mp0 "$MEDIA_SOURCE,mp=$MEDIA_IN_CT,ro=1"
  [[ -n "$MEDIA_GPU_DEVICE" ]] || return 0
  ct_exec getent group render > /dev/null || ct_exec groupadd --system render
  local gid
  gid="$(ct_exec getent group render | cut -d: -f3)"
  ct_set_option dev0 "$MEDIA_GPU_DEVICE,gid=$gid,mode=0660"
}

# ---- Hooks ----

service_usage() {
  cat << EOF

Media (environment, remembered):
  MEDIA_SHARE_CT  hostname of the file server CT         [$MEDIA_SHARE_CT]
  MEDIA_PATH      host folder with the media instead of share's /media
  MEDIA_GROUPS    share groups that get an account
                  [$MEDIA_GROUPS]
  MEDIA_GPU       "auto", "none" or a render node        [$MEDIA_GPU]
EOF
}

service_preflight() {
  MEDIA_SOURCE="${MEDIA_PATH:-$(share_media_path)}"
  [[ -d "$MEDIA_SOURCE" ]] || die "no media folder at $MEDIA_SOURCE"
  MEDIA_FILES_GID="$(files_gid_of "$MEDIA_SOURCE")"

  MEDIA_OWNER="$(share_setting SHARE_ADMIN)"
  [[ -n "$MEDIA_OWNER" ]] || die "no SHARE_ADMIN in $SHARE_STATE/settings.env, run pve-share.sh first"
  [[ -s "$SHARE_STATE/users/$MEDIA_OWNER" ]] || die "no share password for $MEDIA_OWNER"

  case "$MEDIA_GPU" in
    none) MEDIA_GPU_DEVICE="" ;;
    auto) MEDIA_GPU_DEVICE="/dev/dri/renderD128" ;;
    *) MEDIA_GPU_DEVICE="$MEDIA_GPU" ;;
  esac
  [[ -z "$MEDIA_GPU_DEVICE" || -c "$MEDIA_GPU_DEVICE" ]] && return 0
  [[ "$MEDIA_GPU" == "auto" ]] || die "$MEDIA_GPU_DEVICE is not a device"
  warn "No iGPU render node on the host, transcoding will use the CPU"
  MEDIA_GPU_DEVICE=""
}

# @description On updates the container exists: bring its options in line.
service_host_setup() {
  [[ -n "$EXISTING_ID" ]] || return 0
  guest_ensure_running
  configure_ct
}

service_after_create() {
  configure_ct
}

service_exports() {
  export_var MEDIA_IN_CT "$MEDIA_IN_CT"
  export_var MEDIA_FILES_GID "$MEDIA_FILES_GID"
  export_var MEDIA_GPU_DEVICE "$MEDIA_GPU_DEVICE"
  export_var MEDIA_OWNER "$MEDIA_OWNER"
  export_var MEDIA_OWNER_PASSWORD "$(head -n 1 "$SHARE_STATE/users/$MEDIA_OWNER")"
  export_var MEDIA_VIEWERS "$(viewer_credentials)"
  export_var MEDIA_API_KEY "$(read_secret api-key)"
}

service_summary() {
  printf 'Web       : http://%s:8096/\n' "$(guest_address || true)"
  printf 'Media     : %s -> %s (read-only)\n' "$MEDIA_SOURCE" "$MEDIA_IN_CT"
  printf 'iGPU      : %s\n' "${MEDIA_GPU_DEVICE:-none, CPU transcoding}"
  printf 'Accounts  : %s (admin) + %s viewers, passwords as in share\n' \
    "$MEDIA_OWNER" "$(viewer_credentials 2> /dev/null | grep -c . || true)"
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
API=http://127.0.0.1:8096
CLIENT='MediaBrowser Client="pve-media", Device="pve-media", DeviceId="pve-media", Version="1.0"'
AUTH="$CLIENT"
MANAGED=/var/lib/pve-media/users
FFMPEG_DIR=/usr/lib/jellyfin-ffmpeg

# Folder in share -> "library name:collection type".
declare -A LIBRARIES=(
  [films]="Фильмы:movies"
  [series]="Сериалы:tvshows"
  [music]="Музыка:music"
)

fail() {
  printf '[x] ERROR: %s\n' "$*" >&2
  exit 1
}

# Calls the Jellyfin API: api METHOD PATH [JSON BODY].
api() {
  local args=(-fsS -X "$1" -H "Authorization: $AUTH" -H 'Content-Type: application/json')
  [[ -z "${3:-}" ]] || args+=(--data-binary "$3")
  curl "${args[@]}" "$API$2"
}

# Prints the argument encoded for a URL query.
uri() {
  jq -rn --arg v "$1" '$v | @uri'
}

setup_jellyfin() {
  apt_install ca-certificates curl gnupg jq
  local codename
  codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  curl -fsSI "https://repo.jellyfin.org/debian/dists/$codename/Release" > /dev/null \
    || fail "the Jellyfin repository has no Debian '$codename' yet"
  curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
    | gpg --dearmor | write_file /etc/apt/keyrings/jellyfin.gpg 644
  write_file /etc/apt/sources.list.d/jellyfin.sources 644 << EOF
Types: deb
URIs: https://repo.jellyfin.org/debian
Suites: $codename
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/jellyfin.gpg
EOF
  apt-get update -q > /dev/null
  log "Installing or upgrading Jellyfin"
  apt_install jellyfin
  ok "Jellyfin $(dpkg-query -W -f '${Version}' jellyfin-server)"
}

# Lets Jellyfin read the share files (their group) and use the iGPU.
grant_access() {
  local group
  group="$(getent group "$MEDIA_FILES_GID" | cut -d: -f1)"
  if [[ -z "$group" ]]; then
    groupadd --gid "$MEDIA_FILES_GID" share-files
    group=share-files
  fi
  usermod -aG "$group" jellyfin
  [[ -z "$MEDIA_GPU_DEVICE" ]] || usermod -aG render jellyfin
  systemctl restart jellyfin
  runuser -u jellyfin -- test -r "$MEDIA_IN_CT" -a -x "$MEDIA_IN_CT" \
    || warn "jellyfin cannot read $MEDIA_IN_CT, check its group in share"
}

check_gpu() {
  [[ -n "$MEDIA_GPU_DEVICE" ]] || return 0
  local driver
  driver="$(runuser -u jellyfin -- "$FFMPEG_DIR/vainfo" --display drm \
    --device "$MEDIA_GPU_DEVICE" 2>&1 | grep -m 1 -i 'driver version' || true)"
  if [[ -n "$driver" ]]; then
    ok "iGPU: ${driver#*: }"
  else
    warn "iGPU does not answer, transcoding will fall back to the CPU"
  fi
}

wait_api() {
  local waited=0
  log "Waiting for Jellyfin (the first start and upgrades migrate the database)"
  until curl -fsS "$API/System/Info/Public" > /dev/null 2>&1; do
    ((waited += 3))
    ((waited < 600)) || fail "Jellyfin does not answer on $API"
    sleep 3
  done
}

# Runs the startup wizard once: Russian, owner account, LAN only.
first_setup() {
  local completed
  completed="$(curl -fsS "$API/System/Info/Public" | jq -r .StartupWizardCompleted)"
  [[ "$completed" != "true" ]] || return 1
  log "Running the startup wizard"
  api POST /Startup/Configuration \
    '{"ServerName":"media","UICulture":"ru","MetadataCountryCode":"RU","PreferredMetadataLanguage":"ru"}' > /dev/null
  api GET /Startup/User > /dev/null
  api POST /Startup/User "$(jq -n --arg n "$MEDIA_OWNER" --arg p "$MEDIA_OWNER_PASSWORD" \
    '{Name: $n, Password: $p}')" > /dev/null
  api POST /Startup/RemoteAccess \
    '{"EnableRemoteAccess":false,"EnableAutomaticPortMapping":false}' > /dev/null
  api POST /Startup/Complete > /dev/null
  ok "Owner account $MEDIA_OWNER created"
}

# Uses the saved API key, or signs in as the owner and makes one.
sign_in() {
  if [[ -n "$MEDIA_API_KEY" ]]; then
    AUTH="$CLIENT, Token=\"$MEDIA_API_KEY\""
    api GET /System/Info > /dev/null 2>&1 && return 0
    warn "The saved API key no longer works, making a new one"
  fi
  local token key
  AUTH="$CLIENT"
  token="$(api POST /Users/AuthenticateByName "$(jq -n --arg n "$MEDIA_OWNER" \
    --arg p "$MEDIA_OWNER_PASSWORD" '{Username: $n, Pw: $p}')" | jq -r .AccessToken)" \
    || fail "cannot sign in as $MEDIA_OWNER (password changed in Jellyfin?)"
  AUTH="$CLIENT, Token=\"$token\""
  api POST "/Auth/Keys?app=pve-media" > /dev/null
  key="$(api GET /Auth/Keys | jq -r '[.Items[] | select(.AppName == "pve-media")][-1].AccessToken')"
  [[ -n "$key" && "$key" != "null" ]] || fail "could not create an API key"
  emit_secret api-key "$key"
  AUTH="$CLIENT, Token=\"$key\""
}

# Intel QSV with the codecs every iGPU since Skylake decodes.
setup_transcoding() {
  [[ -n "$MEDIA_GPU_DEVICE" ]] || return 0
  local config
  config="$(api GET /System/Configuration/encoding | jq --arg d "$MEDIA_GPU_DEVICE" '
    .HardwareAccelerationType = "qsv"
    | .VaapiDevice = $d
    | .QsvDevice = $d
    | .EnableHardwareEncoding = true
    | .HardwareDecodingCodecs = ["h264", "hevc", "mpeg2video", "vc1"]')"
  if api POST /System/Configuration/encoding "$config" > /dev/null; then
    ok "Transcoding set to Intel QSV"
  else
    warn "Could not set QSV, set it in Dashboard > Playback > Transcoding"
  fi
}

add_libraries() {
  local existing dir name type body
  existing="$(api GET /Library/VirtualFolders | jq -r '.[].Name')"
  for dir in "${!LIBRARIES[@]}"; do
    name="${LIBRARIES[$dir]%%:*}"
    type="${LIBRARIES[$dir]#*:}"
    grep -qxF "$name" <<< "$existing" && continue
    if [[ ! -d "$MEDIA_IN_CT/$dir" ]]; then
      warn "No /media/$dir in share yet, library '$name' skipped"
      continue
    fi
    body="$(jq -n --arg p "$MEDIA_IN_CT/$dir" '{LibraryOptions: {
      PathInfos: [{Path: $p}], PreferredMetadataLanguage: "ru",
      MetadataCountryCode: "RU", EnableRealtimeMonitor: true,
      SaveLocalMetadata: false}}')"
    api POST "/Library/VirtualFolders?name=$(uri "$name")&collectionType=$type&refreshLibrary=true" \
      "$body" > /dev/null
    ok "Library $name added"
  done
}

# Applies a jq filter to a user's policy: set_policy ID FILTER.
set_policy() {
  local policy
  policy="$(api GET "/Users/$1" | jq ".Policy | $2")"
  api POST "/Users/$1/Policy" "$policy" > /dev/null
}

# Viewer accounts from share; people gone from it are disabled.
sync_users() {
  local users login password id wanted=""
  users="$(api GET /Users)"
  while IFS=: read -r login password; do
    [[ -n "$login" ]] || continue
    wanted+="$login"$'\n'
    id="$(jq -r --arg n "$login" '.[] | select(.Name == $n) | .Id' <<< "$users")"
    if [[ -n "$id" ]]; then
      set_policy "$id" '.IsDisabled = false'
      continue
    fi
    id="$(api POST /Users/New "$(jq -n --arg n "$login" --arg p "$password" \
      '{Name: $n, Password: $p}')" | jq -r .Id)"
    set_policy "$id" '.IsAdministrator = false | .IsDisabled = false
      | .EnableContentDeletion = false | .EnableRemoteControlOfOtherUsers = false
      | .EnableSharedDeviceControl = false'
    ok "Account $login created"
  done <<< "$MEDIA_VIEWERS"

  touch "$MANAGED"
  while read -r login; do
    [[ -n "$login" ]] || continue
    grep -qxF "$login" <<< "$wanted" && continue
    id="$(jq -r --arg n "$login" '.[] | select(.Name == $n) | .Id' <<< "$users")"
    [[ -n "$id" ]] || continue
    set_policy "$id" '.IsDisabled = true'
    ok "Account $login disabled (gone from share)"
  done < "$MANAGED"
  printf '%s' "$wanted" | write_file "$MANAGED" 600
}

main() {
  upgrade_os
  mountpoint -q "$MEDIA_IN_CT" || warn "$MEDIA_IN_CT is not mounted"
  install -d -m 700 "$(dirname "$MANAGED")"
  setup_jellyfin
  grant_access
  check_gpu
  wait_api
  local fresh=0
  first_setup && fresh=1
  sign_in
  ((fresh == 0)) || setup_transcoding
  add_libraries
  sync_users
  log "Jellyfin: $(systemctl is-active jellyfin)"
}
SCRIPT
}

guest_main "$@"
