# probo-nix

Nix packaging of the [Probo device agent](https://www.probo.com/device-agent)
(`probo-agent`, from [getprobo/probo](https://github.com/getprobo/probo)): a
package and a NixOS module.

This repository was written with the help of AI: Claude Opus 5.5, through Claude
Code.

## Checking a machine before enrolling

To see the posture report the agent would send, without installing or
enrolling anything:

```sh
nix shell github:niols/probo-nix -c sudo probo-agent collect
```

`collect` runs the checks once and prints the results. It does not write any
state or contact the Probo server.

## NixOS

```nix
{
  inputs.probo-nix.url = "github:niols/probo-nix";

  outputs = { nixpkgs, probo-nix, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      modules = [
        probo-nix.nixosModules.default
        {
          services.probo-agent = {
            enable = true;
            serverUrl = "https://eu.probo.com"; # or https://us.probo.com
            # One-shot token from Probo; keep it out of the Nix store.
            enrollmentTokenFile = "/run/secrets/probo-enrollment-token";
          };
        }
      ];
    };
  };
}
```

On other distributions, `probo-agent install` enrolls the device and writes
`/etc/systemd/system/probo-agent.service`. The module provides the same unit
(same command, restart policy and hardening). It replaces the imperative
`install` step with a pre-start step: if `/var/lib/probo-agent/config.json` does
not exist, it runs `probo-agent install --skip-service --no-auto-update` with
the token from `enrollmentTokenFile`. Once the device is enrolled, the token
file is no longer needed.

To enroll by hand instead, use `probo-agent install --skip-service …`. Without
`--skip-service`, the device still gets enrolled, but the command fails on
`/etc/systemd/system` being read-only.

To unenroll, run `probo-agent uninstall`, then disable the module.

## Differences from upstream

Two patches are applied to the source:

- `nixos-command-paths.patch`: the posture checks only run commands from
  hard-coded FHS paths (`/usr/bin/systemctl`, `/usr/bin/lsblk`, …), and none of
  those paths exist on NixOS. With the patch, the checks also look in
  `/run/wrappers/bin` and `/run/current-system/sw/bin`. The patch also makes the
  auto-update check recognise `system.autoUpgrade` (`nixos-upgrade.timer`).
- `disable-self-update.patch`: the agent normally replaces its own binary from
  GitHub Releases. That cannot work from the Nix store, so it is disabled.
  Update the agent by updating this flake.

## Development

```sh
nix build .#probo-agent
nix build .#checks.x86_64-linux.nixos   # VM test against a mock Probo API
```

To update: bump `version` in `pkgs/probo-agent/package.nix`, refresh `hash` and
`vendorHash`, and check that the patches still apply.
