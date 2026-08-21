#!/bin/sh
set -e

# Detect the directory where this script is located
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DOCKER_SCRIPT_PATH="${SCRIPT_DIR}/install_docker.sh"

# Configuration URLs
URL_SSH_PUBLIC_KEY="https://raw.githubusercontent.com/kobbilevi/Linux/refs/heads/main/SSHKey-FingerPrint.txt"
URL_DOCKER_COMPOSE="https://raw.githubusercontent.com/kobbilevi/Linux/refs/heads/main/Forgejo-docker-compose.yml"
DOCKER_SCRIPT_URL="https://raw.githubusercontent.com/kobbilevi/Linux/refs/heads/main/Alpine-Install-Docker-And-Docker-Compose.sh"

echo "=== Starting Initial Setup Script ==="

echo "=== 1. Updates & Package Installation ==="
apk update && apk upgrade
apk add nano openssh-server git wget

echo "Target directory for downloads: ${SCRIPT_DIR}"

# 2. Download and save the Docker script locally
echo "Downloading Docker installation script..."
wget -O "$DOCKER_SCRIPT_PATH" "$DOCKER_SCRIPT_URL"

echo "Making the Docker script executable..."
chmod +x "$DOCKER_SCRIPT_PATH"

# 3. Execute the Docker script
echo "Executing Docker installation script..."
"$DOCKER_SCRIPT_PATH"

echo "=== Resuming Main Initialization Script ==="
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

echo "=== 4. Setting up Forgejo Workspace Dynamically ==="
# Automatically detect the non-root user who invoked the script via doas or sudo
REAL_USER=${DOAS_USER:-${SUDO_USER:-$(whoami)}}
REAL_HOME=$(eval echo "~$REAL_USER")
TARGET_DIR="${REAL_HOME}/forgejo-server"

echo "Creating workspace for user '${REAL_USER}' at '${TARGET_DIR}'"
mkdir -p "${TARGET_DIR}/forgejo-data"
mkdir -p "${TARGET_DIR}/backups"

echo "Downloading official Forgejo docker-compose config..."
wget -O "${TARGET_DIR}/docker-compose.yml" "$URL_DOCKER_COMPOSE"

echo "Fixing file and directory permissions..."
# Parent directory and compose file owned by the real user
chown -R "${REAL_USER}:${REAL_USER}" "${TARGET_DIR}"
# Data directory owned by UID 1000 (Internal Docker Forgejo User)
chown -R 1000:1000 "${TARGET_DIR}/forgejo-data"

echo "=== 5. Starting Forgejo ==="
cd "${TARGET_DIR}"
docker-compose up -d

echo "=================================================="
echo "======= All setups completed successfully! ======="
echo " Installation complete! Forgejo is running."
echo "=================================================="
