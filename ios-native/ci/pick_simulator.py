#!/usr/bin/env python3
"""Pick the best available iPhone simulator (newest iOS runtime, prefer "iPhone NN Pro").

Prints three lines: UDID, device name, runtime identifier.
Usage: python3 pick_simulator.py
"""
import json
import re
import subprocess
import sys


def runtime_version(identifier):
    m = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", identifier)
    if not m:
        return None
    return tuple(int(x or 0) for x in m.groups())


def name_score(name):
    m = re.search(r"iPhone (\d+)", name)
    model = int(m.group(1)) if m else 0
    if re.fullmatch(r"iPhone \d+ Pro", name):
        kind = 3
    elif re.fullmatch(r"iPhone \d+", name):
        kind = 2
    elif "Pro" in name:
        kind = 1
    else:
        kind = 0
    return (kind, model)


def main():
    out = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
    data = json.loads(out)
    best = None
    for runtime, devices in data.get("devices", {}).items():
        ver = runtime_version(runtime)
        if ver is None or ver[0] < 16:
            continue
        for dev in devices:
            name = dev.get("name", "")
            if not name.startswith("iPhone") or not dev.get("isAvailable", True):
                continue
            key = (ver, name_score(name))
            if best is None or key > best[0]:
                best = (key, dev["udid"], name, runtime)
    if best is None:
        print("no available iPhone simulator found", file=sys.stderr)
        sys.exit(1)
    print(best[1])
    print(best[2])
    print(best[3])


if __name__ == "__main__":
    main()
