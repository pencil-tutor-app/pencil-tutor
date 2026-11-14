#!/usr/bin/env python3
"""Run ink scripts through the real Pencil Tutor app, on the iPad or in a simulator, and score what the tutor did.

For each case: copy the ink script into the app's Documents folder, launch the Debug app with
`--open-problem <id> --replay-ink <file>`, wait for the app to log `replay_done`, pull the session log, the page pictures that
were sent to the tutor and a screenshot of the screen, then score the log.

  python3 tools/handwriting/run_device.py --cases-dir tools/handwriting/cases --out-dir runs/2026-11-15 [--case ID ...]
  python3 tools/handwriting/run_device.py --target sim --sim-udid <UDID> --student-code-env STUDENT_CODE ...   (a simulator has
      no Keychain code yet: pass one through that environment variable; it is never printed or written)

The iPad must be unlocked. The Debug app must already be installed (see docs/evals/2026-11-15-handwriting-replay.md).
Scoring reads labels and counts from the log only. Standard library only.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time

BUNDLE = "com.edwardtran.penciltutor"
DEFAULT_DEVICE = "00008030-0002101902D0202E"


def run(cmd: list[str], timeout: int = 120, check: bool = False) -> subprocess.CompletedProcess:
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:5])}... failed ({result.returncode}): {(result.stderr or result.stdout)[-400:]}")
    return result


class Target:
    """Where the app runs. `device` is the iPad over devicectl; `sim` is a booted simulator."""

    def __init__(self, kind: str, device: str, sim_udid: str | None, student_code_env: str | None):
        self.kind, self.device, self.sim_udid = kind, device, sim_udid
        self.code = os.environ.get(student_code_env) if student_code_env else None
        self._container: str | None = None

    # -- files
    def container(self) -> str:
        if self._container is None:
            out = run(["xcrun", "simctl", "get_app_container", self.sim_udid, BUNDLE, "data"], check=True)
            self._container = out.stdout.strip()
        return self._container

    def copy_to(self, local: str, remote_name: str) -> None:
        if self.kind == "device":
            run(["xcrun", "devicectl", "device", "copy", "to", "--device", self.device, "--domain-type", "appDataContainer",
                 "--domain-identifier", BUNDLE, "--source", local, "--destination", f"Documents/{remote_name}"], check=True)
        else:
            run(["cp", local, os.path.join(self.container(), "Documents", remote_name)], check=True)

    def list_documents(self) -> list[str]:
        if self.kind == "device":
            out = run(["xcrun", "devicectl", "device", "info", "files", "--device", self.device, "--domain-type",
                       "appDataContainer", "--domain-identifier", BUNDLE])
            return sorted(set(re.findall(r"Documents/([^\s]+\.(?:jsonl|png))", out.stdout)))
        docs = os.path.join(self.container(), "Documents")
        return sorted(f for f in os.listdir(docs) if f.endswith((".jsonl", ".png")))

    def copy_from(self, remote_name: str, local: str) -> bool:
        if self.kind == "device":
            result = run(["xcrun", "devicectl", "device", "copy", "from", "--device", self.device, "--domain-type",
                          "appDataContainer", "--domain-identifier", BUNDLE, "--source", f"Documents/{remote_name}",
                          "--destination", local])
            return result.returncode == 0 and os.path.exists(local)
        src = os.path.join(self.container(), "Documents", remote_name)
        if os.path.exists(src):
            run(["cp", src, local])
            return True
        return False

    # -- the app
    def launch(self, problem_id: str, script_name: str, settle: int) -> tuple[bool, str]:
        # --silent always: the tutor's voice still runs and is logged, but plays at volume 0 (nobody is listening at night).
        args = ["--open-problem", problem_id, "--replay-ink", script_name, "--replay-settle", str(settle), "--silent"]
        if self.kind == "device":
            result = run(["xcrun", "devicectl", "device", "process", "launch", "--device", self.device, "--terminate-existing",
                          BUNDLE, *args], timeout=90)
        else:
            run(["xcrun", "simctl", "terminate", self.sim_udid, BUNDLE])
            extra = ["--student-code", self.code] if self.code else []
            result = run(["xcrun", "simctl", "launch", self.sim_udid, BUNDLE, *args, *extra], timeout=60)
        text = (result.stdout + result.stderr)
        return result.returncode == 0, re.sub(r"\s+", " ", text.replace(self.code or "\0", "<code>"))[-300:]

    def terminate(self) -> None:
        if self.kind == "device":
            listing = run(["xcrun", "devicectl", "device", "info", "processes", "--device", self.device], timeout=60).stdout
            for line in listing.splitlines():
                match = re.match(r"\s*(\d+)\s+.*PencilTutor\.app/PencilTutor", line)
                if match:
                    run(["xcrun", "devicectl", "device", "process", "terminate", "--device", self.device, "--pid", match.group(1)])
        else:
            run(["xcrun", "simctl", "terminate", self.sim_udid, BUNDLE])


# ------------------------------------------------------------------------------------------------------- scoring
def parse_time(text: str) -> float:
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def read_events(path: str) -> list[dict]:
    events = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            try:
                event = json.loads(raw)
                event["_ts"] = parse_time(event["t"])
                events.append(event)
            except (ValueError, KeyError):
                continue
    return events


def score(case: dict, script: dict, events: list[dict]) -> dict:
    """What the tutor did, against what was planted. Returns a flat dict of labels and numbers."""
    by_type: dict[str, list[dict]] = {}
    for event in events:
        by_type.setdefault(event["type"], []).append(event)
    expected = script["expected"]
    result: dict = {"case": case["id"], "expected": expected["outcome"], "mistake_line": expected.get("line"),
                    "app_line": expected.get("app_line"), "silent": "voice_muted_for_test" in by_type}
    failed = by_type.get("replay_failed")
    if failed:
        return {**result, "verdict": "REPLAY_FAILED", "detail": failed[0].get("reason", "")}
    if "replay_done" not in by_type:
        return {**result, "verdict": "NO_REPLAY_DONE", "detail": "the app never logged replay_done"}
    batches = {int(e["line"]): e for e in by_type.get("replay_stroke_batch", [])}
    finished = (by_type.get("replay_finished") or [{}])[0]
    decisions = by_type.get("decision", [])
    interrupts = [d for d in decisions if d.get("action") == "interrupt"]
    waits = [d for d in decisions if d.get("action") == "wait"]
    result.update({
        "script_lines": len(script["lines"]), "strokes_drawn": finished.get("strokes_drawn"),
        "drawing_strokes": finished.get("drawing_strokes"), "max_late_ms": finished.get("max_late_ms"),
        "ink_changed_events": len(by_type.get("ink_changed", [])),
        "looks": len(by_type.get("look_started", [])), "waits": len(waits), "interrupts": len(interrupts),
        "discards": len(by_type.get("discard", [])), "errors": len(by_type.get("error", [])),
        "marks_on_screen": (by_type.get("replay_done") or [{}])[0].get("marks"),
        "interrupt_lines": [d.get("line") for d in interrupts],
    })
    if (finished.get("strokes_drawn") or 0) > 0 and result["ink_changed_events"] == 0:
        result["warning"] = "delegate_not_fired"        # PencilKit did not report the replayed strokes; nothing below is meaningful
    elif result["ink_changed_events"] != finished.get("strokes_drawn"):
        result["ink_changed_vs_strokes"] = f"{result['ink_changed_events']} events for {finished.get('strokes_drawn')} strokes"
    groupings = by_type.get("ink_changed", [])      # the grouper's count after the last stroke: all the work, not what a look saw
    expected_app_lines = sum(l.get("app_lines", 1) for l in script["lines"])
    if groupings:
        result["app_lines_seen"] = groupings[-1].get("lines")
        result["grouping_matches_script"] = groupings[-1].get("lines") == expected_app_lines
    result["app_lines_expected"] = expected_app_lines
    if not decisions:
        return {**result, "verdict": "NO_DECISION", "detail": "the app made no watch decision (errors or no look happened)"}

    if expected["outcome"] == "no_mistake":
        result["verdict"] = "PASS" if not interrupts else "FALSE_ALARM"
        return result

    first_line = expected["app_line"]
    rows = next(l["app_lines"] for l in script["lines"] if l["index"] == expected["line"])
    wanted = range(first_line, first_line + rows)
    hit = next((d for d in interrupts if d.get("line") in wanted), None)
    early = [d for d in interrupts if isinstance(d.get("line"), int) and d["line"] < first_line]
    late = [d for d in interrupts if isinstance(d.get("line"), int) and d["line"] >= first_line + rows]
    result["false_alarm_lines"] = [d.get("line") for d in early]
    result["other_lines_flagged"] = [d.get("line") for d in late]
    if hit:
        started_at = (by_type.get("replay_started") or [{}])[0].get("_ts")
        written_at = batches.get(expected["line"], {}).get("_ts")
        if written_at:
            result["seconds_from_line_written_to_mark"] = round(hit["_ts"] - written_at, 1)
        if finished.get("_ts"):
            result["seconds_from_last_stroke_to_mark"] = round(hit["_ts"] - finished["_ts"], 1)
        following = next((l for l in script["lines"] if l["index"] == expected["line"] + 1), None)
        if started_at and following:
            # did the mark land while the student was still thinking after the bad line, before the next line began?
            result["mark_before_next_line_started"] = hit["_ts"] < started_at + following["t_start"]
        result["model_latency_ms"] = hit.get("server_latency_ms")
        result["verdict"] = "PASS" if not early else "PASS_WITH_FALSE_ALARM"
    elif interrupts:
        result["verdict"] = "WRONG_LINE"
    else:
        result["verdict"] = "MISSED"
    return result


# ---------------------------------------------------------------------------------------------------------- main
def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cases-dir", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--case", action="append", help="case id to run (default: all in cases.json)")
    parser.add_argument("--target", choices=["device", "sim"], default="device")
    parser.add_argument("--device", default=DEFAULT_DEVICE)
    parser.add_argument("--sim-udid")
    parser.add_argument("--student-code-env", help="name of an environment variable holding a student code (simulator only)")
    parser.add_argument("--settle", type=int, default=20, help="seconds the app waits after the last stroke before it stops")
    parser.add_argument("--max-wait", type=int, default=240, help="seconds to wait for a case after its script ends")
    args = parser.parse_args()
    if args.target == "sim" and not args.sim_udid:
        sys.exit("--sim-udid is required for --target sim")

    os.makedirs(args.out_dir, exist_ok=True)
    with open(os.path.join(args.cases_dir, "cases.json"), encoding="utf-8") as handle:
        cases = json.load(handle)
    if args.case:
        cases = [c for c in cases if c["id"] in args.case]
    target = Target(args.target, args.device, args.sim_udid, args.student_code_env)
    results = []
    for case in cases:
        case_dir = os.path.join(args.out_dir, case["id"])
        os.makedirs(case_dir, exist_ok=True)
        local_script = os.path.join(args.cases_dir, case["file"])
        with open(local_script, encoding="utf-8") as handle:
            script = json.load(handle)
        print(f"== {case['id']}  ({script['duration_s']}s of ink)", flush=True)
        before = set(target.list_documents())
        target.copy_to(local_script, case["file"])
        launched_at = time.time()
        ok, note = target.launch(case["problem_id"], case["file"], args.settle)
        if not ok:
            print("   launch failed:", note, flush=True)
            results.append({"case": case["id"], "verdict": "LAUNCH_FAILED", "detail": note})
            continue
        deadline = launched_at + script["duration_s"] + args.settle + args.max_wait
        log_name, events, done = None, [], False
        while time.time() < deadline and not done:
            time.sleep(6)
            new_logs = sorted(f for f in target.list_documents() if f.startswith("session-") and f.endswith(".jsonl") and f not in before)
            if not new_logs:
                continue
            log_name = new_logs[-1]
            local_log = os.path.join(case_dir, "session.jsonl")
            if target.copy_from(log_name, local_log):
                events = read_events(local_log)
                done = any(e["type"] in ("replay_done", "replay_failed") for e in events)
        if not log_name:
            print("   no session log appeared", flush=True)
            results.append({"case": case["id"], "verdict": "NO_LOG"})
            continue
        stamp = log_name[len("session-"):-len(".jsonl")]
        for name in target.list_documents():
            if name not in before and name.endswith(".png") and (name.startswith("page-" + stamp) or name.startswith("screen-")):
                target.copy_from(name, os.path.join(case_dir, name))
        outcome = score(case, script, events)
        if not done:
            outcome["verdict"] = "TIMEOUT"
        results.append(outcome)
        with open(os.path.join(case_dir, "score.json"), "w", encoding="utf-8") as handle:
            json.dump(outcome, handle, indent=1)
        print("  ", json.dumps({k: v for k, v in outcome.items() if k != "case"}), flush=True)
        if not outcome.get("silent"):
            # The installed app is an old build without --silent: stop before the next run speaks aloud.
            print("STOPPING: this run did not log voice_muted_for_test, so the app may have spoken. Install a build with --silent.",
                  flush=True)
            break
    try:
        target.terminate()
    except Exception as err:   # noqa: BLE001 - the runs are already scored; say so and carry on
        print("note: could not stop the app at the end:", err)
    with open(os.path.join(args.out_dir, "results.json"), "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=1)
    print("\nverdicts:", {v: sum(1 for r in results if r.get("verdict") == v) for v in sorted({r.get('verdict') for r in results})})


if __name__ == "__main__":
    main()
