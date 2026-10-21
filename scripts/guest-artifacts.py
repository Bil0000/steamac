#!/usr/bin/env python3
"""Content-based build receipts; called by the guest builds and release packagers.

Only selected Git inputs are hashed, using working-tree bytes (not HEAD/index).
A receipt is published only after a successful build with unchanged inputs, and
binds those inputs to the output bytes. Never adopt an unproven existing output.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "work/out"
MESA_INPUTS = (
    "guest/mesa/build.sh", "guest/mesa/versions.env", "guest/mesa/container",
    "scripts/config.env", "scripts/steps/10-rootfs.sh",
    "scripts/builder/Dockerfile", "scripts/keys/steamdeck-images.pem",
)
INPUTS = {
    "kernel": ("guest/kernel/build.sh", "guest/kernel/container-build.sh",
               "guest/kernel/Dockerfile", "guest/kernel/check-config.sh",
               "guest/kernel/config", "guest/kernel/patches"),
    "initramfs": ("guest/initramfs/init", "scripts/build-image.sh",
                  "scripts/steps/20-initramfs.sh", "scripts/config.env",
                  "scripts/builder/Dockerfile"),
    "mesa": MESA_INPUTS,
    "mesa-aarch64": MESA_INPUTS,
    "mesa-x86": MESA_INPUTS,
    "layer": ("guest/layer/usr", "guest/progress-agent", "fex-eac/build-fex.sh", "fex-eac/install-fex-tool.sh", "scripts/build-image.sh",
              "scripts/steps/25-progress-agent.sh", "scripts/steps/30-layer.sh") + MESA_INPUTS,
}
OUTPUTS = {
    "kernel": (OUT / "Image",),
    "initramfs": (OUT / "initramfs.cpio.gz",),
    "mesa": (OUT / "mesa-venus",),
    "mesa-aarch64": (OUT / "mesa-venus/usr/lib/libvulkan_virtio.so", OUT / "mesa-venus/usr/share/vulkan"),
    "mesa-x86": (OUT / "mesa-venus/usr/share/guestos", OUT / "mesa-venus/usr/lib/steamac"),
    "layer": (OUT / "steamac-layer.img",),
}
COMMANDS = {
    "kernel": "guest/kernel/build.sh",
    "initramfs": "scripts/build-image.sh builder initramfs",
    "mesa": "scripts/build-image.sh builder rootfs && guest/mesa/build.sh",
    "mesa-aarch64": "guest/mesa/build.sh fetch aarch64",
    "mesa-x86": "guest/mesa/build.sh fetch x86",
    "layer": "scripts/build-image.sh builder layer",
}


def fail(kind, reason):
    raise ValueError(f"{kind}: {reason}; rerun `{COMMANDS[kind]}`")


def stamp_path(kind, resources=None):
    if resources is not None:
        return resources / (OUTPUTS[kind][0].name + ".inputs.json")
    if kind.startswith("mesa-"):
        return OUT / (kind + ".inputs.json")
    return OUTPUTS[kind][0].with_name(OUTPUTS[kind][0].name + ".inputs.json")


def add_record(digest, *fields):
    for field in fields:
        data = os.fsencode(field)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def hash_entry(digest, path, name):
    if path.is_symlink():
        add_record(digest, name, "symlink", os.readlink(path))
    elif path.is_file():
        add_record(digest, name, "executable" if path.stat().st_mode & 0o111 else "file",
                   file_digest(path))
    else:
        raise ValueError(f"missing or unsupported input: {path}")


def input_digest(kind):
    paths = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others",
         "--exclude-standard", "--", *INPUTS[kind]]).split(b"\0")
    digest = hashlib.sha256()
    add_record(digest, "steamac-guest-inputs-1", kind)
    for name in sorted(set(p for p in paths if p)):
        try:
            hash_entry(digest, ROOT / os.fsdecode(name), name)
        except (OSError, ValueError) as error:
            fail(kind, f"missing/invalid source input ({error})")
    if kind in ("initramfs", "layer"):
        add_record(digest, "SOURCE_DATE_EPOCH", os.environ.get("SOURCE_DATE_EPOCH", "1767225600"))
    if kind == "layer":
        check("mesa")
        add_record(digest, "mesa-receipt", file_digest(stamp_path("mesa")))
    if kind == "mesa":
        for architecture in ("mesa-aarch64", "mesa-x86"):
            check(architecture)
            add_record(digest, architecture, file_digest(stamp_path(architecture)))
    return digest.hexdigest()


def output_digest(kind, resources=None):
    digest = hashlib.sha256()
    paths = OUTPUTS[kind] if resources is None else (resources / OUTPUTS[kind][0].name,)
    for index, path in enumerate(paths):
        if path.is_dir() and not path.is_symlink():
            add_record(digest, str(index), "directory")
            for directory, dirs, files in os.walk(path, followlinks=False):
                # Include symlinked directories without following them.
                for name in sorted(dirs + files):
                    entry = Path(directory) / name
                    relative = entry.relative_to(path)
                    if entry.is_dir() and not entry.is_symlink():
                        add_record(digest, str(index), str(relative), "directory")
                    else:
                        hash_entry(digest, entry, f"{index}/{relative}")
                dirs.sort()
        else:
            hash_entry(digest, path, str(index))
    return digest.hexdigest()


def check(kind, resources=None):
    try:
        receipt = json.loads(stamp_path(kind, resources).read_text())
    except (OSError, ValueError) as error:
        fail(kind, f"missing/invalid input stamp ({error})")
    if not isinstance(receipt, dict) or receipt.get("version") != 1 or receipt.get("kind") != kind:
        fail(kind, "invalid input stamp")
    if receipt.get("inputs") != input_digest(kind):
        fail(kind, "stale source inputs")
    try:
        output = output_digest(kind, resources)
    except (OSError, ValueError) as error:
        fail(kind, f"missing/invalid artifact ({error})")
    if receipt.get("output") != output:
        fail(kind, "artifact bytes differ from successful build")


def main():
    action = sys.argv[1]
    if action in ("check-release", "check-bundle"):
        resources = Path(sys.argv[2]) if action == "check-bundle" else None
        for kind in ("kernel", "initramfs", "layer"):
            try:
                check(kind, resources)
            except ValueError as error:
                if resources is not None:
                    raise ValueError(f"{error}; then rerun `host/launcher/build.sh` to refresh the app") from error
                raise
        return
    kind = sys.argv[2]
    stamp = stamp_path(kind)
    if action in ("begin", "invalidate"):
        stamp.unlink(missing_ok=True)
        if action == "begin":
            print(input_digest(kind))
    elif action == "finish":
        inputs = input_digest(kind)
        if inputs != sys.argv[3]:
            fail(kind, "inputs changed during build")
        receipt = {"version": 1, "kind": kind, "inputs": inputs,
                   "output": output_digest(kind)}
        temporary = stamp.with_name(stamp.name + f".tmp.{os.getpid()}")
        try:
            temporary.write_text(json.dumps(receipt, sort_keys=True) + "\n")
            temporary.replace(stamp)
        finally:
            temporary.unlink(missing_ok=True)
    elif action == "check":
        check(kind)
    else:
        raise ValueError(f"unknown action: {action}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"guest artifacts: {error}")
