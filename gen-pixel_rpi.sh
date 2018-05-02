#!/bin/sh
#genetate pixel [rpi] image: chmod +x gen-pixel.sh && sudo ./gen-pixel.sh
#depends: dosfstools debootstrap

set -eu

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

	Usage: gen-pixel.sh [options]

	Valid options are:
		-b DEBIAN_BRANCH        Debian branch to install (default is stretch).
		-m DEBIAN_MIRROR        URI of the mirror to fetch packages from
					(default is http://mirrors.ustc.edu.cn/debian/).
		-o OUTPUT_IMG           Output img file
					(default is BUILD_DATE-pixel-rpi-ARCH-DEBIAN_BRANCH.img).
		-h                      Show this help message and exit.
EOF
}

while getopts 'b:m:o:h' OPTION; do
	case "$OPTION" in
		b) DEBIAN_BRANCH="$OPTARG";;
		m) DEBIAN_MIRROR="$OPTARG";;
		o) OUTPUT="$OPTARG";;
		h) usage; exit 0;;
	esac
done 

: ${DEBIAN_BRANCH:="stretch"}
: ${DEBIAN_MIRROR:="http://mirrors.ustc.edu.cn/debian/"}
: ${OUTPUT_IMG:="${BUILD_DATE}-pixel-rpi-${DEBIAN_BRANCH}.img"}

#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 3 * 1024 * 1024 *1024 )) "$OUTPUT_IMG"
cat > fdisk.cmd <<-EOF
	o
	n
	p
	1
	
	+100MB
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
	mkfs.fat -F32 "$BOOT_DEV"
	mkfs.ext4 "$ROOT_DEV"
	mkdir -p mnt
	mount "$ROOT_DEV" mnt
	mkdir -p mnt/boot
	mount "$BOOT_DEV" mnt/boot
}

do_debootstrap() {
	debootstrap --arch="armhf" "$DEBIAN_BRANCH" mnt "$DEBIAN_MIRROR"
}

gen_wpa_supplicant_conf() {
	cat <<EOF
country=CN
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
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
	echo "PARTUUID=${BOOT_PARTUUID}  /boot           vfat    defaults          0       2
PARTUUID=${ROOT_PARTUUID}  /               ext4    defaults,noatime  0       1"
}

add_user_groups() {
	for USER_GROUP in input spi i2c gpio; do
		groupadd -f -r $USER_GROUP
	done
	for USER_GROUP in adm dialout cdrom audio users sudo video games plugdev input gpio spi i2c netdev; do
		adduser pi $USER_GROUP
	done
}

gen_resize2fs_once_scripts() {
	cat <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          resize2fs_once
# Required-Start:
# Required-Stop:
# Default-Start: 3
# Default-Stop:
# Short-Description: Resize the root filesystem to fill partition
# Description:
### END INIT INFO
. /lib/lsb/init-functions
case "$1" in
  start)
    log_daemon_msg "Starting resize2fs_once"
    ROOT_DEV=$(findmnt / -o source -n) &&
    resize2fs $ROOT_DEV &&
    update-rc.d resize2fs_once remove &&
    rm /etc/init.d/resize2fs_once &&
    log_end_msg $?
    ;;
  *)
    echo "Usage: $0 start" >&2
    exit 3
    ;;
esac
EOF
}

gen_cmdline_txt() {
	cat <<EOF
dwc_otg.lpm_enable=0 console=serial0,115200 console=tty1 root=PARTUUID=${ROOT_PARTUUID} rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait quiet init=/usr/lib/raspi-config/init_resize.sh
EOF
}

gen_env() {
	echo "LOOP_DEV=${LOOP_DEV}
	export DEBIAN_FRONTEND=noninteractive
	DEBIAN_BRANCH=${DEBIAN_BRANCH}"
}

setup_chroot() {
	chroot mnt /bin/bash <<-EOF
		set -xe
		source /root/env_file
		source /root/functions
		rm -f /root/env_file /root/functions
		ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		apt-get update && apt-get install -y locales
		echo "en_US.UTF-8 UTF-8" | tee --append /etc/locale.gen
		locale-gen
		echo raspberrypi > /etc/hostname
		echo "127.0.1.1    raspberrypi.localdomain    raspberrypi" | tee --append /etc/hosts
		apt-get install -y dirmngr
		echo "deb http://mirrors.ustc.edu.cn/raspbian/raspbian/ ${DEBIAN_BRANCH} main contrib non-free rpi" > /etc/apt/sources.list
		echo "deb http://mirrors.ustc.edu.cn/archive.raspberrypi.org/debian/ ${DEBIAN_BRANCH} main ui" > /etc/apt/sources.list.d/raspi.list
		apt-key adv --keyserver keyserver.ubuntu.com --recv 9165938D90FDDD2E
		apt-key adv --keyserver keyserver.ubuntu.com --recv 82B129927FA3303E
		apt-get update && apt-get upgrade -y
		apt-get install -y ssh
		apt-get install -y dhcpcd5 wpasupplicant net-tools wireless-tools firmware-atheros firmware-brcm80211 firmware-libertas firmware-misc-nonfree firmware-realtek raspberrypi-net-mods
		apt-get install -y raspberrypi-ui-mods lxterminal rpi-chromium-mods rc-gui raspi-config omxplayer fake-hwclock htop screen geany fcitx-pinyin fonts-wqy-zenhei
		mv /etc/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf
		sed -i '7s|^.*$|  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/games:/usr/games"|' /etc/profile
		useradd -g sudo -ms /bin/bash pi
		add_user_groups
		systemctl set-default graphical.target
		ln -fs /etc/systemd/system/autologin@.service /etc/systemd/system/getty.target.wants/getty@tty1.service
		sed /etc/lightdm/lightdm.conf -i -e "s/^\(#\|\)autologin-user=.*/autologin-user=pi/"
		systemctl enable dhcpcd.service
		echo "pi:raspberry" | chpasswd
		echo "pi ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
		sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /home/pi/.bashrc
		gen_resize2fs_once_scripts > /etc/init.d/resize2fs_once
		chmod +x /etc/init.d/resize2fs_once
		systemctl enable resize2fs_once
		echo "dtparam=audio=yes" > /boot/config.txt
		rm -rf /var/lib/apt/lists/*
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

gen_wpa_supplicant_conf > mnt/etc/wpa_supplicant.conf

gen_keyboard_layout > mnt/etc/default/keyboard

IMGID="$(dd if="${OUTPUT_IMG}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"

BOOT_PARTUUID="${IMGID}-01"
ROOT_PARTUUID="${IMGID}-02"

gen_fstabs > mnt/etc/fstab

gen_cmdline_txt > mnt/boot/cmdline.txt

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
