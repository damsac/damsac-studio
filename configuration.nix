{ config, pkgs, lib, ... }:
{
  # Auto-import all .nix files from modules/ — drop new service modules
  # here and redeploy to add services to the VPS.
  imports = let
    modulesDir = ./modules;
  in
    if builtins.pathExists modulesDir then
      map (f: modulesDir + "/${f}")
        (builtins.attrNames
          (lib.filterAttrs (n: v: v == "regular" && lib.hasSuffix ".nix" n)
            (builtins.readDir modulesDir)))
    else [];

  # --- Caddy: reverse proxy with auto TLS ---
  services.caddy = {
    enable = true;
    virtualHosts."damsac.studio" = {
      extraConfig = ''
        reverse_proxy localhost:8080
      '';
    };
  };

  # --- Networking ---
  networking = {
    hostName = "damsac";
    useNetworkd = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 80 443 ];
    };
  };

  # DHCP on all physical ethernet interfaces (Hetzner Cloud uses eth0)
  systemd.network.networks."10-wan" = {
    matchConfig.Name = "eth* en*";
    networkConfig.DHCP = "ipv4";
    dhcpV4Config.UseDNS = true;
    linkConfig.RequiredForOnline = "routable";
  };

  # --- SSH ---
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # --- Locale & Timezone ---
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # --- Boot & Filesystem ---
  # Disk layout managed by disko (see disko-config.nix).
  # GRUB with BIOS boot partition — reliable on Hetzner Cloud where
  # UEFI NVRAM resets on reboot (systemd-boot doesn't persist in boot order).
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "/dev/sda";
  };

  # Hetzner Cloud runs KVM/QEMU — virtio modules needed in initrd
  boot.initrd.availableKernelModules = [
    "virtio_pci" "virtio_blk" "virtio_scsi" "virtio_net" "ahci"
  ];

  # --- Nix ---
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # --- System ---
  system.stateVersion = "24.11";
}
