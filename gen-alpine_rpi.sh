#!/bin/sh
#genetate alpine edge rpi armhf/aarch64 image: chmod +x gen-alpine_rpi.sh && sudo ./gen-alpine_rpi.sh
#depends: apk-tools-static, vim(xxd)

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
		-a ALPINE_ARCH          Options: armhf, aarch64.
		-m ALPINE_MIRROR        URI of the mirror to fetch packages from
		                        (default is https://mirrors.ustc.edu.cn/alpine).
		-o OUTPUT_IMG           Output img file
		                        (default is BUILD_DATE-alpine-rpi-ARCH.img).
		-h                      Show this help message and exit.
EOF
}

while getopts 'a:m:o:h' OPTION; do
	case "$OPTION" in
		a) ALPINE_ARCH="$OPTARG";;
		m) ALPINE_MIRROR="$OPTARG";;
		o) OUTPUT="$OPTARG";;
		h) usage; exit 0;;
	esac
done 

: ${ALPINE_ARCH:="$(uname -m)"}
: ${ALPINE_MIRROR:="https://mirrors.ustc.edu.cn/alpine"}
: ${OUTPUT_IMG:="${BUILD_DATE}-alpine-rpi-${ALPINE_ARCH}.img"}


#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 300 * 1024 *1024 )) "$OUTPUT_IMG"
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
	echo "/dev/mmcblk0p1  /boot           vfat    defaults          0       2
/dev/mmcblk0p2  /               ext4    defaults,noatime  0       1"
}

add_normal_user() {
	addgroup pi
	adduser -G pi -s /bin/bash -D pi
	echo "pi:raspberry" | /usr/sbin/chpasswd
	echo "pi ALL=NOPASSWD: ALL" >> /etc/sudoers
}

add_user_groups() {
	for USER_GROUP in spi i2c gpio; do
		groupadd -f -r $USER_GROUP
	done
	for USER_GROUP in adm dialout cdrom audio users wheel video games plugdev input gpio spi i2c netdev; do
		adduser pi $USER_GROUP
	done
}

gen_config_txt_32b() {
        cat > /boot/config.txt <<EOF
boot_delay=0
gpu_mem=256
gpu_mem_256=64
[pi0]
kernel=vmlinuz-rpi
initramfs initramfs-rpi
[pi1]
kernel=vmlinuz-rpi
initramfs initramfs-rpi
[pi2]
kernel=vmlinuz-rpi2
initramfs initramfs-rpi2
[pi3]
kernel=vmlinuz-rpi2
initramfs initramfs-rpi2
[all]
include usercfg.txt
EOF
}

gen_config_txt_64b() {
        cat > /boot/config.txt <<EOF
boot_delay=0
gpu_mem=256
gpu_mem_256=64

# 64bit-mode
arm_control=0x200

kernel=vmlinuz-rpi
initramfs initramfs-rpi

device_tree_address=0x100
device_tree_end=0x8000

include usercfg.txt
EOF
}

gen_config_txt() {
	case $ALPINE_ARCH in
		armhf) gen_config_txt_32b;;
		aarch64) gen_config_txt_64b;;
	esac
}

gen_usercfg_txt() {
	cat > /boot/usercfg.txt <<EOF
#enable_uart=1

disable_overscan=1

dtparam=sd_overclock=100

# for sound over HDMI
hdmi_drive=2

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

EOF
}

get_rpi_blobs() {
# for branch other than edge, since bootloader package not exist, need to download it directly

	for blobs in bootcode.bin fixup.dat start.elf ; do
		wget -P /boot https://github.com/raspberrypi/firmware/raw/master/boot/${blobs}
	done
#	apk add raspberrypi-bootloader
}

get_rpi_firmware() {
	# since alpine upstream package linux-firmware-brcm have include those firmwares, no need to download it now

	for wifi_fw in 43455-sdio.bin 43455-sdio.clm_blob 43455-sdio.txt ; do
		wget -P /lib/firmware/brcm https://github.com/RPi-Distro/firmware-nonfree/raw/master/brcm/brcmfmac${wifi_fw} 
	done

	for bt_fw in BCM43430A1.hcd BCM4345C0.hcd ; do
		wget -P /lib/firmware/brcm https://github.com/RPi-Distro/bluez-firmware/raw/master/broadcom/${bt_fw}
	done
}

gen_cmdline_txt() {
	echo "root=/dev/mmcblk0p2 modules=loop,squashfs,sd-mod,usb-storage quiet dwc_otg.lpm_enable=0 console=ttyAMA0,115200 console=tty1" > /boot/cmdline.txt
}

setup_ntp_server() {
	sed -i 's/pool.ntp.org/cn.pool.ntp.org/' /etc/init.d/ntpd
}

add_vchiq_udev_rules() {
	mkdir -p /etc/udev/rules.d

	cat > /etc/udev/rules.d/raspberrypi.rules <<"EOF"
SUBSYSTEM=="vchiq|input", MODE="0777"
KERNEL=="mouse*|mice|event*",  MODE="0777"
EOF
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
reboot
EOF

chmod +x /etc/init.d/resize2fs-once /usr/bin/resize2fs-once
rc-update add resize2fs-once default
}

make_bash_fancy() {
	su pi <<-'EOF'
	sh -c 'cat > /home/pi/.profile << "EOF"
	if [ -f "$HOME/.bashrc" ] ; then
	    source $HOME/.bashrc
	fi
	EOF'
	
	wget https://gist.github.com/yangxuan8282/f2537770982a5dec74095ce4f32de59c/raw/ce003332eff55d50738b726f68a1b493c6867594/.bashrc -P /home/pi
	EOF
}

install_kernel() {
	case $ALPINE_ARCH in
		armhf) KERNEL_FLAVOR="linux-rpi linux-rpi2";;
		aarch64) KERNEL_FLAVOR=linux-rpi;;
	esac

	apk add $KERNEL_FLAVOR

	cd /usr/lib/linux-*/
	find . -type f -regex ".*\.dtbo\?$" -exec install -Dm644 {} /boot/{} \;
}

install_xorg_driver() {
	apk add xorg-server xf86-video-fbdev xf86-input-libinput
}

install_xfce4() {

	install_xorg_driver

	apk add xfce4 xfce4-mixer xfce4-wavelan-plugin lxdm paper-icon-theme arc-theme \
		gvfs gvfs-smb sshfs \
        	network-manager-applet gnome-keyring

	mkdir -p /usr/share/wallpapers &&
	curl https://img2.goodfon.com/original/2048x1820/3/b6/android-5-0-lollipop-material-5355.jpg \
		--output /usr/share/wallpapers/android-5-0-lollipop-material-5355.jpg

	su pi sh -c 'mkdir -p /home/pi/.config && \
	wget https://github.com/yangxuan8282/dotfiles/archive/master.tar.gz -O- | \
		tar -C /home/pi/.config -xzf - --strip=2 dotfiles-master/alpine-config'

	sed -i 's/^# autologin=dgod/autologin=pi/' /etc/lxdm/lxdm.conf
	sed -i 's|^# session=/usr/bin/startlxde|session=/usr/bin/startxfce4|' /etc/lxdm/lxdm.conf

	rc-update add lxdm default
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
		echo "raspberrypi" > /etc/hostname
		echo "127.0.0.1    raspberrypi raspberrypi.localdomain" > /etc/hosts
		apk add dbus eudev haveged openssh util-linux coreutils shadow e2fsprogs e2fsprogs-extra tzdata
		apk add iw wireless-tools crda wpa_supplicant networkmanager
		apk add nano htop bash bash-completion curl tar
		apk add ca-certificates wget && update-ca-certificates
		setup_openrc_service
		add_user_groups
		gen_nm_config
		gen_wpa_supplicant_config
		echo "options cfg80211 ieee80211_regdom=CN" > /etc/modprobe.d/cfg80211.conf
		gen_syslog_config
		setup_ntp_server
		ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		install_kernel
		get_rpi_blobs
		#get_rpi_firmware
		add_vchiq_udev_rules
		gen_resize2fs_once_service
		#apk add omxplayer
		gen_cmdline_txt
		gen_config_txt
		gen_usercfg_txt
		make_bash_fancy
		#install_xfce4
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

