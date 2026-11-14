"""Re-runnable verifier for shared/courses/bc-math-8/problems.json.

Run:  python3 -I verify.py      (exits non-zero on any failure)

Two kinds of checks:
 1. Per-problem: recompute the answer independently (Fractions, brute force,
    enumeration) and require it to appear in final_answer and, where listed,
    in the worked_solution.
 2. Arithmetic scan: every simple "a op b ... = c" chain in every worked_solution
    line is evaluated with exact Fractions and compared.
"""
import json, math, os, re, statistics, sys
from fractions import Fraction as F
from itertools import product

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = json.load(open(os.path.join(HERE, "problems.json"), encoding="utf-8"))
BY_ID = {p["id"]: p for p in DATA}
failures = []


def norm(s):
    s = s.replace("−", "-").replace(" ", " ")
    return re.sub(r"(?<=\d) (?=\d{3}\b)", "", s)


def need(pid, final=(), ws=()):
    p = BY_ID[pid]
    f = norm(p["final_answer"])
    w = norm(" | ".join(p["worked_solution"]))
    for t in final:
        if norm(str(t)) not in f:
            failures.append(f"{pid}: final_answer lacks {t!r}: {p['final_answer']!r}")
    for t in ws:
        if norm(str(t)) not in w:
            failures.append(f"{pid}: worked_solution lacks {t!r}")


def mixed(fr):
    w, r = divmod(fr.numerator, fr.denominator)
    return f"{w} {r}/{fr.denominator}" if w and r else str(fr)


# ---- S1
need("m8-01", ["Perfect square", "not a perfect cube"])
assert 12 * 12 == 144 and not any(k ** 3 == 144 for k in range(1, 20))
need("m8-02", [15 ** 2 + 4 ** 3], [15 ** 2, 4 ** 3])
fac = {}; n = 216; d = 2
while n > 1:
    while n % d == 0: fac[d] = fac.get(d, 0) + 1; n //= d
    d += 1
assert fac == {2: 3, 3: 3} and 6 ** 3 == 216
need("m8-03", ["2³ × 3³", "6³"])
k = next(k for k in range(1, 100) if math.isqrt(72 * k) ** 2 == 72 * k)
need("m8-04", [k], [72 * k, math.isqrt(72 * k)])
sq = [i * i for i in range(1, 30) if 50 < i * i < 200]
need("m8-05", [len(sq)], [", ".join(map(str, sq)).split(", ")[0]])
for s in sq: need("m8-05", ws=[s])
# ---- S2
need("m8-06", [f"{math.isqrt(16)}/{math.isqrt(169)}"])
assert math.isqrt(16) ** 2 == 16 and math.isqrt(169) ** 2 == 169
need("m8-07", [round(125 ** (1 / 3)), "2/3"])
assert 5 ** 3 == 125 and F(2, 3) ** 3 == F(8, 27)
need("m8-08", [round(math.sqrt(30), 1)], ["30.25", "29.16", "29.7025"]); assert 5.45 ** 2 < 30 < 5.55 ** 2
assert abs(5.5 ** 2 - 30.25) < 1e-9 and abs(5.4 ** 2 - 29.16) < 1e-9
side = math.isqrt(289); assert side ** 2 == 289
need("m8-09", [4 * side], [side])
e = next(e for e in range(1, 50) if e ** 3 == 1728)
need("m8-10", [e, 6 * e * e], [e * e])
# ---- S3
need("m8-11", ["10000"]); assert F(1, 200) * 2_000_000 == 10000
need("m8-12", ["0.004", "2.5"]); assert F("0.4") / 100 == F("0.004") and F(250, 100) == F("2.5")
g = F("0.0325") * 600000; assert g == 19500
need("m8-13", [600000 + g], [g])
need("m8-14", [int(F("1.35") * 24000 - 24000)], [int(F("1.35") * 24000)])
orig = F(77000) / F("2.2"); assert orig == 35000 and orig * F("2.2") == 77000
need("m8-15", [int(orig)])
# ---- S4
one = F(105, 15)
need("m8-16", [f"{3*one} cm", f"{5*one} cm", f"{7*one} cm"]); assert 3 * one + 5 * one + 7 * one == 105
part = F(35, 7); need("m8-17", [f"{2*part} L blue", f"{5*part} L white"])
need("m8-18", [F(3, 12) * 20], ["0.25"])
need("m8-19", [f"{F(18,24)*100}%"])
need("m8-20", [F(240) / (F(90) / F("1.5"))], [F(90) / F("1.5")])
# ---- S5
frs = {
    "m8-21": F(2, 3) + F(3, 4), "m8-22": F(5, 6) - F(3, 8), "m8-23": F(3, 4) * F(2, 9),
    "m8-24": F(5, 6) / F(10, 9), "m8-25": F(3, 4) / F(3, 2) * (2 - F(1, 5)),
    "m8-26": F(3, 4) * (2 + F(1, 2)),
}
for pid, v in frs.items():
    if pid != "m8-26": need(pid, [f"{v.numerator}/{v.denominator}"])
need("m8-21", ["1 5/12"]); need("m8-26", ["1 7/8"]); assert mixed(frs["m8-26"]) == "1 7/8"
need("m8-22", ws=["20/24", "9/24"]); need("m8-23", ws=["6/36"]); need("m8-24", ws=["45/60"])
need("m8-25", ws=["9/5", "1/2"]); assert F(3, 4) / F(3, 2) == F(1, 2) and 2 - F(1, 5) == F(9, 5)
# ---- S6
xs, ys = [0, 1, 2, 3], [5, 8, 11, 14]
assert all(3 * x + 5 == y for x, y in zip(xs, ys)); need("m8-27", ["y = 3x + 5", 3 * 10 + 5])
need("m8-28", [", ".join(str(2 * x - 6) for x in (-2, 0, 3, 5))])
pts = [(0, 10), (5, 25), (10, 40)]; assert all(3 * x + 10 == y for x, y in pts)
need("m8-29", ["y = 3x + 10", 3 * 20 + 10])
assert 4 * 9 + 15 == 51 and (79 - 15) / 4 == 16; need("m8-30", ["$51", "16 GB"])
def quad(x, y): return "I" if x > 0 and y > 0 else "II" if x < 0 and y > 0 else "III" if x < 0 and y < 0 else "IV"
q = [(x, -x + 4) for x in (-3, -1, 2, 6)]
need("m8-31", [", ".join(str(y) for _, y in q), ", ".join(quad(*p) for p in q)])
# ---- S7
need("m8-32", [F("2.5") * 10 - 4 * 10 + 18])
need("m8-33", ["$%.2f" % (3.5 + 1.2 * 15)])
a, b, c = 4, -2, 5; need("m8-34", [2 * (a + 3 * b) - c])
assert [3 * n + 2 for n in (1, 2, 3)] == [5, 8, 11]; need("m8-35", ["3n + 2", 3 * 20 + 2])
# ---- S8
def solve(f, lo=-200, hi=200):
    s = [x for x in range(lo, hi) if f(F(x))]
    assert len(s) == 1, s
    return s[0]
need("m8-36", [f"x = {solve(lambda x: 3*x-4 == -19)}"])
need("m8-37", [f"x = {solve(lambda x: 5*x+7 == 32)}"])
need("m8-38", [f"x = {solve(lambda x: -2*x+9 == 21)}"])
need("m8-39", [f"x = {solve(lambda x: x/4-3 == 2)}"])
need("m8-40", [solve(lambda n: 18*n+45 == 225)])
need("m8-41", [f"x = {solve(lambda x: -7 == 3*x+5)}"])
# ---- S9
need("m8-42", [f"V = {5*4*3}", f"SA = {2*(20+15+12)}"])
assert 3 ** 2 + 4 ** 2 == 5 ** 2
need("m8-43", [f"V = {3*4//2*10}", f"SA = {2*(3*4//2)+(3+4+5)*10}"])
assert 90 * math.pi - 282.7 < 0.05; need("m8-44", ["90π", f"{90*math.pi:.1f}"])
assert 130 * math.pi - 408.4 < 0.05; need("m8-45", ["130π", f"{130*math.pi:.1f}"])
need("m8-46", [f"V = {6*4//2*9}", f"{2*12+(5+5+6)*9}"])
assert 150 / 25 == 6; need("m8-47", ["6 cm"])
# ---- S10
need("m8-48", [math.isqrt(6*6+8*8)]); assert math.isqrt(100) ** 2 == 100
need("m8-49", [math.isqrt(13*13-5*5)]); assert math.isqrt(144) ** 2 == 144
need("m8-50", [math.isqrt(17*17-8*8), "15 m"]); assert math.isqrt(225) ** 2 == 225
assert 7 ** 2 + 24 ** 2 == 25 ** 2; need("m8-51", ["Yes"])
assert 40 ** 2 + 30 ** 2 == 50 ** 2; need("m8-52", [70 - 50])
h = math.sqrt(52); need("m8-53", [f"{h:.1f}"]); assert 7.2 ** 2 < 52 < 7.3 ** 2
# ---- S11
box = (5, 3, 2); sa = 2 * (5*3 + 5*2 + 3*2); need("m8-54", ["5 × 3 × 2", sa])
need("m8-55", [3*2+2, 3*2])
need("m8-56", ["8π", f"{8*math.pi:.1f}", "80π", f"{80*math.pi:.1f}"])
# ---- S12
d1 = [5, 8, 6, 10, 6, 15, 6]
need("m8-57", [f"mean {statistics.mean(d1)}", f"median {statistics.median(d1)}", f"mode {statistics.mode(d1)}"])
d2 = [72, 85, 90, 85, 82, 90]
need("m8-58", [f"mean {statistics.mean(d2)}", f"median {int(statistics.median(d2))}", "modes 85 and 90"])
assert sorted(statistics.multimode(d2)) == [85, 90]
need("m8-59", [5 * 14 - (12 + 15 + 16 + 10)])
d4 = [40, 42, 44, 46, 248]
need("m8-60", [f"mean {statistics.mean(d4)}", f"median {statistics.median(d4)}"])
# ---- S13
need("m8-61", [str(F(1, 6) * F(1, 2))])
need("m8-62", [4 * 2, str(F(1, 8))]); assert len(list(product("RBGY", "HT"))) == 8
ev = sum(1 for a, b in product(range(1, 7), repeat=2) if a % 2 == 0 and b % 2 == 0)
need("m8-63", [str(F(ev, 36))])
need("m8-64", [str(F(3, 5) * F(2, 5))])
s7 = [(a, b) for a, b in product(range(1, 7), repeat=2) if a + b == 7]
need("m8-65", [str(F(len(s7), 36))], [len(s7)])
# ---- S14
assert 3 * F(300, 100) > 2 * F(420, 100) and F(300, 500) > F(420, 750); need("m8-66", ["Juice B"], ["9.00", "8.40"])
assert 40 * F(3, 4) == 30 and 30 < 32; need("m8-67", ["Store A", "$2"])
assert F("3.90") / 6 == F("0.65") and F(6) / 10 == F("0.60"); need("m8-68", ["10 for $6.00"])
first = next(m for m in range(0, 100) if 25 + 30 * m < 38 * m)
need("m8-69", [f"{first} months"], [25 + 30 * 3, 38 * 3, 25 + 30 * 4, 38 * 4])
assert F("7.98") / 2 - F("18.50") / 5 == F("0.29"); need("m8-70", ["5 kg", "$0.29"])

# ---- schema
for p in DATA:
    for k in ("id", "source", "prompt_latex", "prompt_plain", "prompt_parts", "worked_solution", "final_answer", "level"):
        if k not in p: failures.append(f"{p.get('id')}: missing {k}")
    if p["level"] != "middle_school": failures.append(f"{p['id']}: level")
    if not (2 <= len(p["worked_solution"]) <= 12): failures.append(f"{p['id']}: solution length {len(p['worked_solution'])}")
if len({p["id"] for p in DATA}) != len(DATA): failures.append("duplicate ids")

# ---- arithmetic scan over every worked_solution line
ATOM = r"-?\d+(?:\.\d+)?(?:/\d+)?"
CHAIN = rf"(?<![\w.²³/])({ATOM}(?:\s*[×÷+\-]\s*{ATOM})*)\s*=\s*({ATOM}(?:\s*[×÷+\-]\s*{ATOM})*)(?![\w.²³(/])"
def ev(expr):
    expr = expr.replace("×", "*").replace("÷", "/")
    expr = re.sub(r"(?<![\w.)])(\d+)/(\d+)(?![\d.])", r"F(\1,\2)", expr)
    expr = re.sub(r"(?<![\w.)])(\d+\.\d+)(?![\d.])", r"F('\1')", expr)
    expr = re.sub(r"(?<![\w.(),'])(\d+)(?![\d.(),'])", r"F(\1)", expr)
    return eval(expr, {"F": F, "__builtins__": {}})
checked = 0
for p in DATA:
    for line in p["worked_solution"]:
        line = norm(line)
        for m in re.finditer(CHAIN, line):
            before = line[:m.start()].rstrip(" ")
            after = line[m.end():]
            # skip chains that are only part of a bigger expression (brackets, roots,
            # variables, mixed numbers, a leading operator): they are not standalone
            if before and (before[-1] in "×÷+-−)√∛½(" or before[-1].isalnum() and line[m.start() - 1] == " " and before[-1].isdigit()):
                continue
            if re.match(r"\s*\d", after) or after[:1] in ("x", "n", "g", "h", "a"):
                continue
            try:
                l, r = ev(m.group(1)), ev(m.group(2))
            except Exception:
                continue
            checked += 1
            if l != r:
                failures.append(f"{p['id']}: arithmetic mismatch '{m.group(0)}' ({l} != {r}) in: {line}")

print(f"problems: {len(DATA)}; arithmetic chains checked: {checked}; failures: {len(failures)}")
for f in failures: print("FAIL", f)
sys.exit(1 if failures else 0)
