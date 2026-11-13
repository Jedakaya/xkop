"""Release catalogue metadata tests; no package installation or network access."""
import importlib.util
import io
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_metadata", ROOT / "tools/release-metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


def archive(entries):
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode="w:gz") as tar:
        for name, body in entries.items():
            item = tarfile.TarInfo(name)
            item.size = len(body)
            tar.addfile(item, io.BytesIO(body))
    return result.getvalue()


def ipk(path, name, version, arch, extra=""):
    control = f"Package: {name}\nVersion: {version}\nArchitecture: {arch}\nInstalled-Size: 7\n{extra}".encode()
    path.write_bytes(archive({"./control.tar.gz": archive({"./control": control}),
                              "./data.tar.gz": archive({"./usr/share/value": b"fixture"})}))


class ReleaseMetadata(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def test_ipk_native_control_not_filename_guess(self):
        path = self.folder / "package.ipk"
        ipk(path, "xkop", "0.2.25-r1", "all")
        self.assertEqual(metadata.package_metadata(path),
                         {"name": "xkop", "version": "0.2.25-r1", "arch": "all", "installed_size": 7})
        ipk(path, "other-package", "9-r7", "x86_64")
        self.assertEqual(metadata.package_metadata(path)["name"], "other-package")

    def test_duplicate_fields_and_corrupt_payload_rejected(self):
        path = self.folder / "package.ipk"
        ipk(path, "xkop", "0.2.25-r1", "all", "Installed-Size: 9\n")
        with self.assertRaises(ValueError):
            metadata.package_metadata(path)
        path.write_bytes(archive({"./control.tar.gz": archive({"./control": b"Package: xkop\n"}),
                                  "./data.tar.gz": b"broken"}))
        with self.assertRaises((ValueError, tarfile.TarError, OSError)):
            metadata.package_metadata(path)

    def complete_fixture(self):
        expected = {}
        for fmt in ("apk", "ipk"):
            for name, version, arch in [("xkop", "0.2.25", "noarch" if fmt == "apk" else "all"),
                                        ("luci-app-xkop", "0.2.25", "noarch" if fmt == "apk" else "all")] + [
                    ("xray-xkop", "26.10.31", arch) for arch in metadata.ARCHES]:
                suffix = "" if fmt == "apk" and name != "xray-xkop" else "-" + arch
                path = self.folder / f"{name}-{version}-r1{suffix}.{fmt}"
                if fmt == "ipk":
                    ipk(path, name, version + "-r1", arch)
                else:
                    path.write_bytes(b"apk test boundary")
                expected[path.name] = {"name": name, "version": version + "-r1", "arch": arch, "installed_size": 7}
        (self.folder / "install.sh").write_text("installer\n")
        return expected

    def test_complete_manifest_metadata_and_hashes(self):
        expected = self.complete_fixture()
        real_reader = metadata.package_metadata
        def reader(path, apk_tool="apk"):
            return expected[path.name] if path.suffix == ".apk" else real_reader(path, apk_tool)
        with patch.object(metadata, "package_metadata", reader):
            result = metadata.build_manifest(self.folder, "0.2.25", "26.10.31")
        self.assertEqual(len(result["assets"]), 21)
        for item in result["assets"]:
            if item["name"] != "install.sh":
                self.assertEqual(item["package"], expected[item["name"]])
            else:
                self.assertNotIn("package", item)
            self.assertEqual(item["sha256"], metadata.sha256(self.folder / item["name"]))

    def test_native_metadata_mismatch_fails_closed(self):
        expected = self.complete_fixture()
        expected["xkop-0.2.25-r1.apk"]["version"] = "9-r1"
        with (patch.object(metadata, "package_metadata", side_effect=lambda path, apk_tool="apk": expected[path.name]),
              self.assertRaisesRegex(ValueError, "metadata mismatch")):
            metadata.build_manifest(self.folder, "0.2.25", "26.10.31")

    def test_missing_and_ambiguous_assets_fail(self):
        expected = self.complete_fixture()
        (self.folder / "xkop-0.2.25-1.apk").write_bytes(b"duplicate revision spelling")
        with (patch.object(metadata, "package_metadata", side_effect=lambda path, apk_tool="apk": expected[path.name]),
              self.assertRaisesRegex(ValueError, "missing/ambiguous")):
            metadata.build_manifest(self.folder, "0.2.25", "26.10.31")
        (self.folder / "xkop-0.2.25-1.apk").unlink()
        (self.folder / "xray-xkop-26.10.31-r1-mips_24kc.ipk").unlink()
        with (patch.object(metadata, "package_metadata", side_effect=lambda path, apk_tool="apk": expected[path.name]),
              self.assertRaisesRegex(ValueError, "missing/ambiguous")):
            metadata.build_manifest(self.folder, "0.2.25", "26.10.31")

    @unittest.skipUnless(os.environ.get("APK_TOOL"), "native APK tool supplied only in isolated Linux test")
    def test_real_apk_metadata_and_integrity(self):
        import subprocess
        tool = os.environ["APK_TOOL"]
        payload = self.folder / "payload/usr/share"
        payload.mkdir(parents=True)
        (payload / "fixture").write_bytes(b"fixture")
        path = self.folder / "native.apk"
        subprocess.run([tool, "mkpkg", "--info", "name:xkop", "--info", "version:0.2.25-r1",
                        "--info", "arch:noarch", "--files", str(self.folder / "payload"), "--output", str(path)], check=True)
        self.assertEqual(metadata.package_metadata(path, tool),
                         {"name": "xkop", "version": "0.2.25-r1", "arch": "noarch", "installed_size": 7})
        path.write_bytes(path.read_bytes()[:-8])
        with self.assertRaises(ValueError):
            metadata.package_metadata(path, tool)


if __name__ == "__main__":
    unittest.main()
