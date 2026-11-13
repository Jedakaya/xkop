"""Real rpcd/crypt and file ACL tests in disposable OpenWrt rootfs namespaces."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
LAB = Path(os.environ.get("XKOP_NATIVE_LAB", "/nonexistent"))
PASSWORD = 'test+$\\"&?pass'


@unittest.skipUnless(LAB.is_dir(), "explicit disposable OpenWrt rootfs lab required")
class NativeSecurity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="security-case-", dir=LAB)
        self.addCleanup(self.tmp.cleanup)

    def setup_router(self, version):
        self.router = Path(self.tmp.name) / version
        shutil.copytree(LAB / version, self.router, symlinks=True)
        shutil.copytree(ROOT / "client-panel/cgi-bin", self.router / "lab/cgi")

    def shell(self, script):
        outer = '''set -eu
mount --make-rprivate /
mount --bind "$1" "$1"
mount -t tmpfs tmpfs "$1/dev"
mknod "$1/dev/null" c 1 3
mknod "$1/dev/urandom" c 1 9
mount -t proc proc "$1/proc"
chroot "$1" /bin/sh -c "$2"
'''
        # Neither host network nor host PID namespace is visible to test daemons.
        bootstrap = '''set -eu
export PATH=/lab:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /var/run/ubus
ubusd >/tmp/ubusd.log 2>&1 & bus=$!
i=0
until ubus list >/dev/null 2>&1; do
 i=$((i + 1)); [ "$i" -lt 5 ] || exit 1; sleep 1
done
rpcd >/tmp/rpcd.log 2>&1 & rpc=$!
trap 'kill "$rpc" "$bus" 2>/dev/null || :' EXIT
i=0
until ubus list session >/dev/null 2>&1; do
 i=$((i + 1)); [ "$i" -lt 5 ] || { cat /tmp/rpcd.log; exit 1; }; sleep 1
done
'''
        return subprocess.run(["unshare", "--mount", "--net", "--pid", "--fork", "sh", "-c",
                               outer, "lab", str(self.router), bootstrap + script],
                              capture_output=True, text=True, timeout=60, check=False)

    def test_real_password_verifier(self):
        for version in ("25.12.5", "24.10.4"):
            self.setup_router(version)
            for algorithm, salt in (("6", "fixture"), ("5", "fixture"), ("1", "fixture"),
                                    ("6", "rounds=10000$fixture")):
                with self.subTest(version=version, algorithm=algorithm, salt=salt):
                    hashed = subprocess.run(["openssl", "passwd", "-" + algorithm, "-salt", salt, "-stdin"],
                                            input=PASSWORD, text=True, capture_output=True, check=True).stdout.strip()
                    (self.router / "etc/shadow").write_text(f"root:{hashed}:0:0:99999:7:::\n")
                    body = urlencode({"password": PASSWORD})
                    (self.router / "lab/request").write_text(body)
                    result = self.shell(f"rm -f /tmp/xkop-panel-token /tmp/xkop-panel-failures\nHTTPS=on CONTENT_LENGTH={len(body)} sh /lab/cgi/auth </lab/request | tail -n 1 | jq -c 'del(.token)'\n")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), {"ok": True}, result.stderr)
            for name, shadow in (("locked", "root:!:0:0:99999:7:::\n"),
                                 ("empty", "root::0:0:99999:7:::\n"), ("missing", None)):
                with self.subTest(version=version, account=name):
                    if shadow is None:
                        (self.router / "etc/shadow").unlink()
                    else:
                        (self.router / "etc/shadow").write_text(shadow)
                    result = self.shell("rm -f /tmp/xkop-panel-token /tmp/xkop-panel-failures\nHTTPS=on CONTENT_LENGTH=0 sh /lab/cgi/auth | tail -n 1 | jq -c 'del(.token)'\n")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(json.loads(result.stdout)["ok"])

    def test_rpcd_read_only_boundary(self):
        for version in ("25.12.5", "24.10.4"):
            with self.subTest(version=version):
                self.setup_router(version)
                source = ROOT / "luci-app-xkop/root"
                acl = "usr/share/rpcd/acl.d/luci-app-xkop.json"
                wrapper = "usr/libexec/xkop-read"
                for name in (acl, wrapper):
                    (self.router / name).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source / name, self.router / name)
                (self.router / wrapper).chmod(0o755)
                executable = self.router / "usr/bin/xkop"
                executable.write_text('#!/bin/sh\nprintf \'{"ok":true}\\n\'\n')
                executable.chmod(0o755)
                hashed = subprocess.run(["openssl", "passwd", "-6", "-salt", "fixture", "-stdin"],
                                        input=PASSWORD, text=True, capture_output=True, check=True).stdout.strip()
                (self.router / "etc/shadow").write_text(f"root:{hashed}:0:0:99999:7:::\n")
                with (self.router / "etc/config/rpcd").open("a") as config:
                    config.write("\nconfig login\n option username 'reader'\n option password '$p$root'\n list read 'luci-app-xkop'\n")
                (self.router / "lab/login").write_text(json.dumps({"username": "reader", "password": PASSWORD}))
                result = self.shell('''
sid=$(ubus call session login "$(cat /lab/login)" | jq -er .ubus_rpc_session)
for command in /usr/bin/xkop /etc/init.d/xkop; do
 ubus call session access "$(jq -nc --arg sid "$sid" --arg cmd "$command" '{ubus_rpc_session:$sid,scope:"file",object:$cmd,function:"exec"}')" | jq -e '.access == false' >/dev/null
done
ubus call session access "$(jq -nc --arg sid "$sid" '{ubus_rpc_session:$sid,scope:"file",object:"/usr/libexec/xkop-read",function:"exec"}')" | jq -e '.access == true' >/dev/null
ubus call file exec "$(jq -nc --arg sid "$sid" '{ubus_rpc_session:$sid,command:"/usr/libexec/xkop-read",params:["dashboard"]}')" | jq -e '.code == 0 and (.stdout | fromjson | .ok)' >/dev/null
if ubus call file exec "$(jq -nc --arg sid "$sid" '{ubus_rpc_session:$sid,command:"/usr/bin/xkop",params:["service","stop"]}')" >/dev/null 2>&1; then exit 1; fi
ubus call file exec "$(jq -nc --arg sid "$sid" '{ubus_rpc_session:$sid,command:"/usr/libexec/xkop-read",params:["service","stop"]}')" | jq -e '.code != 0' >/dev/null
echo 'read-only enforced'
''')
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertIn("read-only enforced", result.stdout)


if __name__ == "__main__":
    unittest.main()
