#!/bin/sh
#genetate archlinux arm rpi image: chmod +x gen-arch_rpi.sh && sudo ./gen-arch_rpi.sh
#depends: arch-install-scripts, vim(xxd)

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
	Usage: gen-arch_rpi.sh [options]
	Valid options are:
		-m ARCH_MIRROR          URI of the mirror to fetch packages from
		                        (default is https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm).
		-o OUTPUT_IMG           Output img file
		                        (default is BUILD_DATE-arch-rpi-xfce4-mods.img).
		-h                      Show this help message and exit.
EOF
}

while getopts 'm:o:h' OPTION; do
	case "$OPTION" in
		m) ARCH_MIRROR="$OPTARG";;
		o) OUTPUT="$OPTARG";;
		h) usage; exit 0;;
	esac
done 

: ${ARCH_MIRROR:="https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm"}
: ${OUTPUT_IMG:="${BUILD_DATE}-arch-rpi-xfce4-mods.img"}

#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 4 * 1024 * 1024 *1024 )) "$OUTPUT_IMG"
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
	sed -i "5i Server = ${ARCH_MIRROR}/\$arch/\$repo" /etc/pacman.d/mirrorlist
}

delete_mirrors() {
	sed -i '5d' /etc/pacman.d/mirrorlist
}

do_pacstrap() {
	pacstrap mnt base base-devel 
}

gen_resize2fs_once_service() {
	cat > /etc/systemd/system/resize2fs-once.service <<'EOF'
[Unit]
Description=Resize the root filesystem to fill partition
DefaultDependencies=no
Conflicts=shutdown.target
After=systemd-remount-fs.service
Before=systemd-sysusers.service sysinit.target shutdown.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/resize2fs_once
StandardOutput=tty
StandardInput=tty
StandardError=tty
[Install]
WantedBy=sysinit.target
EOF

	cat > /usr/local/bin/resize2fs_once <<'EOF'
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
systemctl disable resize2fs-once
EOF

chmod +x /usr/local/bin/resize2fs_once
systemctl enable resize2fs-once
}

gen_fstabs() {
	echo "# Static information about the filesystems.
# See fstab(5) for details.

# <file system> <dir> <type> <options> <dump> <pass>
/dev/mmcblk0p1  /boot   vfat    defaults        0       0
"
}

gen_env() {
	echo "LOOP_DEV=${LOOP_DEV}"
}

install_bootloader() {
	pacman -S --noconfirm raspberrypi-bootloader raspberrypi-bootloader-x
}

gen_config_txt() {
	cat > /boot/config.txt <<EOF
# See /boot/overlays/README for all available options

gpu_mem=64
initramfs initramfs-linux.img followkernel

# to take advantage of your high speed sd card
dtparam=sd_overclock=100

# use drm backend
#dtoverlay=vc4-fkms-v3d

# have a properly sized image
disable_overscan=1

# for sound over HDMI
hdmi_drive=2

# Enable audio (loads snd_bcm2835)
dtparam=audio=on
EOF
}

add_sudo_user() {
	useradd -m -G wheel -s /bin/bash alarm
	echo "alarm:alarm" | chpasswd
	echo "alarm ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
	pacman -S --noconfirm polkit
}

install_kernel() {
	pacman -S --noconfirm linux-raspberrypi
}

enable_systemd_timesyncd() {
	systemctl enable systemd-timesyncd.service
}

add_vchiq_udev_rules() {
        cat <<'EOF'
SUBSYSTEM=="vchiq|input", MODE="0777"
KERNEL=="mouse*|mice|event*",  MODE="0777"
EOF
}

install_packer() {
        su alarm sh -c 'cd /tmp && \
        wget https://github.com/archlinuxarm/PKGBUILDs/raw/a1ad4045699093b1cf4911b93cbf8830ee972639/aur/packer/PKGBUILD && \
        makepkg -si --noconfirm'
}

aur_install_packages() {
	su alarm <<-EOF
	packer -S --noconfirm $@
	EOF
}

install_drivers() {
	pacman -S --noconfirm raspberrypi-firmware firmware-raspberrypi xf86-video-fbdev
	aur_install_packages pi-bluetooth
}

install_sddm() {
	pacman -S --noconfirm sddm
	sddm --example-config > /etc/sddm.conf
	sed -i "s/^User=/User=alarm/" /etc/sddm.conf
	sed -i "s/^Session=/Session=xfce.desktop/" /etc/sddm.conf 
	systemctl enable sddm.service 
}

install_network_manager() {
	pacman -S --noconfirm networkmanager crda wireless_tools net-tools
	systemctl enable NetworkManager.service
}

install_ssh_server() {
	pacman -S --noconfirm openssh
	systemctl enable sshd
}

install_browser() {
	pacman -S --noconfirm chromium
}

install_xfce4() {
	pacman -S --noconfirm git xorg-server xorg-xrefresh xfce4 xfce4-goodies \
					xarchiver gvfs gvfs-smb sshfs \
					ttf-roboto arc-gtk-theme \
					blueman pulseaudio-bluetooth pavucontrol \
					network-manager-applet gnome-keyring
	systemctl disable dhcpcd
	install_network_manager
	install_sddm
	systemctl enable bluetooth brcm43438
}

install_xfce4_mods() {
	install_xfce4
	aur_install_packages ttf-roboto-mono
	pacman -S --noconfirm curl wget
	wget https://github.com/yangxuan8282/PKGBUILDs/raw/master/pkgs/paper-icon-theme-1.5.0-2-any.pkg.tar.xz
	pacman -U --noconfirm paper-icon-theme-1.5.0-2-any.pkg.tar.xz && rm -f paper-icon-theme-1.5.0-2-any.pkg.tar.xz
	mkdir -p /usr/share/wallpapers
	curl https://img2.goodfon.com/original/2048x1820/3/b6/android-5-0-lollipop-material-5355.jpg \
					--output /usr/share/wallpapers/android-5-0-lollipop-material-5355.jpg
	su alarm sh -c 'mkdir -p /home/alarm/.config && \
	wget https://github.com/yangxuan8282/dotfiles/archive/master.tar.gz -O- | \
		tar -C /home/alarm/.config -xzf - --strip=2 dotfiles-master/config'
}

install_termite() {
	pacman -S --noconfirm termite
	mkdir -p /home/alarm/.config/termite
	cp /etc/xdg/termite/config /home/alarm/.config/termite/config
	sed -i 's/font = Monospace 9/font = RobotoMono 11/g' /home/alarm/.config/termite/config
	chown -R alarm:alarm /home/alarm/.config
}

install_docker() {
	pacman -S --noconfirm docker docker-compose
	gpasswd -a alarm docker
	systemctl enable docker
}

setup_miscs() {
	ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
	echo "en_US.UTF-8 UTF-8" | tee --append /etc/locale.gen
	locale-gen
	echo LANG=en_US.UTF-8 > /etc/locale.conf
	echo alarm > /etc/hostname
	echo "127.0.1.1    alarm.localdomain    alarm" | tee --append /etc/hosts
}

setup_chroot() {
	arch-chroot mnt /bin/bash <<-EOF
		set -xe
		source /root/env_file
		source /root/functions
		rm -f /root/functions /root/env_file
		pacman -Syu --noconfirm
		pacman-key --init
		pacman-key --populate archlinuxarm
		echo "root:toor" | chpasswd
		add_sudo_user
		install_kernel
		setup_miscs
		gen_resize2fs_once_service
		install_docker
		enable_systemd_timesyncd
		install_packer
		install_drivers
		add_vchiq_udev_rules > /etc/udev/rules.d/raspberrypi.rules
		install_ssh_server
		#install_termite
		install_xfce4_mods
		install_browser
		install_bootloader
		gen_config_txt
EOF
}

umounts() {
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

do_pacstrap

IMGID="$(dd if="${OUTPUT_IMG}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"

BOOT_PARTUUID="${IMGID}-01"
ROOT_PARTUUID="${IMGID}-02"

gen_fstabs > mnt/etc/fstab

gen_env > mnt/root/env_file

pass_function > mnt/root/functions

setup_chroot

umounts

cat >&2 <<-EOF
	---
	Installation is complete
	Flash to usb disk with: dd if=${OUTPUT_IMG} of=/dev/TARGET_DEV bs=4M status=progress
	
EOF
