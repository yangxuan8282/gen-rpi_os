#!/bin/sh
# vim: set ts=4:

set -xe

die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
	exit 1
}

if [ "$(id -u)" -ne 0 ]; then
	die 'This script must be run as root!'
fi

mirror="http://mirrors.ustc.edu.cn/alpine"
branch="v3.7"
arch="armhf"
chroot_dir="mnt"

mkdir -p ${chroot_dir}

wget ${mirror}/${branch}/main/${arch}/apk-tools-static-2.9.1-r2.apk

tar -xzf apk-tools-static-*.apk

./sbin/apk.static -X ${mirror}/${branch}/main -U --allow-untrusted --root ${chroot_dir} --initdb add alpine-base

cp /etc/resolv.conf ${chroot_dir}/etc/
mkdir -p ${chroot_dir}/root

mkdir -p ${chroot_dir}/etc/apk
echo "${mirror}/${branch}/main" > ${chroot_dir}/etc/apk/repositories

mount -t proc none ${chroot_dir}/proc
mount -o bind /sys ${chroot_dir}/sys
mount -o bind /dev ${chroot_dir}/dev

# chroot ${chroot_dir} /bin/sh -l

# apk --update add util-linux dosfstools e2fsprogs debootstrap perl vim
# apk add ca-certificates wget && update-ca-certificates
# mkdir -p /root/repos/gen-pixel_rpi
# cd /root/repos/gen-pixel_rpi
# wget https://github.com/yangxuan8282/gen-rpi_os/raw/master/gen-pixel_rpi.sh && chmod +x gen-pixel_rpi.sh 
# ./gen-pixel_rpi.sh

# apk --update add util-linux dosfstools e2fsprogs vim
# apk add ca-certificates wget && update-ca-certificates
# mkdir -p /root/repos/gen-arch_rpi
# cd /root/repos/gen-arch_rpi
# wget https://github.com/yangxuan8282/gen-rpi_os/raw/master/gen-arch_rpi.sh && chmod +x gen-arch_rpi.sh
# mkdir -p /etc/pacman.d
# wget https://github.com/archlinuxarm/PKGBUILDs/raw/009a908c4bae6b95a82baa89d214c5c22730bea4/core/pacman/pacman.conf -O /etc/pacman.conf
# sed -i 's/Architecture =.*/Architecture = armv7h/' /etc/pacman.conf
# echo "Server = https://mirrors.ustc.edu.cn/archlinuxarm/\$arch/\$repo" > /etc/pacman.d/mirrorlist
# mkdir -p /run/shm
# ./get-arch_rpi.sh
