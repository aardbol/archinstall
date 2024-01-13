#!/bin/bash

# Stop the script if any command fails
set -e

CUSTOM_USER=
LOCALE=
HOSTNAME=
KEYBOARD=
TIMEZONE=
NVME_DRIVE=/dev/nvme0n1
EFI_PART_SIZE=550MiB
BTRFS_PART_SIZE=50GiB
MOUNT_POINT=/mnt
CRYPT_NAME=luks
ENABLE_SWAPFILE=true
REFLECTOR_COUNTRIES=France,Germany
INSTALL_PACKAGES="plasma plasma-wayland-session networkmanager-iwd nftables iptables-nft manjaro-zsh-config pikaur kate gwenview konsole kcalc okular firefox kdeconnect kamoso okular skanlite kleopatra partitionmanager dolphin ark zstd bluez bluez-utils bluedevil pipewire-pulse print-manager kwalletmanager kdialog filelight ffmpegthumbs kdegraphics-thumbnailers dosfstools exfat-utils xorg-xeyes keepassxc noto-fonts-emoji exa ttf-ubuntu-font-family man-db nvme-cli openbsd-netcat nmap bind p7zip whois usbutils ttf-roboto-mono pacman-contrib fuse2 xdg-desktop-portal rsync apparmor zoxide ncdu trash-cli ansible-core ansible-lint wireguard-tools ttf-jetbrains-mono jq terraform python-dnspython python-netaddr python-jmespath helm python-poetry podman buildah netavark aardvark-dns slirp4netns borgmatic signal-desktop"

print_msg() {
    echo
    echo "$1"
    echo
}

create_partitions() {
    echo
    echo "Creating EFI partition of size $EFI_PART_SIZE and a an encrypted BTRFS partition of size $BTRFS_PART_SIZE"
    read -p "This will erase data on $NVME_DRIVE! Is that okay? (yes/No): " answer

    if [[ "$answer" =~ [Yy][Ee][Ss] ]]; then
        parted -s "$NVME_DRIVE" mklabel gpt \
            mkpart primary fat32 1MiB $EFI_PART_SIZE \
            set 1 esp on \
            mkpart primary btrfs $EFI_PART_SIZE $BTRFS_PART_SIZE

        mkfs.vfat -F32 -n EFI "${NVME_DRIVE}p1"
        cryptsetup luksFormat "${NVME_DRIVE}p2"
        cryptsetup open "${NVME_DRIVE}p2" $CRYPT_NAME
        mkfs.btrfs -f -L ROOT /dev/mapper/$CRYPT_NAME
    else
        echo "Quitting script. Be sure to customize before running it again."
        exit 1
    fi
}

create_btrfs_subvolumes() {
    print_msg "Creating the BTRFS subvolumes and mounting the drives"

    mount /dev/mapper/$CRYPT_NAME $MOUNT_POINT
    btrfs sub create $MOUNT_POINT/@
    btrfs sub create $MOUNT_POINT/@swap
    btrfs sub create $MOUNT_POINT/@home
    btrfs sub create $MOUNT_POINT/@pkg
    btrfs sub create $MOUNT_POINT/@snapshots
    mount -o noatime,nodiratime,compress=zstd,space_cache=v2,ssd,subvol=@ /dev/mapper/$CRYPT_NAME $MOUNT_POINT
    mkdir -p $MOUNT_POINT/{boot,home,var/cache/pacman/pkg,.snapshots,btrfs}
    mount -o noatime,nodiratime,compress=zstd,space_cache=v2,ssd,subvol=@home /dev/mapper/$CRYPT_NAME $MOUNT_POINT/home
    mount -o noatime,nodiratime,compress=zstd,space_cache=v2,ssd,subvol=@pkg /dev/mapper/$CRYPT_NAME $MOUNT_POINT/var/cache/pacman/pkg
    mount -o noatime,nodiratime,compress=zstd,space_cache=v2,ssd,subvol=@snapshots /dev/mapper/$CRYPT_NAME $MOUNT_POINT/.snapshots
    mount -o noatime,nodiratime,compress=zstd,space_cache=v2,ssd,subvolid=5 /dev/mapper/$CRYPT_NAME $MOUNT_POINT/btrfs
    mount "${NVME_DRIVE}p1" $MOUNT_POINT/boot;

    if [[ $ENABLE_SWAPFILE == true && -d $MOUNT_POINT/@swap ]]; then
        btrfs filesystem mkswapfile --size "$(awk '/MemTotal/ {print $2}' /proc/meminfo)k" --uuid clear $MOUNT_POINT/@swap/swapfile
        swapon $MOUNT_POINT/@swap/swapfile
    else
        echo "Avoiding swapfile"
    fi
}

generate_fstab() {
    CPU_TYPE=$(grep -o -m 1 'vendor_id.*' /proc/cpuinfo | awk '{print $3}')

    if [ "$CPU_TYPE" == "GenuineIntel" ]; then
        CPU_PACKAGE="intel-ucode"
    elif [ "$CPU_TYPE" == "AuthenticAMD" ]; then
        CPU_PACKAGE="amd-ucode"
    fi

    pacstrap $MOUNT_POINT linux-lts linux-firmware base btrfs-progs $CPU_PACKAGE nano
    genfstab -U $MOUNT_POINT >> $MOUNT_POINT/etc/fstab

    print_msg "Finished generating fstab. Be sure to check it and modify if necessary"
}

config_arch() {
    print_msg "Configuring Arch system"

    arch-chroot $MOUNT_POINT sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    arch-chroot $MOUNT_POINT sed -i "s/#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
    arch-chroot $MOUNT_POINT echo $HOSTNAME > /etc/hostname;
    arch-chroot $MOUNT_POINT tee /etc/locale.conf <<EOF
LANG=en_US.UTF-8
LC_ADDRESS=$LOCALE
LC_IDENTIFICATION=$LOCALE
LC_MEASUREMENT=$LOCALE
LC_MONETARY=$LOCALE
LC_NAME=$LOCALE
LC_NUMERIC=$LOCALE
LC_PAPER=$LOCALE
LC_TELEPHONE=$LOCALE
LC_TIME=$LOCALE
EOF
    arch-chroot $MOUNT_POINT locale-gen

    arch-chroot $MOUNT_POINT echo KEYMAP=$KEYBOARD > /etc/vconsole.conf
    arch-chroot $MOUNT_POINT echo FONT=lat9w-16 >> /etc/vconsole.conf
    arch-chroot $MOUNT_POINT ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    arch-chroot $MOUNT_POINT hwclock --systohc

    arch-chroot $MOUNT_POINT tee /etc/hosts << EOF
#<ip-address>	<hostname.domain.org>	<hostname>
127.0.0.1   localhost	$(cat /etc/hostname)
127.0.1.1   pluto.localdomain   $(cat /etc/hostname)
::1   localhost ip6-localhost   ip6-loopback
ff02::1   ip6-allnodes
ff02::2   ip6-allrouters
EOF

    arch-chroot $MOUNT_POINT sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard keymap block sd-encrypt btrfs filesystems resume)/' /etc/mkinitcpio.conf
    arch-chroot $MOUNT_POINT mkinitcpio -p linux-lts

    arch-chroot $MOUNT_POINT bootctl --path=/boot install
    arch-chroot $MOUNT_POINT tee /boot/loader/entries/arch.conf << EOF
title Arch Linux
linux /vmlinuz-linux-lts
initrd /$CPU_PACKAGE.img
initrd /initramfs-linux-lts.img
options rd.luks.name=$(blkid -s UUID -o value "${NVME_DRIVE}p2")=luks root=/dev/mapper/luks rootflags=subvol=@ rd.luks.options=discard,no-read-workqueue,no-write-workqueue rw resume=/dev/mapper/luks resume_offset=$(btrfs inspect-internal map-swapfile -r $MOUNT_POINT/btrfs/@swap/swapfile)
EOF

    arch-chroot $MOUNT_POINT mkdir /etc/pacman.d/hooks; tee /etc/pacman.d/hooks/95-systemd-boot.hook << EOF
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Gracefully upgrading systemd-boot...
When = PostTransaction
Exec = /usr/bin/systemctl restart systemd-boot-update.service
EOF

    arch-chroot $MOUNT_POINT tee /boot/loader/loader.conf << EOF
default  arch.conf
timeout  0
console-mode max
editor   no
EOF

    arch-chroot $MOUNT_POINT pacman -S --needed sudo which zsh zsh-completions base-devel git reflector python-pip
    arch-chroot $MOUNT_POINT sed -i "s/^# --country $REFLECTOR_COUNTRIES/--country $REFLECTOR_COUNTRIES/" /etc/xdg/reflector/reflector.conf
    arch-chroot $MOUNT_POINT sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    arch-chroot $MOUNT_POINT systemctl enable reflector.timer systemd-timesyncd.service

    arch-chroot $MOUNT_POINT tee -a /etc/sudoers << EOF

Defaults      editor=/usr/bin/rnano, !env_editor
%wheel      ALL=(ALL:ALL) ALL
EOF
}

arch_setup() {
    arch-chroot $MOUNT_POINT useradd -m -G wheel -s /bin/zsh $CUSTOM_USER

    read -s -p "Enter password for user root: " password
    arch-chroot $MOUNT_POINT /bin/bash -c "echo 'root:$password' | chpasswd"
    echo

    read -s -p "Enter password for user $CUSTOM_USER: " password
    arch-chroot $MOUNT_POINT /bin/bash -c "echo '$CUSTOM_USER:$password' | chpasswd"
    echo

    arch-chroot $MOUNT_POINT /bin/bash <<EOF
      pacman -Syu && \
      sudo -u $CUSTOM_USER /bin/bash -c '
        cd /tmp && \
        git clone https://aur.archlinux.org/yay-bin.git && \
        cd /tmp/yay-bin && \
        makepkg -si && \
        yay -Syu && \
        yay -S $INSTALL_PACKAGES && \
        yay -Rcns wpa_supplicant yay
      '
EOF

    arch-chroot $MOUNT_POINT cat /etc/zsh/zshrc-manjaro/.zshrc > /home/$CUSTOM_USER/.zshrc
    arch-chroot $MOUNT_POINT systemctl enable sddm.service NetworkManager.service fstrim.timer
}

final_steps(){
    umount -a

    # Lock root
    arch-chroot $MOUNT_POINT passwd -l root
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parts)
            create_partitions
            shift
            ;;
        --btrfs)
            create_btrfs_subvolumes
            shift
            ;;
        --fstab)
            generate_fstab
            shift
            ;;
        --config)
            config_arch
            shift
            ;;
        --setup)
            arch_setup
            shift
            ;;
        --finish)
            final_steps
            shift
            ;;
        --all)
            create_partitions
            create_btrfs_subvolumes
            generate_fstab
            config_arch
            arch_setup
            print_msg "Be sure to still run it with the --finish flag after you confirm everything is OK"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

print_msg "Steps to run: --parts, --btrfs, --fstab, --config, --setup, --finish"
