#!/usr/bin/env bash
set -euo pipefail

# ---- Config ----
BASE_DIR="$HOME/pve-fake-subscription"
GITHUB_REPO="Jamesits/pve-fake-subscription"
HOSTS_ENTRY="127.0.0.1 shop.maurer-it.com"

# ---- Prepare directory ----
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# ---- Download sha256sum file from latest release ----
curl -fsSL -o sha256sum.txt \
  "https://github.com/${GITHUB_REPO}/releases/latest/download/sha256sum.txt"

# ---- Extract .deb filename from sha256sum.txt ----
DEB_FILE="$(awk '{print $2}' sha256sum.txt | grep '\.deb$' | head -n1)"

if [[ -z "$DEB_FILE" ]]; then
  echo "ERROR: .deb file name not found in sha256sum.txt"
  exit 1
fi

# ---- Download .deb ----
curl -fsSL -o "$DEB_FILE" \
  "https://github.com/${GITHUB_REPO}/releases/latest/download/${DEB_FILE}"

# ---- Verify checksum ----
echo "Verifying checksum..."
sha256sum -c sha256sum.txt --ignore-missing

# ---- Install package ----
echo "Installing package..."
sudo dpkg -i "$DEB_FILE"

# ---- Update /etc/hosts if needed ----
if ! grep -qF "$HOSTS_ENTRY" /etc/hosts; then
  echo "Updating /etc/hosts..."
  echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts > /dev/null
else
  echo "/etc/hosts already contains required entry"
fi

echo "Done."
