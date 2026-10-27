#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

server_rootfs=deepin-25-server-arm64.rootfs.tar.xz
desktop_rootfs=deepin-25-desktop-arm64.rootfs.tar.xz

if [[ ${DESKTOP_ONLY} == "Y" ]]; then
    if [[ -f ${desktop_rootfs} ]]; then
        exit 0
    fi
elif [[ ${SERVER_ONLY} == "Y" ]]; then
    if [[ -f ${server_rootfs} ]]; then
        exit 0
    fi
else
    if [[ -f ${server_rootfs} && -f ${desktop_rootfs} ]]; then
        exit 0
    fi
fi

# These env vars can cause issues with chroot
unset TMP
unset TEMP
unset TMPDIR

# Prevent dpkg interactive dialogues
export DEBIAN_FRONTEND=noninteractive

arch=arm64
release=crimson
mirror="${DEEPIN_MIRROR:-https://mirrors.huaweicloud.com/deepin/beige}"
mirror="${mirror%/}"
components="main,commercial,community"
chroot_dir=rootfs
overlay_dir=../overlay

# Fetch the deepin archive key (deepin-keyring) for Release verification
keyring_root="$(pwd)/deepin-keyring"
keyring_file="${keyring_root}/usr/share/keyrings/deepin-archive-crimson-keyring.gpg"

if [[ ! -f ${keyring_file} ]]; then
    echo "==> Fetching deepin-keyring"
    rm -rf "${keyring_root}"
    mkdir -p "${keyring_root}"

    packages_index=deepin-Packages.xz
    curl -fsSL -o "${packages_index}" \
        "${mirror}/dists/${release}/main/binary-${arch}/Packages.xz"

    keyring_deb_path="$(xz -dc "${packages_index}" \
        | awk '/^Package: deepin-keyring$/{found=1} found && /^Filename:/{print $2; exit}')"
    rm -f "${packages_index}"

    if [[ -z ${keyring_deb_path} ]]; then
        echo "Error: deepin-keyring not found in the deepin repository"
        exit 1
    fi

    curl -fsSL -o deepin-keyring.deb "${mirror}/${keyring_deb_path}"
    dpkg-deb -x deepin-keyring.deb "${keyring_root}"
    rm -f deepin-keyring.deb
fi

if [[ ! -f ${keyring_file} ]]; then
    echo "Error: failed to extract the deepin archive key: ${keyring_file}"
    exit 1
fi

# Private debootstrap directory with the deepin suite script
db_dir="$(pwd)/debootstrap"
rm -rf "${db_dir}"
cp -a /usr/share/debootstrap "${db_dir}"
cat > "${db_dir}/scripts/crimson" << 'SUITE'
# debootstrap suite for deepin 25 (crimson), based on Debian 13 rules
mirror_style release
download_style apt
finddebs_style from-indices
variants - buildd fakechroot minbase
keyring /usr/share/keyrings/deepin-archive-crimson-keyring.gpg

if [ -e "$DEBOOTSTRAP_DIR/scripts/debian-common" ]; then
	. "$DEBOOTSTRAP_DIR/scripts/debian-common"
elif [ -e /debootstrap/debian-common ]; then
	. /debootstrap/debian-common
elif [ -e "$DEBOOTSTRAP_DIR/debian-common" ]; then
	. "$DEBOOTSTRAP_DIR/debian-common"
else
	error 1 NOCOMMON "File not found: debian-common"
fi
SUITE
chmod 0644 "${db_dir}/scripts/crimson"

# Clean chroot dir and make sure folder is not mounted
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true
rm -rf ${chroot_dir}
mkdir -p ${chroot_dir}

# arm64 binaries need binfmt on x86_64 hosts
if [ "$(uname -m)" = "x86_64" ] &&
   ! grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
    echo "ARM64 binfmt is not enabled. Install qemu-user-static and enable qemu-aarch64." >&2
    exit 1
fi

DEBOOTSTRAP_DIR="${db_dir}" debootstrap \
    --arch="${arch}" \
    --keyring="${keyring_file}" \
    --components="${components}" \
    "${release}" "${chroot_dir}" "${mirror}/"

# deepin has a single rolling repository, no -updates/-security suites
rm -f ${chroot_dir}/etc/apt/sources.list
mkdir -p ${chroot_dir}/etc/apt/sources.list.d
cat > ${chroot_dir}/etc/apt/sources.list.d/deepin.list << EOF
deb ${mirror}/ ${release} main commercial community
EOF

# Install the deepin archive keys into the rootfs for apt
mkdir -p ${chroot_dir}/etc/apt/trusted.gpg.d
cp -f ${keyring_root}/usr/share/keyrings/*.gpg ${chroot_dir}/etc/apt/trusted.gpg.d/

# Mount the temporary API filesystems
mkdir -p ${chroot_dir}/{proc,sys,run,dev,dev/pts}
mount -t proc /proc ${chroot_dir}/proc
mount -t sysfs /sys ${chroot_dir}/sys
mount -o bind /dev ${chroot_dir}/dev
mount -o bind /dev/pts ${chroot_dir}/dev/pts

# Base system configuration
cat << 'CHROOT' | chroot ${chroot_dir} /bin/bash
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

# Create User
useradd -G sudo -m -s /bin/bash cat
echo 'cat:temppwd' | chpasswd
groupadd -r render 2> /dev/null || true
usermod -aG video,audio,render cat
echo 'root:root' | chpasswd

# allow root login
sed -i '/pam_securetty.so/s/^/# /g' /etc/pam.d/login

# hostname
echo lubancat > /etc/hostname

# set localtime
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo 'Asia/Shanghai' > /etc/timezone
CHROOT

if [[ -f ${overlay_dir}/etc/resolv.conf ]]; then
    cp ${overlay_dir}/etc/resolv.conf ${chroot_dir}/etc/resolv.conf
fi

# Install base packages
packages_server="dmidecode i2c-tools linux-firmware bash-completion man-db nano gnupg \
initramfs-tools tree dosfstools mtools parted ntfs-3g exfat-fuse zip htop pciutils \
lshw lsof hwinfo net-tools openssh-client openssh-server wpasupplicant network-manager \
pigz wget curl lm-sensors bluez gdisk usb-modeswitch usb-modeswitch-data make gcc \
libc6-dev bison libssl-dev flex bc rfkill wireless-regdb python3 python3-pip \
python3-numpy python3-venv cloud-guest-utils kmod usbutils sudo locales \
console-setup systemd-timesyncd ca-certificates dkms device-tree-compiler libdrm2 \
cloud-initramfs-growroot"

cat << CHROOT | chroot ${chroot_dir} /bin/bash
set -eE
trap 'echo Error: in \$0 on line \$LINENO' ERR

apt-get -y update
apt-get -y full-upgrade

apt-get -y install ${packages_server}

localedef -c -f UTF-8 -i zh_CN /usr/lib/locale/zh_CN.UTF-8
update-locale LANG=zh_CN.UTF-8

apt-get -y remove cryptsetup brltty 2> /dev/null || true

apt-get -y autoremove
apt-get -y clean
CHROOT

# Optional Rockchip multimedia debs, disabled by default
if [[ ${DEEPIN_INSTALL_ROCKCHIP_DEBS:-0} == "1" ]]; then
    echo "==> Installing Rockchip multimedia debs"
    mkdir -p ${chroot_dir}/tmp/rockchip-debs
    find ../packages/arm64/ -maxdepth 1 -type f -name "*.deb" \
        -exec cp -f {} ${chroot_dir}/tmp/rockchip-debs/ \;
    set +e
    chroot ${chroot_dir} /bin/bash -c \
        "apt-get -y install /tmp/rockchip-debs/*.deb" && rc=0 || rc=$?
    set -e
    if [[ ${rc} -ne 0 ]]; then
        echo "Warning: Rockchip multimedia debs failed (rc=${rc}), skipped"
        chroot ${chroot_dir} /bin/bash -c "dpkg --configure -a > /dev/null 2>&1 || true"
    fi
    rm -rf ${chroot_dir}/tmp/rockchip-debs
fi

# Hardware overlay (distro independent parts only)
install -D -m 0755 ${overlay_dir}/usr/lib/scripts/board-detect.sh ${chroot_dir}/usr/lib/scripts/board-detect.sh
install -D -m 0755 ${overlay_dir}/usr/lib/scripts/gpu-governor.sh ${chroot_dir}/usr/lib/scripts/gpu-governor.sh
install -D -m 0755 ${overlay_dir}/usr/lib/scripts/alsa-audio-config ${chroot_dir}/usr/lib/scripts/alsa-audio-config

for unit in cpu-governor-performance gpu-governor-performance board-detect \
            lubancat-mount-boot rtc-hym8563 alsa-audio-config; do
    install -D -m 0644 ${overlay_dir}/usr/lib/systemd/system/${unit}.service \
        ${chroot_dir}/usr/lib/systemd/system/${unit}.service
done

install -D -m 0755 ${overlay_dir}/usr/local/sbin/lubancat-mount-boot ${chroot_dir}/usr/local/sbin/lubancat-mount-boot
install -D -m 0755 ${overlay_dir}/usr/local/bin/mac-lookup ${chroot_dir}/usr/local/bin/mac-lookup
install -D -m 0755 ${overlay_dir}/usr/local/bin/ebf-config ${chroot_dir}/usr/local/bin/ebf-config
install -D -m 0644 ${overlay_dir}/etc/mac-lookup/ids.txt ${chroot_dir}/etc/mac-lookup/ids.txt

# Serial console and logs
install -D -m 0644 ${overlay_dir}/etc/profile.d/resize.sh ${chroot_dir}/etc/profile.d/resize.sh
install -D -m 0644 ${overlay_dir}/usr/lib/systemd/system/serial-getty@.service.d/10-term.conf \
    ${chroot_dir}/lib/systemd/system/serial-getty@.service.d/10-term.conf
install -D -m 0644 ${overlay_dir}/etc/systemd/journald.conf.d/console.conf \
    ${chroot_dir}/etc/systemd/journald.conf.d/console.conf

# Network
install -D -m 0644 ${overlay_dir}/etc/udev/rules.d/80-net-setup-link.rules \
    ${chroot_dir}/etc/udev/rules.d/80-net-setup-link.rules
install -D -m 0644 ${overlay_dir}/usr/lib/NetworkManager/conf.d/10-override-wifi-random-mac-disable.conf \
    ${chroot_dir}/etc/NetworkManager/conf.d/10-override-wifi-random-mac-disable.conf
install -D -m 0644 ${overlay_dir}/usr/lib/NetworkManager/conf.d/20-override-wifi-powersave-disable.conf \
    ${chroot_dir}/etc/NetworkManager/conf.d/20-override-wifi-powersave-disable.conf

# initramfs
install -D -m 0644 ${overlay_dir}/etc/initramfs-tools/conf.d/compression.conf \
    ${chroot_dir}/etc/initramfs-tools/conf.d/compression.conf
install -D -m 0644 ${overlay_dir}/etc/initramfs-tools/conf-hooks.d/plymouth \
    ${chroot_dir}/etc/initramfs-tools/conf-hooks.d/plymouth
install -D -m 0755 ${overlay_dir}/etc/initramfs/post-update.d/zz-update-firmware \
    ${chroot_dir}/etc/initramfs/post-update.d/zz-update-firmware
install -D -m 0755 ${overlay_dir}/usr/share/initramfs-tools/hooks/usb_modeswitch \
    ${chroot_dir}/usr/share/initramfs-tools/hooks/usb_modeswitch
install -D -m 0755 ${overlay_dir}/usr/share/initramfs-tools/hooks/rtl-bt \
    ${chroot_dir}/usr/share/initramfs-tools/hooks/rtl-bt

# Rockchip audio UCM: copy only the rockchip-* directories so the deepin ucm.conf
# is not overwritten
mkdir -p ${chroot_dir}/usr/share/alsa/ucm2
for ucm_dir in ${overlay_dir}/usr/share/alsa/ucm2/rockchip-*; do
    cp -r "${ucm_dir}" ${chroot_dir}/usr/share/alsa/ucm2/
done

# Use ext4 for the root partition
sed -i 's/^FSTYPE=auto/FSTYPE=ext4/' ${chroot_dir}/etc/initramfs-tools/initramfs.conf 2> /dev/null || true

# Serial console and performance governor services
chroot ${chroot_dir} /bin/bash -c \
    "systemctl enable cpu-governor-performance gpu-governor-performance board-detect lubancat-mount-boot rtc-hym8563 alsa-audio-config > /dev/null"

# Swapfile
cat << 'CHROOT' | chroot ${chroot_dir} /bin/bash
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR
dd if=/dev/zero of=/tmp/swapfile bs=1024 count=2097152
chmod 600 /tmp/swapfile
mkswap /tmp/swapfile
mv /tmp/swapfile /swapfile
CHROOT

# Let systemd generate the machine-id on first boot
rm -f ${chroot_dir}/var/lib/dbus/machine-id
true > ${chroot_dir}/etc/machine-id

# Umount temporary API filesystems
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

# Tar the server rootfs
if [[ ${DESKTOP_ONLY} != "Y" ]]; then
    echo "==> Packing ${server_rootfs}"
    cd ${chroot_dir} && XZ_OPT="-3 -T0" tar -cpJf ../${server_rootfs} . && cd ..
fi

if [[ ${SERVER_ONLY} == "Y" ]]; then
    exit 0
fi

# Desktop: DDE
mkdir -p ${chroot_dir}/{proc,sys,run,dev,dev/pts}
mount -t proc /proc ${chroot_dir}/proc
mount -t sysfs /sys ${chroot_dir}/sys
mount -o bind /dev ${chroot_dir}/dev
mount -o bind /dev/pts ${chroot_dir}/dev/pts

packages_desktop="xserver-xorg xinit deepin-desktop-environment-core"
if [[ ${DEEPIN_DESKTOP_EXTRAS:-0} == "1" ]]; then
    packages_desktop="${packages_desktop} deepin-desktop-environment-extras"
fi

cat << CHROOT | chroot ${chroot_dir} /bin/bash
set -eE
trap 'echo Error: in \$0 on line \$LINENO' ERR

apt-get -y install ${packages_desktop}

localedef -c -f UTF-8 -i zh_CN /usr/lib/locale/zh_CN.UTF-8
update-locale LANG=zh_CN.UTF-8

apt-get -y autoremove
apt-get -y clean
apt-get -y autoclean
CHROOT

# Boot into the graphical target with lightdm
chroot ${chroot_dir} /bin/bash -c \
    "systemctl enable lightdm > /dev/null && systemctl set-default graphical.target > /dev/null"

# Rebuild initramfs (GPU/audio firmware)
chroot ${chroot_dir} /bin/bash -c "update-initramfs -u"

# Let systemd generate the machine-id on first boot
rm -f ${chroot_dir}/var/lib/dbus/machine-id
true > ${chroot_dir}/etc/machine-id

# Umount temporary API filesystems
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

echo "==> Packing ${desktop_rootfs}"
cd ${chroot_dir} && XZ_OPT="-3 -T0" tar -cpJf ../${desktop_rootfs} . && cd ..

exit 0
