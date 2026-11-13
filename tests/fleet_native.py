"""Actual APK/opkg tests in isolated disposable OpenWrt root filesystems.

Opt-in test harness only; never run against a router's root filesystem.
"""
import copy
import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
LAB = Path(os.environ.get("XKOP_NATIVE_LAB", "/nonexistent"))


def run(*args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=40, check=False, **kwargs)


def archive(entries):
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode="w:gz") as tar:
        parents = {str(parent) for name in entries for parent in PurePosixPath(name).parents if str(parent) != "."}
        for parent in sorted(parents, key=lambda name: (name.count("/"), name)):
            info = tarfile.TarInfo("./" + parent)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            tar.addfile(info)
        for name, data in entries.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755 if name.endswith("preinst") else 0o644
            tar.addfile(info, io.BytesIO(data))
    return result.getvalue()


@unittest.skipUnless(LAB.is_dir(), "explicit disposable OpenWrt rootfs lab required")
class NativePackages(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="native-case-", dir=LAB)
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def shell(self, script, check=True, timeout=40):
        # No production bind mounts, no external network, no host PID namespace.
        outer = '''set -eu
mount --make-rprivate /
mount --bind "$1" "$1"
mount -t tmpfs tmpfs "$1/dev"
mknod "$1/dev/null" c 1 3
mknod "$1/dev/urandom" c 1 9
mount -t proc proc "$1/proc"
set +e
chroot "$1" /bin/sh -c "$2"
result=$?
exit "$result"
'''
        return subprocess.run(["unshare", "--mount", "--net", "--pid", "--fork",
                               "sh", "-c", outer, "lab", str(self.router), script],
                              capture_output=True, text=True, check=check, timeout=timeout)

    def setup_router(self, fmt):
        self.fmt = fmt
        version = "25.12.5" if fmt == "apk" else "24.10.4"
        self.router = self.base / fmt
        shutil.copytree(LAB / version, self.router, symlinks=True)
        self.code = self.router / "lab/code"
        shutil.copytree(ROOT / "xkop", self.code / "xkop")
        shutil.copytree(ROOT / "tools", self.code / "tools")
        self.bundle = self.router / "lab/bundle"
        self.bundle.mkdir()
        self.state = self.router / "etc/xkop/fleet"
        self.state.mkdir(parents=True)
        (self.state / "enabled").touch()
        self.shell("usign -G -s /lab/key -p /etc/xkop/fleet/release.pub")
        self.manifest = {"schema": 1, "issued": int(time.time()) - 1,
                         "expires": int(time.time()) + 3600, "format": fmt,
                         "arch": "x86_64", "openwrt_series": version.rsplit(".", 1)[0],
                         "packages": []}
        pkg = {"name": "xkop", "from": "0.2.22-r1", "to": "0.2.23-r1"}
        for direction, ver, body in (("rollback", pkg["from"], b"old\n"),
                                     ("forward", pkg["to"], b"new\n")):
            filename = f"{direction}.{fmt}"
            self.make_package(self.bundle / filename, ver, body)
            data = (self.bundle / filename).read_bytes()
            pkg[direction] = {"file": filename, "size": len(data),
                              "sha256": hashlib.sha256(data).hexdigest(), "installed_size": len(body)}
        self.manifest["packages"].append(pkg)
        self.shell(self.install_command("/lab/bundle/rollback." + fmt))
        self.sign()

    def prepare_transaction(self, health="exit 0\n"):
        (self.router / "lab/xkop-native-lab").write_text("DISPOSABLE OPENWRT ROOTFS\n")
        (self.router / "lab/check-health").write_text("#!/bin/sh\n" + health)
        (self.router / "lab/check-health").chmod(0o700)
        (self.router / "etc/config/xkop").write_text("original router config\n")
        (self.router / "etc/xkop/subscription.json").write_text("original subscription\n")
        self.tx = self.state / "transaction"

    def transact(self, action="start", copied=False):
        script = "/etc/xkop/fleet/transaction/runner.sh" if copied else "/lab/code/tools/fleet-transaction-lab.sh"
        return self.shell(f"PATH=/lab:$PATH sh {script} {action} {self.pin}", check=False)

    def journal(self):
        return json.loads((self.tx / "journal.json").read_text())

    def test_packaged_transaction_owner_gate_and_native_result(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                self.prepare_transaction()
                library = self.router / "usr/lib/xkop"
                library.mkdir(parents=True, exist_ok=True)
                for file in (ROOT / "xkop/files/usr/lib/xkop").glob("fleet-*"):
                    shutil.copy2(file, library / file.name)
                # Lab health substitutes only the network contract. Native PM,
                # snapshots, validation and installed transaction are real.
                (library / "fleet-health.sh").write_text("#!/bin/sh\nexit 0\n")
                script = f"PATH=/lab:$PATH sh /usr/lib/xkop/fleet-transaction.sh start {self.pin}"
                result = self.shell(script, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.tx.exists())
                (self.state / "allow-install").touch()
                (self.state / "health.json").write_text('{}')
                (self.router / "lab/xkop-native-lab").unlink()
                result = self.shell(script, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.journal()["state"], "committed")
                self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"new\n")

    def test_packaged_guardian_survives_missing_package_and_ack_is_scoped(self):
        self.setup_router("apk")
        self.prepare_transaction('if [ "$1" = forward ]; then kill -KILL "$PPID"; fi\nexit 0\n')
        runtime = self.state / "supervisor/runtime/lib"
        runtime.mkdir(parents=True)
        for file in (ROOT / "xkop/files/usr/lib/xkop").glob("fleet-*"):
            shutil.copy2(file, runtime / file.name)
        shutil.copy2(self.router / "lab/check-health", runtime / "fleet-health.sh")
        (self.state / "allow-install").touch()
        (self.state / "health.json").write_text('{}')
        guardian = "/etc/xkop/fleet/supervisor/runtime/lib/fleet-guardian.sh"
        job = "a" * 32
        result = self.shell(f'PATH=/lab:$PATH sh {guardian} queue {self.pin} 4 8 {job}; PATH=/lab:$PATH sh {guardian} run', check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.journal()["state"], "rolled_back")
        self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"old\n")
        wrong = self.shell(f'PATH=/lab:$PATH sh {guardian} ack {"b" * 32}', check=False)
        self.assertNotEqual(wrong.returncode, 0)
        good = self.shell(f'PATH=/lab:$PATH sh {guardian} ack {job}', check=False)
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertTrue((self.state / "supervisor/acknowledged").exists())

    def test_health_rejects_missing_policy_route_and_unrelated_probe(self):
        self.setup_router("apk")
        (self.state / "health.json").write_text(json.dumps({"dns_name": "probe.example", "dns_server": "127.0.0.1", "url": "https://probe.example/", "http_status": 204}))
        (self.router / "etc/xkop/config.json").write_text(json.dumps({"inbounds": [{"tag": "tproxy-in", "port": 1608, "listen": "127.0.0.1"}, {"tag": "probe-in", "port": 10809, "listen": "127.0.0.1"}]}))
        (self.router / "tmp/xkop").mkdir()
        (self.router / "tmp/xkop/access.log").touch()
        for command, body in {
            "sleep": "exit 0",
            "xray": "exit 0",
            "dig": "echo 192.0.2.2",
            "nft": "printf '%s\\n' 'type filter hook prerouting' 'tproxy ip to 127.0.0.1:1608'",
            "ip": 'if [ "$TEST_ROUTE" = yes ]; then printf "%s\\n" "local default dev lo" "fwmark 0x200000/0x200000 lookup 106"; fi',
            "curl": '''port=44444
while [ "$#" -gt 0 ]; do if [ "$1" = --local-port ]; then port=$2; fi; shift; done
[ "$TEST_CORRELATED" = yes ] || port=1
echo "from tcp:127.0.0.1:$port accepted tcp:probe.example:443 [probe-in -> node]" >> /tmp/xkop/access.log
printf 204''',
        }.items():
            path = self.router / "lab" / command
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o700)
        health = "/lab/code/xkop/files/usr/lib/xkop/fleet-health.sh"
        for route, correlated, expected in (("no", "yes", False), ("yes", "no", False), ("yes", "yes", True)):
            with self.subTest(route=route, correlated=correlated):
                result = self.shell(f"PATH=/lab:$PATH TEST_ROUTE={route} TEST_CORRELATED={correlated} sh {health} baseline", check=False)
                self.assertEqual(result.returncode == 0, expected, (route, correlated, result.stderr))

    def test_manual_recovery_states_are_reported_as_terminal_failure(self):
        self.setup_router("apk")
        sup = self.state / "supervisor"
        (sup / "runtime/lib").mkdir(parents=True)
        (sup / "runtime/lib/fleet-guardian.sh").touch()
        (self.state / "jobs").mkdir()
        (self.state / "transaction").mkdir()
        (sup / "active.json").write_text(json.dumps({"job_id": "a" * 32, "pin": self.pin}))
        (self.state / "jobs/current.json").write_text(json.dumps({"job_id": "a" * 32, "release": {"manifest_sha256": self.pin}}))
        (self.state / "transaction/journal.json").write_text(json.dumps({"manifest_sha256": self.pin, "state": "verifying"}))
        for status in ("recovery_interrupted", "recovery_integrity_failed"):
            with self.subTest(status=status):
                (sup / "status.json").write_text(json.dumps({"state": status}))
                result = self.shell('''export PATH=/lab:$PATH
STATE=/etc/xkop/fleet
. /lab/code/xkop/files/usr/lib/xkop/fleet-install.sh
fleet_job_event() { printf '%s %s' "$1" "$2"; }
fleet_install_tick
''', check=False)
                self.assertEqual(result.stdout, "failed recovery_failed", result.stderr)

    def test_installer_setup_resumes_and_refreshes_only_after_ack(self):
        self.setup_router("apk")
        library = self.router / "usr/lib/xkop"
        library.mkdir(parents=True, exist_ok=True)
        for file in (ROOT / "xkop/files/usr/lib/xkop").glob("fleet-*"):
            shutil.copy2(file, library / file.name)
        shutil.copy2(ROOT / "xkop/files/usr/bin/xkop-fleet", self.router / "usr/bin/xkop-fleet")
        (library / "fleet-health.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.state / "health.json").write_text('{}')
        for cmd in ("curl", "dig", "nft", "xray"):
            file = self.router / "lab" / cmd
            file.write_text("#!/bin/sh\nexit 0\n")
            file.chmod(0o700)
        (self.router / "etc/rc.common").write_text('#!/bin/sh\n[ ! -f /lab/fail-setup ] || exit 1\nexit 0\n')
        (self.router / "lab/fail-setup").touch()
        command = "PATH=/lab:$PATH sh /usr/bin/xkop-fleet enable-updates /etc/xkop/fleet/health.json"
        self.assertNotEqual(self.shell(command, check=False).returncode, 0)
        self.assertFalse((self.state / "allow-install").exists())
        (self.router / "lab/fail-setup").unlink()
        result = self.shell(command, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        sup = self.state / "supervisor"
        before = (sup / "runtime/lib/fleet-health.sh").read_bytes()
        (library / "fleet-health.sh").write_text("#!/bin/sh\n# new tested health revision\nexit 0\n")
        (sup / "active.json").write_text(json.dumps({"job_id": "a" * 32, "pin": self.pin}))
        tx = self.state / "transaction"
        tx.mkdir()
        (tx / "journal.json").write_text(json.dumps({"state": "committed", "manifest_sha256": self.pin}))
        self.assertNotEqual(self.shell(command, check=False).returncode, 0)
        self.assertEqual((sup / "runtime/lib/fleet-health.sh").read_bytes(), before)
        (sup / "acknowledged").write_text("a" * 32 + "\n")
        result = self.shell(command, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"new tested", (sup / "runtime/lib/fleet-health.sh").read_bytes())

    def test_transaction_success_and_repeat_do_not_reinstall(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                self.prepare_transaction()
                result = self.transact()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.journal()["state"], "committed")
                self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"new\n")
                before = (self.tx / "operations.log").read_bytes()
                self.assertEqual(self.transact().returncode, 0)
                self.assertEqual((self.tx / "operations.log").read_bytes(), before)

    def test_failed_health_restores_package_and_configuration(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                self.prepare_transaction('if [ "$1" = forward ]; then\n'
                                         'echo changed > /etc/config/xkop\n'
                                         'echo changed > /etc/xkop/subscription.json\n'
                                         'echo junk > /etc/xkop/new-file\nexit 1\nfi\nexit 0\n')
                result = self.transact()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.journal()["state"], "rolled_back", result.stderr)
                self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"old\n")
                self.assertEqual((self.router / "etc/config/xkop").read_text(), "original router config\n")
                self.assertEqual((self.router / "etc/xkop/subscription.json").read_text(), "original subscription\n")
                self.assertFalse((self.router / "etc/xkop/new-file").exists())

    def test_interrupted_worker_recovers_from_independent_copy(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                self.prepare_transaction('if [ "$1" = forward ]; then\n'
                                         'echo changed > /etc/config/xkop\n'
                                         'kill -KILL "$PPID"\nfi\nexit 0\n')
                result = self.transact()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.journal()["state"], "verifying")
                shutil.rmtree(self.code)
                # Revocation stops NEW work, not restoration of an armed update.
                (self.state / "enabled").unlink()
                result = self.transact("recover", copied=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.journal()["state"], "rolled_back")
                self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"old\n")

    def test_unrestorable_transaction_is_never_reported_successful(self):
        self.setup_router("apk")
        self.prepare_transaction('if [ "$1" = forward ]; then\nkill -KILL "$PPID"\nfi\nexit 0\n')
        self.transact()
        (self.tx / "bundle/rollback.apk").write_bytes(b"broken")
        result = self.transact("recover", copied=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.journal()["state"], "recovery_failed")

    def test_missing_dependency_refused_before_transaction_is_armed(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                path = self.bundle / ("forward." + fmt)
                self.make_package(path, "0.2.23-r1", b"new\n", depends="xkop-lab-missing")
                data = path.read_bytes()
                self.manifest["packages"][0]["forward"].update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
                self.sign()
                self.prepare_transaction()
                result = self.transact()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("dependency", result.stderr)
                self.assertFalse(self.tx.exists())
                self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"old\n")

    def test_failed_native_install_restores_old_files_even_if_database_is_old(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                path = self.bundle / ("forward." + fmt)
                # A failing package script damaged a file before unpacking.
                preinst = "#!/bin/sh\necho corrupt > /usr/share/xkop-lab/value\nexit 7\n"
                self.make_package(path, "0.2.23-r1", b"new\n", preinst=preinst)
                data = path.read_bytes()
                self.manifest["packages"][0]["forward"].update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
                self.sign()
                self.prepare_transaction()
                result = self.transact()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.journal()["state"], "rolled_back", result.stderr)
                self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"old\n")

    def test_concurrent_recovery_cannot_overlap_live_worker(self):
        self.setup_router("apk")
        self.prepare_transaction('if [ "$1" = forward ]; then\ntouch /lab/waiting\nsleep 3\nexit 1\nfi\nexit 0\n')
        result = self.shell(f'''export PATH=/lab:$PATH
sh /lab/code/tools/fleet-transaction-lab.sh start {self.pin} >/lab/first.log 2>&1 &
worker=$!
for count in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -f /lab/waiting ] || break
    sleep 1
done
sh /etc/xkop/fleet/transaction/runner.sh recover {self.pin} >/lab/second.log 2>&1
second=$?
wait "$worker"
first=$?
printf '%s %s\\n' "$first" "$second"
''', check=False)
        self.assertEqual(result.stdout.strip(), "1 1", result.stderr)
        self.assertIn("transaction busy", (self.router / "lab/second.log").read_text())
        self.assertEqual(self.journal()["state"], "rolled_back")

    def test_corrupt_recovery_library_is_not_sourced(self):
        self.setup_router("apk")
        self.prepare_transaction('if [ "$1" = forward ]; then\nkill -KILL "$PPID"\nfi\nexit 0\n')
        self.transact()
        with (self.tx / "lib/fleet-native.sh").open("a") as file:
            file.write("\ntouch /lab/corrupt-library-ran\n")
        result = self.transact("recover", copied=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.router / "lab/corrupt-library-ran").exists())
        self.assertEqual(self.journal()["state"], "recovery_failed")

    def test_signed_ipk_rollback_with_broken_payload_cannot_arm(self):
        self.setup_router("ipk")
        path = self.bundle / "rollback.ipk"
        with tarfile.open(path) as tar:
            control = tar.extractfile("./control.tar.gz").read()
        path.write_bytes(archive({"./debian-binary": b"2.0\n", "./control.tar.gz": control,
                                  "./data.tar.gz": b"not-a-gzip-payload"}))
        data = path.read_bytes()
        self.manifest["packages"][0]["rollback"].update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        self.sign()
        self.prepare_transaction()
        result = self.transact()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.tx.exists())
        self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"old\n")

    def test_live_package_manager_keeps_lock_after_runner_is_killed(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                path = self.bundle / ("forward." + fmt)
                self.make_package(path, "0.2.23-r1", b"new\n",
                                  preinst="#!/bin/sh\ntouch /lab/installing-marker\nsleep 4\nexit 0\n")
                data = path.read_bytes()
                self.manifest["packages"][0]["forward"].update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
                self.sign()
                self.prepare_transaction()
                result = self.shell(f'''export PATH=/lab:$PATH
sh /lab/code/tools/fleet-transaction-lab.sh start {self.pin} >/lab/first.log 2>&1 &
worker=$!
for count in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -f /lab/installing-marker ] || break
    sleep 1
done
test -f /lab/installing-marker || exit 90
kill -KILL "$worker"
wait "$worker"
sh /etc/xkop/fleet/transaction/runner.sh recover {self.pin} >/lab/second.log 2>&1
early=$?
sleep 5
sh /etc/xkop/fleet/transaction/runner.sh recover {self.pin} >/lab/third.log 2>&1
later=$?
printf '%s %s\\n' "$early" "$later"
''', check=False)
                self.assertEqual(result.stdout.strip(), "1 0", result.stderr)
                self.assertIn("transaction busy", (self.router / "lab/second.log").read_text())
                self.assertEqual(self.journal()["state"], "rolled_back")
                self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"old\n")

    def make_package(self, path, version, body, name="xkop", arch=None, depends=None, preinst=None):
        arch = arch or ("noarch" if self.fmt == "apk" else "all")
        if self.fmt == "apk":
            payload = self.base / "payload"
            (payload / "usr/share/xkop-lab").mkdir(parents=True, exist_ok=True)
            (payload / "usr/share/xkop-lab/value").write_bytes(body)
            args = [str(LAB / "builder/sbin/apk.static"), "mkpkg", "--info", f"name:{name}",
                    "--info", f"version:{version}", "--info", f"arch:{arch}",
                    "--info", "description:Disposable lab fixture", "--files", str(payload),
                    "--output", str(path)]
            if depends:
                args += ["--info", f"depends:{depends}"]
            if preinst:
                script = self.base / "preinst"
                script.write_text(preinst)
                args += ["--script", f"pre-upgrade:{script}"]
            result = run(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            control = f"Package: {name}\nVersion: {version}\nArchitecture: {arch}\nInstalled-Size: {len(body)}\nDescription: Disposable lab fixture\n"
            if depends:
                control += f"Depends: {depends}\n"
            controls = {"./control": control.encode()}
            if preinst:
                controls["./preinst"] = preinst.encode()
            path.write_bytes(archive({"./debian-binary": b"2.0\n",
                                      "./control.tar.gz": archive(controls),
                                      "./data.tar.gz": archive({"./usr/share/xkop-lab/value": body})}))

    def guardian(self, script="", timeout=40):
        result = self.shell(f'''export PATH=/lab:$PATH
g=/lab/code/tools/fleet-guardian-lab.sh
sh "$g" queue {self.pin} 4 8
{script}
sh "$g" run
''', check=False, timeout=timeout)
        if result.returncode:
            for name in ("status.json", "worker.log"):
                path = self.state / "supervisor" / name
                if path.exists():
                    result.stderr += "\n" + path.read_text()
        return result

    def test_guardian_recovers_killed_runner_without_original_source(self):
        self.setup_router("apk")
        self.prepare_transaction('if [ "$1" = forward ]; then\n'
                                 'rm -rf /lab/code/xkop\nrm /etc/xkop/fleet/enabled\n'
                                 'kill -KILL "$PPID"\nfi\nexit 0\n')
        result = self.guardian()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.journal()["state"], "rolled_back")
        before = (self.tx / "operations.log").read_bytes()
        result = self.shell("PATH=/lab:$PATH sh /lab/code/tools/fleet-guardian-lab.sh run", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.tx / "operations.log").read_bytes(), before)

    def test_guardian_bounds_native_installer_and_restores_dns(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                path = self.bundle / ("forward." + fmt)
                self.make_package(path, "0.2.23-r1", b"new\n", preinst=
                                  "#!/bin/sh\necho broken > /etc/config/dhcp\n"
                                  "touch /lab/installer-live\nsleep 30\ntouch /lab/escaped\n")
                data = path.read_bytes()
                self.manifest["packages"][0]["forward"].update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
                self.sign()
                self.prepare_transaction()
                (self.router / "etc/config/dhcp").write_text("original dns\n")
                result = self.guardian()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((self.router / "lab/installer-live").exists())
                self.assertFalse((self.router / "lab/escaped").exists())
                self.assertEqual(self.journal()["state"], "rolled_back")
                self.assertEqual((self.router / "etc/config/dhcp").read_text(), "original dns\n")

    def test_guardian_restart_retains_deadline(self):
        self.setup_router("apk")
        self.prepare_transaction('if [ "$1" = forward ]; then touch /lab/waiting; sleep 30; fi\nexit 0\n')
        result = self.guardian('''sh "$g" run >/lab/guardian-first.log 2>&1 &
supervisor=$!
for n in 1 2 3 4 5; do [ ! -f /lab/waiting ] || break; sleep 1; done
test -f /lab/waiting || exit 90
kill -KILL "$supervisor"
wait "$supervisor"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.journal()["state"], "rolled_back")

    def test_guardian_boot_recovery_ignores_old_pid_and_stops_after_failure(self):
        self.setup_router("apk")
        self.prepare_transaction('[ "$1" != baseline ] || exit 0\nif [ "$1" = forward ]; then kill -KILL "$PPID"; fi\nexit 1\n')
        self.transact()
        # The stale PID deliberately belongs to the calling shell in this boot.
        result = self.shell('''export PATH=/lab:$PATH
mkdir -p /etc/xkop/fleet/supervisor
jq -nc --argjson pid $$ '{boot:"previous-boot",pid:$pid,ticks:"0",mode:"start",deadline:0}' > /etc/xkop/fleet/supervisor/session.json
sh /lab/code/tools/fleet-guardian-lab.sh run
first=$?
cp /etc/xkop/fleet/transaction/operations.log /lab/first-operations
sh /lab/code/tools/fleet-guardian-lab.sh run
second=$?
cmp /lab/first-operations /etc/xkop/fleet/transaction/operations.log || exit 99
printf '%s %s\\n' "$first" "$second"
''', check=False)
        self.assertEqual(result.stdout.strip(), "1 1", result.stderr)
        self.assertEqual(self.journal()["state"], "recovery_failed")

    def test_guardian_rejects_reused_pid_identity(self):
        self.setup_router("apk")
        self.prepare_transaction()
        result = self.shell('''export PATH=/lab:$PATH
mkdir -p /etc/xkop/fleet/supervisor
setsid sh -c 'echo $$ > /lab/unrelated-pid; exec sleep 20' &
sleep 1
unrelated=$(cat /lab/unrelated-pid)
jq -nc --arg boot "$(cat /proc/sys/kernel/random/boot_id)" --argjson pid "$unrelated" \
    '{boot:$boot,pid:$pid,ticks:"999999999",mode:"start",deadline:0}' > /etc/xkop/fleet/supervisor/session.json
sh /lab/code/tools/fleet-guardian-lab.sh run
rc=$?
kill -0 "$unrelated" || exit 98
printf 'survived:%s\\n' "$rc"
''', check=False)
        self.assertEqual(result.stdout.strip(), "survived:1", result.stderr)
        self.assertFalse(self.tx.exists())

    def test_guardian_restart_after_anchor_cleanup_recovers_without_signalling_stale_pid(self):
        self.setup_router("apk")
        self.prepare_transaction('if [ "$1" = forward ]; then sleep 30; fi\nexit 0\n')
        guard = self.code / "xkop/files/usr/lib/xkop/fleet-guardian.sh"
        original = guard.read_text()
        crash = original.replace('wait "$pid" 2>/dev/null || :',
                                 'wait "$pid" 2>/dev/null || :\n    kill -KILL "$$"')
        self.assertNotEqual(original, crash)
        guard.write_text(crash)
        self.guardian()
        self.assertEqual(self.journal()["state"], "verifying")
        self.assertTrue((self.state / "supervisor/session.json").exists())
        guard.write_text(original)
        (self.state / "supervisor/runtime/lib/fleet-guardian.sh").write_text(original)
        result = self.shell("PATH=/lab:$PATH sh /lab/code/tools/fleet-guardian-lab.sh run", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.journal()["state"], "rolled_back")

    def test_guardian_checks_recovery_runner_before_execution(self):
        self.setup_router("apk")
        self.prepare_transaction('if [ "$1" = forward ]; then kill -KILL "$PPID"; fi\nexit 0\n')
        self.transact()
        (self.tx / "runner.sh").write_text("#!/bin/sh\ntouch /lab/corrupt-runner-executed\nexit 0\n")
        result = self.shell("PATH=/lab:$PATH sh /lab/code/tools/fleet-guardian-lab.sh run", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.router / "lab/corrupt-runner-executed").exists())

    def test_guardian_daemon_accepts_queue_while_idle(self):
        self.setup_router("apk")
        self.prepare_transaction()
        result = self.shell(f'''export PATH=/lab:$PATH
g=/lab/code/tools/fleet-guardian-lab.sh
sh "$g" serve >/lab/daemon.log 2>&1 &
daemon=$!
sleep 1
sh "$g" queue {self.pin} 10 10 || exit 91
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ "$(jq -r .state /etc/xkop/fleet/supervisor/status.json 2>/dev/null)" != committed ] || break
    sleep 1
done
kill -TERM "$daemon"
wait "$daemon"
test "$(jq -r .state /etc/xkop/fleet/supervisor/status.json)" = committed
''', check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.journal()["state"], "committed")

    def install_command(self, path):
        if self.fmt == "apk":
            return f"apk --no-network --allow-untrusted add {path}"
        return f"opkg --force-downgrade install {path}"

    def test_ordinary_updater_downgrade_and_partial_file_repair(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                self.shell(self.install_command("/lab/bundle/forward." + fmt))
                script = f'''export PATH=/lab:$PATH
. /lab/code/xkop/files/usr/lib/xkop/update.sh
XKOP_ROLLBACK_DIR=/lab/ordinary-rollback
mkdir -p "$XKOP_ROLLBACK_DIR"
update_restore_file /lab/bundle/rollback.{fmt} xkop || exit 91
test "$(update_package_version xkop)" = 0.2.22-r1 || exit 92
'''
                result = self.shell(script, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                # Keep the old database version but damage an owned file: add
                # alone may no-op; restoring must force extraction of old bytes.
                target = self.router / "usr/share/xkop-lab/value"
                target.write_text("partial new package\n")
                result = self.shell(script, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(target.read_bytes(), b"old\n")

    def test_ordinary_updater_managed_transaction_lock(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                result = self.shell('''export PATH=/lab:$PATH
. /lab/code/xkop/files/usr/lib/xkop/lock.sh
. /lab/code/xkop/files/usr/lib/xkop/update.sh
XKOP_RUN_DIR=/tmp/ordinary-update
log_info() { :; }; log_warn() { :; }
update_apply_locked() { touch /lab/mutation; }
exec 9>/etc/xkop/fleet/transaction.lock
flock -n 9 || exit 91
update_apply >/lab/result.json
test "$(jq -r .error /lab/result.json)" = update_busy || exit 92
test ! -e /lab/mutation || exit 93
exec 9>&-
mkdir -p /etc/xkop/fleet/configuration/current
echo '{"state":"recovery_failed"}' >/etc/xkop/fleet/configuration/current/status.json
update_apply >/lab/result.json
test "$(jq -r .error /lab/result.json)" = recovery_required || exit 94
echo '{"state":"committed"}' >/etc/xkop/fleet/configuration/current/status.json
update_apply
test -e /lab/mutation
''', check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def sign(self):
        data = json.dumps(self.manifest).encode()
        self.pin = hashlib.sha256(data).hexdigest()
        (self.bundle / "manifest.json").write_bytes(data)
        self.shell("usign -S -s /lab/key -m /lab/bundle/manifest.json -x /lab/bundle/manifest.json.sig")
        dest = self.state / "updates" / self.pin
        shutil.copytree(self.bundle, dest, dirs_exist_ok=True)
        self.prepared = dest

    def inspect(self):
        return self.shell(f"PATH=/lab:$PATH XKOP_FLEET_UPDATE_LIB=/lab/code/xkop/files/usr/lib/xkop/fleet-update.sh sh /lab/code/xkop/files/usr/bin/xkop-fleet check-update {self.pin}", check=False)

    def test_metadata_accepts_both_native_formats_without_installing(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                result = self.inspect()
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads((self.prepared / "native-checked.json").read_text())
                self.assertFalse(receipt["installation_allowed"])
                self.assertEqual((self.router / "usr/share/xkop-lab/value").read_bytes(), b"old\n")

    def test_metadata_rejects_signed_lies_and_missing_rollback(self):
        for fmt in ("apk", "ipk"):
            with self.subTest(format=fmt):
                self.setup_router(fmt)
                original = copy.deepcopy(self.manifest)
                for field, value in (("version", "0.2.99-r1"), ("name", "other-package"),
                                     ("arch", "mips_24kc"), ("size", 1)):
                    with self.subTest(field=field):
                        self.manifest = copy.deepcopy(original)
                        path = self.bundle / ("forward." + fmt)
                        self.make_package(path, value if field == "version" else "0.2.23-r1",
                                          b"new\n", name=value if field == "name" else "xkop",
                                          arch=value if field == "arch" else None)
                        artifact = self.manifest["packages"][0]["forward"]
                        data = path.read_bytes()
                        artifact.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
                        if field == "size":
                            artifact["installed_size"] = value
                        self.sign()
                        result = self.inspect()
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("package metadata", result.stderr)
                        self.assertFalse((self.prepared / "native-checked.json").exists())
                (self.prepared / ("rollback." + fmt)).unlink()
                self.assertNotEqual(self.inspect().returncode, 0)


if __name__ == "__main__":
    unittest.main()
