#!/bin/sh
#genetate ubuntu phicomm n1 image: chmod +x gen-ubuntu_n1.sh && sudo ./gen-ubuntu_n1.sh
#depends: dosfstools debootstrap

set -xu

die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
	exit 1
}

if [ "$(id -u)" -ne 0 ]; then
	die 'This script must be run as root!'
fi

unset

export DEBIAN_FRONTEND=noninteractive

BUILD_DATE="$(date +%Y-%m-%d)"

usage() {
	cat <<EOF
	Usage: gen-ubuntu.sh [options]
	Valid options are:
        -a ARCH                 Options: armhf, arm64 (default is arm64).
        -b DEBIAN_BRANCH        Debian branch to install (default is bionic).
        -m DEBIAN_MIRROR        URI of the mirror to fetch packages from
                                (default is http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/).
        -o OUTPUT_IMG           Output img file
                                (default is BUILD_DATE-ubuntu-n1-ARCH-DEBIAN_BRANCH.img).
        -h                      Show this help message and exit.
EOF
}

while getopts 'a:b:m:o:h' OPTION; do
	case "$OPTION" in
		a) ARCH="$OPTARG";;
		b) DEBIAN_BRANCH="$OPTARG";;
		m) DEBIAN_MIRROR="$OPTARG";;
		o) OUTPUT="$OPTARG";;
		h) usage; exit 0;;
	esac
done 

: ${DEBIAN_BRANCH:="bionic"}
: ${DEBIAN_MIRROR:="http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/"}
: ${ARCH:="arm64"}
: ${OUTPUT_IMG:="${BUILD_DATE}-ubuntu-n1-${ARCH}-${DEBIAN_BRANCH}.img"}

#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 4900 * 1024 *1024 )) "$OUTPUT_IMG"
cat > fdisk.cmd <<-EOF
	o
	n
	p
	1
	
	+100MB
	t
	c
	n
	p
	2
	
	
	w
EOF
fdisk "$OUTPUT_IMG" < fdisk.cmd
rm -f fdisk.cmd
}

do_format() {
	mkfs.fat -F32 "$BOOT_DEV"
	mkfs.ext4 "$ROOT_DEV"
	mkdir -p mnt
	mount "$ROOT_DEV" mnt
	mkdir -p mnt/boot
	mount "$BOOT_DEV" mnt/boot
}

do_debootstrap() {
	debootstrap --no-check-gpg --arch="$ARCH" "$DEBIAN_BRANCH" mnt "$DEBIAN_MIRROR"
}

gen_sources_list() {
	cat <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_BRANCH} main restricted universe multiverse
deb ${DEBIAN_MIRROR} ${DEBIAN_BRANCH}-updates main restricted universe multiverse
deb ${DEBIAN_MIRROR} ${DEBIAN_BRANCH}-backports main restricted universe multiverse
deb ${DEBIAN_MIRROR} ${DEBIAN_BRANCH}-security main restricted universe multiverse
EOF
}

gen_fstabs() {
	echo "UUID=${BOOT_UUID}  /boot           vfat    defaults          0       2
UUID=${ROOT_UUID}  /               ext4    defaults,noatime  0       1"
}

gen_env() {
	echo "LOOP_DEV=${LOOP_DEV}
	export DEBIAN_FRONTEND=noninteractive
	ARCH=${ARCH}
	DEBIAN_MIRROR=${DEBIAN_MIRROR}
	DEBIAN_BRANCH=${DEBIAN_BRANCH}
	BOOT_UUID=${BOOT_UUID}
	ROOT_UUID=${ROOT_UUID}"
}

gen_resizeonce_scripts() {
	cat > /etc/rc.local <<'EOF'
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.
if [ -f /resize2fs_once ]; then /resize2fs_once ; fi
exit 0
EOF

chmod +x /etc/rc.local

	cat > /resize2fs_once <<'EOF'
#!/bin/sh 
set -x
ROOT_DEV=$(findmnt / -o source -n)
ROOT_START=$(fdisk -l $(echo "$ROOT_DEV" | sed -E 's/p?2$//') | grep "$ROOT_DEV" | awk '{ print $2 }')
cat > /tmp/fdisk.cmd <<-EOF
	d
	2
	
	n
	p
	2
	${ROOT_START}
	
	w
	EOF
fdisk "$(echo "$ROOT_DEV" | sed -E 's/p?2$//')" < /tmp/fdisk.cmd
rm -f /tmp/fdisk.cmd
partprobe &&
resize2fs "$ROOT_DEV" &&
mv /resize2fs_once /usr/local/bin/resize2fs_once
EOF

chmod +x /resize2fs_once

}

install_extras() {
	apt-get install -y openssh-server htop nano net-tools wireless-tools curl wget ca-certificates
}

install_desktop() {
	/etc/init.d/dbus start
	apt-get install -y ubuntu-mate-core ttf-wqy-zenhei fcitx-pinyin
	#apt-get install -y lubuntu-core
	systemctl set-default graphical.target
}

add_sudo_user() {
	apt-get install -y sudo
	useradd -g sudo -ms /bin/bash ubuntu
	echo "ubuntu:ubuntu" | chpasswd
	echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
	sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /home/ubuntu/.bashrc
}

add_dtb() {
	local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/dtb/meson-gxl-s905d-phicomm-n1.dtb"

	wget $url
	mv *.dtb /boot/dtb.img
}

install_kernel() {
	apt-get install -y wget

	local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/150balbes_kernel/kernel_4.18.7_20180922.tar.gz"

	wget $url
	tar xf *.tar.gz
	cp -R --no-preserve=mode,ownership kernel_*/boot/* /boot/
	cp -a kernel_*/lib/* /lib/
	sed -i "s|root=LABEL=ROOTFS|root=UUID=${ROOT_UUID}|" /boot/uEnv.ini
	rm -rf kernel_*
	add_dtb
}

gen_env() {
	echo "LOOP_DEV=${LOOP_DEV}
	ROOT_UUID=${ROOT_UUID}"
}

setup_miscs() {
	ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
	apt-get install -y locales
	echo "en_US.UTF-8 UTF-8" | tee --append /etc/locale.gen
	locale-gen
	echo ubuntu > /etc/hostname
	echo "127.0.1.1    ubuntu.localdomain    ubuntu" | tee --append /etc/hosts
}

setup_chroot() {
	chroot mnt /bin/bash <<-EOF
		set -xe
		source /root/env_file
		source /root/functions
		rm -f /root/env_file /root/functions
		apt-get update && apt-get upgrade -y
		install_kernel
		setup_miscs
		install_extras
		install_desktop
		add_sudo_user
		gen_resizeonce_scripts
		rm -rf /var/lib/apt/lists/*
		EOF
}

mounts() {
	mount -t proc /proc mnt/proc
	mount -t sysfs /sys mnt/sys
	mount -o bind /dev mnt/dev
}

umounts() {
	umount mnt/proc
	umount mnt/sys
	umount mnt/dev
	umount mnt/boot
	umount mnt
	losetup -d "$LOOP_DEV"
}

#=======================  F u n c t i o n s  =======================#

pass_function() {
	sed -nE '/^#===.*F u n c t i o n s.*===#/,/^#===.*F u n c t i o n s.*===#/p' "$0"
}

gen_image

LOOP_DEV=$(losetup --partscan --show --find "${OUTPUT_IMG}")
BOOT_DEV="$LOOP_DEV"p1
ROOT_DEV="$LOOP_DEV"p2

do_format

do_debootstrap

IMGID="$(dd if="${OUTPUT_IMG}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"

BOOT_UUID=$(blkid ${BOOT_DEV} | cut -f 2 -d '"')
ROOT_UUID=$(blkid ${ROOT_DEV} | cut -f 2 -d '"')

gen_fstabs > mnt/etc/fstab

gen_sources_list > mnt/etc/apt/sources.list

gen_env > mnt/root/env_file

pass_function > mnt/root/functions

mounts

setup_chroot

umounts

cat >&2 <<-EOF
	---
	Installation is complete
	Flash to usb disk with: dd if=${OUTPUT_IMG} of=/dev/TARGET_DEV bs=4M status=progress
	
EOF
