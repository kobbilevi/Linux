#!/bin/dash
set -e

echo "===================================================="
echo "Starting Automated Alpine Linux Installation Process"
echo "===================================================="

GITHUB_USER="kobbilevi"
GITHUB_REPO="Linux"
GITHUB_BRANCH="main"

BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/refs/heads/${GITHUB_BRANCH}"

INSTALL_TYPE_DEFAULT="sys"
USE_LVM_DEFAULT="yes"
USE_CRYPT_DEFAULT="no"

echo "--> Downloading answers.txt..."

wget -q -O answers.txt "${BASE_URL}/answers.txt"

if [ ! -s answers.txt ]; then
    echo "[-] Error: answers.txt is missing or empty."
    exit 1
fi

while [ -z "$TARGET_USER" ]; do
    printf "Enter the username to create: "
    read -r TARGET_USER
done

TARGET_USER=$(printf '%s' "$TARGET_USER" | tr '[:upper:]' '[:lower:]')

case "$TARGET_USER" in
    *[!a-z0-9_-]*|"")
        echo "[-] Error: Invalid username."
        exit 1
        ;;
esac

USEROPTS_INJECTION="-a -u -g audio,input,video,netdev $TARGET_USER"

sed -i "s|TARGET_USER_PLACEHOLDER|$USEROPTS_INJECTION|g" answers.txt

echo "--> Detecting installation disk..."

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

if [ -z "$DETECTED_DISK" ]; then
    echo "[-] Error: No eligible installation disk found."
    exit 1
fi

echo "[+] Installation disk: $DETECTED_DISK"

select_with_timeout()
{
    PROMPT="$1"
    DEFAULT="$2"

    printf "%s [%s] (10 seconds): " "$PROMPT" "$DEFAULT"

    ANSWER=""

    if read -r -t 10 ANSWER; then
        :
    else
        ANSWER="$DEFAULT"
        printf "\n"
    fi

    if [ -z "$ANSWER" ]; then
        ANSWER="$DEFAULT"
    fi
}

select_with_timeout "Install Alpine as SYS or DATA" "$INSTALL_TYPE_DEFAULT"

case "$(printf '%s' "$ANSWER" | tr '[:upper:]' '[:lower:]')" in
    sys)
        INSTALL_TYPE="sys"
        ;;
    data)
        INSTALL_TYPE="data"
        ;;
    *)
        echo "[-] Invalid installation type."
        exit 1
        ;;
esac

select_with_timeout "Use LVM? (yes/no)" "$USE_LVM_DEFAULT"

case "$(printf '%s' "$ANSWER" | tr '[:upper:]' '[:lower:]')" in
    yes|y)
        USE_LVM="yes"
        ;;
    no|n)
        USE_LVM="no"
        ;;
    *)
        echo "[-] Invalid LVM selection."
        exit 1
        ;;
esac

select_with_timeout "Use disk encryption? (yes/no)" "$USE_CRYPT_DEFAULT"

case "$(printf '%s' "$ANSWER" | tr '[:upper:]' '[:lower:]')" in
    yes|y)
        USE_CRYPT="yes"
        ;;
    no|n)
        USE_CRYPT="no"
        ;;
    *)
        echo "[-] Invalid encryption selection."
        exit 1
        ;;
esac

case "${INSTALL_TYPE}:${USE_LVM}:${USE_CRYPT}" in

    sys:no:no)
        INSTALL_MODE="sys"
        DISKOPTS="-m sys $DETECTED_DISK"
        ;;

    sys:yes:no)
        INSTALL_MODE="lvmsys"
        DISKOPTS="-L -m sys $DETECTED_DISK"
        ;;

    sys:no:yes)
        INSTALL_MODE="encsys"
        DISKOPTS="-e -m sys $DETECTED_DISK"
        ;;

    sys:yes:yes)
        INSTALL_MODE="enclvmsys"
        DISKOPTS="-e -L -m sys $DETECTED_DISK"
        ;;

    data:no:no)
        INSTALL_MODE="data"
        DISKOPTS="-m data $DETECTED_DISK"
        ;;

    data:yes:no)
        INSTALL_MODE="lvmdata"
        DISKOPTS="-L -m data $DETECTED_DISK"
        ;;

    data:no:yes)
        INSTALL_MODE="encdata"
        DISKOPTS="-e -m data $DETECTED_DISK"
        ;;

    data:yes:yes)
        INSTALL_MODE="enclvmdata"
        DISKOPTS="-e -L -m data $DETECTED_DISK"
        ;;

esac

echo
echo "===================================================="
echo "Installation Configuration"
echo "===================================================="
echo "Disk:       $DETECTED_DISK"
echo "Type:       $INSTALL_TYPE"
echo "LVM:        $USE_LVM"
echo "Encryption: $USE_CRYPT"
echo "Mode:       $INSTALL_MODE"
echo "DISKOPTS:   $DISKOPTS"
echo "===================================================="
echo

sed -i "s|^DISKOPTS=.*|DISKOPTS=\"$DISKOPTS\"|g" answers.txt

export ERASE_DISKS="$DETECTED_DISK"

if [ "$INSTALL_TYPE" = "sys" ]; then
    echo "--> Installing eject utility in RAM only..."

    if ! command -v eject >/dev/null 2>&1; then
        apk add --no-cache util-linux-misc
    fi
fi

echo "--> Starting Alpine installation..."

setup-alpine -f answers.txt

MNT_PREFIX=""

if [ "$INSTALL_TYPE" = "sys" ]; then

    echo "--> Locating installed SYS root..."

    TARGET_ROOT=""

    if [ "$USE_CRYPT" = "yes" ]; then

        echo
        echo "===================================================="
        echo "Encrypted installation detected."
        echo "Enter the encryption password to unlock the"
        echo "installed system for post-installation."
        echo "===================================================="
        echo

        CRYPT_PART=""

        for part in $(lsblk -lnpo NAME "$DETECTED_DISK" 2>/dev/null); do
            if cryptsetup isLuks "$part" >/dev/null 2>&1; then
                CRYPT_PART="$part"
                break
            fi
        done

        if [ -z "$CRYPT_PART" ]; then
            echo "[-] Error: Could not locate LUKS partition."
            exit 1
        fi

        echo "[+] LUKS device: $CRYPT_PART"
        echo "--> Unlocking encrypted root..."

        cryptsetup open "$CRYPT_PART" root

        if [ "$USE_LVM" = "yes" ]; then
            echo "--> Activating LVM..."

            vgchange -ay

            TARGET_ROOT=$(
                lvs --noheadings --options lv_path 2>/dev/null |
                sed 's/^[[:space:]]*//' |
                grep '/lv_root$' |
                head -n 1
            )
        else
            TARGET_ROOT="/dev/mapper/root"
        fi

    else

        if [ "$USE_LVM" = "yes" ]; then

            echo "--> Activating LVM..."

            vgchange -ay

            TARGET_ROOT=$(
                lvs --noheadings --options lv_path 2>/dev/null |
                sed 's/^[[:space:]]*//' |
                grep '/lv_root$' |
                head -n 1
            )

        else

            if [ -b "${DETECTED_DISK}2" ]; then
                TARGET_ROOT="${DETECTED_DISK}2"
            elif [ -b "${DETECTED_DISK}3" ]; then
                TARGET_ROOT="${DETECTED_DISK}3"
            fi

        fi
    fi

    if [ -z "$TARGET_ROOT" ] || [ ! -b "$TARGET_ROOT" ]; then
        echo "[-] Error: Could not locate installed root filesystem."
        exit 1
    fi

    echo "[+] Installed root: $TARGET_ROOT"

    mount "$TARGET_ROOT" /mnt

    MNT_PREFIX="/mnt"

    if [ -b "${DETECTED_DISK}1" ]; then
        mkdir -p /mnt/boot

        if ! mountpoint -q /mnt/boot; then
            mount "${DETECTED_DISK}1" /mnt/boot 2>/dev/null || true
        fi
    fi

    mkdir -p /mnt/dev /mnt/proc /mnt/sys

    mount --bind /dev /mnt/dev
    mount --bind /proc /mnt/proc
    mount --bind /sys /mnt/sys

else

    echo "[+] DATA installation detected."

    MNT_PREFIX=""

fi

echo "--> Configuring password for user '$TARGET_USER'..."

chroot ${MNT_PREFIX:-.} passwd "$TARGET_USER"

echo "--> Updating package indexes..."

chroot ${MNT_PREFIX:-.} apk update

echo "--> Upgrading installed packages..."

chroot ${MNT_PREFIX:-.} apk upgrade

echo "--> Downloading package list..."

wget -q -O packages.txt "${BASE_URL}/packages.txt"

if [ ! -s packages.txt ]; then
    echo "[-] Error: packages.txt is missing or empty."
    exit 1
fi

echo "--> Installing requested packages..."

chroot ${MNT_PREFIX:-.} apk add $(cat packages.txt)

echo "--> Installing doas..."

chroot ${MNT_PREFIX:-.} apk add doas

DOAS_DIR="${MNT_PREFIX}/etc/doas.d"

mkdir -p "$DOAS_DIR"

echo "permit :wheel" > "$DOAS_DIR/doas.conf"
echo "permit nopass $TARGET_USER cmd apk args update" >> "$DOAS_DIR/doas.conf"
echo "permit nopass $TARGET_USER cmd apk args upgrade" >> "$DOAS_DIR/doas.conf"
echo "permit nopass $TARGET_USER cmd reboot" >> "$DOAS_DIR/doas.conf"
echo "permit nopass $TARGET_USER cmd poweroff" >> "$DOAS_DIR/doas.conf"

echo "--> Installing SSH server..."

chroot ${MNT_PREFIX:-.} apk add openssh

chroot ${MNT_PREFIX:-.} rc-update add sshd default || true

USER_HOME_DIR="${MNT_PREFIX}/home/$TARGET_USER"

if [ -d "$USER_HOME_DIR/.ssh" ]; then

    chmod 700 "$USER_HOME_DIR/.ssh"

    if [ -f "$USER_HOME_DIR/.ssh/authorized_keys" ]; then
        chmod 600 "$USER_HOME_DIR/.ssh/authorized_keys"
    fi

    USER_UID=$(chroot ${MNT_PREFIX:-.} id -u "$TARGET_USER")
    USER_GID=$(chroot ${MNT_PREFIX:-.} id -g "$TARGET_USER")

    chown -R "$USER_UID:$USER_GID" "$USER_HOME_DIR/.ssh"

fi

SSHD_CONFIG="${MNT_PREFIX}/etc/ssh/sshd_config"

if [ -f "$SSHD_CONFIG" ]; then

    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' "$SSHD_CONFIG"

    sed -i 's/^#PermitRootLogin .*/PermitRootLogin no/' "$SSHD_CONFIG"
    sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' "$SSHD_CONFIG"

    grep -q '^PasswordAuthentication no$' "$SSHD_CONFIG" ||
        echo "PasswordAuthentication no" >> "$SSHD_CONFIG"

    grep -q '^PermitRootLogin no$' "$SSHD_CONFIG" ||
        echo "PermitRootLogin no" >> "$SSHD_CONFIG"

fi

if [ "$INSTALL_TYPE" = "data" ]; then

    echo "--> Saving DATA changes with LBU..."

    lbu add /etc
    lbu add "/home/$TARGET_USER"

    sync

    lbu commit -d

fi

echo "--> Waiting for pending operations..."

sleep 2

if [ "$INSTALL_TYPE" = "sys" ]; then

    echo "--> Syncing before cleanup..."

    sync

    echo "--> Unmounting installed system..."

    umount /mnt/sys 2>/dev/null || true
    umount /mnt/proc 2>/dev/null || true
    umount /mnt/dev 2>/dev/null || true
    umount /mnt/boot 2>/dev/null || true
    umount /mnt 2>/dev/null || true

    if [ "$USE_LVM" = "yes" ]; then
        vgchange -an >/dev/null 2>&1 || true
    fi

    if [ "$USE_CRYPT" = "yes" ]; then
        cryptsetup close root >/dev/null 2>&1 || true
    fi

    if command -v eject >/dev/null 2>&1; then

        echo "--> Ejecting installation media..."

        if [ -e /dev/cdrom ]; then
            eject /dev/cdrom >/dev/null 2>&1 || true
        else
            eject >/dev/null 2>&1 || true
        fi

    fi

fi

sync

echo "===================================================="
echo "Installation completed successfully!"
echo "===================================================="

echo "--> Rebooting..."

reboot
