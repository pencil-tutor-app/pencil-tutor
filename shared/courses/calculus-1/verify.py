#!/usr/bin/env python3
"""Mechanical check of every problem in problems.json with sympy.

Run (sympy must be importable; no network, no other dependency):

    uv run --with sympy python -I shared/courses/calculus-1/verify.py

Exit code 0 only when every problem has a check and every check passes.

What a check does, per problem:
  1. recomputes the answer from the prompt's own function/numbers with sympy;
  2. recomputes the key intermediate results the worked solution relies on
     (derivatives, critical numbers, the equation a word problem sets up);
  3. asserts that the numbers it proved actually appear in `final_answer`
     (or in `worked_solution`), so the text cannot drift from the math.
"""
import json
import pathlib
import sys

import sympy as sp
from sympy.calculus.util import continuous_domain

HERE = pathlib.Path(__file__).resolve().parent
x, y, t, h, a, c, r, th = sp.symbols("x y t h a c r theta", real=True)
xp = sp.symbols("xp", positive=True)  # positive x, for roots / logs
oo = sp.oo
CHECKS = {}


def check(n):
    def deco(fn):
        CHECKS[f"c1-{n:02d}"] = fn
        return fn
    return deco


# ------------------------------------------------------------------ helpers
def same(u, v, var=x, pts=(0.7, 1.3, 2.9, 4.1)):
    """u and v are the same function: symbolic simplify, else numeric at sample points."""
    if sp.simplify(u - v) == 0:
        return
    for p in pts:
        d = sp.N((u - v).subs(var, p))
        assert abs(d) < 1e-9, f"{u} != {v} at {var}={p}: diff {d}"


def final_has(p, *tokens):
    for tok in tokens:
        assert tok in p["final_answer"], f"final_answer {p['final_answer']!r} lacks {tok!r}"


def steps_have(p, *tokens):
    text = "\n".join(p["worked_solution"])
    for tok in tokens:
        assert tok in text, f"worked_solution lacks {tok!r}"


def val(expr, **subs):
    return sp.nsimplify(sp.simplify(expr.subs(subs)))


R = sp.Rational

# ------------------------------------------------------------------ limits
@check(1)
def _(p):
    f = (x**2 + 5*x + 6) / (x**2 - 9)
    assert sp.cancel(f) == (x + 2) / (x - 3)
    assert sp.limit(f, x, -3) == R(1, 6)
    final_has(p, "1/6")


@check(2)
def _(p):
    f = (sp.sqrt(9 + 2*x) - 3) / x
    same(f, 2 / (sp.sqrt(9 + 2*x) + 3))
    assert sp.limit(f, x, 0) == R(1, 3)
    final_has(p, "1/3")


@check(3)
def _(p):
    f = (1/x - R(1, 2)) / (x - 2)
    same(f, -1 / (2*x))
    assert sp.limit(f, x, 2) == R(-1, 4)
    final_has(p, "−1/4")


@check(4)
def _(p):
    f = sp.Abs(x - 5) / (x**2 - 25)
    assert sp.limit(f, x, 5, "-") == R(-1, 10)
    assert sp.limit(f, x, 5, "+") == R(1, 10)
    same(-1 / (x + 5), f, pts=(4.0, 4.5, 3.0))   # left of 5
    same(1 / (x + 5), f, pts=(5.5, 6.0, 9.0))    # right of 5
    final_has(p, "−1/10", "1/10", "does not exist")


@check(5)
def _(p):
    f = x**2 * sp.cos(5/x)
    for v in (0.5, 0.1, 0.01, -0.3, -0.02):          # the sandwich really holds
        assert -v**2 <= float(f.subs(x, v)) <= v**2
    assert sp.limit(x**2, x, 0) == 0 and sp.limit(-x**2, x, 0) == 0
    assert p["final_answer"] == "0"


@check(6)
def _(p):
    assert sp.limit(4*x - 3, x, 2) == 5 and sp.limit(x**2 + 1, x, 2) == 5
    assert sp.expand((x**2 + 1) - (4*x - 3)) == sp.expand((x - 2)**2)
    assert p["final_answer"] == "5"


@check(7)
def _(p):
    f = (4*x**3 - x) / (2*x**3 + 7*x**2 + 1)
    assert sp.limit(f, x, oo) == 2
    assert p["final_answer"] == "2"


@check(8)
def _(p):
    f = sp.sqrt(9*x**2 + 1) / (2*x - 5)
    assert sp.limit(f, x, oo) == R(3, 2)
    assert sp.limit(f, x, -oo) == R(-3, 2)
    final_has(p, "3/2", "−3/2")


@check(9)
def _(p):
    f = sp.sqrt(xp**2 + 6*xp) - xp
    same(f, 6*xp / (sp.sqrt(xp**2 + 6*xp) + xp), var=xp, pts=(1.5, 10, 100))
    assert sp.limit(6 / (sp.sqrt(1 + 6/xp) + 1), xp, oo) == 3
    assert sp.limit(f, xp, oo) == 3
    assert p["final_answer"] == "3"


@check(10)
def _(p):
    f = (x - 5) / (x - 2)**2
    assert sp.limit(f, x, 2, "+") == -oo and sp.limit(f, x, 2, "-") == -oo
    assert sp.limit(f, x, 2) == -oo
    final_has(p, "−∞")


@check(11)
def _(p):
    f = (x**2 - x - 6) / (x**2 - 5*x + 6)
    assert sp.factor(x**2 - x - 6) == (x - 3)*(x + 2) and sp.factor(x**2 - 5*x + 6) == (x - 2)*(x - 3)
    assert sp.limit(f, x, 3) == 5
    assert (2 - 3)*(2 + 2) == -4
    assert sp.limit(f, x, 2, "+") == oo and sp.limit(f, x, 2, "-") == -oo   # genuine asymptote at x = 2
    final_has(p, "x = 2", "(3, 5)")


@check(12)
def _(p):
    f = 5/x - 3/x**2
    same(f, (5*x - 3) / x**2, pts=(0.3, 2.0))
    assert sp.limit(f, x, 0, "+") == -oo
    final_has(p, "−∞")


# ------------------------------------------------------------------ continuity
@check(13)
def _(p):
    sol = sp.solve(sp.Eq(2*a + 1, 4 - a), a)
    assert sol == [1]
    assert (2*1 + 1) == (2**2 - 1) == 3
    final_has(p, "a = 1")


@check(14)
def _(p):
    f = (x**2 - 1) / (x**2 - 3*x + 2)
    assert sp.factor(x**2 - 3*x + 2) == (x - 1)*(x - 2)
    assert sp.limit(f, x, 1) == -2
    assert {sp.limit(f, x, 2, "+"), sp.limit(f, x, 2, "-")} == {oo, -oo}
    final_has(p, "x = 1 removable", "x = 2 infinite")


@check(15)
def _(p):
    left = lambda v: v + 2          # x < 1
    mid = lambda v: 5 - v           # 1 <= x < 3
    right = lambda v: 2*v - 4       # x >= 3
    assert left(1) == 3 and mid(1) == 4            # jump at 1
    assert mid(1) - left(1) == 1
    assert mid(3) == 2 and right(3) == 2           # continuous at 3
    final_has(p, "x = 1", "jump")


@check(16)
def _(p):
    g = sp.sqrt(x + 2) / (x - 3)
    dom = continuous_domain(g, x, sp.S.Reals)
    want = sp.Union(sp.Interval.Ropen(-2, 3), sp.Interval.open(3, oo))
    assert dom == want, dom
    final_has(p, "[−2, 3)", "(3, ∞)")


@check(17)
def _(p):
    f = sp.exp(x) + x**2 - 4
    assert sp.N(f.subs(x, 1)) < 0 < sp.N(f.subs(x, 2))
    assert abs(sp.N(f.subs(x, 1)) - (sp.E - 3).evalf()) < 1e-12
    final_has(p, "f(1) < 0 < f(2)")
    steps_have(p, "e − 3", "e²")


@check(18)
def _(p):
    g = 2*sp.sin(x) - x**2
    assert sp.N(g.subs(x, 1)) > 0 > sp.N(g.subs(x, 2))
    assert round(float(g.subs(x, 1)), 2) == 0.68 and round(float(g.subs(x, 2)), 2) == -2.18
    final_has(p, "g(1) > 0 > g(2)")


# ------------------------------------------------------------------ definition of the derivative
@check(19)
def _(p):
    f = lambda v: 3*v**2 - 5*v
    quo = sp.expand((f(x + h) - f(x)) / h)
    assert quo == 6*x + 3*h - 5
    assert sp.limit(quo, h, 0) == 6*x - 5 == sp.diff(f(x), x)
    assert sp.expand(f(x + h) - f(x)) == 6*x*h + 3*h**2 - 5*h
    final_has(p, "6x − 5")


@check(20)
def _(p):
    f = lambda v: 1 / (v + 2)
    quo = sp.simplify((f(x + h) - f(x)) / h)
    same(quo, -1 / ((x + h + 2)*(x + 2)), var=x, pts=(0.4, 1.7))
    assert sp.limit(quo, h, 0) == -1 / (x + 2)**2 == sp.diff(f(x), x)
    final_has(p, "−1/(x + 2)²")


@check(21)
def _(p):
    f = sp.sqrt(3*x + 1)
    assert f.subs(x, 5) == 4
    quo = (f - 4) / (x - 5)
    same(quo, 3 / (f + 4), pts=(2.0, 6.0, 9.5))
    assert sp.limit(quo, x, 5) == R(3, 8) == sp.diff(f, x).subs(x, 5)
    final_has(p, "3/8", "y − 4 = (3/8)(x − 5)")


@check(22)
def _(p):
    s = lambda v: 2*v**2 - 6*v
    assert s(1) == -4 and s(3) == 0
    assert R(s(3) - s(1), 2) == 2
    assert sp.expand(s(3 + h) - s(3)) == 6*h + 2*h**2
    assert sp.limit(sp.expand(s(3 + h) - s(3)) / h, h, 0) == 6 == sp.diff(s(t), t).subs(t, 3)
    final_has(p, "2 m/s", "6 m/s")


# ------------------------------------------------------------------ product / quotient
@check(23)
def _(p):
    f = (2*x**2 - x) * (x**3 + 4)
    d = sp.diff(f, x)
    assert sp.expand(d) == 10*x**4 - 4*x**3 + 16*x - 4
    assert sp.expand((4*x - 1)*(x**3 + 4)) == 4*x**4 - x**3 + 16*x - 4
    assert sp.expand((2*x**2 - x)*3*x**2) == 6*x**4 - 3*x**3
    final_has(p, "10x⁴ − 4x³ + 16x − 4")


@check(24)
def _(p):
    f = (3*x - 2) / (x**2 + 1)
    same(sp.diff(f, x), (-3*x**2 + 4*x + 3) / (x**2 + 1)**2)
    assert sp.expand(3*(x**2 + 1) - (3*x - 2)*2*x) == -3*x**2 + 4*x + 3
    final_has(p, "(−3x² + 4x + 3)/(x² + 1)²")


@check(25)
def _(p):
    f = 4*sp.sqrt(xp) - 6/xp**3 + 9*xp**R(2, 3)
    same(sp.diff(f, xp), 2/sp.sqrt(xp) + 18/xp**4 + 6/xp**R(1, 3), var=xp, pts=(0.5, 2.0, 7.0))
    final_has(p, "2/√x + 18/x⁴ + 6/x^(1/3)")


@check(26)
def _(p):
    f = sp.exp(x) * (sp.cos(x) + 2*x)
    same(sp.diff(f, x), sp.exp(x)*(sp.cos(x) - sp.sin(x) + 2*x + 2))
    final_has(p, "eˣ(cos x − sin x + 2x + 2)")


@check(27)
def _(p):
    xx = sp.symbols("xx", real=True)
    f = x*sp.asin(x) + sp.sqrt(1 - x**2)
    same(sp.diff(f, x), sp.asin(x), pts=(-0.8, 0.1, 0.5, 0.9))
    same(sp.diff(sp.sqrt(1 - x**2), x), -x / sp.sqrt(1 - x**2), pts=(-0.8, 0.1, 0.5))
    final_has(p, "arcsin x")


@check(28)
def _(p):
    f = xp**2*sp.log(xp) - xp**2/2
    same(sp.diff(f, xp), 2*xp*sp.log(xp), var=xp, pts=(0.5, 1.7, 6.0))
    same(sp.diff(xp**2*sp.log(xp), xp), 2*xp*sp.log(xp) + xp, var=xp, pts=(0.5, 1.7))
    final_has(p, "2x ln x")


# ------------------------------------------------------------------ chain rule
@check(29)
def _(p):
    f = (x**3 - 2*x + 1)**5
    same(sp.diff(f, x), 5*(x**3 - 2*x + 1)**4*(3*x**2 - 2))
    final_has(p, "5(x³ − 2x + 1)⁴(3x² − 2)")


@check(30)
def _(p):
    f = sp.sin(4*x)**3
    same(sp.diff(f, x), 12*sp.sin(4*x)**2*sp.cos(4*x))
    final_has(p, "12 sin²(4x) cos(4x)")


@check(31)
def _(p):
    f = sp.log(x + sp.sqrt(x**2 + 4))
    same(sp.diff(f, x), 1/sp.sqrt(x**2 + 4))
    same(1 + x/sp.sqrt(x**2 + 4), (sp.sqrt(x**2 + 4) + x)/sp.sqrt(x**2 + 4))
    final_has(p, "1/√(x² + 4)")


# ------------------------------------------------------------------ logarithmic differentiation
@check(32)
def _(p):
    f = xp**sp.cos(xp)
    claimed = f*(sp.cos(xp)/xp - sp.sin(xp)*sp.log(xp))
    same(sp.diff(f, xp), claimed, var=xp, pts=(0.6, 1.9, 4.4))
    final_has(p, "x^(cos x)", "cos x / x − sin x ln x")


@check(33)
def _(p):
    f = xp**2*(xp + 3)**5 / (xp - 1)**3
    assert f.subs(xp, 2) == 12500
    ratio = 2/xp + 5/(xp + 3) - 3/(xp - 1)
    assert ratio.subs(xp, 2) == -1
    assert sp.diff(f, xp).subs(xp, 2) == -12500
    final_has(p, "−12500")


@check(34)
def _(p):
    f = x*sp.exp(-3*x)
    same(sp.diff(f, x), sp.exp(-3*x)*(1 - 3*x))
    same(sp.diff(f, x, 2), (9*x - 6)*sp.exp(-3*x))
    final_has(p, "(9x − 6)e^(−3x)")


# ------------------------------------------------------------------ implicit differentiation
@check(35)
def _(p):
    F = x**2*y + y**3 - 10
    assert F.subs({x: 1, y: 2}) == 0
    d = sp.idiff(F, y, x)
    assert sp.simplify(d - (-2*x*y/(x**2 + 3*y**2))) == 0
    assert d.subs({x: 1, y: 2}) == R(-4, 13)
    final_has(p, "(−4/13)(x − 1)")


@check(36)
def _(p):
    F = x*sp.exp(y) + y - 1
    assert F.subs({x: 0, y: 1}) == 0
    d = sp.idiff(F, y, x)
    assert sp.simplify(d.subs({x: 0, y: 1}) + sp.E) == 0
    final_has(p, "−e")


@check(37)
def _(p):
    F = x**2 + y**2 - 25
    assert F.subs({x: 3, y: 4}) == 0
    d2 = sp.idiff(F, y, x, 2)
    assert d2.subs({x: 3, y: 4}) == R(-25, 64)
    final_has(p, "−25/64")


# ------------------------------------------------------------------ mean value theorem
@check(38)
def _(p):
    f = lambda v: v**3 - 3*v
    slope = R(f(2) - f(0), 2)
    assert slope == 1
    roots = sp.solve(sp.Eq(3*c**2 - 3, 1), c)
    inside = [rt for rt in roots if 0 < rt < 2]
    assert inside == [2/sp.sqrt(3)] or inside == [2*sp.sqrt(3)/3]
    assert abs(float(inside[0]) - 1.155) < 1e-3
    final_has(p, "2/√3")


@check(39)
def _(p):
    f = lambda v: 2*v + 1
    assert f(1) == 3 and f(5) == 11 and sp.diff(2*x + 1, x) == 2
    assert 3 + 2*(5 - 1) == 11
    final_has(p, "11")


# ------------------------------------------------------------------ curve sketching
@check(40)
def _(p):
    f = x**3 - 6*x**2 + 9*x + 1
    d = sp.diff(f, x)
    assert sp.expand(d - 3*(x - 1)*(x - 3)) == 0
    assert sp.solve(d, x) == [1, 3]
    assert [sp.sign(d.subs(x, v)) for v in (0, 2, 4)] == [1, -1, 1]
    assert f.subs(x, 1) == 5 and f.subs(x, 3) == 1
    final_has(p, "(1, 5)", "(3, 1)")


@check(41)
def _(p):
    f = x**4 - 8*x**3 + 18*x**2
    d2 = sp.diff(f, x, 2)
    assert sp.expand(d2 - 12*(x - 1)*(x - 3)) == 0
    assert [sp.sign(d2.subs(x, v)) for v in (0, 2, 4)] == [1, -1, 1]
    assert f.subs(x, 1) == 11 and f.subs(x, 3) == 27
    final_has(p, "(1, 11)", "(3, 27)")


@check(42)
def _(p):
    f = 2*x**3 - 9*x**2 + 12*x
    d = sp.diff(f, x)
    assert sp.expand(d - 6*(x - 1)*(x - 2)) == 0
    crit = [v for v in sp.solve(d, x) if 0 <= v <= 3]
    values = {v: f.subs(x, v) for v in crit + [0, 3]}
    assert values == {1: 5, 2: 4, 0: 0, 3: 9}
    assert max(values.values()) == 9 and min(values.values()) == 0
    final_has(p, "9 at x = 3", "0 at x = 0")


@check(43)
def _(p):
    f = 2*x**2 / (x**2 - 4)
    assert sp.limit(f, x, oo) == 2 and sp.limit(f, x, -oo) == 2
    assert sp.limit(f, x, 2, "+") == oo and sp.limit(f, x, -2, "-") == oo
    d = sp.diff(f, x)
    same(d, -16*x / (x**2 - 4)**2)
    assert sp.sign(d.subs(x, -1)) == 1 and sp.sign(d.subs(x, 1)) == -1 \
        and sp.sign(d.subs(x, 3)) == -1 and sp.sign(d.subs(x, -3)) == 1
    final_has(p, "x = ±2", "y = 2", "(0, 0)")


@check(44)
def _(p):
    f = x*sp.exp(-x)
    d, d2 = sp.diff(f, x), sp.diff(f, x, 2)
    same(d, sp.exp(-x)*(1 - x))
    same(d2, sp.exp(-x)*(x - 2))
    assert sp.solve(d, x) == [1] and sp.solve(d2, x) == [2]
    assert f.subs(x, 1) == sp.exp(-1) and sp.simplify(f.subs(x, 2) - 2*sp.exp(-2)) == 0
    assert sp.limit(f, x, oo) == 0
    final_has(p, "(1, 1/e)", "(2, 2/e²)")


# ------------------------------------------------------------------ L'Hopital
@check(45)
def _(p):
    f = (sp.exp(3*x) - 1 - 3*x) / x**2
    assert sp.limit(f, x, 0) == R(9, 2)
    assert sp.limit((3*sp.exp(3*x) - 3) / (2*x), x, 0) == R(9, 2)
    assert (9*sp.exp(3*x) / 2).subs(x, 0) == R(9, 2)
    final_has(p, "9/2")


@check(46)
def _(p):
    f = sp.sqrt(xp)*sp.log(xp)
    assert sp.limit(f, xp, 0, "+") == 0
    same((1/xp) / (-R(1, 2)*xp**R(-3, 2)), -2*sp.sqrt(xp), var=xp, pts=(0.3, 2.0))
    assert p["final_answer"] == "0"


@check(47)
def _(p):
    f = sp.cos(x)**(1/x**2)
    assert sp.limit(sp.log(sp.cos(x)) / x**2, x, 0) == R(-1, 2)
    assert sp.limit(-sp.tan(x) / (2*x), x, 0) == R(-1, 2)
    assert (-sp.sec(x)**2 / 2).subs(x, 0) == R(-1, 2)
    assert sp.limit(f, x, 0) == sp.exp(R(-1, 2))
    final_has(p, "e^(−1/2)")


# ------------------------------------------------------------------ Newton's method
def newton(f, x1, steps):
    out, cur = [], sp.Rational(x1)
    for _ in range(steps):
        cur = sp.nsimplify(cur - f(cur) / sp.diff(f(x), x).subs(x, cur))
        out.append(cur)
    return out


@check(48)
def _(p):
    f = lambda v: v**3 + v - 3
    x2, x3 = newton(f, 1, 2)
    assert x2 == R(5, 4) and x3 == R(17, 14)
    assert f(R(5, 4)) == R(13, 64) and sp.diff(f(x), x).subs(x, R(5, 4)) == R(91, 16)
    assert abs(float(x3) - 1.2143) < 1e-4
    root = sp.nsolve(f(x), x, 1.2)
    assert abs(float(x3) - float(root)) < 1e-3
    final_has(p, "5/4", "17/14")


@check(49)
def _(p):
    f = lambda v: v**2 - 7
    x2, x3 = newton(f, 3, 2)
    assert x2 == R(8, 3) and x3 == R(127, 48)
    assert abs(float(x3) - float(sp.sqrt(7))) < 1e-4
    final_has(p, "8/3", "127/48")


# ------------------------------------------------------------------ optimization
@check(50)
def _(p):
    A = x*(240 - 3*x)
    crit = sp.solve(sp.diff(A, x), x)
    assert crit == [40] and sp.diff(A, x, 2) < 0
    assert 240 - 3*40 == 120 and A.subs(x, 40) == 4800
    # brute force over the whole domain agrees with the calculus answer
    best = max(range(1, 80), key=lambda k: k*(240 - 3*k))
    assert best == 40
    final_has(p, "40 m by 120 m", "4800")


@check(51)
def _(p):
    V = x*(30 - 2*x)**2
    d = sp.diff(V, x)
    assert sp.factor(d) == sp.factor((30 - 2*x)*(30 - 6*x))
    crit = [v for v in sp.solve(d, x) if 0 < v < 15]
    assert crit == [5] and sp.diff(V, x, 2).subs(x, 5) < 0
    assert V.subs(x, 5) == 2000
    final_has(p, "x = 5", "2000")


@check(52)
def _(p):
    hh = 128 / r**2
    assert sp.simplify(sp.pi*r**2*hh - 128*sp.pi) == 0
    S = 2*sp.pi*r**2 + 2*sp.pi*r*hh
    same(S, 2*sp.pi*r**2 + 256*sp.pi/r, var=r, pts=(1.5, 4.0))
    crit = [v for v in sp.solve(sp.diff(S, r), r) if v.is_real and v > 0]
    assert crit == [4]
    assert hh.subs(r, 4) == 8 and sp.diff(S, r, 2).subs(r, 4) > 0
    assert S.subs(r, 4) == 96*sp.pi
    final_has(p, "r = 4", "h = 8", "96π")


@check(53)
def _(p):
    D = x**2 + (x**2 - 3)**2
    assert sp.expand(D) == x**4 - 5*x**2 + 9
    crit = sp.solve(sp.diff(D, x), x)
    assert set(crit) == {0, sp.sqrt(R(5, 2)), -sp.sqrt(R(5, 2))}
    assert D.subs(x, sp.sqrt(R(5, 2))) == R(11, 4) and D.subs(x, 0) == 9
    assert sp.sqrt(R(11, 4)) == sp.sqrt(11)/2
    assert sp.sqrt(R(5, 2))**2 == R(5, 2)
    grid = [i/1000 for i in range(-3000, 3001)]
    best = min(grid, key=lambda v: float(D.subs(x, v)))
    assert abs(abs(best) - float(sp.sqrt(R(5, 2)))) < 2e-3
    final_has(p, "√(5/2), 5/2", "√11/2")


# ------------------------------------------------------------------ linear approximation
@check(54)
def _(p):
    f = xp**R(1, 3)
    fp = sp.diff(f, xp).subs(xp, 64)
    assert f.subs(xp, 64) == 4 and fp == R(1, 48)
    L = 4 + fp*(67 - 64)
    assert L == R(65, 16) and float(L) == 4.0625
    assert abs(float(67**(1/3)) - 4.0615) < 1e-4
    final_has(p, "4.0625")


@check(55)
def _(p):
    V = R(4, 3)*sp.pi*r**3
    dV = sp.diff(V, r).subs(r, 10) * R(1, 10)
    assert dV == 40*sp.pi and abs(float(dV) - 125.7) < 0.05
    assert V.subs(r, 10) == 4000*sp.pi/3
    assert dV / V.subs(r, 10) == R(3, 100)
    final_has(p, "40π", "3%")


@check(56)
def _(p):
    f = sp.tan(x)
    assert f.subs(x, sp.pi/4) == 1 and sp.diff(f, x).subs(x, sp.pi/4) == 2
    L = 1 + 2*(0.8 - float(sp.pi/4))
    assert abs(L - 1.0292) < 1e-4 and abs(float(sp.tan(0.8)) - 1.0296) < 1e-4
    final_has(p, "1 + 2(x − π/4)", "1.029")


# ------------------------------------------------------------------ related rates
@check(57)
def _(p):
    yy = sp.sqrt(169 - x**2)            # top height as a function of bottom distance
    assert yy.subs(x, 5) == 12
    dydt = sp.diff(yy, x).subs(x, 5) * R(1, 2)     # dx/dt = 0.5 m/s
    assert dydt == R(-5, 24)
    # same answer from the differentiated equation 2x x' + 2y y' = 0
    assert sp.solve(sp.Eq(5*R(1, 2) + 12*sp.Symbol("v"), 0), sp.Symbol("v")) == [R(-5, 24)]
    final_has(p, "5/24")


@check(58)
def _(p):
    hh = sp.Symbol("hh", positive=True)
    rad = hh / 2
    V = sp.pi*rad**2*hh/3
    same(V, sp.pi*hh**3/12, var=hh, pts=(1.0, 4.0))
    dVdh = sp.diff(V, hh)
    same(dVdh, sp.pi*hh**2/4, var=hh, pts=(1.0, 4.0))
    rate = sp.solve(sp.Eq(2, dVdh.subs(hh, 4)*sp.Symbol("w")), sp.Symbol("w"))
    assert rate == [1/(2*sp.pi)] and abs(float(rate[0]) - 0.159) < 1e-3
    final_has(p, "1/(2π)")


@check(59)
def _(p):
    s = sp.sqrt(x**2 + 9)
    assert s.subs(x, 4) == 5
    dsdt = sp.diff(s, x).subs(x, 4) * (-400)
    assert dsdt == -320
    final_has(p, "320")


@check(60)
def _(p):
    s, X = sp.symbols("s X", positive=True)
    sol = sp.solve(sp.Eq(s/R(18, 10), (X + s)/5), s)[0]
    assert sp.simplify(sol - R(9, 16)*X) == 0
    assert R(9, 16)*R(12, 10) == R(27, 40) and float(R(27, 40)) == 0.675
    final_has(p, "0.675", "27/40")


# ------------------------------------------------------------------ velocity / acceleration / antiderivatives
@check(61)
def _(p):
    s = t**3 - 9*t**2 + 15*t
    v = sp.diff(s, t)
    assert sp.expand(v - 3*(t - 1)*(t - 5)) == 0
    rest = [rt for rt in sp.solve(v, t) if rt >= 0]
    assert rest == [1, 5]
    a_ = sp.diff(s, t, 2)
    assert sp.expand(a_ - (6*t - 18)) == 0 and a_.subs(t, 1) == -12 and a_.subs(t, 5) == 12
    final_has(p, "t = 1", "t = 5", "−12", "12")


@check(62)
def _(p):
    a_ = 6*t - 4
    s = t**3 - 2*t**2 + 5*t + 2
    v = sp.diff(s, t)
    assert sp.expand(v - (3*t**2 - 4*t + 5)) == 0
    assert sp.diff(v, t) == a_ and v.subs(t, 0) == 5 and s.subs(t, 0) == 2
    final_has(p, "t³ − 2t² + 5t + 2")


# ------------------------------------------------------------------ parametric
@check(63)
def _(p):
    X, Y = t**2 + 1, t**3 - 3*t
    slope = sp.diff(Y, t) / sp.diff(X, t)
    assert slope.subs(t, 2) == R(9, 4)
    assert (X.subs(t, 2), Y.subs(t, 2)) == (5, 2)
    final_has(p, "9/4", "y − 2 = (9/4)(x − 5)")


@check(64)
def _(p):
    X, Y = t**3 - 3*t, t**2 - 4*t
    dx, dy = sp.diff(X, t), sp.diff(Y, t)
    horiz = [(X.subs(t, v), Y.subs(t, v)) for v in sp.solve(dy, t) if dx.subs(t, v) != 0]
    vert = [(X.subs(t, v), Y.subs(t, v)) for v in sp.solve(dx, t) if dy.subs(t, v) != 0]
    assert horiz == [(2, -4)]
    assert sorted(vert) == [(-2, -3), (2, 5)]
    final_has(p, "(2, −4)", "(−2, −3)", "(2, 5)")


@check(65)
def _(p):
    X, Y = t**2, t**3 - 3*t
    dydx = sp.diff(Y, t) / sp.diff(X, t)
    d2 = sp.diff(dydx, t) / sp.diff(X, t)
    same(d2, 3*(t**2 + 1) / (4*t**3), var=t, pts=(0.5, 1.0, 2.5))
    assert d2.subs(t, 1) == R(3, 2)
    final_has(p, "3/2")


# ------------------------------------------------------------------ polar
def polar_slope(rr, theta0):
    rp = sp.diff(rr, th)
    num = rp*sp.sin(th) + rr*sp.cos(th)
    den = rp*sp.cos(th) - rr*sp.sin(th)
    pt = (sp.simplify((rr*sp.cos(th)).subs(th, theta0)), sp.simplify((rr*sp.sin(th)).subs(th, theta0)))
    return sp.simplify((num/den).subs(th, theta0)), pt


@check(66)
def _(p):
    m, pt = polar_slope(2 + sp.cos(th), sp.pi/2)
    assert m == R(1, 2) and pt == (0, 2)
    final_has(p, "1/2", "y = 2 + x/2")


@check(67)
def _(p):
    m, pt = polar_slope(4*sp.cos(th), sp.pi/3)
    assert sp.simplify(m - 1/sp.sqrt(3)) == 0 and pt == (1, sp.sqrt(3))
    # Cartesian cross-check: r = 4cos(theta) is the circle (x-2)^2 + y^2 = 4
    X, Y = sp.symbols("X Y", real=True)
    circle = (X - 2)**2 + Y**2 - 4
    assert circle.subs({X: 1, Y: sp.sqrt(3)}) == 0
    slope = sp.idiff(circle, Y, X).subs({X: 1, Y: sp.sqrt(3)})
    assert sp.simplify(slope - 1/sp.sqrt(3)) == 0
    final_has(p, "1/√3", "(1, √3)")


# ------------------------------------------------------------------ antiderivatives
@check(68)
def _(p):
    f = 6*xp**2 - 4/xp**3 + 5*sp.sqrt(xp)
    F = 2*xp**3 + 2/xp**2 + R(10, 3)*xp**R(3, 2)
    same(sp.diff(F, xp), f, var=xp, pts=(0.5, 2.0, 5.0))
    final_has(p, "2x³ + 2/x² + (10/3)x^(3/2) + C")


@check(69)
def _(p):
    f = 3*sp.sin(x) - 4/(1 + x**2) + 2*sp.exp(x)
    F = -3*sp.cos(x) - 4*sp.atan(x) + 2*sp.exp(x)
    same(sp.diff(F, x), f)
    final_has(p, "−3 cos x − 4 arctan x + 2eˣ + C")


@check(70)
def _(p):
    f = x**3 + 2*x**2 - 4*x + 2
    assert sp.expand(sp.diff(f, x, 2) - (6*x + 4)) == 0
    assert sp.diff(f, x).subs(x, 1) == 3 and f.subs(x, 0) == 2
    assert sp.expand(sp.diff(f, x) - (3*x**2 + 4*x - 4)) == 0
    final_has(p, "x³ + 2x² − 4x + 2")


# ------------------------------------------------------------------ driver
FIELDS = {"id", "source", "prompt_latex", "prompt_plain", "prompt_parts", "worked_solution", "final_answer", "level"}


def check_format(problems):
    """The bank's own shape (matches shared/problems.json and server/README.md)."""
    seen = set()
    for p in problems:
        assert set(p) == FIELDS, f"{p.get('id')}: fields {sorted(set(p) ^ FIELDS)}"
        assert p["id"] not in seen, f"duplicate id {p['id']}"
        seen.add(p["id"])
        assert p["level"] == "college" and p["source"].endswith(", original")
        assert p["prompt_plain"] and p["prompt_latex"] and p["final_answer"]
        assert len(p["worked_solution"]) >= 3 and all(isinstance(s, str) and s for s in p["worked_solution"])
        assert p["prompt_parts"], p["id"]
        for part in p["prompt_parts"]:
            assert part.keys() in ({"text"}, {"frac"}), f"{p['id']}: bad part {part}"
            if "frac" in part:
                assert set(part["frac"]) == {"num", "den"}
    return len(seen)


def main():
    problems = json.loads((HERE / "problems.json").read_text(encoding="utf-8"))
    n = check_format(problems)
    print(f"format ok: {n} problems")
    missing = [p["id"] for p in problems if p["id"] not in CHECKS]
    extra = [k for k in CHECKS if k not in {p["id"] for p in problems}]
    failed, passed = [], 0
    for p in problems:
        fn = CHECKS.get(p["id"])
        if fn is None:
            continue
        try:
            fn(p)
            passed += 1
        except Exception as exc:  # report every failure, do not stop at the first
            failed.append((p["id"], f"{type(exc).__name__}: {exc}"))
    print(f"verified {passed} of {len(problems)}")
    for pid, why in failed:
        print(f"FAIL {pid}: {why}")
    if missing:
        print("NO CHECK for:", ", ".join(missing))
    if extra:
        print("CHECK without problem:", ", ".join(extra))
    return 0 if not failed and not missing and not extra else 1


if __name__ == "__main__":
    sys.exit(main())
