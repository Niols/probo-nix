{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    types
    ;

  cfg = config.services.probo-agent;

  # The agent hard-codes this directory (and /run/probo-agent for its
  # enrollment marker and lock) when `--dir` is not given.
  stateDir = "/var/lib/probo-agent";
in
{
  options.services.probo-agent = {
    enable = mkEnableOption "the Probo device agent, which reports this device's security posture to Probo";

    package = mkPackageOption pkgs "probo-agent" { };

    serverUrl = mkOption {
      type = types.str;
      example = "https://eu.probo.com";
      description = ''
        Base URL of the Probo server to enroll with, e.g.
        `https://us.probo.com` or `https://eu.probo.com`.
      '';
    };

    enrollmentTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/probo-enrollment-token";
      description = ''
        File containing the one-shot enrollment token issued by Probo for this
        device. It is only read when the device is not enrolled yet, i.e. when
        `${stateDir}/config.json` does not exist, so it can be removed once
        enrollment has succeeded.

        Do not use a path literal here: it would be copied into the
        world-readable Nix store. Use a string path to a secret managed outside
        of the store (agenix, sops-nix, …).

        If `null`, the device must be enrolled by hand before the service can
        start: `probo-agent install --skip-service --server <url>
        --enrollment-token <token>`.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Mirrors the unit that `probo-agent install` writes to
    # /etc/systemd/system/probo-agent.service on other Linux distributions
    # (pkg/deviceagent/service/service_linux.go), plus a pre-start enrollment
    # step that replaces the imperative `probo-agent install`.
    systemd.services.probo-agent = {
      description = "Probo device posture agent";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # The posture checks look up commands in the NixOS system profile
      # directly; this is for the commands they run through `runuser`/`sudo`.
      path = [
        "/run/wrappers"
        "/run/current-system/sw"
      ];

      preStart = ''
        if [ -e ${stateDir}/config.json ]; then
          exit 0
        fi
      ''
      + (
        if cfg.enrollmentTokenFile == null then
          ''
            echo "probo-agent: this device is not enrolled and services.probo-agent.enrollmentTokenFile is not set." >&2
            echo "probo-agent: enroll by hand with: probo-agent install --skip-service --server ${lib.escapeShellArg cfg.serverUrl} --enrollment-token <token>" >&2
            exit 1
          ''
        else
          ''
            echo "probo-agent: enrolling device with ${cfg.serverUrl}"
            PROBO_ENROLLMENT_TOKEN=$(< ${lib.escapeShellArg cfg.enrollmentTokenFile})
            export PROBO_ENROLLMENT_TOKEN
            ${lib.getExe cfg.package} install \
              --skip-service \
              --no-auto-update \
              --server ${lib.escapeShellArg cfg.serverUrl}
          ''
      );

      serviceConfig = {
        Type = "simple";
        ExecStart = "${lib.getExe cfg.package} run --dir ${stateDir}";
        Restart = "always";
        RestartSec = 10;
        # 75 is the exit code emitted after a successful self-update. The Nix
        # build disables self-update, but keep this in line with upstream.
        SuccessExitStatus = 75;
        User = "root";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "full";

        StateDirectory = "probo-agent";
        StateDirectoryMode = "0700";
      };
    };
  };
}
