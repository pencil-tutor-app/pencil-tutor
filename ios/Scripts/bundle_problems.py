#!/usr/bin/python3
"""Xcode post-build step: copy shared/problems.json into the app bundle.

Only the fields the iPad needs are copied (id, prompt_plain, prompt_latex, prompt_parts).
The worked solutions and final answers stay on the server, so a student cannot read them
out of the app. A missing or malformed source file fails the build loudly.
"""
import json
import os
import sys

KEEP = ("id", "prompt_plain", "prompt_latex", "prompt_parts")


def fail(message):
    print("error: bundle_problems: " + message, file=sys.stderr)
    sys.exit(1)


def main():
    srcroot = os.environ.get("SRCROOT")
    build_dir = os.environ.get("TARGET_BUILD_DIR")
    resources = os.environ.get("UNLOCALIZED_RESOURCES_FOLDER_PATH")
    if not (srcroot and build_dir and resources):
        fail("Xcode build variables are missing (SRCROOT, TARGET_BUILD_DIR, UNLOCALIZED_RESOURCES_FOLDER_PATH)")

    source = os.path.normpath(os.path.join(srcroot, "..", "shared", "problems.json"))
    dest = os.path.join(build_dir, resources, "problems.json")

    if not os.path.isfile(source):
        fail("problem bank not found at " + source)
    try:
        with open(source, encoding="utf-8") as handle:
            problems = json.load(handle)
    except ValueError as err:
        fail("problems.json is not valid JSON: " + str(err))
    if not isinstance(problems, list) or not problems:
        fail("problems.json must be a non-empty array")

    trimmed = []
    for entry in problems:
        missing = [key for key in ("id", "prompt_plain") if key not in entry]
        if missing:
            fail("problem " + str(entry.get("id", "?")) + " is missing " + ", ".join(missing))
        trimmed.append({key: entry[key] for key in KEEP if key in entry})

    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w", encoding="utf-8") as handle:
        json.dump(trimmed, handle, ensure_ascii=False)
    print("bundle_problems: wrote %d problems to %s (dropped worked_solution, final_answer, source)" % (len(trimmed), dest))


if __name__ == "__main__":
    main()
