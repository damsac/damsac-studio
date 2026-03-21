{ pkgs, ... }:

{
  # Shared group for workspace access
  users.groups.damsac = {};

  # Disable mutable users — all user config is declarative
  users.mutableUsers = false;

  users.users.gudnuf = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "damsac" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH/l2PXd8ieGkeiwStlfp0dX1igdWrSx/sqE9/WGpjz4 gudnuf@damsac"
    ];
  };

  users.users.isaac = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "damsac" ];
    openssh.authorizedKeys.keys = [
      # TODO: Replace with isaac's actual SSH public key
      "ssh-ed25519 AAAA... isaac"
    ];
  };

  # Passwordless sudo for wheel group
  security.sudo.wheelNeedsPassword = false;

  # Root keeps the existing deploy key for provisioning/emergency
  users.users.root.openssh.authorizedKeys.keys = [
    (builtins.readFile ../keys/deploy.pub)
  ];

  # Enable zsh system-wide (required for user shells)
  programs.zsh.enable = true;
}
