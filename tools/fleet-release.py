#!/usr/bin/env python3
"""Build an immutable, signed preparation bundle. No key generation or upload."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


def build(spec, artifacts, output, key, public_key):
    if output.exists() or output.is_symlink():
        raise ValueError("Output already exists; immutable releases cannot be replaced")
    if not output.parent.is_dir():
        raise ValueError("Output parent must exist")
    if spec.stat().st_size > 16384:
        raise ValueError("Release specification is too large")
    manifest = json.loads(spec.read_text(encoding="utf-8"))
    publication_lock = output.with_name(output.name + ".publishing")
    descriptor = os.open(publication_lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    staging = None
    try:
        if output.exists() or output.is_symlink():
            raise ValueError("Output already exists")
        staging = Path(tempfile.mkdtemp(prefix=".fleet-release-", dir=output.parent))
        names = set()
        packages = manifest["packages"]
        if not isinstance(packages, list) or not 1 <= len(packages) <= 3:
            raise ValueError("Invalid packages")
        for package in packages:
            for direction in ("forward", "rollback"):
                item = package[direction]
                filename = item["file"]
                if (not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9_+~-][A-Za-z0-9._+~-]{0,127}", filename)
                        or ".." in filename or filename in names):
                    raise ValueError("Invalid or duplicate artifact filename")
                names.add(filename)
                source = artifacts / filename
                if source.is_symlink() or not source.is_file() or not 0 < source.stat().st_size <= 67108864:
                    raise ValueError("Artifact must be a regular file between 1 byte and 64 MiB")
                destination = staging / filename
                # Hash the snapshot to be published, not a source that may change later.
                shutil.copyfile(source, destination)
                item["size"] = destination.stat().st_size
                item["sha256"] = hashlib.sha256(destination.read_bytes()).hexdigest()
        message = staging / "manifest.json"
        message.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        if message.stat().st_size > 16384:
            raise ValueError("Final manifest is too large")
        schema = Path(__file__).resolve().parents[1] / "xkop/files/usr/lib/xkop/fleet-manifest.jq"
        subprocess.run(["jq", "-e", "--argjson", "now", str(int(time.time())), "-f", str(schema), str(message)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        subprocess.run(["usign", "-S", "-s", str(key), "-m", str(message), "-x", str(message) + ".sig"],
                       check=True, capture_output=True, timeout=15)
        subprocess.run(["usign", "-V", "-q", "-p", str(public_key), "-m", str(message), "-x", str(message) + ".sig"],
                       check=True, capture_output=True, timeout=15)
        pin = hashlib.sha256(message.read_bytes()).hexdigest()
        # Same-filesystem rename makes the complete signed directory visible at
        # once. The exclusive lock serializes this tool's competing publishers.
        (staging / "READY").write_text(pin + "\n", encoding="ascii")
        os.rename(staging, output)
        staging = None
        return pin
    finally:
        if staging is not None:
            shutil.rmtree(staging)
        publication_lock.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("spec", "artifacts", "output", "key", "public-key"):
        parser.add_argument("--" + option, type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        print(build(args.spec, args.artifacts, args.output, args.key, args.public_key))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Never echo manifests or signing tool stderr, which can contain private paths.
        parser.exit(1, "Release preparation failed; check inputs, key pair and dependencies.\n")


if __name__ == "__main__":
    main()
