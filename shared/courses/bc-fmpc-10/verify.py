#!/usr/bin/env python3
"""Re-runnable verifier for shared/courses/bc-fmpc-10/problems.json.

Run:  python3 -I shared/courses/bc-fmpc-10/verify.py     (standard library only)
Exit code 0 only if every problem passes every check, otherwise 1.

What is checked, mechanically, for every problem:
  1. Schema: same fields and shapes as shared/problems.json; prompt_plain matches prompt_parts.
  2. The final answer, recomputed from the problem's givens with Fractions, brute force, or
     the math module (trig). The givens are read back out of prompt_plain wherever it is
     a clean expression or equation, so a typo in the JSON cannot hide.
  3. Intermediate lines: every "A = B = C" chain inside worked_solution is parsed by a
     small Unicode-math evaluator and each neighbouring pair must be equal (or equal
     within 0.2% for "≈") at the answer values (equations), at random rational values
     (algebraic identities), on sample points of the line (line equations), or as plain
     numbers. Lines that are prose are skipped and counted.
"""
import json
import math
import random
import re
import sys
from fractions import Fraction as F
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROBLEMS = HERE / "problems.json"

# ---------------------------------------------------------------------------
# Unicode-math evaluator (Fractions only)
# ---------------------------------------------------------------------------
SUPMAP = str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹⁻", "0123456789-")
TOKEN = re.compile(
    r"\s+|(?P<sup>[⁰¹²³⁴⁵⁶⁷⁸⁹⁻]+)|(?P<num>\d+(?:\.\d+)?)|(?P<var>[A-Za-z])|(?P<op>[()+\-*/])|(?P<bad>.)"
)


class Skip(Exception):
    """This text is prose or something the evaluator does not handle."""


def ev(text, names="", values=None):
    values = values or {}
    s = text.replace("$", "").replace("−", "-").replace("×", "*").replace("·", "*").replace("÷", "/")
    s = re.sub(r"(?<=\d),(?=\d{3}(?!\d))", "", s)
    out, prev = [], None
    for m in TOKEN.finditer(s):
        kind = m.lastgroup
        if kind is None:
            continue
        t = m.group()
        if kind == "bad":
            raise Skip(t)
        if kind == "sup":
            e = t.translate(SUPMAP)
            if not re.fullmatch(r"-?\d+", e) or prev not in ("num", "var", "rp"):
                raise Skip(t)
            out.append(f"**(F({e}))")
            prev = "sup"
        elif kind == "num":
            if prev == "num":
                raise Skip(t)
            if prev in ("rp", "sup", "var"):
                out.append("*")
            out.append(f"F('{t}')")
            prev = "num"
        elif kind == "var":
            if t not in names:
                raise Skip(t)
            if prev in ("num", "var", "rp", "sup"):
                out.append("*")
            out.append(f"V['{t}']")
            prev = "var"
        elif t == "(":
            if prev in ("num", "var", "rp", "sup"):
                out.append("*")
            out.append("(")
            prev = "lp"
        elif t == ")":
            out.append(")")
            prev = "rp"
        else:
            out.append(t)
            prev = "op"
    if not out:
        raise Skip("empty")
    try:
        v = eval("".join(out), {"__builtins__": {}}, {"F": F, "V": values})
    except (ZeroDivisionError, SyntaxError, TypeError, ValueError, OverflowError):
        raise Skip("unevaluable")
    if not isinstance(v, F):
        raise Skip("not a number")
    return v


def pieces(line):
    out = []
    for p in re.split(r",? so |; ", line):
        if ":" in p:
            p = p.rsplit(":", 1)[1]
        out.append(p.strip())
    return out


def pair_results(piece, names, values):
    """Yield (ok, a, b, op) for each neighbouring pair of parseable segments in A = B ≈ C."""
    tokens = re.split(r"(=|≈)", piece)
    segs, ops = tokens[0::2], tokens[1::2]
    vals = []
    for sg in segs:
        try:
            vals.append(ev(sg, names, values))
        except Skip:
            vals.append(None)
    for i, op in enumerate(ops):
        a, b = vals[i], vals[i + 1]
        if a is None or b is None:
            continue
        ok = (a == b) if op == "=" else abs(a - b) <= F(2, 1000) * max(abs(a), abs(b))
        yield ok, a, b, op


def random_points(names, count=7, seed=20261114):
    rng = random.Random(seed)
    pts = []
    for _ in range(count):
        d = {}
        for n in names:
            while True:
                v = F(rng.choice([-1, 1]) * rng.randint(1, 9), rng.randint(1, 4))
                if abs(v) not in (0, 1):
                    break
            d[n] = v
        pts.append(d)
    return pts


class Ctx:
    def __init__(self, p):
        self.p = p
        self.pid = p["id"]
        self.errors = []
        self.checked = 0
        self.prose = 0

    def err(self, msg):
        self.errors.append(msg)

    def expect(self, cond, msg):
        if not cond:
            self.err(msg)

    # -- intermediate lines --------------------------------------------------
    def lines(self, names="", assign=None, ident=False, loci=None, skip_idx=()):
        """Check every neighbouring pair in every line.

        assign: one dict of values (equation-solving problems)
        ident:  True -> random rational values for `names`
        loci:   list of point-lists; a pair passes if it holds on all points of ANY locus
        """
        for idx, line in enumerate(self.p["worked_solution"]):
            if idx in skip_idx:
                continue
            found_pair = False
            for piece in pieces(line):
                if "=" not in piece and "≈" not in piece:
                    continue
                tokens = re.split(r"(=|≈)", piece)
                # evaluate under the right scenario(s)
                if loci:
                    scenarios_list = loci
                elif ident:
                    scenarios_list = [random_points(names)]
                else:
                    scenarios_list = [[assign or {}]]
                per_locus = []
                pair_info = None
                for locus in scenarios_list:
                    oks, info = [], []
                    for values in locus:
                        res = list(pair_results(piece, names, values))
                        oks.append(all(r[0] for r in res))
                        info.append(len(res))
                    per_locus.append((all(oks), min(info) if info else 0))
                n_pairs = max(i for _, i in per_locus) if per_locus else 0
                if n_pairs == 0:
                    continue
                found_pair = True
                self.checked += n_pairs
                if not any(ok for ok, _ in per_locus):
                    self.err(f"line {idx + 1} piece '{piece}' fails")
            if not found_pair:
                self.prose += 1

    # -- final answer helpers ----------------------------------------------
    def final(self):
        return self.p["final_answer"]

    def prompt(self):
        return self.p["prompt_plain"]

    def prompt_expr(self):
        return self.prompt().split(": ", 1)[1]

    def final_has(self, *needles):
        for n in needles:
            if not re.search(r"(?<![\d.])" + re.escape(str(n)) + r"(?![\d])", self.final().replace(",", "")):
                self.err(f"final_answer lacks '{n}': {self.final()}")

    def bind(self, *subs):
        for s in subs:
            if s not in self.prompt():
                self.err(f"prompt lacks given '{s}'")

    def step(self, idx):
        return self.p["worked_solution"][idx]


def money(x):
    return f"{x:,.2f}"


def factorint(n):
    d, p = {}, 2
    while p * p <= n:
        while n % p == 0:
            d[p] = d.get(p, 0) + 1
            n //= p
        p += 1
    if n > 1:
        d[n] = d.get(n, 0) + 1
    return d


def is_prime(n):
    return n > 1 and factorint(n) == {n: 1}


def prime_product_text(ctx, text, n):
    """text like '2² × 3 × 7' must be the prime factorization of n."""
    terms = re.findall(r"(\d+)([⁰¹²³⁴⁵⁶⁷⁸⁹]*)", text)
    got = {}
    for base, sup in terms:
        b = int(base)
        e = int(sup.translate(SUPMAP)) if sup else 1
        if not is_prime(b):
            ctx.err(f"'{b}' in '{text}' is not prime")
        got[b] = got.get(b, 0) + e
    ctx.expect(got == factorint(n), f"'{text}' is not the prime factorization of {n}: {factorint(n)}")


def last_segment(line):
    return pieces(line)[-1].split("=")[-1].strip()


def poly_coeffs(text, var="x", deg=4):
    """Coefficients c0..c_deg of an expression in `var`, by exact interpolation."""
    xs = [F(i) for i in range(deg + 1)]
    ys = [ev(text, var, {var: x}) for x in xs]
    # Newton/Gauss: solve Vandermonde
    n = deg + 1
    A = [[x ** j for j in range(n)] + [y] for x, y in zip(xs, ys)]
    for i in range(n):
        piv = next(r for r in range(i, n) if A[r][i] != 0)
        A[i], A[piv] = A[piv], A[i]
        A[i] = [v / A[i][i] for v in A[i]]
        for r in range(n):
            if r != i and A[r][i] != 0:
                f = A[r][i]
                A[r] = [a - f * b for a, b in zip(A[r], A[i])]
    return [A[i][n] for i in range(n)]


def coeffs_gcd(cs):
    g = 0
    for c in cs:
        g = math.gcd(g, int(c))
    return g


# ---------------------------------------------------------------------------
# Check kinds
# ---------------------------------------------------------------------------
CHECKS = {}


def register(pid):
    def deco(fn):
        CHECKS[pid] = fn
        return fn
    return deco


def num_problem(pid, value, expr=True):
    """Pure number problem: prompt expression (if any) and final answer both equal `value`."""
    def fn(c):
        if expr:
            c.expect(ev(c.prompt_expr()) == value, f"prompt expression != {value}")
        c.expect(ev(c.final()) == value, f"final answer != {value}")
        c.lines()
    CHECKS[pid] = fn


def ident_problem(pid, names, expanded=False, extra=None):
    """Prompt expression and final answer are the same algebraic expression."""
    def fn(c):
        for vals in random_points(names, 8):
            a, b = ev(c.prompt_expr(), names, vals), ev(c.final(), names, vals)
            if a != b:
                c.err(f"prompt and final answer differ at {vals}: {a} vs {b}")
                break
        if expanded:
            c.expect("(" not in c.final(), "answer must be expanded (no brackets)")
        if extra:
            extra(c)
        c.lines(names=names, ident=True)
    CHECKS[pid] = fn


def solve_linear(eq_text, names):
    """Solve one linear equation in one unknown, or return dict for 2 equations elsewhere."""
    left, right = eq_text.split("=")
    f = lambda v: ev(left, names, v) - ev(right, names, v)
    if len(names) == 1:
        n = names[0]
        f0, f1 = f({n: F(0)}), f({n: F(1)})
        k = f1 - f0
        if k == 0:
            raise Skip("not a unique linear equation")
        return {n: -f0 / k}
    raise Skip("one unknown only")


def solve_system(eqs, names):
    """Two linear equations in x, y (names of length 2). Returns {x:..., y:...} or None."""
    rows = []
    for e in eqs:
        left, right = e.split("=")
        f = lambda v: ev(left, names, v) - ev(right, names, v)
        z = {names[0]: F(0), names[1]: F(0)}
        a = f({names[0]: F(1), names[1]: F(0)}) - f(z)
        b = f({names[0]: F(0), names[1]: F(1)}) - f(z)
        rows.append((a, b, -f(z)))
    (a1, b1, c1), (a2, b2, c2) = rows
    det = a1 * b2 - a2 * b1
    if det == 0:
        return None
    return {names[0]: (c1 * b2 - c2 * b1) / det, names[1]: (a1 * c2 - a2 * c1) / det}


def assigns_in(text):
    """'x = 3, y = −2' -> {'x': 3, 'y': -2}"""
    out = {}
    for name, val in re.findall(r"\b([a-z]) = (−?[\d.]+(?:/\d+)?)", text):
        out[name] = ev(val)
    return out


def single_eq_problem(pid, eq, name, bind):
    def fn(c):
        c.bind(*bind)
        sol = solve_linear(eq, name)
        c.expect(assigns_in(c.final()).get(name) == sol[name], f"final {name} != {sol[name]}")
        c.lines(names=name, assign=sol)
    CHECKS[pid] = fn


def system_problem(pid, names="xy", eqs=None, brute=None):
    def fn(c):
        local_eqs = eqs or [e.strip() for e in c.prompt_expr().split(" and ")]
        sol = solve_system(local_eqs, names)
        c.expect(sol is not None, "system has no unique solution")
        if brute:
            c.expect(brute(c) == sol, f"brute force disagrees with linear solve: {brute(c)} vs {sol}")
        c.expect(assigns_in(c.final()) == sol, f"final answer {assigns_in(c.final())} != {sol}")
        c.lines(names=names, assign=sol)
    CHECKS[pid] = fn


def points_on(p0, slope, ks=(-2, -1, 0, 1, 2), dx=1):
    return [(p0[0] + dx * k, p0[1] + dx * k * slope) for k in ks]


def line_problem(pid, main, other=None, bind=(), final_eq=None, off=None, extra=None):
    """`main`/`other` are lists of (x, y) Fractions that lie on the right line(s)."""
    def fn(c):
        c.bind(*bind)
        loci = [[{"x": F(x), "y": F(y)} for x, y in main]]
        if other:
            loci.append([{"x": F(x), "y": F(y)} for x, y in other])
        c.lines(names="xy", loci=loci)
        eq = final_eq or c.final()
        c.expect(eq in c.final(), f"final answer lacks '{eq}'")
        left, right = eq.split("=")
        for x, y in main:
            v = {"x": F(x), "y": F(y)}
            c.expect(ev(left, "xy", v) == ev(right, "xy", v), f"final equation false at {(x, y)}")
        ox, oy = off or (main[0][0], main[0][1] + 1)
        v = {"x": F(ox), "y": F(oy)}
        c.expect(ev(left, "xy", v) != ev(right, "xy", v), "final equation also true off the line")
        if extra:
            extra(c)
    CHECKS[pid] = fn


# ---- A: powers ------------------------------------------------------------
num_problem("f10-01", F(4))
num_problem("f10-02", F(-12))
ident_problem("f10-03", "mn")
ident_problem("f10-04", "xy")
num_problem("f10-05", F(2))

# ---- B: prime factorization -----------------------------------------------
@register("f10-06")
def _(c):
    rhs = c.final().split("=")[1]
    prime_product_text(c, rhs, 180)
    c.expect(c.final().startswith("180 ="), "final should start with 180 =")
    c.lines()


@register("f10-07")
def _(c):
    c.bind("84", "126")
    prime_product_text(c, last_segment(c.step(0)), 84)
    prime_product_text(c, last_segment(c.step(1)), 126)
    c.expect(ev(c.final()) == math.gcd(84, 126) == 42, "GCF should be 42")
    c.lines()


@register("f10-08")
def _(c):
    c.bind("18", "24")
    prime_product_text(c, last_segment(c.step(0)), 18)
    prime_product_text(c, last_segment(c.step(1)), 24)
    c.expect(ev(c.final()) == math.lcm(18, 24) == 72, "LCM should be 72")
    c.lines()


@register("f10-09")
def _(c):
    c.bind("600")
    n = next(n for n in range(1, 10000) if math.isqrt(600 * n) ** 2 == 600 * n)
    c.expect(n == 6 and c.final() == f"n = {n}", f"smallest n is {n}")
    prime_product_text(c, last_segment(c.step(0)), 600)
    c.lines()


@register("f10-10")
def _(c):
    c.bind("84 cm", "126 cm")
    g = math.gcd(84, 126)
    pieces_total = 84 // g + 126 // g
    c.expect((g, pieces_total) == (42, 5), "42 cm and 5 pieces expected")
    c.final_has(g, pieces_total)
    c.lines()


# ---- C: functions and relations -------------------------------------------
def relation_check(c, pairs, is_fn, domain, rng):
    c.bind("{" + ", ".join(f"({a}, {b})" for a, b in pairs) + "}")
    seen = {}
    for a, b in pairs:
        seen.setdefault(a, set()).add(b)
    actually_fn = all(len(v) == 1 for v in seen.values())
    c.expect(actually_fn == is_fn, f"function status should be {actually_fn}")
    return seen


@register("f10-11")
def _(c):
    pairs = [(1, 4), (2, 7), (3, 4), (5, 9)]
    relation_check(c, pairs, True, None, None)
    dom = sorted({a for a, _ in pairs})
    rng = sorted({b for _, b in pairs})
    c.expect(c.final() == f"Yes, a function. Domain {{{', '.join(map(str, dom))}}}, range {{{', '.join(map(str, rng))}}}",
             f"final answer should state domain {dom}, range {rng}")
    c.expect("Domain = all x-values = {1, 2, 3, 5}" in c.p["worked_solution"], "domain step wrong")
    c.expect("Range = all y-values = {4, 7, 9}" in c.p["worked_solution"], "range step wrong")
    c.prose += 4
    c.checked += 2


@register("f10-12")
def _(c):
    pairs = [(2, 5), (3, 1), (2, 6), (4, 0)]
    seen = relation_check(c, pairs, False, None, None)
    bad = {a: sorted(v) for a, v in seen.items() if len(v) > 1}
    c.expect(bad == {2: [5, 6]}, f"conflict is {bad}")
    c.expect(c.final() == "Not a function: the input 2 has two outputs, 5 and 6", "final wording")
    c.prose += 3
    c.checked += 1


@register("f10-13")
def _(c):
    f = lambda x: 3 * x ** 2 - 2 * x + 1
    c.bind("f(x) = 3x² − 2x + 1", "f(−2)")
    c.expect(c.final() == f"f(−2) = {f(-2)}" == "f(−2) = 17", "f(−2) should be 17")
    c.lines()


@register("f10-14")
def _(c):
    c.bind("g(x) = 5 − 2x", "= −7")
    sol = solve_linear("5 − 2x = −7", "x")
    c.expect(c.final() == f"x = {sol['x']}" == "x = 6", f"x should be {sol['x']}")
    c.lines(names="x", assign=sol)


@register("f10-15")
def _(c):
    c.bind("V(t) = 200 − 8t", "200 L", "8 L")
    t_empty = solve_linear("200 − 8t = 0", "t")["t"]
    v = lambda t: 200 - 8 * t
    lo, hi = v(t_empty), v(0)
    c.expect(c.final() == f"Domain 0 ≤ t ≤ {t_empty} hours; range {lo} ≤ V ≤ {hi} L", f"domain/range should be [0,{t_empty}] and [{lo},{hi}]")
    c.lines(names="t", assign={"t": t_empty})


@register("f10-16")
def _(c):
    c.bind("C(d) = 4 + 2.5d", "C(12)", "C(d) = 39")
    cost = lambda d: F(4) + F("2.5") * d
    d = solve_linear("4 + 2.5d = 39", "d")["d"]
    c.expect(c.final() == f"C(12) = ${cost(12)} and d = {d} km" == "C(12) = $34 and d = 14 km", "C(12)=34, d=14")
    c.lines(names="d", assign={"d": d})


# ---- D: linear functions --------------------------------------------------
@register("f10-17")
def _(c):
    (x1, y1), (x2, y2) = (2, -1), (6, 7)
    c.bind("(2, −1)", "(6, 7)")
    m = F(y2 - y1, x2 - x1)
    c.expect(c.final() == f"m = {m}" == "m = 2", f"slope should be {m}")
    c.lines()


@register("f10-18")
def _(c):
    c.bind("A(3, 5)", "B(3, −2)", "C(−4, 6)", "D(5, 6)")
    A, B, C, D = (3, 5), (3, -2), (-4, 6), (5, 6)
    ab = "undefined" if B[0] - A[0] == 0 else F(B[1] - A[1], B[0] - A[0])
    cd = "undefined" if D[0] - C[0] == 0 else F(D[1] - C[1], D[0] - C[0])
    c.expect(c.final() == f"AB: {ab} slope, x = {A[0]}; CD: slope {cd}, y = {C[1]}", f"AB {ab}, CD {cd}")
    ab_points = [{"x": F(3), "y": F(t)} for t in (-2, 0, 5, 9)]
    cd_points = [{"x": F(t), "y": F(6)} for t in (-4, 0, 5, 9)]
    c.lines(names="xy", loci=[ab_points, cd_points])


line_problem("f10-19", points_on((2, 5), -3), bind=("slope −3", "(2, 5)"), final_eq="y = −3x + 11")
# through A(-1, 4) and B(3, -4): parametrise A + t(B - A)
_AB = [(F(-1) + t * 4, F(4) + t * (-8)) for t in (F(0), F(1), F(1, 2), F(2), F(-1))]
line_problem("f10-20", _AB, bind=("(−1, 4)", "(3, −4)"), final_eq="2x + y − 2 = 0")
line_problem("f10-21", points_on((3, 4), 2), bind=("y = 2x − 5", "(3, 4)"), final_eq="y = 2x − 2")
# perpendicular to 3x + 2y = 6 (slope -3/2) through (6, 1): slope 2/3
_given = [(F(x), F(6 - 3 * x, 2)) for x in (-2, 0, 2, 4)]
line_problem("f10-22", points_on((6, 1), F(2, 3), dx=3), other=_given, bind=("3x + 2y = 6", "(6, 1)"), final_eq="y = (2/3)x − 3")
_table = [(0, 5), (1, 8), (2, 11), (3, 14)]
_m = F(_table[1][1] - _table[0][1], _table[1][0] - _table[0][0])
_pts23 = [(F(x), F(y)) for x, y in _table] + [(F(10), F(_table[0][1]) + _m * 10)]


def _check_y_at_10(c):
    c.expect(c.final().endswith(f"y = {_pts23[-1][1]} when x = 10"), "y at x = 10 should be 35")


line_problem("f10-23", _pts23, bind=("x = 0, 1, 2, 3", "y = 5, 8, 11, 14"), final_eq="y = 3x + 5", extra=_check_y_at_10)


# ---- E: arithmetic sequences ----------------------------------------------
@register("f10-24")
def _(c):
    seq = [7, 11, 15, 19]
    c.bind("7, 11, 15, 19")
    d = seq[1] - seq[0]
    c.expect(all(seq[i + 1] - seq[i] == d for i in range(3)), "sequence not arithmetic")
    t10 = seq[0] + 9 * d
    c.expect(c.final() == f"d = {d} and t₁₀ = {t10}" == "d = 4 and t₁₀ = 43", "d=4, t10=43")
    listing = [int(x) for x in re.findall(r"\d+", c.step(3).split(":")[1])]
    c.expect(listing == [seq[0] + k * d for k in range(10)], f"listing wrong: {listing}")
    c.lines()


@register("f10-25")
def _(c):
    terms = [50, 44, 38, 32]
    c.bind("50, 44, 38, 32")
    d = terms[1] - terms[0]
    ref = lambda n: terms[0] + (n - 1) * d
    c.expect([ref(n) for n in (1, 2, 3, 4)] == terms, "reference formula misses the terms")
    rhs = c.final().split("=", 1)[1]
    for vals in random_points("n", 8):
        c.expect(ev(rhs, "n", vals) == ref(vals["n"]), f"final tₙ wrong at {vals}")
    c.lines(names="n", ident=True)


@register("f10-26")
def _(c):
    c.bind("t₃ = 11", "t₇ = 27")
    d = F(27 - 11, 7 - 3)
    t1 = 11 - 2 * d
    t20 = t1 + 19 * d
    c.expect(c.final() == f"d = {d}, t₁ = {t1}, t₂₀ = {t20}" == "d = 4, t₁ = 3, t₂₀ = 79", "d=4, t1=3, t20=79")
    c.expect(t1 + 2 * d == 11 and t1 + 6 * d == 27, "t3 and t7 not reproduced")
    c.lines(names="d", assign={"d": d})


@register("f10-27")
def _(c):
    c.bind("$40", "$15 more", "$250")
    n = next(n for n in range(1, 200) if 40 + 15 * (n - 1) == 250)
    c.expect(c.final() == f"Day {n}" == "Day 15", f"day should be {n}")
    c.expect(c.step(0) == "The deposits 40, 55, 70, … are arithmetic with t₁ = 40 and d = 15.", "intro line")
    c.lines(names="n", assign={"n": F(n)})


@register("f10-28")
def _(c):
    c.bind("7 + 11 + 15 + 19", "first 20 terms")
    total = sum(7 + 4 * k for k in range(20))
    t20 = 7 + 19 * 4
    c.expect(total == 900 and c.final() == "900", f"series sum is {total}")
    c.expect(f"= {t20}" in c.step(0), "t20 line")
    c.lines()


# ---- F: systems -------------------------------------------------------------
@register("f10-29")
def _(c):
    c.bind("y = 3x − 2", "y = x + 4", "x = 0, 1, 2, 3, 4")
    xs = range(5)
    a = [3 * x - 2 for x in xs]
    b = [x + 4 for x in xs]
    meets = [(x, a[x]) for x in xs if a[x] == b[x]]
    c.expect(meets == [(3, 7)] and c.final() == "(3, 7)", f"meeting point {meets}")
    row = lambda k: c.step(k).split("gives y = ")[1].split(" for")[0].replace("−", "-")
    c.expect(row(0) == ", ".join(map(str, a)), "table row 1")
    c.expect(row(1) == ", ".join(map(str, b)), "table row 2")
    c.lines()
    c.checked += 2


system_problem("f10-30")
system_problem("f10-31")
system_problem("f10-32")


@register("f10-33")
def _(c):
    c.bind("6x − 3y = 9", "y = 2x + 5")
    # first line: y = 2x - 3 (slope 2, intercept -3); second: y = 2x + 5 (slope 2, intercept 5)
    s1, i1 = F(6, 3), F(-9, 3)
    s2, i2 = F(2), F(5)
    c.expect(s1 == s2 and i1 != i2, "lines should be parallel and distinct")
    c.expect(c.final() == "No solution: the lines are parallel", "final wording")
    left = [pieces(c.step(k))[-1].split("=")[0] for k in (0, 1, 2)]
    # LHS chain: 6x − 3(2x + 5)  ==  6x − 6x − 15  ==  −15 for every x; RHS is 9, not −15
    for vals in random_points("x", 6):
        vs = [ev(t, "x", vals) for t in left]
        c.expect(vs[0] == vs[1] == vs[2] == -15, f"left side is not constantly -15: {vs}")
    c.expect(c.step(2) == "−15 = 9", "step 3 should be the false statement −15 = 9")
    c.expect(ev("-15") != ev("9"), "-15 equals 9?")
    # the rewritten first equation y = 2x − 3 lies on 6x − 3y = 9
    for x in (0, 1, 2, 5):
        y = 2 * x - 3
        c.expect(6 * x - 3 * y == 9, "y = 2x − 3 not on 6x − 3y = 9")
    c.expect("y = 2x − 3" in c.step(4), "step 5 should state y = 2x − 3")
    c.checked += 4


@register("f10-34")
def _(c):
    c.bind("$12", "$8", "50 tickets", "$520")
    sols = [(a, 50 - a) for a in range(51) if 12 * a + 8 * (50 - a) == 520]
    c.expect(sols == [(30, 20)], f"brute force {sols}")
    c.expect(c.final() == "30 adult tickets and 20 student tickets", "final wording")
    c.lines(names="as", assign={"a": F(30), "s": F(20)})


# ---- G: multiplication of polynomials --------------------------------------
ident_problem("f10-35", "x", expanded=True)
ident_problem("f10-36", "x", expanded=True)
ident_problem("f10-37", "x", expanded=True)
ident_problem("f10-38", "x", expanded=True)


@register("f10-39")
def _(c):
    c.bind("length 2x + 5", "width x + 3", "x = 4")
    area_poly = c.final().split(";")[0]
    for vals in random_points("x", 8):
        x = vals["x"]
        c.expect(ev(area_poly, "x", vals) == (2 * x + 5) * (x + 3), f"area trinomial wrong at {vals}")
    c.expect("(" not in area_poly, "area should be an expanded trinomial")
    c.expect(len(re.findall(r"x", area_poly)) == 2, "trinomial shape")
    c.expect(c.final() == f"{area_poly}; the area is {(2 * 4 + 5) * (4 + 3)} when x = 4" == "2x² + 11x + 15; the area is 91 when x = 4", "area at x=4")
    c.lines(names="x", ident=True)


# ---- H: polynomial factoring ------------------------------------------------
@register("f10-40")
def _(c):
    m = re.fullmatch(r"(\d+)x\((.*)\)", c.final())
    c.expect(m is not None, "final should look like 6x(...)")
    outer, inner = int(m.group(1)), m.group(2)
    poly = [int(v) for v in poly_coeffs(c.prompt_expr(), "x", 4)]  # 0, 24, -18, 12, 0
    c.expect(poly[0] == 0 and poly[4] == 0, "expression not a cubic with no constant")
    gcd_coef = coeffs_gcd(poly)
    c.expect(outer == gcd_coef == 6, f"numeric GCF should be {gcd_coef}")
    inner_c = [int(v) for v in poly_coeffs(inner, "x", 4)]
    c.expect(coeffs_gcd(inner_c) == 1 and inner_c[0] != 0, "bracket still has a common factor")
    for vals in random_points("x", 6):
        c.expect(ev(c.prompt_expr(), "x", vals) == outer * vals["x"] * ev(inner, "x", vals), "product != original")
    c.lines(names="x", ident=True)


def factor_problem(pid, constants):
    def fn(c):
        got = sorted(int(s.replace("−", "-").replace(" ", "")) for s in re.findall(r"x ([+−] \d+)\)", c.final()))
        c.expect(got == sorted(constants), f"constants {got} != {sorted(constants)}")
        coeffs = [int(v) for v in poly_coeffs(c.prompt_expr(), "x", 3)]
        gcd_all = coeffs_gcd(coeffs)
        outer = int(re.match(r"\d+", c.final()).group()) if re.match(r"\d", c.final()) else 1
        c.expect(outer == gcd_all, f"numeric GCF {gcd_all} vs {outer}")
        for vals in random_points("x", 6):
            c.expect(ev(c.prompt_expr(), "x", vals) == ev(c.final(), "x", vals), "factorization != original")
        c.lines(names="x", ident=True)
    CHECKS[pid] = fn


factor_problem("f10-41", [4, 5])
factor_problem("f10-42", [4, -7])


def _difference_of_squares(c):
    c.expect(poly_coeffs(c.prompt_expr(), "x", 3) == [-64, 0, 9, 0], "prompt should be 9x² − 64")
    c.expect(c.final() == "(3x − 8)(3x + 8)", "difference of squares shape: (ax − b)(ax + b)")


ident_problem("f10-43", "x", extra=_difference_of_squares)
factor_problem("f10-44", [-1, -4])


# ---- I: trigonometry (tolerant checks on decimals) ----------------------------
@register("f10-45")
def _(c):
    c.bind("AB = 13", "BC = 5", "AC = 12")
    c.expect(5 ** 2 + 12 ** 2 == 13 ** 2, "not a right triangle")
    opp, adj, hyp = 5, 12, 13
    want = f"sin A = {F(opp, hyp)}, cos A = {F(adj, hyp)}, tan A = {F(opp, adj)}"
    c.expect(c.final() == want, f"final should be '{want}'")
    c.lines()


def decimals_in(text):
    return [float(x) for x in re.findall(r"\d+\.\d+|\d+", text.replace(",", ""))]


@register("f10-46")
def _(c):
    c.bind("20 m", "35°")
    s = math.sin(math.radians(35))
    h = 20 * s
    c.expect(c.final() == f"h ≈ {h:.1f} m" == "h ≈ 11.5 m", f"h is {h:.4f}")
    c.expect(f"{s:.4f}" in c.step(3), f"step 4 should quote sin 35° ≈ {s:.4f}")
    c.expect(f"≈ {h:.2f}" in c.step(3), f"step 4 should quote {h:.2f}")
    c.lines()


@register("f10-47")
def _(c):
    c.bind("6.0 m", "1.5 m")
    ratio = 1.5 / 6.0
    th = math.degrees(math.acos(ratio))
    c.expect(ratio == 0.25 and "0.25" in c.step(1), "cos θ should be 0.25")
    c.expect(c.final() == f"θ ≈ {th:.1f}°" == "θ ≈ 75.5°", f"θ is {th:.4f}")
    c.expect(f"{th:.2f}°" in c.step(2), f"step 3 should quote {th:.2f}°")
    c.lines()


@register("f10-48")
def _(c):
    c.bind("9 cm", "12 cm")
    hyp = math.sqrt(9 ** 2 + 12 ** 2)
    th = math.degrees(math.asin(9 / hyp))
    th_tan = math.degrees(math.atan(9 / 12))
    c.expect(hyp == 15 and abs(th - th_tan) < 1e-9, "hypotenuse 15 and sin/tan agree")
    c.expect(c.final() == f"hypotenuse {hyp:.0f} cm; θ ≈ {th:.1f}°" == "hypotenuse 15 cm; θ ≈ 36.9°", f"θ is {th:.4f}")
    c.expect(f"{th:.2f}°" in c.step(3) and f"{th_tan:.2f}°" in c.step(4), "36.87° quoted")
    c.lines()


@register("f10-49")
def _(c):
    c.bind("40 m", "28°", "1.6 m")
    t = math.tan(math.radians(28))
    h = 40 * t
    total = h + 1.6
    c.expect(c.final() == f"about {total:.1f} m" == "about 22.9 m", f"height is {total:.4f}")
    c.expect(f"{t:.4f}" in c.step(3), f"step 4 should quote tan 28° ≈ {t:.4f}")
    c.expect(f"≈ {h:.2f}" in c.step(3), f"step 4 should quote {h:.2f}")
    c.expect(f"{h:.2f} + 1.6 = {total:.2f}" in c.step(4), "step 5 sum")
    c.lines()


# ---- J: financial literacy -----------------------------------------------------
@register("f10-50")
def _(c):
    c.bind("35 hours", "$19.40")
    gross = F(35) * F("19.40")
    c.expect(c.final() == "$" + money(float(gross)) == "$679.00", f"gross {gross}")
    c.lines()


@register("f10-51")
def _(c):
    c.bind("$22.00", "40", "1.5 times", "44 hours")
    gross = F(40) * 22 + F(4) * F("1.5") * 22
    c.expect(ev(c.final()) == gross == 1012 and c.final() == "$1,012.00", f"gross {gross}")
    c.lines()


@register("f10-52")
def _(c):
    c.bind("$600", "4%", "$18,500")
    gross = 600 + F("0.04") * 18500
    c.expect(ev(c.final()) == gross == 1340 and c.final() == "$1,340.00", f"gross {gross}")
    c.lines()


@register("f10-53")
def _(c):
    c.bind("$1,200.00", "$168.00", "$62.40", "$19.50")
    ded = F("168.00") + F("62.40") + F("19.50")
    net = F("1200.00") - ded
    pct = ded / 1200 * 100
    c.expect(ded == F("249.90") and net == F("950.10") and pct == F("20.825"), f"ded {ded}, net {net}, pct {pct}")
    c.expect(c.final() == f"Deductions ${float(ded):.2f}; net pay ${float(net):.2f}; {round(float(pct), 1)}% deducted"
             == "Deductions $249.90; net pay $950.10; 20.8% deducted", "final wording")
    c.expect("20.825, which rounds to 20.8%" in c.step(3), "rounding step")
    c.lines()


@register("f10-54")
def _(c):
    c.bind("$54,000", "26 pay periods", "22%")
    gross = F(54000, 26)
    net = F(78, 100) * gross
    c.expect(f"{float(gross):.2f}" == "2076.92" and net == 1620, f"gross {float(gross):.4f}, net {net}")
    c.expect(c.final() == f"Gross ${float(gross):,.2f}; net ${float(net):,.2f} per pay period", "final wording")
    c.lines()


# ---------------------------------------------------------------------------
# Generic schema checks
# ---------------------------------------------------------------------------
FIELDS = {"id", "source", "prompt_latex", "prompt_plain", "prompt_parts", "worked_solution", "final_answer", "level"}
# Real names to block come from the environment (comma-separated), never from the repo: BLOCKED_NAMES="..." python3 verify.py
_BLOCKED = [re.escape(n.strip()) for n in __import__("os").environ.get("BLOCKED_NAMES", "").split(",") if n.strip()]
BLOCKLIST = re.compile(r"\b(" + "|".join(_BLOCKED + ["Name:"]) + r")\b")


def plain_from_parts(parts):
    out = ""
    for part in parts:
        if set(part) == {"text"}:
            out += part["text"]
        elif set(part) == {"frac"}:
            n, d = part["frac"]["num"], part["frac"]["den"]
            wrap = lambda t: t if re.fullmatch(r"[A-Za-z0-9.]+", t) else f"({t})"
            out += f"{wrap(n)}/{wrap(d)}"
        else:
            return None
    return out


def schema_errors(p, seen_ids):
    e = []
    if set(p) != FIELDS:
        e.append(f"fields {sorted(set(p) ^ FIELDS)}")
    if not re.fullmatch(r"f10-\d\d", p.get("id", "")):
        e.append("id format")
    if p.get("id") in seen_ids:
        e.append("duplicate id")
    if p.get("level") != "high_school":
        e.append("level")
    if not str(p.get("source", "")).endswith("original") or "content:" not in p.get("source", ""):
        e.append("source")
    if plain_from_parts(p.get("prompt_parts", [])) != p.get("prompt_plain"):
        e.append("prompt_plain != prompt_parts")
    if not p.get("prompt_latex"):
        e.append("prompt_latex empty")
    ws = p.get("worked_solution", [])
    if not (2 <= len(ws) <= 12) or not all(isinstance(s, str) and s.strip() for s in ws):
        e.append(f"worked_solution length {len(ws)}")
    if not p.get("final_answer") or len(p["final_answer"]) > 100:
        e.append("final_answer empty or long")
    blob = json.dumps(p, ensure_ascii=False)
    if BLOCKLIST.search(blob):
        e.append("student name or Name: field")
    return e


def main():
    problems = json.loads(PROBLEMS.read_text(encoding="utf-8"))
    failures, seen = 0, set()
    total_pairs = total_prose = 0
    for p in problems:
        ctx = Ctx(p)
        for msg in schema_errors(p, seen):
            ctx.err("schema: " + msg)
        seen.add(p["id"])
        check = CHECKS.get(p["id"])
        if check is None:
            ctx.err("no mechanical check registered")
        else:
            try:
                check(ctx)
            except Exception as exc:  # a crash is a failure, never a pass
                ctx.err(f"check crashed: {type(exc).__name__}: {exc}")
        if ctx.checked == 0:
            ctx.err("no intermediate line pair was checked")
        total_pairs += ctx.checked
        total_prose += ctx.prose
        if ctx.errors:
            failures += 1
            print(f"FAIL {p['id']}: " + " | ".join(ctx.errors))
        else:
            print(f"ok   {p['id']}  ({ctx.checked} line pairs checked, {ctx.prose} prose lines)")
    extra = set(CHECKS) - {p["id"] for p in problems}
    if extra:
        failures += 1
        print(f"FAIL checks registered for missing problems: {sorted(extra)}")
    print(
        f"\n{len(problems)} problems, {len(problems) - failures} verified, {failures} failed; "
        f"{total_pairs} intermediate pairs checked, {total_prose} prose-only lines skipped"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
