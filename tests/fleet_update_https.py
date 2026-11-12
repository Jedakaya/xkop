"""Real signature/TLS tests with synthetic packages; no package installation."""
import functools
import hashlib
import http.server
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "posix" and shutil.which("usign"), "Linux and real usign required")
class SignedStaging(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.www = self.root / "www"
        self.www.mkdir()
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        (self.state / "enabled").touch()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "mutations"
        self.key = self.root / "signing.key"
        self.command("usign", "-G", "-s", str(self.key), "-p", str(self.state / "release.pub"))
        self.cert = self.root / "tls.pem"
        tls_key = self.root / "tls.key"
        self.command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                     "-keyout", str(tls_key), "-out", str(self.cert), "-days", "1",
                     "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1")
        self.requests = []
        requests = self.requests
        self.faults = {}
        faults = self.faults

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                requests.append(self.path)
                if self.path in faults:
                    fault = faults[self.path]
                    self.send_response(fault.get("code", 200))
                    self.send_header("Content-Length", str(fault.get("length", 0)))
                    if "location" in fault:
                        self.send_header("Location", fault["location"])
                    self.end_headers()
                    self.wfile.write(fault.get("body", b""))
                    self.close_connection = True
                    return
                super().do_GET()

        handler = functools.partial(Handler, directory=str(self.www))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.cert, tls_key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.base = f"https://127.0.0.1:{self.server.server_port}"
        self.release = self.root / "openwrt_release"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        CURL_CA_BUNDLE=str(self.cert), XKOP_FLEET_DIR=str(self.state),
                        XKOP_FLEET_LOCK=str(self.root / "lock"),
                        XKOP_FLEET_UPDATE_LIB=str(ROOT / "xkop/files/usr/lib/xkop/fleet-update.sh"),
                        XKOP_FLEET_RELEASE_FILE=str(self.release), MUTATION_LOG=str(self.calls))

    def stop_server(self):
        self.server.shutdown()
        self.thread.join(5)
        self.server.server_close()

    def command(self, *args):
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=15)

    def platform(self, fmt="apk"):
        for name in ("apk", "opkg"):
            (self.bin / name).unlink(missing_ok=True)
        series = "25.12" if fmt == "apk" else "24.10"
        self.release.write_text(f"DISTRIB_RELEASE='{series}.5'\nDISTRIB_ARCH='aarch64_cortex-a53'\n")
        manager = "apk" if fmt == "apk" else "opkg"
        rows = ("xkop-0.2.23-r1 aarch64_cortex-a53 {xkop} (MIT) [installed]\n"
                "luci-app-xkop-0.2.23-r1 aarch64_cortex-a53 {xkop} (MIT) [installed]\n"
                "xray-xkop-26.10.31-r1 aarch64_cortex-a53 {xkop} (MIT) [installed]")
        if fmt == "ipk":
            rows = "xkop - 0.2.23-r1\nluci-app-xkop - 0.2.23-r1\nxray-xkop - 26.10.31-r1"
        script = ("#!/bin/sh\ncase \"$1\" in list|list-installed)\ncat <<'DATA'\n"
                  + rows + "\nDATA\n;; *) echo called >> \"$MUTATION_LOG\"; exit 99;; esac\n")
        (self.bin / manager).write_text(script)
        (self.bin / manager).chmod(0o755)
        return series

    def manifest(self, fmt="apk"):
        series = self.platform(fmt)
        packages = []
        for name in ("xkop", "luci-app-xkop", "xray-xkop"):
            previous = "26.10.31-r1" if name == "xray-xkop" else "0.2.23-r1"
            target = "26.11.1-r1" if name == "xray-xkop" else "0.2.24-r1"
            package = {"name": name, "from": previous, "to": target}
            for direction in ("forward", "rollback"):
                filename = f"{name}-{direction}.{fmt}"
                data = f"synthetic {name} {direction}".encode()
                (self.www / filename).write_bytes(data)
                package[direction] = {"file": filename, "sha256": hashlib.sha256(data).hexdigest(),
                                      "size": len(data), "installed_size": 4096}
            packages.append(package)
        now = int(time.time())
        return {"schema": 1, "issued": now - 1, "expires": now + 3600,
                "openwrt_series": series, "arch": "aarch64_cortex-a53", "format": fmt, "packages": packages}

    def publish(self, manifest):
        path = self.www / "manifest.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        self.command("usign", "-S", "-m", str(path), "-s", str(self.key), "-x", str(path) + ".sig")
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def prepare(self, pin, **overrides):
        return subprocess.run(["sh", str(ROOT / "xkop/files/usr/bin/xkop-fleet"), "prepare",
                               self.base + "/manifest.json", pin], env=dict(self.env, **overrides),
                              capture_output=True, text=True, timeout=30, check=False)

    def assert_rejected(self, pin, before_packages=False, **overrides):
        self.requests.clear()
        result = self.prepare(pin, **overrides)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / "updates" / pin / "prepared.json").exists())
        self.assertFalse(self.calls.exists(), "package manager must never mutate during preparation")
        if before_packages:
            self.assertFalse(any(path.endswith((".apk", ".ipk")) for path in self.requests))
        return result

    def test_complete_forward_and_rollback_prepared_for_both_formats(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(fmt=fmt):
                manifest = self.manifest(fmt)
                pin = self.publish(manifest)
                result = self.prepare(pin)
                self.assertEqual(result.returncode, 0, result.stderr)
                prepared = self.state / "updates" / pin
                receipt = json.loads((prepared / "prepared.json").read_text())
                self.assertEqual(receipt["state"], "prepared")
                self.assertFalse(receipt["installation_allowed"])
                self.assertEqual(receipt["manifest_sha256"], pin)
                self.assertEqual(prepared.stat().st_mode & 0o777, 0o700)
                for package in manifest["packages"]:
                    for direction in ("forward", "rollback"):
                        artifact = package[direction]
                        self.assertEqual(hashlib.sha256((prepared / artifact["file"]).read_bytes()).hexdigest(),
                                         artifact["sha256"])
                self.assertEqual(self.prepare(pin).returncode, 0)
                self.assertFalse(self.calls.exists())

    def test_signature_pin_tls_and_owner_gates(self):
        pin = self.publish(self.manifest())
        self.assert_rejected("0" * 64, True)
        signature = self.www / "manifest.json.sig"
        original = signature.read_bytes()
        signature.write_bytes(b"invalid signature")
        self.assert_rejected(pin, True)
        signature.write_bytes(original)
        self.assert_rejected(pin, True, CURL_CA_BUNDLE=str(self.root / "absent.pem"))
        (self.state / "release.pub").rename(self.state / "saved.pub")
        self.assert_rejected(pin, True)
        self.assertEqual(self.requests, [])
        (self.state / "saved.pub").rename(self.state / "release.pub")
        (self.state / "enabled").unlink()
        self.assert_rejected(pin, True)
        self.assertEqual(self.requests, [])

    def test_incompatible_or_unsafe_signed_manifest_is_rejected_before_package_fetch(self):
        mutations = [lambda m: m.update(arch="x86_64"), lambda m: m.update(format="ipk"),
                     lambda m: m.update(openwrt_series="23.05"), lambda m: m.update(expires=1),
                     lambda m: m["packages"][0].update({"from": "0.0.1-r1"}),
                     lambda m: m["packages"][0].pop("rollback"),
                     lambda m: m["packages"].pop(1),
                     lambda m: m["packages"][0]["forward"].update(file="../escape.apk"),
                     lambda m: m["packages"].append(m["packages"][0]),
                     lambda m: m.update(command="reboot")]
        for mutate in mutations:
            manifest = self.manifest()
            mutate(manifest)
            self.assert_rejected(self.publish(manifest), True)

    def test_corrupt_missing_rollback_and_low_disk_never_mark_prepared(self):
        manifest = self.manifest()
        pin = self.publish(manifest)
        rollback = self.www / manifest["packages"][2]["rollback"]["file"]
        rollback.write_bytes(b"corrupt")
        self.assert_rejected(pin)
        rollback.unlink()
        self.assert_rejected(pin)
        manifest = self.manifest()
        pin = self.publish(manifest)
        (self.bin / "df").write_text("#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/test 1 1 0 100%% /test\\n'\n")
        (self.bin / "df").chmod(0o755)
        self.assert_rejected(pin, True)

    def test_existing_prepared_set_is_not_trusted_without_revalidation(self):
        manifest = self.manifest()
        pin = self.publish(manifest)
        self.assertEqual(self.prepare(pin).returncode, 0)
        prepared = self.state / "updates" / pin
        (prepared / manifest["packages"][0]["rollback"]["file"]).write_bytes(b"changed")
        result = self.prepare(pin)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((prepared / "prepared.json").exists())
        self.assertFalse(self.calls.exists())

    def test_redirect_and_interrupted_download_do_not_prepare(self):
        manifest = self.manifest()
        pin = self.publish(manifest)
        self.faults["/manifest.json"] = {"code": 302, "location": self.base + "/other.json"}
        self.assert_rejected(pin, True)
        self.assertNotIn("/other.json", self.requests)
        self.faults.clear()
        artifact = manifest["packages"][0]["rollback"]
        self.faults["/" + artifact["file"]] = {"length": artifact["size"], "body": b"short"}
        self.assert_rejected(pin)
        self.assertEqual(list((self.state / "updates").glob(".prepare.*")), [])

    def test_disable_before_lock_prevents_all_prepare_requests(self):
        pin = self.publish(self.manifest())
        ready, resume = self.root / "ready", self.root / "resume"
        mkdir = self.bin / "mkdir"
        mkdir.write_text("#!/bin/sh\nif [ -n \"${PAUSE_PREPARE:-}\" ]; then\n"
                         ': > "$PAUSE_READY"\ni=0\n'
                         'while [ ! -f "$PAUSE_RESUME" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done\nfi\n'
                         + f'exec {shutil.which("mkdir")} "$@"\n')
        mkdir.chmod(0o755)
        client = str(ROOT / "xkop/files/usr/bin/xkop-fleet")
        process = subprocess.Popen(["sh", client, "prepare", self.base + "/manifest.json", pin],
                                   env=dict(self.env, PAUSE_PREPARE="1", PAUSE_READY=str(ready), PAUSE_RESUME=str(resume)),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(ready.exists())
            result = subprocess.run(["sh", client, "disable"], env=self.env, capture_output=True,
                                    timeout=5, check=False)
            self.assertEqual(result.returncode, 0)
            resume.touch()
            self.assertNotEqual(process.wait(20), 0)
            self.assertEqual(self.requests, [])
        finally:
            resume.touch()
            if process.poll() is None:
                process.kill()
                process.wait(5)

    def test_release_builder_copies_hashes_signs_and_refuses_overwrite(self):
        manifest = self.manifest()
        for package in manifest["packages"]:
            for direction in ("forward", "rollback"):
                package[direction].pop("sha256")
                package[direction].pop("size")
        draft = self.root / "draft.json"
        draft.write_text(json.dumps(manifest))
        output = self.root / "release"
        args = ["python3", str(ROOT / "tools/fleet-release.py"), "--spec", str(draft),
                "--artifacts", str(self.www), "--output", str(output), "--key", str(self.key),
                "--public-key", str(self.state / "release.pub")]
        result = subprocess.run(args, capture_output=True, text=True, timeout=15, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.command("usign", "-V", "-p", str(self.state / "release.pub"),
                     "-m", str(output / "manifest.json"), "-x", str(output / "manifest.json.sig"))
        built = json.loads((output / "manifest.json").read_text())
        self.assertEqual(result.stdout.strip(), hashlib.sha256((output / "manifest.json").read_bytes()).hexdigest())
        for package in built["packages"]:
            for direction in ("forward", "rollback"):
                item = package[direction]
                self.assertEqual(item["sha256"], hashlib.sha256((output / item["file"]).read_bytes()).hexdigest())
        old = (output / "manifest.json").read_bytes()
        self.assertNotEqual(subprocess.run(args, capture_output=True, check=False).returncode, 0)
        self.assertEqual((output / "manifest.json").read_bytes(), old)

    def test_release_builder_rejects_path_escape_and_mismatched_signing_key(self):
        manifest = self.manifest()
        draft = self.root / "draft.json"
        manifest["packages"][0]["forward"]["file"] = "../private.key"
        draft.write_text(json.dumps(manifest))
        output = self.root / "rejected"
        args = ["python3", str(ROOT / "tools/fleet-release.py"), "--spec", str(draft),
                "--artifacts", str(self.www), "--output", str(output), "--key", str(self.key),
                "--public-key", str(self.state / "release.pub")]
        self.assertNotEqual(subprocess.run(args, capture_output=True, check=False).returncode, 0)
        self.assertFalse(output.exists())
        draft.write_text(json.dumps(self.manifest()))
        self.command("usign", "-G", "-s", str(self.root / "wrong.key"), "-p", str(self.state / "release.pub"))
        self.assertNotEqual(subprocess.run(args, capture_output=True, check=False).returncode, 0)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
