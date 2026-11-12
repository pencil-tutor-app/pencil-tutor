#!/usr/bin/env python3
"""CI helper: export the screenshots a UI test attached to an .xcresult as plain PNG files.

usage: ci_export_screenshots.py <result.xcresult> <output-dir>

Uses `xcresulttool export attachments`, then renames the exported files with the attachment names the
test gave them (01-planted-problem-shown.png, ...). Exits non-zero if nothing was exported, so an empty
receipt can never look like a pass.
"""
import json
import os
import re
import shutil
import subprocess
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: ci_export_screenshots.py <result.xcresult> <output-dir>", file=sys.stderr)
        sys.exit(2)
    bundle, out_dir = sys.argv[1], sys.argv[2]
    raw_dir = out_dir.rstrip("/") + "-raw"
    for path in (raw_dir, out_dir):
        shutil.rmtree(path, ignore_errors=True)
        os.makedirs(path)

    subprocess.check_call(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", raw_dir])

    exported = 0
    manifest_path = os.path.join(raw_dir, "manifest.json")
    if os.path.isfile(manifest_path):
        with open(manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        for test in manifest:
            for attachment in test.get("attachments", []):
                source = os.path.join(raw_dir, attachment["exportedFileName"])
                human = attachment.get("suggestedHumanReadableName") or attachment["exportedFileName"]
                human = re.sub(r"_\d+_[0-9A-Fa-f-]{36}", "", human)
                if not human.lower().endswith(".png"):
                    human += ".png"
                if not os.path.isfile(source):
                    print("warning: manifest lists %s but the file is missing" % source, file=sys.stderr)
                    continue
                shutil.copy(source, os.path.join(out_dir, human))
                print("exported %s (%d bytes)" % (human, os.path.getsize(source)))
                exported += 1
    else:
        print("warning: no manifest.json in %s; copying every png" % raw_dir, file=sys.stderr)
        for name in sorted(os.listdir(raw_dir)):
            if name.lower().endswith(".png"):
                shutil.copy(os.path.join(raw_dir, name), os.path.join(out_dir, name))
                exported += 1

    if exported == 0:
        print("error: no screenshots were exported from %s" % bundle, file=sys.stderr)
        sys.exit(1)
    print("exported %d screenshots to %s" % (exported, out_dir))


if __name__ == "__main__":
    main()
