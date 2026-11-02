#!/usr/bin/env bash
#
# @file pve-pterodactyl.sh
# @brief Unattended deploy and update of Pterodactyl (Panel + Wings) in a
#   Proxmox VM.
# @description
#   Runs on a Proxmox VE host as root and needs no answers.
#
#   No VM named $VM_NAME yet:
#   * downloads the Debian cloud image (checksum verified) and creates a VM
#     from it with cloud-init: static IP, a dedicated SSH key of this host;
#   * inside the VM installs Pterodactyl Panel (PHP, MariaDB, Redis, nginx,
#     queue worker, cron) and Wings (Docker), creates the admin user, a
#     location, a node for this VM with its Wings config, and allocations.
#
#   VM already exists: snapshots it, upgrades Debian packages and updates
#   Panel and Wings to the latest releases with the official update steps,
#   keeping the database, servers and settings.
#
#   Docker runs in a VM rather than an LXC container, as the Proxmox
#   documentation recommends; Docker inside LXC breaks on some containerd
#   updates. The panel is plain HTTP for the LAN only.
#
#   How to run:
#     VM_IP=192.168.11.52/24 VM_GW=192.168.11.1 bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-pterodactyl.sh)
#
#   Settings given once are remembered in $SETTINGS_FILE; secrets (admin
#   password, database password, APP_KEY, SSH key) are kept under
#   $STATE_DIR with mode 600.

set -euo pipefail

# ---- Settings (environment > saved > default) ----

# The host may be reached through the PVE web shell, which starts without
# $HOME, so the state paths are absolute on purpose.
STATE_DIR="/root/pve-pterodactyl"
SETTINGS_FILE="$STATE_DIR/settings.env"

# Settings that are remembered between runs.
PERSISTED_SETTINGS=(
  VM_IP VM_GW VM_DNS PHP_VERSION ALLOCATION_PORTS ADMIN_EMAIL TIMEZONE
)

# @description Load saved settings for variables that are not set in the
#   environment. A variable set to an empty value still wins.
load_settings() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  local name value
  while IFS='=' read -r name value; do
    [[ " ${PERSISTED_SETTINGS[*]} " == *" $name "* ]] || continue
    [[ -z "${!name+x}" ]] || continue
    # Values are written with printf %q by save_settings.
    eval "$name=$value"
  done < "$SETTINGS_FILE"
}

load_settings

VM_NAME="${VM_NAME:-ptero}"
VM_ID="${VM_ID:-}"
VM_STORAGE="${VM_STORAGE:-}"
VM_CORES="${VM_CORES:-4}"
VM_MEMORY="${VM_MEMORY:-12288}"
VM_DISK_GB="${VM_DISK_GB:-80}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
VM_IP="${VM_IP:-}"
VM_GW="${VM_GW:-}"
VM_DNS="${VM_DNS:-}"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-3}"
PHP_VERSION="${PHP_VERSION:-8.3}"
ALLOCATION_PORTS="${ALLOCATION_PORTS:-25565-25575}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@pve.lan}"
TIMEZONE="${TIMEZONE:-$(timedatectl show -p Timezone --value 2> /dev/null || echo UTC)}"
FORCE="${FORCE:-0}"

IMAGE_BASE="https://cloud.debian.org/images/cloud/trixie/latest"
IMAGE_NAME="debian-13-genericcloud-amd64.qcow2"
IMAGE_DIR="/var/lib/vz/import"
VM_USER="ptero"
LOG_FILE="/var/log/pve-pterodactyl.log"
LOCK_FILE="/run/lock/pve-pterodactyl.lock"
SNAPSHOT_PREFIX="ptero_"
SSH_TIMEOUT=300

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

# @description Print usage information.
usage() {
  cat << 'EOF'
pve-pterodactyl.sh - deploy or update Pterodactyl (Panel + Wings) in a VM.

Usage:
  pve-pterodactyl.sh [--auto | --install | --update | --help]

Modes:
  --auto     install if the VM does not exist, update otherwise (default)
  --install  only create a new VM, fail if it already exists
  --update   only update an existing VM, fail if it is missing

Environment (all optional unless noted):
  VM_IP                static address, CIDR, required for a new VM
  VM_GW                gateway, required for a new VM
  VM_DNS               DNS server                         [host default]
  VM_NAME              VM name, also used to find it again        [ptero]
  VM_ID                ID for a new VM                       [next free]
  VM_STORAGE           storage for the disk                       [auto]
  VM_CORES             CPU cores                                     [4]
  VM_MEMORY            RAM, MiB                                  [12288]
  VM_DISK_GB           disk size, GiB                               [80]
  VM_BRIDGE            network bridge                            [vmbr0]
  KEEP_SNAPSHOTS       update snapshots to keep                      [3]
  PHP_VERSION          PHP for the panel (8.3 is documented)       [8.3]
  ALLOCATION_PORTS     game ports for the node      [25565-25575]
  ADMIN_EMAIL          panel admin e-mail              [admin@pve.lan]
  TIMEZONE             panel time zone                    [host zone]
  FORCE                1 = reinstall Panel and Wings files          [0]

VM_*, PHP_VERSION, ALLOCATION_PORTS, ADMIN_EMAIL and TIMEZONE are
remembered in /root/pve-pterodactyl/settings.env.

Secrets are saved under /root/pve-pterodactyl/ (mode 600).
Log: /var/log/pve-pterodactyl.log
EOF
}

# ---- Guards ----

# @description Stop unless running as root.
require_root() {
  [[ "$(id -u)" -eq 0 ]] && return 0
  die "run me as root"
}

# @description Stop unless the Proxmox tools are available.
require_pve() {
  local tool
  for tool in qm pvesh pvesm; do
    command -v "$tool" > /dev/null && continue
    die "'$tool' not found, this script must run on a Proxmox VE host"
  done
}

# @description Stop if another copy of the script is already running.
take_lock() {
  exec 9> "$LOCK_FILE"
  flock -n 9 && return 0
  die "another pve-pterodactyl.sh is already running"
}

# @description Validate the network settings of a new VM.
# @exitcode 1 Missing address or gateway, or the address is in use.
check_network_settings() {
  [[ -n "$VM_IP" && "$VM_IP" == */* ]] \
    || die "VM_IP is required in CIDR form, e.g. 192.168.11.52/24"
  [[ -n "$VM_GW" ]] || die "VM_GW is required"
  ping -c 1 -W 1 "${VM_IP%/*}" > /dev/null 2>&1 || return 0
  die "${VM_IP%/*} already answers ping, pick another VM_IP"
}

# ---- State on the host ----

# @description Save a secret under $STATE_DIR.
# @arg $1 string File name.
# @arg $2 string Content.
save_secret() {
  install -d -m 700 "$STATE_DIR"
  (umask 077 && printf '%s\n' "$2" > "$STATE_DIR/$1")
}

# @description Print a saved secret, empty when missing.
# @arg $1 string File name.
# @stdout Content.
read_secret() {
  [[ -s "$STATE_DIR/$1" ]] || return 0
  head -n 1 "$STATE_DIR/$1"
}

# @description Print a secret, generating and saving it first when missing.
#   The value always has upper case, lower case and digits, as the panel
#   requires for passwords.
# @arg $1 string File name.
# @stdout Secret.
secret_or_new() {
  local value
  value="$(read_secret "$1")"
  if [[ -z "$value" ]]; then
    value="Pt$(openssl rand -hex 10)7"
    save_secret "$1" "$value"
  fi
  printf '%s' "$value"
}

# @description Remember the persisted settings for the next run.
save_settings() {
  local name
  install -d -m 700 "$STATE_DIR"
  (
    umask 077
    {
      printf '# Managed by pve-pterodactyl.sh; edit or delete to reset.\n'
      for name in "${PERSISTED_SETTINGS[@]}"; do
        printf '%s=%q\n' "$name" "${!name}"
      done
    } > "$SETTINGS_FILE"
  )
  chmod 600 "$SETTINGS_FILE"
}

# @description Create the SSH key this host uses to reach the VM.
ensure_ssh_key() {
  install -d -m 700 "$STATE_DIR"
  [[ -f "$STATE_DIR/id_ed25519" ]] && return 0
  ssh-keygen -q -t ed25519 -N '' -C "pve-pterodactyl@$(hostname)" \
    -f "$STATE_DIR/id_ed25519"
  ok "SSH key for the VM created"
}

# ---- VM helpers ----

# @description Print the ID of the VM with the given name.
# @arg $1 string VM name.
# @stdout VM ID, empty when none.
find_vm_by_name() {
  qm list | awk -v name="$1" 'NR > 1 && $2 == name { print $1; exit }'
}

# @description Print the active storage with the most free space that
#   accepts VM disks.
# @stdout Storage name.
pick_storage() {
  pvesm status --content images --enabled 1 2> /dev/null \
    | awk 'NR > 1 && $3 == "active" { print $6, $1 }' \
    | sort -rn \
    | awk 'NR == 1 { print $2 }'
}

# @description Print the VM address without the prefix length.
# @stdout IPv4 address.
vm_address() {
  printf '%s' "${VM_IP%/*}"
}

# @description Run a command in the VM over SSH as root (through sudo).
# @arg $@ string Remote command.
vm_ssh() {
  ssh -i "$STATE_DIR/id_ed25519" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$STATE_DIR/known_hosts" \
    "$VM_USER@$(vm_address)" sudo "$@"
}

# @description Start the VM unless it is already running.
ensure_running() {
  qm status "$VM_ID" | grep -q 'running' && return 0
  log "Starting VM $VM_ID"
  qm start "$VM_ID"
}

# @description Wait until the VM answers SSH and cloud-init is finished.
# @exitcode 1 No SSH within $SSH_TIMEOUT seconds.
wait_for_vm() {
  local waited=0
  log "Waiting for SSH on $(vm_address)"
  until vm_ssh true > /dev/null 2>&1; do
    ((waited += 5))
    ((waited < SSH_TIMEOUT)) || die "no SSH to $(vm_address) after ${SSH_TIMEOUT}s"
    sleep 5
  done
  vm_ssh cloud-init status --wait > /dev/null 2>&1 || true
  ok "VM is reachable"
}

# ---- VM lifecycle ----

# @description Download the Debian cloud image unless the current one is
#   already there, and verify its SHA-512 checksum.
ensure_image() {
  local sums expected
  install -d "$IMAGE_DIR"
  sums="$(curl -fsSL --retry 3 "$IMAGE_BASE/SHA512SUMS")" \
    || die "cannot download $IMAGE_BASE/SHA512SUMS"
  expected="$(awk -v f="$IMAGE_NAME" '$2 == f { print $1 }' <<< "$sums")"
  [[ -n "$expected" ]] || die "$IMAGE_NAME is not listed in SHA512SUMS"

  if [[ -f "$IMAGE_DIR/$IMAGE_NAME" ]] \
    && sha512sum "$IMAGE_DIR/$IMAGE_NAME" | grep -q "^$expected "; then
    ok "Cloud image already present: $IMAGE_NAME"
    return 0
  fi
  log "Downloading $IMAGE_NAME"
  curl -fL --retry 3 -o "$IMAGE_DIR/$IMAGE_NAME.part" "$IMAGE_BASE/$IMAGE_NAME"
  sha512sum "$IMAGE_DIR/$IMAGE_NAME.part" | grep -q "^$expected " \
    || die "checksum mismatch for $IMAGE_NAME"
  mv -f "$IMAGE_DIR/$IMAGE_NAME.part" "$IMAGE_DIR/$IMAGE_NAME"
  ok "Cloud image downloaded and verified"
}

# @description Create the VM from the cloud image and start it.
create_vm() {
  local storage="${VM_STORAGE:-$(pick_storage)}"
  [[ -n "$storage" ]] || die "no storage accepts VM disks (images)"
  ensure_image
  ensure_ssh_key

  VM_ID="${VM_ID:-$(pvesh get /cluster/nextid)}"
  local -a dns=()
  [[ -n "$VM_DNS" ]] && dns=(--nameserver "$VM_DNS")

  log "Creating VM $VM_ID ($VM_NAME) on $storage"
  qm create "$VM_ID" \
    --name "$VM_NAME" \
    --description "Pterodactyl Panel + Wings, managed by pve-pterodactyl.sh" \
    --tags pterodactyl \
    --ostype l26 \
    --cpu host \
    --cores "$VM_CORES" \
    --memory "$VM_MEMORY" \
    --scsihw virtio-scsi-single \
    --scsi0 "$storage:0,import-from=$IMAGE_DIR/$IMAGE_NAME,discard=on,iothread=1" \
    --ide2 "$storage:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1 \
    --net0 "virtio,bridge=$VM_BRIDGE" \
    --ciuser "$VM_USER" \
    --sshkeys "$STATE_DIR/id_ed25519.pub" \
    --ipconfig0 "ip=$VM_IP,gw=$VM_GW" \
    --ciupgrade 0 \
    --onboot 1 \
    "${dns[@]}"
  qm resize "$VM_ID" scsi0 "${VM_DISK_GB}G"
  # A recreated VM gets new host keys; forget the old ones for this IP.
  ssh-keygen -R "$(vm_address)" -f "$STATE_DIR/known_hosts" \
    > /dev/null 2>&1 || true
  qm start "$VM_ID"
  ok "VM $VM_ID created and started"
}

# @description Snapshot the VM and keep only the newest update snapshots.
#   Storages without snapshot support only produce a warning.
snapshot_vm() {
  local name
  name="${SNAPSHOT_PREFIX}$(date +%Y%m%d_%H%M%S)"
  if ! qm snapshot "$VM_ID" "$name" --description "before update" \
    > /dev/null 2>&1; then
    warn "Snapshot failed (storage without snapshots?), continuing"
    return 0
  fi
  ok "Snapshot $name created"
  prune_snapshots
}

# @description Delete update snapshots beyond $KEEP_SNAPSHOTS.
prune_snapshots() {
  local old
  qm listsnapshot "$VM_ID" \
    | { grep -oE "\b${SNAPSHOT_PREFIX}[0-9]{8}_[0-9]{6}\b" || true; } \
    | sort -u \
    | head -n "-$KEEP_SNAPSHOTS" \
    | while read -r old; do
      if qm delsnapshot "$VM_ID" "$old"; then
        log "Old snapshot $old removed"
      else
        warn "Could not remove old snapshot $old"
      fi
    done
}

# ---- Inside the VM ----

# @description Print the setup script that runs inside the VM as root.
#   Settings and secrets are prepended as "export" lines by run_vm_setup,
#   so they travel through stdin and never show up in process arguments on
#   the host.
# @stdout Bash script.
vm_script() {
  cat << 'SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive COMPOSER_ALLOW_SUPERUSER=1

PANEL_DIR=/var/www/pterodactyl
INSTALLED_MARKER=/etc/pve-pterodactyl.installed
PHP="php${PHP_VERSION}"

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }

# Installs packages, keeping local config files on upgrades.
apt_install() {
  apt-get install -y -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@" > /dev/null
}

# Writes stdin to a file atomically: write_file PATH MODE.
write_file() {
  install -d "$(dirname "$1")"
  cat > "$1.tmp"
  chmod "$2" "$1.tmp"
  mv -f "$1.tmp" "$1"
}

# Prints the tag of the latest GitHub release of a pterodactyl repo.
latest_tag() {
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 \
    "https://github.com/pterodactyl/$1/releases/latest" || true)"
  [[ "$url" == */tag/* ]] || return 0
  printf '%s' "${url##*/tag/}"
}

artisan() {
  (cd "$PANEL_DIR" && "$PHP" artisan --no-interaction "$@")
}

upgrade_os() {
  log "Upgrading Debian packages"
  apt-get update -q > /dev/null
  apt-get full-upgrade -y -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold > /dev/null
  apt_install curl ca-certificates gnupg tar unzip git cron \
    jq qemu-guest-agent nginx mariadb-server redis-server docker.io
  systemctl enable --now mariadb redis-server docker qemu-guest-agent \
    > /dev/null 2>&1
  ok "Debian packages, MariaDB, Redis, nginx and Docker are up to date"
}

# The panel documents PHP 8.2/8.3; Debian 13 ships 8.4, so 8.3 comes from
# the sury.org repository, as the official Debian guide does.
setup_php() {
  if ! apt-cache show "${PHP}-cli" > /dev/null 2>&1; then
    log "Adding the packages.sury.org repository for $PHP"
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg \
      | gpg --dearmor --yes -o /etc/apt/keyrings/sury-php.gpg
    write_file /etc/apt/sources.list.d/sury-php.sources 644 << EOF
Types: deb
URIs: https://packages.sury.org/php/
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: main
Signed-By: /etc/apt/keyrings/sury-php.gpg
EOF
    apt-get update -q > /dev/null
  fi
  local ext
  local -a packages=()
  for ext in common cli gd mysql mbstring bcmath xml fpm curl zip; do
    packages+=("${PHP}-${ext}")
  done
  apt_install "${packages[@]}"
  update-alternatives --set php "/usr/bin/$PHP" > /dev/null
  systemctl enable --now "${PHP}-fpm" > /dev/null 2>&1
  ok "$($PHP -r 'echo "PHP ", PHP_VERSION;') is ready"
}

setup_composer() {
  if [[ ! -x /usr/local/bin/composer ]]; then
    log "Installing composer"
    local expected actual
    expected="$(curl -fsSL https://composer.github.io/installer.sig)"
    curl -fsSL -o /tmp/composer-setup.php https://getcomposer.org/installer
    actual="$("$PHP" -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
    [[ "$expected" == "$actual" ]] || { echo "composer installer checksum mismatch"; exit 1; }
    "$PHP" /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin \
      --filename=composer
    rm -f /tmp/composer-setup.php
  fi
  "$PHP" /usr/local/bin/composer self-update --2 --quiet || true
  ok "composer $("$PHP" /usr/local/bin/composer --version 2> /dev/null | awk '{ print $3 }')"
}

composer_install() {
  (cd "$PANEL_DIR" && "$PHP" /usr/local/bin/composer install \
    --no-dev --optimize-autoloader --no-interaction --quiet)
}

download_panel() {
  curl -fsSL --retry 3 \
    https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
    | tar -xz -C "$PANEL_DIR"
  chmod -R 755 "$PANEL_DIR"/storage/* "$PANEL_DIR"/bootstrap/cache/
}

panel_version() {
  grep -oP "'version' => '\K[^']+" "$PANEL_DIR/config/app.php" 2> /dev/null || true
}

setup_database() {
  mariadb << EOF
CREATE DATABASE IF NOT EXISTS panel;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
}

# Every step can be repeated, so an install that stopped halfway is simply
# run again; the marker file is written only at the very end.
install_panel() {
  log "Installing Pterodactyl Panel"
  install -d "$PANEL_DIR"
  download_panel
  [[ -f "$PANEL_DIR/.env" ]] || cp "$PANEL_DIR/.env.example" "$PANEL_DIR/.env"
  composer_install
  setup_database
  grep -q '^APP_KEY=base64:' "$PANEL_DIR/.env" \
    || artisan key:generate --force > /dev/null
  artisan p:environment:setup \
    --author="$ADMIN_EMAIL" --url="http://${VM_ADDRESS}" \
    --timezone="$TIMEZONE" --cache=redis --session=redis --queue=redis \
    --redis-host=127.0.0.1 --redis-pass= --redis-port=6379 \
    --settings-ui=true --telemetry=false > /dev/null
  artisan p:environment:database --host=127.0.0.1 --port=3306 \
    --database=panel --username=pterodactyl --password="$DB_PASSWORD" \
    > /dev/null
  artisan migrate --seed --force > /dev/null
  if [[ "$(mariadb -N panel -e 'SELECT COUNT(*) FROM users')" == "0" ]]; then
    artisan p:user:make --email="$ADMIN_EMAIL" --username=admin \
      --name-first=Admin --name-last=PVE --password="$ADMIN_PASSWORD" \
      --admin=1 > /dev/null
  fi
  chown -R www-data:www-data "$PANEL_DIR"
  touch "$INSTALLED_MARKER"
  ok "Panel $(panel_version) installed, admin user created"
}

# The official update steps from the Pterodactyl documentation.
update_panel() {
  local current latest
  current="$(panel_version)"
  latest="$(latest_tag panel)"
  if [[ "$FORCE" != "1" && -n "$latest" && "v$current" == "$latest" ]]; then
    ok "Panel $current is already the latest"
    return 0
  fi
  log "Updating Panel $current -> ${latest:-latest}"
  artisan down > /dev/null
  download_panel
  composer_install
  artisan view:clear > /dev/null
  artisan config:clear > /dev/null
  artisan migrate --seed --force > /dev/null
  chown -R www-data:www-data "$PANEL_DIR"
  artisan queue:restart > /dev/null
  artisan up > /dev/null
  ok "Panel updated to $(panel_version)"
}

setup_panel() {
  if [[ -f "$INSTALLED_MARKER" ]]; then
    update_panel
  else
    install_panel
  fi
}

setup_panel_services() {
  write_file /etc/nginx/sites-available/pterodactyl.conf 644 << EOF
# Managed by pve-pterodactyl.sh, rewritten on every run.
server {
    listen 80 default_server;
    server_name _;
    root ${PANEL_DIR}/public;
    index index.php;
    charset utf-8;

    access_log off;
    error_log /var/log/nginx/pterodactyl.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt { access_log off; log_not_found off; }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/${PHP}-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/pterodactyl.conf \
    /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t > /dev/null 2>&1 || { nginx -t; exit 1; }
  systemctl enable nginx > /dev/null 2>&1
  systemctl reload-or-restart nginx

  write_file /etc/systemd/system/pteroq.service 644 << EOF
# Managed by pve-pterodactyl.sh, rewritten on every run.
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/${PHP} ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  write_file /etc/cron.d/pterodactyl 644 << EOF
# Managed by pve-pterodactyl.sh, rewritten on every run.
* * * * * root /usr/bin/${PHP} ${PANEL_DIR}/artisan schedule:run > /dev/null 2>&1
EOF
  systemctl daemon-reload
  systemctl enable pteroq > /dev/null 2>&1
  systemctl restart pteroq
  ok "nginx, queue worker and scheduler are running"
}

first_node_id() {
  artisan p:node:list --format=json | jq -r '.[0].id // empty'
}

# Registers this VM as a node once: location, node, allocations and the
# Wings config generated by the panel itself.
setup_node() {
  local node_id location_id
  node_id="$(first_node_id)"
  if [[ -n "$node_id" ]]; then
    ok "Node $node_id already registered"
    write_wings_config "$node_id"
    return 0
  fi
  log "Registering this VM as a node"
  local query="SELECT id FROM locations WHERE short = 'home' LIMIT 1"
  location_id="$(mariadb -N panel -e "$query")"
  if [[ -z "$location_id" ]]; then
    artisan p:location:make --short=home --long="Proxmox at home" > /dev/null
    location_id="$(mariadb -N panel -e "$query")"
  fi
  artisan p:node:make --name=pve --description="Wings in the ptero VM" \
    --locationId="$location_id" --fqdn="$VM_ADDRESS" --public=1 \
    --scheme=http --proxy=0 --maintenance=0 \
    --maxMemory="$NODE_MEMORY" --overallocateMemory=0 \
    --maxDisk="$NODE_DISK" --overallocateDisk=0 --uploadSize=100 \
    --daemonListeningPort=8080 --daemonSFTPPort=2022 \
    --daemonBase=/var/lib/pterodactyl/volumes > /dev/null
  node_id="$(first_node_id)"
  # The panel has no artisan command for allocations; its own service
  # inserts them and skips ports that already exist.
  local php_code
  php_code="app(Pterodactyl\\Services\\Allocations\\AssignmentService::class)"
  php_code+="->handle(Pterodactyl\\Models\\Node::findOrFail($node_id), ["
  php_code+="'allocation_ip' => '$VM_ADDRESS', "
  php_code+="'allocation_ports' => ['$ALLOCATION_PORTS']]);"
  artisan tinker --execute="$php_code" > /dev/null
  write_wings_config "$node_id"
  ok "Node $node_id registered with ports $ALLOCATION_PORTS"
}

# Writes the Wings config generated by the panel, only when it is missing:
# Wings keeps its own changes in that file.
write_wings_config() {
  [[ -s /etc/pterodactyl/config.yml ]] && return 0
  install -d -m 700 /etc/pterodactyl
  artisan p:node:configuration "$1" --format=yaml \
    | write_file /etc/pterodactyl/config.yml 600
  ok "Wings config written"
}

wings_version() {
  /usr/local/bin/wings --version 2> /dev/null | grep -oE 'v[0-9][^ ]*' || true
}

setup_wings() {
  local current latest
  current="$(wings_version)"
  latest="$(latest_tag wings)"
  if [[ "$FORCE" == "1" || -z "$current" || "$current" != "$latest" ]]; then
    log "Installing Wings ${latest:-latest}"
    curl -fsSL --retry 3 -o /usr/local/bin/wings.new \
      https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
    chmod 755 /usr/local/bin/wings.new
    mv -f /usr/local/bin/wings.new /usr/local/bin/wings
  fi
  write_file /etc/systemd/system/wings.service 644 << 'EOF'
# Managed by pve-pterodactyl.sh, rewritten on every run.
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable wings > /dev/null 2>&1
  systemctl restart wings
  ok "Wings $(wings_version) is running"
}

report() {
  local code
  sleep 5
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/auth/login)"
  log "Panel login page: HTTP $code"
  log "Services: $(systemctl is-active nginx "${PHP}-fpm" pteroq mariadb redis-server docker wings | tr '\n' ' ')"
  # The key decrypts stored secrets; the host keeps a copy (see summary).
  grep '^APP_KEY=' "$PANEL_DIR/.env" | sed 's/^/APP_KEY_LINE /'
}

main() {
  upgrade_os
  setup_php
  setup_composer
  setup_panel
  setup_panel_services
  setup_node
  setup_wings
  report
}

# The script itself arrives on stdin: give the commands /dev/null instead,
# so nothing can swallow the rest of it.
main < /dev/null
SCRIPT
}

# @description Run the VM setup with settings and secrets passed through
#   stdin, and keep a copy of APP_KEY on the host.
run_vm_setup() {
  local -A vars=(
    [VM_ADDRESS]="$(vm_address)"
    [PHP_VERSION]="$PHP_VERSION"
    [ALLOCATION_PORTS]="$ALLOCATION_PORTS"
    [ADMIN_EMAIL]="$ADMIN_EMAIL"
    [ADMIN_PASSWORD]="$(secret_or_new admin-password)"
    [DB_PASSWORD]="$(secret_or_new db-password)"
    [TIMEZONE]="$TIMEZONE"
    [FORCE]="$FORCE"
    # Leave about 2 GiB of RAM and 10 GiB of disk to the VM itself.
    [NODE_MEMORY]="$((VM_MEMORY - 2048))"
    [NODE_DISK]="$(((VM_DISK_GB - 10) * 1024))"
  )
  local name line
  {
    for name in "${!vars[@]}"; do
      printf 'export %s=%q\n' "$name" "${vars[$name]}"
    done
    vm_script
  } | vm_ssh bash -s | while IFS= read -r line; do
    if [[ "$line" == APP_KEY_LINE\ * ]]; then
      save_secret app-key "${line#APP_KEY_LINE }"
      continue
    fi
    printf '%s\n' "$line"
  done
}

# ---- Summary ----

# @description Print the final summary without secrets.
print_summary() {
  printf '\n========== pterodactyl ==========\n'
  printf 'VM        : %s (%s)\n' "$VM_ID" "$VM_NAME"
  printf 'Panel     : http://%s  (user admin)\n' "$(vm_address)"
  printf 'Password  : cat %s/admin-password\n' "$STATE_DIR"
  printf 'Game ports: %s on %s\n' "$ALLOCATION_PORTS" "$(vm_address)"
  printf 'SSH       : ssh -i %s/id_ed25519 %s@%s\n' \
    "$STATE_DIR" "$VM_USER" "$(vm_address)"
  printf 'APP_KEY   : %s/app-key (keep a copy off this server)\n' "$STATE_DIR"
  printf '=================================\n'
}

# ---- Actions ----

# ID of the VM that already has $VM_NAME, empty when none.
EXISTING_ID=""

# @description Create the VM and install Pterodactyl in it.
action_install() {
  [[ -z "$EXISTING_ID" ]] || die "VM $EXISTING_ID ($VM_NAME) already exists"
  check_network_settings
  create_vm
  wait_for_vm
  run_vm_setup
}

# @description Update Debian, Panel and Wings in the existing VM.
action_update() {
  [[ -n "$EXISTING_ID" ]] || die "no VM named '$VM_NAME' to update"
  VM_ID="$EXISTING_ID"
  [[ -n "$VM_IP" ]] || die "VM_IP is unknown, pass it once (it is remembered)"
  ensure_ssh_key
  log "Updating VM $VM_ID ($VM_NAME)"
  snapshot_vm
  ensure_running
  wait_for_vm
  run_vm_setup
}

# @description Pick install or update depending on whether the VM exists.
action_auto() {
  if [[ -n "$EXISTING_ID" ]]; then
    action_update
  else
    action_install
  fi
}

# Command-line flag -> action (lookup table instead of if/elif chains).
declare -A ACTIONS=(
  [--auto]=action_auto
  [--install]=action_install
  [--update]=action_update
)

# ---- Main ----

# @description Entry point.
# @arg $1 string Mode flag, see usage.
main() {
  local mode="${1:---auto}"
  if [[ "$mode" == "--help" || "$mode" == "-h" ]]; then
    usage
    return 0
  fi
  [[ -n "${ACTIONS[$mode]+x}" ]] || { usage >&2; die "unknown mode: $mode"; }

  require_root
  require_pve
  take_lock
  (umask 077 && : >> "$LOG_FILE")
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "pve-pterodactyl.sh started $(date '+%F %T'), mode $mode"

  EXISTING_ID="$(find_vm_by_name "$VM_NAME")"
  "${ACTIONS[$mode]}"
  save_settings
  print_summary
  ok "Done. Log: $LOG_FILE"
}

main "$@"
