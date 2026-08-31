#!/bin/dash
set -e

echo "===================================================="
echo "Starting Automated Alpine Linux Installation Process"
echo "===================================================="

GITHUB_USER="kobbilevi"
GITHUB_REPO="Linux"
GITHUB_BRANCH="main"

BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/refs/heads/${GITHUB_BRANCH}"

wget -O answers.txt "${BASE_URL}/answers.txt"

while [ -z "$TARGET_USER" ]; do
    printf "Enter the username to create (lowercase letters only): "
    read -r TARGET_USER
done

TARGET_USER=$(echo "$TARGET_USER" | tr '[:upper:]' '[:lower:]')
echo "[+] Target deployment user set to: $TARGET_USER"

USEROPTS_INJECTION="-a -u -g audio,input,video,netdev $TARGET_USER"

sed -i "s|TARGET_USER_PLACEHOLDER|$USEROPTS_INJECTION|g" answers.txt

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

# Installation mode:
# sys
# data
# lvmsys
# lvmdata
# cryptsys
# enclvmsys
#
# You can change this value in the wrapper.
INSTALL_MODE="lvmsys"

case "$INSTALL_MODE" in
    sys)
        DISKOPTS="-m sys $DETECTED_DISK"
        ;;

    data)
        DISKOPTS="-m data $DETECTED_DISK"
        ;;

    lvmsys)
        DISKOPTS="-L -m sys $DETECTED_DISK"
        ;;

    lvmdata)
        DISKOPTS="-L -m data $DETECTED_DISK"
        ;;

    cryptsys)
        DISKOPTS="-e -m sys $DETECTED_DISK"
        ;;

    enclvmsys)
        DISKOPTS="-e -L -m sys $DETECTED_DISK"
        ;;

    enclvmdata)
        DISKOPTS="-e -L -m data $DETECTED_DISK"
        ;;

    cryptdata)
        DISKOPTS="-e -m data $DETECTED_DISK"
        ;;

    *)
        echo "[-] Error: Unsupported installation mode: $INSTALL_MODE"
        exit 1
        ;;
esac

echo "[+] Installation mode: $INSTALL_MODE"
echo "[+] DISKOPTS: $DISKOPTS"

sed -i "s|^DISKOPTS=.*|DISKOPTS=\"$DISKOPTS\"|g" answers.txt

export ERASE_DISKS="$DETECTED_DISK"

echo
echo "Final disk configuration:"
grep '^DISKOPTS=' answers.txt
echo "ERASE_DISKS=$ERASE_DISKS"
echo

setup-alpine -f answers.txt

echo "--> Analyzing installation output to locate root partition..."

umount -R /mnt 2>/dev/null || true

if [ -b "/dev/mapper/root" ] || [ -d "/dev/mapper" ] && ls /dev/mapper/crypt-* 2>/dev/null; then
    echo "[+] Encrypted partition layout detected."
    TARGET_ROOT=$(ls -1 /dev/mapper/root /dev/mapper/crypt-* 2>/dev/null | head -n 1)

elif [ -d "/dev/vg0" ] || vgscan 2>/dev/null | grep -q "Found volume group"; then
    echo "[+] LVM layout detected. Activating Volume Groups..."
    vgscan >/dev/null 2>&1
    vgchange -ay >/dev/null 2>&1

    if [ -b "/dev/vg0/lv_root" ]; then
        TARGET_ROOT="/dev/vg0/lv_root"
    elif [ -b "/dev/vg0/root" ]; then
        TARGET_ROOT="/dev/vg0/root"
    else
        TARGET_ROOT=$(ls -1 /dev/vg0/* | head -n 1)
    fi

elif [ -b "${DETECTED_DISK}2" ]; then
    echo "[+] Standard 'sys' layout detected."
    TARGET_ROOT="${DETECTED_DISK}2"

elif [ -b "${DETECTED_DISK}1" ]; then
    echo "[+] 'data' layout detected."
    TARGET_ROOT="LIVE_MODE"

else
    echo "[-] Error: Could not determine the installed root file system partition."
    exit 1
fi

if [ "$TARGET_ROOT" = "LIVE_MODE" ]; then
    MNT_PREFIX=""
else
    echo "[+] Mounting root partition ($TARGET_ROOT) to /mnt..."
    mount "$TARGET_ROOT" /mnt
    MNT_PREFIX="/mnt"

    if [ -b "${DETECTED_DISK}1" ] && [ "${DETECTED_DISK}1" != "$TARGET_ROOT" ]; then
        echo "--> Mounting boot partition (${DETECTED_DISK}1)..."
        mkdir -p /mnt/boot
        mount "${DETECTED_DISK}1" /mnt/boot
    fi

    echo "--> Binding system API directories..."
    mount --bind /dev /mnt/dev
    mount --bind /proc /mnt/proc
    mount --bind /sys /mnt/sys
fi

echo "--> Configuring Password Security for user '$TARGET_USER'..."
chroot ${MNT_PREFIX:-.} passwd "$TARGET_USER"

echo "--> Upgrading system packages to their latest versions..."
chroot ${MNT_PREFIX:-.} apk update
chroot ${MNT_PREFIX:-.} apk upgrade

echo "--> Fetching custom package list and installing..."

if [ ! -f "packages.txt" ]; then
    wget -O packages.txt "${BASE_URL}/packages.txt"
fi

cat packages.txt | xargs chroot ${MNT_PREFIX:-.} apk add

echo "--> Configuring DOAS rules and passwordless exceptions..."

chroot ${MNT_PREFIX:-.} apk add doas

echo "permit :wheel" > ${MNT_PREFIX}/etc/doas.d/doas.conf
echo "permit nopass $TARGET_USER cmd apk args update" >> ${MNT_PREFIX}/etc/doas.d/doas.conf
echo "permit nopass $TARGET_USER cmd apk args upgrade" >> ${MNT_PREFIX}/etc/doas.d/doas.conf
echo "permit nopass $TARGET_USER cmd reboot" >> ${MNT_PREFIX}/etc/doas.d/doas.conf
echo "permit nopass $TARGET_USER cmd poweroff" >> ${MNT_PREFIX}/etc/doas.d/doas.conf

echo "--> Installing and hardening SSH Server..."

chroot ${MNT_PREFIX:-.} apk add openssh
chroot ${MNT_PREFIX:-.} rc-update add sshd default || true

USER_HOME_DIR="${MNT_PREFIX}/home/$TARGET_USER"

if [ -d "$USER_HOME_DIR/.ssh" ]; then
    echo "--> Hardening SSH permissions for user: $TARGET_USER"

    chmod 700 "$USER_HOME_DIR/.ssh"
    chmod 600 "$USER_HOME_DIR/.ssh/authorized_keys"

    USER_UID=$(chroot ${MNT_PREFIX:-.} id -u "$TARGET_USER")
    USER_GID=$(chroot ${MNT_PREFIX:-.} id -g "$TARGET_USER")

    chown -R "$USER_UID:$USER_GID" "$USER_HOME_DIR/.ssh"
else
    echo "[-] Warning: SSH directory for $TARGET_USER was not found."
fi

sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' ${MNT_PREFIX}/etc/ssh/sshd_config || true

echo "PasswordAuthentication no" >> ${MNT_PREFIX}/etc/ssh/sshd_config
echo "PermitRootLogin no" >> ${MNT_PREFIX}/etc/ssh/sshd_config

if [ "$TARGET_ROOT" = "LIVE_MODE" ]; then
    echo "--> Mode DATA detected: Saving state with lbu commit..."
    lbu commit -d
fi

echo "===================================================="
echo "Installation completed successfully! Rebooting..."
echo "===================================================="

if [ "$TARGET_ROOT" != "LIVE_MODE" ]; then
    umount -R /mnt
fi

reboot
