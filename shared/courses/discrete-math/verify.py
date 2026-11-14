#!/usr/bin/env python3
"""Mechanical verification of shared/courses/discrete-math/problems.json.

Run:  python3 verify.py          (needs: pip install sympy)

Every problem id has one check function below. A check recomputes the answer
independently (itertools brute force, truth-table enumeration, simulation, or
sympy) and then asserts that the key values appear in the problem's
final_answer (and, for some, in worked_solution). For proof problems the check
(a) brute-forces the claim for small cases, (b) verifies the base case and the
inductive-step algebra with sympy, and (c) tests the exact identities used in
the written proof. Exit code 0 only if every check passes.
"""
import itertools
import json
import math
import os
import sys
from fractions import Fraction

import sympy as sp

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEMS = json.load(open(os.path.join(HERE, "problems.json"), encoding="utf-8"))
BY_ID = {p["id"]: p for p in PROBLEMS}

CHECKS = {}      # id -> function
KIND = {}        # id -> "computation" | "proof"


def check(pid, kind="computation"):
    def deco(fn):
        CHECKS[pid] = fn
        KIND[pid] = kind
        return fn
    return deco


def fa_has(pid, *tokens):
    fa = BY_ID[pid]["final_answer"]
    for t in tokens:
        assert t in fa, f"{pid}: final_answer {fa!r} is missing {t!r}"


def ws_has(pid, *tokens):
    ws = "\n".join(BY_ID[pid]["worked_solution"])
    for t in tokens:
        assert t in ws, f"{pid}: worked_solution is missing {t!r}"


def imp(a, b):
    return (not a) or b


TF = [True, False]

# ------------------------------------------------------------------ LOGIC


@check("dm-01")
def _():
    for p, q in itertools.product(TF, TF):
        assert imp(q, p) == imp(not p, not q) == ((not q) or p) == (p or (not q))
    fa_has("dm-01", "q → p", "¬p ∧ q", "≡ ¬p → ¬q")


@check("dm-02")
def _():
    rows = [(p, q, r) for p, q, r in itertools.product(TF, TF, TF) if not imp(p or q, not r)]
    assert sorted(rows) == sorted([(True, True, True), (True, False, True), (False, True, True)])
    assert len(rows) == 3
    fa_has("dm-02", "3 of the 8", "TTT, TFT, FTT")


@check("dm-03")
def _():
    for p, q in itertools.product(TF, TF):
        lhs = imp(p, q) and imp(p, not q)
        assert lhs == (not p)
        assert lhs == (((not p) or q) and ((not p) or (not q))) == ((not p) or (q and not q))


@check("dm-04")
def _():
    nums = range(1, 1000)
    assert all(n % 3 == 0 for n in nums if n % 6 == 0)                       # original true
    assert min(n for n in nums if n % 3 == 0 and n % 6 != 0) == 3            # converse fails at 3
    assert min(n for n in nums if n % 6 != 0 and n % 3 == 0) == 3            # inverse fails at 3
    assert all(n % 6 != 0 for n in nums if n % 3 != 0)                       # contrapositive true
    fa_has("dm-04", "counterexample 3")


@check("dm-05")
def _():
    # witness x = 0: no y satisfies 0*y = 1 (sympy), and every x != 0 does have y = 1/x
    y = sp.symbols("y")
    assert sp.solve(sp.Eq(0 * y, 1), y) == []
    assert all(Fraction(x) * (1 / Fraction(x)) == 1 for x in range(-50, 51) if x != 0)
    fa_has("dm-05", "∃x ∀y (xy ≠ 1)", "x = 0")


def entails(premises, conclusion, nvars):
    bad = []
    for vals in itertools.product(TF, repeat=nvars):
        if all(pr(*vals) for pr in premises) and not conclusion(*vals):
            bad.append(vals)
    return bad


@check("dm-06")
def _():
    prem = [lambda p, q, r: imp(p, q), lambda p, q, r: imp(q, r), lambda p, q, r: not r]
    assert entails(prem, lambda p, q, r: not p, 3) == []
    # intermediate step: hypothetical syllogism p->r
    assert entails(prem[:2], lambda p, q, r: imp(p, r), 3) == []
    fa_has("dm-06", "¬p", "modus tollens")


@check("dm-07")
def _():
    prem = [lambda p, q: imp(p, q), lambda p, q: not p]
    assert entails(prem, lambda p, q: not q, 2) == [(False, True)]
    fa_has("dm-07", "Invalid", "p = F, q = T")


# ------------------------------------------------------------ PROOF METHODS


@check("dm-08", "proof")
def _():
    k, m = sp.symbols("k m", integer=True)
    assert sp.expand((2 * k + 1) + (2 * m + 1) - 2 * (k + m + 1)) == 0
    assert sp.expand((2 * k + 1) * (2 * m + 1) - (2 * (2 * k * m + k + m) + 1)) == 0
    for a in range(-40, 41):
        for b in range(-40, 41):
            if a % 2 and b % 2:
                assert (a + b) % 2 == 0 and (a * b) % 2 == 1


@check("dm-09", "proof")
def _():
    k = sp.symbols("k", integer=True)
    assert sp.expand((2 * k + 1) ** 2 - (2 * (2 * k ** 2 + 2 * k) + 1)) == 0
    assert all((n * n % 2 == 0) <= (n % 2 == 0) for n in range(-1000, 1001))
    assert all(((n * n) % 2 == 1) for n in range(-999, 1000, 2))


@check("dm-10", "proof")
def _():
    k = sp.symbols("k", integer=True)
    assert sp.expand((2 * k + 1) ** 2 - (4 * (k ** 2 + k) + 1)) == 0
    assert {x * x % 4 for x in range(-500, 500)} == {0, 1}
    assert not any(x * x - 2 == 4 * y for x in range(-300, 301) for y in range(-100, 25001) if (x * x - 2) % 4 == 0)
    assert not any((x * x - 2) % 4 == 0 for x in range(-300, 301))


@check("dm-11", "proof")
def _():
    assert 1 < math.log2(3) < 2
    assert not any(2 ** p == 3 ** q for p in range(1, 400) for q in range(1, 400))
    assert all(2 ** p % 2 == 0 for p in range(1, 100)) and all(3 ** q % 2 == 1 for q in range(1, 100))
    assert sp.factorint(2 ** 10) == {2: 10} and sp.factorint(3 ** 7) == {3: 7}


# ------------------------------------------------------------------- SETS


def powerset(s):
    s = list(s)
    return [frozenset(c) for r in range(len(s) + 1) for c in itertools.combinations(s, r)]


@check("dm-12")
def _():
    A = {2, 4, 6, 8, 10}
    B = set(range(1, 5))
    AxB = list(itertools.product(A, B))
    assert len(powerset(A)) == 32 and len(AxB) == 20
    assert sum(1 for _ in itertools.combinations(AxB, 2)) == 190 == math.comb(20, 2)
    fa_has("dm-12", "32", "20", "190")


@check("dm-13")
def _():
    U = set(range(1, 11)); A = {1, 2, 3, 4, 5, 6}; B = {4, 5, 6, 7, 8}; C = {2, 4, 6, 8, 10}
    assert (A | B) & (U - C) == {1, 3, 5, 7}
    assert A ^ B == {1, 2, 3, 7, 8}
    fa_has("dm-13", "{1, 3, 5, 7}", "{1, 2, 3, 7, 8}")


@check("dm-14", "proof")
def _():
    subs = powerset(range(1, 5))
    for A, B, C in itertools.product(subs, repeat=3):
        assert A - (B | C) == (A - B) & (A - C)


@check("dm-15", "proof")
def _():
    subs = powerset(range(1, 5))
    for A, B, C in itertools.product(subs, repeat=3):
        assert A - (B & C) == (A - B) | (A - C)
    # the exact table written in the worked solution
    table = []
    for a, b, c in itertools.product([0, 1], repeat=3):
        lhs = int(a and not (b and c))
        rhs = int((a and not b) or (a and not c))
        assert lhs == rhs
        table.append(f"{a} {b} {c} | {lhs} | {rhs}")
    ws_has("dm-15", *table)


@check("dm-16", "proof")
def _():
    U = frozenset(range(1, 5))
    for A, B in itertools.product(powerset(U), repeat=2):
        assert (A | B) & (A | (U - B)) == A
        assert (B & (U - B)) == frozenset()


# -------------------------------------------------------------- FUNCTIONS


@check("dm-17")
def _():
    f = lambda n: 3 * n + 1
    dom = range(-1000, 1001)
    assert len({f(n) for n in dom}) == len(list(dom))               # injective on the sample
    n = sp.symbols("n")
    assert sp.solve(sp.Eq(3 * n + 1, 2), n) == [sp.Rational(1, 3)]  # 2 has no integer preimage
    assert all(f(n) % 3 == 1 for n in dom)                          # range = 1 mod 3
    fa_has("dm-17", "Injective but not surjective")


@check("dm-18")
def _():
    x, y = sp.symbols("x y", real=True)
    f = x ** 2 - 4 * x + 5
    assert sp.expand(f - ((x - 2) ** 2 + 1)) == 0
    assert sp.solve(sp.diff(f, x), x) == [2] and f.subs(x, 2) == 1
    for yy in [1, 2, 10, sp.Rational(37, 4)]:
        for xx in (2 + sp.sqrt(yy - 1), 2 - sp.sqrt(yy - 1)):
            assert sp.simplify(f.subs(x, xx) - yy) == 0
    assert f.subs(x, 1) == f.subs(x, 3) == 2
    fa_has("dm-18", "[1, ∞)", "f(1) = f(3) = 2")


@check("dm-19")
def _():
    x = sp.symbols("x")
    f = lambda t: 2 * t + 3
    g = lambda t: t ** 2 - 1
    assert sp.expand(f(g(x)) - (2 * x ** 2 + 1)) == 0
    assert sp.expand(g(f(x)) - (4 * x ** 2 + 12 * x + 8)) == 0
    assert f(g(2)) == 9 and g(f(2)) == 48 and g(2) == 3 and f(2) == 7
    fa_has("dm-19", "2x² + 1", "4x² + 12x + 8", "9", "48")


@check("dm-20")
def _():
    x, y = sp.symbols("x y")
    f = lambda t: (2 * t - 1) / (t + 3)
    finv = lambda t: (3 * t + 1) / (2 - t)
    sol = sp.solve(sp.Eq(y, f(x)), x)
    assert len(sol) == 1 and sp.simplify(sol[0] - finv(y)) == 0
    assert sp.simplify(f(finv(y)) - y) == 0
    assert sp.simplify(finv(f(x)) - x) == 0
    assert sp.simplify((2 * (3 * y + 1) - (2 - y)) / ((3 * y + 1) + 3 * (2 - y)) - y) == 0   # line in the written check
    fa_has("dm-20", "(3y + 1)/(2 − y)")


@check("dm-21")
def _():
    f = lambda t: t * t - 3
    assert {f(t) for t in (-2, -1, 0, 1)} == {-3, -2, 1}
    pre = {t for t in range(-100, 101) if f(t) in {-2, 1, 6, 13}}
    assert pre == {-4, -3, -2, -1, 1, 2, 3, 4}
    fa_has("dm-21", "{−3, −2, 1}", "±1", "±4")


@check("dm-22", "proof")
def _():
    for n in range(-2000, 2001):
        fl = math.floor(Fraction(n, 2)); ce = math.ceil(Fraction(n, 2))
        assert fl + ce == n
    k = sp.symbols("k", integer=True)
    assert sp.floor(sp.Rational(1, 2)) + sp.ceiling(sp.Rational(1, 2)) == 1
    assert (k + (k + 1)) - (2 * k + 1) == 0


# --------------------------------------------- SEQUENCES AND SUMMATION


@check("dm-23")
def _():
    a = [4]
    for _ in range(40):
        a.append(2 * a[-1] - 3)
    assert a[:5] == [4, 5, 7, 11, 19]
    assert all(a[n] == 2 ** n + 3 for n in range(41))
    n = sp.symbols("n")
    assert sp.simplify(2 * (2 ** n + 3) - 3 - (2 ** (n + 1) + 3)) == 0
    fa_has("dm-23", "2ⁿ + 3")


@check("dm-24")
def _():
    k = sp.symbols("k")
    assert sum(3 * i - 2 for i in range(1, 21)) == 590 == sp.summation(3 * k - 2, (k, 1, 20))
    fa_has("dm-24", "590")


@check("dm-25")
def _():
    k = sp.symbols("k")
    assert sum(3 * 2 ** i for i in range(8)) == 765 == sp.summation(3 * 2 ** k, (k, 0, 7)) == 3 * (2 ** 8 - 1)
    fa_has("dm-25", "765")


@check("dm-26", "proof")
def _():
    k, n = sp.symbols("k n", positive=True, integer=True)
    assert sp.simplify(sp.summation(1 / (k * (k + 1)), (k, 1, n)) - n / (n + 1)) == 0
    assert sp.apart(1 / (k * (k + 1)), k) == 1 / k - 1 / (k + 1)
    assert sum(Fraction(1, i * (i + 1)) for i in range(1, 100)) == Fraction(99, 100)
    fa_has("dm-26", "99/100")


# --------------------------------------- ALGORITHMS AND GROWTH OF FUNCTIONS


@check("dm-27", "proof")
def _():
    assert all(3 * n * n + 5 * n + 7 <= 15 * n * n for n in range(1, 20001))
    assert 3 * 1 + 5 + 7 == 15            # tight at n = 1
    fa_has("dm-27", "C = 15", "k = 1")


@check("dm-28")
def _():
    n = sp.symbols("n", positive=True)
    # asymptotic ratios (sympy limits): each function is little-o of the next
    assert sp.limit(100 * n / (n * sp.log(n, 2)), n, sp.oo) == 0
    assert sp.limit(n * sp.log(n, 2) / n ** 3, n, sp.oo) == 0
    assert sp.limit(n ** 3 / 2 ** n, n, sp.oo) == 0
    assert sp.limit(2 ** n / sp.factorial(n), n, sp.oo) == 0
    # numeric log-values at n = 2**200 (where the crossover n log n > 100 n has already happened)
    N = float(2 ** 200)
    vals = {
        "100n": math.log(100) + 200 * math.log(2),
        "nlogn": 200 * math.log(2) + math.log(200),
        "n3": 600 * math.log(2),
        "2n": N * math.log(2),
        "n!": math.lgamma(N + 1),
    }
    order = sorted(vals, key=vals.get)
    assert order == ["100n", "nlogn", "n3", "2n", "n!"], order
    fa_has("dm-28", "100n < n log₂ n < n³ < 2ⁿ < n!")


@check("dm-29")
def _():
    def count(n):
        c = 0
        for i in range(1, n + 1):
            for j in range(i, n + 1):
                c += 1
        return c
    assert all(count(n) == n * (n + 1) // 2 for n in range(1, 60))
    assert count(10) == 55
    fa_has("dm-29", "n(n + 1)/2", "55", "Θ(n²)")


@check("dm-30")
def _():
    def iters(n):
        i, c = 1, 0
        while i < n:
            i *= 2; c += 1
        return c
    assert iters(1000) == 10
    assert all(iters(n) == (n - 1).bit_length() == math.ceil(math.log2(n)) for n in range(2, 5001))
    fa_has("dm-30", "10 iterations", "Θ(log n)")


# ----------------------------------------- DIVISIBILITY / MODULAR ARITHMETIC


@check("dm-31")
def _():
    a, b = 1274, 504
    assert math.gcd(a, b) == 14
    lines = []
    while b:
        q, r = divmod(a, b)
        lines.append(f"{a} = {q}·{b} + {r}")
        a, b = b, r
    assert a == 14
    ws_has("dm-31", *lines)
    fa_has("dm-31", "14")


@check("dm-32")
def _():
    s0, t0, g = sp.gcdex(91, 35)
    assert g == 7 and 91 * s0 + 35 * t0 == 7          # sympy agrees a Bezout pair exists
    assert math.gcd(91, 35) == 7 and 2 * 91 + (-5) * 35 == 7
    assert 21 == 91 - 2 * 35 and 14 == 35 - 21 and 7 == 21 - 14 and 2 * 21 - 35 == 7
    fa_has("dm-32", "= 7", "s = 2", "t = −5")


@check("dm-33")
def _():
    assert [x for x in range(15) if (7 * x) % 15 == 4] == [7]
    assert pow(7, -1, 15) == 13 and 7 * (-2) % 15 == 1 and (13 * 4) % 15 == 7
    fa_has("dm-33", "x ≡ 7 (mod 15)")


@check("dm-34")
def _():
    assert pow(3, 100, 7) == 4 and pow(3, 6, 7) == 1 and 100 == 16 * 6 + 4 and 81 % 7 == 4
    fa_has("dm-34", "≡ 4 (mod 7)")


@check("dm-35", "proof")
def _():
    a, b, c, d, n, k, m = sp.symbols("a b c d n k m", integer=True)
    assert sp.expand((b + n * k) * (d + n * m) - (b * d + n * (b * m + d * k + n * k * m))) == 0
    for modulus in range(2, 9):
        for a_, b_, c_, d_ in itertools.product(range(-9, 10), repeat=4):
            if (a_ - b_) % modulus == 0 and (c_ - d_) % modulus == 0:
                assert (a_ * c_ - b_ * d_) % modulus == 0


@check("dm-36")
def _():
    sols = [x for x in range(35) if x % 5 == 3 and x % 7 == 4]
    assert sols == [18]
    from sympy.ntheory.modular import crt
    assert crt([5, 7], [3, 4]) == (18, 35)
    assert (5 * 3) % 7 == 1
    fa_has("dm-36", "18 (mod 35)")


@check("dm-37")
def _():
    assert divmod(-47, 6) == (-8, 1) and 6 * (-8) + 1 == -47
    assert -47 - 6 * (-7) == -5          # the rejected choice q = -7 gives a negative remainder
    fa_has("dm-37", "q = −8", "r = 1")


# ------------------------------------------------- REPRESENTATION OF INTEGERS


@check("dm-38")
def _():
    assert int("10110110", 2) == 182 == 128 + 32 + 16 + 4 + 2
    assert format(182, "X") == "B6" and int("1011", 2) == 11 and int("0110", 2) == 6 and 11 * 16 + 6 == 182
    fa_has("dm-38", "182", "B6")


@check("dm-39")
def _():
    assert format(2025, "o") == "3751" and format(2025, "b") == "11111101001"
    digits, n = [], 2025
    while n:
        digits.append(n % 8); n //= 8
    assert digits == [1, 5, 7, 3]
    assert "".join(format(int(d), "03b") for d in "3751").lstrip("0") == "11111101001"
    fa_has("dm-39", "3751₈", "11111101001₂")


# ------------------------------------------------------------- INDUCTION


@check("dm-40", "proof")
def _():
    k, n, m = sp.symbols("k n m", integer=True, positive=True)
    rhs = lambda t: t * (t + 1) * (t + 2) / 3
    assert rhs(1) == 2 == 1 * 2                                           # base case
    assert sp.simplify(rhs(m) + (m + 1) * (m + 2) - rhs(m + 1)) == 0       # inductive step algebra
    assert sp.simplify((m + 1) * (m + 2) * (m / 3 + 1) - rhs(m + 1)) == 0  # factored form in the proof
    assert all(sum(i * (i + 1) for i in range(1, t + 1)) == t * (t + 1) * (t + 2) // 3 for t in range(1, 400))


@check("dm-41", "proof")
def _():
    m, t = sp.symbols("m t", integer=True)
    assert 7 ** 0 - 1 == 0
    assert sp.expand(7 * (7 ** m - 1) + 6 - (7 ** (m + 1) - 1)) == 0
    assert sp.expand(7 * (6 * t) + 6 - 6 * (7 * t + 1)) == 0
    assert all((7 ** n - 1) % 6 == 0 for n in range(0, 300))


@check("dm-42", "proof")
def _():
    assert math.factorial(4) == 24 > 2 ** 4 == 16
    assert all(math.factorial(n) > 2 ** n for n in range(4, 300))
    assert math.factorial(3) < 2 ** 3          # shows why the base must be 4
    assert all((m + 1) * 2 ** m > 2 * 2 ** m for m in range(4, 300))


@check("dm-43", "proof")
def _():
    def rep(n):
        return any((n - 4 * a) % 5 == 0 for a in range(n // 4 + 1))
    assert all(rep(n) for n in range(12, 3000))
    assert not rep(11)
    assert 12 == 4 * 3 and 13 == 4 * 2 + 5 and 14 == 4 + 5 * 2 and 15 == 5 * 3
    ws_has("dm-43", "12 = 4·3 + 5·0", "13 = 4·2 + 5·1", "14 = 4·1 + 5·2", "15 = 4·0 + 5·3")


@check("dm-44", "proof")
def _():
    a = {1: 1, 2: 3}
    for i in range(3, 200):
        a[i] = a[i - 1] + 2 * a[i - 2]
    assert all(a[i] * 3 == 2 ** (i + 1) + (-1) ** i for i in a)
    assert (2 ** 2 + (-1)) / 3 == 1 and (2 ** 3 + 1) / 3 == 3                # base cases
    s, p = sp.symbols("s p")      # s = (-1)^n, p = 2^n
    step = (p + (-s)) / 3 + 2 * (p / 2 + s) / 3 - (2 * p + s) / 3             # (-1)^(n-1) = -s, (-1)^(n-2) = s
    assert sp.simplify(step) == 0


@check("dm-45", "proof")
def _():
    m = sp.symbols("m", integer=True)
    assert all(3 ** n >= n * n for n in range(0, 500))
    assert [3 ** n >= n * n for n in (0, 1, 2)] == [True] * 3
    assert sp.expand(3 * m ** 2 - (m + 1) ** 2 - (2 * m ** 2 - 2 * m - 1)) == 0
    assert all(2 * mm ** 2 - 2 * mm - 1 >= 0 for mm in range(2, 500))
    assert 2 * 1 ** 2 - 2 * 1 - 1 == -1 < 0          # the step fails at m = 1 (3*1 < 4)
    assert sp.expand(2 * m ** 2 - 2 * m - 1 - (2 * m * (m - 1) - 1)) == 0      # form used in the written proof
    assert all(2 * mm * (mm - 1) - 1 >= 3 for mm in range(2, 500))


# -------------------------------------------------------------- RECURSION


@check("dm-46")
def _():
    a = [2]
    for _ in range(60):
        a.append(3 * a[-1] + 1)
    assert a[:3] == [2, 7, 22]
    assert all(2 * a[n] == 5 * 3 ** n - 1 for n in range(61))
    n = sp.symbols("n")
    assert sp.simplify(2 * 3 ** n + (3 ** n - 1) / 2 - (5 * 3 ** n - 1) / 2) == 0
    fa_has("dm-46", "(5·3ⁿ − 1)/2")


@check("dm-47")
def _():
    n = sp.symbols("n", integer=True)
    f = sp.Function("f")
    sol = sp.rsolve(f(n) - 5 * f(n - 1) + 6 * f(n - 2), f(n), {f(0): 1, f(1): 4})
    assert sp.simplify(sol - (2 * 3 ** n - 2 ** n)) == 0
    a = [1, 4]
    for _ in range(40):
        a.append(5 * a[-1] - 6 * a[-2])
    assert all(a[i] == 2 * 3 ** i - 2 ** i for i in range(len(a)))
    r = sp.symbols("r")
    assert sp.factor(r ** 2 - 5 * r + 6) == (r - 2) * (r - 3)
    fa_has("dm-47", "2·3ⁿ − 2ⁿ")


@check("dm-48")
def _():
    def brute(n):
        return sum(1 for bits in itertools.product("01", repeat=n) if "00" not in "".join(bits))
    b = {1: 2, 2: 3}
    for i in range(3, 15):
        b[i] = b[i - 1] + b[i - 2]
    assert all(brute(i) == b[i] for i in range(1, 15))
    assert b[6] == 21 and [b[i] for i in (3, 4, 5)] == [5, 8, 13]
    fa_has("dm-48", "b₆ = 21")


@check("dm-49")
def _():
    def T(n):
        return 0 if n == 1 else 2 * T(n // 2) + n
    assert all(T(2 ** k) == k * 2 ** k for k in range(0, 20))
    assert [T(2), T(4), T(8), T(16)] == [2, 8, 24, 64]
    fa_has("dm-49", "n log₂ n", "64")


# ---------------------------------------------------------------- COUNTING


@check("dm-50")
def _():
    letters = sum(1 for _ in itertools.permutations(range(26), 2))
    digits = sum(1 for d in range(1000) if d >= 100)
    assert letters == 650 and digits == 900 and letters * digits == 585000
    fa_has("dm-50", "585 000")


@check("dm-51")
def _():
    word = "STATISTICS"
    assert len(word) == 10 and {c: word.count(c) for c in set(word)} == {"S": 3, "T": 3, "I": 2, "A": 1, "C": 1}
    brute = len(set(itertools.permutations(word)))
    assert brute == 50400 == math.factorial(10) // (6 * 6 * 2)
    fa_has("dm-51", "50 400")


@check("dm-52")
def _():
    people = ["M"] * 7 + ["W"] * 6
    good = sum(1 for c in itertools.combinations(range(13), 5) if sum(1 for i in c if i >= 7) >= 2)
    assert good == 1056 == math.comb(13, 5) - math.comb(7, 5) - 6 * math.comb(7, 4)
    assert math.comb(13, 5) == 1287
    fa_has("dm-52", "1056")


@check("dm-53")
def _():
    N = 300
    assert sum(1 for n in range(1, N + 1) if n % 2 == 0 or n % 3 == 0 or n % 5 == 0) == 220
    assert 150 + 100 + 60 - 50 - 30 - 20 + 10 == 220
    fa_has("dm-53", "220")


@check("dm-54", "proof")
def _():
    U = range(1, 11)
    assert all(any(a + b == 11 for a, b in itertools.combinations(s, 2)) for s in itertools.combinations(U, 6))
    assert sum(1 for _ in itertools.combinations(U, 6)) == 210
    # 5 is not enough, so the bound is sharp
    assert not any(a + b == 11 for a, b in itertools.combinations(range(1, 6), 2))


@check("dm-55")
def _():
    def max_suit_ok(n):    # is there a hand of n cards with <= 2 of every suit?
        return any(max(c) <= 2 for c in itertools.product(range(14), repeat=4) if sum(c) == n)
    assert max_suit_ok(8) and not max_suit_ok(9)
    assert math.ceil(9 / 4) == 3 and math.ceil(8 / 4) == 2
    fa_has("dm-55", "9 cards")


@check("dm-56")
def _():
    x, y = sp.symbols("x y")
    assert sp.Poly(sp.expand((2 * x - y) ** 7), x, y).coeff_monomial(x ** 3 * y ** 4) == 280
    assert math.comb(7, 3) * 8 == 280
    fa_has("dm-56", "280")


@check("dm-57")
def _():
    cnt = sum(1 for t in itertools.product(range(1, 13), repeat=4) if sum(t) == 12)
    assert cnt == 165 == math.comb(11, 3)
    fa_has("dm-57", "165")


@check("dm-58")
def _():
    d = sum(1 for p in itertools.permutations(range(4)) if all(p[i] != i for i in range(4)))
    assert d == 9
    assert 24 - 6 * 4 + 12 - 4 + 1 == 9 and 24 - 12 + 4 - 1 == 15 and 24 - 15 == 9
    fa_has("dm-58", "9 ways")


# ------------------------------------------------------------ PROBABILITY


@check("dm-59")
def _():
    rolls = list(itertools.product(range(1, 7), repeat=2))
    fav = [r for r in rolls if sum(r) == 9 or r[0] == r[1]]
    assert len(rolls) == 36 and len(fav) == 10 and Fraction(len(fav), 36) == Fraction(5, 18)
    fa_has("dm-59", "5/18")


@check("dm-60")
def _():
    deck = [(r, s) for s in range(4) for r in range(13)]
    hands = list(itertools.combinations(deck, 3))
    same = sum(1 for h in hands if len({c[1] for c in h}) == 1)
    assert len(hands) == 22100 and same == 1144 and Fraction(same, len(hands)) == Fraction(22, 425)
    assert abs(22 / 425 - 0.0518) < 5e-5
    fa_has("dm-60", "22/425")


@check("dm-61")
def _():
    strings = list(itertools.product((0, 1), repeat=8))
    e3 = sum(1 for s in strings if sum(s) == 3)
    ge2 = sum(1 for s in strings if sum(s) >= 2)
    assert len(strings) == 256 and e3 == 56 and Fraction(e3, 256) == Fraction(7, 32)
    assert ge2 == 247 and Fraction(ge2, 256) == Fraction(247, 256)
    fa_has("dm-61", "7/32", "247/256")


# --------------------------------------------------------------- RELATIONS


def props(R, A):
    refl = all((a, a) in R for a in A)
    irrefl = all((a, a) not in R for a in A)
    sym = all((b, a) in R for (a, b) in R)
    anti = all(not ((b, a) in R and a != b) for (a, b) in R)
    trans = all((a, d) in R for (a, b) in R for (c, d) in R if b == c)
    return dict(refl=refl, irrefl=irrefl, sym=sym, anti=anti, trans=trans)


@check("dm-62")
def _():
    A = {1, 2, 3, 4}
    R = {(1, 1), (2, 2), (3, 3), (4, 4), (1, 2), (2, 1), (3, 4), (4, 3)}
    p = props(R, A)
    assert p["refl"] and p["sym"] and p["trans"]
    classes = {frozenset(b for b in A if (a, b) in R) for a in A}
    assert classes == {frozenset({1, 2}), frozenset({3, 4})}
    fa_has("dm-62", "equivalence relation", "{1, 2}", "{3, 4}")


@check("dm-63")
def _():
    A = range(1, 61)
    R = {(a, b) for a in A for b in A if b % a == 0}
    p = props(R, A)
    assert p["refl"] and p["anti"] and p["trans"] and not p["sym"]
    fa_has("dm-63", "not symmetric", "partial order")


@check("dm-64")
def _():
    A = [1, 2, 3]
    R = {(1, 2), (2, 3), (3, 1), (3, 3)}
    M = [[int((i, j) in R) for j in A] for i in A]
    assert M == [[0, 1, 0], [0, 0, 1], [1, 0, 1]]
    p = props(R, A)
    assert p == dict(refl=False, irrefl=False, sym=False, anti=True, trans=False)
    fa_has("dm-64", "antisymmetric")
    ws_has("dm-64", "row 1 = [0 1 0]", "row 2 = [0 0 1]", "row 3 = [1 0 1]")


@check("dm-65")
def _():
    A = [1, 2, 3, 4]
    R = {(1, 2), (2, 3), (3, 4)}
    closure = set(R)
    changed = True
    while changed:                      # Warshall-style fixed point
        changed = False
        for (a, b) in list(closure):
            for (c, d) in list(closure):
                if b == c and (a, d) not in closure:
                    closure.add((a, d)); changed = True
    assert closure == {(i, j) for i in A for j in A if i < j} and len(closure) == 6
    fa_has("dm-65", "6 pairs")


# ----------------------------------------------- FSM AND FORMAL LANGUAGES


@check("dm-66")
def _():
    delta = {("q0", "0"): "q1", ("q0", "1"): "q0",
             ("q1", "0"): "q1", ("q1", "1"): "q2",
             ("q2", "0"): "q1", ("q2", "1"): "q0"}

    def run(s):
        q, trace = "q0", ["q0"]
        for ch in s:
            q = delta[(q, ch)]; trace.append(q)
        return q, trace
    for n in range(0, 13):
        for bits in itertools.product("01", repeat=n):
            s = "".join(bits)
            assert (run(s)[0] == "q2") == s.endswith("01")
    assert run("110101")[1] == ["q0", "q0", "q0", "q1", "q2", "q1", "q2"]
    fa_has("dm-66", "110101 is accepted")


@check("dm-67")
def _():
    # enumerate every sentence derivable with up to 12 rule applications
    sentences, frontier = set(), {"S"}
    for _ in range(12):
        nxt = set()
        for f in frontier:
            if "S" in f:
                nxt.add(f.replace("S", "aSb", 1))
                done = f.replace("S", "ab", 1)
                sentences.add(done)
        frontier = nxt
    expected = {"a" * n + "b" * n for n in range(1, 13)}
    assert sentences == expected
    assert "aaabbb" in sentences and "aab" not in sentences
    # the written derivation S => aSb => aaSbb => aaabbb
    d = "S"; d = d.replace("S", "aSb"); assert d == "aSb"; d = d.replace("S", "aSb"); assert d == "aaSbb"
    d = d.replace("S", "ab"); assert d == "aaabbb"
    fa_has("dm-67", "{aⁿbⁿ : n ≥ 1}", "aaabbb is in it", "aab is not")


# ---------------------------------------------------------- GRAPHS AND TREES


@check("dm-68")
def _():
    # sum of degrees = 2E, 3-regular with E = 12 => V = 8; the cube graph Q3 is an example
    assert 2 * 12 // 3 == 8
    verts = list(itertools.product((0, 1), repeat=3))
    edges = {frozenset((u, v)) for u in verts for v in verts if sum(a != b for a, b in zip(u, v)) == 1}
    assert len(verts) == 8 and len(edges) == 12
    assert all(sum(1 for e in edges if v in e) == 3 for v in verts)
    assert [v for v in range(1, 12) if (3 * v) % 2 == 0] == [2, 4, 6, 8, 10]      # 5 is excluded by parity
    assert 3 * 5 == 15 and 15 % 2 == 1
    fa_has("dm-68", "8 vertices", "15")


@check("dm-69")
def _():
    from functools import lru_cache

    @lru_cache(None)
    def shapes(leaves):
        """Return {total_vertices: number_of_shapes} for full binary trees with the given leaves."""
        if leaves == 1:
            return {1: 1}
        out = {}
        for left in range(1, leaves):
            for nl, cl in shapes(left).items():
                for nr, cr in shapes(leaves - left).items():
                    out[nl + nr + 1] = out.get(nl + nr + 1, 0) + cl * cr
        return out
    s = shapes(10)
    assert s == {19: 4862}          # Catalan(9) shapes, every one has 19 vertices
    assert 19 - 10 == 9 and 2 * 9 == 19 - 1
    fa_has("dm-69", "9 internal", "19 vertices")


@check("dm-70")
def _():
    w = {("A", "B"): 4, ("A", "C"): 2, ("B", "C"): 1, ("B", "D"): 5, ("C", "D"): 8, ("C", "E"): 10, ("D", "E"): 2}
    V = "ABCDE"

    def is_spanning_tree(es):
        parent = {v: v for v in V}

        def find(x):
            while parent[x] != x:
                parent[x] = parent[parent[x]]; x = parent[x]
            return x
        for a, b in es:
            ra, rb = find(a), find(b)
            if ra == rb:
                return False
            parent[ra] = rb
        return True
    trees = [es for es in itertools.combinations(w, 4) if is_spanning_tree(es)]
    best = min(sum(w[e] for e in es) for es in trees)
    winners = [set(es) for es in trees if sum(w[e] for e in es) == best]
    assert best == 10 and winners == [{("B", "C"), ("A", "C"), ("D", "E"), ("B", "D")}]
    # Kruskal in the order written in the solution
    order = sorted(w, key=lambda e: (w[e], e))
    assert [w[e] for e in order] == [1, 2, 2, 4, 5, 8, 10]
    fa_has("dm-70", "weight 10")


# ----------------------------------------------------------- STRUCTURE


def structure_checks():
    keys = ["id", "source", "prompt_latex", "prompt_plain", "prompt_parts", "worked_solution", "final_answer", "level"]
    ids = [p["id"] for p in PROBLEMS]
    assert ids == [f"dm-{i:02d}" for i in range(1, len(ids) + 1)], "ids must run dm-01.. with no gaps"
    assert len(set(ids)) == len(ids)
    for p in PROBLEMS:
        assert list(p.keys()) == keys, f"{p['id']}: keys/order differ from shared/problems.json"
        assert p["level"] == "college"
        assert p["source"].endswith(", original"), p["id"]
        assert p["prompt_parts"] == [{"text": p["prompt_plain"]}], f"{p['id']}: prompt_parts must mirror prompt_plain"
        assert 2 <= len(p["worked_solution"]) <= 12, f"{p['id']}: worked_solution has {len(p['worked_solution'])} lines"
        assert all(isinstance(s, str) and s.strip() for s in p["worked_solution"])
        assert p["final_answer"].strip() and len(p["final_answer"]) <= 120, f"{p['id']}: final_answer too long"
        assert "\\" not in p["prompt_plain"] and "\\" not in "".join(p["worked_solution"]), f"{p['id']}: LaTeX leaked into plain text"
        assert "$" not in p["prompt_plain"]
    # same keys as the app's existing file
    ref = json.load(open(os.path.join(HERE, "..", "..", "problems.json"), encoding="utf-8"))
    assert list(ref[0].keys()) == keys, "app problem format changed; update this course file"


def main():
    structure_checks()
    print(f"structure: {len(PROBLEMS)} problems match shared/problems.json format")
    missing = [p["id"] for p in PROBLEMS if p["id"] not in CHECKS]
    extra = [i for i in CHECKS if i not in BY_ID]
    assert not missing and not extra, f"missing checks {missing}, stray checks {extra}"
    failed = []
    for pid in sorted(CHECKS):
        try:
            CHECKS[pid]()
        except Exception as e:      # report every failure, not just the first
            failed.append((pid, repr(e)))
            print(f"FAIL {pid}: {e!r}")
    ok = len(CHECKS) - len(failed)
    comp = sum(1 for i in CHECKS if KIND[i] == "computation")
    proofs = sum(1 for i in CHECKS if KIND[i] == "proof")
    print(f"verified {ok}/{len(CHECKS)} problems ({comp} computational, {proofs} proof) with {len(failed)} failures")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
