# disko-config.nix — declarative disk layout for Hetzner Cloud VPS
#
# Used by nixos-anywhere during provisioning. Defines:
# - GPT partition table
# - 1MB BIOS boot partition (for GRUB on GPT)
# - 512MB EFI system partition (for UEFI fallback)
# - Remainder as ext4 root partition (mounted at /)
#
# Hetzner Cloud UEFI firmware resets NVRAM on reboot, so systemd-boot
# doesn't reliably persist in the boot order. GRUB with a BIOS boot
# partition provides reliable booting on Hetzner.
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02"; # BIOS boot partition
            };
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
