#!/bin/bash
set -euo pipefail

DISK="/dev/sda"
CRYPT_NAME="cryptroot"
VG_NAME="vg_arch"
PASSWORD="azerty123"
HOSTNAME="archlinux"

### Pré-checks basiques ###
if [[ ! -d /sys/firmware/efi ]]; then
  echo "ERREUR: Le système n'est pas booté en UEFI."
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo "ERREUR: Disque $DISK introuvable."
  lsblk
  exit 1
fi

### Partitionnement (GPT + EFI + LUKS) ###
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sgdisk -n 2:0:0     -t 2:8300 "$DISK"

partprobe "$DISK"
sleep 1

mkfs.fat -F32 "${DISK}1"

### LUKS + LVM ###
echo -n "$PASSWORD" | cryptsetup luksFormat "${DISK}2" -
echo -n "$PASSWORD" | cryptsetup open "${DISK}2" "$CRYPT_NAME" -

pvcreate "/dev/mapper/$CRYPT_NAME"
vgcreate "$VG_NAME" "/dev/mapper/$CRYPT_NAME"

lvcreate -L 25G -n lv_root   "$VG_NAME"
lvcreate -L 20G -n lv_home   "$VG_NAME"
lvcreate -L 10G -n lv_vbox   "$VG_NAME"
lvcreate -L 5G  -n lv_shared "$VG_NAME"
lvcreate -L 10G -n lv_secret "$VG_NAME"
lvcreate -L 4G  -n lv_swap   "$VG_NAME"

mkfs.ext4 "/dev/$VG_NAME/lv_root"
mkfs.ext4 "/dev/$VG_NAME/lv_home"
mkfs.ext4 "/dev/$VG_NAME/lv_vbox"
mkfs.ext4 "/dev/$VG_NAME/lv_shared"
mkswap    "/dev/$VG_NAME/lv_swap"

# LUKS dessus + FS sans de montage auto
echo -n "$PASSWORD" | cryptsetup luksFormat "/dev/$VG_NAME/lv_secret" -
echo -n "$PASSWORD" | cryptsetup open "/dev/$VG_NAME/lv_secret" secretvol -
mkfs.ext4 /dev/mapper/secretvol
cryptsetup close secretvol

### Montage ###
mount "/dev/$VG_NAME/lv_root" /mnt
mkdir -p /mnt/{boot,home,var/lib/virtualbox,srv/shared}
mount "${DISK}1" /mnt/boot
mount "/dev/$VG_NAME/lv_home" /mnt/home
mount "/dev/$VG_NAME/lv_vbox" /mnt/var/lib/virtualbox
mount "/dev/$VG_NAME/lv_shared" /mnt/srv/shared
swapon "/dev/$VG_NAME/lv_swap"

### Installation de base ###
pacstrap /mnt base linux linux-firmware \
  lvm2 cryptsetup sudo vim nano \
  networkmanager i3 i3status dmenu \
  firefox gcc make gdb htop virtualbox

genfstab -U /mnt >> /mnt/etc/fstab

### Chroot ###
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname

systemctl enable NetworkManager
systemctl enable lvm2-monitor

echo "root:$PASSWORD" | chpasswd

useradd -m -G wheel user
useradd -m -G wheel userfils

groupadd -f shared
usermod -aG shared user
usermod -aG shared userfils

echo "user:$PASSWORD" | chpasswd
echo "userfils:$PASSWORD" | chpasswd

chgrp shared /srv/shared
chmod 2770 /srv/shared

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

### mkinitcpio : indispensable pour boot avec LUKS+LVM ###
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

### Bootloader UEFI : systemd-boot ###
bootctl install

# UUID de la partition LUKS (sda2) pour cryptdevice=
CRYPT_UUID=\$(blkid -s UUID -o value ${DISK}2)

cat > /boot/loader/loader.conf <<EOL
default arch
timeout 3
editor no
EOL

cat > /boot/loader/entries/arch.conf <<EOL
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options cryptdevice=UUID=\$CRYPT_UUID:${CRYPT_NAME} root=/dev/${VG_NAME}/lv_root rw
EOL

EOF

echo "Installation terminée avec succès."
echo "Tu peux faire: umount -R /mnt && swapoff -a && reboot"
