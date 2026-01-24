#!/usr/bin/env bash
set -euo pipefail

# How to run me:
# cd ~/pve-fake-subscription/
# curl -LJO https://raw.githubusercontent.com/Gesugao-san/chocolatey-scripts/refs/heads/master/src/pve-sub-fix.sh
# chmod +x pve-sub-fix.sh
# ./pve-sub-fix.sh

echo "[*] Starting pve-fake-subscription setup script"

# ---- Safety check ----
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[!] ERROR: This script must be run with bash, not sh"
  exit 1
fi
echo "[+] Running under bash ${BASH_VERSION}"

# ---- Config ----
BASE_DIR="$HOME/pve-fake-subscription"
REPO="Jamesits/pve-fake-subscription"
HOSTS_ENTRY="127.0.0.1 shop.maurer-it.com"

echo "[*] Base directory: $BASE_DIR"
echo "[*] GitHub repository: $REPO"

# ---- Prepare directory ----
echo "[*] Creating working directory (if missing)"
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"
echo "[+] Working directory ready: $(pwd)"

# ---- Detect latest release tag ----
echo "[*] Detecting latest release tag via GitHub API"
TAG="$(curl -fsSL https://api.github.com/repos/${REPO}/releases/latest \
  | grep '"tag_name"' | cut -d '"' -f4)"

if [ -z "$TAG" ]; then
  echo "[!] ERROR: Failed to detect latest release tag"
  exit 1
fi
echo "[+] Latest release tag detected: $TAG"

# ---- Download sha256sum.txt ----
echo "[*] Downloading sha256sum.txt"
curl -fsSL -o sha256sum.txt \
  "https://github.com/${REPO}/releases/download/${TAG}/sha256sum.txt"
echo "[+] sha256sum.txt downloaded"

# ---- Extract .deb filename ----
echo "[*] Extracting .deb filename from sha256sum.txt"
DEB_FILE="$(awk '{print $2}' sha256sum.txt | sed 's/^\*//' | grep '\.deb$' | head -n1)"

if [ -z "$DEB_FILE" ]; then
  echo "[!] ERROR: .deb file name not found in sha256sum.txt"
  exit 1
fi
echo "[+] Package file detected: $DEB_FILE"

# ---- Download .deb ----
echo "[*] Downloading package: $DEB_FILE"
curl -fsSL -o "$DEB_FILE" \
  "https://github.com/${REPO}/releases/download/${TAG}/${DEB_FILE}"
echo "[+] Package downloaded successfully"

# ---- Verify checksum ----
echo "[*] Verifying SHA256 checksum"
sha256sum -c sha256sum.txt --ignore-missing
echo "[+] Checksum verification passed"

# ---- Install package ----
echo "[*] Installing package via dpkg"
sudo dpkg -i "$DEB_FILE"
echo "[+] Package installed"

# ---- Update /etc/hosts ----
echo "[*] Checking /etc/hosts for required entry"
if grep -qF "$HOSTS_ENTRY" /etc/hosts; then
  echo "[=] /etc/hosts already contains required entry"
else
  echo "[*] Adding entry to /etc/hosts"
  echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts > /dev/null
  echo "[+] Entry added to /etc/hosts"
fi

systemctl restart pveproxy.service

echo "[✓] Script finished successfully"
