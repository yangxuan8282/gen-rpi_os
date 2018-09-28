#!/bin/sh
#genetate alpine edge n1 armhf/aarch64 image: chmod +x gen-alpine_n1.sh && sudo ./gen-alpine_n1.sh
#depends: apk-tools-static, vim(xxd)

set -x

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
	Usage: gen-alpine_n1.sh [options]
	Valid options are:
		-a ALPINE_ARCH          Options: armhf, aarch64.
		-m ALPINE_MIRROR        URI of the mirror to fetch packages from
		                        (default is https://mirrors.tuna.tsinghua.edu.cn/alpine).
		-o OUTPUT_IMG           Output img file
		                        (default is BUILD_DATE-alpine-n1-ARCH.img).
		-h                      Show this help message and exit.
EOF
}

while getopts 'a:m:o:h' OPTION; do
	case "$OPTION" in
		a) ALPINE_ARCH="$OPTARG";;
		m) ALPINE_MIRROR="$OPTARG";;
		o) OUTPUT_IMG="$OPTARG";;
		h) usage; exit 0;;
	esac
done 

: ${ALPINE_ARCH:="$(uname -m)"}
: ${ALPINE_MIRROR:="https://mirrors.tuna.tsinghua.edu.cn/alpine"}
: ${OUTPUT_IMG:="${BUILD_DATE}-alpine-n1-${ALPINE_ARCH}.img"}


#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 350 * 1024 *1024 )) "$OUTPUT_IMG"
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
	#mv mnt/etc/apk/repositories mnt/etc/apk/repositories.old

	for ALPINE_REPOS in main community testing ; do
		echo ${ALPINE_MIRROR}/edge/${ALPINE_REPOS} >> mnt/etc/apk/repositories
	done
}

do_apkstrap() {
	apk.static -X ${ALPINE_MIRROR}/edge/main -U --allow-untrusted --root mnt --initdb add alpine-base
}

gen_fstabs() {
	echo "UUID=${BOOT_UUID}  /boot           vfat    defaults          0       2
UUID=${ROOT_UUID}  /               ext4    defaults,noatime  0       1"
}

add_normal_user() {
	addgroup n1
	adduser -G n1 -s /bin/bash -D n1
	echo "n1:phicomm" | /usr/sbin/chpasswd
	echo "n1 ALL=NOPASSWD: ALL" >> /etc/sudoers
}

add_user_groups() {
	for USER_GROUP in spi i2c gpio; do
		groupadd -f -r $USER_GROUP
	done
	for USER_GROUP in adm dialout cdrom audio users wheel video games plugdev input gpio spi i2c netdev; do
		adduser n1 $USER_GROUP
	done
}

setup_ntp_server() {
	sed -i 's/pool.ntp.org/cn.pool.ntp.org/' /etc/init.d/ntpd
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
partprobe
resize2fs "$ROOT_DEV"
rc-update del resize2fs-once default
#reboot
EOF

chmod +x /etc/init.d/resize2fs-once /usr/bin/resize2fs-once
rc-update add resize2fs-once default
}

make_bash_fancy() {
	su n1 <<-'EOF'
	sh -c 'cat > /home/n1/.profile << "EOF"
	if [ -f "$HOME/.bashrc" ] ; then
	    source $HOME/.bashrc
	fi
	EOF'
	
	wget https://gist.github.com/yangxuan8282/f2537770982a5dec74095ce4f32de59c/raw/ce003332eff55d50738b726f68a1b493c6867594/.bashrc -P /home/n1
	EOF
}

gen_motd() {

	cat > /etc/motd << "EOF"
Welcome to Alpine!

The Alpine Wiki contains a large amount of how-to guides and general
information about administrating Alpine systems.
See <http://wiki.alpinelinux.org>.

This img was created by this scripts: https://git.io/fA9FA

For more info please check here: https://git.io/fA9Fh
                                                                                        
EOF

	cat > /etc/profile.d/motd.sh << "EOF"
#!/bin/sh

my_ip=$(ip route get 1 | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | tail -1)

root_usage=$(df -h / | awk '/\// {print $(NF-1)}')

echo "
  ⚡  MY IP:   ${my_ip}

  ⚡  DISK USAGE:   ${root_usage}

"
EOF

}

install_gotty() {
	local url="https://github.com/yangxuan8282/rpi-aports/raw/master/apks/gotty-1.0.1-r1.apk"
	wget $url
	apk add --allow-untrusted *.apk
	sed -i 's|-u alpine|-u n1|' /etc/init.d/gotty
	sed -i 's|-w.*|--port 1234 -w ssh n1@localhost|' /etc/init.d/gotty
	rc-update add gotty default
	rm -f *.apk
}

install_create_ap() {
	local url="https://github.com/yangxuan8282/rpi-aports/raw/master/apks/create_ap-0.4.6-r1.apk"
	wget $url
	apk add --allow-untrusted --no-cache *.apk
	rm -f *.apk
}

gen_aml_autoscript() {
	cat > /boot/aml_autoscript.cmd <<'EOF'
setenv bootcmd "run start_autoscript; run try_auto_burn; run storeboot;"
setenv start_autoscript "if usb start ; then run start_usb_autoscript; fi; run start_mmc_autoscript;"
setenv start_mmc_autoscript "if fatload mmc 1:a 1020000 s905_autoscript; then autoscr 1020000; fi;"
setenv start_usb_autoscript "if fatload usb 0 1020000 s905_autoscript; then autoscr 1020000; fi; if fatload usb 1 1020000 s905_autoscript; then autoscr 1020000; fi;"
setenv upgrade_step "0"
saveenv
sleep 1
reboot
EOF

}

gen_s905_autoscript() {
	cat > /boot/s905_autoscript.cmd <<'EOF'
setenv env_addr    "0x10400000"
setenv kernel_addr "0x11000000"
setenv initrd_addr "0x13000000"
setenv boot_start booti ${kernel_addr} ${initrd_addr} ${dtb_mem_addr}
if fatload usb 0 ${kernel_addr} vmlinuz-s905d; then if fatload usb 0 ${initrd_addr} uInitrd; then if fatload usb 0 ${env_addr} uEnv.ini; then env import -t ${env_addr} ${filesize};run cmdline_keys;fi; if fatload usb 0 ${dtb_mem_addr} dtb.img; then run boot_start; else store dtb read ${dtb_mem_addr}; run boot_start;fi;fi;fi;
if fatload usb 1 ${kernel_addr} vmlinuz-s905d; then if fatload usb 1 ${initrd_addr} uInitrd; then if fatload usb 1 ${env_addr} uEnv.ini; then env import -t ${env_addr} ${filesize};run cmdline_keys;fi; if fatload usb 1 ${dtb_mem_addr} dtb.img; then run boot_start; else store dtb read ${dtb_mem_addr}; run boot_start;fi;fi;fi;
if fatload mmc 1:a ${kernel_addr} vmlinuz-s905d; then if fatload mmc 1:a ${initrd_addr} uInitrd; then if fatload mmc 1:a ${env_addr} uEnv.ini; then env import -t ${env_addr} ${filesize};run cmdline_keys;fi; if fatload mmc 1:a ${dtb_mem_addr} dtb.img; then run boot_start; else store dtb read ${dtb_mem_addr}; run boot_start;fi;fi;fi;
EOF

}

gen_uEnv_ini() {
	cat > /boot/uEnv.ini <<'EOF'
bootargs=root=LABEL=ROOTFS rootflags=data=writeback rw console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0
EOF

sed -i "s|root=LABEL=ROOTFS|root=UUID=${ROOT_UUID}|" /boot/uEnv.ini

}

install_kernel() {
	local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/4.18.7_alpine/linux-s905d-4.18.7-r3.apk"

	apk add --no-cache uboot-tools
	wget $url
	apk add --allow-untrusted --no-cache linux-*.apk

	rm -f *.apk
}

install_uboot() {

	gen_aml_autoscript

	gen_s905_autoscript

	#apk add --no-cache uboot-tools

	mkimage -C none -A arm -T script -d /boot/aml_autoscript.cmd /boot/aml_autoscript

	mkimage -C none -A arm -T script -d /boot/s905_autoscript.cmd /boot/s905_autoscript

	#mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd -d /boot/initramfs-s905d /boot/uInitrd

	#apk del uboot-tools

	gen_uEnv_ini

	cp /usr/lib/linux*/meson-gxl-s905d-p230.dtb /boot/dtb.img

	local url="https://github.com/yangxuan8282/phicomm-n1/releases/download/20180917/u-boot.bin"
	wget $url
	dd if=u-boot.bin of=${LOOP_DEV} bs=1 count=442 conv=fsync
	dd if=u-boot.bin of=${LOOP_DEV} bs=512 skip=1 seek=1 conv=fsync
	rm -f u-boot.bin

}

install_xorg_driver() {
	apk add --no-cache xorg-server xf86-video-fbdev xf86-input-libinput
}

install_xfce4() {

	install_xorg_driver

	apk add --no-cache xfce4 xfce4-mixer xfce4-wavelan-plugin lxdm paper-icon-theme arc-theme \
		gvfs gvfs-smb sshfs \
        	network-manager-applet gnome-keyring

	mkdir -p /usr/share/wallpapers &&
	curl https://img2.goodfon.com/original/2048x1820/3/b6/android-5-0-lollipop-material-5355.jpg \
		--output /usr/share/wallpapers/android-5-0-lollipop-material-5355.jpg

	su n1 sh -c 'mkdir -p /home/n1/.config && \
	wget https://github.com/yangxuan8282/dotfiles/archive/master.tar.gz -O- | \
		tar -C /home/n1/.config -xzf - --strip=2 dotfiles-master/alpine-config'

	sed -i 's/^# autologin=dgod/autologin=n1/' /etc/lxdm/lxdm.conf
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
	sed -i 's/wpa_supplicant_args=\"/wpa_supplicant_args=\" -u -Dnl80211/' /etc/conf.d/wpa_supplicant
	touch /etc/wpa_supplicant/wpa_supplicant.conf
}

gen_syslog_config() {
	sed s/=\"/=\""-C4048 "/  -i /etc/conf.d/syslog
}

gen_env() {
	echo "LOOP_DEV=${LOOP_DEV}
	ALPINE_ARCH=${ALPINE_ARCH}
	ROOT_UUID=${ROOT_UUID}"
}

setup_chroot() {
	chroot mnt /bin/sh <<-EOF
		set -x
		source /root/env_file
		source /etc/profile
		source /root/functions
		rm -f /root/functions /root/env_file
		echo "root:toor" | chpasswd
		apk --update add sudo
		add_normal_user
		echo "phicomm" > /etc/hostname
		echo "127.0.0.1    localhost" > /etc/hosts
		echo "127.0.1.1    phicomm phicomm.localdomain" >> /etc/hosts
		apk add --no-cache dbus eudev haveged openssh util-linux coreutils shadow e2fsprogs e2fsprogs-extra tzdata
		apk add --no-cache iw wireless-tools crda wpa_supplicant networkmanager
		apk add --no-cache nano htop bash bash-completion curl tar
		apk add --no-cache ca-certificates wget && update-ca-certificates
		setup_openrc_service
		add_user_groups
		gen_nm_config
		gen_wpa_supplicant_config
		echo "options cfg80211 ieee80211_regdom=CN" > /etc/modprobe.d/cfg80211.conf
		echo "blacklist btsdio" >> /etc/modprobe.d/blacklist.conf
		gen_syslog_config
		setup_ntp_server
		ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		install_kernel
		gen_resize2fs_once_service
		gen_motd
		make_bash_fancy
		install_gotty
		install_create_ap
		#install_xfce4
		sync
		install_uboot
		rm -rf /tmp/* /boot/*.cmd
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
	Flash to usb disk with: dd if=${OUTPUT_IMG} of=/dev/TARGET_DEV bs=4M
	
EOF
