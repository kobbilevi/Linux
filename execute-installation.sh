#!/bin/dash
set -e

echo "===================================================="
echo "Starting Automated Alpine Linux Installation Process"
echo "===================================================="

GITHUB_USER="kobbilevi"
GITHUB_REPO="Linux"
GITHUB_BRANCH="main"

BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/refs/heads/${GITHUB_BRANCH}"

wget -q -O answers.txt "${BASE_URL}/answers.txt"

if [ ! -s answers.txt ]; then
    echo "[-] Error: Failed to download answers.txt"
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
    prompt="$1"
    default="$2"

    printf "%s [%s] (10 seconds): " "$prompt" "$default"

    if read -r -t 10 ANSWER; then
        [ -n "$ANSWER" ] || ANSWER="$default"
    else
        ANSWER="$default"
        printf "\n"
    fi
}

select_with_timeout "Install Alpine as SYS or DATA" "SYS"

case "$(printf '%s' "$ANSWER" | tr '[:upper:]' '[:lower:]')" in
    sys)
        INSTALL_TYPE="sys"
        ;;
    data)
        INSTALL_TYPE="data"
        ;;
    *)
        echo "[-] Invalid selection."
        exit 1
        ;;
esac

select_with_timeout "Use LVM? (yes/no)" "yes"

case "$(printf '%s' "$ANSWER" | tr '[:upper:]' '[:lower:]')" in
    yes|y)
        USE_LVM="yes"
        ;;
    no|n)
        USE_LVM="no"
        ;;
    *)
        echo "[-] Invalid selection."
        exit 1
        ;;
esac

select_with_timeout "Use disk encryption? (yes/no)" "no"

case "$(printf '%s' "$ANSWER" | tr '[:upper:]' '[:lower:]')" in
    yes|y)
        USE_CRYPT="yes"
        ;;
    no|n)
        USE_CRYPT="no"
        ;;
    *)
        echo "[-] Invalid selection."
        exit 1
        ;;
esac

case "${USE_CRYPT}:${USE_LVM}:${INSTALL_TYPE}" in
    no:no:sys)
        DISKOPTS="-m sys $DETECTED_DISK"
        INSTALL_MODE="sys"
        ;;

    no:yes:sys)
        DISKOPTS="-L -m sys $DETECTED_DISK"
        INSTALL_MODE="lvmsys"
        ;;

    yes:no:sys)
        DISKOPTS="-e -m sys $DETECTED_DISK"
        INSTALL_MODE="cryptsys"
        ;;

    yes:yes:sys)
        DISKOPTS="-e -L -m sys $DETECTED_DISK"
        INSTALL_MODE="enclvmsys"
        ;;

    no:no:data)
        DISKOPTS="-m data $DETECTED_DISK"
        INSTALL_MODE="data"
        ;;

    no:yes:data)
        DISKOPTS="-L -m data $DETECTED_DISK"
        INSTALL_MODE="lvmdata"
        ;;

    yes:no:data)
        DISKOPTS="-e -m data $DETECTED_DISK"
        INSTALL_MODE="encdata"
        ;;

    yes:yes:data)
        DISKOPTS="-e -L -m data $DETECTED_DISK"
        INSTALL_MODE="enclvmdata"
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

sed -i "s|^ERASE_DISKS=.*|ERASE_DISKS=\"$DETECTED_DISK\"|g" answers.txt

if [ "$INSTALL_TYPE" = "data" ]; then
    sed -i 's|^LBUOPTS=.*|LBUOPTS="none"|g' answers.txt
    sed -i 's|^APKCACHEOPTS=.*|APKCACHEOPTS="none"|g' answers.txt
else
    sed -i 's|^LBUOPTS=.*|LBUOPTS="none"|g' answers.txt
    sed -i 's|^APKCACHEOPTS=.*|APKCACHEOPTS="none"|g' answers.txt
fi

setup-alpine -f answers.txt

TARGET_ROOT=""
MNT_PREFIX=""

if [ "$INSTALL_TYPE" = "sys" ]; then

    echo "--> Locating installed SYS root..."

    if command -v lvs >/dev/null 2>&1; then
        vgchange -ay >/dev/null 2>&1 || true

        TARGET_ROOT=$(
            lvs --noheadings -o lv_path 2>/dev/null |
            sed 's/^[[:space:]]*//' |
            grep '/lv_root$' |
            head -n 1
        )
    fi

    if [ -z "$TARGET_ROOT" ]; then
        if [ -b "${DETECTED_DISK}2" ]; then
            TARGET_ROOT="${DETECTED_DISK}2"
        elif [ -b "${DETECTED_DISK}3" ]; then
            TARGET_ROOT="${DETECTED_DISK}3"
        fi
    fi

    if [ -z "$TARGET_ROOT" ] || [ ! -b "$TARGET_ROOT" ]; then
        if [ -b "/dev/mapper/root" ]; then
            TARGET_ROOT="/dev/mapper/root"
        else
            echo "[-] Error: Could not locate installed root filesystem."
            exit 1
        fi
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

    mkdir -p /media/lbu

    echo "--> Preparing persistent DATA storage for LBU..."

    if mountpoint -q /var; then
        mount --bind /var /media/lbu
    else
        echo "[-] Error: /var is not mounted."
        exit 1
    fi

    setup-lbu /media/lbu

    mkdir -p /media/lbu/cache/apk

    if [ ! -L /etc/apk/cache ]; then
        setup-apkcache /media/lbu/cache/apk
    fi
fi

echo "--> Configuring password for user '$TARGET_USER'..."

chroot ${MNT_PREFIX:-.} passwd "$TARGET_USER"

echo "--> Updating package indexes..."

chroot ${MNT_PREFIX:-.} apk update

echo "--> Upgrading installed packages..."

chroot ${MNT_PREFIX:-.} apk upgrade

echo "--> Fetching package list..."

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
    echo "--> Committing DATA configuration to LBU..."

    lbu add /etc
    lbu add "/home/$TARGET_USER"

    sync
    lbu commit -d
fi

echo "--> Allowing background processes to finish..."
sleep 2

if [ "$INSTALL_TYPE" = "sys" ]; then
    echo "--> Syncing before cleanup..."
    sync

    echo "--> Unmounting target filesystem..."

    umount /mnt/sys 2>/dev/null || true
    umount /mnt/proc 2>/dev/null || true
    umount /mnt/dev 2>/dev/null || true
    umount /mnt/boot 2>/dev/null || true
    umount /mnt 2>/dev/null || true
fi

if [ "$INSTALL_TYPE" = "data" ]; then
    umount /media/lbu 2>/dev/null || true
fi

echo "--> Final filesystem sync..."
sync

echo "===================================================="
echo "Installation completed successfully!"
echo "===================================================="

echo "--> Rebooting..."
reboot
