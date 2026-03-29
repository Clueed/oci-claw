{ pkgs, config, ... }:
let
  galleryScript = pkgs.writeText "image-gallery.ts" (builtins.readFile ./image-gallery.ts);
in
{
  systemd.services.image-gallery = {
    description = "Image gallery for transmission downloads";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.bun}/bin/bun run ${galleryScript} ${config.services.transmission.settings.download-dir} 8766";
      User = "transmission";
      Restart = "on-failure";
    };
  };

  systemd.services.tailscale-serve-gallery = {
    description = "Tailscale Serve for image gallery";
    after = [ "tailscale-online.service" ];
    requires = [ "tailscale-online.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --service=svc:torrent-gallery --https=8766 127.0.0.1:8766";
    };
  };
}
