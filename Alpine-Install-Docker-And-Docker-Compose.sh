#!/bin/sh
set -e

# 1. Check if the script is running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (or via sudo)." >&2
    exit 1
fi

echo "=== Starting Docker & Docker Compose installation on Alpine Linux ==="

# 2. Enable the Community Repository
ALPINE_VERSION=$(cut -d. -f1,2 /etc/alpine-release)
REPO_LINE="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community"


if ! grep -q "^${REPO_LINE}" /etc/apk/repositories; then
    echo "Enabling the community repository for version ${ALPINE_VERSION}..."
    # If the line exists but is commented out with '#', uncomment it. Otherwise, append it.
    if grep -q "v${ALPINE_VERSION}/community" /etc/apk/repositories; then
        sed -i "s|#.*v${ALPINE_VERSION}/community|${REPO_LINE}|" /etc/apk/repositories
    else
        echo "${REPO_LINE}" >> /etc/apk/repositories
    fi
fi

# 3. Update package index and install Docker
echo "Updating apk cache and installing packages..."
apk update
apk add docker docker-cli-compose

# 4. Configure and start OpenRC service
echo "Configuring Docker service to start on boot..."
rc-update add docker boot
service docker start

# 5. Verify the installation
echo "=== Installation completed successfully! ==="
docker --version
docker compose version

echo "Tip: To allow a non-root user to run Docker, run: addgroup <username> docker"
