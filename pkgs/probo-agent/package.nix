{
  lib,
  buildGoModule,
  fetchFromGitHub,
  go_1_27,
  versionCheckHook,
}:

(buildGoModule.override { go = go_1_27; }) (finalAttrs: {
  pname = "probo-agent";
  version = "0.7.1";

  src = fetchFromGitHub {
    owner = "getprobo";
    repo = "probo";
    tag = "probo-agent/v${finalAttrs.version}";
    hash = "sha256-pSPH6huObAkZ6Vu5qm7rmlerMoChYkVQjnpo8j0Nrg4=";
  };

  vendorHash = "sha256-DTjaYK8Tb8Zju6hc9jKpyTgayrTOam/c0YOim9aRROQ=";

  patches = [
    # The posture checks only look for commands at hard-coded FHS paths
    # (/usr/bin/systemctl, …). Also look in the NixOS system profile, and
    # recognise `system.autoUpgrade` as an auto-update mechanism.
    ./nixos-command-paths.patch
    # The agent replaces its own binary from GitHub Releases, which cannot
    # work from the read-only Nix store. Updates come from Nix instead.
    ./disable-self-update.patch
  ];

  subPackages = [
    "cmd/probo-agent"
    # Library packages: nothing gets installed, but their tests are run.
    "pkg/deviceagent/..."
  ];

  env.CGO_ENABLED = 0;

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  meta = {
    description = "Probo device agent: reports device security posture to Probo";
    homepage = "https://www.probo.com/device-agent";
    changelog = "https://github.com/getprobo/probo/blob/probo-agent/v${finalAttrs.version}/cmd/probo-agent/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "probo-agent";
    platforms = lib.platforms.linux ++ lib.platforms.freebsd;
  };
})
