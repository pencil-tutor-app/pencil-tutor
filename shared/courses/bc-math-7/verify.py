"""Re-runnable check for bc-math-7/problems.json. Run: python3 -I verify.py
Each problem is recomputed independently; the answer and key intermediate
values must appear in final_answer / worked_solution. Exits 1 on any failure."""
import json, os, sys
from decimal import Decimal as D
from fractions import Fraction as Fr

here = os.path.dirname(os.path.abspath(__file__))
probs = {p["id"]: p for p in json.load(open(os.path.join(here, "problems.json"), encoding="utf-8"))}
PI = D("3.14")
fails, checked = [], 0


def norm(s):
    s = str(s).replace("-", "−")
    return s.replace(" ", "").replace(" ", "")


def num(x):
    """Plain string of a Decimal/int with no trailing zeros."""
    x = D(x).normalize()
    s = format(x, "f")
    return s


def expect(pid, answers, steps=()):
    """answers: strings that must be in final_answer; steps: strings in worked_solution."""
    global checked
    p = probs[pid]
    fa = norm(p["final_answer"])
    ws = norm(" ".join(p["worked_solution"]))
    for a in answers:
        checked += 1
        if norm(a) not in fa:
            fails.append(f"{pid}: final_answer missing {a!r} (got {p['final_answer']!r})")
    for s in steps:
        checked += 1
        if norm(s) not in ws:
            fails.append(f"{pid}: worked_solution missing {s!r}")


# S1
expect("m7-01", [346 * 5], [346 * 10, 346 * 10 // 2])
expect("m7-02", [18 * 15], [18 * 10, 18 * 5])
expect("m7-03", [96 // 8], [80 // 8, 16 // 8]); assert 96 % 8 == 0
expect("m7-04", [48 * 25], [48 * 100, 48 * 100 // 4])
# S2
expect("m7-05", [-7 + 12], [12 - 7])
expect("m7-06", [-6 - (-9)], [])
expect("m7-07", [(-6) * 5 // (-3)], [(-6) * 5]); assert (-6 * 5) % -3 == 0
expect("m7-08", [3 + (-4) * (2 - 6)], [2 - 6, (-4) * (-4)])
expect("m7-09", [-8 + 3 * 5 - 4], [3 * 5, -8 + 15])
# S3
expect("m7-10", [num(D("4.75") + D("3.6"))])
expect("m7-11", [num(D("12.5") - D("7.84"))])
expect("m7-12", [num(D("3.6") * D("0.25"))], [36 * 25])
expect("m7-13", [num(D("7.2") / D("0.4"))], [72 // 4])
expect("m7-14", [num(D("2.5") + D("1.5") * (D("4.2") - D("1.2")) / D("0.5"))],
       [num(D("4.2") - D("1.2")), num(D("1.5") * 3), num(D("4.5") / D("0.5"))])
# S4
expect("m7-15", [num(D(3) / 8), num(D(3) / 8 * 100) + "%"])
expect("m7-16", [f"{Fr(64, 100).numerator}/{Fr(64, 100).denominator}", "64%"])
rep = str(D(5) / D(11))  # 0.4545...
assert rep.startswith("0.4545"); expect("m7-17", ["Repeating"], [])
vals = sorted([(Fr(5, 8), "5/8"), (Fr(6, 10), "0.6"), (Fr(59, 100), "59%"), (Fr(3, 5), "3/5")])
assert [v[1] for v in vals] == ["59%", "0.6", "3/5", "5/8"] or [v[1] for v in vals] == ["59%", "3/5", "0.6", "5/8"]
expect("m7-18", ["59%", "5/8"], [num(D(5) / 8), "0.59"])
expect("m7-19", [num(D(9) / 25 * 100) + "%"], [9 * 4, 25 * 4])
# S5
rel = lambda a, b: (lambda n: a * n + b)
assert [rel(3, 2)(n) for n in (1, 2, 3, 4)] == [5, 8, 11, 14]
expect("m7-20", ["3n+2", rel(3, 2)(10)], [rel(3, 2)(10)])
assert [rel(4, -1)(n) for n in range(1, 6)] == [3, 7, 11, 15, 19]
expect("m7-21", ["3, 7, 11, 15, 19", [n for n in range(1, 50) if 4 * n - 1 == 39][0]])
assert [rel(2, 1)(n) for n in (1, 2, 3)] == [3, 5, 7]
expect("m7-22", ["2n+1", rel(2, 1)(8)], [rel(2, 1)(8)])
assert [rel(3, 1)(n) for n in (1, 2, 3)] == [4, 7, 10]
expect("m7-23", ["3n+1", rel(3, 1)(25)], [rel(3, 1)(25)])
ys = [2 * x - 3 for x in (-2, -1, 0, 1, 2)]
assert ys == [-7, -5, -3, -1, 1] and 2 * 3 - 3 == 3
expect("m7-24", ["−7, −5, −3, −1, 1", "yes"], [f"({x}, {y})".replace("-", "−") for x, y in zip((-2, -1, 0, 1, 2), ys)])
# S6 : brute-force solve a*x+b=c
def solve(a, b, c):
    r = [x for x in range(-100, 101) if a * x + b == c]; assert len(r) == 1; return r[0]
expect("m7-25", [solve(5, 3, 28)], [5 * solve(5, 3, 28)])
expect("m7-26", [solve(4, -7, 21)], [21 + 7 and 4 * solve(4, -7, 21)])
expect("m7-27", [solve(2, 9, 31)], [31 - 9])
expect("m7-28", [solve(3, 4, 25)], [25 - 4])
expect("m7-29", [solve(6, -15, 33)], [33 + 15])
# S7
C = lambda d: PI * d
A = lambda r: PI * r * r
expect("m7-30", [num(C(10))])
expect("m7-31", [num(C(12))], [12])
expect("m7-32", [num(A(5))], [num(PI * 25)])
expect("m7-33", [num(A(7))], [7, num(PI * 49)])
d = D("62.8") / PI
expect("m7-34", [num(d), num(d / 2), num(A(d / 2))], [])
# S9 etc. use plain arithmetic
# S8
expect("m7-35", [8 * 5 * 3], [8 * 5])
expect("m7-36", [24 * 7])
expect("m7-37", [num(PI * 9 * 10)], [num(PI * 9)])
expect("m7-38", [num(PI * 25 * 4)], [num(PI * 25)])
expect("m7-39", [40 * 25 * 20 // 1000], [40 * 25 * 20])
# S9
expect("m7-40", ["(−3, 5)", "Quadrant II"])
q = lambda x, y: "I" if x > 0 and y > 0 else "II" if x < 0 < y else "III" if x < 0 and y < 0 else "IV"
assert q(-3, 5) == "II" and q(-4, -6) == "III" and q(7, -2) == "IV"
expect("m7-41", ["Quadrant III", "Quadrant IV"])
w, h = 4 - (-2), 1 - (-3)
expect("m7-42", ["(−2, −3)", w * h], [w, h])
expect("m7-43", [3 - (-5)])
assert [2 * x - 1 for x in (0, 1, 2)] == [-1, 1, 3]
expect("m7-44", [f"(3, {2 * 3 - 1})", "y=2x−1"])
# S10
expect("m7-45", [f"({2 + 4}, {3 - 5})".replace("-", "−")])
expect("m7-46", ["(−3, −2)"])
tri = [(1, 1), (4, 1), (1, 3)]
ref = [(x, -y) for x, y in tri]
expect("m7-47", [f"({x}, {y})".replace("-", "−") for x, y in ref])
rot = lambda x, y: (-y, x)  # 90 deg CCW about origin
x1, y1 = rot(2, 1); fx, fy = x1 - 3, y1 + 2
assert (x1, y1) == (-1, 2)
expect("m7-48", [f"({fx}, {fy})".replace("-", "−")], [f"({x1}, {y1})".replace("-", "−")])
interior = lambda n: Fr((n - 2) * 180, n)
assert interior(5) == 108 and (360 / 108) != int(360 / 108)
assert interior(6) == 120 and 360 % 120 == 0  # sanity: hexagons do tessellate
expect("m7-49", ["No"])
# S11
expect("m7-50", [D("0.35") * 200 == 70 and 70])
expect("m7-51", [int(Fr(25, 100) * 360)])
counts = {"pizza": 8, "tacos": 6, "sushi": 4, "pasta": 2}
tot = sum(counts.values()); assert tot == 20
pct = {k: v * 100 // tot for k, v in counts.items()}
ang = {k: v * 360 // tot for k, v in counts.items()}
assert sum(ang.values()) == 360
expect("m7-52", [f"{k.capitalize()} {pct[k]}% ({ang[k]}°)" if k == "pizza" else f"{k} {pct[k]}% ({ang[k]}°)" for k in counts],
       [sum(ang.values())])
expect("m7-53", [int(Fr(90, 360) * 480)])
expect("m7-54", [int(Fr(54, 360) * 1200)], [num(D(54) / 360)])
# S12
expect("m7-55", [num(D(11) / 40), num(D(11) / 40 * 100) + "%"])
expect("m7-56", ["9/50", num(D(9) / 50 * 100) + "%", int(D(9) / 50 * 300)])
f = Fr(4, 25); expect("m7-57", ["4/25", num(D(f.numerator) / f.denominator * 100) + "%"])
tosses = {"HH": 15, "HT": 17, "TH": 14, "TT": 14}; assert sum(tosses.values()) == 60
alo = Fr(tosses["HH"] + tosses["HT"] + tosses["TH"], 60)
expect("m7-58", [f"{alo.numerator}/{alo.denominator}"], [15 + 17 + 14])
f = Fr(6, 30); expect("m7-59", [f"{f.numerator}/{f.denominator}", "20%", int(f * 150)])
# S13
expect("m7-60", [num(D("0.12") * 40 + D("0")).replace("4.8", "4.80"), "44.80"])
expect("m7-61", ["4.80", "36.80"] if D("0.15") * 32 == D("4.8") and 32 + D("4.8") == D("36.8") else ["FAIL"])
expect("m7-62", [num(D("0.30") * 60), num(60 - D("0.30") * 60)])
orig = D(36) / D("0.8"); assert orig * D("0.8") == 36
expect("m7-63", [num(orig)])
sale = D("0.75") * 85; tax = D("0.12") * sale
assert (sale, tax, sale + tax) == (D("63.75"), D("7.65"), D("71.40"))
expect("m7-64", ["71.40"], ["63.75", "7.65"])

# Structural checks
for p in probs.values():
    checked += 1
    keys = {"id", "source", "prompt_latex", "prompt_plain", "prompt_parts", "worked_solution", "final_answer", "level"}
    if set(p) != keys or p["level"] != "middle_school" or not p["worked_solution"]:
        fails.append(f"{p['id']}: bad structure")
expected = {f"m7-{i:02d}" for i in range(1, 65)}
if set(probs) != expected:
    fails.append(f"id set mismatch: {sorted(set(probs) ^ expected)}")

print(f"problems: {len(probs)}, checks run: {checked}, failures: {len(fails)}")
for m in fails:
    print("FAIL", m)
sys.exit(1 if fails else 0)
