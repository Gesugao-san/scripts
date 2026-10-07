#!/bin/bash
cd ~
echo "====="
for i in $(seq 2); do
  echo "[$i/2]"
  sudo apt update -y
  apt list --upgradable -a
  sudo apt upgrade -y
  #do-release-upgrade -d
  #apt dist-upgrade
  sudo dpkg --configure -a
  sudo apt autoremove -y
  sudo apt autoclean -y
  echo "====="
done
