#!/bin/sh
#genetate omv [phicomm-n1] image: chmod +x gen-omv_n1.sh && sudo ./gen-omv_n1.sh
#depends: dosfstools debootstrap xz

set -xe

die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
	exit 1
}

if [ "$(id -u)" -ne 0 ]; then
	die 'This script must be run as root!'
fi

export DEBIAN_FRONTEND=noninteractive

BUILD_DATE="$(date +%Y-%m-%d)"

usage() {
	cat <<EOF

	Usage: gen-omv_n1.sh [options]

	Valid options are:
		-b DEBIAN_BRANCH        Debian branch to install (default is stretch).
		-m DEBIAN_MIRROR        URI of the mirror to fetch packages from
					(default is http://mirrors.tuna.tsinghua.edu.cn/debian/).
		-o OUTPUT_IMG           Output img file
					(default is BUILD_DATE-omv-n1--DEBIAN_BRANCH.img).
		-h                      Show this help message and exit.
EOF
}

while getopts 'b:m:o:h' OPTION; do
	case "$OPTION" in
		b) DEBIAN_BRANCH="$OPTARG";;
		m) DEBIAN_MIRROR="$OPTARG";;
		o) OUTPUT_IMG="$OPTARG";;
		h) usage; exit 0;;
	esac
done 

: ${DEBIAN_BRANCH:="stretch"}
: ${DEBIAN_MIRROR:="http://mirrors.tuna.tsinghua.edu.cn/debian/"}
: ${OUTPUT_IMG:="${BUILD_DATE}-omv-n1-${DEBIAN_BRANCH}.img"}

#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 1500 * 1024 *1024 )) "$OUTPUT_IMG"
cat > fdisk.cmd <<-EOF
	o
	n
	p
	1
	
	+128MB
	t
	c
	a
	n
	p
	2
	
	
	w
EOF
fdisk "$OUTPUT_IMG" < fdisk.cmd
rm -f fdisk.cmd
}

do_format() {
	mkfs.vfat  "$BOOT_DEV"
	mkfs.ext4 "$ROOT_DEV"
	mkdir -p mnt
	mount "$ROOT_DEV" mnt
	mkdir -p mnt/boot
	mount "$BOOT_DEV" mnt/boot
}

do_debootstrap() {
	#debootstrap --arch="arm64" "$DEBIAN_BRANCH" mnt "$DEBIAN_MIRROR"
	local url="https://github.com/yangxuan8282/gen-rpi_os/releases/download/debian_rootfs/stretch-arm64_rootfs.tar.xz"
	mkdir -p mnt
	$(wget $url -O- | tar -C mnt -xJf -) || true
}

gen_sources_list() {
	cat <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_BRANCH} main contrib non-free
EOF
}

gen_keyboard_layout() {
	cat <<EOF
# KEYBOARD CONFIGURATION FILE

# Consult the keyboard(5) manual page.

XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""

BACKSPACE="guess"
EOF
}

gen_fstabs() {
	echo "UUID=${BOOT_UUID}  /boot           vfat    defaults          0       2
UUID=${ROOT_UUID}  /               ext4    defaults,noatime  0       1"
}

add_normal_user() {
	echo "root:toor" | chpasswd
	useradd -g sudo -ms /bin/bash n1
	echo "n1:phicomm" | chpasswd
	echo "n1 ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
	sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /home/n1/.bashrc
}

config_network() {
	cat >> /etc/network/interfaces << 'EOF'
# eth0 network interface
auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF
}

install_omv() {
	apt-get update
	apt-get install -y dirmngr
	apt-key adv --keyserver keyserver.ubuntu.com --recv 7E7A6C592EF35D13
	apt-key adv --keyserver keyserver.ubuntu.com --recv 24863F0C716B980B

	cat <<EOF >> /etc/apt/sources.list.d/openmediavault.list
deb http://packages.openmediavault.org/public arrakis main
# deb http://downloads.sourceforge.net/project/openmediavault/packages arrakis main
## Uncomment the following line to add software from the proposed repository.
# deb http://packages.openmediavault.org/public arrakis-proposed main
# deb http://downloads.sourceforge.net/project/openmediavault/packages arrakis-proposed main
## This software is not part of OpenMediaVault, but is offered by third-party
## developers as a service to OpenMediaVault users.
# deb http://packages.openmediavault.org/public arrakis partner
# deb http://downloads.sourceforge.net/project/openmediavault/packages arrakis partner
EOF

export LANG=C
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
apt-get update
apt-get install -y openmediavault-keyring
apt-get update
apt-get --yes --auto-remove --show-upgraded \
    --allow-downgrades --allow-change-held-packages \
    --no-install-recommends \
    --option Dpkg::Options::="--force-confdef" \
    --option DPkg::Options::="--force-confold" \
    install postfix openmediavault
# Initialize the system and database.
#omv-initsystem

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


if [ -f /resize2fs_once ]; then /resize2fs_once && omv-initsystem ; fi

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

install_kernel() {
	local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/150balbes_kernel/kernel_3.14.29.tar.gz"
	#local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/150balbes_kernel/kernel_4.18.7_20180922.tar.gz"

	wget $url
	tar xf *.tar.gz
	cp -R --no-preserve=mode,ownership kernel_*/boot/* /boot/
	cp -a kernel_*/lib/* /lib/
	sed -i "s|root=LABEL=ROOTFS|root=UUID=${ROOT_UUID}|" /boot/uEnv.ini
	rm -rf kernel_*
}

install_uboot() {
	local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/20180917/u-boot.bin"
	wget $url
	dd if=u-boot.bin of=${LOOP_DEV} bs=1 count=442 conv=fsync
	dd if=u-boot.bin of=${LOOP_DEV} bs=512 skip=1 seek=1 conv=fsync
	rm -f u-boot.bin
}

gen_env() {
	echo "LOOP_DEV=${LOOP_DEV}
	export DEBIAN_FRONTEND=noninteractive
	DEBIAN_BRANCH=${DEBIAN_BRANCH}
	ROOT_UUID=${ROOT_UUID}"
}

setup_chroot() {
	chroot mnt /bin/bash <<-EOF
		set -xe
		source /root/env_file
		source /root/functions
		rm -f /root/env_file /root/functions
		ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		apt-get update && apt-get install -y locales sudo
		echo "en_US.UTF-8 UTF-8" | tee --append /etc/locale.gen
		locale-gen
		echo phicomm > /etc/hostname
		echo "127.0.1.1    phicomm.localdomain    phicomm" | tee --append /etc/hosts
		config_network
		install_omv
		add_normal_user
		gen_resizeonce_scripts
		install_kernel
		sync
		install_uboot
		#rm -rf /var/lib/apt/lists/* /tmp/*
		EOF
}

mounts() {
	mount -t proc /proc mnt/proc
	mount -t sysfs /sys mnt/sys
	mount -o bind /dev mnt/dev
}

umounts() {
	umount mnt/dev
	umount mnt/sys
	umount mnt/proc
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

gen_keyboard_layout > mnt/etc/default/keyboard

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
