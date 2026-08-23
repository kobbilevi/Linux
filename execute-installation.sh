#!/bin/dash
set -e

echo "===================================================="
echo "Starting Automated Alpine Linux Installation Process"
echo "===================================================="

# ====================================================
# GLOBAL CONFIGURATION - EDIT YOUR GITHUB PATHS HERE
# ====================================================
GITHUB_USER="kobbilevi"
GITHUB_REPO="Linux"
GITHUB_BRANCH="main"

# Constructing relative base URL from the variables above
BASE_URL="https://githubusercontent.com{GITHUB_USER}/${GITHUB_REPO}/refs/heads/${GITHUB_BRANCH}"
# ====================================================

# Fetch the raw answer file from GitHub ONLY if it's not already present locally
if [ ! -f "answers.txt" ]; then
    echo "--> Downloading answers.txt from GitHub..."
    wget -O answers.txt "${BASE_URL}/answers.txt"
else
    echo "[+] Using local answers.txt configuration file."
fi

# Prompt interactively for the username right at the start
while [ -z "$TARGET_USER" ]; do
    printf "Enter the username to create (lowercase letters only): "
    read -r TARGET_USER
done

# Ensure the username complies with Linux standards (lowercase verification)
TARGET_USER=$(echo "$TARGET_USER" | tr '[:upper:]' '[:lower:]')
echo "[+] Target deployment user set to: $TARGET_USER"

# Inject the chosen username into the answer file before execution
USEROPTS_INJECTION="-a -u -g audio,input,video,netdev $TARGET_USER"
sed -i "s|TARGET_USER_PLACEHOLDER|$USEROPTS_INJECTION|g" answers.txt

# Dynamically detect the primary physical storage disk drive
echo "--> Detecting primary storage disk..."
DETECTED_DISK=""
for disk in nvme0n1 sda vda sdb vdb; do
    if [ -b "/dev/$disk" ]; then
        if mount | grep -q "/dev/$disk"; then
            continue
        fi
        DETECTED_DISK="/dev/$disk"
        break
    fi
done

if [ -z "$DETECTED_DISK" ] && [ -b "/dev/sda" ]; then
    DETECTED_DISK="/dev/sda"
fi

if [ -z "$DETECTED_DISK" ]; then
    echo "[-] Error: No eligible installation disk was found."
    exit 1
fi
echo "[+] Target installation disk auto-selected: $DETECTED_DISK"

# Inject the detected disk path into the answer file before execution
sed -i "s|TARGET_DISK_PLACEHOLDER|-m lvmsys $DETECTED_DISK|g" answers.txt

# Run the official setup script using the custom answer file
setup-alpine -f answers.txt

echo "--> Mounting the newly created LVM volume partitions..."
mount /dev/vg0/root /mnt
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

echo "--> Configuring Password Security for user 'root'..."
chroot /mnt passwd root

echo "--> Configuring Password Security for user '$TARGET_USER'..."
chroot /mnt passwd "$TARGET_USER"

echo "--> Upgrading system packages to their latest versions..."
chroot /mnt apk update
chroot /mnt apk upgrade

echo "--> Fetching custom package list and installing..."
if [ ! -f "packages.txt" ]; then
    wget -O packages.txt "${BASE_URL}/packages.txt"
fi
cat packages.txt | xargs chroot /mnt apk add

echo "--> Configuring DOAS rules and passwordless exceptions..."
chroot /mnt apk add doas
echo "permit :wheel" > /mnt/etc/doas.d/doas.conf
echo "permit nopass $TARGET_USER cmd apk args update" >> /mnt/etc/doas.d/doas.conf
echo "permit nopass $TARGET_USER cmd apk args upgrade" >> /mnt/etc/doas.d/doas.conf
echo "permit nopass $TARGET_USER cmd reboot" >> /mnt/etc/doas.d/doas.conf
echo "permit nopass $TARGET_USER cmd poweroff" >> /mnt/etc/doas.d/doas.conf

echo "--> Installing and hardening SSH Server..."
chroot /mnt apk add openssh
chroot /mnt rc-update add sshd default

# Dynamic Hardening of the SSH directory and authorized_keys file permissions
USER_HOME_DIR="/mnt/home/$TARGET_USER"
if [ -d "$USER_HOME_DIR/.ssh" ]; then
    echo "--> Hardening SSH permissions for user: $TARGET_USER"
    chmod 700 "$USER_HOME_DIR/.ssh"
    chmod 600 "$USER_HOME_DIR/.ssh/authorized_keys"
    USER_UID=$(chroot /mnt id -u "$TARGET_USER")
    USER_GID=$(chroot /mnt id -g "$TARGET_USER")
    chown -R "$USER_UID:$USER_GID" "$USER_HOME_DIR/.ssh"
else
    echo "[-] Warning: SSH directory for $TARGET_USER was not found."
fi

# Prevent root login and completely drop password authentication over SSH
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /mnt/etc/ssh/sshd_config || true
echo "PasswordAuthentication no" >> /mnt/etc/ssh/sshd_config
echo "PermitRootLogin no" >> /mnt/etc/ssh/sshd_config

echo "===================================================="
echo "Installation completed successfully! Rebooting..."
echo "===================================================="
umount -R /mnt
reboot
