#!/usr/bin/env python3
"""Inspect built app/package metadata without installing or executing payloads."""

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


MINIMUM = (13, 0, 0)
BINARIES = {
    "gui": ("MacOS/Entoma", True),
    "proxy": ("Frameworks/proxy.framework/Versions/A/proxy", True),
    "window_ext": ("Frameworks/window_ext.framework/Versions/A/window_ext", True),
    # Toolchain-owned runtimes may support older systems. They must not require
    # anything newer than the app's supported minimum; do not patch vendor code.
    "aot": ("Frameworks/App.framework/Versions/A/App", False),
    "flutter": ("Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS", False),
    "core": ("MacOS/FlClashCore", False),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return (parts + (0, 0, 0))[:3]


def command(*args):
    return subprocess.check_output(args, text=True)


def binary(path, exact):
    architectures = command("xcrun", "lipo", "-archs", str(path)).split()
    require(bool(architectures), f"Missing Mach-O architectures: {path}")
    slices = {}
    for architecture in architectures:
        output = command("xcrun", "vtool", "-arch", architecture, "-show-build", str(path))
        match = re.search(r"^\s*minos\s+(\S+)", output, re.MULTILINE)
        if match is None and "LC_VERSION_MIN_MACOSX" in output:
            match = re.search(r"^\s*version\s+(\S+)", output, re.MULTILINE)
        require(match is not None, f"Missing macOS build version: {path} ({architecture})")
        minimum = match.group(1)
        require(version(minimum) == MINIMUM if exact else version(minimum) <= MINIMUM,
                f"Unexpected minimum {minimum}: {path} ({architecture})")
        slices[architecture] = minimum
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "slices": slices}


def app(path):
    with (path / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    require(info.get("CFBundleIdentifier") == "com.entoma.client", "Unexpected app identity")
    require(version(info.get("LSMinimumSystemVersion", "0")) == MINIMUM,
            "App Info.plist must require macOS13.0")
    binaries = {name: binary(path / "Contents" / relative, exact)
                for name, (relative, exact) in BINARIES.items()}
    gui_architectures = set(binaries["gui"]["slices"])
    for name, item in binaries.items():
        require(gui_architectures <= set(item["slices"]), f"Missing app architecture in {name}")
    return {"minimum": info["LSMinimumSystemVersion"], "binaries": binaries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--pkg", type=Path, required=True)
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    built = app(args.app)
    with tempfile.TemporaryDirectory(prefix="entoma-minimum-") as directory:
        expanded = Path(directory) / "expanded"
        subprocess.run(["pkgutil", "--expand-full", str(args.pkg.resolve()), str(expanded)],
                       check=True)
        distribution = ET.parse(expanded / "Distribution").getroot()
        ranges = distribution.findall(".//allowed-os-versions/os-version")
        require(len(ranges) == 1 and version(ranges[0].get("min", "0")) == MINIMUM
                and ranges[0].get("before") is None,
                "Installer must contain one open-ended macOS13.0 minimum range")
        options = distribution.find("options")
        require(options is not None and set(options.get("hostArchitectures", "").split(","))
                == {"arm64", "x86_64"}, "Unexpected installer architectures")
        payloads = list(expanded.rglob("Entoma.app"))
        require(len(payloads) == 1, "Expected one actual Entoma app payload")
        payload = app(payloads[0])
        require(payload == built, "Installer payload differs from the verified built app")
        report = {
            "sourceSha": command("git", "rev-parse", "HEAD").strip(),
            "trackedSourceDirty": subprocess.run(
                ["git", "diff", "--quiet", "--ignore-submodules=all", "HEAD"],
                check=False).returncode != 0,
            "requiredMacOS": "13.0", "app": built,
            "installer": {"minimum": ranges[0].get("min"),
                          "sha256": hashlib.sha256(args.pkg.read_bytes()).hexdigest(),
                          "payloadMatchesBuiltApp": True},
            "verification": "static artifact inspection; no payload install or execution",
        }
    if args.helper is not None:
        report["helper"] = binary(args.helper, True)
        require(set(report["helper"]["slices"]) == {"arm64", "x86_64"},
                "Expected universal helper")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: App plist, all Mach-O slices, installer gate and packaged payload minimum verified")


if __name__ == "__main__":
    main()
