{ config, pkgs, lib, ... }:

let
  # -----------------------------------------------------------------------
  # Set your domain here. Once DNS points to the VPS, Caddy auto-provisions
  # TLS. Until then, access the dashboard at http://<VPS_IP>.
  # -----------------------------------------------------------------------
  domain = ":80"; # e.g., "analytics.yourdomain.com"
in
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

  # --- damsac-studio analytics service ---
  services.damsac-studio = {
    enable = true;
    port = 8080;
    dataDir = "/var/lib/damsac-studio";
    apiKeys = [ "sk_murmur:murmur-ios" ];
    dashboardPasswordFile = "/run/secrets/damsac-dashboard-pw";
    secureCookie = domain != ":80"; # only set Secure flag when using a real domain (HTTPS)
  };

  # --- Caddy: reverse proxy with auto TLS ---
  services.caddy = {
    enable = true;
    virtualHosts.${domain} = {
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

  users.users.root.openssh.authorizedKeys.keys = [
    (builtins.readFile ./keys/deploy.pub)
  ];

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

  # --- System ---
  system.stateVersion = "24.11";
}
