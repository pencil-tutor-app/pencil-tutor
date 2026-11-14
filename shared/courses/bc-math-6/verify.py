#!/usr/bin/env python3
"""Re-runnable check for shared/courses/bc-math-6/problems.json.

Run:  python3 -I verify.py        (exit code 0 = every problem passed, 1 = at least one failed)

Two independent checks per problem:
  1. FINAL ANSWER: the numbers (and key words) in final_answer must equal what Python
     computes directly from the problem statement (TRUTH below, brute force / Fraction /
     math / sympy-free so it runs anywhere).
  2. WORKED LINES: every plain arithmetic equality written in worked_solution
     (like "12 x 5 = 60" or "35/100 = 7/20") is re-evaluated with exact fractions.
Plus format checks (ids, level, keys, prompt_parts rebuild prompt_plain, no student names).
"""
import json, math, os, re, sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
ID_PREFIX = "m6-"
LEVEL = "elementary"
KEYS = ["id", "source", "prompt_latex", "prompt_plain", "prompt_parts", "worked_solution", "final_answer", "level"]
# Real names to block come from the environment (comma-separated), never from the repo: BLOCKED_NAMES="..." python3 verify.py
BANNED = [n.strip().lower() for n in __import__("os").environ.get("BLOCKED_NAMES", "").split(",") if n.strip()] + ["edward", "tran "]


def nums(*vals):
    return [Fraction(v) for v in vals]


def txt(*words):
    return list(words)


def factors(n):
    return ("factors", n)


def flat(points):
    """[(x, y), ...] -> the numbers x1, y1, x2, y2, ... that should appear in the answer."""
    return nums(*[c for p in points for c in p])


def poly(vertices):
    """Perimeter of the closed polygon through the vertices (axis-parallel sides)."""
    ring = vertices + [vertices[0]]
    return sum(abs(a[0] - b[0]) + abs(a[1] - b[1]) for a, b in zip(ring, ring[1:]))


def perim_cells(cells):
    """Perimeter, in unit sides, of a set of unit squares (a side shared by two squares is hidden)."""
    cells = set(cells)
    return sum(1 for (x, y) in cells for d in ((1, 0), (-1, 0), (0, 1), (0, -1)) if (x + d[0], y + d[1]) not in cells)


TRUTH = {
    'm6-01': nums(4*10**7),
    'm6-02': nums(*[Fraction(s) for s in sorted(['0.409','0.49','0.094','0.4'], key=Fraction)]),
    'm6-03': nums(80000, 38947+41205),
    'm6-04': nums(Fraction('12.375')+Fraction('4.86')),
    'm6-05': nums(23*4),
    'm6-06': nums(49*6),
    'm6-07': nums(15*14),
    'm6-08': nums(Fraction(6)*Fraction('3.5')),
    'm6-09': nums(18-4*3),
    'm6-10': nums((7+5)*3-8),
    'm6-11': nums(36//(2+4)+9*2),
    'm6-12': nums(Fraction(20)-Fraction(6*(9-4),4)),
    'm6-13': nums(3*(14-2*5)+48//8),
    'm6-14': factors(180),
    'm6-15': nums(math.gcd(36,48)),
    'm6-16': nums(math.lcm(12,18)),
    'm6-17': nums(math.lcm(15,20)),
    'm6-18': nums(*[d for d in (2,3,5,9) if 4530 % d == 0]),
    'm6-19': nums(Fraction(23,6)),
    'm6-20': nums(Fraction(4)+Fraction(2,5)),
    'm6-21': nums(Fraction(7,4)),
    'm6-22': nums(Fraction(9,4), Fraction(7,3), Fraction(5,2)),
    'm6-23': nums(*[Fraction(12,math.gcd(12,20)), Fraction(20,math.gcd(12,20))]),
    'm6-24': nums(3, 8),
    'm6-25': nums(3*(28//4)),
    'm6-26': nums(15//3*2),
    'm6-27': nums(40*3//(5+3)),
    'm6-28': nums(35, Fraction(7,20), Fraction('0.35')),
    'm6-29': nums(80*25//100),
    'm6-30': nums(100*18//24),
    'm6-31': nums(60-60*30//100),
    'm6-32': nums(15*100//20),
    'm6-33': nums(Fraction('0.125')*3),
    'm6-34': nums(Fraction('7.2')/9),
    'm6-35': nums(Fraction('4.6')*Fraction('0.3')),
    'm6-36': nums(Fraction('12.6')/Fraction('0.6')),
    'm6-37': nums(Fraction('2.35')*4),
    'm6-38': nums(3, 2, 10, 3*10+2),
    'm6-39': nums(4, 3, 4*12+3),
    'm6-40': nums(9),
    'm6-41': nums(2*15+1, (41-1)//2),
    'm6-42': nums(4, 3*4+1, 3*8+1),
    'm6-43': nums(17-9),
    'm6-44': nums(15+7),
    'm6-45': nums(54//6),
    'm6-46': nums(8*5),
    'm6-47': nums(14, 31, 31-14),
    'm6-48': nums(poly([(0,0),(9,0),(9,4),(6,4),(6,9),(0,9)])),
    'm6-49': nums(7, poly([(0,0),(10,0),(10,3),(4,3),(4,7),(0,7)])),
    'm6-50': nums(2*(12+9)),
    'm6-51': nums(perim_cells({(0,0),(1,0),(2,0),(1,1)})*3),
    'm6-52': nums(2*((8+4)+5)),
    'm6-53': nums(9*6),
    'm6-54': nums(14*8//2),
    'm6-55': nums((6+10)*5//2),
    'm6-56': nums(30*2//10),
    'm6-57': nums(10*6+10*4//2),
    'm6-58': txt('right','obtuse','reflex','straight'),
    'm6-59': nums(180-115),
    'm6-60': nums(180-48-67),
    'm6-61': nums(360-90-110-75),
    'm6-62': nums(4*(360//12), 90),
    'm6-63': nums(5*4*3),
    'm6-64': nums(6*3*4, 6*3*4),
    'm6-65': nums(20*10*15//1000),
    'm6-66': nums(Fraction('2.5')*1000),
    'm6-67': nums(Fraction(2)*Fraction('1.5')*1),
    'm6-68': txt('equilateral'),
    'm6-69': txt('isosceles','acute'),
    'm6-70': [Fraction(120), 'obtuse'],
    'm6-71': txt('right','scalene'),
    'm6-72': flat([(x+3,y+2) for x,y in [(1,1),(4,1),(1,3)]]),
    'm6-73': flat([(10-x,y) for x,y in [(2,3),(4,1),(2,1)]]),
    'm6-74': flat([(x,8-y) for x,y in [(1,1),(3,2),(2,3)]]),
    'm6-75': flat([(8-x,8-y) for x,y in [(6,5),(7,4),(6,2)]]),
    'm6-76': flat([(y,8-x) for x,y in [(5,4),(5,6),(6,4)]]),
    'm6-77': flat([(12-(x+2),y+1) for x,y in [(1,1),(3,1),(1,4)]]),
    'm6-78': nums(2,3,4),
    'm6-79': nums(12-3,3,4),
    'm6-80': [Fraction(12-9), 'flat'],
    'm6-81': nums(1,5,2,9,3,13,4,17,6,5+4*5),
    'm6-82': nums(Fraction(3,8)),
    'm6-83': nums(Fraction(len([n for n in range(1,7) if n%2==0 and n>2]),6)),
    'm6-84': nums(Fraction(22,40), Fraction(1,2), 20),
    'm6-85': nums(Fraction(5+2,5+3+2)),
    'm6-86': nums(Fraction(len([c for c in 'MATHEMATICS' if c in 'AEIOU']),len('MATHEMATICS'))),
    'm6-87': nums(152//8),
    'm6-88': nums((150-30)//12),
    'm6-89': nums(Fraction('4.5')/6),
    'm6-90': nums(60*60//100, 60-60*60//100),
    'm6-91': nums(39//(40-12-15)),
}

SUP = {"²": 2, "³": 3}
NUM_RE = re.compile(r"\d+ \d+/\d+|\d+/\d+|\d+(?: \d{3})*(?:\.\d+)?")


def to_fraction(tok):
    tok = tok.strip()
    m = re.fullmatch(r"(\d+) (\d+)/(\d+)", tok)
    if m:
        return Fraction(int(m[1])) + Fraction(int(m[2]), int(m[3]))
    if "/" in tok:
        a, b = tok.split("/")
        return Fraction(int(a), int(b))
    return Fraction(tok.replace(" ", ""))


def numbers_in(text):
    return [to_fraction(t) for t in NUM_RE.findall(text)]


def is_prime(n):
    return n > 1 and all(n % d for d in range(2, int(n ** 0.5) + 1))


def check_answer(truth, answer):
    if isinstance(truth, tuple) and truth[0] == "factors":
        n = truth[1]
        rhs = answer.split("=")[-1]
        prod = 1
        for base, sup in re.findall(r"(\d+)([²³]?)", rhs):
            if not is_prime(int(base)):
                return f"factor {base} is not prime"
            prod *= int(base) ** SUP.get(sup, 1)
        return None if prod == n else f"prime factors multiply to {prod}, not {n}"
    want_nums = [t for t in truth if isinstance(t, Fraction)]
    want_words = [t for t in truth if isinstance(t, str)]
    got = numbers_in(answer)
    if want_nums and got != want_nums:
        return f"answer numbers {[str(g) for g in got]} != computed {[str(w) for w in want_nums]}"
    for w in want_words:
        if w not in answer.lower():
            return f"answer is missing the word '{w}'"
    return None


RUN_RE = re.compile(r"[0-9.+\-*/()=%\s]+")
EVAL_OK = re.compile(r"^[0-9.+\-*/()\s]+$")


def to_expr(piece):
    piece = piece.strip()
    piece = piece.rstrip("(").lstrip(")")
    piece = re.sub(r"(\d+(?:\.\d+)?)", r'F("\1")', piece)
    return piece


def check_line(line):
    """Return list of (status, detail). status 'ok', 'fail' or 'skip'."""
    s = line.replace("×", "*").replace("·", "*").replace("÷", "/").replace("−", "-")
    s = re.sub(r"(?<=\d) (?=\d{3}(?!\d))", "", s)
    results = []
    if re.search(r"\d\s*:\s*\d", s):  # ratio lines like "3 : 4 = 21 : 28" are not arithmetic
        return results
    for m in RUN_RE.finditer(s):
        run = m.group(0)
        if "=" not in run or "%" in run:
            continue
        pieces = run.split("=")
        before = s[m.start() - 1] if m.start() > 0 else " "
        after = s[m.end()] if m.end() < len(s) else " "
        if before.isalpha() or before in "²³′°)":
            pieces = pieces[1:]
        if (after.isalpha() or after in "²³") and not run.endswith(" "):
            pieces = pieces[:-1]
        vals = []
        for p in pieces:
            p2 = p.strip().rstrip("(").lstrip(")").strip()
            if not p2 or not re.search(r"\d", p2) or not EVAL_OK.match(p2):
                continue
            try:
                v = eval(to_expr(p2), {"__builtins__": {}}, {"F": Fraction})
            except Exception:
                results.append(("skip", p2))
                continue
            vals.append((p2, Fraction(v)))
        if len(vals) >= 2:
            if all(v == vals[0][1] for _, v in vals):
                results.append(("ok", " = ".join(p for p, _ in vals)))
            else:
                results.append(("fail", " | ".join(f"{p} -> {v}" for p, v in vals)))
    return results


def main():
    with open(os.path.join(HERE, "problems.json"), encoding="utf-8") as f:
        probs = json.load(f)
    failures, answers_ok, lines_ok, lines_skipped = [], 0, 0, 0
    ids = [p["id"] for p in probs]
    if len(set(ids)) != len(ids):
        failures.append("duplicate ids")
    if set(ids) != set(TRUTH):
        failures.append(f"ids without truth: {sorted(set(ids) ^ set(TRUTH))}")
    for p in probs:
        pid = p["id"]
        errs = []
        if list(p.keys()) != KEYS:
            errs.append(f"keys {list(p.keys())}")
        if not pid.startswith(ID_PREFIX):
            errs.append("bad id prefix")
        if p.get("level") != LEVEL:
            errs.append("bad level")
        if not p.get("worked_solution") or not all(isinstance(x, str) and x for x in p["worked_solution"]):
            errs.append("empty worked_solution")
        if not p.get("final_answer"):
            errs.append("empty final_answer")
        rebuilt = "".join(
            seg["text"] if "text" in seg else f'{seg["frac"]["num"]}/{seg["frac"]["den"]}'
            for seg in p["prompt_parts"])
        if rebuilt != p["prompt_plain"]:
            errs.append("prompt_parts do not rebuild prompt_plain")
        blob = json.dumps(p, ensure_ascii=False).lower()
        for b in BANNED:
            if b in blob:
                errs.append(f"banned word {b!r}")
        if pid in TRUTH:
            e = check_answer(TRUTH[pid], p["final_answer"])
            if e:
                errs.append("FINAL ANSWER: " + e)
            else:
                answers_ok += 1
        for line in p["worked_solution"]:
            for status, detail in check_line(line):
                if status == "ok":
                    lines_ok += 1
                elif status == "skip":
                    lines_skipped += 1
                else:
                    errs.append(f"WORKED LINE wrong: {line!r} ({detail})")
        if errs:
            failures.append(f"{pid}: " + "; ".join(errs))
    print(f"problems: {len(probs)}")
    print(f"final answers matching independent computation: {answers_ok}/{len(probs)}")
    print(f"worked-line arithmetic equalities re-checked and correct: {lines_ok} (unparseable pieces skipped: {lines_skipped})")
    if failures:
        print("FAILURES:")
        for f in failures:
            print(" -", f)
        return 1
    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
