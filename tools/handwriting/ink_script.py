#!/usr/bin/env python3
"""Make "ink scripts" for the Pencil Tutor replay: what a student writes, stroke by stroke, with timestamps.

Usage (from the repo root, with the venv that has Pillow for `preview`):
  python3 tools/handwriting/ink_script.py plan  --course bc-math-9
  python3 tools/handwriting/ink_script.py gen   --course bc-math-9 --problem m9-01 [--mistake-line 2] [--seed 1] --out out.json
  python3 tools/handwriting/ink_script.py cases --out-dir tools/handwriting/cases        (the standard 12 cases)
  python3 tools/handwriting/ink_script.py preview out.json out.png                        (needs Pillow)
  python3 tools/handwriting/ink_script.py from-eval-manifest manifest.json --id 16-u3-04-wrong-w2 --out out.json

The lines written come from `worked_solution` in shared/courses/<slug>/problems.json: the steps that are plain math (an
equation or an expression), with the prose around them left out, because a student writes the math. A planted mistake changes the
last number on the right of the "=" of line N and carries the changed value into later lines where the old one appears.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import ink_synth as synth  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
COURSES = os.path.join(REPO, "shared", "courses")
FUNCTION_WORDS = {"sin", "cos", "tan", "sec", "csc", "cot", "lim", "log", "ln", "arcsin", "arccos", "arctan", "det", "max", "min"}
MATH_SHORT_WORDS = {"dx", "dy", "dt", "ds", "du", "dv", "or", "at"}
SPLITTERS =re.compile(r"(?:,\s*)?\b(?:so|because|gives|giving|then|therefore|thus|hence|and)\b\s*|:\s+|;\s+|\.\s+")
MAX_CHARS = 34
CANVAS_W, CANVAS_H = 1080, 810      # the iPad (9th generation) in landscape: the canvas the app reports (device log, 2026-11-15)
# The problem card and the buttons cover the top of the canvas and the tool rail covers its left edge, so a student writes below
# and to the right of them: this is where the first line starts, in page points from the top-left of the canvas.
TOP_MARGIN, LEFT_MARGIN = 130, 120


# ------------------------------------------------------------------------------------------ lines from a solution
def _is_math(segment: str) -> bool:
    words = [w for w in re.findall(r"[A-Za-z]{2,}", segment) if w.lower() not in FUNCTION_WORDS | MATH_SHORT_WORDS]
    if words:
        return False
    has_relation = any(c in segment for c in "=≤≥<>≠→")
    has_operator = any(c in segment for c in "+-−×÷/·^") and re.search(r"\d", segment)
    return bool(has_relation or has_operator)


def math_lines(steps: list[str]) -> list[str]:
    out = []
    for step in steps:
        # a matrix keeps its ";" between rows: hide them from the splitter, then put them back
        hidden = re.sub(r"\[[^\]]*\]", lambda m: m.group(0).replace(";", "\x00"), step)
        for part in SPLITTERS.split(hidden):
            part = (part or "").replace("\x00", ";").strip(" ,.;")
            if part and _is_math(part) and len(part) >= 3:
                out.append(part)
    # drop immediate repeats
    return [line for i, line in enumerate(out) if i == 0 or line != out[i - 1]]


def check_drawable(lines: list[str]) -> str | None:
    """None when every line can be drawn, else why not."""
    for line in lines:
        if len(line) > MAX_CHARS and synth.count_visual_rows(line) == 1:
            return f"line too long ({len(line)} chars)"
        try:
            synth.layout_text(line, 26.0)
        except synth.Unsupported as err:
            return f"cannot draw {err!s}"
    return None


NUMBER = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])")


def plant_mistake(lines: list[str], line_no: int, rng: random.Random) -> tuple[list[str], dict] | None:
    """Changes line `line_no` (1-based) so it is wrong, and carries the change into the lines after it."""
    text = lines[line_no - 1]
    cut = text.rfind("=")
    head, tail = text[: cut + 1], text[cut + 1:]
    numbers = list(NUMBER.finditer(tail))
    if not numbers:
        return None
    m = numbers[-1]
    old = m.group(1)
    sign_before = tail[: m.start()].rstrip()[-1:] in ("-", "−") if tail[: m.start()].strip() else False
    if "." in old:
        return None
    value = int(old)
    options = [value + rng.choice([1, 2, 3, -1]), value * 2 if value > 1 else value + 2, value + 10 if value >= 10 else value + 1]
    options = [o for o in options if o != value and o >= 0]
    new = str(rng.choice(options))
    new_tail = tail[: m.start()] + new + tail[m.end():]
    out = list(lines)
    out[line_no - 1] = head + new_tail
    # carry the changed value forward: same signed number in later lines
    signed_old = ("−" if sign_before else "") + old
    signed_new = ("−" if sign_before else "") + new
    pattern = re.compile(r"(?<![\w.])" + re.escape(signed_old) + r"(?![\w.])")
    carried = 0
    for i in range(line_no, len(out)):
        replaced, n = pattern.subn(signed_new, out[i])
        if n:
            out[i] = replaced
            carried += n
    info = {"line": line_no, "from": text, "to": out[line_no - 1], "old_number": signed_old, "new_number": signed_new,
            "carried_substitutions": carried}
    return out, info


# ------------------------------------------------------------------------------------------------ the page of ink
def build_script(lines: list[str], seed: int, meta: dict, expected: dict, cap: float = 30.0, speed: float | None = None,
                 think: float = 1.0, gap_scale: float = 1.0, jitter: float = 1.0) -> dict:
    """`gap_scale` shrinks the space between lines (0.4 is cramped: lines nearly touch); `jitter` multiplies the hand's wobble,
    baseline drift and tilt (2 is a rushed, messy writer)."""
    writer = synth.Writer.make(seed, speed=speed, think=think)
    writer.jitter *= jitter
    rng = random.Random(seed)
    for _ in range(8):
        boxes = [synth.layout_text(line, cap * writer.size) for line in lines]
        gap = (0.7 * cap + 14) * gap_scale
        total = TOP_MARGIN + sum(b.asc + b.desc for b in boxes) + gap * (len(boxes) - 1)
        if total <= CANVAS_H - 40 or cap <= 18:
            break
        cap *= 0.92
    x0 = LEFT_MARGIN + rng.gauss(0, 6)
    baseline = TOP_MARGIN + boxes[0].asc
    t = 1.0
    out_lines, app_line = [], 1
    for index, (text, box) in enumerate(zip(lines, boxes), start=1):
        x_here = x0 + rng.gauss(0, 5)
        strokes, t_end, bbox = synth.write_line(box, (x_here, baseline), writer, rng, t, tilt=rng.gauss(0, 0.006 * jitter))
        rows = 1       # a matrix is one line of work: its rows stay together (the grouper keeps the rows between brackets in one line)
        out_lines.append({
            "index": index, "text": text, "app_line_start": app_line, "app_lines": rows,
            "t_start": strokes[0][0][2] if strokes else t, "t_end": round(t_end, 3),
            "bbox": [round(v, 1) for v in bbox], "strokes": [{"points": s} for s in strokes],
        })
        app_line += rows
        pause = rng.uniform(0.7, 1.6) * writer.think
        if rng.random() < 0.12:
            pause += rng.uniform(2.0, 3.5)        # a long think; sometimes longer than the idle time that triggers a look
        t = t_end + pause
        if index < len(boxes):
            baseline += box.desc + gap + boxes[index].asc
    all_boxes = [l["bbox"] for l in out_lines]
    return {
        "version": 1, **meta, "seed": seed, "cap_height_pt": round(cap * writer.size, 1),
        "canvas_hint": {"width": CANVAS_W, "height": CANVAS_H, "origin": "top-left of the first screen, page points"},
        "bounds": [round(min(b[0] for b in all_boxes), 1), round(min(b[1] for b in all_boxes), 1),
                   round(max(b[2] for b in all_boxes), 1), round(max(b[3] for b in all_boxes), 1)],
        "expected": expected, "duration_s": round(t, 2),
        "lines": out_lines,
    }


def stats(script: dict) -> str:
    strokes = sum(len(l["strokes"]) for l in script["lines"])
    points = sum(len(s["points"]) for l in script["lines"] for s in l["strokes"])
    return f"{len(script['lines'])} lines, {strokes} strokes, {points} points, {script['duration_s']}s, bounds {script['bounds']}"


# ------------------------------------------------------------------------------------------------------ the cases
def load_problems(course: str) -> list[dict]:
    with open(os.path.join(COURSES, course, "problems.json"), encoding="utf-8") as handle:
        return json.load(handle)


def candidate(problem: dict, allow_matrix: bool) -> list[str] | None:
    lines = math_lines(problem["worked_solution"])
    if not 4 <= len(lines) <= 7:
        return None
    if check_drawable(lines):
        return None
    if not all("=" in l for l in lines):     # every line a full equation step: no stray fragments like "11/40"
        return None
    if not allow_matrix and any(synth.count_visual_rows(l) > 1 for l in lines):
        return None
    # some line in 2..n-1 must be mistakable (a whole number after an "=")
    for n in range(2, len(lines)):
        if "=" in lines[n - 1] and NUMBER.search(lines[n - 1][lines[n - 1].rfind("=") + 1:]):
            return lines
    return None


def mistakable_line(lines: list[str], rng: random.Random) -> int | None:
    options = [n for n in range(2, len(lines))
               if "=" in lines[n - 1] and NUMBER.search(lines[n - 1][lines[n - 1].rfind("=") + 1:])]
    return rng.choice(options[:2]) if options else None


def make_case(course: str, problem: dict, lines: list[str], mistake_line: int | None, seed: int, think: float = 1.0,
              suffix: str = "", gap_scale: float = 1.0, jitter: float = 1.0) -> dict:
    rng = random.Random(seed)
    meta = {"id": f"{course}_{problem['id']}_" + ("mistake" if mistake_line else "correct") + suffix, "course": course,
            "problem_id": problem["id"], "source": "worked_solution"}
    expected = {"outcome": "no_mistake", "line": None, "truth_lines": lines}
    written = lines
    if mistake_line:
        planted = plant_mistake(lines, mistake_line, rng)
        if planted is None:
            raise ValueError(f"cannot plant a mistake on line {mistake_line} of {problem['id']}")
        written, info = planted
        expected = {"outcome": "mistake", "line": mistake_line, "mutation": info, "truth_lines": lines}
    script = build_script(written, seed, meta, expected, think=think, gap_scale=gap_scale, jitter=jitter)
    if mistake_line:
        script["expected"]["app_line"] = script["lines"][mistake_line - 1]["app_line_start"]
    return script


def cmd_plan(args):
    for problem in load_problems(args.course):
        lines = candidate(problem, allow_matrix=args.matrix)
        if lines:
            print(problem["id"], "|", " ## ".join(lines))


def cmd_gen(args):
    problem = next(p for p in load_problems(args.course) if p["id"] == args.problem)
    lines = math_lines(problem["worked_solution"])
    reason = check_drawable(lines)
    if reason:
        sys.exit(f"{args.problem}: {reason}")
    script = make_case(args.course, problem, lines, args.mistake_line, args.seed, think=args.think,
                       suffix=args.suffix, gap_scale=args.gap_scale, jitter=args.jitter)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(script, handle, ensure_ascii=False, separators=(",", ":"))
    print(args.out, stats(script))


CASE_COURSES = ["bc-math-5", "bc-math-9", "bc-pc-11", "bc-calc-12", "calculus-1", "linear-algebra"]


# Problems whose worked solution reads as one coherent page of equations from the first line (picked by reading the
# `plan` output). Extra problems come first when you ask for more than one per course.
PINNED = {"bc-math-5": ["m5-26", "m5-28"], "bc-math-9": ["m9-07", "m9-02"], "bc-pc-11": ["pc11-24", "pc11-23"],
          "bc-calc-12": ["ca12-24", "ca12-50"], "calculus-1": ["c1-54", "c1-59"], "linear-algebra": ["la-01", "la-35"]}


def cmd_cases(args):
    os.makedirs(args.out_dir, exist_ok=True)
    manifest = []
    # `--pick course:problem` (repeatable) writes exactly those problems; otherwise one pinned problem per course.
    picks = [p.split(":", 1) for p in (args.pick or [])]
    for course in (list(dict.fromkeys(c for c, _ in picks)) if picks else CASE_COURSES):
        picked = 0
        by_id = {p["id"]: p for p in load_problems(course)}
        if picks:
            ordered = [by_id[i] for c, i in picks if c == course and i in by_id]
        else:
            ordered = [by_id[i] for i in PINNED.get(course, []) if i in by_id] + list(by_id.values())
        for problem in ordered:
            lines = candidate(problem, allow_matrix=args.matrix)
            if not lines:
                if picks:
                    print(f"WARNING: {problem['id']} is not a clean page of equations (see `plan`)", file=sys.stderr)
                continue
            rng = random.Random(f"{course}{problem['id']}")
            n = mistakable_line(lines, rng)
            if n is None:
                continue
            for mistake in ((n,) if args.mistake_only else (None, n)):
                seed = sum(map(ord, problem["id"])) + (7 if mistake else 0)   # fixed, so the same case is the same ink
                script = make_case(course, problem, lines, mistake, seed, think=args.think, suffix=args.suffix,
                                   gap_scale=args.gap_scale, jitter=args.jitter)
                path = os.path.join(args.out_dir, script["id"] + ".json")
                with open(path, "w", encoding="utf-8") as handle:
                    json.dump(script, handle, ensure_ascii=False, separators=(",", ":"))
                manifest.append({"id": script["id"], "course": course, "problem_id": problem["id"], "file": os.path.basename(path),
                                 "expected": script["expected"]["outcome"], "mistake_line": mistake,
                                 "app_line": script["expected"].get("app_line"), "lines": len(lines), "duration_s": script["duration_s"],
                                 "written": [l["text"] for l in script["lines"]]})
                print(script["id"], stats(script))
            picked += 1
            if not picks and picked >= args.per_course:
                break
        if picked == 0:
            print(f"WARNING: no suitable problem in {course}", file=sys.stderr)
    with open(os.path.join(args.out_dir, "cases.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=1)
    print("wrote", len(manifest), "cases to", args.out_dir)


def cmd_stress(args):
    """A pile of pages for testing line grouping offline (no iPad): every drawable problem in every course, at several line
    spacings and wobbles. Files only; the lines each page should group into are in `lines[].app_lines`."""
    os.makedirs(args.out_dir, exist_ok=True)
    courses = sorted(d for d in os.listdir(COURSES) if os.path.isdir(os.path.join(COURSES, d)))
    made = 0
    for course in courses:
        for problem in load_problems(course):
            lines = math_lines(problem["worked_solution"])
            if not 2 <= len(lines) <= 8 or check_drawable(lines):
                continue
            if not args.matrix and any(synth.count_visual_rows(l) > 1 for l in lines):
                continue
            for gap_scale, jitter in ((1.0, 1.0), (0.6, 1.0), (0.4, 1.0), (0.6, 2.0), (0.4, 2.0)):
                seed = sum(map(ord, problem["id"])) + int(gap_scale * 10) + int(jitter * 3)
                script = make_case(course, problem, lines, None, seed, suffix=f"-g{int(gap_scale * 100)}j{int(jitter * 10)}",
                                   gap_scale=gap_scale, jitter=jitter)
                with open(os.path.join(args.out_dir, script["id"] + ".json"), "w", encoding="utf-8") as handle:
                    json.dump(script, handle, ensure_ascii=False, separators=(",", ":"))
                made += 1
    print("wrote", made, "pages to", args.out_dir)


def cmd_from_eval_manifest(args):
    """Reuse the eval-courses fixtures (BC Math 9 equation pages, a known first wrong line) as ink scripts."""
    with open(args.manifest, encoding="utf-8") as handle:
        entries = json.load(handle)
    entry = next(e for e in entries if e["id"] == args.id)
    rows = [re.sub(r"\{([^/]+)/([^}]+)\}", r"(\1)/(\2)", r) for r in entry["rows"]]
    wrong = entry["wrong_line"]
    meta = {"id": entry["id"], "course": "bc-math-9", "problem_id": entry["problem_id"], "source": "eval-courses manifest"}
    expected = {"outcome": "mistake" if wrong else "no_mistake", "line": wrong, "truth_lines": None,
                "error_type": entry.get("error_type")}
    script = build_script(rows, args.seed, meta, expected)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(script, handle, ensure_ascii=False, separators=(",", ":"))
    print(args.out, stats(script))


# ---------------------------------------------------------------------------------------------------- the preview
def cmd_preview(args):
    from PIL import Image, ImageDraw
    with open(args.script, encoding="utf-8") as handle:
        script = json.load(handle)
    scale = args.scale
    image = Image.new("RGB", (int(CANVAS_W * scale), int(CANVAS_H * scale)), "white")
    draw = ImageDraw.Draw(image)
    for line in script["lines"]:
        for stroke in line["strokes"]:
            pts = stroke["points"]
            for a, b in zip(pts, pts[1:]):
                width = max(1, round((1.6 + 2.6 * (a[3] + b[3]) / 2) * scale))
                draw.line([(a[0] * scale, a[1] * scale), (b[0] * scale, b[1] * scale)], fill=(10, 10, 14), width=width)
        draw.text((6, line["bbox"][1] * scale), str(line["index"]), fill=(150, 150, 150))
    image.save(args.out)
    print(args.out, stats(script))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--course", required=True)
    p.add_argument("--matrix", action="store_true")
    p.set_defaults(fn=cmd_plan)
    p = sub.add_parser("gen")
    p.add_argument("--course", required=True)
    p.add_argument("--problem", required=True)
    p.add_argument("--mistake-line", type=int)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--think", type=float, default=1.0)
    p.add_argument("--suffix", default="")
    p.add_argument("--gap-scale", type=float, default=1.0, help="space between lines; 0.4 is cramped")
    p.add_argument("--jitter", type=float, default=1.0, help="wobble, drift and tilt; 2 is a rushed writer")
    p.add_argument("--out", required=True)
    p.set_defaults(fn=cmd_gen)
    p = sub.add_parser("cases")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--per-course", type=int, default=1, help="problems per course; each gives one correct and one mistake case")
    p.add_argument("--think", type=float, default=1.0, help="multiplier on the pause after each line (1 = brisk, 3 = a student who thinks)")
    p.add_argument("--suffix", default="", help="added to every case id, e.g. -think, so two sets can share a folder")
    p.add_argument("--gap-scale", type=float, default=1.0, help="space between lines; 0.4 is cramped")
    p.add_argument("--jitter", type=float, default=1.0, help="wobble, drift and tilt; 2 is a rushed writer")
    p.add_argument("--pick", action="append", help="COURSE:PROBLEM to write instead of the pinned set (repeatable)")
    p.add_argument("--matrix", action="store_true", help="allow problems whose lines include a matrix")
    p.add_argument("--mistake-only", action="store_true", help="only the page with a planted mistake")
    p.set_defaults(fn=cmd_cases)
    p = sub.add_parser("stress")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--matrix", action="store_true")
    p.set_defaults(fn=cmd_stress)
    p = sub.add_parser("preview")
    p.add_argument("script")
    p.add_argument("out")
    p.add_argument("--scale", type=float, default=1.0)
    p.set_defaults(fn=cmd_preview)
    p = sub.add_parser("from-eval-manifest")
    p.add_argument("manifest")
    p.add_argument("--id", required=True)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out", required=True)
    p.set_defaults(fn=cmd_from_eval_manifest)
    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
