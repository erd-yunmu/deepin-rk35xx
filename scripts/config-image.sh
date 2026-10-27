#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set"
    exit 1
fi

# deepin 25 image prefix
distro_prefix="deepin-25"

uboot_deb_name="${UBOOT_DEB_NAME:-u-boot-${BOARD}}"
uboot_package="$(basename "$(find "${uboot_deb_name}"_*.deb | sort | tail -n1)")"
if [ ! -e "$uboot_package" ]; then
    echo 'Error: could not find the u-boot .deb file'
    exit 1
fi

linux_image_package="$(basename "$(find linux-image-*.deb | sort | tail -n1)")"
if [ ! -e "$linux_image_package" ]; then
    echo 'Error: could not find the linux image .deb file'
    exit 1
fi

linux_headers_package="$(basename "$(find linux-headers-*.deb | sort | tail -n1)")"
if [ ! -e "$linux_headers_package" ]; then
    echo 'Error: could not find the linux headers .deb file'
    exit 1
fi

camera_package="$(basename "$(find ../packages/camera/ -type f -name "camera_engine_rkaiq_${OVERLAY_PREFIX}_*.deb" | sort | tail -n1)")"
if [ -z "${camera_package}" ] || [ ! -e "../packages/camera/${camera_package}" ]; then
    echo "Error: could not find the camera engine .deb file for ${OVERLAY_PREFIX}"
    exit 1
fi

if [[ ${SERVER_ONLY} == "Y" ]]; then
    target="server"
elif [[ ${DESKTOP_ONLY} == "Y" ]]; then
    target="desktop"
else
    target="server desktop"
fi

# These env vars can cause issues with chroot
unset TMP
unset TEMP
unset TMPDIR

# Prevent dpkg interactive dialogues
export DEBIAN_FRONTEND=noninteractive

# Debootstrap options
chroot_dir=rootfs
overlay_dir=../overlay

for type in $target; do

    # Clean chroot dir and make sure folder is not mounted
    umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
    umount -lf ${chroot_dir}/* 2> /dev/null || true
    rm -rf ${chroot_dir}
    mkdir -p ${chroot_dir}

    tar -xpJf ${distro_prefix}-${type}-arm64.rootfs.tar.xz -C ${chroot_dir}

    # Mount the temporary API filesystems
    mkdir -p ${chroot_dir}/{proc,sys,run,dev,dev/pts}
    mount -t proc /proc ${chroot_dir}/proc
    mount -t sysfs /sys ${chroot_dir}/sys
    mount -o bind /dev ${chroot_dir}/dev
    mount -o bind /dev/pts ${chroot_dir}/dev/pts

    # Run config hook to handle board specific changes
    if [[ $(type -t config_image_hook__"${BOARD}") == function ]]; then
        config_image_hook__"${BOARD}"
    fi 

    # Install the bootloader
    cp "${uboot_package}" ${chroot_dir}/tmp/
    chroot ${chroot_dir} /bin/bash -c "dpkg -i /tmp/${uboot_package} && rm -rf /tmp/*"
    chroot ${chroot_dir} /bin/bash -c "apt-mark hold $(echo "${uboot_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"

    # Install the kernel
    kernel_version="$(echo "${linux_image_package}" | sed -rn 's/linux-image-(.*)_[[:digit:]].*/\1/p')"
    cp "${linux_image_package}" "${linux_headers_package}" ${chroot_dir}/tmp/
    chroot ${chroot_dir} /bin/bash -c "dpkg -i /tmp/{${linux_image_package},${linux_headers_package}} && rm -rf /tmp/*"
    chroot ${chroot_dir} /bin/bash -c "depmod -a ${kernel_version}"
    if [ ! -e "${chroot_dir}/boot/initrd.img-${kernel_version}" ]; then
        chroot ${chroot_dir} /bin/bash -c "update-initramfs -c -k ${kernel_version}"
    fi
    chroot ${chroot_dir} /bin/bash -c "apt-mark hold $(echo "${linux_image_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} /bin/bash -c "apt-mark hold $(echo "${linux_headers_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"

    # Rebuild DKMS modules for the installed kernel only (uname inside chroot
    # reports the host kernel, so the version must be passed explicitly)
    if chroot ${chroot_dir} /bin/bash -c "command -v dkms > /dev/null"; then
        chroot ${chroot_dir} /bin/bash -c "dkms autoinstall -k ${kernel_version}" || \
            echo "Warning: dkms autoinstall failed for ${kernel_version}, skipped"
    fi

    # Install the camera engine (rkaiq) matching the board SoC
    cp "../packages/camera/${camera_package}" ${chroot_dir}/tmp/
    chroot ${chroot_dir} /bin/bash -c "dpkg -i /tmp/${camera_package} && rm -rf /tmp/*"

    # Clean package cache
    chroot ${chroot_dir} /bin/bash -c "apt-get -y autoremove && apt-get -y clean"

    # Copy kernel and initrd for the boot partition
    mkdir -p ${chroot_dir}/boot/firmware/
    cp ${chroot_dir}/boot/initrd.img-* ${chroot_dir}/boot/firmware/initrd.img
    cp ${chroot_dir}/boot/vmlinuz-* ${chroot_dir}/boot/firmware/vmlinuz

    # Copy device trees and overlays for the boot partition
    mkdir -p ${chroot_dir}/boot/firmware/dtbs/
    cp -r ${chroot_dir}/usr/lib/linux-image-*/. ${chroot_dir}/boot/firmware/dtbs/

    # Copy rockchip dedicated audio to system files
    # Only copy the rockchip-* directories to keep the deepin ucm.conf untouched
    mkdir -p ${chroot_dir}/usr/share/alsa/ucm2
    for ucm_dir in ${overlay_dir}/usr/share/alsa/ucm2/rockchip-*; do
        cp -r "${ucm_dir}" ${chroot_dir}/usr/share/alsa/ucm2/
    done

    # Umount temporary API filesystems
    umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
    umount -lf ${chroot_dir}/* 2> /dev/null || true

    # Tar the entire rootfs
    cd ${chroot_dir} && tar -cpf ../${distro_prefix}-${type}-arm64-"${BOARD}".rootfs.tar . && cd ..
    ../scripts/build-image.sh ${distro_prefix}-${type}-arm64-"${BOARD}".rootfs.tar
    rm -f ${distro_prefix}-${type}-arm64-"${BOARD}".rootfs.tar
done
