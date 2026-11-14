#!/usr/bin/env python3
"""Problem bank + verifier in one file (standard library only).

  python3 -I verify.py            re-check problems.json against this spec and re-run every maths check
  python3 -I verify.py --write    regenerate problems.json from this spec (then re-check)

Every problem below carries a check function that recomputes the final answer
(and key intermediate results) independently with fractions / math / brute force.
Exit code is non-zero if any check fails or problems.json differs from the spec.
"""
import json, math, re, sys, os, itertools
from fractions import Fraction as F
from math import comb, perm, factorial, pi, e, sqrt, sin, cos, tan, log, exp, atan, asin, acos

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEMS = []
STD = {}
PREFIX = ""


# ---------- text helpers ----------
def fmt(x):
    """Fraction/int/float -> short plain text (a/b, ints bare, floats trimmed to 6 dp)."""
    if isinstance(x, F):
        return str(x.numerator) if x.denominator == 1 else f"{x.numerator}/{x.denominator}"
    if isinstance(x, int):
        return str(x)
    r = round(x, 6)
    if r == int(r):
        return str(int(r))
    return f"{r:.6f}".rstrip("0").rstrip(".")


def rnd(x, n=2):
    """Round half away from zero to n decimals and print with exactly n decimals."""
    from decimal import Decimal, ROUND_HALF_UP
    q = Decimal(1).scaleb(-n)
    return str(Decimal(repr(x)).quantize(q, rounding=ROUND_HALF_UP))


def M(s):
    """Use the real minus sign."""
    return s.replace("-", "−")


_FR = re.compile(r"\{([^{}|]*)\|([^{}|]*)\}")


def _wrap(t):
    return f"({t})" if re.search(r"[\s+−*]", t) else t


def plain(prompt):
    return _FR.sub(lambda m: f"{_wrap(m.group(1))}/{_wrap(m.group(2))}", prompt)


def parts(prompt):
    out, i = [], 0
    for m in _FR.finditer(prompt):
        if m.start() > i:
            out.append({"text": prompt[i:m.start()]})
        out.append({"frac": {"num": m.group(1), "den": m.group(2)}})
        i = m.end()
    if i < len(prompt):
        out.append({"text": prompt[i:]})
    return out


_SUP = {"²": "^{2}", "³": "^{3}", "⁴": "^{4}", "⁵": "^{5}", "⁶": "^{6}"}
_SUB = {c: f"_{{{i}}}" for i, c in enumerate("₀₁₂₃₄₅₆₇₈₉")}
_SYM = [("⁻¹", "^{-1}"), ("∘", r"\circ "), ("−", "-"), ("×", r"\times "), ("÷", r"\div "), ("≤", r"\le "), ("≥", r"\ge "),
        ("≠", r"\ne "), ("π", r"\pi "), ("θ", r"\theta "), ("α", r"\alpha "), ("β", r"\beta "),
        ("∞", r"\infty "), ("°", r"^\circ "), ("→", r"\to "), ("∫", r"\int "), ("Σ", r"\sum "),
        ("Δ", r"\Delta "), ("≈", r"\approx "), ("∈", r"\in "), ("±", r"\pm "), ("•", r"\cdot ")]


def _sqrt(s):
    while "√(" in s:
        i = s.index("√(")
        d, j = 0, i + 1
        while True:
            d += s[j] == "("
            d -= s[j] == ")"
            if d == 0:
                break
            j += 1
        s = s[:i] + r"\sqrt{" + s[i + 2:j] + "}" + s[j + 1:]
    return s


def tex(s):
    s = _sqrt(s)
    for k, v in _SUP.items():
        s = s.replace(k, v)
    for k, v in _SUB.items():
        s = s.replace(k, v)
    for k, v in _SYM:
        s = s.replace(k, v)
    s = re.sub(r"\^\(([^()]*)\)", r"^{\1}", s)
    s = re.sub(r"\^([A-Za-z0-9])", r"^{\1}", s)
    s = re.sub(r"_([A-Za-z0-9])", r"_{\1}", s)
    s = re.sub(r"(?<![A-Za-z\\])(arcsin|arccos|arctan|sin|cos|tan|sec|csc|cot|ln|log|lim|det)(?![A-Za-z])", r"\\\1", s)
    return s


def latex(prompt):
    out, i = "", 0
    for m in _FR.finditer(prompt):
        out += tex(prompt[i:m.start()]) + r"\dfrac{" + tex(m.group(1)) + "}{" + tex(m.group(2)) + "}"
        i = m.end()
    return (out + tex(prompt[i:])).strip()


# ---------- registry ----------
def P(std, prompt, steps, final, chk):
    n = len(PROBLEMS) + 1
    PROBLEMS.append({
        "spec": {
            "id": f"{PREFIX}-{n:02d}",
            "source": f"{STD[std]}; original",
            "prompt_latex": latex(M(prompt)),
            "prompt_plain": plain(M(prompt)),
            "prompt_parts": parts(M(prompt)),
            "worked_solution": [M(s) for s in steps],
            "final_answer": M(final),
            "level": "high_school",
        },
        "chk": chk,
        "std": std,
    })


# ---------- numeric helpers ----------
def D(f, x, h=1e-5):
    return (f(x + h) - f(x - h)) / (2 * h)


def D2(f, x, h=1e-4):
    return (f(x + h) - 2 * f(x) + f(x - h)) / (h * h)


def simpson(f, a, b, n=2000):
    h = (b - a) / n
    s = f(a) + f(b)
    for k in range(1, n):
        s += (4 if k % 2 else 2) * f(a + k * h)
    return s * h / 3


def near(a, b, tol=1e-4):
    return abs(a - b) <= tol * max(1.0, abs(a), abs(b))


def req(cond, msg="check failed"):
    if not cond:
        raise AssertionError(msg)


def polyval(c, x):
    r = 0
    for a in c:
        r = r * x + a
    return r


def polymul(a, b):
    r = [0] * (len(a) + len(b) - 1)
    for i, x in enumerate(a):
        for j, y in enumerate(b):
            r[i + j] += x * y
    return r


def polydiv(n, d):
    """Long division of coefficient lists (highest degree first) -> (quotient, remainder), Fractions."""
    n = [F(x) for x in n]
    q = []
    while len(n) >= len(d):
        c = n[0] / d[0]
        q.append(c)
        for i in range(len(d)):
            n[i] -= c * d[i]
        n.pop(0)
    return q, n


def int_roots(c, lim=60):
    """All integer and simple rational roots (denominator <= 6) of a polynomial by brute force."""
    out = []
    for den in range(1, 7):
        for num in range(-lim * den, lim * den + 1):
            r = F(num, den)
            if r.denominator == den and polyval(c, r) == 0:
                out.append(r)
    return sorted(out)


def bisect(f, a, b, it=200):
    fa = f(a)
    for _ in range(it):
        m = (a + b) / 2
        fm = f(m)
        if (fa < 0) == (fm < 0):
            a, fa = m, fm
        else:
            b = m
    return (a + b) / 2


def main():
    write = "--write" in sys.argv
    path = os.path.join(HERE, "problems.json")
    specs = [p["spec"] for p in PROBLEMS]
    fails = 0
    ids = [s["id"] for s in specs]
    if len(set(ids)) != len(ids):
        print("FAIL duplicate ids")
        fails += 1
    passed = 0
    for p in PROBLEMS:
        s = p["spec"]
        try:
            got = M(p["chk"]())
            if got != s["final_answer"]:
                raise AssertionError(f"computed {got!r} != final_answer {s['final_answer']!r}")
            if not s["worked_solution"]:
                raise AssertionError("empty worked_solution")
            passed += 1
            print("ok  ", s["id"], "|", s["final_answer"])
        except Exception as ex:
            fails += 1
            print("FAIL", s["id"], "|", type(ex).__name__, ex)
    if write:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(specs, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print("wrote", path)
    else:
        try:
            on_disk = json.load(open(path, encoding="utf-8"))
        except Exception as ex:
            on_disk = None
            print("FAIL cannot read problems.json:", ex)
            fails += 1
        if on_disk is not None and on_disk != specs:
            fails += 1
            print("FAIL problems.json differs from this spec (run with --write)")
    print(f"{passed}/{len(PROBLEMS)} problems verified; failures: {fails}")
    sys.exit(1 if fails else 0)

PREFIX = "fm12"
RAD = math.radians
STD.update({
    "gc": "BC Foundations of Mathematics 12 content: geometric explorations, constructions (perpendicular bisector, tangents, polygons, tessellations)",
    "cn": "BC Foundations of Mathematics 12 content: geometric explorations, conics (locus definition and constructions, conic sections, applications)",
    "fr": "BC Foundations of Mathematics 12 content: geometric explorations, fractals (iteration of a simple instruction; Cantor dust, Sierpinski triangle, Koch snowflake)",
    "gr": "BC Foundations of Mathematics 12 content: graphical representations of polynomial, logarithmic, exponential and sinusoidal functions (using characteristics of a graph to identify them; the curriculum says technology only, so these are short characteristic-reading versions)",
    "rg": "BC Foundations of Mathematics 12 content: regression analysis (polynomial, exponential, sinusoidal, logarithmic; applying the appropriate model; by hand versions of the model step)",
    "cb": "BC Foundations of Mathematics 12 content: combinatorics (permutations, combinations, pathways, Pascal's triangle)",
    "pr": "BC Foundations of Mathematics 12 content: odds, probability and expected value (mutually exclusive, non mutually exclusive, conditional, binomial; Venn diagrams)",
    "fp": "BC Foundations of Mathematics 12 content: financial planning (mortgages, risk, changing interest rates and payments, credit cards, banking options)",
})


# ================= gc =================
def c_gc_1():
    A, B = (1, 2), (7, 6)
    line = lambda x: -1.5 * x + 10
    for x in [-3, 0, 2, 4, 9]:
        P_ = (x, line(x))
        req(near(math.dist(P_, A), math.dist(P_, B)))
    req(line(4) == 4)
    return "y = -(3/2)x + 10"
P("gc", "Find the equation of the perpendicular bisector of the segment from A(1, 2) to B(7, 6).",
  ["Midpoint: ((1 + 7)/2, (2 + 6)/2) = (4, 4)", "Slope of AB: (6 - 2)/(7 - 1) = 4/6 = 2/3", "Perpendicular slope is the negative reciprocal: -3/2", "y - 4 = -(3/2)(x - 4)", "y = -(3/2)x + 6 + 4 = -(3/2)x + 10"],
  "y = -(3/2)x + 10", c_gc_1)


def c_gc_2():
    # tangent at (3,4) to x^2+y^2=25 : 3x + 4y = 25 ; every other point of the line is outside the circle
    for x in [-5, -1, 1, 3, 7, 11]:
        y = (25 - 3 * x) / 4
        req(x * x + y * y >= 25 - 1e-9)
    req(3 * 3 + 4 * 4 == 25)
    return "3x + 4y = 25"
P("gc", "Find the equation of the tangent to the circle x² + y² = 25 at the point (3, 4).",
  ["A tangent is perpendicular to the radius at the point of tangency", "Radius from (0, 0) to (3, 4) has slope 4/3, so the tangent slope is -3/4", "y - 4 = -(3/4)(x - 3)",
   "Multiply by 4: 4y - 16 = -3x + 9", "3x + 4y = 25"],
  "3x + 4y = 25", c_gc_2)


def c_gc_3():
    n = 8
    interior = (n - 2) * 180 / n
    exterior = 360 / n
    req(interior + exterior == 180)
    return f"interior {fmt(interior)}°, exterior {fmt(exterior)}°"
P("gc", "Find the size of each interior angle and each exterior angle of a regular octagon.",
  ["Interior angle sum of an n sided polygon: (n - 2)(180°) = 6(180°) = 1080°", "Each interior angle: 1080° / 8 = 135°", "Exterior angle: 180° - 135° = 45° (or 360°/8)"],
  "interior 135°, exterior 45°", c_gc_3)


def c_gc_4():
    ang = F(3 * 180, 5)
    req(ang == 108 and 360 % 108 != 0 and 3 * 108 < 360 < 4 * 108)
    return "108° does not divide 360° (3 pentagons leave a 36° gap, 4 overlap)"
P("gc", "Explain why regular pentagons cannot tessellate the plane by themselves.",
  ["Interior angle of a regular pentagon: 3(180°)/5 = 108°", "Angles at a vertex must add to exactly 360°", "3 pentagons: 324° leaves a 36° gap. 4 pentagons: 432° overlaps",
   "360/108 is not a whole number, so the pentagons never fit"],
  "108° does not divide 360° (3 pentagons leave a 36° gap, 4 overlap)", c_gc_4)


def c_gc_5():
    A, B, C = (0, 0), (6, 0), (0, 8)
    O = (3, 4)
    d = [math.dist(O, p) for p in (A, B, C)]
    req(all(near(x, 5) for x in d))
    return "circumcentre (3, 4), radius 5"
P("gc", "Triangle ABC has A(0, 0), B(6, 0) and C(0, 8). Find its circumcentre and the circumradius using perpendicular bisectors.",
  ["Perpendicular bisector of AB (horizontal side from (0, 0) to (6, 0)): x = 3", "Perpendicular bisector of AC (vertical side from (0, 0) to (0, 8)): y = 4", "They meet at (3, 4)",
   "Radius = distance to A = √(9 + 16) = 5", "Check distance to B: √(9 + 16) = 5 and to C: √(9 + 16) = 5 ✓"],
  "circumcentre (3, 4), radius 5", c_gc_5)


# ================= cn =================
def c_cn_1():
    f = (0, 2)
    for x in [-6, -2, 0, 3, 8]:
        y = x * x / 8
        req(near(math.dist((x, y), f), y + 2))
    return "x² = 8y"
P("cn", "A parabola is the set of points equally far from the focus (0, 2) and the directrix y = -2. Find its equation.",
  ["Let P(x, y). Distance to the focus: √(x² + (y - 2)²). Distance to the directrix: y + 2", "Set equal and square: x² + (y - 2)² = (y + 2)²",
   "x² + y² - 4y + 4 = y² + 4y + 4", "x² = 8y"],
  "x² = 8y", c_cn_1)


def c_cn_2():
    # x^2 + y^2 - 6x + 4y - 12 = 0 -> (x-3)^2 + (y+2)^2 = 25
    for ang in range(0, 360, 30):
        x, y = 3 + 5 * cos(RAD(ang)), -2 + 5 * sin(RAD(ang))
        req(abs(x * x + y * y - 6 * x + 4 * y - 12) < 1e-9)
    return "centre (3, -2), radius 5"
P("cn", "Find the centre and radius of x² + y² - 6x + 4y - 12 = 0.",
  ["Group: (x² - 6x) + (y² + 4y) = 12", "Complete the squares: add 9 and 4 to both sides", "(x - 3)² + (y + 2)² = 12 + 9 + 4 = 25", "Centre (3, -2), radius 5"],
  "centre (3, -2), radius 5", c_cn_2)


def c_cn_3():
    a2, b2 = 25, 9
    c = sqrt(a2 - b2)
    req(near(c, 4))
    for t in range(0, 360, 20):
        x, y = 5 * cos(RAD(t)), 3 * sin(RAD(t))
        req(near(math.dist((x, y), (4, 0)) + math.dist((x, y), (-4, 0)), 10))
    return "vertices (±5, 0), foci (±4, 0)"
P("cn", "For the ellipse {x²|25} + {y²|9} = 1, find the vertices on the x axis and the foci.",
  ["a² = 25 (larger, under x²), b² = 9, so a = 5 and b = 3", "Vertices on the major axis: (±5, 0)", "c² = a² - b² = 25 - 9 = 16, so c = 4", "Foci (±4, 0)"],
  "vertices (±5, 0), foci (±4, 0)", c_cn_3)


def c_cn_4():
    a, b = 4, 3
    c = sqrt(a * a + b * b)
    req(c == 5)
    # asymptote slope b/a ; far points of the hyperbola approach it
    for x in [100, 1000]:
        y = b * sqrt(x * x / (a * a) - 1)
        req(abs(y - 0.75 * x) < 0.2)
    return "vertices (±4, 0), foci (±5, 0), asymptotes y = ±(3/4)x"
P("cn", "For the hyperbola {x²|16} - {y²|9} = 1, find the vertices, foci and asymptotes.",
  ["a² = 16, b² = 9: a = 4, b = 3", "Vertices (±4, 0)", "For a hyperbola c² = a² + b² = 25, so c = 5 and the foci are (±5, 0)", "Asymptotes y = ±(b/a)x = ±(3/4)x"],
  "vertices (±4, 0), foci (±5, 0), asymptotes y = ±(3/4)x", c_cn_4)


def c_cn_5():
    for t in range(0, 360, 15):
        x, y = 5 * cos(RAD(t)), 4 * sin(RAD(t))
        req(near(math.dist((x, y), (3, 0)) + math.dist((x, y), (-3, 0)), 10))
    return "x²/25 + y²/16 = 1"
P("cn", "The sum of the distances from a point to (-3, 0) and (3, 0) is always 10. Find the equation of the locus.",
  ["This is an ellipse with foci (±3, 0), so c = 3", "Sum of distances = 2a = 10, so a = 5", "b² = a² - c² = 25 - 9 = 16", "x²/25 + y²/16 = 1",
   "Check (0, 4): distances √(9 + 16) = 5 each, sum 10 ✓"],
  "x²/25 + y²/16 = 1", c_cn_5)


def c_cn_6():
    p = 16 / 4
    req(p == 4)
    # points on y = x^2/16 equidistant from (0,4) and y = -4
    for x in [-8, -2, 0, 5, 12]:
        y = x * x / 16
        req(near(math.dist((x, y), (0, 4)), y + 4))
    return "focus (0, 4), 4 m above the vertex"
P("cn", "A satellite dish cross section is the parabola y = x²/16 (metres). Find the coordinates of the focus, where the receiver goes.",
  ["Write x² = 16y and compare with x² = 4py", "4p = 16, so p = 4", "The focus is p units above the vertex (0, 0): (0, 4)", "Check: (8, 4) is on the parabola (64/16 = 4). Its distance to (0, 4) is 8 and its distance to the line y = -4 is 4 + 4 = 8 ✓"],
  "focus (0, 4), 4 m above the vertex", c_cn_6)


# ================= fr =================
def c_fr_1():
    p = 27 * F(4, 3) ** 3
    req(p == 64)
    return "64 cm"
P("fr", "A Koch snowflake starts as an equilateral triangle with side 9 cm. Each iteration replaces every segment by 4 segments one third as long. Find the perimeter after 3 iterations.",
  ["Start perimeter: 3 · 9 = 27 cm", "Each iteration multiplies the number of segments by 4 and the length by 1/3, so the perimeter by 4/3", "After 3 iterations: 27(4/3)³ = 27 · 64/27", "= 64 cm"],
  "64 cm", c_fr_1)


def c_fr_2():
    n = 5
    count, area = 3 ** n, F(3, 4) ** n
    req(count == 243 and area == F(243, 1024))
    return "243 triangles remain; area fraction 243/1024"
P("fr", "In the Sierpinski triangle, each step removes the middle triangle from every remaining triangle. After 5 steps, how many triangles remain, and what fraction of the original area is left?",
  ["Each remaining triangle becomes 3 smaller ones, so the count is 3ⁿ: 3⁵ = 243", "Each step keeps 3/4 of the area (one of four equal parts removed)", "(3/4)⁵ = 243/1024"],
  "243 triangles remain; area fraction 243/1024", c_fr_2)


def c_fr_3():
    n = 4
    segs, length = 2 ** n, F(2, 3) ** n
    req(segs == 16 and length == F(16, 81) and segs * F(1, 3 ** n) == length)
    return "16 segments, total length 16/81"
P("fr", "Cantor dust starts with a segment of length 1. Each step removes the open middle third of every segment. After 4 steps, how many segments are there and what is their total length?",
  ["Each step doubles the number of segments: 2⁴ = 16", "Each segment is (1/3)⁴ = 1/81 long", "Total length 16 · (1/81) = 16/81 (which is (2/3)⁴)"],
  "16 segments, total length 16/81", c_fr_3)


def c_fr_4():
    d = log(3) / log(2)
    req(near(2 ** d, 3))
    return f"D = ln 3 / ln 2 ≈ {rnd(d)}"
P("fr", "Halving the side of a Sierpinski triangle gives 3 copies of itself. Find its fractal dimension D, where 3 = 2^D, to 2 decimal places.",
  ["Scale factor 2 (each piece is half the size) gives 3 pieces: 2^D = 3", "Take logs: D ln 2 = ln 3", "D = 1.0986 / 0.6931 ≈ 1.58", "Between a line (1) and a filled region (2), as expected for a fractal"],
  "D = ln 3 / ln 2 ≈ 1.58", c_fr_4)


# ================= gr =================
def c_gr_1():
    f = lambda x: 2 * 2 ** x
    req(f(0) == 2 and f(1) == 4 and f(2) == 8 and f(-50) < 1e-10)
    return "exponential, y = 2(2)^x"
P("gr", "A graph has y intercept 2, passes through (1, 4) and (2, 8), and flattens toward y = 0 as x gets very negative. Identify the function type and write its equation.",
  ["y values double each time x goes up by 1: ratio 4/2 = 2 and 8/4 = 2", "A constant ratio means exponential: y = a(b)^x with b = 2", "y intercept 2 gives a = 2", "y = 2(2)^x with horizontal asymptote y = 0"],
  "exponential, y = 2(2)^x", c_gr_1)


def c_gr_2():
    mx, mn, xmx, xmn = 5, -1, 2, 6
    amp, mid, period = (mx - mn) / 2, (mx + mn) / 2, 2 * (xmn - xmx)
    req(amp == 3 and mid == 2 and period == 8)
    return "sinusoidal: amplitude 3, midline y = 2, period 8"
P("gr", "A graph repeats smoothly, with a maximum of 5 at x = 2 and the next minimum of -1 at x = 6. Identify the function type and give its amplitude, midline and period.",
  ["A smooth repeating wave is sinusoidal", "Amplitude = (5 - (-1))/2 = 3", "Midline = (5 + (-1))/2 = 2", "Maximum to the next minimum is half a period: 6 - 2 = 4, so the period is 8"],
  "sinusoidal: amplitude 3, midline y = 2, period 8", c_gr_2)


def c_gr_3():
    f = lambda x: math.log2(x)
    req(f(1) == 0 and f(2) == 1 and f(4) == 2 and f(8) == 3)
    return "logarithmic, y = log₂ x"
P("gr", "A graph has a vertical asymptote at x = 0, passes through (1, 0), (2, 1) and (4, 2), and rises ever more slowly. Identify the function and write its equation.",
  ["A vertical asymptote at x = 0 and a point (1, 0) suggest a logarithm", "Each doubling of x adds 1 to y: (2, 1), (4, 2), so the base is 2", "y = log₂ x"],
  "logarithmic, y = log₂ x", c_gr_3)


def c_gr_4():
    f = lambda x: -(x + 1) * (x - 2) * (x - 3)
    req(f(-1) == f(2) == f(3) == 0 and f(-100) > 0 and f(100) < 0)
    return "polynomial, least degree 3, negative leading coefficient"
P("gr", "A graph crosses the x axis at -1, 2 and 3, rises toward the top on the far left and falls toward the bottom on the far right. Name the function type, its least degree and the sign of its leading coefficient.",
  ["Smooth curve with several x intercepts and no asymptotes: polynomial", "Three zeros means degree at least 3", "Ends in opposite directions means odd degree", "Up on the left, down on the right means negative leading coefficient"],
  "polynomial, least degree 3, negative leading coefficient", c_gr_4)


# ================= rg =================
def c_rg_1():
    a = 50
    b = (400 / a) ** (1 / 3)
    req(near(b, 2))
    f = lambda x: 50 * 2 ** x
    return f"y = 50(2)^x; y(5) = {f(5)}"
P("rg", "An exponential model y = a·b^x passes through (0, 50) and (3, 400). Find the model and predict y at x = 5.",
  ["x = 0 gives a = 50", "x = 3: 50b³ = 400, so b³ = 8 and b = 2", "y = 50(2)^x", "y(5) = 50(32) = 1600"],
  "y = 50(2)^x; y(5) = 1600", c_rg_1)


def c_rg_2():
    a = exp(1.2)
    req(near(a, 3.3201, 1e-4))
    x = 2.0
    req(near(math.log(a * exp(0.5 * x)), 1.2 + 0.5 * x))
    return f"y ≈ {rnd(a)}e^(0.5x)"
P("rg", "A calculator fits a line to (x, ln y) and gets ln y = 1.2 + 0.5x. Write the exponential model y = a·e^(bx) and give a to 2 decimal places.",
  ["Raise e to both sides: y = e^(1.2 + 0.5x)", "= e^1.2 · e^(0.5x)", "e^1.2 ≈ 3.32", "y ≈ 3.32e^(0.5x)"],
  "y ≈ 3.32e^(0.5x)", c_rg_2)


def c_rg_3():
    T = lambda t: 6 * cos(pi * (t - 14) / 12) + 12
    req(near(T(14), 18) and near(T(2), 6) and near(T(38), 18) and near(T(26), 6))
    return "T(t) = 6 cos(π(t - 14)/12) + 12"
P("rg", "A day's temperature peaks at 18 °C at t = 14 h and bottoms out at 6 °C at t = 2 h. Write a model T(t) = a cos(b(t - c)) + d with a > 0, b > 0 and c equal to the time of the maximum.",
  ["a = (18 - 6)/2 = 6 and d = (18 + 6)/2 = 12", "Maximum to minimum is 12 hours, so the period is 24 and b = 2π/24 = π/12", "A plain cosine peaks at its start, so shift the start to the peak time: c = 14",
   "T(t) = 6 cos(π(t - 14)/12) + 12", "Check: T(2) = 6 cos(-π) + 12 = 6 ✓"],
  "T(t) = 6 cos(π(t - 14)/12) + 12", c_rg_3)


def c_rg_4():
    data = [(1, 2), (2, 5), (3, 10), (4, 17)]
    A = lambda x: 3 * x - 2
    B = lambda x: x * x + 1
    sa = sum((y - A(x)) ** 2 for x, y in data)
    sb = sum((y - B(x)) ** 2 for x, y in data)
    req(sa == 60 and sb == 0)
    return "SSE 60 for the line, 0 for the quadratic; y = x² + 1 fits better"
P("rg", "Data: (1, 2), (2, 5), (3, 10), (4, 17). Compare the sum of squared residuals for y = 3x - 2 and y = x² + 1 and pick the better model.",
  ["Line y = 3x - 2 predicts 1, 4, 7, 10. Residuals 2 - 1, 5 - 4, 10 - 7, 17 - 10 = 1, 1, 3, 7", "SSE = 1 + 1 + 9 + 49 = 60",
   "Quadratic y = x² + 1 predicts 2, 5, 10, 17: all residuals 0, SSE = 0", "The smaller SSE wins: y = x² + 1"],
  "SSE 60 for the line, 0 for the quadratic; y = x² + 1 fits better", c_rg_4)


# ================= cb =================
def c_cb_1():
    return f"{4 * 6 * 3}"
P("cb", "A menu has 4 appetizers, 6 mains and 3 desserts. How many meals have one of each?",
  ["Fundamental counting principle: multiply the choices", "4 × 6 × 3 = 72"],
  "72", c_cb_1)


def c_cb_2():
    v = perm(8, 5)
    req(v == len(list(itertools.permutations(range(8), 5))))
    return f"{v}"
P("cb", "Eight runners race. In how many ways can the first five places be filled?",
  ["Order matters, so use permutations: P(8, 5) = 8!/(8 - 5)!", "= 8 × 7 × 6 × 5 × 4", "= 6720"],
  "6720", c_cb_2)


def c_cb_3():
    v = factorial(10) // (factorial(3) * factorial(3) * factorial(2))
    req(v == 50400)
    return f"{v}"
P("cb", "How many different arrangements are there of the letters in STATISTICS?",
  ["10 letters: S appears 3 times, T 3 times, I 2 times, A once, C once", "Divide out the repeats: 10!/(3! 3! 2!)", "= 3 628 800 / (6 × 6 × 2) = 3 628 800 / 72", "= 50 400"],
  "50400", c_cb_3)


def c_cb_4():
    v = comb(7, 3) * comb(5, 2)
    req(v == 350)
    return f"{v}"
P("cb", "A team of 3 boys and 2 girls is chosen from 7 boys and 5 girls. How many different teams are possible?",
  ["Order does not matter, so use combinations", "Boys: C(7, 3) = 35", "Girls: C(5, 2) = 10", "Multiply: 35 × 10 = 350"],
  "350", c_cb_4)


def c_cb_5():
    paths = lambda e, n: comb(e + n, n)
    v = paths(5, 3)
    # brute force count of lattice paths
    def count(e, n):
        if e == 0 or n == 0: return 1
        return count(e - 1, n) + count(e, n - 1)
    req(count(5, 3) == v == 56)
    return f"{v}"
P("cb", "How many shortest paths are there on a grid from (0, 0) to (5, 3) moving only right or up?",
  ["Every path has 5 rights (R) and 3 ups (U): 8 moves in total", "Choose which 3 of the 8 moves are U: C(8, 3)", "= 56"],
  "56", c_cb_5)


def c_cb_6():
    def count(e, n):
        if e == 0 or n == 0: return 1
        return count(e - 1, n) + count(e, n - 1)
    v = count(2, 1) * count(3, 2)
    req(v == comb(3, 1) * comb(5, 2) == 30)
    return f"{v}"
P("cb", "How many shortest paths go from (0, 0) to (5, 3), moving only right or up, and pass through (2, 1)?",
  ["Split the trip at (2, 1)", "(0, 0) to (2, 1): 2 rights and 1 up, C(3, 1) = 3 paths", "(2, 1) to (5, 3): 3 rights and 2 ups, C(5, 2) = 10 paths", "Multiply: 3 × 10 = 30"],
  "30", c_cb_6)


def c_cb_7():
    c = polymul(polymul([1, 2], [1, 2]), polymul([1, 2], [1, 2]))
    req(c == [1, 8, 24, 32, 16])
    return "x⁴ + 8x³ + 24x² + 32x + 16"
P("cb", "Use the row of Pascal's triangle that begins 1, 4 to expand (x + 2)⁴.",
  ["The row for exponent 4 is 1, 4, 6, 4, 1", "Terms: 1·x⁴ + 4·x³(2) + 6·x²(2²) + 4·x(2³) + 1·(2⁴)", "= x⁴ + 8x³ + 24x² + 32x + 16"],
  "x⁴ + 8x³ + 24x² + 32x + 16", c_cb_7)


# ================= pr =================
def c_pr_1():
    p = F(1, 5)
    fav, against = p, 1 - p
    req(fav / against == F(1, 4))
    return "odds in favour 1 : 4, odds against 4 : 1"
P("pr", "The probability of rain tomorrow is 0.2. State the odds in favour of rain and the odds against.",
  ["P(rain) = 0.2 = 1/5 and P(no rain) = 4/5", "Odds in favour = P(rain) : P(no rain) = 1 : 4", "Odds against = 4 : 1"],
  "odds in favour 1 : 4, odds against 4 : 1", c_pr_1)


def c_pr_2():
    v = F(3, 10) + F(45, 100)
    req(v == F(3, 4))
    return "0.75"
P("pr", "A and B are mutually exclusive with P(A) = 0.30 and P(B) = 0.45. Find P(A or B).",
  ["Mutually exclusive means they cannot both happen, so P(A and B) = 0", "P(A or B) = P(A) + P(B) = 0.30 + 0.45", "= 0.75"],
  "0.75", c_pr_2)


def c_pr_3():
    deck = [(r, s) for r in range(13) for s in range(4)]       # suit 0 = hearts; ranks 10,11,12 = J,Q,K
    fav = [c for c in deck if c[1] == 0 or c[0] >= 10]
    req(len(fav) == 22)
    return fmt(F(len(fav), 52))
P("pr", "One card is drawn from a standard deck of 52. Find P(heart or face card). Face cards are J, Q, K.",
  ["Not mutually exclusive: the J, Q, K of hearts are in both groups", "P(heart) = 13/52, P(face) = 12/52, P(heart and face) = 3/52", "P(heart or face) = 13/52 + 12/52 - 3/52 = 22/52", "= 11/26"],
  "11/26", c_pr_3)


def c_pr_4():
    neither = 30 - (18 + 12 - 5)
    only_f, only_s = 18 - 5, 12 - 5
    req(only_f + only_s + 5 + neither == 30 and neither == 5)
    return f"{neither} students"
P("pr", "In a class of 30, 18 take French, 12 take Spanish and 5 take both. How many take neither? Use a Venn diagram.",
  ["Both: 5. Only French: 18 - 5 = 13. Only Spanish: 12 - 5 = 7", "In at least one: 13 + 5 + 7 = 25", "Neither: 30 - 25 = 5"],
  "5 students", c_pr_4)


def c_pr_5():
    p = F(4, 52) * F(3, 51)
    req(p == F(1, 221))
    pairs = list(itertools.permutations(range(52), 2))
    aces = [pq for pq in pairs if pq[0] < 4 and pq[1] < 4]
    req(F(len(aces), len(pairs)) == p)
    return fmt(p)
P("pr", "Two cards are drawn from a standard deck without replacement. Find the probability that both are aces.",
  ["P(first is an ace) = 4/52", "Given that, 3 aces remain among 51 cards: P(second is an ace | first) = 3/51", "P(both) = (4/52)(3/51) = 12/2652", "= 1/221"],
  "1/221", c_pr_5)


def c_pr_6():
    v = F(2, 10) / F(5, 10)
    req(v == F(2, 5))
    return fmt(v)
P("pr", "In a club, P(plays chess) = 0.5 and P(plays chess and guitar) = 0.2. Find P(guitar | chess).",
  ["Conditional probability: P(G | C) = P(G and C) / P(C)", "= 0.2 / 0.5", "= 2/5 (0.4)"],
  "2/5", c_pr_6)


def c_pr_7():
    v = F(comb(6, 4), 2 ** 6)
    req(v == F(15, 64))
    outcomes = list(itertools.product("HT", repeat=6))
    req(F(sum(o.count("H") == 4 for o in outcomes), 64) == v)
    return fmt(v)
P("pr", "A fair coin is flipped 6 times. Find the probability of exactly 4 heads.",
  ["Binomial: P(k) = C(n, k) p^k (1 - p)^(n - k) with n = 6, k = 4, p = 1/2", "C(6, 4) = 15", "(1/2)⁴(1/2)² = 1/64", "15/64"],
  "15/64", c_pr_7)


def c_pr_8():
    p = 0.7
    v = sum(comb(5, k) * p ** k * (1 - p) ** (5 - k) for k in (4, 5))
    return f"{rnd(v, 3)}"
P("pr", "A player makes 70% of free throws. In 5 shots, find P(at least 4 makes) to 3 decimal places.",
  ["At least 4 means exactly 4 or exactly 5", "P(4) = C(5, 4)(0.7)⁴(0.3) = 5(0.2401)(0.3) = 0.36015", "P(5) = (0.7)⁵ = 0.16807", "0.36015 + 0.16807 = 0.52822 ≈ 0.528"],
  "0.528", c_pr_8)


def c_pr_9():
    ev_payout = F(1, 6) * 6 + F(5, 6) * 0
    net = ev_payout - 2
    req(net == -1 and ev_payout == 1)
    return "expected net -$1.00; a fair entry fee is $1"
P("pr", "A game costs $2 to play. You roll a fair die and are paid $6 if you roll a 6, otherwise nothing. Find the expected net gain per game and the entry fee that would make the game fair.",
  ["Expected winnings: (1/6)(6) + (5/6)(0) = 1", "Expected net = 1 - 2 = -1, so you lose $1 per game on average", "A fair game has expected net 0, so the fee would be $1"],
  "expected net -$1.00; a fair entry fee is $1", c_pr_9)


# ================= fp =================
def c_fp_1():
    v = 5000 * (1 + 0.036 / 12) ** 60
    return f"${rnd(v)}"
P("fp", "$5000 is invested at 3.6% per year compounded monthly for 5 years. Find the final amount.",
  ["Monthly rate i = 0.036/12 = 0.003; n = 12 × 5 = 60 periods", "A = 5000(1.003)^60", "(1.003)^60 ≈ 1.1968948", "A ≈ 5000(1.1968948) ≈ $5984.47"],
  "$5984.47", c_fp_1)


def c_fp_2():
    i, n, Pv = 0.05 / 12, 300, 300000
    pm = Pv * i / (1 - (1 + i) ** -n)
    # check by amortizing: balance after n payments of pm is ~0
    bal = Pv
    for _ in range(n):
        bal = bal * (1 + i) - round(pm, 2)
    req(abs(bal) < 5)
    return f"${rnd(pm)} per month"
P("fp", "A $300 000 mortgage is at 5% per year compounded monthly with monthly payments over 25 years. Find the monthly payment.",
  ["i = 0.05/12 = 0.0041667 and n = 25 × 12 = 300", "PMT = P · i / (1 - (1 + i)^(-n))", "(1 + i)^(-300) ≈ 0.28725", "PMT = 300000(0.0041667)/(1 - 0.28725) = 1250/0.71275", "≈ $1753.77"],
  "$1753.77 per month", c_fp_2)


def c_fp_3():
    pm = round(300000 * (0.05 / 12) / (1 - (1 + 0.05 / 12) ** -300), 2)
    total = pm * 300
    interest = total - 300000
    return f"${interest:,.0f}".replace(",", " ") + " in interest"
P("fp", "For the $300 000 mortgage with payments of $1753.77 for 300 months, how much interest is paid in total?",
  ["Total paid = 1753.77 × 300 = $526 131", "Interest = total paid - amount borrowed = 526 131 - 300 000", "= $226 131 (about 75% of the amount borrowed)"],
  "$226 131 in interest", c_fp_3)


def c_fp_4():
    bal, rate = 1500, 0.192 / 12
    interest = bal * rate
    new = bal + interest - 45
    req(near(interest, 24) and near(new, 1479))
    return "interest $24.00, new balance $1479.00"
P("fp", "A credit card charges 19.2% per year compounded monthly. On a $1500 balance, find one month's interest, then the balance after a $45 minimum payment (no new purchases).",
  ["Monthly rate = 19.2%/12 = 1.6% = 0.016", "Interest = 1500(0.016) = $24.00", "New balance = 1500 + 24 - 45 = $1479.00", "Only $21 of the $45 payment reduced the debt"],
  "interest $24.00, new balance $1479.00", c_fp_4)


def c_fp_5():
    n = -math.log(1 - 10000 * 0.005 / 500) / math.log(1.005)
    bal = 10000.0
    k = 0
    while bal > 0:
        bal = bal * 1.005 - 500
        k += 1
    req(k == 22 and 21 < n < 22)
    return f"n ≈ {rnd(n, 1)}, so {k} payments (the last one is smaller)"
P("fp", "A $10 000 loan at 6% per year compounded monthly is repaid with $500 monthly payments. How many payments are needed?",
  ["i = 0.06/12 = 0.005. Payment formula: P = PMT(1 - (1 + i)^(-n))/i", "10000 = 500(1 - 1.005^(-n))/0.005, so 1 - 1.005^(-n) = 0.1", "1.005^(-n) = 0.9, so n = -ln 0.9 / ln 1.005 = 0.10536/0.004988",
   "n ≈ 21.1: 21 full payments leave a small balance, so a 22nd smaller payment finishes it"],
  "n ≈ 21.1, so 22 payments (the last one is smaller)", c_fp_5)


def c_fp_6():
    a = (1 + 0.024 / 12) ** 12 - 1
    b = 0.0245
    req(b > a)
    return f"A: {rnd(a * 100)}%, B: {rnd(b * 100)}%; B is better"
P("fp", "Account A pays 2.4% per year compounded monthly. Account B pays 2.45% per year compounded annually. Compare their effective annual rates.",
  ["Account A: (1 + 0.024/12)^12 - 1 = (1.002)^12 - 1", "(1.002)^12 ≈ 1.02427, so about 2.43%", "Account B is already annual: 2.45%", "2.45% > 2.43%, so B is slightly better"],
  "A: 2.43%, B: 2.45%; B is better", c_fp_6)


def c_fp_7():
    ev = 0.6 * 800 + 0.4 * (-500)
    req(near(ev, 280))
    return "$280"
P("fp", "An investment has a 60% chance of gaining $800 and a 40% chance of losing $500. Find the expected return.",
  ["Expected value = sum of (probability × outcome)", "0.6(800) + 0.4(-500) = 480 - 200", "= $280", "Positive on average, but a 40% chance of losing $500 is the risk to weigh"],
  "$280", c_fp_7)


if __name__ == "__main__":
    main()
