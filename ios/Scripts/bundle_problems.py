#!/usr/bin/python3
"""Xcode post-build step: copy the course banks from shared/ into the app bundle.

Writes into the app's resources folder:
  courses.json          the manifest: slug, title, group, grade, count and the resource name of each course
  course-<slug>.json    the problems of one course
  problems.json         the original twelve BC Math 9 unit 3 problems (kept for the older flat list)

Only the fields the iPad needs are copied (id, prompt_plain, prompt_latex, prompt_parts). The worked solutions and final
answers stay on the server, so a student cannot read them out of the app. The manifest is shared/courses/index.json, built by
`npm run build-courses` in server/. A missing, malformed or stale source fails the build loudly (a course folder that is not in
the manifest, or a count that no longer matches its file).
"""
import json
import os
import sys

KEEP = ("id", "prompt_plain", "prompt_latex", "prompt_parts")
REQUIRED = ("id", "prompt_plain")


def fail(message):
    print("error: bundle_problems: " + message, file=sys.stderr)
    sys.exit(1)


def load_json(path, what):
    if not os.path.isfile(path):
        fail(what + " not found at " + path)
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except ValueError as err:
        fail(what + " is not valid JSON: " + str(err))


def trim(problems, what):
    if not isinstance(problems, list) or not problems:
        fail(what + " must be a non-empty array")
    trimmed = []
    for entry in problems:
        missing = [key for key in REQUIRED if key not in entry]
        if missing:
            fail(what + ": problem " + str(entry.get("id", "?")) + " is missing " + ", ".join(missing))
        trimmed.append({key: entry[key] for key in KEEP if key in entry})
    return trimmed


def write(path, value):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False)


def main():
    srcroot = os.environ.get("SRCROOT")
    build_dir = os.environ.get("TARGET_BUILD_DIR")
    resources = os.environ.get("UNLOCALIZED_RESOURCES_FOLDER_PATH")
    if not (srcroot and build_dir and resources):
        fail("Xcode build variables are missing (SRCROOT, TARGET_BUILD_DIR, UNLOCALIZED_RESOURCES_FOLDER_PATH)")

    shared = os.path.normpath(os.path.join(srcroot, "..", "shared"))
    dest_dir = os.path.join(build_dir, resources)
    os.makedirs(dest_dir, exist_ok=True)

    manifest = load_json(os.path.join(shared, "courses", "index.json"), "course manifest")
    courses = manifest.get("courses") if isinstance(manifest, dict) else None
    if not isinstance(courses, list) or not courses:
        fail("the course manifest must hold a non-empty list of courses")

    # A course folder the manifest does not list means somebody forgot `npm run build-courses`.
    folders = sorted(
        name for name in os.listdir(os.path.join(shared, "courses")) if os.path.isdir(os.path.join(shared, "courses", name))
    )
    listed = sorted(c["slug"] for c in courses if c["file"].startswith("courses/"))
    if folders != listed:
        fail("course folders %s do not match the manifest %s: run `npm run build-courses` in server/" % (folders, listed))

    seen = set()
    bundled = []
    total = 0
    for course in courses:
        slug = course["slug"]
        trimmed = trim(load_json(os.path.join(shared, course["file"]), "course " + slug), "course " + slug)
        if len(trimmed) != course["count"]:
            fail("course %s has %d problems but the manifest says %d: run `npm run build-courses` in server/" % (slug, len(trimmed), course["count"]))
        for problem in trimmed:
            if problem["id"] in seen:
                fail("duplicate problem id " + problem["id"])
            seen.add(problem["id"])
        resource = "course-" + slug
        write(os.path.join(dest_dir, resource + ".json"), trimmed)
        bundled.append({
            "slug": slug,
            "title": course["title"],
            "group": course["group"],
            "grade": course.get("grade"),
            "count": len(trimmed),
            "resource": resource,
        })
        total += len(trimmed)
    write(os.path.join(dest_dir, "courses.json"), {"version": 1, "courses": bundled})

    legacy = trim(load_json(os.path.join(shared, "problems.json"), "problem bank"), "problems.json")
    write(os.path.join(dest_dir, "problems.json"), legacy)

    print("bundle_problems: wrote %d courses, %d problems (+ %d legacy) to %s (dropped worked_solution, final_answer, source)"
          % (len(bundled), total, len(legacy), dest_dir))


if __name__ == "__main__":
    main()
