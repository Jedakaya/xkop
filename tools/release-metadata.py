#!/usr/bin/env python3
"""Inspect native package archives without installing/executing their payloads."""
import argparse
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path

ARCHES = ("aarch64_cortex-a53", "aarch64_cortex-a72", "aarch64_generic",
          "arm_cortex-a7_neon-vfpv4", "arm_cortex-a9_neon", "mipsel_24kc", "mips_24kc", "x86_64")
MAX_CONTROL = 4 * 1024 * 1024
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_PAYLOAD = 128 * 1024 * 1024


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def member_bytes(archive, name, limit):
    matches = [item for item in archive.getmembers() if item.name.removeprefix("./") == name]
    if len(matches) != 1 or not matches[0].isfile() or not 0 < matches[0].size <= limit:
        raise ValueError(f"invalid archive member {name}")
    with archive.extractfile(matches[0]) as stream:
        value = stream.read(limit + 1)
    if len(value) > limit:
        raise ValueError(f"oversized archive member {name}")
    return value


def package_metadata(path, apk_tool="apk"):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_ARCHIVE:
        raise ValueError(f"invalid package file {path.name}")
    if path.suffix == ".apk":
        try:
            subprocess.run([apk_tool, "--allow-untrusted", "verify", str(path)], check=True,
                           capture_output=True, timeout=60)
            result = subprocess.run([apk_tool, "adbdump", "--format", "json", str(path)], check=True,
                                    capture_output=True, timeout=30)
            info = json.loads(result.stdout)["info"]
            value = {"name": info["name"], "version": info["version"], "arch": info["arch"],
                     "installed_size": info["installed-size"]}
        except (subprocess.SubprocessError, KeyError, json.JSONDecodeError) as exc:
            raise ValueError(f"invalid native APK {path.name}") from exc
    elif path.suffix == ".ipk":
        with tarfile.open(path, "r:gz") as outer:
            control = member_bytes(outer, "control.tar.gz", MAX_CONTROL)
            payload = member_bytes(outer, "data.tar.gz", MAX_ARCHIVE)
        with tarfile.open(fileobj=io.BytesIO(control), mode="r:gz") as archive:
            text = member_bytes(archive, "control", MAX_CONTROL).decode("utf-8")
        # Verify through the final CRC, not only the tar end marker. No extraction.
        with gzip.GzipFile(fileobj=io.BytesIO(payload)) as stream:
            total = 0
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                total += len(chunk)
                if total > MAX_PAYLOAD:
                    raise ValueError("oversized IPK payload")
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
            archive.getmembers()
        def field(name):
            values = [line[len(name) + 2:] for line in text.splitlines() if line.startswith(name + ": ")]
            if len(values) != 1:
                raise ValueError(f"missing/duplicate IPK field {name}")
            return values[0]
        size = field("Installed-Size")
        if not size.isascii() or not size.isdigit():
            raise ValueError("invalid IPK installed size")
        value = {"name": field("Package"), "version": field("Version"), "arch": field("Architecture"),
                 "installed_size": int(size)}
    else:
        raise ValueError("unsupported package format")
    if any(not isinstance(value[key], str) or not value[key] or len(value[key]) > 128
           or re.search(r"[^A-Za-z0-9_.+~-]", value[key]) for key in ("name", "version", "arch")):
        raise ValueError("invalid native package identity")
    if type(value["installed_size"]) is not int or not 0 < value["installed_size"] <= MAX_PAYLOAD:
        raise ValueError("invalid native installed size")
    return value


def build_manifest(folder, version, engine, apk_tool="apk"):
    folder = Path(folder)
    for value in (version, engine):
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
            raise ValueError("invalid release version")
    assets = []
    for fmt in ("apk", "ipk"):
        for name, core, arch in [("xkop", version, "noarch" if fmt == "apk" else "all"),
                                ("luci-app-xkop", version, "noarch" if fmt == "apk" else "all")] + [
                ("xray-xkop", engine, arch) for arch in ARCHES]:
            suffix = "" if fmt == "apk" and name != "xray-xkop" else "-" + arch
            candidates = [folder / f"{name}-{core}-{revision}{suffix}.{fmt}" for revision in ("r1", "1")]
            candidates = [path for path in candidates if path.exists()]
            if len(candidates) != 1:
                raise ValueError(f"missing/ambiguous release package {name}-{core}{suffix}.{fmt}")
            path = candidates[0]
            info = package_metadata(path, apk_tool)
            exact = path.name[len(name) + 1:-(len(suffix) + len(fmt) + 1)]
            if info["name"] != name or info["version"] != exact or info["arch"] != arch:
                raise ValueError(f"package metadata mismatch: {path.name}")
            assets.append({"name": path.name, "sha256": sha256(path), "size": path.stat().st_size, "package": info})
    installer = folder / "install.sh"
    if installer.is_symlink() or not installer.is_file() or not 0 < installer.stat().st_size <= MAX_CONTROL:
        raise ValueError("missing/invalid installer")
    assets.append({"name": installer.name, "sha256": sha256(installer), "size": installer.stat().st_size})
    return {"schema": 1, "version": version, "engine": engine, "assets": assets}


def write_manifest(path, manifest):
    path = Path(path)
    temp = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, prefix=".manifest-", delete=False) as stream:
            temp = Path(stream.name)
            json.dump(manifest, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("version")
    parser.add_argument("engine")
    parser.add_argument("--apk-tool", default=os.environ.get("APK_TOOL", "apk"))
    args = parser.parse_args()
    manifest = build_manifest(args.folder, args.version, args.engine, args.apk_tool)
    write_manifest(args.folder / "release-manifest.json", manifest)


if __name__ == "__main__":
    main()
