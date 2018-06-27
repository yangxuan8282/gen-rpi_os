raspberry pi
---

- binary blobs

arm board dosen't came with BIOS, instead they have blobs from vendor 

and which is closed source

for raspberry pi that is: 

bootcode.bin

fixup.dat

start.elf

we can get it from this repos: https://github.com/raspberrypi/firmware/tree/master/boot

they usually put in `/boot` directory 

- fixup.dat, start.elf: the most common use one

- fixup_cd.dat, start_cd.elf: used when GPU memory is set to 16 MB 

- fixup_x.dat, start_x.elf: with experimental support for more free codecs

- start_db.elf, fixup_db.dat: debug use

- bootloader

usually we don't need bootloader for rpi, but if we want we can install das u-boot and grub2

here is a repos from opensuse member: https://github.com/agraf/rpi-instsd

he chainload the grub2 with u-boot

- kernel
 
	- [upstream](https://github.com/torvalds/linux)

		- rpi zero, zero w, A+, B+: bcm2835_defconfig
 
		- 2B+, 3B 32bit, 3B+ 32bit: multi_v7_defconfig
 
		- 3B 64bit, 3B+ 64bit: defconfig(?)
 
	upstream is from Linux upstream
	
 
	- [downstream](https://github.com/raspberrypi/linux)

		- rpi zero, zero w, A+, B+: bcmrpi_defconfig
 
		- 2B+, 3B 32bit, 3B+ 32bit: bcm2709_defconfig
 
		- 3B 64bit, 3B+ 64bit: bcmrpi3_defconfig

  downstream is from Raspberry Pi Foundation, have better support for raspberry pi board, we usually use this
	

- drivers

	- LAN
		
		- 2B+/3B: `CONFIG_USB_NET_SMSC95XX`
		
		- 3B+: `CONFIG_USB_LAN78XX`
		
	- Wi-Fi
		
		- 3B, zero w: brcmfmac43430-sdio.bin, brcmfmac43430-sdio.txt
		
		- 3B+: brcmfmac43455-sdio.bin, brcmfmac43455-sdio.clm_blob, brcmfmac43455-sdio.txt
		
    also need (CONFIG_MMC_BCM2835_MMC&&CONFIG_BRCMFMAC_USB)
    
    get them from here: https://github.com/RPi-Distro/firmware-nonfree/tree/master/brcm
		
	- Bluetooth
	
		- 3B, zero w: BCM43430A1.hcd
		
		- 3B+: BCM4345C0.hcd
		
    get them from here: https://github.com/RPi-Distro/bluez-firmware/tree/master/broadcom
		
    usually those broadcom firmware should locate in `/lib/firmware/brcm`

- rootfs

