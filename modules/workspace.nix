{ ... }:

{
  # Create /srv/damsac/ with setgid so new files inherit the damsac group.
  # Git repos are cloned manually after provisioning (mutable state).
  systemd.tmpfiles.rules = [
    "d /srv/damsac 2775 root damsac - -"
  ];
}
