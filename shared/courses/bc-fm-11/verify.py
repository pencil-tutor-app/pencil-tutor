#!/usr/bin/env python3
"""Single source of truth and mechanical verifier for the course problem bank.

Run:   python3 -I verify.py            verify problems.json against this file (exit 1 on any failure)
       python3 -I verify.py --write    regenerate problems.json from this file, then verify

Needs sympy (pip install sympy). Every problem below carries its own check function that recomputes the answer
with sympy / fractions / brute force and compares it to the text of final_answer and the worked solution.
On top of that, two automatic line-by-line checks run on every worked solution:
  - numeric chains such as "2(5) - 4 = 6" must evaluate equal;
  - when a problem declares its roots, every equation line that only uses the variable must hold at a root.
Verified 2026-11-14 onward (see README.md for the dated run).
"""
import json
import math
import os
import re
import sys
from fractions import Fraction

import sympy as sp
from sympy.parsing.sympy_parser import (
    convert_xor,
    implicit_multiplication_application,
    parse_expr,
    standard_transformations,
)

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEMS = []
x, y, z, t, k, n, a, b, c, m, r, h, w, p_, q_ = sp.symbols("x y z t k n a b c m r h w p q")
TRANSFORMS = standard_transformations + (implicit_multiplication_application, convert_xor)
LOCALS = {
    "x": x, "y": y, "z": z, "t": t, "k": k, "n": n, "a": a, "b": b, "c": c, "m": m, "r": r, "h": h, "w": w,
    "p": p_, "q": q_,
    "sqrt": sp.sqrt, "cbrt": sp.cbrt, "root4": lambda v: v ** sp.Rational(1, 4), "pi": sp.pi,
    "sin": sp.sin, "cos": sp.cos, "tan": sp.tan, "ln": sp.log, "log": sp.log, "Abs": sp.Abs,
}


# ---------------------------------------------------------------------------------------------------------------
# text -> sympy
# ---------------------------------------------------------------------------------------------------------------
def _find_close(s, i):
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "(":
            depth += 1
        elif s[j] == ")":
            depth -= 1
            if depth == 0:
                return j
    raise ValueError("unbalanced parentheses in " + s)


def _rewrite_radicals(s, fn_for, wrap):
    """Replace √(..), √5, ∛(..), ∜(..) using wrap(kind, inner); innermost-last so nesting works."""
    while True:
        idx = max(s.rfind("√"), s.rfind("∛"), s.rfind("∜"))
        if idx < 0:
            return s
        sym = s[idx]
        j = idx + 1
        if j < len(s) and s[j] == "(":
            e = _find_close(s, j)
            inner = s[j + 1:e]
        else:
            mm = re.match(r"\d+(?:\.\d+)?|[A-Za-z]", s[j:])
            inner = mm.group(0)
            e = j + len(inner) - 1
        s = s[:idx] + wrap(sym, inner) + s[e + 1:]


def Z(s):
    """Parse plain Unicode math text into a sympy expression."""
    s = s.strip().replace("−", "-").replace("·", "*").replace("×", "*").replace("÷", "/").replace("π", "pi")
    for sup, dig in zip("²³⁴⁵⁶⁷⁸⁹", "23456789"):
        s = s.replace(sup, "**" + dig)
    s = re.sub(r"\^\(([^()]*)\)", r"**(\1)", s).replace("^", "**")
    s = re.sub(r"(?<=\d),(?=\d{3}\b)", "", s)
    s = _rewrite_radicals(s, None, lambda sym, inner: {"√": "sqrt(", "∛": "cbrt(", "∜": "root4("}[sym] + inner + ")")
    return parse_expr(s, local_dict=dict(LOCALS), transformations=TRANSFORMS)


def Zq(s):
    return sp.nsimplify(Z(s))


def to_latex(s):
    s = _rewrite_radicals(
        s, None,
        lambda sym, inner: {"√": "\\sqrt{", "∛": "\\sqrt[3]{", "∜": "\\sqrt[4]{"}[sym] + inner + "}",
    )
    s = re.sub(r"\^\(([^()]*)\)", r"^{\1}", s)
    for u, l in [("²", "^{2}"), ("³", "^{3}"), ("⁴", "^{4}"), ("⁵", "^{5}"), ("⁶", "^{6}"), ("⁷", "^{7}"),
                 ("⁸", "^{8}"), ("⁹", "^{9}"), ("−", "-"), ("≤", "\\le "), ("≥", "\\ge "),
                 ("·", "\\cdot "), ("×", "\\times "), ("÷", "\\div "), ("°", "^{\\circ}"), ("π", "\\pi "),
                 ("θ", "\\theta "), ("±", "\\pm "), ("≠", "\\ne "), ("∞", "\\infty "), ("→", "\\to "),
                 ("≈", "\\approx "), ("∠", "\\angle "), ("△", "\\triangle "), ("∥", "\\parallel ")]:
        s = s.replace(u, l)
    return s


FRAC = re.compile(r"\[\[(.+?)//(.+?)\]\]")


def render(prompt):
    """[[num//den]] marks a stacked fraction. Returns (latex, plain, parts)."""
    parts, plain, latex, pos = [], "", "", 0
    for mt in FRAC.finditer(prompt):
        txt = prompt[pos:mt.start()]
        if txt:
            parts.append({"text": txt})
        num, den = mt.group(1), mt.group(2)
        parts.append({"frac": {"num": num, "den": den}})
        plain += txt
        latex += to_latex(txt)
        wrap = lambda v: "(" + v + ")" if re.search(r"[ +\-−·×÷]", v) else v
        plain += wrap(num) + "/" + wrap(den)
        latex += "\\dfrac{" + to_latex(num) + "}{" + to_latex(den) + "}"
        pos = mt.end()
    tail = prompt[pos:]
    if tail:
        parts.append({"text": tail})
    plain += tail
    latex += to_latex(tail)
    return latex, plain, parts


# ---------------------------------------------------------------------------------------------------------------
# numeric helpers used by checks
# ---------------------------------------------------------------------------------------------------------------
def _num(e, pt):
    try:
        v = complex(sp.N(sp.sympify(e).subs(pt)))
    except Exception:
        return None
    if v != v or abs(v.imag) > 1e-9:
        return None
    return v.real


def equiv(e1, e2):
    """Equal as functions: compare at several positive sample points (symbols shared)."""
    e1 = Z(e1) if isinstance(e1, str) else sp.sympify(e1)
    e2 = Z(e2) if isinstance(e2, str) else sp.sympify(e2)
    syms = sorted(e1.free_symbols | e2.free_symbols, key=str)
    if not syms:
        return abs(complex(sp.N(e1 - e2))) < 1e-9
    good = 0
    for base in (1.37, 2.11, 0.83, 3.29, 4.7, 1.9):
        pt = {s: base + 0.173 * i for i, s in enumerate(syms)}
        v1, v2 = _num(e1, pt), _num(e2, pt)
        if v1 is None or v2 is None:
            continue
        if abs(v1 - v2) > 1e-7 * max(1.0, abs(v1)):
            return False
        good += 1
    return good >= 2


def close(v1, v2, tol=0.051):
    return abs(float(v1) - float(v2)) <= tol


def fin(p):
    return p["final_answer"]


def steps_text(p):
    return " ".join(p["worked_solution"])


def has_final(p, *needles):
    for s in needles:
        assert s in fin(p), f"final_answer missing {s!r}: {fin(p)!r}"


def has_steps(p, *needles):
    blob = steps_text(p)
    for s in needles:
        assert s in blob, f"worked_solution missing {s!r}"


def sol(p):
    """Parse 'x = 3 or x = −2' (also 'x = 3, −2') into a list of sympy values."""
    f = re.split(r"\s\((?=[^)]*(?:extraneous|reject))", fin(p))[0].strip()
    out = []
    for piece in re.split(r"\s+or\s+|\s*;\s*|,\s+(?=[a-z]\s*=)", f):
        out.append(Zq(piece.split("=")[-1]))
    return out


def same_set(got, want):
    got = sorted([sp.nsimplify(v) for v in got], key=lambda v: float(sp.N(v)))
    want = sorted([sp.nsimplify(v) for v in want], key=lambda v: float(sp.N(v)))
    assert len(got) == len(want), f"{got} vs {want}"
    for g, w_ in zip(got, want):
        assert abs(float(sp.N(g - w_))) < 1e-9, f"{got} vs {want}"


def ok_solve(p, eq, var=x, domain=None):
    """final_answer's solution list must equal sympy.solve(eq, var); eq is a sympy Eq or expression == 0."""
    want = sp.solve(eq, var)
    if domain is not None:
        want = [v for v in want if domain(v)]
    same_set(sol(p), want)


# ---------------------------------------------------------------------------------------------------------------
# registering problems
# ---------------------------------------------------------------------------------------------------------------
def add(std, prompt, steps, final, chk, roots=None, var=None):
    latex, plain, parts = render(prompt)
    PROBLEMS.append({
        "record": {
            "id": f"{PREFIX}-{len(PROBLEMS) + 1:02d}",
            "source": f"{std}, original",
            "prompt_latex": latex,
            "prompt_plain": plain,
            "prompt_parts": parts,
            "worked_solution": steps,
            "final_answer": final,
            "level": LEVEL,
        },
        "check": chk,
        "roots": roots,
        "var": var if var is not None else x,
        "std": std,
    })


# ---------------------------------------------------------------------------------------------------------------
# automatic line-by-line checks
# ---------------------------------------------------------------------------------------------------------------
NUMERIC_ONLY = re.compile(r"^[0-9 .+\-−·×÷/()²³⁴⁵⁶⁷⁸⁹√∛∜^π]*$")


def auto_chain_lines(record):
    """Return (checked, failures) for pure-number equality chains inside worked_solution lines."""
    checked, fails = 0, []
    for line in record["worked_solution"]:
        text = re.sub(r"(?<=\d),(?=\d{3}\b)", "", line).replace("✓", "").replace("$", "")
        for chunk in re.split(r"\s+(?:and|so|then)\s+|[;]|\s+\(", text):
            chunk = chunk.strip().rstrip(")").strip()
            if "=" not in chunk or any(sym in chunk for sym in ("≈", "≠", "≤", "≥", "<", ">")):
                continue
            if ":" in chunk:
                chunk = chunk.split(":", 1)[1]
            segs = [s.strip() for s in chunk.split("=")]
            if len(segs) < 2 or not all(s and NUMERIC_ONLY.match(s) for s in segs):
                continue
            try:
                vals = [Zq(s) for s in segs]
            except Exception:
                continue
            checked += 1
            if any(abs(complex(sp.N(v - vals[0]))) > 1e-9 for v in vals[1:]):
                fails.append(f"chain mismatch in {line!r}: {segs}")
    return checked, fails


def auto_root_lines(record, roots, var):
    """For each worked line made only of the variable and numbers, 'L = R [= ...]' must hold at some root."""
    checked, fails = 0, []
    roots = [sp.nsimplify(rt) for rt in roots]
    for line in record["worked_solution"]:
        text = re.sub(r"(?<=\d),(?=\d{3}\b)", "", line).replace("✓", "")
        if any(sym in text for sym in ("≈", "≠", "≤", "≥", "<", ">", "±", "°", ":", " or ", " and ", "so ", "Check")):
            continue
        segs = [s.strip() for s in text.split("=")]
        if len(segs) < 2:
            continue
        try:
            exprs = [Z(s) for s in segs]
        except Exception:
            continue
        if any((e.free_symbols - {var}) for e in exprs):
            continue
        if not any(e.free_symbols for e in exprs):
            continue
        checked += 1
        holds = False
        for rt in roots:
            vals = [complex(sp.N(e.subs(var, rt))) for e in exprs]
            if all(abs(v - vals[0]) < 1e-9 for v in vals[1:]):
                holds = True
                break
        if not holds:
            fails.append(f"line not true at any root {roots}: {line!r}")
    return checked, fails


def schema_checks(records):
    errs, seen = [], set()
    for rec in records:
        i = rec["id"]
        if i in seen:
            errs.append(f"duplicate id {i}")
        seen.add(i)
        for key in ("id", "source", "prompt_latex", "prompt_plain", "prompt_parts", "worked_solution",
                    "final_answer", "level"):
            if not rec.get(key):
                errs.append(f"{i}: empty {key}")
        if rec["level"] != LEVEL:
            errs.append(f"{i}: level {rec['level']}")
        if not (3 <= len(rec["worked_solution"]) <= 14):
            errs.append(f"{i}: {len(rec['worked_solution'])} worked lines")
        if len(rec["final_answer"]) > 140:
            errs.append(f"{i}: final_answer too long")
    return errs


def main():
    write = "--write" in sys.argv
    records = [e["record"] for e in PROBLEMS]
    path = os.path.join(HERE, "problems.json")
    if write:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(records, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print(f"wrote {len(records)} problems to {path}")
    failures = schema_checks(records)
    try:
        on_disk = json.load(open(path, encoding="utf-8"))
    except Exception as exc:
        on_disk = None
        failures.append(f"cannot read problems.json: {exc}")
    if on_disk is not None and on_disk != records:
        failures.append("problems.json differs from the problems defined in verify.py (run with --write)")
    passed, chain_lines, root_lines = 0, 0, 0
    for e in PROBLEMS:
        rec = e["record"]
        errs = []
        try:
            res = e["check"](rec)
            items = list(res) if isinstance(res, (tuple, list)) else [res]
            assert items, "check returned an empty tuple"
            for idx, item in enumerate(items):
                assert item is None or bool(item), f"condition #{idx + 1} in the check is False"
        except Exception as exc:  # noqa: BLE001 - report every failure with its id
            errs.append(f"check failed: {type(exc).__name__}: {exc}")
        cl, cf = auto_chain_lines(rec)
        chain_lines += cl
        errs += cf
        if e["roots"] is not None:
            rl, rf = auto_root_lines(rec, e["roots"], e["var"])
            root_lines += rl
            errs += rf
        if errs:
            for er in errs:
                failures.append(f"{rec['id']}: {er}")
        else:
            passed += 1
    total = len(PROBLEMS)
    print(f"{COURSE}: {passed}/{total} problems passed their check "
          f"({chain_lines} numeric chains and {root_lines} equation lines also checked line by line)")
    per_std = {}
    for e in PROBLEMS:
        per_std.setdefault(e["std"], []).append(e["record"]["id"])
    for std, ids in per_std.items():
        print(f"  {len(ids):3d}  {std}")
    if failures:
        print("FAILURES:")
        for f_ in failures:
            print("  -", f_)
        sys.exit(1)
    print("ALL OK")

# ===============================================================================================================
# BC Foundations of Mathematics 11 problems.
# Standards follow https://curriculum.gov.bc.ca/curriculum/mathematics/11/foundations-of-mathematics
# ===============================================================================================================
COURSE = "BC Foundations of Mathematics 11"
PREFIX = "fm11"
LEVEL = "high_school"
C = "BC Foundations of Mathematics 11 content: "

# ---------------------------------------------------------------- forms of mathematical reasoning
S = C + "forms of mathematical reasoning (inductive and deductive reasoning, proof, counter-examples, logic, game analysis)"


def _r1(p):
    def prime(v):
        return v > 1 and all(v % d for d in range(2, int(v ** 0.5) + 1))
    first_bad = next(i for i in range(0, 100) if not prime(i * i + i + 11))
    assert first_bad == 10 and 10 * 10 + 10 + 11 == 121 == 11 * 11
    has_final(p, "n = 10", "121")


add(S, "A student claims that n² + n + 11 is prime for every whole number n. Test the claim for n = 0, 1, 2, … and look for a counterexample.",
    ["n = 0: 11. n = 1: 13. n = 2: 17. n = 3: 23. n = 4: 31. All are prime so far.",
     "n = 5: 41. n = 6: 53. n = 7: 67. n = 8: 83. n = 9: 101. All prime, so the pattern looks convincing.",
     "n = 10: 10² + 10 + 11 = 121 = 11 · 11, which is not prime.",
     "One counterexample is enough to disprove a claim, however many cases worked."],
    "n = 10 gives 121 = 11 × 11, so the claim is false", _r1)


def _r2(p):
    seq = [n_ ** 2 + 2 * n_ for n_ in range(1, 6)]
    assert seq == [3, 8, 15, 24, 35] and 10 ** 2 + 2 * 10 == 120
    has_final(p, "n² + 2n", "120")


add(S, "Look at the pattern 3, 8, 15, 24, 35, … Find a rule for the nth term and predict the 10th term. Is this a proof?",
    ["First differences: 5, 7, 9, 11. Second differences: 2, 2, 2. A constant second difference points to an n² term with coefficient 1.",
     "Subtract n² from each term: 3 − 1 = 2, 8 − 4 = 4, 15 − 9 = 6, 24 − 16 = 8. That is 2n.",
     "Rule: t_n = n² + 2n. Test n = 5: 25 + 10 = 35, which matches.",
     "10th term: 10² + 2(10) = 100 + 20 = 120.",
     "This is inductive reasoning: a prediction from a pattern. It is not a proof, because the pattern could break later."],
    "t_n = n² + 2n; the 10th term is 120; it is a prediction, not a proof", _r2)


def _r3(p):
    expr = sp.expand(n + (n + 1) + (n + 2))
    assert expr == 3 * n + 3
    assert all(((m_ + (m_ + 1) + (m_ + 2)) % 3 == 0) for m_ in range(-60, 60))
    has_final(p, "3(n + 1)")


add(S, "Prove that the sum of any three consecutive integers is divisible by 3.",
    ["Let the three consecutive integers be n, n + 1 and n + 2, where n is any integer.",
     "Sum: n + (n + 1) + (n + 2) = 3n + 3",
     "Factor: 3n + 3 = 3(n + 1)",
     "n + 1 is an integer, so the sum is 3 times an integer. It is divisible by 3 for every n. ∎"],
    "Sum = 3(n + 1), a multiple of 3, for every integer n", _r3)


def _r4(p):
    assert sp.expand((2 * a + 1) * (2 * b + 1) - (2 * (2 * a * b + a + b) + 1)) == 0
    has_final(p, "2(2ab + a + b) + 1")


add(S, "Prove that the product of two odd integers is always odd.",
    ["Any odd integer can be written 2a + 1, where a is an integer. Let the two odd integers be 2a + 1 and 2b + 1.",
     "Product: (2a + 1)(2b + 1) = 4ab + 2a + 2b + 1",
     "Take a 2 out of the first three terms: 4ab + 2a + 2b + 1 = 2(2ab + a + b) + 1",
     "2ab + a + b is an integer, so the product has the form 2(integer) + 1, which is odd. ∎"],
    "(2a + 1)(2b + 1) = 2(2ab + a + b) + 1, which is odd", _r4)


def _r5(p):
    nums = range(1, 1000)
    assert all(n_ % 3 == 0 for n_ in nums if n_ % 6 == 0)  # original is true
    assert any(n_ % 3 == 0 and n_ % 6 != 0 for n_ in nums) and 9 % 3 == 0 and 9 % 6 != 0  # converse false, 9
    assert all(n_ % 6 != 0 for n_ in nums if n_ % 3 != 0)  # contrapositive true
    has_final(p, "false", "9", "true")


add(S, "Statement: \"If a whole number is divisible by 6, then it is divisible by 3.\" Write the converse and the contrapositive. Decide whether each is true or false, and give a counterexample for any false one.",
    ["Original: if divisible by 6, then divisible by 3. True: 6 = 2 · 3, so any multiple of 6 is a multiple of 3.",
     "Converse (swap the parts): if a whole number is divisible by 3, then it is divisible by 6.",
     "Counterexample: 9 is divisible by 3, but 9 ÷ 6 = 1.5, so 9 is not divisible by 6. The converse is false.",
     "Contrapositive (swap and negate both): if a whole number is not divisible by 3, then it is not divisible by 6.",
     "A multiple of 6 is always a multiple of 3, so a non-multiple of 3 cannot be a multiple of 6. The contrapositive is true (it always has the same truth value as the original)."],
    "Converse: false (counterexample 9). Contrapositive: true", _r5)


def _nim(p):
    from functools import lru_cache

    @lru_cache(None)
    def win(k):  # player to move wins if some move leaves the opponent in a losing position
        return any(not win(k - m_) for m_ in (1, 2, 3) if k - m_ >= 0) if k > 0 else False

    firsts = [m_ for m_ in (1, 2, 3) if not win(21 - m_)]
    assert firsts == [1] and win(21)
    assert all(not win(4 * j) for j in range(0, 6))
    has_final(p, "Take 1 first")


add(S, "Two players take turns removing 1, 2 or 3 counters from a pile of 21. Whoever takes the last counter wins. You go first. What is your winning first move and strategy?",
    ["Work backward. If you leave 4 counters, the opponent takes 1, 2 or 3, and you take the rest (3, 2 or 1) and win.",
     "So 4 is a losing number for whoever must move. The same is true for 8, 12, 16 and 20: each is a multiple of 4.",
     "21 − 20 = 1, so take 1 counter first, leaving 20.",
     "After that, whatever the opponent takes (k), you take 4 − k. Each round removes 4, so the pile goes 20, 16, 12, 8, 4, 0 on your turns.",
     "The other first moves (2 or 3) leave 19 or 18, which are not multiples of 4, so the opponent could use the same strategy against you."],
    "Take 1 first, then always take 4 minus what your opponent took", _nim)


def _magic(p):
    expr = sp.simplify((2 * n + 10) / 2 - n)
    assert expr == 5
    has_final(p, "5")


add(S, "A number trick: pick any number, double it, add 10, halve the result, then subtract your starting number. Show that the answer is always 5.",
    ["Let n be the starting number.",
     "Double it: 2n. Add 10: 2n + 10.",
     "Halve it: (2n + 10) / 2 = n + 5.",
     "Subtract the starting number: n + 5 − n = 5.",
     "The n cancels for every starting number, so the answer is always 5. ∎"],
    "Always 5", _magic)

# ---------------------------------------------------------------- angle relationships
S = C + "angle relationships (parallel lines, triangles, polygons, proofs, constructions)"

add(S, "Lines AB and CD are parallel and are cut by a transversal. Two alternate interior angles measure (2x + 15)° and (3x − 10)°. Find x and the size of the angles.",
    ["Alternate interior angles between parallel lines are equal.",
     "2x + 15 = 3x − 10",
     "25 = x",
     "Each angle: 2(25) + 15 = 65° and 3(25) − 10 = 65°. They match."],
    "x = 25; both angles are 65°", lambda p: (sp.solve(2 * x + 15 - (3 * x - 10), x) == [25], has_final(p, "x = 25", "65°")), roots=[25])

add(S, "Two parallel lines are cut by a transversal. Two co-interior (same-side interior) angles measure (4x − 20)° and (2x + 50)°. Find x and the two angles.",
    ["Co-interior angles between parallel lines are supplementary: they add to 180°.",
     "(4x − 20) + (2x + 50) = 180",
     "6x + 30 = 180",
     "6x = 150, so x = 25",
     "Angles: 4(25) − 20 = 80° and 2(25) + 50 = 100°. Check: 80° + 100° = 180°."],
    "x = 25; the angles are 80° and 100°", lambda p: (sp.solve(4 * x - 20 + 2 * x + 50 - 180, x) == [25], has_final(p, "x = 25", "80°", "100°")),
    roots=[25])

add(S, "In triangle ABC, ∠A = 52° and the exterior angle at C is 125°. Find ∠B and the interior angle ∠C.",
    ["The exterior angle of a triangle equals the sum of the two opposite interior angles: exterior at C = ∠A + ∠B.",
     "125° = 52° + ∠B, so ∠B = 125° − 52° = 73°.",
     "The interior angle at C and the exterior angle at C make a straight line: ∠C = 180° − 125° = 55°.",
     "Check: 52° + 73° + 55° = 180°"],
    "∠B = 73°, ∠C = 55°", lambda p: (125 - 52 == 73 and 180 - 125 == 55 and 52 + 73 + 55 == 180, has_final(p, "73°", "55°")))

add(S, "The angles of a triangle measure x°, (2x + 10)° and (3x − 10)°. Find x and all three angles.",
    ["The angles of a triangle add to 180°.",
     "x + (2x + 10) + (3x − 10) = 180",
     "6x = 180, so x = 30",
     "Angles: 30°, 2(30) + 10 = 70°, and 3(30) − 10 = 80°. Check: 30° + 70° + 80° = 180°."],
    "x = 30; the angles are 30°, 70°, 80°", lambda p: (sp.solve(x + (2 * x + 10) + (3 * x - 10) - 180, x) == [30], has_final(p, "30°", "70°", "80°")),
    roots=[30])

add(S, "Find the sum of the interior angles of a decagon (10 sides). Then find each interior angle of a regular decagon.",
    ["Interior angle sum of an n-sided polygon: (n − 2) × 180°.",
     "n = 10: (10 − 2) × 180° = 8 × 180° = 1440°.",
     "A regular decagon has 10 equal angles: 1440° ÷ 10 = 144°.",
     "Check with exterior angles: 360° ÷ 10 = 36°, and 180° − 36° = 144°."],
    "Sum 1440°; each angle 144°", lambda p: ((10 - 2) * 180 == 1440, 1440 / 10 == 144, 180 - 360 / 10 == 144, has_final(p, "1440°", "144°")))

add(S, "Each exterior angle of a regular polygon is 24°. How many sides does it have, and how large is each interior angle?",
    ["The exterior angles of any polygon add to 360°. A regular polygon has equal exterior angles.",
     "Number of sides = 360° ÷ 24° = 15.",
     "Interior angle = 180° − 24° = 156°.",
     "Check with the sum formula: (15 − 2) × 180° ÷ 15 = 2340° ÷ 15 = 156°."],
    "15 sides; each interior angle is 156°", lambda p: (360 / 24 == 15, 180 - 24 == 156, (15 - 2) * 180 / 15 == 156, has_final(p, "15 sides", "156°")))

add(S, "Four angles of a pentagon are 100°, 110°, 120° and 95°. Find the fifth angle.",
    ["Interior angle sum of a pentagon: (5 − 2) × 180° = 540°.",
     "Known angles: 100° + 110° + 120° + 95° = 425°.",
     "Fifth angle: 540° − 425° = 115°."],
    "115°", lambda p: ((5 - 2) * 180 == 540, 100 + 110 + 120 + 95 == 425, 540 - 425 == 115, has_final(p, "115°")))


def _vert(p):
    a_, b_, c_ = sp.symbols("a_ b_ c_")
    res = sp.solve([a_ + b_ - 180, b_ + c_ - 180], [a_, c_], dict=True)[0]
    assert sp.simplify(res[a_] - res[c_]) == 0
    has_final(p, "a = c")


add(S, "Prove that vertical angles are equal.",
    ["Two straight lines cross and make four angles a, b, c and d in order around the point. Angles a and c are vertical angles.",
     "a + b = 180° because a and b make a straight line.",
     "b + c = 180° because b and c make a straight line.",
     "So a + b = b + c. Subtract b from both sides: a = c. ∎"],
    "a = c, so vertical angles are equal", _vert)


def _tri_sum(p):
    import random
    rnd = random.Random(11)
    for _ in range(200):
        P = [(rnd.uniform(0, 10), rnd.uniform(0, 10)) for _ in range(3)]
        tot = 0.0
        for i in range(3):
            A_, B_, C_ = P[i], P[(i + 1) % 3], P[(i + 2) % 3]
            v1, v2 = (B_[0] - A_[0], B_[1] - A_[1]), (C_[0] - A_[0], C_[1] - A_[1])
            cosv = (v1[0] * v2[0] + v1[1] * v2[1]) / (math.hypot(*v1) * math.hypot(*v2))
            tot += math.degrees(math.acos(max(-1, min(1, cosv))))
        assert abs(tot - 180) < 1e-6
    has_final(p, "180°")


add(S, "Prove that the angles of a triangle add to 180°, using a line through one vertex parallel to the opposite side.",
    ["In triangle ABC, draw a line through A parallel to BC. The line makes an angle x with AB on one side and an angle y with AC on the other.",
     "x = ∠B, because x and ∠B are alternate interior angles between the parallel lines.",
     "y = ∠C, for the same reason, with transversal AC.",
     "The angles x, ∠A and y lie along one straight line, so x + ∠A + y = 180°.",
     "Replace x and y: ∠B + ∠A + ∠C = 180°. ∎"],
    "∠A + ∠B + ∠C = 180°", _tri_sum)

add(S, "Describe how to construct a 75° angle with a compass and straightedge, using only bisectors and equilateral triangles.",
    ["Construct an equilateral triangle. Every angle is 180° ÷ 3 = 60°.",
     "Bisect the 60° angle: 60° ÷ 2 = 30°.",
     "Bisect the 30° angle: 30° ÷ 2 = 15°.",
     "Place the 15° angle next to the 60° angle, sharing a ray: 60° + 15° = 75°."],
    "60° + 15° = 75°", lambda p: (180 / 3 == 60, 60 / 2 == 30, 30 / 2 == 15, 60 + 15 == 75, has_final(p, "75°")))


# ---------------------------------------------------------------- graphical analysis (worked by hand here; the BC standard says technology)
def quad_features(expr):
    f = sp.sympify(expr)
    xv = sp.solve(sp.diff(f, x), x)[0]
    return {"vertex": (xv, sp.simplify(f.subs(x, xv))), "xint": sorted(sp.solve(f, x), key=lambda v: float(sp.N(v))),
            "yint": f.subs(x, 0), "a": sp.Poly(f, x).LC()}


def lp_vertices(cons):
    """cons: list of (a, b, c, '<=' or '>=') meaning a*x + b*y <= c. Returns the feasible corner points."""
    import itertools
    pts = set()
    for (a1, b1, c1, _), (a2, b2, c2, _) in itertools.combinations(cons, 2):
        det = a1 * b2 - a2 * b1
        if det == 0:
            continue
        px = sp.Rational(c1 * b2 - c2 * b1, det)
        py = sp.Rational(a1 * c2 - a2 * c1, det)
        if all((a_ * px + b_ * py <= c_) if s_ == "<=" else (a_ * px + b_ * py >= c_) for a_, b_, c_, s_ in cons):
            pts.add((px, py))
    return pts


def lp_best(cons, obj, mode):
    pts = lp_vertices(cons)
    vals = {pt: obj(*pt) for pt in pts}
    best = (max if mode == "max" else min)(vals.values())
    return best, {pt for pt, v in vals.items() if v == best}, vals


S = C + "graphical analysis: linear inequalities (solution region, slope and intercepts, intersection points)"


def _l1(p):
    # boundary y = 2x - 3 : slope 2, y-intercept -3; (0,0) satisfies y >= 2x - 3; points above satisfy it, below do not
    assert 0 >= 2 * 0 - 3 and (0 >= 2 * 0 - 3)
    assert 5 >= 2 * 1 - 3 and not (-5 >= 2 * 1 - 3)
    has_final(p, "Solid", "y = 2x − 3", "above")


add(S, "Graph the inequality y ≥ 2x − 3. Say what kind of boundary line it has and which side to shade.",
    ["Boundary line y = 2x − 3: the y-intercept is −3 and the slope is 2 (up 2, right 1). Points: (0, −3), (1, −1), (2, 1).",
     "The sign is ≥, which includes the boundary, so draw a solid line.",
     "Test the origin (0, 0): is 0 ≥ 2(0) − 3 = −3? Yes, 0 ≥ −3 is true.",
     "The origin is above the line, so shade above the line."],
    "Solid line y = 2x − 3; shade above it (the side with the origin)", _l1)


def _l2(p):
    assert 3 * 4 + 4 * 0 == 12 and 3 * 0 + 4 * 3 == 12 and 3 * 0 + 4 * 0 < 12
    has_final(p, "Dashed", "(4, 0)", "(0, 3)")


add(S, "Graph 3x + 4y < 12 using its intercepts. Say what kind of boundary line it has and which side to shade.",
    ["x-intercept: set y = 0, so 3x = 12 and x = 4. The point is (4, 0).",
     "y-intercept: set x = 0, so 4y = 12 and y = 3. The point is (0, 3).",
     "The sign is <, which does not include the boundary, so draw a dashed line through (4, 0) and (0, 3).",
     "Test (0, 0): 3(0) + 4(0) = 0 < 12 is true, so shade the side that contains the origin."],
    "Dashed line through (4, 0) and (0, 3); shade the side with the origin", _l2)


def _l3(p):
    sol_ = sp.solve([x + y - 10, 2 * x - y - 2], [x, y])
    assert sol_ == {x: 4, y: 6}
    has_final(p, "(4, 6)")


add(S, "The boundary lines of x + y ≤ 10 and 2x − y ≥ 2 cross at a corner of the solution region. Find that corner point.",
    ["Boundary lines: x + y = 10 and 2x − y = 2.",
     "Add the two equations so y cancels: (x + y) + (2x − y) = 10 + 2, so 3x = 12 and x = 4.",
     "Substitute into x + y = 10: 4 + y = 10, so y = 6.",
     "Check in the other line: 2(4) − 6 = 2 ✓"],
    "(4, 6)", _l3)


def _l4(p):
    def inside(px, py):
        return py < px + 1 and py >= -px + 4
    assert inside(3, 2) and not inside(1, 3) and not inside(2, 1)
    has_final(p, "(3, 2)")


add(S, "Which of the points (3, 2), (1, 3) and (2, 1) satisfy both inequalities y < x + 1 and y ≥ −x + 4?",
    ["Test each point in both inequalities.",
     "(3, 2): 2 < 3 + 1 = 4 true, and 2 ≥ −3 + 4 = 1 true. Both hold.",
     "(1, 3): 3 < 1 + 1 = 2 is false. It fails the first inequality.",
     "(2, 1): 1 < 2 + 1 = 3 true, but 1 ≥ −2 + 4 = 2 is false. It fails the second."],
    "Only (3, 2)", _l4)

S = C + "graphical analysis: quadratic functions (end behaviour, vertex, maximum/minimum, symmetry, intercepts)"


def _fq1(p):
    f = quad_features(-x ** 2 + 6 * x - 5)
    assert f["vertex"] == (3, 4) and f["xint"] == [1, 5] and f["yint"] == -5 and f["a"] < 0
    has_final(p, "Opens down", "(3, 4)", "maximum", "x = 3", "x-intercepts 1, 5", "y-intercept −5")


add(S, "Analyse y = −x² + 6x − 5: end behaviour, axis of symmetry, vertex, maximum or minimum, and intercepts.",
    ["a = −1 < 0, so the parabola opens down. Both ends go down: as x → ±∞, y → −∞.",
     "Axis of symmetry: x = −b / (2a) = −6 / (−2) = 3.",
     "Vertex: y = −(3)² + 6(3) − 5 = −9 + 18 − 5 = 4, so (3, 4). It is the maximum value, 4.",
     "x-intercepts: −x² + 6x − 5 = 0, so x² − 6x + 5 = 0 and (x − 1)(x − 5) = 0, giving x = 1 and x = 5.",
     "y-intercept: set x = 0, so y = −5."],
    "Opens down; vertex (3, 4) is a maximum; axis x = 3; x-intercepts 1, 5; y-intercept −5", _fq1)


def _fq2(p):
    f = quad_features(2 * x ** 2 - 4 * x - 6)
    assert f["vertex"] == (1, -8) and f["xint"] == [-1, 3] and f["yint"] == -6 and f["a"] > 0
    has_final(p, "Opens up", "(1, −8)", "minimum", "x = 1", "x-intercepts −1, 3", "y-intercept −6")


add(S, "Analyse y = 2x² − 4x − 6: end behaviour, axis of symmetry, vertex, maximum or minimum, and intercepts.",
    ["a = 2 > 0, so the parabola opens up. Both ends go up: as x → ±∞, y → +∞.",
     "Axis of symmetry: x = −(−4) / (2 · 2) = 4/4 = 1.",
     "Vertex: y = 2(1)² − 4(1) − 6 = 2 − 4 − 6 = −8, so (1, −8). It is the minimum value, −8.",
     "x-intercepts: 2x² − 4x − 6 = 0, divide by 2: x² − 2x − 3 = 0, so (x − 3)(x + 1) = 0, giving x = 3 and x = −1.",
     "y-intercept: set x = 0, so y = −6."],
    "Opens up; vertex (1, −8) is a minimum; axis x = 1; x-intercepts −1, 3; y-intercept −6", _fq2)


def _fq3(p):
    fx = -x * (x - 6)
    f = quad_features(fx)
    assert f["vertex"] == (3, 9) and f["xint"] == [0, 6]
    assert sp.expand(fx) == -x ** 2 + 6 * x
    has_final(p, "y = −x² + 6x")


add(S, "A parabola opens down, has x-intercepts 0 and 6, and has a maximum value of 9. Find its equation.",
    ["The axis of symmetry is halfway between the intercepts: x = (0 + 6) / 2 = 3, so the vertex is (3, 9).",
     "Use factored form with the intercepts: y = a(x − 0)(x − 6) = ax(x − 6).",
     "Substitute the vertex (3, 9): 9 = a(3)(3 − 6) = a(3)(−3) = −9a, so a = −1.",
     "y = −x(x − 6) = −x² + 6x. Check the sign: a < 0, so it opens down ✓."],
    "y = −x² + 6x", _fq3)


def _fq4(p):
    fx = (x - 4) ** 2 - 4
    assert fx.subs(x, 1) == 5 and fx.subs(x, 7) == 5 and quad_features(fx)["vertex"] == (4, -4)
    assert sp.expand(fx) == x ** 2 - 8 * x + 12
    has_final(p, "y = (x − 4)² − 4", "x² − 8x + 12")


add(S, "A parabola passes through (1, 5) and (7, 5) and has a minimum value of −4. Find its equation.",
    ["(1, 5) and (7, 5) are at the same height, so they are symmetric about the axis: x = (1 + 7) / 2 = 4.",
     "The vertex is on the axis with y = −4: (4, −4). So y = a(x − 4)² − 4.",
     "Substitute (1, 5): 5 = a(1 − 4)² − 4 = 9a − 4, so 9a = 9 and a = 1.",
     "y = (x − 4)² − 4 = x² − 8x + 16 − 4 = x² − 8x + 12."],
    "y = (x − 4)² − 4 = x² − 8x + 12", _fq4)

S = C + "graphical analysis: systems of equations (linear-linear, linear-quadratic, quadratic-quadratic)"

add(S, "Solve the system y = 2x + 1 and 3x + y = 11.",
    ["Substitute y = 2x + 1 into the second equation: 3x + (2x + 1) = 11.",
     "5x + 1 = 11, so 5x = 10 and x = 2.",
     "y = 2(2) + 1 = 5.",
     "Check in the second equation: 3(2) + 5 = 11 ✓"],
    "(2, 5)", lambda p: (sp.solve([y - 2 * x - 1, 3 * x + y - 11], [x, y]) == {x: 2, y: 5}, has_final(p, "(2, 5)")))


def _sys2(p):
    sols = sp.solve([y - (x ** 2 - 4 * x + 3), y - (x - 1)], [x, y])
    assert sorted(sols) == [(1, 0), (4, 3)]
    has_final(p, "(1, 0)", "(4, 3)")


add(S, "Find the points where the parabola y = x² − 4x + 3 meets the line y = x − 1.",
    ["At an intersection both y-values are equal: x² − 4x + 3 = x − 1.",
     "x² − 5x + 4 = 0",
     "(x − 1)(x − 4) = 0, so x = 1 or x = 4.",
     "Use the line to find y: x = 1 gives y = 0, and x = 4 gives y = 3.",
     "Check in the parabola: 1 − 4 + 3 = 0 ✓ and 16 − 16 + 3 = 3 ✓"],
    "(1, 0) and (4, 3)", _sys2, roots=[1, 4])


def _sys3(p):
    sols = sp.solve([y - (x ** 2 - 2 * x - 3), y - (-x + 3)], [x, y])
    assert sorted(sols) == [(-2, 5), (3, 0)]
    has_final(p, "(3, 0)", "(−2, 5)")


add(S, "Find the points where y = x² − 2x − 3 meets y = −x + 3.",
    ["Set the y-values equal: x² − 2x − 3 = −x + 3.",
     "x² − x − 6 = 0",
     "(x − 3)(x + 2) = 0, so x = 3 or x = −2.",
     "Use the line: x = 3 gives y = −3 + 3 = 0, and x = −2 gives y = 2 + 3 = 5."],
    "(3, 0) and (−2, 5)", _sys3, roots=[3, -2])


def _sys4(p):
    sols = sp.solve([y - (x ** 2 + 2 * x - 3), y - (-x ** 2 + 2 * x + 5)], [x, y])
    assert sorted(sols) == [(-2, -3), (2, 5)]
    has_final(p, "(2, 5)", "(−2, −3)")


add(S, "Find the points where the parabolas y = x² + 2x − 3 and y = −x² + 2x + 5 meet.",
    ["Set the y-values equal: x² + 2x − 3 = −x² + 2x + 5.",
     "Collect terms: 2x² − 8 = 0, so x² = 4 and x = 2 or x = −2.",
     "x = 2: y = 4 + 4 − 3 = 5. x = −2: y = 4 − 4 − 3 = −3.",
     "Check the other parabola: −4 + 4 + 5 = 5 ✓ and −4 − 4 + 5 = −3 ✓"],
    "(2, 5) and (−2, −3)", _sys4, roots=[2, -2])


def _be(p):
    Rv = -sp.Rational(1, 10) * n ** 2 + 30 * n
    Cv = 10 * n + 640
    assert sorted(sp.solve(Rv - Cv, n)) == [40, 160]
    assert Rv.subs(n, 40) == Cv.subs(n, 40) == 1040 and Rv.subs(n, 160) == Cv.subs(n, 160) == 2240
    assert Rv.subs(n, 100) > Cv.subs(n, 100)
    has_final(p, "40", "160")


add(S, "A company's revenue is R = −0.1n² + 30n dollars and its cost is C = 10n + 640 dollars when it makes n items. For which production levels does it break even, and when does it make a profit?",
    ["Break even means revenue equals cost: −0.1n² + 30n = 10n + 640.",
     "Move everything to one side: −0.1n² + 20n − 640 = 0.",
     "Multiply by −10: n² − 200n + 6400 = 0, so (n − 40)(n − 160) = 0 and n = 40 or n = 160.",
     "Check n = 40: R = −160 + 1200 = 1040 and C = 400 + 640 = 1040 ✓",
     "The revenue parabola opens down, so revenue is above cost between the two break-even points: a profit for 40 < n < 160."],
    "Break even at 40 and 160 items; profit between 40 and 160 items", _be)


def _tangent(p):
    assert sp.solve(x ** 2 + 1 - 2 * x, x) == [1]
    disc = (-1) ** 2 - 4 * 1 * 2
    assert disc < 0 and all(not v.is_real for v in sp.solve(x ** 2 + 1 - (x - 1), x))
    has_final(p, "one point (1, 2)", "none")


add(S, "How many points does the parabola y = x² + 1 share with (a) the line y = 2x, and (b) the line y = x − 1?",
    ["(a) Set equal: x² + 1 = 2x, so x² − 2x + 1 = 0 and (x − 1)² = 0. One solution, x = 1, and y = 2(1) = 2.",
     "The line touches the parabola at (1, 2) and does not cross it: it is tangent.",
     "(b) Set equal: x² + 1 = x − 1, so x² − x + 2 = 0.",
     "Discriminant: (−1)² − 4(1)(2) = 1 − 8 = −7 < 0, so there is no real solution.",
     "The line misses the parabola completely."],
    "(a) one point (1, 2), the line is tangent   (b) none", _tangent)

S = C + "graphical analysis: optimization (feasible region, objective function, profit and cost, area and volume)"


def _o1(p):
    cons = [(1, 0, 0, ">="), (0, 1, 0, ">="), (1, 1, 6, "<="), (1, 2, 8, "<=")]
    best, where, vals = lp_best(cons, lambda a_, b_: 3 * a_ + 2 * b_, "max")
    assert best == 18 and where == {(6, 0)}
    assert vals == {(0, 0): 0, (6, 0): 18, (0, 4): 8, (4, 2): 16}
    has_final(p, "(6, 0)", "18")


add(S, "Maximize P = 3x + 2y subject to x ≥ 0, y ≥ 0, x + y ≤ 6 and x + 2y ≤ 8.",
    ["Find the corner points of the feasible region. On the axes: (0, 0), (6, 0) from x + y = 6, and (0, 4) from x + 2y = 8.",
     "The two slanted lines cross where x + y = 6 and x + 2y = 8: subtract to get y = 2, then x = 4. The corner is (4, 2).",
     "(6, 0) satisfies x + 2y = 6 ≤ 8, and (0, 4) satisfies x + y = 4 ≤ 6, so all four corners are feasible.",
     "P at each corner: (0, 0) gives 0; (6, 0) gives 18; (0, 4) gives 8; (4, 2) gives 12 + 4 = 16.",
     "The maximum of an objective function on a feasible region is at a corner. The largest value is 18."],
    "Maximum P = 18 at (6, 0)", _o1)


def _o2(p):
    cons = [(1, 0, 0, ">="), (0, 1, 0, ">="), (2, 1, 16, "<="), (1, 1, 10, "<=")]
    best, where, vals = lp_best(cons, lambda a_, b_: 15 * a_ + 10 * b_, "max")
    assert best == 130 and where == {(6, 4)}
    has_final(p, "6 cakes", "4 pies", "$130")


add(S, "A bakery makes x cakes and y pies in a day. A cake takes 2 hours of oven time and a pie takes 1 hour; the oven is available 16 hours. Together they use at most 10 kg of flour (1 kg for each cake and each pie). Profit is $15 per cake and $10 per pie. How many of each give the greatest profit?",
    ["Constraints: x ≥ 0, y ≥ 0, oven 2x + y ≤ 16, flour x + y ≤ 10. Objective: maximize P = 15x + 10y.",
     "Corners: (0, 0); (8, 0) from 2x + y = 16; (0, 10) from x + y = 10.",
     "The slanted lines cross where 2x + y = 16 and x + y = 10: subtract to get x = 6, then y = 4. Corner (6, 4).",
     "Profit: (0, 0) gives $0; (8, 0) gives $120; (0, 10) gives $100; (6, 4) gives 90 + 40 = $130.",
     "(8, 0) and (0, 10) are feasible: 8 + 0 ≤ 10 and 0 + 10 ≤ 16. The best corner is (6, 4)."],
    "6 cakes and 4 pies, profit $130", _o2)


def _o3(p):
    cons = [(1, 0, 0, ">="), (0, 1, 0, ">="), (1, 1, 10, ">="), (1, 3, 18, ">=")]
    best, where, vals = lp_best(cons, lambda a_, b_: 3 * a_ + 2 * b_, "min")
    assert best == 20 and where == {(0, 10)}
    assert vals[(6, 4)] == 26 and vals[(18, 0)] == 54
    has_final(p, "(0, 10)", "$20")


add(S, "A farmer mixes feed A ($3 per kg) and feed B ($2 per kg). The mix must have at least 10 kg in total, and x + 3y ≥ 18 (a nutrient requirement, with x kg of A and y kg of B). Find the cheapest mix.",
    ["Constraints: x ≥ 0, y ≥ 0, x + y ≥ 10, x + 3y ≥ 18. Objective: minimize C = 3x + 2y.",
     "Corners of the feasible region (which extends up and to the right): (18, 0) from x + 3y = 18, and (0, 10) from x + y = 10.",
     "The two lines cross where x + y = 10 and x + 3y = 18: subtract to get 2y = 8, so y = 4 and x = 6. Corner (6, 4).",
     "Cost: (18, 0) gives $54; (6, 4) gives 18 + 8 = $26; (0, 10) gives $20.",
     "(0, 10) is feasible: 0 + 10 ≥ 10 and 0 + 30 ≥ 18. The minimum cost is $20."],
    "10 kg of feed B only: (0, 10), cost $20", _o3)


def _o4(p):
    A = lambda w_: w_ * (50 - w_)  # noqa: E731
    best = max(range(0, 51), key=A)
    assert best == 25 and A(25) == 625
    has_final(p, "25 m", "625 m²")


add(S, "You have 100 m of fencing to make a rectangular enclosure. What dimensions give the greatest area?",
    ["Perimeter 100 m means width w and length l satisfy 2w + 2l = 100, so l = 50 − w.",
     "Area A = w(50 − w) = −w² + 50w.",
     "The parabola opens down, so the maximum is at the vertex: w = −50 / (2 · (−1)) = 25.",
     "l = 50 − 25 = 25, so the best shape is a square. A = 25 × 25 = 625."],
    "25 m by 25 m (a square), area 625 m²", _o4)


def _o5(p):
    V = lambda x_: x_ * (30 - 2 * x_) ** 2  # noqa: E731
    table = {x_: V(x_) for x_ in range(1, 15)}
    assert max(table, key=table.get) == 5 and table[5] == 2000 and table[4] == 1936 and table[6] == 1944
    xs = sp.symbols("xs")
    assert sp.solve(sp.diff(xs * (30 - 2 * xs) ** 2, xs), xs) == [5, 15]
    has_final(p, "5 cm", "2000 cm³")


add(S, "A box with no lid is made from a 30 cm by 30 cm sheet by cutting a square of side x from each corner and folding up the sides. Use a table of whole-number values of x to find the x that gives the greatest volume.",
    ["After folding, the base is (30 − 2x) by (30 − 2x) and the height is x, so V = x(30 − 2x)².",
     "x = 3: 3(24)² = 1728. x = 4: 4(22)² = 1936. x = 5: 5(20)² = 2000.",
     "x = 6: 6(18)² = 1944. x = 7: 7(16)² = 1792.",
     "The volume rises to x = 5 and then falls, so the largest value in the table is at x = 5.",
     "Cut 5 cm squares: base 20 cm by 20 cm, height 5 cm, volume 2000 cm³."],
    "x = 5 cm, volume 2000 cm³", _o5)


def _o6(p):
    P = lambda w_: 2 * (w_ + 36 / w_)  # noqa: E731
    cands = [w_ / 100 for w_ in range(100, 3600)]
    best = min(cands, key=P)
    assert best == 6.0 and P(6) == 24
    has_final(p, "6 m by 6 m", "24 m")


add(S, "A rectangular pen must have an area of 36 m². Which dimensions give the smallest perimeter?",
    ["Let the width be w. The length is 36 / w, so the perimeter is P = 2(w + 36/w).",
     "Try values: w = 3 gives 2(3 + 12) = 30; w = 4 gives 2(4 + 9) = 26; w = 6 gives 2(6 + 6) = 24; w = 9 gives 2(9 + 4) = 26.",
     "The perimeter is smallest at w = 6, which is where the width equals the length (36 / 6 = 6).",
     "The best shape is a square: 6 m by 6 m, perimeter 24 m."],
    "6 m by 6 m, perimeter 24 m", _o6)


# ---------------------------------------------------------------- applications of statistics
from statistics import NormalDist, mean, median, multimode, pstdev

S = C + "applications of statistics (central tendency, standard deviation, z-scores, distributions, confidence intervals)"


def _st1(p):
    data = [12, 15, 15, 18, 20, 22, 24, 30]
    assert mean(data) == 19.5 and median(data) == 19 and multimode(data) == [15] and sum(data) == 156
    has_final(p, "mean 19.5", "median 19", "mode 15")


add(S, "Eight students recorded how many minutes they spent on homework: 12, 15, 15, 18, 20, 22, 24, 30. Find the mean, median and mode.",
    ["Mean: add and divide by 8. 12 + 15 + 15 + 18 + 20 + 22 + 24 + 30 = 156, and 156 ÷ 8 = 19.5.",
     "Median: the data are in order and there are 8 values, so average the 4th and 5th: (18 + 20) / 2 = 19.",
     "Mode: the value that appears most often is 15 (it appears twice)."],
    "mean 19.5, median 19, mode 15", _st1)


def _st2(p):
    data = [2, 4, 4, 4, 5, 5, 7, 9]
    assert mean(data) == 5 and sum((d - 5) ** 2 for d in data) == 32 and pstdev(data) == 2
    has_final(p, "2")


add(S, "Find the (population) standard deviation of the data set 2, 4, 4, 4, 5, 5, 7, 9.",
    ["Mean: (2 + 4 + 4 + 4 + 5 + 5 + 7 + 9) / 8 = 40 / 8 = 5.",
     "Squared deviations from 5: (2 − 5)² = 9, 1, 1, 1, 0, 0, (7 − 5)² = 4, (9 − 5)² = 16.",
     "Add them: 9 + 1 + 1 + 1 + 0 + 0 + 4 + 16 = 32.",
     "Variance = 32 / 8 = 4.",
     "Standard deviation = √4 = 2."],
    "σ = 2", _st2)


def _st3(p):
    z1, z2 = (78 - 70) / 8, (70 - 62) / 5
    assert z1 == 1.0 and z2 == 1.6 and z2 > z1
    has_final(p, "second", "1.6")


add(S, "A student scored 78 on a test with mean 70 and standard deviation 8, and scored 70 on a different test with mean 62 and standard deviation 5. On which test did the student do relatively better?",
    ["Compare using z-scores: z = (score − mean) / standard deviation.",
     "First test: z = (78 − 70) / 8 = 8 / 8 = 1.",
     "Second test: z = (70 − 62) / 5 = 8 / 5 = 1.6.",
     "1.6 > 1, so the second score is further above its mean (in standard deviations)."],
    "The second test (z = 1.6 versus z = 1)", _st3)


def _st4(p):
    nd = NormalDist(170, 10)
    exact = nd.cdf(190) - nd.cdf(160)
    assert close(exact * 100, 81.9, 0.1)
    assert 68 + (95 - 68) / 2 == 81.5
    has_final(p, "81.5%")


add(S, "Heights of adult women in a town are approximately normal with mean 170 cm and standard deviation 10 cm. About what percent are between 160 cm and 190 cm?",
    ["160 cm is 1 standard deviation below the mean and 190 cm is 2 standard deviations above it.",
     "Empirical rule: 68% lie within 1 standard deviation, and 95% lie within 2.",
     "From 160 to 170 is half of 68%, which is 34%.",
     "From 170 to 190 is half of 95%, which is 47.5%.",
     "Total: 34% + 47.5% = 81.5%."],
    "About 81.5%", _st4)


def _st5(p):
    ph = 220 / 400
    se = math.sqrt(ph * (1 - ph) / 400)
    me = 1.96 * se
    assert ph == 0.55 and close(me, 0.0488, 0.0001)
    assert close((ph - me) * 100, 50.1, 0.05) and close((ph + me) * 100, 59.9, 0.05)
    has_final(p, "4.9%", "50.1%", "59.9%")


add(S, "In a poll of 400 voters, 220 support a new bike lane. Find a 95% confidence interval for the proportion of all voters who support it. Use margin of error = 1.96 √(p(1 − p) / n), where p is the sample proportion.",
    ["Sample proportion: p = 220 / 400 = 0.55.",
     "p(1 − p) = 0.55 × 0.45 = 0.2475, and 0.2475 / 400 = 0.00061875.",
     "Square root: √0.00061875 ≈ 0.0249.",
     "Margin of error = 1.96 × 0.0249 ≈ 0.0488, about 4.9 percentage points.",
     "Interval: 0.55 − 0.049 = 0.501 to 0.55 + 0.049 = 0.599."],
    "55% ± 4.9%, that is 50.1% to 59.9%", _st5)


def _st6(p):
    me = 1.96 * 6 / math.sqrt(36)
    assert close(me, 1.96, 1e-9) and close(24.5 - me, 22.54, 1e-9) and close(24.5 + me, 26.46, 1e-9)
    has_final(p, "22.54", "26.46")


add(S, "A sample of 36 students takes an average of 24.5 minutes to get to school, with a sample standard deviation of 6 minutes. Find a 95% confidence interval for the true mean, using margin of error = 1.96 s / √n.",
    ["n = 36, so √n = 6.",
     "Margin of error = 1.96 × 6 / 6 = 1.96.",
     "Lower end: 24.5 − 1.96 = 22.54. Upper end: 24.5 + 1.96 = 26.46.",
     "We are 95% confident the true mean travel time is between 22.54 and 26.46 minutes."],
    "24.5 ± 1.96, that is 22.54 to 26.46 minutes", _st6)


def _st7(p):
    A_, B_ = [4, 5, 5, 6], [1, 3, 7, 9]
    assert mean(A_) == mean(B_) == 5 and close(pstdev(A_), 0.71, 0.005) and close(pstdev(B_), 3.16, 0.005)
    has_final(p, "0.71", "3.16")


add(S, "Data set A is 4, 5, 5, 6 and data set B is 1, 3, 7, 9. Both have mean 5. Find each standard deviation and say what it tells you.",
    ["Set A squared deviations: (4 − 5)² = 1, 0, 0, (6 − 5)² = 1. Sum = 2, variance = 2 / 4 = 0.5, σ = √0.5 ≈ 0.71.",
     "Set B squared deviations: (1 − 5)² = 16, (3 − 5)² = 4, (7 − 5)² = 4, (9 − 5)² = 16. Sum = 40, variance = 40 / 4 = 10, σ = √10 ≈ 3.16.",
     "Same mean, but 3.16 is much larger than 0.71.",
     "Set B is far more spread out; set A is tightly clustered around 5."],
    "σ_A ≈ 0.71 and σ_B ≈ 3.16, so B varies much more", _st7)


def _st8(p):
    z = NormalDist().inv_cdf(0.975)
    assert close(z, 1.96, 0.001) and close(100 + 1.96 * 15, 129.4, 1e-9) and close(100 + z * 15, 129.4, 0.01)
    has_final(p, "129.4")


add(S, "Scores on an aptitude test are approximately normal with mean 100 and standard deviation 15. About 2.5% of scores are above a cutoff at z = 1.96. What is the cutoff score?",
    ["Use x = mean + z × standard deviation.",
     "x = 100 + 1.96 × 15",
     "1.96 × 15 = 29.4",
     "x = 100 + 29.4 = 129.4"],
    "About 129.4", _st8)

# ---------------------------------------------------------------- scale models
S = C + "scale models (enlargements and reductions, similar objects, square-cube law)"

add(S, "A model car is built at a scale of 1 : 24. The real car is 4.8 m long. How long is the model, in centimetres?",
    ["A scale of 1 : 24 means every 1 unit on the model is 24 units on the real car.",
     "Convert the real length to centimetres: 4.8 m = 480 cm.",
     "Model length = 480 ÷ 24 = 20 cm."],
    "20 cm", lambda p: (4.8 * 100 == 480, 480 / 24 == 20, has_final(p, "20 cm")))

add(S, "A 4 cm by 6 cm rectangle is enlarged by a scale factor of 2.5. Find the new dimensions, the old and new areas, and the ratio of the areas.",
    ["New dimensions: 4 × 2.5 = 10 cm and 6 × 2.5 = 15 cm.",
     "Old area: 4 × 6 = 24 cm². New area: 10 × 15 = 150 cm².",
     "Ratio of areas: 150 ÷ 24 = 6.25.",
     "That equals the scale factor squared: 2.5² = 6.25."],
    "10 cm by 15 cm; areas 24 cm² and 150 cm²; the area ratio is 6.25 = 2.5²",
    lambda p: (4 * 2.5 == 10 and 6 * 2.5 == 15, 4 * 6 == 24 and 10 * 15 == 150, 150 / 24 == 6.25 == 2.5 ** 2, has_final(p, "6.25")))

add(S, "A small cylinder has surface area 50 cm² and volume 40 cm³. A similar cylinder is made with every length tripled. Find the new surface area and volume.",
    ["Scale factor k = 3.",
     "Areas scale by k²: 50 × 3² = 50 × 9 = 450 cm².",
     "Volumes scale by k³: 40 × 3³ = 40 × 27 = 1080 cm³."],
    "Surface area 450 cm²; volume 1080 cm³", lambda p: (50 * 9 == 450, 40 * 27 == 1080, has_final(p, "450 cm²", "1080 cm³")))

add(S, "Two similar triangles have areas 18 cm² and 50 cm². The smaller one has perimeter 12 cm. Find the perimeter of the larger one.",
    ["The ratio of areas is the scale factor squared: k² = 50 / 18 = 25 / 9.",
     "k = √(25 / 9) = 5 / 3.",
     "Perimeters (lengths) scale by k: 12 × 5/3 = 20 cm."],
    "20 cm", lambda p: (sp.Rational(50, 18) == sp.Rational(25, 9), sp.sqrt(sp.Rational(25, 9)) == sp.Rational(5, 3), 12 * sp.Rational(5, 3) == 20,
                        has_final(p, "20 cm")))

add(S, "A statue is 2 m tall and has volume 0.5 m³. A model is made with height 20 cm. Find the volume of the model in cm³.",
    ["Scale factor: model height / real height = 20 cm / 200 cm = 1/10.",
     "Volumes scale by k³ = (1/10)³ = 1/1000.",
     "Real volume in cm³: 0.5 m³ = 0.5 × 1 000 000 = 500 000 cm³.",
     "Model volume = 500 000 ÷ 1000 = 500 cm³."],
    "500 cm³", lambda p: (sp.Rational(20, 200) == sp.Rational(1, 10), sp.Rational(1, 10) ** 3 == sp.Rational(1, 1000), sp.Rational(1, 2) * 10 ** 6 == 500000,
                          500000 / 1000 == 500, has_final(p, "500 cm³")))

add(S, "A cube with side 10 cm is enlarged into a cube with side 30 cm. Compare the surface areas and the volumes.",
    ["Scale factor k = 30 / 10 = 3.",
     "Surface area of a cube = 6 × side². Old: 6 × 10² = 600 cm². New: 6 × 30² = 5400 cm².",
     "Volume = side³. Old: 10³ = 1000 cm³. New: 30³ = 27 000 cm³.",
     "Surface area grew by 5400 ÷ 600 = 9 = 3², and volume grew by 27 000 ÷ 1000 = 27 = 3³."],
    "Surface area ×9 (600 to 5400 cm²); volume ×27 (1000 to 27 000 cm³)",
    lambda p: (6 * 10 ** 2 == 600 and 6 * 30 ** 2 == 5400, 10 ** 3 == 1000 and 30 ** 3 == 27000, 5400 / 600 == 9 and 27000 / 1000 == 27,
               has_final(p, "×9", "×27")))

add(S, "An animal is scaled up to be 2 times taller, with the same shape. Its mass grows with volume, and the strength of its leg bones grows with their cross-section area. By what factor does the load on each unit of bone area change?",
    ["Scale factor k = 2.",
     "Mass scales like volume: k³ = 2³ = 8 times heavier.",
     "Bone cross-section scales like area: k² = 2² = 4 times larger.",
     "Load per unit area = 8 ÷ 4 = 2 times as much. This is why a bigger animal needs thicker, not just longer, bones (the square-cube law)."],
    "2 times as much load per unit of bone area", lambda p: (2 ** 3 == 8 and 2 ** 2 == 4 and 8 / 4 == 2, has_final(p, "2 times")))

add(S, "A map has scale 1 : 50 000. A road measures 3.2 cm on the map, and a lake covers 12 cm² on the map. Find the real road length in km and the real lake area in km².",
    ["Length: 3.2 cm × 50 000 = 160 000 cm. There are 100 000 cm in 1 km, so 160 000 ÷ 100 000 = 1.6 km.",
     "Area: scale factor squared = 50 000² = 2 500 000 000.",
     "12 cm² × 2 500 000 000 = 30 000 000 000 cm². There are 100 000² = 10 000 000 000 cm² in 1 km².",
     "30 000 000 000 ÷ 10 000 000 000 = 3 km²."],
    "Road 1.6 km; lake 3 km²", lambda p: (3.2 * 50000 / 100000 == 1.6, 12 * 50000 ** 2 / 100000 ** 2 == 3.0, has_final(p, "1.6 km", "3 km²")))

add(S, "A 30 cm statue needs 40 mL of paint. How much paint does a similar 90 cm statue need?",
    ["Scale factor k = 90 / 30 = 3.",
     "Paint covers surface area, and area scales by k² = 3² = 9.",
     "Paint needed = 40 mL × 9 = 360 mL."],
    "360 mL", lambda p: (90 / 30 == 3 and 40 * 3 ** 2 == 360, has_final(p, "360 mL")))

# ---------------------------------------------------------------- financial literacy
S = C + "financial literacy: compound interest, investments and loans, buy/lease"


def money(p):
    return [float(v.replace(",", "").replace(" ", "")) for v in re.findall(r"\$([\d][\d, ]*(?:\.\d+)?)", fin(p))]


def money_is(p, *wanted):
    got = money(p)
    assert len(got) == len(wanted) and all(abs(g - w_) <= 0.0051 for g, w_ in zip(got, wanted)), (got, wanted)


add(S, "You invest $3000 at 5% per year compounded semi-annually for 4 years. Find the final amount and the interest earned.",
    ["Semi-annual means 2 periods a year: i = 0.05 / 2 = 0.025 and N = 2 × 4 = 8.",
     "A = 3000(1.025)^8",
     "(1.025)^8 ≈ 1.21840",
     "A ≈ 3000 × 1.21840 ≈ $3,655.21",
     "Interest = 3655.21 − 3000 = $655.21."],
    "Amount $3,655.21; interest $655.21",
    lambda p: (money_is(p, round(3000 * 1.025 ** 8, 2), round(round(3000 * 1.025 ** 8, 2) - 3000, 2)), has_steps(p, f"{1.025 ** 8:.5f}")))

add(S, "Compare $5000 invested for 5 years at 3% per year simple interest with 3% per year compounded annually.",
    ["Simple interest: A = P(1 + rt) = 5000(1 + 0.03 × 5) = 5000 × 1.15 = $5,750.00.",
     "Compound: A = 5000(1.03)^5.",
     "(1.03)^5 ≈ 1.15927, so A ≈ 5000 × 1.15927 ≈ $5,796.37.",
     "Difference: 5796.37 − 5750.00 = $46.37 more with compounding."],
    "Simple $5,750.00; compound $5,796.37 (an extra $46.37)",
    lambda p: (money_is(p, 5750.00, round(5000 * 1.03 ** 5, 2), 46.37), round(5000 * 1.03 ** 5, 2) - 5750 > 46.36, has_steps(p, f"{1.03 ** 5:.5f}")))


def _fm_loan(p):
    pmt = 12000 * 0.004 / (1 - 1.004 ** -48)
    assert round(pmt, 2) == 275.27
    total = round(275.27 * 48, 2)
    assert total == 13212.96 and round(total - 12000, 2) == 1212.96
    money_is(p, 275.27, 13212.96, 1212.96)
    has_steps(p, f"{1.004 ** -48:.5f}")


add(S, "A $12,000 loan is at 4.8% per year compounded monthly over 4 years. Find the monthly payment, the total repaid and the interest paid.",
    ["Loan payment: PMT = PV × i / (1 − (1 + i)^(−N)).",
     "i = 0.048 / 12 = 0.004 and N = 12 × 4 = 48.",
     "(1.004)^(−48) ≈ 0.82562, so the bottom is 1 − 0.82562 = 0.17438.",
     "PMT = 12000 × 0.004 / 0.17438 = 48 / 0.17438 ≈ $275.27 per month.",
     "Total repaid = 48 × 275.27 = $13,212.96, so the interest is 13212.96 − 12000 = $1,212.96."],
    "Payment $275.27; total $13,212.96; interest $1,212.96", _fm_loan)


def _fm_sav(p):
    fv = 150 * ((1.003 ** 36 - 1) / 0.003)
    assert round(fv, 2) == 5693.38 and 150 * 36 == 5400 and round(fv - 5400, 2) == 293.38
    money_is(p, 5693.38, 293.38)
    has_steps(p, f"{1.003 ** 36:.5f}")


add(S, "You deposit $150 at the end of every month for 3 years into an account paying 3.6% per year compounded monthly. How much is there at the end, and how much of it is interest?",
    ["Future value of regular deposits: FV = PMT × ((1 + i)^N − 1) / i.",
     "i = 0.036 / 12 = 0.003 and N = 12 × 3 = 36.",
     "(1.003)^36 ≈ 1.11387, so ((1.003)^36 − 1) / 0.003 ≈ 0.11387 / 0.003 ≈ 37.956.",
     "FV ≈ 150 × 37.956 ≈ $5,693.38.",
     "You deposited 150 × 36 = $5,400, so the interest is 5693.38 − 5400 = $293.38."],
    "Final amount $5,693.38; interest $293.38", _fm_sav)

add(S, "Compare the 3-year cost of leasing and buying a car. Lease: $0 down and $395 a month for 36 months. Buy: $1500 down and $520 a month for 36 months, and then the car sells for $9,800. Which has the lower net cost?",
    ["Lease total: 36 × 395 = $14,220, and you own nothing afterward.",
     "Buy cash paid: 1500 + 36 × 520 = 1500 + 18720 = $20,220.",
     "Selling the car returns $9,800, so the net cost of buying is 20220 − 9800 = $10,420.",
     "10,420 is less than 14,220, so buying costs $3,800 less over the 3 years."],
    "Buying: $10,420 net versus leasing: $14,220",
    lambda p: (money_is(p, 10420, 14220), 36 * 395 == 14220, 1500 + 36 * 520 - 9800 == 10420, 14220 - 10420 == 3800, has_steps(p, "$3,800")))


def _rule72(p):
    exact = math.log(2) / math.log(1.06)
    assert close(exact, 11.90, 0.005) and 72 / 6 == 12
    has_final(p, "12", "11.9")
    has_steps(p, f"{math.log(2):.5f}", f"{math.log(1.06):.5f}")


add(S, "The Rule of 72 says money doubles in about 72 ÷ (interest rate in %) years. Use it for 6% per year compounded annually, then find the exact doubling time with logarithms.",
    ["Rule of 72: 72 ÷ 6 = 12 years.",
     "Exact: (1.06)^n = 2. Take logarithms: n ln 1.06 = ln 2, so n = ln 2 / ln 1.06.",
     "ln 2 ≈ 0.69315 and ln 1.06 ≈ 0.05827.",
     "n ≈ 0.69315 / 0.05827 ≈ 11.90 years. The rule gives 12, which is very close."],
    "Rule of 72: 12 years; exact: about 11.9 years", _rule72)


if __name__ == "__main__":
    main()
