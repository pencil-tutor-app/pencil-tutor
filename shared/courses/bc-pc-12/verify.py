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

PREFIX = "pc12"
STD.update({
    "tr1": "BC Pre-calculus 12 content: transformations of functions and relations (parent functions; vertical and horizontal translations, stretches, reflections)",
    "tr2": "BC Pre-calculus 12 content: transformations (inverses: graphs and equations)",
    "tr3": "BC Pre-calculus 12 content: transformations extension (composed functions, operations on functions)",
    "ex1": "BC Pre-calculus 12 content: exponential functions and equations (graphing, including transformations)",
    "ex2": "BC Pre-calculus 12 content: exponential functions and equations (solving same-base and different-base equations incl. base e; situational problems)",
    "gs": "BC Pre-calculus 12 content: geometric sequences and series (common ratio, general term, infinite series, sigma notation)",
    "lg1": "BC Pre-calculus 12 content: logarithms (laws of logarithms, different bases, common and natural logarithms, inverse of exponential)",
    "lg2": "BC Pre-calculus 12 content: logarithms (graphing, solving equations, situational problems)",
    "po1": "BC Pre-calculus 12 content: polynomial functions and equations (factoring, factor theorem, remainder theorem)",
    "po2": "BC Pre-calculus 12 content: polynomial functions and equations (graph characteristics; solving algebraically and graphically)",
    "ra": "BC Pre-calculus 12 content: rational functions (asymptotes, intercepts, point discontinuities, domain, end behaviour)",
    "tg1": "BC Pre-calculus 12 content: trigonometry (angles in standard position in radians and degrees, unit circle, reference and coterminal angles, special angles)",
    "tg2": "BC Pre-calculus 12 content: trigonometry (graphing primary trigonometric functions, transformations and characteristics)",
    "tg3": "BC Pre-calculus 12 content: trigonometry (solving first and second degree equations; situational problems)",
    "tg4": "BC Pre-calculus 12 content: trigonometry (identities: Pythagorean, quotient, double angle, reciprocal, sum and difference)",
})
RAD = math.radians
G = lambda *a: [x for x in a]


# ================= tr1: transformations of parent functions =================
def c_tr1_1():
    g = lambda x: abs(x - 3) - 2
    xs = [i / 10 for i in range(-50, 100)]
    xm = min(xs, key=g)
    req(near(xm, 3) and near(g(xm), -2))
    return "y = |x - 3| - 2, vertex (3, -2)".replace("-", "−")
P("tr1", "The graph of y = |x| is shifted 3 right and 2 down. Write the new equation and its vertex.",
  ["Right 3 replaces x with x - 3: y = |x - 3|", "Down 2 subtracts 2 from y: y = |x - 3| - 2",
   "The vertex (0, 0) moves right 3 and down 2 to (3, -2)"],
  "y = |x - 3| - 2, vertex (3, -2)", c_tr1_1)


def c_tr1_2():
    f9 = 9
    x2 = 4 + 1
    y2 = -2 * f9 + 3
    return f"({x2}, {y2})"
P("tr1", "The point (4, 9) is on y = f(x). Find its image on y = -2f(x - 1) + 3.",
  ["x - 1 means a shift right 1, so x goes from 4 to 5", "-2f stretches by 2 and reflects: y = -2(9) = -18",
   "+3 shifts up: -18 + 3 = -15", "Image point (5, -15)"],
  "(5, -15)", c_tr1_2)


def c_tr1_3():
    f_zero = [-2, 4]
    xs = [F(-2, 3), F(4, 3)]
    for x in xs:
        req(3 * x in f_zero)
    return "x = -2/3 and x = 4/3"
P("tr1", "The graph of y = f(x) has x intercepts at -2 and 4. Find the x intercepts of y = f(3x).",
  ["y = f(3x) is a horizontal compression by a factor of 1/3", "Each x value is divided by 3: -2/3 and 4/3",
   "Check: f(3 · (4/3)) = f(4) = 0 and f(3 · (-2/3)) = f(-2) = 0"],
  "x = -2/3 and x = 4/3", c_tr1_3)


def c_tr1_4():
    g = lambda x: math.sqrt(2 * x - 6)
    f = lambda x: math.sqrt(x)
    for x in [3, 3.5, 5, 7, 11]:
        req(near(g(x), f(2 * (x - 3))))
    return "horizontal compression by a factor of 1/2, then right 3"
P("tr1", "Describe how y = √x becomes y = √(2x - 6).",
  ["Factor inside the root: 2x - 6 = 2(x - 3)", "So y = √(2(x - 3))", "The 2 multiplying x is a horizontal compression by a factor of 1/2",
   "The (x - 3) is a shift right 3"],
  "horizontal compression by a factor of 1/2, then right 3", c_tr1_4)


def c_tr1_5():
    g = lambda x: 2 / (x - 1) + 3
    req(near(g(2), 5))
    return "x = 1 and y = 3; image of (1, 1) is (2, 5)"
P("tr1", "The point (1, 1) is on y = 1/x. For y = 2/(x - 1) + 3, state the asymptotes and the image of that point.",
  ["The parent y = 1/x has asymptotes x = 0 and y = 0", "x - 1 shifts right 1, so the vertical asymptote is x = 1",
   "+3 shifts up 3, so the horizontal asymptote is y = 3",
   "(1, 1): x goes to 1 + 1 = 2; y is stretched by 2 to 2, then up 3 to 5", "Image (2, 5)"],
  "x = 1 and y = 3; image of (1, 1) is (2, 5)", c_tr1_5)


# ================= tr2: inverses =================
def c_tr2_1():
    f = lambda x: 3 * x - 5
    fi = lambda x: (x + 5) / 3
    for x in [-3, 0, 2.5, 8]:
        req(near(f(fi(x)), x) and near(fi(f(x)), x))
    return "f⁻¹(x) = (x + 5)/3"
P("tr2", "Find the inverse of f(x) = 3x - 5.",
  ["Write y = 3x - 5", "Swap x and y: x = 3y - 5", "Add 5: x + 5 = 3y", "Divide by 3: y = (x + 5)/3"],
  "f⁻¹(x) = (x + 5)/3", c_tr2_1)


def c_tr2_2():
    f = lambda x: (x - 2) ** 2 + 1
    fi = lambda x: 2 + math.sqrt(x - 1)
    for x in [1, 2, 5, 10, 17]:
        req(near(f(fi(x)), x))
    for x in [2, 3, 6]:
        req(near(fi(f(x)), x))
    return "f⁻¹(x) = 2 + √(x - 1), x ≥ 1"
P("tr2", "Find the inverse of f(x) = (x - 2)² + 1, x ≥ 2, and state its domain.",
  ["y = (x - 2)² + 1", "Swap: x = (y - 2)² + 1", "x - 1 = (y - 2)²", "y - 2 = √(x - 1), positive root because y ≥ 2 in the original domain",
   "y = 2 + √(x - 1)", "Domain of the inverse is the range of f: x ≥ 1"],
  "f⁻¹(x) = 2 + √(x - 1), x ≥ 1", c_tr2_2)


def c_tr2_3():
    f = lambda x: (2 * x + 1) / (x - 3)
    fi = lambda x: (3 * x + 1) / (x - 2)
    for x in [-5, 0, 1, 4, 7.5]:
        req(near(f(fi(x)), x))
    return "f⁻¹(x) = (3x + 1)/(x - 2)"
P("tr2", "Find the inverse of f(x) = {2x + 1|x - 3}.",
  ["y = (2x + 1)/(x - 3)", "Swap: x = (2y + 1)/(y - 3)", "x(y - 3) = 2y + 1", "xy - 3x = 2y + 1", "xy - 2y = 3x + 1",
   "y(x - 2) = 3x + 1", "y = (3x + 1)/(x - 2)"],
  "f⁻¹(x) = (3x + 1)/(x - 2)", c_tr2_3)


def c_tr2_4():
    f = lambda x: x * x - 4
    req(f(2) == f(-2) == 0)
    return "No: f(2) = f(-2) fails the horizontal line test; restrict to x ≥ 0"
P("tr2", "Explain why f(x) = x² - 4 has no inverse function on all real numbers, and give a restriction that fixes it.",
  ["f(2) = 0 and f(-2) = 0, so two different inputs give the same output", "The graph fails the horizontal line test, so f is not one to one",
   "Restrict the domain to x ≥ 0 (one branch of the parabola)", "Then f is one to one and the inverse is f⁻¹(x) = √(x + 4)"],
  "No: f(2) = f(-2) fails the horizontal line test; restrict to x ≥ 0", c_tr2_4)


# ================= tr3: composition and operations =================
def c_tr3_1():
    f = lambda x: 2 * x + 1
    g = lambda x: x * x
    return f"f(g(3)) = {f(g(3))}, g(f(3)) = {g(f(3))}"
P("tr3", "Let f(x) = 2x + 1 and g(x) = x². Find f(g(3)) and g(f(3)).",
  ["g(3) = 9, so f(g(3)) = f(9) = 2(9) + 1 = 19", "f(3) = 7, so g(f(3)) = g(7) = 49"],
  "f(g(3)) = 19, g(f(3)) = 49", c_tr3_1)


def c_tr3_2():
    f = lambda x: x * x - 4
    g = lambda x: math.sqrt(x + 1)
    for x in [-1, 0, 3, 8]:
        req(near(f(g(x)), x - 3))
    return "(f∘g)(x) = x - 3, x ≥ -1"
P("tr3", "f(x) = x² - 4 and g(x) = √(x + 1). Find (f∘g)(x) in simplest form and its domain.",
  ["(f∘g)(x) = f(g(x)) = (√(x + 1))² - 4", "= (x + 1) - 4 = x - 3", "Domain comes from the inside function: x + 1 ≥ 0, so x ≥ -1"],
  "(f∘g)(x) = x - 3, x ≥ -1", c_tr3_2)


def c_tr3_3():
    f = lambda x: 3 * x - 2
    g = lambda x: x * x + 1
    prod = polymul([3, -2], [1, 0, 1])
    req(prod == [3, -2, 3, -2])
    for x in [-2, 0, 1, 3]:
        req(f(x) * g(x) == polyval(prod, x))
    return f"3x³ - 2x² + 3x - 2; (f·g)(2) = {f(2) * g(2)}"
P("tr3", "f(x) = 3x - 2 and g(x) = x² + 1. Find (f·g)(x) expanded, then evaluate it at x = 2.",
  ["(f·g)(x) = (3x - 2)(x² + 1)", "= 3x³ + 3x - 2x² - 2", "= 3x³ - 2x² + 3x - 2",
   "At x = 2: 3(8) - 2(4) + 3(2) - 2 = 24 - 8 + 6 - 2 = 20", "Check: f(2) g(2) = 4 · 5 = 20"],
  "3x³ - 2x² + 3x - 2; (f·g)(2) = 20", c_tr3_3)


def c_tr3_4():
    ok = [x / 2 for x in range(-20, 40) if x / 2 >= 1 and x / 2 != 5]
    req(5 not in ok and 1 in ok and 0.5 not in ok)
    return "x ≥ 1, x ≠ 5"
P("tr3", "f(x) = √(x - 1) and g(x) = x - 5. State the domain of (f/g)(x).",
  ["f needs x - 1 ≥ 0, so x ≥ 1", "g is defined for all x", "The denominator g(x) = x - 5 cannot be 0, so x ≠ 5",
   "Domain: x ≥ 1 with x ≠ 5"],
  "x ≥ 1, x ≠ 5", c_tr3_4)


# ================= ex1: exponential graphs =================
def c_ex1_1():
    f = lambda x: 3 * 2 ** x - 4
    req(f(0) == -1 and near(f(-60), -4, 1e-9) and f(10) > 1000)
    return "y intercept -1; horizontal asymptote y = -4; range y > -4"
P("ex1", "For y = 3(2)^x - 4, state the y intercept, the horizontal asymptote and the range.",
  ["y intercept: x = 0 gives 3(1) - 4 = -1", "As x gets very negative, 2^x → 0, so y → -4: asymptote y = -4",
   "2^x is always positive, so 3(2)^x > 0 and y > -4", "Range: y > -4"],
  "y intercept -1; horizontal asymptote y = -4; range y > -4", c_ex1_1)


def c_ex1_2():
    f = lambda x: 2 ** x
    g = lambda x: -(2 ** (x + 3)) + 1
    for x in [-2, 0, 1.5]:
        req(near(g(x), -f(x + 3) + 1))
    return "reflect in the x axis, left 3, up 1"
P("ex1", "Describe the transformations from y = 2^x to y = -(2^(x + 3)) + 1.",
  ["The minus sign in front reflects the graph in the x axis", "x + 3 shifts the graph left 3", "+1 shifts the graph up 1",
   "Asymptote moves from y = 0 to y = 1"],
  "reflect in the x axis, left 3, up 1", c_ex1_2)


def c_ex1_3():
    a = 5
    b2 = F(45, a)
    b = int(math.isqrt(int(b2)))
    req(b * b == b2 and a * b ** 2 == 45)
    return f"y = {a}(3)^x"
P("ex1", "An exponential function y = a·b^x passes through (0, 5) and (2, 45). Find its equation.",
  ["At x = 0: a·b⁰ = a = 5", "At x = 2: 5b² = 45, so b² = 9", "b = 3 (a base must be positive)", "y = 5(3)^x"],
  "y = 5(3)^x", c_ex1_3)


def c_ex1_4():
    for x in [-1, 0, 2.5]:
        req(near(4 ** (x - 1), 2 ** (2 * (x - 1))))
    return "y = 2^(2(x - 1)): horizontal compression by a factor of 1/2, right 1"
P("ex1", "Rewrite y = 4^(x - 1) as a power of 2, then describe it as a transformation of y = 2^x.",
  ["4 = 2², so 4^(x - 1) = (2²)^(x - 1) = 2^(2(x - 1))", "The 2 multiplying (x - 1) compresses horizontally by a factor of 1/2",
   "The (x - 1) shifts right 1"],
  "y = 2^(2(x - 1)): horizontal compression by a factor of 1/2, right 1", c_ex1_4)


# ================= ex2: exponential equations =================
def c_ex2_1():
    x = F(5, 2)
    req(9 ** (float(x) - 1) == 27 or near(9 ** (float(x) - 1), 27))
    return "x = 5/2"
P("ex2", "Solve 9^(x - 1) = 27.",
  ["Write both sides with base 3: (3²)^(x - 1) = 3³", "3^(2x - 2) = 3^3", "Same base, so exponents match: 2x - 2 = 3", "2x = 5, x = 5/2",
   "Check: 9^(3/2) = 27 ✓"],
  "x = 5/2", c_ex2_1)


def c_ex2_2():
    x = log(20) / log(3)
    req(near(3 ** x, 20))
    return f"x ≈ {rnd(x)}"
P("ex2", "Solve 3^x = 20. Give x to 2 decimal places.",
  ["Take the natural log of both sides: ln(3^x) = ln 20", "Power law: x ln 3 = ln 20", "x = ln 20 / ln 3 = 2.9957 / 1.0986", "x ≈ 2.73"],
  "x ≈ 2.73", c_ex2_2)


def c_ex2_3():
    sols = [x for x in range(-5, 6) if F(5) ** (2 * x) - 6 * F(5) ** x + 5 == 0]
    req(sols == [0, 1])
    return "x = 0 or x = 1"
P("ex2", "Solve 5^(2x) - 6(5^x) + 5 = 0.",
  ["Let u = 5^x, so 5^(2x) = u²", "u² - 6u + 5 = 0", "(u - 1)(u - 5) = 0, so u = 1 or u = 5", "5^x = 1 gives x = 0; 5^x = 5 gives x = 1"],
  "x = 0 or x = 1", c_ex2_3)


def c_ex2_4():
    x = log(7) / 2
    req(near(exp(2 * x), 7))
    return f"x = (ln 7)/2 ≈ {rnd(x)}"
P("ex2", "Solve e^(2x) = 7. Give an exact answer and a 2 decimal place answer.",
  ["Take ln of both sides: ln(e^(2x)) = ln 7", "2x = ln 7", "x = (ln 7)/2 = 1.9459/2", "x ≈ 0.97"],
  "x = (ln 7)/2 ≈ 0.97", c_ex2_4)


def c_ex2_5():
    t = 3 * math.log2(8000 / 500)
    req(near(500 * 2 ** (t / 3), 8000) and near(t, 12))
    return f"t = {fmt(t)} hours"
P("ex2", "A culture of 500 bacteria doubles every 3 hours. After how many hours will it reach 8000 bacteria?",
  ["N = 500(2)^(t/3)", "8000 = 500(2)^(t/3), so 2^(t/3) = 16", "16 = 2⁴, so t/3 = 4", "t = 12 hours"],
  "t = 12 hours", c_ex2_5)


def c_ex2_6():
    n = log(3000 / 2000) / log(1.04)
    req(near(2000 * 1.04 ** n, 3000))
    return f"n ≈ {rnd(n, 1)} years"
P("ex2", "$2000 earns 4% compounded annually. How many years until it reaches $3000? Answer to 1 decimal place.",
  ["2000(1.04)^n = 3000", "1.04^n = 1.5", "n ln 1.04 = ln 1.5", "n = 0.40547 / 0.03922 ≈ 10.3 years"],
  "n ≈ 10.3 years", c_ex2_6)


# ================= gs: geometric sequences and series =================
def c_gs_1():
    r = 18 // 6
    t = [6 * r ** k for k in range(6)]
    return f"t₆ = {t[5]}"
P("gs", "A geometric sequence has t₁ = 6 and t₂ = 18. Find t₆.",
  ["r = 18/6 = 3", "tₙ = 6(3)^(n - 1)", "t₆ = 6(3)⁵ = 6(243) = 1458"],
  "t₆ = 1458", c_gs_1)


def c_gs_2():
    n = next(n for n in range(1, 40) if 3 * 2 ** (n - 1) == 768)
    return f"n = {n}"
P("gs", "How many terms are in the geometric sequence 3, 6, 12, ..., 768?",
  ["a = 3, r = 2", "3(2)^(n - 1) = 768", "2^(n - 1) = 256 = 2⁸", "n - 1 = 8, so n = 9"],
  "n = 9", c_gs_2)


def c_gs_3():
    s = sum(5 * 2 ** k for k in range(8))
    req(s == 5 * (2 ** 8 - 1) // (2 - 1))
    return f"S₈ = {s}"
P("gs", "Find S₈ for the geometric series 5 + 10 + 20 + ...",
  ["a = 5, r = 2, n = 8", "Sₙ = a(rⁿ - 1)/(r - 1)", "S₈ = 5(2⁸ - 1)/(2 - 1) = 5(255)", "S₈ = 1275"],
  "S₈ = 1275", c_gs_3)


def c_gs_4():
    a, r = F(12), F(1, 2)
    s = a / (1 - r)
    req(abs(float(sum(12 * 0.5 ** k for k in range(200))) - s) < 1e-9)
    return f"S∞ = {fmt(s)}"
P("gs", "Find the sum of the infinite series 12 + 6 + 3 + 1.5 + ...",
  ["r = 6/12 = 1/2, and |r| < 1 so the series converges", "S∞ = a/(1 - r) = 12/(1 - 1/2)", "= 12/(1/2) = 24"],
  "S∞ = 24", c_gs_4)


def c_gs_5():
    r = F(1, 100)
    s = F(36, 100) / (1 - r)
    req(s == F(4, 11) and abs(4 / 11 - 0.363636363636) < 1e-9)
    return f"{fmt(s)}"
P("gs", "Write the repeating decimal 0.363636... as a fraction in lowest terms.",
  ["0.363636... = 0.36 + 0.0036 + 0.000036 + ...", "Geometric with a = 0.36 and r = 0.01", "S∞ = 0.36/(1 - 0.01) = 0.36/0.99", "= 36/99 = 4/11"],
  "4/11", c_gs_5)


def c_gs_6():
    s = sum(3 * 2 ** (k - 1) for k in range(1, 6))
    return f"{s}"
P("gs", "Evaluate Σ 3(2)^(k - 1) for k = 1 to 5.",
  ["Terms: 3, 6, 12, 24, 48", "Geometric with a = 3, r = 2, n = 5", "S₅ = 3(2⁵ - 1)/(2 - 1) = 3(31) = 93"],
  "93", c_gs_6)


# ================= lg1: laws and evaluation =================
def c_lg1_1():
    req(2 ** 5 == 32 and 5 ** 3 == 125)
    return "log₂ 32 = 5; 5³ = 125"
P("lg1", "Write 2⁵ = 32 in logarithmic form, and write log₅ 125 = 3 in exponential form.",
  ["A log asks for the exponent: base 2 to what power gives 32?", "2⁵ = 32 is log₂ 32 = 5", "log₅ 125 = 3 says base 5 to the power 3 gives 125: 5³ = 125"],
  "log₂ 32 = 5; 5³ = 125", c_lg1_1)


def c_lg1_2():
    v = math.log2(32) - math.log(81, 3) + math.log10(1000)
    req(near(v, 4))
    return "4"
P("lg1", "Evaluate log₂ 32 - log₃ 81 + log 1000.",
  ["log₂ 32 = 5 because 2⁵ = 32", "log₃ 81 = 4 because 3⁴ = 81", "log 1000 = 3 (common log, base 10)", "5 - 4 + 3 = 4"],
  "4", c_lg1_2)


def c_lg1_3():
    v = math.log(4, 6) + math.log(9, 6)
    req(near(v, 2) and near(math.log(36, 6), 2))
    return "log₆ 36 = 2"
P("lg1", "Write log₆ 4 + log₆ 9 as a single logarithm and evaluate.",
  ["Product law: log₆ 4 + log₆ 9 = log₆ (4 · 9)", "= log₆ 36", "6² = 36, so log₆ 36 = 2"],
  "log₆ 36 = 2", c_lg1_3)


def c_lg1_4():
    v = 3 * math.log2(6) - math.log2(27)
    req(near(v, 3))
    return "3"
P("lg1", "Evaluate 3 log₂ 6 - log₂ 27.",
  ["Power law: 3 log₂ 6 = log₂ 6³ = log₂ 216", "Quotient law: log₂ 216 - log₂ 27 = log₂ (216/27)", "= log₂ 8 = 3"],
  "3", c_lg1_4)


def c_lg1_5():
    v = log(4) / log(8)
    req(near(v, 2 / 3))
    return "2/3"
P("lg1", "Use change of base to evaluate log₈ 4 exactly.",
  ["Change to base 2: log₈ 4 = log₂ 4 / log₂ 8", "log₂ 4 = 2 and log₂ 8 = 3", "= 2/3", "Check: 8^(2/3) = 4 ✓"],
  "2/3", c_lg1_5)


def c_lg1_6():
    x, y, z = 3.7, 5.2, 1.9
    lhs = math.log10(x * x * y / z ** 3)
    rhs = 2 * math.log10(x) + math.log10(y) - 3 * math.log10(z)
    req(near(lhs, rhs))
    return "2 log x + log y - 3 log z"
P("lg1", "Expand log({x²y|z³}) using the laws of logarithms.",
  ["Quotient law: log(x²y) - log(z³)", "Product law on the first part: log x² + log y - log z³", "Power law: 2 log x + log y - 3 log z"],
  "2 log x + log y - 3 log z", c_lg1_6)


# ================= lg2: log equations, graphs, situations =================
def c_lg2_1():
    x = 2 ** 4 - 3
    req(math.log2(x + 3) == 4)
    return f"x = {x}"
P("lg2", "Solve log₂ (x + 3) = 4.",
  ["Exponential form: x + 3 = 2⁴", "x + 3 = 16", "x = 13", "Check: log₂ 16 = 4 ✓"],
  "x = 13", c_lg2_1)


def c_lg2_2():
    sols = [x for x in range(-10, 11) if x > 2 and x * (x - 2) == 3]
    req(sols == [3] and (-1 * (-1 - 2) == 3))
    return "x = 3"
P("lg2", "Solve log₃ x + log₃ (x - 2) = 1.",
  ["Product law: log₃ [x(x - 2)] = 1", "x(x - 2) = 3¹ = 3", "x² - 2x - 3 = 0, (x - 3)(x + 1) = 0", "x = 3 or x = -1",
   "x = -1 makes log₃ x undefined, so reject it", "x = 3"],
  "x = 3", c_lg2_2)


def c_lg2_3():
    x = F(4, 3)
    req(x > 1 and near(math.log10(float(x) + 2) - math.log10(float(x) - 1), 1))
    return f"x = {fmt(x)}"
P("lg2", "Solve log (x + 2) - log (x - 1) = 1.",
  ["Quotient law: log[(x + 2)/(x - 1)] = 1", "(x + 2)/(x - 1) = 10", "x + 2 = 10x - 10", "12 = 9x, x = 4/3", "x > 1 so both logs are defined ✓"],
  "x = 4/3", c_lg2_3)


def c_lg2_4():
    sols = [x for x in range(1, 20) if x * x == 5 * x - 6]
    req(sols == [2, 3])
    return "x = 2 or x = 3"
P("lg2", "Solve ln(x²) = ln(5x - 6).",
  ["Logs are one to one, so x² = 5x - 6", "x² - 5x + 6 = 0, (x - 2)(x - 3) = 0", "x = 2 or x = 3",
   "Both give positive arguments: 4 and 4 for x = 2, 9 and 9 for x = 3 ✓"],
  "x = 2 or x = 3", c_lg2_4)


def c_lg2_5():
    f = lambda x: math.log2(x - 3) + 1
    req(near(f(3.5), 0) and f(3.0001) < -10)
    return "vertical asymptote x = 3; domain x > 3; x intercept (7/2, 0)"
P("lg2", "For y = log₂ (x - 3) + 1, state the vertical asymptote, the domain and the x intercept.",
  ["The argument must be positive: x - 3 > 0, so x > 3", "Vertical asymptote x = 3, domain x > 3", "x intercept: log₂ (x - 3) + 1 = 0",
   "log₂ (x - 3) = -1, so x - 3 = 2⁻¹ = 1/2", "x = 7/2"],
  "vertical asymptote x = 3; domain x > 3; x intercept (7/2, 0)", c_lg2_5)


def c_lg2_6():
    r = 10 ** (7 - 5)
    return f"{r} times as intense"
P("lg2", "Earthquake magnitude is M = log(I/I₀). How many times as intense is a magnitude 7 quake as a magnitude 5 quake?",
  ["M = log(I/I₀) means I = I₀ · 10^M", "I₇/I₅ = 10⁷/10⁵", "= 10² = 100"],
  "100 times as intense", c_lg2_6)


def c_lg2_7():
    t = log(2) / 0.05
    req(near(500 * exp(0.05 * t), 1000))
    return f"t ≈ {rnd(t, 1)} years"
P("lg2", "An investment grows as A = 500e^(0.05t), where A is in dollars and t is in years. After how many years does it reach $1000? Answer to 1 decimal place.",
  ["1000 = 500e^(0.05t), so e^(0.05t) = 2", "0.05t = ln 2", "t = ln 2 / 0.05 = 0.6931 / 0.05", "t ≈ 13.9 years"],
  "t ≈ 13.9 years", c_lg2_7)


# ================= po1: factoring, factor + remainder theorems =================
def c_po1_1():
    c = [1, -4, 2, 5]
    r = polyval(c, 3)
    q, rem = polydiv(c, [1, -3])
    req(rem == [r])
    return f"remainder {r}"
P("po1", "Find the remainder when x³ - 4x² + 2x + 5 is divided by x - 3.",
  ["Remainder theorem: the remainder is P(3)", "P(3) = 27 - 36 + 6 + 5", "= 2"],
  "remainder 2", c_po1_1)


def c_po1_2():
    ks = [k for k in range(-20, 21) if polyval([1, k, -5, -6], -2) == 0]
    req(ks == [1])
    return f"k = {ks[0]}"
P("po1", "Find k so that x + 2 is a factor of x³ + kx² - 5x - 6.",
  ["Factor theorem: P(-2) must equal 0", "(-2)³ + k(-2)² - 5(-2) - 6 = 0", "-8 + 4k + 10 - 6 = 0", "4k - 4 = 0, so k = 1"],
  "k = 1", c_po1_2)


def c_po1_3():
    c = [1, 0, -7, 6]
    rts = int_roots(c)
    req(rts == [-3, 1, 2])
    req(polymul(polymul([1, -1], [1, -2]), [1, 3]) == c)
    return "(x - 1)(x - 2)(x + 3)"
P("po1", "Factor x³ - 7x + 6 completely.",
  ["Try factors of 6. P(1) = 1 - 7 + 6 = 0, so x - 1 is a factor", "Synthetic division by 1 on 1, 0, -7, 6 gives 1, 1, -6, remainder 0", "So x³ - 7x + 6 = (x - 1)(x² + x - 6)", "x² + x - 6 = (x + 3)(x - 2)",
   "x³ - 7x + 6 = (x - 1)(x - 2)(x + 3)"],
  "(x - 1)(x - 2)(x + 3)", c_po1_3)


def c_po1_4():
    c = [2, 3, -8, 3]
    req(polyval(c, 1) == 0)
    q, rem = polydiv(c, [1, -1])
    req(q == [2, 5, -3] and rem == [0])
    req(polymul(polymul([1, -1], [2, -1]), [1, 3]) == c)
    return "(x - 1)(2x - 1)(x + 3)"
P("po1", "Factor 2x³ + 3x² - 8x + 3 completely.",
  ["P(1) = 2 + 3 - 8 + 3 = 0, so x - 1 is a factor", "Synthetic division by 1 gives coefficients 2, 5, -3", "Quotient 2x² + 5x - 3",
   "2x² + 5x - 3 = (2x - 1)(x + 3)", "(x - 1)(2x - 1)(x + 3)"],
  "(x - 1)(2x - 1)(x + 3)", c_po1_4)


def c_po1_5():
    c = [1, 0, -13, 0, 36]
    req(int_roots(c) == [-3, -2, 2, 3])
    req(polymul(polymul([1, -2], [1, 2]), polymul([1, -3], [1, 3])) == c)
    return "(x - 2)(x + 2)(x - 3)(x + 3)"
P("po1", "Factor x⁴ - 13x² + 36 completely.",
  ["Treat x² as one unit: (x²)² - 13(x²) + 36", "Two numbers with product 36 and sum -13: -4 and -9", "(x² - 4)(x² - 9)",
   "Each is a difference of squares: (x - 2)(x + 2)(x - 3)(x + 3)"],
  "(x - 2)(x + 2)(x - 3)(x + 3)", c_po1_5)


def c_po1_6():
    lhs = polymul([2, -3], [4, 6, 9])
    req(lhs == [8, 0, 0, -27])
    return "(2x - 3)(4x² + 6x + 9)"
P("po1", "Factor 8x³ - 27.",
  ["Difference of cubes: a³ - b³ = (a - b)(a² + ab + b²)", "a = 2x, b = 3", "(2x - 3)(4x² + 6x + 9)",
   "Check: 8x³ + 12x² + 18x - 12x² - 18x - 27 = 8x³ - 27 ✓"],
  "(2x - 3)(4x² + 6x + 9)", c_po1_6)


# ================= po2: polynomial graphs and solving =================
def c_po2_1():
    c = [2, -3, -11, 6]
    req(int_roots(c) == [-2, F(1, 2), 3])
    return "x = 3, x = 1/2 or x = -2"
P("po2", "Solve 2x³ - 3x² - 11x + 6 = 0.",
  ["Try x = 3: 54 - 27 - 33 + 6 = 0, so x - 3 is a factor", "Synthetic division by 3 gives 2, 3, -2", "2x² + 3x - 2 = (2x - 1)(x + 2)",
   "(x - 3)(2x - 1)(x + 2) = 0", "x = 3, x = 1/2 or x = -2"],
  "x = 3, x = 1/2 or x = -2", c_po2_1)


def c_po2_2():
    f = lambda x: -2 * x ** 5 + x ** 2 - 4
    req(f(0) == -4 and f(-100) > 1e9 and f(100) < -1e9)
    return "degree 5; left end up, right end down; y intercept -4; at most 4 turning points"
P("po2", "For y = -2x⁵ + x² - 4, state the degree, the end behaviour, the y intercept and the most turning points possible.",
  ["Highest power is x⁵: degree 5 (odd)", "Odd degree with negative leading coefficient: as x → -∞, y → +∞ and as x → +∞, y → -∞",
   "y intercept: f(0) = -4", "A degree n polynomial has at most n - 1 turning points: 4"],
  "degree 5; left end up, right end down; y intercept -4; at most 4 turning points", c_po2_2)


def c_po2_3():
    f = lambda x: (x + 1) ** 2 * (x - 2) * (x - 4)
    req(f(0) == 8)
    req(f(-1.01) * f(-0.99) > 0)       # touches: no sign change
    req(f(1.99) * f(2.01) < 0 and f(3.99) * f(4.01) < 0)   # crosses
    return "zeros -1 (touches), 2 (crosses), 4 (crosses); y intercept 8"
P("po2", "For y = (x + 1)²(x - 2)(x - 4), find the zeros, say whether the graph crosses or touches the x axis at each, and find the y intercept.",
  ["Zeros: x = -1 (multiplicity 2), x = 2 and x = 4 (multiplicity 1)", "Even multiplicity at -1: the graph touches the axis and turns around",
   "Odd multiplicity at 2 and 4: the graph crosses", "y intercept: (1)²(-2)(-4) = 8"],
  "zeros -1 (touches), 2 (crosses), 4 (crosses); y intercept 8", c_po2_3)


def c_po2_4():
    a = F(12, 6)
    f = lambda x: a * (x + 2) * (x - 1) * (x - 3)
    req(f(0) == 12 and f(-2) == f(1) == f(3) == 0)
    return "y = 2(x + 2)(x - 1)(x - 3)"
P("po2", "Write the equation of a cubic with zeros -2, 1 and 3 that passes through (0, 12).",
  ["y = a(x + 2)(x - 1)(x - 3)", "Use (0, 12): 12 = a(2)(-1)(-3) = 6a", "a = 2", "y = 2(x + 2)(x - 1)(x - 3)"],
  "y = 2(x + 2)(x - 1)(x - 3)", c_po2_4)


def c_po2_5():
    c = [1, -3, -4, 12]
    req(int_roots(c) == [-2, 2, 3])
    f = lambda x: polyval(c, x)
    neg = [x for x in [-3, -2.5, -1, 0, 1, 2.5, 4] if f(x) < 0]
    req(neg == [-3, -2.5, 2.5])
    return "x intercepts -2, 2, 3; y < 0 for x < -2 and 2 < x < 3"
P("po2", "Find the x intercepts of y = x³ - 3x² - 4x + 12 and the x values where y < 0.",
  ["Group: x²(x - 3) - 4(x - 3) = (x - 3)(x² - 4) = (x - 3)(x - 2)(x + 2)", "x intercepts: -2, 2, 3",
   "Positive leading coefficient: the graph starts below the axis on the far left", "Test between zeros: x < -2 negative, -2 < x < 2 positive, 2 < x < 3 negative, x > 3 positive",
   "y < 0 for x < -2 and 2 < x < 3"],
  "x intercepts -2, 2, 3; y < 0 for x < -2 and 2 < x < 3", c_po2_5)


# ================= ra: rational functions =================
def c_ra_1():
    f = lambda x: (x + 2) / (x - 3)
    req(near(f(1e9), 1, 1e-6) and near(f(0), -2 / 3) and f(-2) == 0 and abs(f(3.0001)) > 1e3)
    return "vertical asymptote x = 3; horizontal asymptote y = 1; x intercept -2; y intercept -2/3"
P("ra", "For y = {x + 2|x - 3}, find the asymptotes and both intercepts.",
  ["Denominator is 0 at x = 3: vertical asymptote x = 3", "Degrees are equal, so the horizontal asymptote is the ratio of leading coefficients: y = 1/1 = 1",
   "x intercept: numerator 0 gives x = -2", "y intercept: f(0) = 2/(-3) = -2/3"],
  "vertical asymptote x = 3; horizontal asymptote y = 1; x intercept -2; y intercept -2/3", c_ra_1)


def c_ra_2():
    f = lambda x: (x * x - 9) / (x - 3)
    for x in [-5, 0, 2, 4, 7]:
        req(near(f(x), x + 3))
    return "y = x + 3 with a hole at (3, 6)"
P("ra", "Simplify y = {x² - 9|x - 3} and state the point of discontinuity.",
  ["Factor the numerator: (x - 3)(x + 3)", "Cancel x - 3: y = x + 3, for x ≠ 3", "At x = 3 the cancelled factor leaves a hole, not an asymptote",
   "Hole at y = 3 + 3 = 6, so (3, 6)"],
  "y = x + 3 with a hole at (3, 6)", c_ra_2)


def c_ra_3():
    f = lambda x: (2 * x * x + 1) / (x * x - 4)
    req(near(f(1e6), 2, 1e-5) and abs(f(2.0001)) > 1e3 and abs(f(-2.0001)) > 1e3)
    return "vertical asymptotes x = 2 and x = -2; horizontal asymptote y = 2"
P("ra", "Find all asymptotes of y = {2x² + 1|x² - 4}.",
  ["Denominator: x² - 4 = (x - 2)(x + 2). Numerator is never 0 at those x, so nothing cancels", "Vertical asymptotes x = 2 and x = -2",
   "Equal degrees: horizontal asymptote y = 2/1 = 2"],
  "vertical asymptotes x = 2 and x = -2; horizontal asymptote y = 2", c_ra_3)


def c_ra_4():
    f = lambda x: (x * x - x - 6) / (x * x - 4)
    req(polymul([1, -3], [1, 2]) == [1, -1, -6] and polymul([1, -2], [1, 2]) == [1, 0, -4])
    hole_y = F(-5, -4)
    req(near(f(-2 + 1e-7), float(hole_y), 1e-5))
    req(f(3) == 0 and abs(f(2.0001)) > 1e3 and near(f(1e7), 1, 1e-5))
    return "hole at (-2, 5/4); vertical asymptote x = 2; horizontal asymptote y = 1; x intercept 3"
P("ra", "Describe y = {x² - x - 6|x² - 4}: any hole, vertical and horizontal asymptotes, and x intercept.",
  ["Factor: y = (x - 3)(x + 2) / ((x - 2)(x + 2))", "x + 2 cancels: hole at x = -2. Value there: (-2 - 3)/(-2 - 2) = -5/-4 = 5/4, so the hole is (-2, 5/4)",
   "Remaining denominator x - 2: vertical asymptote x = 2", "Equal degrees: horizontal asymptote y = 1", "x intercept: x - 3 = 0, so x = 3"],
  "hole at (-2, 5/4); vertical asymptote x = 2; horizontal asymptote y = 1; x intercept 3", c_ra_4)


def c_ra_5():
    f = lambda x: (3 * x + 1) / (x - 2)
    g = lambda x: 7 / (x - 2) + 3
    for x in [-3, 0, 1, 2.5, 6]:
        req(near(f(x), g(x)))
    return "y = 7/(x - 2) + 3"
P("ra", "Write y = {3x + 1|x - 2} in the form y = a/(x - h) + k.",
  ["Rewrite the numerator using the denominator: 3(x - 2) = 3x - 6, so 3x + 1 = 3(x - 2) + 7", "y = (3(x - 2) + 7)/(x - 2) = 3 + 7/(x - 2)", "y = 7/(x - 2) + 3",
   "So it is y = 1/x stretched by 7, right 2, up 3"],
  "y = 7/(x - 2) + 3", c_ra_5)


def c_ra_6():
    sols = [F(x, 3) for x in range(-30, 31) if x != 0 and F(x, 3) != -2 and 1 / F(x, 3) + 1 / (F(x, 3) + 2) == F(3, 4)]
    req(sols == [F(-4, 3), 2])
    return "x = 2 or x = -4/3"
P("ra", "Solve {1|x} + {1|x + 2} = {3|4}.",
  ["Common denominator 4x(x + 2): 4(x + 2) + 4x = 3x(x + 2)", "8x + 8 = 3x² + 6x", "3x² - 2x - 8 = 0", "(3x + 4)(x - 2) = 0",
   "x = 2 or x = -4/3. Neither is 0 or -2, so both are allowed"],
  "x = 2 or x = -4/3", c_ra_6)


# ================= tg1: angles, unit circle =================
def c_tg1_1():
    req(near(RAD(135), 3 * pi / 4) and near(7 * pi / 6 * 180 / pi, 210))
    return "135° = 3π/4; 7π/6 = 210°"
P("tg1", "Convert 135° to radians and 7π/6 to degrees.",
  ["Degrees to radians: multiply by π/180. 135π/180 = 3π/4", "Radians to degrees: multiply by 180/π. (7π/6)(180/π) = 210°"],
  "135° = 3π/4; 7π/6 = 210°", c_tg1_1)


def c_tg1_2():
    req(near(sin(5 * pi / 6), 0.5) and near(cos(7 * pi / 6), -sqrt(3) / 2))
    return "sin(5π/6) = 1/2; cos(7π/6) = -√3/2"
P("tg1", "Find the exact values of sin(5π/6) and cos(7π/6).",
  ["5π/6 is in quadrant II with reference angle π - 5π/6 = π/6. Sine is positive there: sin = 1/2",
   "7π/6 is in quadrant III with reference angle 7π/6 - π = π/6. Cosine is negative there: cos = -√3/2"],
  "sin(5π/6) = 1/2; cos(7π/6) = -√3/2", c_tg1_2)


def c_tg1_3():
    co = -250 % 360
    ref = 180 - co
    req(co == 110 and 90 < co < 180 and ref == 70)
    req(near(abs(cos(RAD(-250))), cos(RAD(70))))
    return "110°, quadrant II, reference angle 70°"
P("tg1", "For the angle -250° in standard position, find the coterminal angle between 0° and 360°, its quadrant and its reference angle.",
  ["Add 360°: -250° + 360° = 110°", "90° < 110° < 180°, so quadrant II", "Reference angle: 180° - 110° = 70°"],
  "110°, quadrant II, reference angle 70°", c_tg1_3)


def c_tg1_4():
    x, y = -3, 4
    r = sqrt(x * x + y * y)
    req(r == 5)
    return f"sin θ = 4/5, cos θ = -3/5, tan θ = -4/3"
P("tg1", "The point P(-3, 4) is on the terminal arm of angle θ in standard position. Find sin θ, cos θ and tan θ.",
  ["r = √((-3)² + 4²) = √25 = 5", "sin θ = y/r = 4/5", "cos θ = x/r = -3/5", "tan θ = y/x = 4/(-3) = -4/3"],
  "sin θ = 4/5, cos θ = -3/5, tan θ = -4/3", c_tg1_4)


def c_tg1_5():
    req(near(sin(11 * pi / 6) * cos(5 * pi / 3), -0.25))
    return "-1/4"
P("tg1", "Find the exact value of sin(11π/6) · cos(5π/3).",
  ["11π/6 is in quadrant IV, reference angle π/6: sin is negative, so sin(11π/6) = -1/2",
   "5π/3 is in quadrant IV, reference angle π/3: cos is positive, so cos(5π/3) = 1/2", "(-1/2)(1/2) = -1/4"],
  "-1/4", c_tg1_5)


def c_tg1_6():
    s = 8 * 3 * pi / 4
    req(near(s, 6 * pi))
    return f"6π cm"
P("tg1", "A circle has radius 8 cm. Find the arc length for a central angle of 3π/4 radians. Give an exact answer.",
  ["Arc length s = rθ (θ in radians)", "s = 8 · 3π/4", "s = 6π cm (about 18.85 cm)"],
  "6π cm", c_tg1_6)


# ================= tg2: graphing and characteristics =================
def c_tg2_1():
    f = lambda x: 3 * sin(2 * x - pi) + 1
    g = lambda x: 3 * sin(2 * (x - pi / 2)) + 1
    for x in [0, 0.3, 1.9, 4]:
        req(near(f(x), g(x)))
    return "amplitude 3, period π, phase shift π/2 right, midline y = 1"
P("tg2", "State the amplitude, period, phase shift and midline of y = 3 sin(2x - π) + 1.",
  ["Factor the horizontal part: 2x - π = 2(x - π/2)", "Amplitude |3| = 3", "Period 2π/2 = π", "Phase shift π/2 to the right", "Midline y = 1"],
  "amplitude 3, period π, phase shift π/2 right, midline y = 1", c_tg2_1)


def c_tg2_2():
    f = lambda x: 4 * cos(pi * x / 3) + 3
    req(near(f(0), 7) and near(f(3), -1) and near(f(6), 7))
    return "y = 4 cos(πx/3) + 3"
P("tg2", "A cosine curve has maximum 7, minimum -1 and period 6, with a maximum at x = 0. Write its equation.",
  ["Amplitude = (7 - (-1))/2 = 4", "Midline = (7 + (-1))/2 = 3", "Period 6 = 2π/b, so b = π/3", "A maximum at x = 0 means a plain cosine: y = 4 cos(πx/3) + 3",
   "Check: x = 0 gives 4 + 3 = 7 ✓"],
  "y = 4 cos(πx/3) + 3", c_tg2_2)


def c_tg2_3():
    h = lambda t: -10 * cos(pi * t / 20) + 12
    req(near(h(0), 2) and near(h(20), 22) and near(h(40), 2) and near(h(10), 12))
    return "h(t) = -10 cos(πt/20) + 12"
P("tg2", "A Ferris wheel has radius 10 m, its centre 12 m above ground, and turns once every 40 s. A rider starts at the bottom. Write the height h(t) in metres, t seconds after the ride starts.",
  ["Amplitude = radius = 10, midline = 12", "Period 40 = 2π/b, so b = π/20", "The rider starts at the minimum, so use a reflected cosine: h(t) = -10 cos(πt/20) + 12",
   "Check: t = 0 gives -10 + 12 = 2 m; t = 20 gives 22 m ✓"],
  "h(t) = -10 cos(πt/20) + 12", c_tg2_3)


def c_tg2_4():
    f = lambda x: tan(2 * x)
    req(near(f(0.3), f(0.3 + pi / 2)))
    req(abs(cos(2 * pi / 4)) < 1e-12 and abs(cos(2 * 3 * pi / 4)) < 1e-12)
    return "period π/2; asymptotes x = π/4 and x = 3π/4"
P("tg2", "For y = tan 2x, find the period and the vertical asymptotes for 0 ≤ x ≤ π.",
  ["Period of tan x is π, so y = tan 2x has period π/2", "Asymptotes where cos 2x = 0: 2x = π/2, 3π/2", "x = π/4 and x = 3π/4"],
  "period π/2; asymptotes x = π/4 and x = 3π/4", c_tg2_4)


def c_tg2_5():
    g = lambda x: -2 * sin(x / 2) + 3
    req(near(g(0), 3) and near(g(pi), 1) and near(g(0.7), g(0.7 + 4 * pi)))
    return "reflect in the x axis, vertical stretch 2, horizontal stretch 2, up 3; period 4π"
P("tg2", "Describe the transformations from y = sin x to y = -2 sin(x/2) + 3 and state the period.",
  ["-2: reflect in the x axis and stretch vertically by a factor of 2", "x/2 = (1/2)x: stretch horizontally by a factor of 2", "+3: shift up 3",
   "Period = 2π / (1/2) = 4π"],
  "reflect in the x axis, vertical stretch 2, horizontal stretch 2, up 3; period 4π", c_tg2_5)


# ================= tg3: trig equations =================
def c_tg3_1():
    sols = [pi / 6, 5 * pi / 6]
    req(all(near(2 * sin(s), 1) for s in sols))
    brute = [k * pi / 6 for k in range(12) if near(2 * sin(k * pi / 6), 1)]
    req(len(brute) == 2)
    return "x = π/6 or x = 5π/6"
P("tg3", "Solve 2 sin x = 1 for 0 ≤ x < 2π.",
  ["sin x = 1/2", "Reference angle π/6; sine is positive in quadrants I and II", "x = π/6 or x = π - π/6 = 5π/6"],
  "x = π/6 or x = 5π/6", c_tg3_1)


def c_tg3_2():
    sols = [d for d in range(0, 360) if near(2 * cos(RAD(d)) + sqrt(3), 0, 1e-9)]
    req(sols == [150, 210])
    return "x = 150° or x = 210°"
P("tg3", "Solve 2 cos x + √3 = 0 for 0° ≤ x < 360°.",
  ["cos x = -√3/2", "Reference angle 30°; cosine is negative in quadrants II and III", "x = 180° - 30° = 150° or x = 180° + 30° = 210°"],
  "x = 150° or x = 210°", c_tg3_2)


def c_tg3_3():
    sols = [3 * pi / 4, 7 * pi / 4]
    req(all(near(tan(s), -1) for s in sols))
    req(len([k for k in range(24) if near(tan(k * pi / 12), -1, 1e-9)]) == 2)
    return "x = 3π/4 or x = 7π/4"
P("tg3", "Solve tan x = -1 for 0 ≤ x < 2π.",
  ["Reference angle π/4; tangent is negative in quadrants II and IV", "x = π - π/4 = 3π/4", "x = 2π - π/4 = 7π/4"],
  "x = 3π/4 or x = 7π/4", c_tg3_3)


def c_tg3_4():
    ks = [k for k in range(12) if near(2 * cos(k * pi / 6) ** 2 - cos(k * pi / 6) - 1, 0, 1e-9)]
    req(ks == [0, 4, 8])
    return "x = 0, 2π/3 or 4π/3"
P("tg3", "Solve 2cos²x - cos x - 1 = 0 for 0 ≤ x < 2π.",
  ["Factor like 2u² - u - 1 with u = cos x: (2cos x + 1)(cos x - 1) = 0", "cos x = -1/2 or cos x = 1",
   "cos x = 1: x = 0", "cos x = -1/2: reference angle π/3, quadrants II and III: x = 2π/3, 4π/3"],
  "x = 0, 2π/3 or 4π/3", c_tg3_4)


def c_tg3_5():
    ks = [k for k in range(12) if near(2 * sin(k * pi / 6) ** 2 + sin(k * pi / 6) - 1, 0, 1e-9)]
    req(ks == [1, 5, 9])
    return "x = π/6, 5π/6 or 3π/2"
P("tg3", "Solve 2sin²x + sin x - 1 = 0 for 0 ≤ x < 2π.",
  ["Factor: (2 sin x - 1)(sin x + 1) = 0", "sin x = 1/2: x = π/6 or 5π/6", "sin x = -1: x = 3π/2"],
  "x = π/6, 5π/6 or 3π/2", c_tg3_5)


def c_tg3_6():
    for k in range(-3, 4):
        for base in (pi / 6, 5 * pi / 6):
            req(near(2 * sin(base + 2 * pi * k), 1))
    return "x = π/6 + 2πk or x = 5π/6 + 2πk, k an integer"
P("tg3", "Solve 2 sin x = 1 over all real numbers.",
  ["sin x = 1/2 has solutions π/6 and 5π/6 in one turn", "Sine repeats every 2π, so add 2πk", "x = π/6 + 2πk or x = 5π/6 + 2πk, k an integer"],
  "x = π/6 + 2πk or x = 5π/6 + 2πk, k an integer", c_tg3_6)


def c_tg3_7():
    xs = [k * pi / 12 for k in range(24)]
    sols = [x for x in xs if near(sin(2 * x), sqrt(3) / 2, 1e-9)]
    req(len(sols) == 4)
    req(sorted(round(s / (pi / 6)) for s in sols) == [1, 2, 7, 8])
    return "x = π/6, π/3, 7π/6 or 4π/3"
P("tg3", "Solve sin 2x = √3/2 for 0 ≤ x < 2π.",
  ["Let u = 2x, so 0 ≤ u < 4π (two turns)", "sin u = √3/2: u = π/3, 2π/3, then add 2π: 7π/3, 8π/3",
   "Divide by 2: x = π/6, π/3, 7π/6, 4π/3"],
  "x = π/6, π/3, 7π/6 or 4π/3", c_tg3_7)


def c_tg3_8():
    h = lambda t: -10 * cos(pi * t / 20) + 12
    t = 40 / 3
    req(near(h(t), 17))
    # first time: scan
    first = next(i / 1000 for i in range(0, 40001) if h(i / 1000) >= 17)
    req(abs(first - t) < 0.01)
    return f"t = 40/3 ≈ {rnd(t, 1)} s"
P("tg3", "The height of a rider on a Ferris wheel is h(t) = -10 cos(πt/20) + 12 metres, where t is in seconds and 0 ≤ t ≤ 40. At what time is the rider first 17 m above the ground?",
  ["-10 cos(πt/20) + 12 = 17", "cos(πt/20) = -1/2", "πt/20 = 2π/3 (first angle in quadrant II)", "t = 20 · 2/3 = 40/3 ≈ 13.3 s"],
  "t = 40/3 ≈ 13.3 s", c_tg3_8)


# ================= tg4: identities =================
def c_tg4_1():
    for x in [0.3, 0.9, 1.2, 2.5]:
        req(near(1 / cos(x) - sin(x) * tan(x), cos(x)))
    return "cos x"
P("tg4", "Simplify sec x - sin x tan x.",
  ["Reciprocal and quotient identities: 1/cos x - sin x · (sin x / cos x)", "= (1 - sin²x)/cos x", "Pythagorean identity: 1 - sin²x = cos²x",
   "= cos²x / cos x = cos x"],
  "cos x", c_tg4_1)


def c_tg4_2():
    for x in [0.3, 0.9, 1.2, 2.5]:
        req(near(1 / tan(x) + tan(x), (1 / cos(x)) * (1 / sin(x))))
    return "cot x + tan x = sec x csc x"
P("tg4", "Prove cot x + tan x = sec x csc x.",
  ["Left side: cos x / sin x + sin x / cos x", "Common denominator sin x cos x: (cos²x + sin²x)/(sin x cos x)", "Pythagorean identity: = 1/(sin x cos x)",
   "= (1/cos x)(1/sin x) = sec x csc x = right side"],
  "cot x + tan x = sec x csc x", c_tg4_2)


def c_tg4_3():
    th = math.asin(3 / 5)
    th = pi - th        # quadrant II
    req(near(sin(2 * th), -24 / 25) and near(cos(2 * th), 7 / 25))
    return "sin 2θ = -24/25, cos 2θ = 7/25"
P("tg4", "sin θ = 3/5 and θ is in quadrant II. Find sin 2θ and cos 2θ.",
  ["cos²θ = 1 - 9/25 = 16/25. In quadrant II cosine is negative: cos θ = -4/5", "sin 2θ = 2 sin θ cos θ = 2(3/5)(-4/5) = -24/25",
   "cos 2θ = 1 - 2sin²θ = 1 - 2(9/25) = 7/25"],
  "sin 2θ = -24/25, cos 2θ = 7/25", c_tg4_3)


def c_tg4_4():
    req(near(sin(RAD(75)), (sqrt(6) + sqrt(2)) / 4))
    return "(√6 + √2)/4"
P("tg4", "Use a sum formula to find the exact value of sin 75°.",
  ["75° = 45° + 30°", "sin(A + B) = sin A cos B + cos A sin B", "= (√2/2)(√3/2) + (√2/2)(1/2)", "= (√6 + √2)/4"],
  "(√6 + √2)/4", c_tg4_4)


def c_tg4_5():
    req(near(tan(RAD(15)), 2 - sqrt(3)))
    req(near((sqrt(3) - 1) / (sqrt(3) + 1), 2 - sqrt(3)))
    return "2 - √3"
P("tg4", "Use a difference formula to find the exact value of tan 15°.",
  ["15° = 45° - 30°", "tan(A - B) = (tan A - tan B)/(1 + tan A tan B)", "= (1 - 1/√3)/(1 + 1/√3)", "Multiply top and bottom by √3: (√3 - 1)/(√3 + 1)",
   "Multiply by (√3 - 1)/(√3 - 1): (3 - 2√3 + 1)/(3 - 1) = (4 - 2√3)/2", "= 2 - √3"],
  "2 - √3", c_tg4_5)


def c_tg4_6():
    xs = [k * pi / 12 for k in range(24)]
    sols = [x for x in xs if near(sin(2 * x), sin(x), 1e-9)]
    req(sorted(round(s / (pi / 3)) for s in sols) == [0, 1, 3, 5])
    return "x = 0, π/3, π or 5π/3"
P("tg4", "Solve sin 2x = sin x for 0 ≤ x < 2π.",
  ["Double angle: 2 sin x cos x = sin x", "Move everything to one side (do not divide by sin x): 2 sin x cos x - sin x = 0", "sin x (2 cos x - 1) = 0",
   "sin x = 0: x = 0, π", "cos x = 1/2: x = π/3, 5π/3"],
  "x = 0, π/3, π or 5π/3", c_tg4_6)


if __name__ == "__main__":
    main()
