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
    s = s.replace("-", "−")
    # keep the hyphen in compound words such as Point-slope, Back-substitute
    return re.sub(r"(?<=[A-Za-z]{2})−(?=[A-Za-z]{2})", "-", s)


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

PREFIX = "ca12"
STD.update({
    "fn": "BC Calculus 12 content: functions and graphs (parent functions from Pre-calculus 12, piecewise functions, inverse trigonometric functions)",
    "lm1": "BC Calculus 12 content: limits (from a table, graphically and algebraically; one-sided versus two-sided)",
    "lm2": "BC Calculus 12 content: limits to infinity (end behaviour, horizontal and vertical asymptotes)",
    "ct": "BC Calculus 12 content: continuity (including the intermediate value theorem)",
    "rc": "BC Calculus 12 content: differentiation, rate of change (average versus instantaneous, definition of the derivative, notation, secant and tangent slopes)",
    "dr": "BC Calculus 12 content: differentiation rules (power, product, quotient and chain)",
    "tr": "BC Calculus 12 content: differentiation rules for transcendental functions (logarithmic, exponential, trigonometric)",
    "hi": "BC Calculus 12 content: differentiation, higher order and implicit",
    "ga": "BC Calculus 12 content: applications of differentiation (graph of f, f' and f'', increasing and decreasing, concavity, mean value theorem, Newton's method)",
    "rr": "BC Calculus 12 content: applications of differentiation (related rates)",
    "op": "BC Calculus 12 content: applications of differentiation (optimization)",
    "ap": "BC Calculus 12 content: integration, approximations (Riemann sums, rectangle and trapezoidal methods)",
    "ft": "BC Calculus 12 content: integration (antiderivatives, definite and indefinite integrals, fundamental theorem of calculus)",
    "mi": "BC Calculus 12 content: methods of integration (substitution, integration by parts)",
    "ai": "BC Calculus 12 content: applications of integration (area under and between curves, volume of solids, average value)",
    "de": "BC Calculus 12 content: applications of integration (differential equations, initial value problems, slope fields)",
})
INF = float("inf")


def lim(f, a, side=0, h=1e-7):
    if side < 0:
        return f(a - h)
    if side > 0:
        return f(a + h)
    l, r = f(a - h), f(a + h)
    req(near(l, r, 1e-4), f"one-sided values differ: {l} vs {r}")
    return (l + r) / 2


def deriv_ok(f, g, xs):
    for x in xs:
        req(near(D(f, x), g(x), 1e-5), f"derivative mismatch at {x}: {D(f, x)} vs {g(x)}")


def anti_ok(F_, f, xs):
    for x in xs:
        req(near(D(F_, x), f(x), 1e-5), f"antiderivative mismatch at {x}")


# ================= fn =================
def c_fn_1():
    f = lambda x: x * x + 1 if x < 2 else 3 * x - 1
    return f"f(-1) = {f(-1)}, f(2) = {f(2)}, f(4) = {f(4)}"
P("fn", "f(x) = x² + 1 for x < 2, and f(x) = 3x - 1 for x ≥ 2. Find f(-1), f(2) and f(4).",
  ["-1 < 2, so use x² + 1: f(-1) = 1 + 1 = 2", "2 ≥ 2, so use 3x - 1: f(2) = 6 - 1 = 5", "4 ≥ 2: f(4) = 12 - 1 = 11"],
  "f(-1) = 2, f(2) = 5, f(4) = 11", c_fn_1)


def c_fn_2():
    req(near(math.acos(-0.5), 2 * pi / 3) and near(atan(-1), -pi / 4))
    return "arccos(-1/2) = 2π/3, arctan(-1) = -π/4"
P("fn", "Find the exact values of arccos(-1/2) and arctan(-1).",
  ["arccos gives an angle in [0, π] with cosine -1/2: cos(2π/3) = -1/2, so 2π/3", "arctan gives an angle in (-π/2, π/2) with tangent -1: -π/4"],
  "arccos(-1/2) = 2π/3, arctan(-1) = -π/4", c_fn_2)


def c_fn_3():
    f = lambda x: sqrt(4 - x * x) / (x - 1)
    ok = []
    for i in range(-30, 31):
        x = i / 10
        if x == 1: continue
        try:
            f(x); ok.append(x)
        except ValueError:
            pass
    req(min(ok) == -2.0 and max(ok) == 2.0 and 1.0 not in ok)
    return "-2 ≤ x ≤ 2, x ≠ 1"
P("fn", "State the domain of f(x) = √(4 - x²) / (x - 1).",
  ["Square root needs 4 - x² ≥ 0, so x² ≤ 4 and -2 ≤ x ≤ 2", "Denominator x - 1 ≠ 0, so x ≠ 1", "Domain: -2 ≤ x ≤ 2 with x ≠ 1"],
  "-2 ≤ x ≤ 2, x ≠ 1", c_fn_3)


def c_fn_4():
    g = lambda x: x - 2 if x >= 2 else 2 - x
    for x in [-3, 0, 1.5, 2, 5]:
        req(abs(x - 2) == g(x))
    return "|x - 2| = x - 2 for x ≥ 2, and 2 - x for x < 2"
P("fn", "Write f(x) = |x - 2| as a piecewise function.",
  ["|u| = u when u ≥ 0 and -u when u < 0", "x - 2 ≥ 0 exactly when x ≥ 2", "f(x) = x - 2 for x ≥ 2; f(x) = -(x - 2) = 2 - x for x < 2"],
  "|x - 2| = x - 2 for x ≥ 2, and 2 - x for x < 2", c_fn_4)


def c_fn_5():
    v = sin(math.acos(3 / 5))
    req(near(v, 0.8))
    return "4/5"
P("fn", "Find the exact value of sin(arccos(3/5)).",
  ["Let θ = arccos(3/5), so cos θ = 3/5 with θ in [0, π]", "Right triangle: adjacent 3, hypotenuse 5, opposite √(25 - 9) = 4",
   "θ is in quadrant I, so sin θ = 4/5"],
  "4/5", c_fn_5)


# ================= lm1 =================
def c_lm1_1():
    f = lambda x: (x * x - 4) / (x - 2)
    vals = [round(f(x), 2) for x in (1.9, 1.99, 2.01, 2.1)]
    req(vals == [3.9, 3.99, 4.01, 4.1])
    return "4"
P("lm1", "Use x = 1.9, 1.99, 2.01 and 2.1 to estimate the limit as x → 2 of {x² - 4|x - 2}.",
  ["x = 1.9: (3.61 - 4)/(-0.1) = 3.9", "x = 1.99: (3.9601 - 4)/(-0.01) = 3.99", "x = 2.01: (4.0401 - 4)/(0.01) = 4.01", "x = 2.1: (4.41 - 4)/(0.1) = 4.1", "Values approach 4 from both sides, so the limit is 4"],
  "4", c_lm1_1)


def c_lm1_2():
    f = lambda x: (x * x - 9) / (x - 3)
    req(near(lim(f, 3), 6))
    return "6"
P("lm1", "Evaluate the limit as x → 3 of {x² - 9|x - 3}.",
  ["Substituting gives 0/0, so factor", "(x - 3)(x + 3)/(x - 3) = x + 3 for x ≠ 3", "Limit = 3 + 3 = 6"],
  "6", c_lm1_2)


def c_lm1_3():
    f = lambda x: (sqrt(x + 4) - 2) / x
    req(near(lim(f, 0, h=1e-6), 0.25, 1e-4))
    return "1/4"
P("lm1", "Evaluate the limit as x → 0 of {√(x + 4) - 2|x}.",
  ["0/0 again. Multiply top and bottom by the conjugate √(x + 4) + 2", "Top: (x + 4) - 4 = x", "x / [x(√(x + 4) + 2)] = 1/(√(x + 4) + 2)",
   "At x = 0: 1/(2 + 2) = 1/4"],
  "1/4", c_lm1_3)


def c_lm1_4():
    f = lambda x: abs(x - 2) / (x - 2)
    l, r = lim(f, 2, -1), lim(f, 2, 1)
    req(l == -1 and r == 1)
    return "left limit -1, right limit 1, so the limit does not exist"
P("lm1", "Find the limit as x → 2 from the left and from the right of |x - 2| / (x - 2), and say whether the two sided limit exists.",
  ["From the left x < 2, so x - 2 < 0 and |x - 2| = -(x - 2): the quotient is -1", "From the right x > 2, |x - 2| = x - 2: the quotient is 1",
   "The one sided limits differ (-1 and 1), so the two sided limit does not exist"],
  "left limit -1, right limit 1, so the limit does not exist", c_lm1_4)


def c_lm1_5():
    f = lambda x: (x ** 3 + 1) / (x + 1)
    req(near(lim(f, -1), 3))
    return "3"
P("lm1", "Evaluate the limit as x → -1 of {x³ + 1|x + 1}.",
  ["Sum of cubes: x³ + 1 = (x + 1)(x² - x + 1)", "Cancel x + 1: limit of x² - x + 1", "At x = -1: 1 + 1 + 1 = 3"],
  "3", c_lm1_5)


def c_lm1_6():
    f = lambda x: sin(3 * x) / x
    req(near(lim(f, 0, h=1e-6), 3, 1e-5))
    return "3"
P("lm1", "Evaluate the limit as x → 0 of {sin 3x|x}.",
  ["Use lim sin u / u = 1 as u → 0", "Multiply and divide by 3: (sin 3x)/x = 3 · (sin 3x)/(3x)", "As x → 0, 3x → 0, so the limit is 3(1) = 3"],
  "3", c_lm1_6)


# ================= lm2 =================
def c_lm2_1():
    f = lambda x: (3 * x * x - 5 * x + 1) / (2 * x * x + 4)
    req(near(f(1e8), 1.5, 1e-6))
    return "3/2"
P("lm2", "Evaluate the limit as x → ∞ of {3x² - 5x + 1|2x² + 4}.",
  ["Divide every term by the highest power x²: (3 - 5/x + 1/x²)/(2 + 4/x²)", "5/x, 1/x² and 4/x² → 0", "Limit = 3/2"],
  "3/2", c_lm2_1)


def c_lm2_2():
    f = lambda x: (4 * x + 1) / (x * x - 3)
    req(abs(f(1e8)) < 1e-6)
    return "0"
P("lm2", "Evaluate the limit as x → ∞ of {4x + 1|x² - 3}.",
  ["Divide top and bottom by x²: (4/x + 1/x²)/(1 - 3/x²)", "Numerator → 0, denominator → 1", "Limit = 0 (denominator has the higher degree)"],
  "0", c_lm2_2)


def c_lm2_3():
    f = lambda x: (2 * x ** 3 - x) / (x * x + 5)
    req(f(1e3) > 1.9e3 and f(1e6) > 1.9e6)
    return "∞ (grows without bound, no finite limit)"
P("lm2", "Evaluate the limit as x → ∞ of {2x³ - x|x² + 5}.",
  ["Divide by x²: (2x - 1/x)/(1 + 5/x²)", "Numerator → ∞, denominator → 1", "The limit is ∞ (no finite limit): numerator degree is higher"],
  "∞ (grows without bound, no finite limit)", c_lm2_3)


def c_lm2_4():
    f = lambda x: 3 * x / sqrt(x * x + 1)
    req(near(f(1e7), 3, 1e-6) and near(f(-1e7), -3, 1e-6))
    return "y = 3 and y = -3"
P("lm2", "Find the horizontal asymptotes of f(x) = {3x|√(x² + 1)}.",
  ["As x → ∞ (x > 0): divide top and bottom by x. Then √(x² + 1)/x = √(1 + 1/x²), so f(x) = 3/√(1 + 1/x²) → 3/1 = 3", "As x → -∞ (x < 0): x = -√(x²), so dividing the root by x gives -√(1 + 1/x²). Then f(x) = 3/(-√(1 + 1/x²)) → -3",
   "Horizontal asymptotes y = 3 (right) and y = -3 (left)"],
  "y = 3 and y = -3", c_lm2_4)


def c_lm2_5():
    f = lambda x: 2 / (x - 3)
    req(f(3 - 1e-7) < -1e6 and f(3 + 1e-7) > 1e6)
    return "-∞ from the left, +∞ from the right"
P("lm2", "Find the limit as x → 3 from the left and from the right of {2|x - 3}.",
  ["Left: x slightly less than 3, so x - 3 is a tiny negative number and 2/(x - 3) is a huge negative: -∞",
   "Right: x - 3 is a tiny positive number, so the quotient is a huge positive: +∞", "Vertical asymptote at x = 3"],
  "-∞ from the left, +∞ from the right", c_lm2_5)


# ================= ct =================
def c_ct_1():
    k = 7 - 4
    f_left = lambda x: x * x + k
    f_right = lambda x: 5 * x - 3
    req(f_left(2) == f_right(2) == 7)
    return f"k = {k}"
P("ct", "f(x) = x² + k for x < 2 and f(x) = 5x - 3 for x ≥ 2. Find k so that f is continuous at x = 2.",
  ["Left limit at 2: 4 + k. Right side value f(2) = 10 - 3 = 7", "Continuity needs the left limit to equal f(2): 4 + k = 7", "k = 3"],
  "k = 3", c_ct_1)


def c_ct_2():
    f = lambda x: (x * x - 1) / (x - 1)
    req(near(lim(f, 1), 2))
    return "removable discontinuity at x = 1; defining f(1) = 2 fixes it"
P("ct", "Classify the discontinuity of f(x) = {x² - 1|x - 1} at x = 1 and say how to remove it.",
  ["f(1) is undefined (0/0), so f is not continuous at 1", "(x - 1)(x + 1)/(x - 1) = x + 1 for x ≠ 1, so the limit as x → 1 is 2",
   "The limit exists, so it is a removable discontinuity (a hole at (1, 2))", "Define f(1) = 2 to remove it"],
  "removable discontinuity at x = 1; defining f(1) = 2 fixes it", c_ct_2)


def c_ct_3():
    f = lambda x: x ** 3 + x - 3
    req(f(1) == -1 and f(2) == 7)
    root = bisect(f, 1, 2)
    req(1 < root < 2 and abs(f(root)) < 1e-9)
    return "f(1) = -1 < 0 < 7 = f(2) and f is continuous, so f(c) = 0 for some c in (1, 2)"
P("ct", "Show that f(x) = x³ + x - 3 has a root between x = 1 and x = 2.",
  ["f is a polynomial, so it is continuous on [1, 2]", "f(1) = 1 + 1 - 3 = -1 (negative)", "f(2) = 8 + 2 - 3 = 7 (positive)",
   "By the intermediate value theorem, f takes the value 0 somewhere in (1, 2)"],
  "f(1) = -1 < 0 < 7 = f(2) and f is continuous, so f(c) = 0 for some c in (1, 2)", c_ct_3)


def c_ct_4():
    den = polymul([1, -3], [1, 2])
    req(den == [1, -1, -6])
    bad = [x for x in range(-10, 11) if polyval(den, x) == 0]
    req(bad == [-2, 3])
    return "x = -2 and x = 3"
P("ct", "Where is f(x) = {x + 1|x² - x - 6} discontinuous?",
  ["A rational function is discontinuous where the denominator is 0", "x² - x - 6 = (x - 3)(x + 2) = 0", "x = 3 or x = -2",
   "Neither cancels with the numerator x + 1, so both are vertical asymptotes"],
  "x = -2 and x = 3", c_ct_4)


# ================= rc =================
def c_rc_1():
    s = lambda t: 5 * t * t
    v = (s(3) - s(1)) / (3 - 1)
    return f"{fmt(v)} m/s"
P("rc", "A cart's position is s(t) = 5t² metres. Find its average velocity from t = 1 s to t = 3 s.",
  ["s(1) = 5 and s(3) = 45", "Average rate = (s(3) - s(1))/(3 - 1) = 40/2", "= 20 m/s"],
  "20 m/s", c_rc_1)


def c_rc_2():
    f = lambda x: x * x - 3 * x
    g = lambda x: 2 * x - 3
    for x in [-2, 0, 1.5, 4]:
        h = 1e-6
        req(near((f(x + h) - f(x)) / h, g(x), 1e-4))
        # exact difference quotient: (2x + h - 3)
        h = F(1, 1000)
        xq = F(x).limit_denominator(10)
        req((((xq + h) ** 2 - 3 * (xq + h)) - (xq ** 2 - 3 * xq)) / h == 2 * xq + h - 3)
    return "f'(x) = 2x - 3"
P("rc", "Use the limit definition to find f'(x) for f(x) = x² - 3x.",
  ["f'(x) = lim [f(x + h) - f(x)] / h as h → 0", "f(x + h) = x² + 2xh + h² - 3x - 3h", "f(x + h) - f(x) = 2xh + h² - 3h",
   "Divide by h: 2x + h - 3", "As h → 0: f'(x) = 2x - 3"],
  "f'(x) = 2x - 3", c_rc_2)


def c_rc_3():
    f = lambda x: 1 / x
    for x in [0.5, 2, -3]:
        h = F(1, 10 ** 6)
        xq = F(x).limit_denominator(10)
        dq = (1 / (xq + h) - 1 / xq) / h
        req(dq == -1 / (xq * (xq + h)))
        req(near(float(dq), -1 / float(xq) ** 2, 1e-4))
    return "f'(x) = -1/x², slope at x = 2 is -1/4"
P("rc", "Use the limit definition to find f'(x) for f(x) = 1/x, then the slope of the tangent at x = 2.",
  ["[1/(x + h) - 1/x]/h", "Common denominator: [(x - (x + h)) / (x(x + h))]/h", "x - (x + h) = -h, so this is -h / (h x (x + h))", "= -1/(x(x + h))", "As h → 0: f'(x) = -1/x²",
   "At x = 2: -1/4"],
  "f'(x) = -1/x², slope at x = 2 is -1/4", c_rc_3)


def c_rc_4():
    f = lambda x: x * x
    m = D(f, 3)
    req(near(m, 6))
    line = lambda x: 6 * x - 9
    req(line(3) == 9)
    return "y = 6x - 9"
P("rc", "Find the equation of the tangent line to y = x² at the point (3, 9).",
  ["dy/dx = 2x, so the slope at x = 3 is 6", "Point-slope form: y - 9 = 6(x - 3)", "y = 6x - 18 + 9", "y = 6x - 9"],
  "y = 6x - 9", c_rc_4)


def c_rc_5():
    f = lambda x: sqrt(x)
    g = lambda x: 1 / (2 * sqrt(x))
    deriv_ok(f, g, [0.25, 1, 4, 9])
    for x in [1, 4, 9]:
        h = 1e-7
        req(near((f(x + h) - f(x)) / h, 1 / (sqrt(x + h) + sqrt(x)), 1e-6))
    return "f'(x) = 1/(2√x)"
P("rc", "Use the limit definition to show that the derivative of f(x) = √x is 1/(2√x).",
  ["[√(x + h) - √x]/h. Multiply top and bottom by the conjugate √(x + h) + √x", "Top becomes (x + h) - x = h", "h / [h(√(x + h) + √x)] = 1/(√(x + h) + √x)",
   "As h → 0: 1/(2√x)"],
  "f'(x) = 1/(2√x)", c_rc_5)


# ================= dr =================
def c_dr_1():
    f = lambda x: x ** -2 + 4 * sqrt(x)
    g = lambda x: -2 * x ** -3 + 2 * x ** -0.5
    deriv_ok(f, g, [0.5, 1, 2, 5])
    return "dy/dx = -2x⁻³ + 2x^(-1/2)"
P("dr", "Differentiate y = x⁻² + 4√x.",
  ["Write 4√x as 4x^(1/2)", "Power rule: d/dx x^n = n x^(n-1)", "d/dx x⁻² = -2x⁻³", "d/dx 4x^(1/2) = 2x^(-1/2)", "dy/dx = -2x⁻³ + 2x^(-1/2)"],
  "dy/dx = -2x⁻³ + 2x^(-1/2)", c_dr_1)


def c_dr_2():
    f = lambda x: (x * x + 1) * (3 * x - 2)
    g = lambda x: 9 * x * x - 4 * x + 3
    deriv_ok(f, g, [-2, 0, 1, 3])
    return "dy/dx = 9x² - 4x + 3"
P("dr", "Use the product rule to differentiate y = (x² + 1)(3x - 2).",
  ["(uv)' = u'v + uv' with u = x² + 1, v = 3x - 2", "u' = 2x, v' = 3", "dy/dx = 2x(3x - 2) + 3(x² + 1)", "= 6x² - 4x + 3x² + 3", "= 9x² - 4x + 3"],
  "dy/dx = 9x² - 4x + 3", c_dr_2)


def c_dr_3():
    f = lambda x: (x + 1) / (x - 2)
    g = lambda x: -3 / (x - 2) ** 2
    deriv_ok(f, g, [-3, 0, 1, 4, 7])
    return "dy/dx = -3/(x - 2)²"
P("dr", "Use the quotient rule to differentiate y = {x + 1|x - 2}.",
  ["(u/v)' = (u'v - uv')/v² with u = x + 1, v = x - 2", "u' = 1, v' = 1", "dy/dx = [(1)(x - 2) - (x + 1)(1)] / (x - 2)²", "= (x - 2 - x - 1)/(x - 2)²", "= -3/(x - 2)²"],
  "dy/dx = -3/(x - 2)²", c_dr_3)


def c_dr_4():
    f = lambda x: (3 * x * x - 1) ** 5
    g = lambda x: 30 * x * (3 * x * x - 1) ** 4
    deriv_ok(f, g, [-1, 0.4, 1, 1.3])
    return "dy/dx = 30x(3x² - 1)⁴"
P("dr", "Differentiate y = (3x² - 1)⁵.",
  ["Chain rule: outer power 5, inner 3x² - 1", "dy/dx = 5(3x² - 1)⁴ · (6x)", "= 30x(3x² - 1)⁴"],
  "dy/dx = 30x(3x² - 1)⁴", c_dr_4)


def c_dr_5():
    f = lambda x: sqrt(x * x + 9)
    g = lambda x: x / sqrt(x * x + 9)
    deriv_ok(f, g, [-4, -1, 0.5, 3])
    return "dy/dx = x/√(x² + 9)"
P("dr", "Differentiate y = √(x² + 9).",
  ["y = (x² + 9)^(1/2)", "dy/dx = (1/2)(x² + 9)^(-1/2) · 2x", "= x / √(x² + 9)"],
  "dy/dx = x/√(x² + 9)", c_dr_5)


def c_dr_6():
    f = lambda x: x * (2 * x + 1) ** 3
    g = lambda x: (2 * x + 1) ** 2 * (8 * x + 1)
    deriv_ok(f, g, [-2, -0.5, 0, 1, 2.5])
    return "dy/dx = (2x + 1)²(8x + 1)"
P("dr", "Differentiate y = x(2x + 1)³ and factor the result.",
  ["Product rule with u = x, v = (2x + 1)³", "v' = 3(2x + 1)² · 2 = 6(2x + 1)²", "dy/dx = (1)(2x + 1)³ + x · 6(2x + 1)²",
   "Factor out (2x + 1)²: (2x + 1)²[(2x + 1) + 6x]", "= (2x + 1)²(8x + 1)"],
  "dy/dx = (2x + 1)²(8x + 1)", c_dr_6)


# ================= tr =================
def c_tr_1():
    f = lambda x: math.log(3 * x * x + 1)
    g = lambda x: 6 * x / (3 * x * x + 1)
    deriv_ok(f, g, [-2, 0.3, 1, 5])
    return "dy/dx = 6x/(3x² + 1)"
P("tr", "Differentiate y = ln(3x² + 1).",
  ["d/dx ln u = u'/u with u = 3x² + 1", "u' = 6x", "dy/dx = 6x/(3x² + 1)"],
  "dy/dx = 6x/(3x² + 1)", c_tr_1)


def c_tr_2():
    f = lambda x: x * exp(-3 * x)
    g = lambda x: exp(-3 * x) * (1 - 3 * x)
    deriv_ok(f, g, [-1, 0, 0.5, 2])
    return "dy/dx = e^(-3x)(1 - 3x)"
P("tr", "Differentiate y = x e^(-3x).",
  ["Product rule: u = x, v = e^(-3x)", "u' = 1, v' = -3e^(-3x)", "dy/dx = e^(-3x) + x(-3e^(-3x))", "= e^(-3x)(1 - 3x)"],
  "dy/dx = e^(-3x)(1 - 3x)", c_tr_2)


def c_tr_3():
    f = lambda x: sin(x * x)
    g = lambda x: 2 * x * cos(x * x)
    deriv_ok(f, g, [-1.3, 0.2, 1, 2])
    return "dy/dx = 2x cos(x²)"
P("tr", "Differentiate y = sin(x²).",
  ["Chain rule: d/dx sin u = cos u · u'", "u = x², u' = 2x", "dy/dx = 2x cos(x²)"],
  "dy/dx = 2x cos(x²)", c_tr_3)


def c_tr_4():
    f = lambda x: cos(x) ** 3
    g = lambda x: -3 * cos(x) ** 2 * sin(x)
    deriv_ok(f, g, [-2, 0.4, 1, 3])
    return "dy/dx = -3cos²x sin x"
P("tr", "Differentiate y = cos³x.",
  ["Write y = (cos x)³", "Chain rule: 3(cos x)² · d/dx(cos x)", "d/dx cos x = -sin x", "dy/dx = -3cos²x sin x"],
  "dy/dx = -3cos²x sin x", c_tr_4)


def c_tr_5():
    f = lambda x: 5 ** x
    g = lambda x: 5 ** x * math.log(5)
    deriv_ok(f, g, [-1, 0, 1.5, 3])
    return "dy/dx = 5^x ln 5"
P("tr", "Differentiate y = 5^x.",
  ["Write 5^x = e^(x ln 5)", "Chain rule: e^(x ln 5) · ln 5", "dy/dx = 5^x ln 5"],
  "dy/dx = 5^x ln 5", c_tr_5)


def c_tr_6():
    f = lambda x: math.log(x) / x
    g = lambda x: (1 - math.log(x)) / (x * x)
    deriv_ok(f, g, [0.5, 1, 2, 7])
    return "dy/dx = (1 - ln x)/x²"
P("tr", "Differentiate y = {ln x|x}.",
  ["Quotient rule: u = ln x, v = x; u' = 1/x, v' = 1", "dy/dx = [(1/x)(x) - (ln x)(1)]/x²", "= (1 - ln x)/x²"],
  "dy/dx = (1 - ln x)/x²", c_tr_6)


# ================= hi =================
def c_hi_1():
    f = lambda x: x ** 4 - 3 * x ** 3
    f1 = lambda x: 4 * x ** 3 - 9 * x * x
    f2 = lambda x: 12 * x * x - 18 * x
    f3 = lambda x: 24 * x - 18
    deriv_ok(f, f1, [-2, 1, 3]); deriv_ok(f1, f2, [-2, 1, 3]); deriv_ok(f2, f3, [-2, 1, 3])
    return "f''(x) = 12x² - 18x, f'''(x) = 24x - 18"
P("hi", "For f(x) = x⁴ - 3x³ find f''(x) and f'''(x).",
  ["f'(x) = 4x³ - 9x²", "f''(x) = 12x² - 18x", "f'''(x) = 24x - 18"],
  "f''(x) = 12x² - 18x, f'''(x) = 24x - 18", c_hi_1)


def c_hi_2():
    # x^2 + y^2 = 25 ; y = sqrt(25-x^2) near (3,4)
    y = lambda x: sqrt(25 - x * x)
    req(near(D(y, 3), -3 / 4))
    line = lambda x: -3 / 4 * x + 25 / 4
    req(near(line(3), 4))
    return "dy/dx = -x/y; tangent at (3, 4): y = -(3/4)x + 25/4"
P("hi", "For x² + y² = 25, find dy/dx by implicit differentiation, then the tangent line at (3, 4).",
  ["Differentiate both sides: 2x + 2y(dy/dx) = 0", "dy/dx = -x/y", "At (3, 4): slope = -3/4", "y - 4 = -(3/4)(x - 3)", "y = -(3/4)x + 9/4 + 4 = -(3/4)x + 25/4"],
  "dy/dx = -x/y; tangent at (3, 4): y = -(3/4)x + 25/4", c_hi_2)


def c_hi_3():
    # x^2 + xy + y^2 = 7 at (1,2); y' = -(2x+y)/(x+2y)
    req(1 + 2 + 4 == 7)
    # y(x) near x=1 : y^2 + x y + x^2 - 7 = 0 -> y = (-x + sqrt(x^2 - 4(x^2-7)))/2
    y = lambda x: (-x + sqrt(x * x - 4 * (x * x - 7))) / 2
    req(near(y(1), 2) and near(D(y, 1), -4 / 5))
    return "dy/dx = -(2x + y)/(x + 2y); slope at (1, 2) is -4/5"
P("hi", "Find dy/dx for x² + xy + y² = 7, and the slope at (1, 2).",
  ["Differentiate: 2x + (y + x dy/dx) + 2y dy/dx = 0 (product rule on xy)", "Group the dy/dx terms: (x + 2y) dy/dx = -(2x + y)", "dy/dx = -(2x + y)/(x + 2y)",
   "At (1, 2): -(2 + 2)/(1 + 4) = -4/5"],
  "dy/dx = -(2x + y)/(x + 2y); slope at (1, 2) is -4/5", c_hi_3)


def c_hi_4():
    y = lambda x: sqrt(25 - x * x)
    req(near(D2(y, 3), -25 / 64, 1e-4))
    return "d²y/dx² = -25/64 at (3, 4)"
P("hi", "For x² + y² = 25, find d²y/dx² at (3, 4).",
  ["First derivative: y' = -x/y", "Differentiate again with the quotient rule: y'' = -(y - x y')/y²", "Substitute y' = -x/y: y'' = -(y + x²/y)/y²", "Multiply top and bottom by y: y'' = -(y² + x²)/y³",
   "x² + y² = 25, so y'' = -25/y³", "At y = 4: -25/64"],
  "d²y/dx² = -25/64 at (3, 4)", c_hi_4)


# ================= ga: graph analysis, MVT, Newton =================
def c_ga_1():
    f = lambda x: x ** 3 - 6 * x * x + 9 * x
    f1 = lambda x: 3 * x * x - 12 * x + 9
    deriv_ok(f, f1, [-1, 0.5, 2, 4])
    req(int_roots([3, -12, 9]) == [1, 3])
    req(f1(0) > 0 and f1(2) < 0 and f1(4) > 0)
    req(f(1) == 4 and f(3) == 0)
    return "increasing for x < 1 and x > 3, decreasing for 1 < x < 3; local max (1, 4), local min (3, 0)"
P("ga", "For f(x) = x³ - 6x² + 9x, find where f is increasing and decreasing and the local extrema.",
  ["f'(x) = 3x² - 12x + 9 = 3(x - 1)(x - 3)", "Critical numbers x = 1 and x = 3", "Sign of f': x = 0 gives +9 (positive), x = 2 gives 3(1)(-1) = -3 (negative), x = 4 gives 9 (positive)",
   "Increasing for x < 1 and x > 3, decreasing for 1 < x < 3", "f(1) = 1 - 6 + 9 = 4: local max (1, 4). f(3) = 27 - 54 + 27 = 0: local min (3, 0)"],
  "increasing for x < 1 and x > 3, decreasing for 1 < x < 3; local max (1, 4), local min (3, 0)", c_ga_1)


def c_ga_2():
    f = lambda x: x ** 3 - 6 * x * x + 9 * x
    f2 = lambda x: 6 * x - 12
    req(near(D2(f, 1.0), f2(1.0), 1e-3) and near(D2(f, 3.0), f2(3.0), 1e-3))
    req(f(2) == 2 and f2(1) < 0 and f2(3) > 0)
    return "inflection point (2, 2); concave down for x < 2, concave up for x > 2"
P("ga", "For f(x) = x³ - 6x² + 9x, use f''(x) to find the concavity and the inflection point.",
  ["f'(x) = 3x² - 12x + 9", "f''(x) = 6x - 12 = 0 at x = 2", "x < 2: f'' < 0, concave down. x > 2: f'' > 0, concave up", "Concavity changes at x = 2, f(2) = 8 - 24 + 18 = 2",
   "Inflection point (2, 2)"],
  "inflection point (2, 2); concave down for x < 2, concave up for x > 2", c_ga_2)


def c_ga_3():
    f = lambda x: x ** 3
    slope = (f(3) - f(0)) / 3
    c = sqrt(3)
    req(near(3 * c * c, slope) and 0 < c < 3)
    return "c = √3"
P("ga", "Find the value of c guaranteed by the mean value theorem for f(x) = x³ on [0, 3].",
  ["f is continuous and differentiable everywhere, so the theorem applies", "Average slope = (f(3) - f(0))/(3 - 0) = 27/3 = 9", "f'(c) = 3c² = 9, so c² = 3",
   "c = √3 (the positive root, which lies in (0, 3))"],
  "c = √3", c_ga_3)


def c_ga_4():
    f = lambda x: x * x - 7
    fp = lambda x: 2 * x
    x0 = F(3)
    x1 = x0 - f(x0) / fp(x0)
    x2 = x1 - f(x1) / fp(x1)
    req(x1 == F(8, 3) and x2 == F(127, 48))
    req(near(float(x2), sqrt(7), 1e-4))
    return f"x₁ = 8/3, x₂ = 127/48 ≈ {rnd(float(x2), 4)}"
P("ga", "Use Newton's method on f(x) = x² - 7 with x₀ = 3 to find x₁ and x₂.",
  ["xₙ₊₁ = xₙ - f(xₙ)/f'(xₙ) with f'(x) = 2x", "x₁ = 3 - (9 - 7)/6 = 3 - 1/3 = 8/3", "f(8/3) = 64/9 - 7 = 1/9 and f'(8/3) = 16/3",
   "x₂ = 8/3 - (1/9)/(16/3) = 8/3 - 1/48 = 127/48", "127/48 ≈ 2.6458, close to √7 ≈ 2.6458"],
  "x₁ = 8/3, x₂ = 127/48 ≈ 2.6458", c_ga_4)


def c_ga_5():
    f = lambda x: x ** 4 - 8 * x * x
    f1 = lambda x: 4 * x ** 3 - 16 * x
    f2 = lambda x: 12 * x * x - 16
    deriv_ok(f, f1, [-3, -1, 0.5, 2])
    req(int_roots([4, 0, -16, 0]) == [-2, 0, 2])
    req(f2(0) == -16 and f2(2) == 32 and f2(-2) == 32 and f(0) == 0 and f(2) == -16)
    return "local max at (0, 0); local minima at (2, -16) and (-2, -16)"
P("ga", "Find and classify the critical points of f(x) = x⁴ - 8x² using the second derivative test.",
  ["f'(x) = 4x³ - 16x = 4x(x - 2)(x + 2), critical numbers -2, 0, 2", "f''(x) = 12x² - 16", "f''(0) = -16 < 0: local max, f(0) = 0",
   "f''(2) = 32 > 0 and f''(-2) = 32 > 0: local minima", "f(±2) = 16 - 32 = -16"],
  "local max at (0, 0); local minima at (2, -16) and (-2, -16)", c_ga_5)


# ================= rr: related rates =================
def c_rr_1():
    r, drdt = 5, 2
    dAdt = 2 * pi * r * drdt
    A = lambda rr_: pi * rr_ * rr_
    t = lambda tt: r + drdt * tt
    req(near(D(lambda tt: A(t(tt)), 0), dAdt))
    return "dA/dt = 20π cm²/s"
P("rr", "A circular oil slick has radius growing at 2 cm/s. How fast is its area growing when the radius is 5 cm?",
  ["A = πr²", "Differentiate with respect to time: dA/dt = 2πr (dr/dt)", "dA/dt = 2π(5)(2)", "= 20π cm²/s (about 62.8 cm²/s)"],
  "dA/dt = 20π cm²/s", c_rr_1)


def c_rr_2():
    L, x, dx = 13, 5, 0.5
    y = sqrt(L * L - x * x)
    req(y == 12)
    dy = -x * dx / y
    xt = lambda t: x + dx * t
    yt = lambda t: sqrt(L * L - xt(t) ** 2)
    req(near(D(yt, 0), dy))
    return "the top slides down at 5/24 m/s (about 0.21 m/s)"
P("rr", "A 13 m ladder leans on a wall. The base slides away at 0.5 m/s. How fast is the top sliding down when the base is 5 m from the wall?",
  ["x² + y² = 169", "Differentiate in time: 2x(dx/dt) + 2y(dy/dt) = 0", "When x = 5: y = √(169 - 25) = 12",
   "dy/dt = -x(dx/dt)/y = -(5)(0.5)/12 = -5/24", "The top is sliding down at 5/24 m/s (about 0.21 m/s)"],
  "the top slides down at 5/24 m/s (about 0.21 m/s)", c_rr_2)


def c_rr_3():
    dV = 36 * pi
    r = 3
    drdt = dV / (4 * pi * r * r)
    req(near(drdt, 1))
    return "dr/dt = 1 cm/s"
P("rr", "Air is pumped into a spherical balloon at 36π cm³/s. How fast is the radius increasing when r = 3 cm?",
  ["V = (4/3)πr³", "dV/dt = 4πr² (dr/dt)", "36π = 4π(9)(dr/dt) = 36π (dr/dt)", "dr/dt = 1 cm/s"],
  "dr/dt = 1 cm/s", c_rr_3)


# ================= op: optimization =================
def c_op_1():
    A = lambda x: x * (120 - 2 * x)
    best = max(range(0, 61), key=A)
    req(best == 30 and A(30) == 1800 and 120 - 2 * 30 == 60)
    return "30 m by 60 m (60 m along the river), area 1800 m²"
P("op", "A farmer has 120 m of fence for three sides of a rectangular pen; a river is the fourth side. Find the dimensions with the largest area.",
  ["Let the two sides perpendicular to the river be x, the side parallel be y: 2x + y = 120, so y = 120 - 2x", "A = xy = 120x - 2x²", "A' = 120 - 4x = 0 at x = 30",
   "A'' = -4 < 0, so this is a maximum", "y = 120 - 60 = 60. A = 30(60) = 1800 m²"],
  "30 m by 60 m (60 m along the river), area 1800 m²", c_op_1)


def c_op_2():
    S = lambda r: 2 * pi * r * r + 108 * pi / r
    req(S(3) < S(2.9) and S(3) < S(3.1))
    req(near(54 * pi / (pi * 9), 6))
    return "r = 3 cm, h = 6 cm, S = 54π cm²"
P("op", "A closed cylinder must hold 54π cm³. Find the radius and height that minimize the surface area.",
  ["V = πr²h = 54π, so h = 54/r²", "S = 2πr² + 2πrh = 2πr² + 108π/r", "S' = 4πr - 108π/r² = 0, so r³ = 27 and r = 3",
   "S'' = 4π + 216π/r³ > 0: a minimum", "h = 54/9 = 6. S = 18π + 36π = 54π cm²"],
  "r = 3 cm, h = 6 cm, S = 54π cm²", c_op_2)


def c_op_3():
    R = lambda p: p * (100 - 2 * p)
    best = max(range(0, 51), key=R)
    req(best == 25 and R(25) == 1250)
    return "price $25, revenue $1250"
P("op", "A shop sells q = 100 - 2p items per day at price p dollars. Find the price that maximizes revenue and the maximum revenue.",
  ["R = p · q = p(100 - 2p) = 100p - 2p²", "R' = 100 - 4p = 0, so p = 25", "R'' = -4 < 0: a maximum", "R(25) = 25(50) = 1250"],
  "price $25, revenue $1250", c_op_3)


def c_op_4():
    S = lambda x: x + 36 / x
    best = min([i / 10 for i in range(10, 200)], key=S)
    req(near(best, 6) and near(S(6), 12))
    return "6 and 6, minimum sum 12"
P("op", "Two positive numbers have product 36. Find them if their sum is as small as possible.",
  ["y = 36/x, so S = x + 36/x", "S' = 1 - 36/x² = 0, so x² = 36 and x = 6", "S'' = 72/x³ > 0 for x > 0: a minimum", "Both numbers are 6, sum 12"],
  "6 and 6, minimum sum 12", c_op_4)


# ================= ap: approximations =================
def c_ap_1():
    f = lambda x: x * x
    left = sum(f(i) for i in range(0, 4))
    right = sum(f(i) for i in range(1, 5))
    req(left == 14 and right == 30 and left < 64 / 3 < right)
    return "left sum 14, right sum 30"
P("ap", "Approximate the area under y = x² on [0, 4] with 4 equal rectangles using left endpoints, and then right endpoints.",
  ["Width Δx = (4 - 0)/4 = 1; endpoints 0, 1, 2, 3, 4", "Left: 1[f(0) + f(1) + f(2) + f(3)] = 0 + 1 + 4 + 9 = 14", "Right: 1[f(1) + f(2) + f(3) + f(4)] = 1 + 4 + 9 + 16 = 30",
   "The true area 64/3 ≈ 21.3 lies between them"],
  "left sum 14, right sum 30", c_ap_1)


def c_ap_2():
    f = lambda x: x * x
    mid = sum(f(i + 0.5) for i in range(4))
    req(mid == 21.0)
    return "21"
P("ap", "Use the midpoint rectangle method with 4 rectangles to approximate the integral of x² from 0 to 4.",
  ["Δx = 1; midpoints 0.5, 1.5, 2.5, 3.5", "f values: 0.25, 2.25, 6.25, 12.25", "Sum = 21, times Δx = 1 gives 21", "Compare the exact value 64/3 ≈ 21.33"],
  "21", c_ap_2)


def c_ap_3():
    f = lambda x: x * x
    T = F(1, 2) * (f(0) + 2 * (f(1) + f(2) + f(3)) + f(4))
    req(T == 22 and T > F(64, 3))
    return "22"
P("ap", "Use the trapezoidal rule with 4 subintervals to approximate the integral of x² from 0 to 4.",
  ["T = (Δx/2)[f(0) + 2f(1) + 2f(2) + 2f(3) + f(4)] with Δx = 1", "= (1/2)[0 + 2 + 8 + 18 + 16]", "= (1/2)(44) = 22", "Slightly above 64/3 because x² is concave up"],
  "22", c_ap_3)


def c_ap_4():
    ts, vs = [0, 2, 4, 6], [0, 6, 8, 4]
    T = sum((vs[i] + vs[i + 1]) / 2 * (ts[i + 1] - ts[i]) for i in range(3))
    req(T == 32)
    return "32 m"
P("ap", "A runner's speed in m/s at t = 0, 2, 4, 6 s is 0, 6, 8, 4. Use trapezoids to estimate the distance run in 6 s.",
  ["Distance = area under the speed graph", "[0, 2]: (0 + 6)/2 · 2 = 6", "[2, 4]: (6 + 8)/2 · 2 = 14", "[4, 6]: (8 + 4)/2 · 2 = 12", "Total 6 + 14 + 12 = 32 m"],
  "32 m", c_ap_4)


# ================= ft =================
def c_ft_1():
    F_ = lambda x: 2 * x ** 3 - 2 * x * x + 5 * x
    f = lambda x: 6 * x * x - 4 * x + 5
    anti_ok(F_, f, [-2, 0.5, 3])
    return "2x³ - 2x² + 5x + C"
P("ft", "Find ∫ (6x² - 4x + 5) dx.",
  ["Reverse the power rule: ∫ x^n dx = x^(n+1)/(n+1) + C", "6x² → 2x³, -4x → -2x², 5 → 5x", "2x³ - 2x² + 5x + C", "Check by differentiating: 6x² - 4x + 5 ✓"],
  "2x³ - 2x² + 5x + C", c_ft_1)


def c_ft_2():
    F_ = lambda x: -1 / x + 2 * x ** 1.5
    f = lambda x: x ** -2 + 3 * sqrt(x)
    anti_ok(F_, f, [0.5, 1, 4, 9])
    return "-1/x + 2x^(3/2) + C"
P("ft", "Find ∫ (x⁻² + 3√x) dx.",
  ["Write 3√x = 3x^(1/2)", "∫ x⁻² dx = x⁻¹/(-1) = -1/x", "∫ 3x^(1/2) dx = 3 · x^(3/2)/(3/2) = 2x^(3/2)", "-1/x + 2x^(3/2) + C"],
  "-1/x + 2x^(3/2) + C", c_ft_2)


def c_ft_3():
    v = (3 ** 2 + 3) - (1 + 1)
    req(near(simpson(lambda x: 2 * x + 1, 1, 3), v))
    return f"{v}"
P("ft", "Evaluate ∫ from 1 to 3 of (2x + 1) dx.",
  ["Antiderivative F(x) = x² + x", "FTC: F(3) - F(1)", "= (9 + 3) - (1 + 1) = 12 - 2", "= 10"],
  "10", c_ft_3)


def c_ft_4():
    G = lambda x: simpson(lambda t: exp(t), 1, x * x, 4000)
    for x in [1.2, 1.5, 2.0]:
        req(near(D(G, x, 1e-4), 2 * x * exp(x * x), 1e-4))
    return "G'(x) = 2x e^(x²)"
P("ft", "If G(x) = ∫ from 1 to x² of e^t dt, find G'(x).",
  ["FTC part 1 with an upper limit that is a function: d/dx ∫ from a to u(x) of f(t) dt = f(u(x)) · u'(x)", "f(t) = e^t, u = x², u' = 2x", "G'(x) = e^(x²) · 2x = 2x e^(x²)"],
  "G'(x) = 2x e^(x²)", c_ft_4)


def c_ft_5():
    v = simpson(sin, 0, pi)
    req(near(v, 2, 1e-8))
    return "2"
P("ft", "Evaluate ∫ from 0 to π of sin x dx.",
  ["Antiderivative of sin x is -cos x", "[-cos x] from 0 to π = -cos π - (-cos 0)", "= -(-1) + 1 = 2"],
  "2", c_ft_5)


# ================= mi =================
def c_mi_1():
    F_ = lambda x: (x * x + 1) ** 4 / 4
    f = lambda x: 2 * x * (x * x + 1) ** 3
    anti_ok(F_, f, [-1.5, 0, 0.7, 2])
    return "(x² + 1)⁴/4 + C"
P("mi", "Use substitution to find ∫ 2x(x² + 1)³ dx.",
  ["Let u = x² + 1, so du = 2x dx", "∫ u³ du = u⁴/4 + C", "Back-substitute: (x² + 1)⁴/4 + C"],
  "(x² + 1)⁴/4 + C", c_mi_1)


def c_mi_2():
    F_ = lambda x: 0.5 * math.log(x * x + 4)
    f = lambda x: x / (x * x + 4)
    anti_ok(F_, f, [-3, 0, 1.2, 5])
    return "(1/2) ln(x² + 4) + C"
P("mi", "Find ∫ {x|x² + 4} dx.",
  ["Let u = x² + 4, so du = 2x dx and x dx = du/2", "∫ (1/u)(du/2) = (1/2) ln|u| + C", "x² + 4 > 0, so (1/2) ln(x² + 4) + C"],
  "(1/2) ln(x² + 4) + C", c_mi_2)


def c_mi_3():
    v = (e - 1) / 2
    req(near(simpson(lambda x: x * exp(x * x), 0, 1), v, 1e-9))
    return "(e - 1)/2"
P("mi", "Evaluate ∫ from 0 to 1 of x e^(x²) dx.",
  ["Let u = x², du = 2x dx, so x dx = du/2", "Change limits: x = 0 gives u = 0; x = 1 gives u = 1", "(1/2) ∫ from 0 to 1 of e^u du = (1/2)[e^u] from 0 to 1", "= (1/2)(e - 1)"],
  "(e - 1)/2", c_mi_3)


def c_mi_4():
    F_ = lambda x: x * exp(x) - exp(x)
    f = lambda x: x * exp(x)
    anti_ok(F_, f, [-2, 0, 1, 2.5])
    return "x e^x - e^x + C"
P("mi", "Use integration by parts to find ∫ x e^x dx.",
  ["∫ u dv = uv - ∫ v du", "Choose u = x (gets simpler), dv = e^x dx. Then du = dx, v = e^x", "= x e^x - ∫ e^x dx", "= x e^x - e^x + C"],
  "x e^x - e^x + C", c_mi_4)


def c_mi_5():
    F_ = lambda x: x * sin(x) + cos(x)
    f = lambda x: x * cos(x)
    anti_ok(F_, f, [-2, 0, 1, 2.5])
    return "x sin x + cos x + C"
P("mi", "Use integration by parts to find ∫ x cos x dx.",
  ["u = x, dv = cos x dx, so du = dx, v = sin x", "∫ x cos x dx = x sin x - ∫ sin x dx", "= x sin x - (-cos x) + C", "= x sin x + cos x + C"],
  "x sin x + cos x + C", c_mi_5)


def c_mi_6():
    v = (e * e + 1) / 4
    req(near(simpson(lambda x: x * math.log(x), 1, e, 4000), v, 1e-8))
    return "(e² + 1)/4"
P("mi", "Evaluate ∫ from 1 to e of x ln x dx.",
  ["Parts: u = ln x, dv = x dx, so du = dx/x, v = x²/2", "= [(x²/2) ln x] from 1 to e - ∫ from 1 to e of (x/2) dx", "First part: (e²/2)(1) - (1/2)(0) = e²/2",
   "Second part: [x²/4] from 1 to e = (e² - 1)/4", "e²/2 - (e² - 1)/4 = (2e² - e² + 1)/4 = (e² + 1)/4"],
  "(e² + 1)/4", c_mi_6)


# ================= ai =================
def c_ai_1():
    v = F(4, 3)
    req(near(simpson(lambda x: 2 * x - x * x, 0, 2), float(v), 1e-9))
    return "4/3"
P("ai", "Find the area enclosed by y = x² and y = 2x.",
  ["Intersections: x² = 2x gives x = 0 and x = 2", "On (0, 2), 2x is above x²", "Area = ∫ from 0 to 2 of (2x - x²) dx = [x² - x³/3] from 0 to 2", "= 4 - 8/3 = 4/3"],
  "4/3", c_ai_1)


def c_ai_2():
    req(near(simpson(sqrt, 0, 9, 20000), 18, 1e-5))
    return "18"
P("ai", "Find the area under y = √x from x = 0 to x = 9.",
  ["Area = ∫ from 0 to 9 of x^(1/2) dx", "= [(2/3)x^(3/2)] from 0 to 9", "= (2/3)(27) - 0 = 18"],
  "18", c_ai_2)


def c_ai_3():
    v = pi * simpson(lambda x: sqrt(x) ** 2, 0, 4)
    req(near(v, 8 * pi))
    return "8π"
P("ai", "The region under y = √x from x = 0 to x = 4 is rotated about the x axis. Find the volume.",
  ["Disc method: V = π ∫ [f(x)]² dx", "[√x]² = x", "V = π ∫ from 0 to 4 of x dx = π[x²/2] from 0 to 4", "= π(8) = 8π"],
  "8π", c_ai_3)


def c_ai_4():
    v = pi * simpson(lambda x: x * x - x ** 4, 0, 1)
    req(near(v, 2 * pi / 15, 1e-9))
    return "2π/15"
P("ai", "The region between y = x and y = x² is rotated about the x axis. Find the volume.",
  ["Intersections: x = 0 and x = 1; y = x is the outer curve", "Washer method: V = π ∫ (R² - r²) dx = π ∫ from 0 to 1 of (x² - x⁴) dx", "= π[x³/3 - x⁵/5] from 0 to 1",
   "= π(1/3 - 1/5) = 2π/15"],
  "2π/15", c_ai_4)


def c_ai_5():
    avg = simpson(lambda x: x * x, 0, 3) / 3
    req(near(avg, 3))
    return "3"
P("ai", "Find the average value of f(x) = x² on [0, 3].",
  ["Average value = (1/(b - a)) ∫ f(x) dx", "= (1/3) ∫ from 0 to 3 of x² dx = (1/3)[x³/3] from 0 to 3", "= (1/3)(9) = 3"],
  "3", c_ai_5)


# ================= de =================
def c_de_1():
    y = lambda x: 3 * exp(x * x)
    for x in [-1, 0, 0.7, 1.5]:
        req(near(D(y, x), 2 * x * y(x), 1e-5))
    req(y(0) == 3)
    return "y = 3e^(x²)"
P("de", "Solve dy/dx = 2xy with y(0) = 3.",
  ["Separate variables: dy/y = 2x dx", "Integrate: ln|y| = x² + C", "y = Ae^(x²) where A = e^C", "y(0) = 3 gives A = 3", "y = 3e^(x²)"],
  "y = 3e^(x²)", c_de_1)


def c_de_2():
    y = lambda x: 2 * x ** 3 - 2 * x + 4
    deriv_ok(y, lambda x: 6 * x * x - 2, [-2, 0, 1, 3])
    req(y(1) == 4)
    return "y = 2x³ - 2x + 4"
P("de", "Solve the initial value problem dy/dx = 6x² - 2, y(1) = 4.",
  ["Integrate: y = 2x³ - 2x + C", "Use y(1) = 4: 2 - 2 + C = 4, so C = 4", "y = 2x³ - 2x + 4"],
  "y = 2x³ - 2x + 4", c_de_2)


def c_de_3():
    s = lambda x, y: x - y
    return f"{s(2, 1)}, {s(0, 3)}, {s(1, 1)}"
P("de", "A slope field is drawn for dy/dx = x - y. Find the slope at (2, 1), (0, 3) and (1, 1).",
  ["Substitute each point into x - y", "(2, 1): 2 - 1 = 1", "(0, 3): 0 - 3 = -3", "(1, 1): 1 - 1 = 0, a flat mark (the line y = x has all slopes 0)"],
  "1, -3, 0", c_de_3)


def c_de_4():
    P_ = lambda t: 200 * exp(0.05 * t)
    for t in [0, 3, 10]:
        req(near(D(P_, t), 0.05 * P_(t), 1e-5))
    return f"P = 200e^(0.05t); P(10) ≈ {rnd(P_(10), 1)}"
P("de", "A population satisfies dP/dt = 0.05P with P(0) = 200. Solve for P(t) and find P(10) to 1 decimal place.",
  ["dP/P = 0.05 dt, so ln P = 0.05t + C", "P = Ae^(0.05t) and P(0) = 200 gives A = 200", "P(t) = 200e^(0.05t)", "P(10) = 200e^(0.5) = 200(1.6487) ≈ 329.7"],
  "P = 200e^(0.05t); P(10) ≈ 329.7", c_de_4)


if __name__ == "__main__":
    main()
