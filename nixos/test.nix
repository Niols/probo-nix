# Enrolls the agent against a mock of the Probo agent API
# (/api/agent/v1/{enroll,heartbeat,postures}) and checks that it reports
# postures, then that a restart reuses the stored credentials.
self:
{ pkgs, ... }:

let
  token = "test-enrollment-token";
  apiKey = "test-api-key";

  mockServer = pkgs.writers.writePython3 "mock-probo" { flakeIgnore = [ "E501" ]; } ''
    import json
    from http.server import BaseHTTPRequestHandler, HTTPServer

    LOG = "/tmp/requests.log"


    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or "null")
            auth = self.headers.get("Authorization")
            with open(LOG, "a") as f:
                f.write(json.dumps({"path": self.path, "auth": auth, "body": body}) + "\n")

            if self.path == "/api/agent/v1/enroll":
                if body.get("token") != "${token}":
                    return self.reply(401, {"error": "bad token"})
                return self.reply(200, {"api_key": "${apiKey}"})

            if auth != "Bearer ${apiKey}":
                return self.reply(401, {"error": "bad api key"})

            if self.path == "/api/agent/v1/heartbeat":
                return self.reply(200, {
                    "device_id": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX",
                    "heartbeat_interval_seconds": 60,
                    "posture_interval_seconds": 900,
                    "server_time": "2026-01-01T00:00:00Z",
                })
            if self.path in ("/api/agent/v1/postures", "/api/agent/v1/unenroll"):
                return self.reply(200, {})
            return self.reply(404, {"error": "not found"})

        def reply(self, code, payload):
            data = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)


    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
  '';
in
{
  name = "probo-agent";

  nodes = {
    server = {
      networking.firewall.allowedTCPPorts = [ 8080 ];
      systemd.services.mock-probo = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = mockServer;
      };
    };

    machine = {
      imports = [ self.nixosModules.default ];
      services.probo-agent = {
        enable = true;
        serverUrl = "http://server:8080";
        enrollmentTokenFile = "/etc/probo-enrollment-token";
      };
      # Stands in for a secret deployed out of the Nix store.
      environment.etc."probo-enrollment-token".text = token;
    };
  };

  testScript = ''
    import json

    def requests():
        out = server.succeed("cat /tmp/requests.log || true")
        return [json.loads(line) for line in out.splitlines()]

    def paths():
        return [r["path"] for r in requests()]

    start_all()
    server.wait_for_open_port(8080)
    machine.wait_for_unit("probo-agent.service")

    with subtest("device enrolls and reports postures"):
        server.wait_until_succeeds("grep -q /api/agent/v1/postures /tmp/requests.log", timeout=120)
        assert paths().count("/api/agent/v1/enroll") == 1, paths()
        machine.succeed("test -s /var/lib/probo-agent/config.json")
        machine.succeed("[ $(stat -c %a /var/lib/probo-agent) = 700 ]")

        postures = [r for r in requests() if r["path"] == "/api/agent/v1/postures"][0]
        results = {p["check_key"]: p for p in postures["body"]["results"]}
        print(json.dumps(results, indent=2))
        # These need commands that only exist in the NixOS system profile,
        # which upstream does not look into.
        for key in ["TIME_SYNC", "REMOTE_LOGIN", "MALWARE_PROTECTION"]:
            evidence = json.dumps(results[key].get("evidence"))
            assert "not available at expected absolute path" not in evidence, (key, evidence)
            assert "unavailable" not in evidence, (key, evidence)
        assert results["AUTO_UPDATE"]["evidence"]["backend"] == "nixos-upgrade", results["AUTO_UPDATE"]
        assert "lsblk" in results["DISK_ENCRYPTION"]["evidence"], results["DISK_ENCRYPTION"]

    with subtest("restart reuses the stored credentials"):
        machine.succeed("rm /etc/probo-enrollment-token")
        machine.systemctl("restart probo-agent.service")
        machine.wait_for_unit("probo-agent.service")
        server.wait_until_succeeds(
            "[ $(grep -c /api/agent/v1/heartbeat /tmp/requests.log) -ge 2 ]", timeout=60
        )
        assert paths().count("/api/agent/v1/enroll") == 1, paths()

    with subtest("self-update is disabled"):
        machine.fail("probo-agent update --check")

    with subtest("uninstall revokes the device server-side"):
        out = machine.succeed("probo-agent uninstall 2>&1")
        # NixOS manages the unit, so removing it fails, but only with a warning.
        assert "read-only file system" in out, out
        unenroll = [r for r in requests() if r["path"] == "/api/agent/v1/unenroll"]
        assert len(unenroll) == 1, paths()
        assert unenroll[0]["auth"] == "Bearer ${apiKey}", unenroll
        machine.fail("test -e /var/lib/probo-agent")
  '';
}
