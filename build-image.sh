#!/bin/bash
#
# build-image.sh
#
# Usage:
#   ./build-image.sh stretch
#   ./build-image.sh bookworm
#

set -euo pipefail

##############################################################################
# CONFIGURATION
##############################################################################

DISTRO="${1:-}"

if [[ "$DISTRO" != "stretch" && "$DISTRO" != "bookworm" ]]; then
    echo "Usage:"
    echo "  $0 stretch"
    echo "  $0 bookworm"
    exit 1
fi

VERSION="${VERSION:-1.12.0}"
BUILD="${BUILD:-388}"

DATE="$(date +%Y%m%d)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(dirname "$SCRIPT_DIR")"

BOOT_SOURCE="${SCRIPT_DIR}/boot/${DISTRO}"
ROOTFS_SOURCE="${SCRIPT_DIR}/rootfs/${DISTRO}"

SYSROOT="/home/buck/sysroots/adsb3-${DISTRO}-armhf"

IMAGE_DIR="${WORK_DIR}/adsb3-images"

BOOT_MNT="${WORK_DIR}/rpios/boot"
ROOTFS_MNT="${WORK_DIR}/rpios/rootfs"
ADSBDATA_MNT="${WORK_DIR}/rpios/adsbdata"

IMAGE_NAME="radair-adsb-${DISTRO}-${VERSION}.${BUILD}-${DATE}.img"
IMAGE_PATH="${IMAGE_DIR}/${IMAGE_NAME}"
COMPRESSED_IMAGE="${IMAGE_PATH}.xz"

BOOT_SIZE_MIB=1024
ROOTFS_SIZE_MIB=6144
IMAGE_SIZE_GIB=14

BOOT_LABEL="boot"
ROOTFS_LABEL="rootfs"
ADSBDATA_LABEL="adsbdata"

##############################################################################
# CHECKS
##############################################################################

echo
echo "============================================================"
echo " RADAIR ADS-B IMAGE BUILDER"
echo "============================================================"
echo "DISTRO      : ${DISTRO}"
echo "BOOT SRC    : ${BOOT_SOURCE}"
echo "ROOTFS SRC  : ${ROOTFS_SOURCE}"
echo "SYSROOT     : ${SYSROOT}"
echo "OUTPUT      : ${COMPRESSED_IMAGE}"
echo "============================================================"
echo

[[ -d "${BOOT_SOURCE}" ]] || {
    echo "[ERROR] Boot source not found"
    exit 1
}

[[ -d "${ROOTFS_SOURCE}" ]] || {
    echo "[ERROR] Rootfs source not found"
    exit 1
}

[[ -d "${SYSROOT}" ]] || {
    echo "[ERROR] Sysroot not found"
    exit 1
}

mkdir -p "${IMAGE_DIR}"
mkdir -p "${BOOT_MNT}"
mkdir -p "${ROOTFS_MNT}"
mkdir -p "${ADSBDATA_MNT}"

##############################################################################
# CLEANUP
##############################################################################

cleanup()
{
    set +e

    sync

    mountpoint -q "${ADSBDATA_MNT}" && sudo umount "${ADSBDATA_MNT}"
    mountpoint -q "${BOOT_MNT}" && sudo umount "${BOOT_MNT}"
    mountpoint -q "${ROOTFS_MNT}" && sudo umount "${ROOTFS_MNT}"

    if [[ -n "${LOOPDEV:-}" ]]; then
        sudo losetup -d "${LOOPDEV}" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

##############################################################################
# CREATE IMAGE
##############################################################################

rm -f "${IMAGE_PATH}"
rm -f "${COMPRESSED_IMAGE}"

echo "[INFO] Creating ${IMAGE_SIZE_GIB}GiB image..."

truncate -s "${IMAGE_SIZE_GIB}G" "${IMAGE_PATH}"

##############################################################################
# LOOP DEVICE
##############################################################################

LOOPDEV=$(sudo losetup --partscan --find --show "${IMAGE_PATH}")

echo "[INFO] Loop device: ${LOOPDEV}"

##############################################################################
# PARTITION TABLE
##############################################################################

echo "[INFO] Creating partition table..."

sudo sfdisk "${LOOPDEV}" <<EOF
label: dos

size=${BOOT_SIZE_MIB}MiB,type=c,bootable
size=${ROOTFS_SIZE_MIB}MiB,type=83
type=83
EOF

sudo partprobe "${LOOPDEV}"

sleep 2

BOOT_DEV="${LOOPDEV}p1"
ROOTFS_DEV="${LOOPDEV}p2"
ADSBDATA_DEV="${LOOPDEV}p3"

##############################################################################
# FILESYSTEMS
##############################################################################

echo "[INFO] Formatting filesystems..."

sudo mkfs.vfat -F32 -n "${BOOT_LABEL}" "${BOOT_DEV}"

sudo mkfs.ext4 \
    -F \
    -L "${ROOTFS_LABEL}" \
    "${ROOTFS_DEV}"

sudo mkfs.ext4 \
    -F \
    -L "${ADSBDATA_LABEL}" \
    "${ADSBDATA_DEV}"

##############################################################################
# MOUNT
##############################################################################

echo "[INFO] Mounting partitions..."

sudo mount "${ROOTFS_DEV}" "${ROOTFS_MNT}"
sudo mount "${BOOT_DEV}" "${BOOT_MNT}"
sudo mount "${ADSBDATA_DEV}" "${ADSBDATA_MNT}"

##############################################################################
# COPY BOOT
##############################################################################

echo "[INFO] Copying boot..."

sudo rsync \
    -rltD \
    --delete \
    --exclude='*.tar.gz' \
    --exclude='System Volume Information' \
    "${BOOT_SOURCE}/" \
    "${BOOT_MNT}/"

##############################################################################
# COPY ROOTFS
##############################################################################

echo "[INFO] Copying rootfs..."

sudo rsync -aHAX \
    --numeric-ids \
    \
    --exclude='/boot/*' \
    --exclude='/opt/adsb/data/*' \
    \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/run/*' \
    --exclude='/tmp/*' \
    --exclude='/mnt/*' \
    --exclude='/media/*' \
    --exclude='/lost+found' \
    \
    --exclude='/var/cache/apt/*' \
    --exclude='/var/tmp/*' \
    --exclude='/var/run/*' \
    --exclude='/var/lock/*' \
    --exclude='/var/log/*' \
    \
    --exclude='/etc/machine-id' \
    --exclude='/var/lib/dbus/machine-id' \
    \
    --exclude='/root/.bash_history' \
    --exclude='/home/*/.bash_history' \
    \
    "${ROOTFS_SOURCE}/" \
    "${ROOTFS_MNT}/"

##############################################################################
# ADSBDATA
##############################################################################

echo "[INFO] Populating adsbdata..."

sudo rsync -aHAX \
    --numeric-ids \
    "${SYSROOT}/opt/adsb/data/" \
    "${ADSBDATA_MNT}/"

##############################################################################
# MOUNTPOINTS
##############################################################################

sudo mkdir -p \
    "${ROOTFS_MNT}/boot/firmware" \
    "${ROOTFS_MNT}/opt/adsb/data"

##############################################################################
# MACHINE ID
##############################################################################

echo "[INFO] Resetting machine-id..."

sudo truncate -s 0 \
    "${ROOTFS_MNT}/etc/machine-id"

sudo rm -f \
    "${ROOTFS_MNT}/var/lib/dbus/machine-id"

##############################################################################
# FSTAB
##############################################################################

echo "[INFO] Generating fstab..."

cat <<EOF | sudo tee "${ROOTFS_MNT}/etc/fstab" >/dev/null
LABEL=${ROOTFS_LABEL}    /               ext4    defaults    0 1
LABEL=${BOOT_LABEL}      /boot/firmware  vfat    defaults    0 2
LABEL=${ADSBDATA_LABEL}  /opt/adsb/data  ext4    defaults    0 2
EOF

##############################################################################
# CMDLINE
##############################################################################

CMDLINE="${BOOT_MNT}/cmdline.txt"

if [[ -f "${CMDLINE}" ]]; then

    echo "[INFO] Updating cmdline.txt..."

    sudo sed -i \
        's#root=[^ ]*#root=/dev/mmcblk0p2#g' \
        "${CMDLINE}"

    if ! grep -q "cfg80211.ieee80211_regdom=IT" "${CMDLINE}"; then
        sudo sed -i \
            's#$# cfg80211.ieee80211_regdom=IT#' \
            "${CMDLINE}"
    fi
fi

##############################################################################
# CLEAN LOGS
##############################################################################

echo "[INFO] Cleaning logs..."

sudo rm -rf "${ROOTFS_MNT}/var/log/"*

##############################################################################
# ZERO FREE SPACE
##############################################################################

echo "[INFO] Zeroing free space in rootfs..."

sudo dd if=/dev/zero \
        of="${ROOTFS_MNT}/zero.fill" \
        bs=1M \
        status=progress || true

sudo rm -f "${ROOTFS_MNT}/zero.fill"

echo "[INFO] Zeroing free space in adsbdata..."

sudo dd if=/dev/zero \
        of="${ADSBDATA_MNT}/zero.fill" \
        bs=1M \
        status=progress || true

sudo rm -f "${ADSBDATA_MNT}/zero.fill"

sync

##############################################################################
# FINALIZE
##############################################################################

echo "[INFO] Unmounting..."

sudo umount "${ADSBDATA_MNT}"
sudo umount "${BOOT_MNT}"
sudo umount "${ROOTFS_MNT}"

sudo losetup -d "${LOOPDEV}"
unset LOOPDEV

sync

##############################################################################
# COMPRESS
##############################################################################

echo
echo "[INFO] Compressing image..."
echo

xz \
    -9 \
    "${IMAGE_PATH}"

##############################################################################
# DONE
##############################################################################

echo
echo "============================================================"
echo " BUILD COMPLETED"
echo "============================================================"
echo "${COMPRESSED_IMAGE}"
echo "============================================================"
echo


