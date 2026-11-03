#!/usr/bin/env bash
#
# @file pve-web.sh
# @brief Unattended deploy and update of a static website behind Anubis in
#   a Proxmox LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing):
#
#   * nginx serving /srv/www on 127.0.0.1:8080 (a placeholder page is put
#     there once; replace it with your site);
#   * Anubis (Techaro, .deb from its latest GitHub release) on port 8923 in
#     front of it: visitors solve a small proof-of-work in the browser,
#     scrapers that do not run JavaScript are kept out. Its signing key is
#     kept on the host, so passed challenges survive restarts;
#   * with WEB_ANUBIS=0, nginx itself listens on port 80 instead.
#
#   TLS is not handled here: put the site behind whatever terminates HTTPS
#   (a reverse proxy, or the fallback of an Xray inbound) and set
#   WEB_HTTPS=1 then, so Anubis marks its cookies as secure.
#
#   How to run:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-web.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="web"
PERSISTED_SETTINGS=(WEB_ANUBIS WEB_DIFFICULTY WEB_HTTPS)

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
WEB_ANUBIS="${WEB_ANUBIS:-1}"
WEB_DIFFICULTY="${WEB_DIFFICULTY:-4}"
WEB_HTTPS="${WEB_HTTPS:-0}"
CT_DISK_GB="${CT_DISK_GB:-8}"
CT_MEMORY="${CT_MEMORY:-512}"
CT_DESCRIPTION="Static website behind Anubis"
ct_defaults

# ---- Hooks ----

service_usage() {
  cat << EOF

Website (environment, remembered):
  WEB_ANUBIS      1 = Anubis in front on :8923, 0 = nginx on :80  [$WEB_ANUBIS]
  WEB_DIFFICULTY  proof-of-work difficulty                        [$WEB_DIFFICULTY]
  WEB_HTTPS       1 = the site is served over HTTPS upstream      [$WEB_HTTPS]
EOF
}

service_preflight() {
  [[ "$WEB_ANUBIS" =~ ^[01]$ && "$WEB_HTTPS" =~ ^[01]$ ]] \
    || die "WEB_ANUBIS and WEB_HTTPS must be 0 or 1"
  [[ "$WEB_DIFFICULTY" =~ ^[1-9]$ ]] || die "WEB_DIFFICULTY must be 1..9"
}

# @description Print the Anubis signing key, creating it on first use.
# @stdout 64 hex characters.
anubis_key() {
  local key
  key="$(read_secret anubis-ed25519-key)"
  if [[ -z "$key" ]]; then
    key="$(openssl rand -hex 32)"
    save_secret anubis-ed25519-key "$key"
  fi
  printf '%s' "$key"
}

service_exports() {
  export_var WEB_ANUBIS "$WEB_ANUBIS"
  export_var WEB_DIFFICULTY "$WEB_DIFFICULTY"
  export_var WEB_HTTPS "$WEB_HTTPS"
  export_var ANUBIS_KEY "$(anubis_key)"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  if [[ "$WEB_ANUBIS" == "1" ]]; then
    printf 'Site      : http://%s:8923/  (through Anubis)\n' "$ip"
  else
    printf 'Site      : http://%s/\n' "$ip"
  fi
  printf 'Files     : /srv/www in the container\n'
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
SITE=/srv/www

setup_site() {
  install -d -m 755 "$SITE"
  [[ -e "$SITE/index.html" ]] && return 0
  write_file "$SITE/index.html" 644 << 'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Under construction</title></head>
<body><p>Nothing here yet.</p></body>
</html>
EOF
}

setup_nginx() {
  local listen="127.0.0.1:8080"
  [[ "$WEB_ANUBIS" == "1" ]] || listen="80 default_server"
  write_file /etc/nginx/sites-available/site.conf 644 << EOF
# Managed by pve-web.sh, rewritten on every run.
server {
    listen $listen;
    server_name _;
    root $SITE;
    index index.html;
    server_tokens off;
    location / {
        try_files \$uri \$uri/ =404;
    }
    location ~ /\. { deny all; }
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/site.conf /etc/nginx/sites-enabled/site.conf
  nginx -t > /dev/null 2>&1 || { nginx -t; exit 1; }
  systemctl enable nginx > /dev/null 2>&1
  systemctl reload-or-restart nginx
}

install_anubis() {
  local release tag url have
  release="$(curl -fsSL --retry 3 https://api.github.com/repos/TecharoHQ/anubis/releases/latest || true)"
  tag="$(jq -r '.tag_name // empty' <<< "$release" 2> /dev/null || true)"
  url="$(jq -r '.assets[].browser_download_url | select(test("amd64\\.deb$"))' <<< "$release" 2> /dev/null | head -n 1 || true)"
  have="$(dpkg-query -W -f '${Version}' anubis 2> /dev/null || true)"
  if [[ -z "$url" ]]; then
    [[ -n "$have" ]] || { echo "cannot find the Anubis .deb on GitHub" >&2; exit 1; }
    warn "cannot check for a newer Anubis, keeping $have"
    return 0
  fi
  if [[ -n "$have" && "${tag#v}" == "$have"* ]]; then
    ok "Anubis $have is current"
    return 0
  fi
  log "Installing Anubis $tag"
  curl -fsSL --retry 3 -o /tmp/anubis.deb "$url"
  apt_install /tmp/anubis.deb
  rm -f /tmp/anubis.deb
}

setup_anubis() {
  if [[ "$WEB_ANUBIS" != "1" ]]; then
    systemctl disable --now anubis@site > /dev/null 2>&1 || true
    return 0
  fi
  install_anubis
  local secure=false
  [[ "$WEB_HTTPS" == "1" ]] && secure=true
  write_file /etc/anubis/site.env 600 << EOF
# Managed by pve-web.sh, rewritten on every run.
BIND=:8923
BIND_NETWORK=tcp
TARGET=http://127.0.0.1:8080
DIFFICULTY=$WEB_DIFFICULTY
METRICS_BIND=127.0.0.1:9090
METRICS_BIND_NETWORK=tcp
SERVE_ROBOTS_TXT=true
COOKIE_SECURE=$secure
ED25519_PRIVATE_KEY_HEX=$ANUBIS_KEY
EOF
  systemctl enable anubis@site > /dev/null 2>&1
  systemctl restart anubis@site
}

main() {
  upgrade_os
  apt_install nginx jq
  setup_site
  setup_nginx
  setup_anubis
  sleep 2
  log "nginx: $(systemctl is-active nginx), anubis: $(systemctl is-active anubis@site 2> /dev/null || true)"
}
SCRIPT
}

guest_main "$@"
