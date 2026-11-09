"""Exercise the cold-start tunnel without internet or router privileges."""
import http.server
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path


def field(number, value):
    assert len(value) < 128
    return bytes([number * 8 + 2, len(value)]) + value


def geosite():
    domain = b"\x08\x03" + field(2, b"example.com")
    return field(1, field(1, b"RUSSIA-INSIDE") + field(2, domain))


ports = set()


def port():
    while True:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            value = listener.getsockname()[1]
        if value not in ports:
            ports.add(value)
            return value


def ready(process, value):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError("fixture Xray exited before listening")
        try:
            with socket.create_connection(("127.0.0.1", value), timeout=0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("fixture listener did not start")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        content = b"<html>temporary upstream error</html>" if self.path == "/invalid.dat" else geosite()
        self.send_response(200)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, *_):
        pass


ROOT = Path(os.environ["ROOT"]).resolve()
XRAY = os.environ["XRAY"]
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    for name in ("run", "state", "assets"):
        (work / name).mkdir()
    env = dict(os.environ, ROOT=str(ROOT), WORK=str(work), XRAY=XRAY,
               XRAY_LOCATION_ASSET=str(work / "assets"), NO_PROXY="", no_proxy="")
    upstream_port, probe_port, metrics_port, api_port = (port() for _ in range(4))
    upstream = {
        "log": {"access": str(work / "upstream-access.log"), "loglevel": "warning"},
        "inbounds": [{"tag": "fixture-in", "listen": "127.0.0.1", "port": upstream_port,
                      "protocol": "socks", "settings": {"udp": False}}],
        "outbounds": [{"tag": "direct", "protocol": "freedom"}],
    }
    (work / "upstream.json").write_text(json.dumps(upstream))
    data = json.loads((ROOT / "tests/fixtures/config/with-pool.json").read_text())
    data["settings"].update({
        "access_log_path": str(work / "access.log"), "probe_port": probe_port,
        "metrics_port": metrics_port, "api_port": api_port, "engine_mark": 0,
        "dns_mode": "fakeip", "dns_server": "8.8.8.8", "dns_type": "udp",
        "dns_extra": [], "sniff_excluded": [],
    })
    data["pool"] = [{"tag": "cached-node", "protocol": "socks", "outbound": {
        "tag": "cached-node", "protocol": "socks", "settings": {
            "servers": [{"address": "127.0.0.1", "port": upstream_port}]}}}]
    data["bindings"][0]["profile"]["community_list"] = ["russia-inside"]
    (work / "input.json").write_text(json.dumps(data))
    common = r'''
set -u
XKOP_RUN_DIR="$WORK/run" XKOP_STATE_DIR="$WORK/state"
XKOP_CONFIG_PATH="$WORK/config.json" XKOP_LIB_DIR="$ROOT/xkop/files/usr/lib/xkop"
XKOP_ENGINE_BIN="$XRAY"
. "$XKOP_LIB_DIR/config.sh"
. "$XKOP_LIB_DIR/lists.sh"
XKOP_ASSET_DIR="$WORK/assets"
log_info() { printf '%s\n' "$*" >&2; }
log_warn() { printf '%s\n' "$*" >&2; }
log_error() { printf '%s\n' "$*" >&2; }
config_input_json() { cat "$WORK/input.json"; }
'''

    def shell(body):
        result = subprocess.run(["sh", "-c", common + body], env=env,
                                capture_output=True, text=True, timeout=45, check=False)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    processes = []
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        shell("engine_answers() { return 1; }; config_generate || exit 1\n")
        bootstrap = json.loads((work / "config.json").read_text())
        assert [item["tag"] for item in bootstrap["inbounds"]] == ["probe-in"]
        assert bootstrap["routing"]["rules"][0]["outboundTag"] == "cached-node"
        for name, path in (("upstream", work / "upstream.json"), ("bootstrap", work / "config.json")):
            with (work / (name + ".log")).open("w") as output:
                processes.append(subprocess.Popen([XRAY, "run", "-c", str(path)],
                                                   env=env, stdout=output, stderr=output))
        ready(processes[0], upstream_port)
        ready(processes[1], probe_port)
        print("ok   actual bootstrap starts without geosite and exposes only loopback SOCKS")
        env["XKOP_PROBE_PORT"] = str(probe_port)
        env["METRICS_PORT"] = str(metrics_port)
        env["FIXTURE_URL"] = f"http://127.0.0.1:{server.server_port}/geosite.dat"
        shell(r'''
xray() { "$XRAY" "$@"; }
engine_answers() { command curl -fsS --max-time 2 "http://127.0.0.1:$METRICS_PORT/debug/vars" >/dev/null; }
curl() {
    case "$*" in
        *--socks5-hostname*) command curl "$@" ;;
        *) printf blocked > "$WORK/direct-blocked"; return 22 ;;
    esac
}
XKOP_GEOSITE_URL="$FIXTURE_URL"
old=$(sha256sum "$XKOP_CONFIG_PATH")
XKOP_GEOSITE_URL="${FIXTURE_URL%/*}/invalid.dat"
if lists_update force; then echo 'invalid list accepted'; exit 1; fi
[ ! -f "$XKOP_ASSET_DIR/geosite.dat" ] || exit 1
[ "$old" = "$(sha256sum "$XKOP_CONFIG_PATH")" ] || exit 1
XKOP_GEOSITE_URL="$FIXTURE_URL"
lists_update force || {
    XRAY_LOCATION_ASSET="$XKOP_RUN_DIR/assets" "$XRAY" run -test -format json -c "$XKOP_RUN_DIR/geosite-probe.json"
    exit 1
}
config_generate || exit 1
''')
        assert (work / "direct-blocked").exists()
        assert (work / "assets/geosite.dat").read_bytes() == geosite()
        access = (work / "upstream-access.log").read_text()
        assert str(server.server_port) in access, "download bypassed the cached proxy"
        full = json.loads((work / "config.json").read_text())
        assert any(item["tag"] == "tproxy-in" for item in full["inbounds"])
        assert (work / "run/bootstrap.pending").exists(), "full config lacks confirmation gate"
        print("ok   blocked direct download succeeds through the actual cached SOCKS outbound")
        print("ok   an invalid download preserves bootstrap and the following valid retry succeeds")
        print("ok   downloaded geosite is validated and full config awaits engine confirmation")
    except Exception:
        for path in work.glob("*.log"):
            print(path.name, path.read_text())
        raise
    finally:
        server.shutdown()
        for process in processes:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
