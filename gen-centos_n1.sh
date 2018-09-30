#!/bin/sh
#genetate centos7 n1 aarch64 image: chmod +x gen-centos_n1.sh && sudo ./gen-centos_n1.sh
#depends: wget, xz, sed, vim(xxd)

set -xe

die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
	exit 1
}

if [ "$(id -u)" -ne 0 ]; then
	die 'This script must be run as root!'
fi

which xxd >/dev/null || exit

BUILD_DATE="$(date +%Y-%m-%d)"

usage() {
	cat <<EOF
	Usage: gen-centos_n1.sh [options]
	Valid options are:
		-o OUTPUT_IMG           Output img file
		                        (default is BUILD_DATE-centos7-n1-aarch64.img).
		-h                      Show this help message and exit.
EOF
}

while getopts 'o:h' OPTION; do
	case "$OPTION" in
		o) OUTPUT_IMG="$OPTARG";;
		h) usage; exit 0;;
	esac
done 

: ${OUTPUT_IMG:="${BUILD_DATE}-centos7-n1-aarch64.img"}


#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 2048 * 1024 *1024 )) "$OUTPUT_IMG"
cat > fdisk.cmd <<-EOF
	o
	n
	p
	1
	
	+128MB
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

setup_mirrors() {
	cp mnt/etc/yum.repos.d/CentOS-Base.repo mnt/etc/yum.repos.d/CentOS-Base.repo.orig
	sed -i 's|mirror.centos.org/altarch|mirrors.tuna.tsinghua.edu.cn/centos-altarch|g' mnt/etc/yum.repos.d/CentOS-Base.repo
}

get_rootfs() {
	#local url="http://vault.centos.org/altarch/7.4.1708/isos/aarch64/CentOS-7-aarch64-rootfs-7.4.1708.tar.xz"
	local url="https://github.com/yangxuan8282/gen-rpi_os/releases/download/centos_roots/CentOS-7-aarch64-rootfs-7.5.1804.tar.xz"
	mkdir -p mnt
	$(wget $url -O- | tar -C mnt -xJf -) || true
}

gen_fstabs() {
	echo "UUID=${BOOT_UUID}  /boot           vfat    defaults          0       2
UUID=${ROOT_UUID}  /               ext4    defaults,noatime  0       1"
}

add_normal_user() {
	yum -y install sudo
	useradd -m -G wheel -s /bin/bash n1
	echo "n1:phicomm" | chpasswd
	echo "n1 ALL=NOPASSWD: ALL" >> /etc/sudoers
}

gen_resizeonce_scripts() {

echo "if [ -f /resize2fs_once ]; then /resize2fs_once ; fi" >> /etc/rc.d/rc.local

chmod +x /etc/rc.d/rc.local

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

remove_default_kernel() {
	yum -y remove kernel kernel-devel
	yum -y remove *firmware*
	rm -rf /boot/*
}

install_kernel() {
	#remove_default_kernel

	#local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/150balbes_kernel/kernel_3.14.29.tar.gz"
	local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/150balbes_kernel/kernel_4.18.7_20180922.tar.gz"

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
	ROOT_UUID=${ROOT_UUID}"
}

setup_chroot() {
	chroot mnt /bin/bash <<-EOF
		set -xe
		source /root/env_file
		source /root/functions
		rm -f /root/functions /root/env_file
		remove_default_kernel
		yum -y install epel-release
		yum -y update
		#echo "root:toor" | chpasswd
		add_normal_user
		echo "phicomm" > /etc/hostname
		echo "127.0.1.1    phicomm phicomm.localdomain" >> /etc/hosts
		yum -y install wget curl nano htop wpa_supplicant crda NetworkManager-wifi
		echo "blacklist btsdio" >> /etc/modprobe.d/blacklist.conf
		ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		gen_resizeonce_scripts
		install_kernel
		sync
		install_uboot
		yum clean all
		rm -rf /tmp/*
EOF
}

mounts() {
	mount -t proc none mnt/proc
	mount -o bind /sys mnt/sys
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

get_rootfs

IMGID="$(dd if="${OUTPUT_IMG}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"

BOOT_UUID=$(blkid ${BOOT_DEV} | cut -f 2 -d '"')
ROOT_UUID=$(blkid ${ROOT_DEV} | cut -f 2 -d '"')

gen_fstabs > mnt/etc/fstab

gen_env > mnt/root/env_file

pass_function > mnt/root/functions

mounts

setup_mirrors

cp /etc/resolv.conf mnt/etc/resolv.conf

setup_chroot

umounts

cat >&2 <<-EOF
	---
	Installation is complete
	Flash to usb disk with: dd if=${OUTPUT_IMG} of=/dev/TARGET_DEV bs=4M status=progress
	
EOF
