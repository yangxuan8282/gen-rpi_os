#!/bin/sh
#genetate alpine edge odroid xu4 image: chmod +x gen-alpine_xu4.sh && sudo ./gen-alpine_xu4.sh
#depends: apk-tools-static, vim(xxd)
#kernel is not inclued

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
	Usage: gen-alpine_rpi.sh [options]
	Valid options are:
		-m ALPINE_MIRROR        URI of the mirror to fetch packages from
		                        (default is https://mirrors.tuna.tsinghua.edu.cn/alpine).
		-o OUTPUT_IMG           Output img file
		                        (default is BUILD_DATE-alpine-odroidxu4.img).
		-h                      Show this help message and exit.
EOF
}

while getopts 'm:o:h' OPTION; do
	case "$OPTION" in
		m) ALPINE_MIRROR="$OPTARG";;
		o) OUTPUT="$OPTARG";;
		h) usage; exit 0;;
	esac
done 

: ${ALPINE_MIRROR:="https://mirrors.tuna.tsinghua.edu.cn/alpine"}
: ${OUTPUT_IMG:="${BUILD_DATE}-alpine-odroidxu4.img"}


#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 700 * 1024 *1024 )) "$OUTPUT_IMG"
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
	mkfs.vfat -n boot "$BOOT_DEV"
	mkfs.ext4 "$ROOT_DEV"
	mkdir -p mnt
	mount "$ROOT_DEV" mnt
	mkdir -p mnt/boot
	mount "$BOOT_DEV" mnt/boot
}

setup_mirrors() {
	#mv mnt/etc/apk/repositories mnt/etc/apk/repositories.old

	for ALPINE_REPOS in main community testing ; do
		echo ${ALPINE_MIRROR}/edge/${ALPINE_REPOS} >> mnt/etc/apk/repositories
	done
}

do_apkstrap() {
	apk.static -X ${ALPINE_MIRROR}/edge/main -U --allow-untrusted --root mnt --initdb add alpine-base
}

gen_fstabs() {
	echo "/dev/mmcblk1p1  /boot           vfat    defaults          0       2
/dev/mmcblk1p2  /               ext4    defaults,noatime  0       1"
}

add_normal_user() {
	addgroup odroid
	adduser -G odroid -s /bin/bash -D odroid
	echo "odroid:odroid" | /usr/sbin/chpasswd
	echo "odroid ALL=NOPASSWD: ALL" >> /etc/sudoers
}

add_user_groups() {
	for USER_GROUP in spi i2c gpio; do
		groupadd -f -r $USER_GROUP
	done
	for USER_GROUP in adm dialout cdrom audio users wheel video games plugdev input gpio spi i2c netdev; do
		adduser odroid $USER_GROUP
	done
}

setup_ntp_server() {
	sed -i 's/pool.ntp.org/cn.pool.ntp.org/' /etc/init.d/ntpd
}

get_uboot() {
	local url="https://github.com/hardkernel/u-boot/raw/odroidxu4-v2017.05/sd_fuse"

	for files in bl1.bin.hardkernel bl2.bin.hardkernel.720k_uboot sd_fusing.sh tzsw.bin.hardkernel u-boot.bin.hardkernel ; do
		wget $url/$files
	done

	chmod +x sd_fusing.sh
	./sd_fusing.sh ${LOOP_DEV}

}

edit_boot_ini() {
	sed -i 's|root=UUID=e139ce78-9841-40fe-8823-96a304a09859|root=/dev/mmcblk1p2|' /boot/boot.ini
}

gen_resize2fs_once_service() {
	cat > /etc/init.d/resize2fs-once <<'EOF'
#!/sbin/openrc-run
command="/usr/bin/resize2fs-once"
command_background=false
depend() {
        after modules
        need localmount
}
EOF

	cat > /usr/bin/resize2fs-once <<'EOF'
#!/bin/sh 
set -xe
ROOT_DEV=$(findmnt / -o source -n)
cat > /tmp/fdisk.cmd <<-EOF
	d
	2
	
	n
	p
	2
	
	
	w
	EOF
fdisk "$(echo "$ROOT_DEV" | sed -E 's/p?2$//')" < /tmp/fdisk.cmd
rm -f /tmp/fdisk.cmd
partprobe
resize2fs "$ROOT_DEV"
rc-update del resize2fs-once default
#reboot
EOF

chmod +x /etc/init.d/resize2fs-once /usr/bin/resize2fs-once
rc-update add resize2fs-once default
}

make_bash_fancy() {
	su odroid <<-'EOF'
	sh -c 'cat > /home/odroid/.profile << "EOF"
	if [ -f "$HOME/.bashrc" ] ; then
	    source $HOME/.bashrc
	fi
	EOF'
	
	wget https://gist.github.com/yangxuan8282/f2537770982a5dec74095ce4f32de59c/raw/ce003332eff55d50738b726f68a1b493c6867594/.bashrc -P /home/odroid
	EOF
}

# take from postmarketOS

setup_openrc_service() {
	setup-udev -n

	for service in devfs dmesg; do
		rc-update add $service sysinit
	done

	for service in modules sysctl hostname bootmisc swclock syslog; do
		rc-update add $service boot
	done

	for service in dbus haveged sshd wpa_supplicant ntpd local networkmanager; do
		rc-update add $service default
	done

	for service in mount-ro killprocs savecache; do
		rc-update add $service shutdown
	done

	mkdir -p /run/openrc
	touch /run/openrc/shutdowntime
}

gen_nm_config() {
	cat > /etc/NetworkManager/conf.d/networkmanager.conf <<EOF
[main]
plugins+=ifupdown
dhcp=dhcpcd
[ifupdown]
managed=true
[logging]
level=INFO
[device-mac-randomization]
wifi.scan-rand-mac-address=yes
EOF
}

gen_wpa_supplicant_config() {
	sed -i 's/wpa_supplicant_args=\"/wpa_supplicant_args=\" -u -Dwext,nl80211/' /etc/conf.d/wpa_supplicant
	touch /etc/wpa_supplicant/wpa_supplicant.conf
}

gen_syslog_config() {
	sed s/=\"/=\""-C4048 "/  -i /etc/conf.d/syslog
}

gen_env() {
	echo "LOOP_DEV=${LOOP_DEV}
	ALPINE_ARCH=${ALPINE_ARCH}"
}

setup_chroot() {
	chroot mnt /bin/sh <<-EOF
		set -xe
		source /root/env_file
		source /etc/profile
		source /root/functions
		rm -f /root/functions
		echo "root:toor" | chpasswd
		apk --update add sudo
		add_normal_user
		echo "odroid" > /etc/hostname
		echo "127.0.0.1    odroid odroid.localdomain" > /etc/hosts
		apk add dbus eudev haveged openssh util-linux coreutils shadow e2fsprogs e2fsprogs-extra tzdata
		apk add iw wireless-tools crda wpa_supplicant networkmanager
		apk add nano htop bash bash-completion curl tar
		apk add ca-certificates wget && update-ca-certificates
		setup_openrc_service
		add_user_groups
		gen_nm_config
		gen_wpa_supplicant_config
		#echo "options cfg80211 ieee80211_regdom=CN" > /etc/modprobe.d/cfg80211.conf
		gen_syslog_config
		setup_ntp_server
		ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		gen_resize2fs_once_service
		make_bash_fancy
		get_uboot
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

do_apkstrap

IMGID="$(dd if="${OUTPUT_IMG}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"

BOOT_PARTUUID="${IMGID}-01"
ROOT_PARTUUID="${IMGID}-02"

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
	Flash to usb disk with: dd if=${OUTPUT_IMG} of=/dev/TARGET_DEV bs=4M
	
EOF
