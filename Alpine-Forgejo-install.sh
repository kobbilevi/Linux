#!/bin/sh
set -e

URL_SSH_PUBLIC_KEY="https://raw.githubusercontent.com/kobbilevi/Linux/refs/heads/main/SSHKey-FingerPrint.txt"
URL_DOCKER_COMPOSE="https://raw.githubusercontent.com/kobbilevi/Linux/refs/heads/main/Forgejo-docker-compose.yml"

echo "=== 1. Updates & Package Installation ==="
apk update && apk upgrade
apk add docker docker-compose nano openssh-server git wget

echo "=== 2. Configuring Docker ==="
rc-update add docker boot
service docker start

echo "=== 3. Configuring SSH (Key-based only) ==="
mkdir -p ~/.ssh
chmod 700 ~/.ssh
wget -O ~/.ssh/authorized_keys "$URL_SSH_PUBLIC_KEY"
chmod 600 ~/.ssh/authorized_keys
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
rc-update add sshd default
service sshd restart
apk add avahi avahi-tools
rc-update add avahi-daemon default
service avahi-daemon start

echo "=== 4. Setting up Forgejo Workspace ==="
mkdir -p ~/forgejo-server && cd ~/forgejo-server
wget -O docker-compose.yml "$URL_DOCKER_COMPOSE"

echo "=== 5. Starting Forgejo ==="
docker-compose up -d

echo "=================================================="
echo " Installation complete! Forgejo is running."
echo "=================================================="
