#!/usr/bin/env python3
"""CI helper: print the UDID of the best available iPad simulator on iOS 26 or later.

Prefers a plain "iPad (A16)" (closest to a 9th-generation iPad), then any iPad, on the newest runtime.
Details go to stderr so stdout is just the UDID. Exits non-zero, loudly, if no iPad simulator exists.
"""
import json
import subprocess
import sys


def main():
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
    runtimes = json.loads(raw)["devices"]
    candidates = []
    for runtime, devices in runtimes.items():
        if "SimRuntime.iOS-" not in runtime:
            continue
        version = tuple(int(part) for part in runtime.split("SimRuntime.iOS-")[1].split("-"))
        if version[0] < 26:
            continue
        for device in devices:
            name = device["name"]
            if not name.startswith("iPad"):
                continue
            preference = 0 if name == "iPad (A16)" else 1
            candidates.append((preference, tuple(-v for v in version), name, device["udid"], runtime))
    if not candidates:
        print("error: no iPad simulator on iOS 26+ is installed on this runner", file=sys.stderr)
        print(raw.decode("utf-8", "replace"), file=sys.stderr)
        sys.exit(1)
    candidates.sort()
    _, _, name, udid, runtime = candidates[0]
    print("picked simulator %s (%s) on %s" % (name, udid, runtime), file=sys.stderr)
    print(udid)


if __name__ == "__main__":
    main()
