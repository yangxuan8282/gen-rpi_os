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

which wget > /dev/null || die 'please install wget first'

cd "$(dirname "$0")"

DEST=$(pwd)

_distro=$1
mirror="http://mirrors.ustc.edu.cn/alpine"
branch="v3.7"
arch=$2
chroot_dir="$DEST/mnt"

if [ -z "$_distro" ]
	then
		die 'No distro supplied, please choose from: pixel/debian, arch/archlinuxarm/alarm'
fi

: ${arch:="armhf"}

mkdir -p ${chroot_dir}

wget ${mirror}/${branch}/main/${arch}/apk-tools-static-2.9.1-r2.apk

tar -xzf apk-tools-static-*.apk

./sbin/apk.static -X ${mirror}/${branch}/main -U --allow-untrusted --root ${chroot_dir} --initdb add alpine-base

cp /etc/resolv.conf ${chroot_dir}/etc/
mkdir -p ${chroot_dir}/root

mkdir -p ${chroot_dir}/etc/apk
echo "${mirror}/${branch}/main" > ${chroot_dir}/etc/apk/repositories


mount_devices() {
	mount -t proc none ${chroot_dir}/proc
	mount -o bind /sys ${chroot_dir}/sys
	mount -o bind /dev ${chroot_dir}/dev
}

umount_devices() {
	umount ${chroot_dir}/proc
	umount ${chroot_dir}/sys
	umount ${chroot_dir}/dev
}

gen_rpi_pixel_image() {
	chroot ${chroot_dir} /bin/sh <<-EOF
		set -xe
		source /etc/profile
		apk --update add util-linux dosfstools e2fsprogs debootstrap perl vim
		mkdir -p /root/repos/gen-pixel_rpi
		apk add ca-certificates wget && update-ca-certificates
		wget https://github.com/yangxuan8282/gen-rpi_os/raw/master/gen-pixel_rpi.sh -O /root/repos/gen-pixel_rpi/gen-pixel_rpi.sh
		chmod +x /root/repos/gen-pixel_rpi/gen-pixel_rpi.sh
		cd /root/repos/gen-pixel_rpi
		./gen-pixel_rpi.sh
EOF
}

gen_rpi_arch_image() {
	chroot ${chroot_dir} /bin/sh <<-'EOF'
		set -xe
		source /etc/profile
		apk --update add util-linux dosfstools e2fsprogs vim
		echo "http://mirrors.ustc.edu.cn/alpine/v3.7/community" >> /etc/apk/repositories
		apk --update add arch-install-scripts
		apk add ca-certificates wget && update-ca-certificates
		mkdir -p /root/repos/gen-arch_rpi
		wget https://github.com/yangxuan8282/gen-rpi_os/raw/master/gen-arch_rpi.sh -O /root/repos/gen-arch_rpi/gen-arch_rpi.sh
		chmod +x /root/repos/gen-arch_rpi/gen-arch_rpi.sh
		mkdir -p /etc/pacman.d
		wget https://github.com/archlinuxarm/PKGBUILDs/raw/009a908c4bae6b95a82baa89d214c5c22730bea4/core/pacman/pacman.conf -O /etc/pacman.conf
		sed -i 's/Architecture =.*/Architecture = armv7h/' /etc/pacman.conf
		echo "Server = https://mirrors.ustc.edu.cn/archlinuxarm/\$arch/\$repo" > /etc/pacman.d/mirrorlist
		mkdir -p /run/shm
		cd /root/repos/gen-arch_rpi
		./gen-arch_rpi.sh
EOF
}

gen_rpi_alpine_image() {
	chroot ${chroot_dir} /bin/sh <<-'EOF'
		set -xe
		source /etc/profile
		apk --update add util-linux dosfstools e2fsprogs vim apk-tools-static
		mkdir -p /root/repos/gen-alpine_rpi
		apk add ca-certificates wget && update-ca-certificates
		#wget https://github.com/yangxuan8282/gen-rpi_os/raw/master/gen-alpine_rpi.sh 
		wget http://192.168.2.106:8000/gen-alpine_rpi.sh -O /root/repos/gen-alpine_rpi/gen-alpine_rpi.sh
		chmod +x /root/repos/gen-alpine_rpi/gen-alpine_rpi.sh
		cd /root/repos/gen-alpine_rpi
		./gen-alpine_rpi.sh -a $(apk --print)
EOF
}

mount_devices

case $_distro in
	             debian | pixel ) gen_rpi_pixel_image && mv ${chroot_dir}/root/repos/gen-pixel_rpi/*.img ${DEST}/ ;;
	arch | archlinuxarm | alarm ) gen_rpi_arch_image && mv ${chroot_dir}/root/repos/gen-arch_rpi/*.img ${DEST}/ ;;
	                     alpine ) gen_rpi_alpine_image && mv ${chroot_dir}/root/repos/gen-alpine_rpi/*.img ${DEST}/ ;;
	                          * ) die 'Invalid distro, please choose from: pixel/debian, arch/archlinuxarm/alarm ';;
esac

umount_devices
