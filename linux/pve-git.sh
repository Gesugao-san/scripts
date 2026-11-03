#!/usr/bin/env bash
#
# @file pve-git.sh
# @brief Unattended deploy and update of a Forgejo git server with GitHub
#   mirrors in a Proxmox LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing):
#
#   * Forgejo (binary from Codeberg, SHA-256 verified) with SQLite, its own
#     SSH server on port 2222 and the web UI on port 3000; registration is
#     closed and even reading needs a login;
#   * the admin account GIT_ADMIN with a generated password;
#   * pull mirrors of the repositories in GIT_MIRRORS, refreshed every
#     GIT_MIRROR_INTERVAL, so the code stays at home when GitHub is gone.
#     New URLs are added on the next run; removed ones are left alone.
#
#   Running it again snapshots the container, upgrades Debian and moves
#   Forgejo to the latest release (or FORGEJO_VERSION when set); the
#   database migrates on start. app.ini is written once and then left to
#   you.
#
#   How to run:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-git.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="git"
PERSISTED_SETTINGS=(
  GIT_ADMIN GIT_ADMIN_EMAIL GIT_MIRRORS GIT_MIRROR_INTERVAL FORGEJO_VERSION
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
GIT_ADMIN="${GIT_ADMIN:-gesu}"
GIT_ADMIN_EMAIL="${GIT_ADMIN_EMAIL:-$GIT_ADMIN@git.lan}"
GIT_MIRRORS="${GIT_MIRRORS:-https://github.com/Gesugao-san/scripts}"
GIT_MIRROR_INTERVAL="${GIT_MIRROR_INTERVAL:-8h}"
FORGEJO_VERSION="${FORGEJO_VERSION:-}"
CT_CORES="${CT_CORES:-2}"
CT_MEMORY="${CT_MEMORY:-2048}"
CT_DISK_GB="${CT_DISK_GB:-32}"
CT_DESCRIPTION="Forgejo git server with GitHub mirrors"
ct_defaults

# ---- Hooks ----

service_usage() {
  cat << EOF

Forgejo (environment, remembered):
  GIT_ADMIN            admin login                          [$GIT_ADMIN]
  GIT_ADMIN_EMAIL      admin e-mail                         [$GIT_ADMIN_EMAIL]
  GIT_MIRRORS          repository URLs to mirror, space separated
  GIT_MIRROR_INTERVAL  how often mirrors are refreshed      [$GIT_MIRROR_INTERVAL]
  FORGEJO_VERSION      pin a version, e.g. 15.0.11 (LTS)    [latest]
EOF
}

service_preflight() {
  [[ "$GIT_ADMIN" =~ ^[a-z][a-z0-9_-]{1,38}$ ]] \
    || die "GIT_ADMIN must be a lower-case login"
  # "admin" and a few other names are reserved by Forgejo.
  [[ "$GIT_ADMIN" != "admin" ]] || die "GIT_ADMIN 'admin' is reserved by Forgejo"
  local url
  for url in $GIT_MIRRORS; do
    [[ "$url" =~ ^https://[^[:space:]]+/[^/[:space:]]+$ ]] \
      || die "mirror URL must be https://host/owner/repo: $url"
  done
}

service_exports() {
  export_var GIT_ADMIN "$GIT_ADMIN"
  export_var GIT_ADMIN_EMAIL "$GIT_ADMIN_EMAIL"
  export_var GIT_ADMIN_PASSWORD "$(secret_or_new admin-password)"
  export_var GIT_API_TOKEN "$(read_secret api-token)"
  export_var GIT_MIRRORS "$GIT_MIRRORS"
  export_var GIT_MIRROR_INTERVAL "$GIT_MIRROR_INTERVAL"
  export_var FORGEJO_VERSION "$FORGEJO_VERSION"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'Web       : http://%s:3000  (user %s)\n' "$ip" "$GIT_ADMIN"
  printf 'Password  : cat %s/admin-password\n' "$STATE_DIR"
  printf 'SSH       : ssh://git@%s:2222/<owner>/<repo>.git\n' "$ip"
  printf 'Mirrors   : %s\n' "$(wc -w <<< "$GIT_MIRRORS") repositories"
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
BIN=/usr/local/bin/forgejo
CONF=/etc/forgejo/app.ini
WORK=/var/lib/forgejo
API=http://127.0.0.1:3000/api/v1

# Runs the Forgejo CLI as the git user.
forgejo_cli() {
  runuser -u git -- "$BIN" --config "$CONF" --work-path "$WORK" "$@"
}

setup_user() {
  id git > /dev/null 2>&1 || adduser --system --shell /bin/bash \
    --gecos 'Git Version Control' --group --disabled-password --home /home/git git
  install -d -m 750 -o git -g git "$WORK" "$WORK/custom" "$WORK/data" "$WORK/log"
  install -d -m 750 -o root -g git /etc/forgejo
}

latest_version() {
  curl -fsSL --retry 3 https://codeberg.org/api/v1/repos/forgejo/forgejo/releases/latest \
    | jq -r '.tag_name' | sed 's/^v//'
}

installed_version() {
  [[ -x "$BIN" ]] || return 0
  "$BIN" --version 2> /dev/null | awk '{ print $3 }' | sed 's/+.*//'
}

install_forgejo() {
  local want have base file
  want="${FORGEJO_VERSION:-$(latest_version)}"
  if [[ -z "$want" || "$want" == "null" ]]; then
    # Codeberg unreachable: keep the installed binary, fail without one.
    [[ -x "$BIN" ]] || { echo "cannot reach Codeberg to download Forgejo" >&2; exit 1; }
    warn "cannot check for a newer Forgejo, keeping $(installed_version)"
    return 0
  fi
  have="$(installed_version)"
  if [[ "$have" == "$want" ]]; then
    ok "Forgejo $have is current"
    return 0
  fi
  log "Installing Forgejo $want (was ${have:-none})"
  base="https://codeberg.org/forgejo/forgejo/releases/download/v$want"
  file="forgejo-$want-linux-amd64"
  install -d /tmp/forgejo-dl
  curl -fsSL --retry 3 -o "/tmp/forgejo-dl/$file" "$base/$file"
  curl -fsSL --retry 3 -o "/tmp/forgejo-dl/$file.sha256" "$base/$file.sha256"
  (cd /tmp/forgejo-dl && sha256sum -c "$file.sha256" > /dev/null) \
    || { rm -rf /tmp/forgejo-dl; echo "checksum mismatch for $file" >&2; exit 1; }
  systemctl stop forgejo 2> /dev/null || true
  install -m 755 "/tmp/forgejo-dl/$file" "$BIN"
  rm -rf /tmp/forgejo-dl
  ok "Forgejo $want installed"
}

# The config is written once; later runs leave your edits alone.
write_config() {
  [[ -f "$CONF" ]] && return 0
  local ip
  ip="$(ip -4 -o addr show dev eth0 | awk '{ split($4, a, "/"); print a[1]; exit }')"
  write_file "$CONF" 640 root:git << EOF
; Written once by pve-git.sh; edit freely, it is not overwritten.
APP_NAME = Forgejo
RUN_USER = git
RUN_MODE = prod
WORK_PATH = $WORK

[database]
DB_TYPE = sqlite3
PATH = $WORK/data/forgejo.db

[repository]
ROOT = $WORK/data/forgejo-repositories

[server]
DOMAIN = $ip
HTTP_PORT = 3000
ROOT_URL = http://$ip:3000/
DISABLE_SSH = false
START_SSH_SERVER = true
SSH_PORT = 2222
SSH_LISTEN_PORT = 2222
LFS_START_SERVER = true
LFS_JWT_SECRET = $("$BIN" generate secret JWT_SECRET)
OFFLINE_MODE = true

[lfs]
PATH = $WORK/data/lfs

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true
DEFAULT_KEEP_EMAIL_PRIVATE = true

[security]
INSTALL_LOCK = true
SECRET_KEY = $("$BIN" generate secret SECRET_KEY)
INTERNAL_TOKEN = $("$BIN" generate secret INTERNAL_TOKEN)

[oauth2]
JWT_SECRET = $("$BIN" generate secret JWT_SECRET)

[mirror]
DEFAULT_INTERVAL = 8h
MIN_INTERVAL = 10m

[log]
MODE = console
LEVEL = Info
EOF
  ok "app.ini written"
}

write_unit() {
  write_file /etc/systemd/system/forgejo.service 644 << EOF
# Managed by pve-git.sh, rewritten on every run.
[Unit]
Description=Forgejo
After=network.target

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=$WORK
ExecStart=$BIN web --config $CONF
Restart=always
RestartSec=2s
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=$WORK

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable forgejo > /dev/null 2>&1
  systemctl restart forgejo
}

wait_for_web() {
  for _ in $(seq 1 60); do
    curl -fsS http://127.0.0.1:3000/api/healthz > /dev/null 2>&1 && return 0
    sleep 2
  done
  echo "Forgejo did not come up, see: journalctl -u forgejo" >&2
  exit 1
}

ensure_admin() {
  if forgejo_cli admin user list --admin | awk 'NR > 1 { print $2 }' | grep -qx "$GIT_ADMIN"; then
    ok "Admin $GIT_ADMIN exists"
    return 0
  fi
  forgejo_cli admin user create --admin --username "$GIT_ADMIN" \
    --email "$GIT_ADMIN_EMAIL" --password "$GIT_ADMIN_PASSWORD" \
    --must-change-password=false > /dev/null
  ok "Admin $GIT_ADMIN created"
}

# Reuses the token kept on the host, or makes a new one and hands it over.
ensure_token() {
  if [[ -n "$GIT_API_TOKEN" ]] \
    && curl -fsS -H "Authorization: token $GIT_API_TOKEN" "$API/user" > /dev/null 2>&1; then
    return 0
  fi
  GIT_API_TOKEN="$(forgejo_cli admin user generate-access-token \
    --username "$GIT_ADMIN" --token-name "pve-git-$(date +%s)" \
    --scopes "write:repository,read:user" --raw)"
  emit_secret api-token "$GIT_API_TOKEN"
  ok "API token created"
}

ensure_mirrors() {
  local url repo code body
  for url in $GIT_MIRRORS; do
    repo="$(basename "$url" .git)"
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: token $GIT_API_TOKEN" "$API/repos/$GIT_ADMIN/$repo")"
    if [[ "$code" == "200" ]]; then
      ok "Mirror $repo exists"
      continue
    fi
    body="$(jq -n --arg url "$url" --arg repo "$repo" --arg owner "$GIT_ADMIN" \
      --arg every "$GIT_MIRROR_INTERVAL" \
      '{clone_addr: $url, repo_name: $repo, repo_owner: $owner, mirror: true,
        mirror_interval: $every, private: true, service: "git"}')"
    code="$(curl -s -o /tmp/migrate.out -w '%{http_code}' -X POST \
      -H "Authorization: token $GIT_API_TOKEN" -H 'Content-Type: application/json' \
      -d "$body" "$API/repos/migrate")"
    if [[ "$code" == "201" ]]; then
      ok "Mirror $repo created from $url"
    else
      warn "Mirror $repo failed (HTTP $code): $(head -c 300 /tmp/migrate.out)"
    fi
    rm -f /tmp/migrate.out
  done
}

main() {
  upgrade_os
  apt_install git git-lfs sqlite3 jq
  setup_user
  install_forgejo
  write_config
  write_unit
  wait_for_web
  ensure_admin
  ensure_token
  ensure_mirrors
  log "Forgejo $(installed_version): $(systemctl is-active forgejo)"
}
SCRIPT
}

guest_main "$@"
