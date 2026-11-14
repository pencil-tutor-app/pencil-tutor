#!/usr/bin/env python3
"""Turn a course-eval results file into the numbers for docs/evals/*-courses-watch-eval.md. No network, no model calls.

Usage: python3 server/eval/report_courses.py server/eval/results/<run>.jsonl [--examples]
Reads fixtures/courses/manifest.json for the truth of each page. A look is, per page:
  hit          interrupted on exactly the planted line (mistake pages)
  wrong_line   interrupted, but on another line
  silent       waited on a mistake page (includes looks where the model wanted to interrupt but the server's own checks
               turned it into a wait: hint_reveals_answer, line_not_in_page, hint_missing; those are counted separately too)
  false_alarm  interrupted on a correct page
Also a hint leak check: does the spoken or written hint contain the problem's final answer or the corrected line's key numbers.
"""
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures", sys.argv[sys.argv.index("--fixtures") + 1] if "--fixtures" in sys.argv else "courses")
BANK = os.path.join(HERE, "..", "data", "problems.json")


def norm(s):
    return re.sub(r"\s+", "", s.lower().replace("−", "-").replace("–", "-"))


def verdict(row, page):
    wrong = page["category"] == "wrong"
    interrupted = row["action"] == "interrupt"
    if wrong:
        if interrupted:
            return "hit" if row["line"] == page["wrong_line"] else "wrong_line"
        return "silent"
    return "false_alarm" if interrupted else "correct_wait"


def pct(a, b):
    return "n/a" if b == 0 else f"{100 * a / b:.0f}% ({a}/{b})"


def main():
    path = sys.argv[1]
    show = "--examples" in sys.argv
    pages = {p["id"]: p for p in json.load(open(os.path.join(FIX, "manifest.json")))}
    bank = {p["id"]: p for p in json.load(open(BANK))["problems"]}
    rows = [json.loads(line) for line in open(path) if line.strip()]
    print(f"rows: {len(rows)}  (status>=400: {sum(1 for r in rows if r['status'] >= 400)})")

    by_course = collections.defaultdict(lambda: collections.Counter())
    by_type = collections.defaultdict(lambda: collections.Counter())
    tot = collections.Counter()
    lat, cost, toks = [], [], []
    downgraded = collections.Counter()
    leaks = []
    for r in rows:
        page = pages[r["page"]]
        v = verdict(r, page)
        c = page["course"]
        by_course[c][v] += 1
        tot[v] += 1
        if page["category"] == "wrong":
            by_type[page["error_type"]][v] += 1
        if r["reason"] in ("hint_reveals_answer", "line_not_in_page", "hint_missing", "malformed_output", "model_output_not_valid_json_for_schema"):
            downgraded[r["reason"]] += 1
            by_course[c]["downgraded"] += 1
        lat.append(r["latency_ms"])
        if r["est_cost_usd"] is not None:
            cost.append(r["est_cost_usd"])
        if r["input_tokens"] is not None:
            toks.append((r["input_tokens"], r["output_tokens"] or 0, r["reasoning_tokens"] or 0))
        if r["action"] == "interrupt":
            problem = bank[page["problem_id"]]
            said = norm(" ".join(filter(None, [r.get("hint_spoken"), r.get("hint_written")])))
            fa = norm(problem["final_answer"])
            hit_final = len(fa) >= 2 and fa in said
            # Second check, on mistake pages the tutor caught: a number that is in the CORRECT version of the planted line but not in
            # the student's wrong line is the corrected value; a hint that contains it hands the fix over.
            if page["category"] == "wrong" and r["line"] == page["wrong_line"]:
                twin = pages.get(f"{page['course']}__{page['problem_id']}__correct")
                if twin:
                    right = set(re.findall(r"\d+(?:\.\d+)?", twin["rows"][page["wrong_line"] - 1])) if len(twin["rows"]) >= page["wrong_line"] else set()
                    wrong_nums = set(re.findall(r"\d+(?:\.\d+)?", page["rows"][page["wrong_line"] - 1]))
                    fix_nums = right - wrong_nums
                    seen = set(re.findall(r"\d+(?:\.\d+)?", " ".join(filter(None, [r.get("hint_spoken"), r.get("hint_written")]))))
                    if fix_nums & seen:
                        hit_final = True
            leaks.append((page["id"], hit_final, r.get("hint_spoken"), r.get("hint_written")))

    print("\n| course | mistake pages | caught (right line) | wrong line | silent | correct pages | false alarms | model-wanted-but-blocked |")
    print("|---|---|---|---|---|---|---|---|")
    for c in sorted(by_course):
        k = by_course[c]
        w = k["hit"] + k["wrong_line"] + k["silent"]
        cp = k["correct_wait"] + k["false_alarm"]
        print(f"| {c} | {w} | {k['hit']} | {k['wrong_line']} | {k['silent']} | {cp} | {k['false_alarm']} | {k['downgraded']} |")
    w = tot["hit"] + tot["wrong_line"] + tot["silent"]
    cp = tot["correct_wait"] + tot["false_alarm"]
    print(f"| ALL | {w} | {tot['hit']} | {tot['wrong_line']} | {tot['silent']} | {cp} | {tot['false_alarm']} | {sum(downgraded.values())} |")
    print(f"\ncatch {pct(tot['hit'], w)}  wrong-line {pct(tot['wrong_line'], w)}  silence {pct(tot['silent'], w)}  false alarm {pct(tot['false_alarm'], cp)}")

    print("\n| mistake type | pages | caught | wrong line | silent |")
    print("|---|---|---|---|---|")
    for t in sorted(by_type, key=lambda t: sum(by_type[t].values()), reverse=True):
        k = by_type[t]
        print(f"| {t} | {sum(k.values())} | {k['hit']} | {k['wrong_line']} | {k['silent']} |")

    lat.sort()
    print(f"\nlatency p50 {lat[len(lat)//2]/1000:.1f}s  p90 {lat[int(len(lat)*0.9)]/1000:.1f}s  max {lat[-1]/1000:.1f}s")
    print(f"cost per look ${sum(cost)/len(cost):.5f} over {len(cost)} looks; total ${sum(cost):.4f}")
    if toks:
        n = len(toks)
        print(f"tokens per look: input {sum(t[0] for t in toks)/n:.0f}  output {sum(t[1] for t in toks)/n:.0f}  (reasoning {sum(t[2] for t in toks)/n:.0f})")
    print("downgrades:", dict(downgraded))
    print(f"hints: {len(leaks)} interruptions, final answer appears in hint (after the server's own check): {sum(1 for x in leaks if x[1])}")
    if show:
        print("\n--- every interruption: page | line | spoken | written")
        for pid, leak, sp, wr in leaks:
            print(f"{pid} | {'LEAK ' if leak else ''}{sp} | {wr}")
        print("\n--- non-hit looks on mistake pages and every false alarm")
        for r in rows:
            page = pages[r["page"]]
            v = verdict(r, page)
            if v in ("wrong_line", "silent", "false_alarm"):
                print(f"{v} | {r['page']} | action={r['action']} line={r['line']} planted={page['wrong_line']} reason={r['reason']} | said: {r.get('reason_text')} | {r.get('hint_spoken')}")


if __name__ == "__main__":
    main()
