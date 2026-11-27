#!/usr/bin/env python3
"""CI check: a Release build's session log holds counts and labels, never words.

Usage: check_release_log.py <folder with session-*.jsonl copied from the simulator>

The Release configuration keeps TutorSession.logsWords false, so nothing the student or the tutor said may reach the session
log. The lesson UI test types the concept "solving equations" and asks "why undo the last one first", and the scripted tutor
answers with a fixed lesson, so those strings (and the lesson, the practice problem and the sealed reference) are the canaries.
Also checks that the lesson events were written at all (a log that says nothing proves nothing).
Exit 0 when every rule holds, 1 with a line per violation, 2 when there is nothing to check.
"""
import glob
import json
import os
import sys

# Words that must never appear anywhere in a Release session log.
FORBIDDEN_TEXT = [
    "solving equations",              # the concept the UI test types
    "why undo the last one first",    # the follow-up the UI test types
    "Undoing an operation",           # the scripted lesson's title
    "Undo what was done to x",        # the scripted lesson's spoken line
    "Solve 2x + 1 = 9",               # the scripted example
    "Solve 3x + 2 = 14",              # the scripted practice problem
    "scripted-practice-ref",          # the scripted sealed reference
    "Scripted answer. Undo the last", # the scripted follow-up answer
]

# Field names that only Debug builds may write (TutorSession.logsWords).
FORBIDDEN_KEYS = {"concept", "question", "answer", "student_said", "tutor_said", "hint_spoken", "page_report", "text", "message"}

# Events the lesson flow must have written, each with the fields that carry its counts.
REQUIRED_EVENTS = {
    "lesson_requested": ["concept_chars", "course"],
    "lesson_shown": ["latency_ms", "steps"],
    "practice_ready": ["reference", "latency_ms"],
    "lesson_followup": ["chars", "recent_turns", "latency_ms"],
}


def main(folder):
    files = sorted(glob.glob(os.path.join(folder, "session-*.jsonl")))
    if not files:
        print("no session-*.jsonl in %s: nothing to check" % folder)
        return 2
    problems = []
    seen = {}
    for path in files:
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                line = line.strip()
                if not line:
                    continue
                where = "%s:%d" % (os.path.basename(path), number)
                try:
                    event = json.loads(line)
                except ValueError:
                    problems.append("%s: not JSON" % where)
                    continue
                kind = event.get("type", "?")
                seen.setdefault(kind, event)
                for needle in FORBIDDEN_TEXT:
                    if needle.lower() in line.lower():
                        problems.append("%s: %s event contains the text %r" % (where, kind, needle))
                for key in FORBIDDEN_KEYS & set(event):
                    problems.append("%s: %s event has the Debug-only field %r" % (where, kind, key))
    for kind, fields in REQUIRED_EVENTS.items():
        event = seen.get(kind)
        if event is None:
            problems.append("missing event %s: the lesson flow did not write it" % kind)
            continue
        for field in fields:
            if field not in event:
                problems.append("event %s has no field %r" % (kind, field))
    if problems:
        print("RELEASE LOG CHECK FAILED (%d):" % len(problems))
        for problem in problems[:60]:
            print("  " + problem)
        return 1
    print("release log check ok: %d files, %d event types, no words" % (len(files), len(seen)))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
