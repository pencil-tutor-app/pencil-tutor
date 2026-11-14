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
# BC Pre-calculus 11 problems. Standard names follow https://curriculum.gov.bc.ca/curriculum/mathematics/11/pre-calculus
# ===============================================================================================================
COURSE = "BC Pre-calculus 11"
PREFIX = "pc11"
LEVEL = "high_school"
C = "BC Pre-calculus 11 content: "

# ---------------------------------------------------------------- real number system: classification
S = C + "real number system (classification)"


def _class_check(p):
    rat = {"√36": sp.sqrt(36), "−4/7": sp.Rational(-4, 7), "0.45": sp.Rational(45, 100), "∛27": sp.cbrt(27)}
    irr = {"√20": sp.sqrt(20), "π": sp.pi, "∛10": sp.cbrt(10)}
    head, tail = fin(p).split("Irrational:")
    for name, v in rat.items():
        assert v.is_rational is True and name in head, name
    for name, v in irr.items():
        assert v.is_rational is False and v.is_real and name in tail, name


add(S, "Sort these numbers into rational and irrational: √36, √20, −4/7, π, 0.45, ∛27, ∛10.",
    ["√36 = 6, a whole number, so it is rational.",
     "√20: 20 is not a perfect square (4² = 16 and 5² = 25), so √20 is irrational.",
     "−4/7 is a ratio of integers, and 0.45 = 45/100 = 9/20 terminates, so both are rational.",
     "π never ends and never repeats, so it is irrational.",
     "∛27 = 3 is rational. 10 is not a perfect cube (2³ = 8, 3³ = 27), so ∛10 is irrational."],
    "Rational: √36, −4/7, 0.45, ∛27. Irrational: √20, π, ∛10.", _class_check)


def _sets_check(p):
    v = sp.Rational(-12, 4)
    assert v == -3 and v.is_integer and not v.is_nonnegative
    has_final(p, "integers", "rational", "real")
    for bad in ("natural", "whole", "irrational"):
        assert bad not in fin(p).lower().replace("not ", "")


add(S, "List every set from natural numbers, whole numbers, integers, rational numbers, irrational numbers and real numbers that contains −12/4.",
    ["Simplify first: −12/4 = −3.",
     "−3 is negative, so it is not a natural number and not a whole number.",
     "−3 is an integer, and −3 = −3/1, so it is also rational.",
     "Every rational number is real, and −3 is not irrational."],
    "integers, rational numbers, real numbers", _sets_check)

add(S, "Write 0.888… (the 8 repeats forever) as a fraction in lowest terms.",
    ["Let x = 0.888…",
     "Multiply by 10 to shift one place: 10x = 8.888…",
     "Subtract the first line from the second, so the repeating tail cancels: 9x = 8",
     "x = 8/9"],
    "8/9", lambda p: (close(Zq(fin(p)), sp.Rational(8, 9), 1e-12), close(sp.Rational(8, 9), 0.8888888888888888, 1e-12)))

add(S, "Write 0.2727… (the digits 27 repeat forever) as a fraction in lowest terms.",
    ["Let x = 0.2727…",
     "Two digits repeat, so multiply by 100: 100x = 27.2727…",
     "Subtract: 100x − x = 27, so 99x = 27",
     "x = 27/99 = 3/11"],
    "3/11", lambda p: (
        close(Zq(fin(p)), sp.Rational(27, 99), 1e-12),
        sp.Rational(3, 11) == sp.Rational(27, 99),
        close(sp.N(sp.Rational(3, 11), 12), 0.272727272727, 1e-11)))


def _prod_check(p):
    assert sp.expand((3 + sp.sqrt(5)) * (3 - sp.sqrt(5))) == 4
    assert sp.sqrt(5).is_rational is False
    has_final(p, "Rational", "4")


add(S, "Is (3 + √5)(3 − √5) rational or irrational? Show your work.",
    ["Expand: (3 + √5)(3 − √5) = 9 − 3√5 + 3√5 − (√5)².",
     "The middle terms cancel, and (√5)² = 5.",
     "9 − 5 = 4",
     "4 is a whole number, so the product is rational even though each factor is irrational."],
    "Rational (it equals 4)", _prod_check)

# ---------------------------------------------------------------- powers with rational exponents
S = C + "powers with rational exponents"

add(S, "Evaluate 27^(2/3).",
    ["In 27^(2/3), the denominator 3 is the root and the numerator 2 is the power.",
     "Take the root first, since it keeps the numbers small: ∛27 = 3.",
     "27^(2/3) = (∛27)² = 3² = 9"],
    "9", lambda p: (Zq(fin(p)) == sp.Integer(27) ** sp.Rational(2, 3) == 9))

add(S, "Evaluate 16^(−3/4).",
    ["The negative exponent means reciprocal: 16^(−3/4) = 1 / 16^(3/4).",
     "16^(3/4) = (∜16)³ and ∜16 = 2 because 2⁴ = 16.",
     "(∜16)³ = 2³ = 8",
     "16^(−3/4) = 1/8"],
    "1/8", lambda p: (Zq(fin(p)) == sp.Integer(16) ** sp.Rational(-3, 4) == sp.Rational(1, 8)))

add(S, "Evaluate (4/9)^(−3/2).",
    ["A negative exponent flips the fraction: (4/9)^(−3/2) = (9/4)^(3/2).",
     "Square root first: √(9/4) = 3/2.",
     "(3/2)³ = 27/8"],
    "27/8", lambda p: (Zq(fin(p)) == sp.Rational(4, 9) ** sp.Rational(-3, 2) == sp.Rational(27, 8)))

add(S, "Simplify x^(2/3) · x^(1/2) ÷ x^(1/6). Write the answer with a single exponent.",
    ["The bases are the same, so add the exponents when multiplying and subtract when dividing.",
     "Exponent: 2/3 + 1/2 − 1/6 = 4/6 + 3/6 − 1/6",
     "4/6 + 3/6 − 1/6 = 6/6 = 1",
     "x¹ = x"],
    "x", lambda p: (equiv("x^(2/3) * x^(1/2) / x^(1/6)", fin(p)),
                    sp.Rational(2, 3) + sp.Rational(1, 2) - sp.Rational(1, 6) == 1))

add(S, "Simplify (8x⁶y^(−3))^(2/3). Write the answer with positive exponents.",
    ["Apply the exponent 2/3 to each factor: 8^(2/3) · (x⁶)^(2/3) · (y^(−3))^(2/3).",
     "8^(2/3) = (∛8)² = 2² = 4",
     "(x⁶)^(2/3) = x^(6 · 2/3) = x⁴ and (y^(−3))^(2/3) = y^(−2)",
     "Product: 4x⁴y^(−2)",
     "A negative exponent moves y to the denominator: 4x⁴ / y²."],
    "4x⁴/y²", lambda p: (equiv("(8*x^6*y^(-3))^(2/3)", "4x^4/y^2"), equiv("4x⁴/y²", "4x^4/y^2")))

add(S, "(a) Write ∛(x²) using a rational exponent. (b) Write y^(−3/4) as a radical with no negative exponent.",
    ["(a) The index 3 goes in the denominator and the power 2 in the numerator: ∛(x²) = x^(2/3).",
     "(b) First remove the negative: y^(−3/4) = 1 / y^(3/4).",
     "Then y^(3/4) = ∜(y³), the 4th root of y cubed.",
     "So y^(−3/4) = 1 / ∜(y³)."],
    "(a) x^(2/3)   (b) 1/∜(y³)", lambda p: (
        equiv("cbrt(x^2)", "x^(2/3)"), equiv("y^(-3/4)", "1/root4(y^3)"), has_final(p, "x^(2/3)", "1/∜(y³)")))

add(S, "Evaluate 125^(−2/3) ÷ 25^(1/2).",
    ["125^(−2/3) = 1 / (∛125)² = 1 / 5² = 1/25",
     "25^(1/2) = √25 = 5",
     "(1/25) ÷ 5 = 1/25 · 1/5 = 1/125"],
    "1/125", lambda p: (Zq(fin(p)) == sp.Integer(125) ** sp.Rational(-2, 3) / sp.Integer(25) ** sp.Rational(1, 2)))

add(S, "Solve x^(3/2) = 27.",
    ["Undo the power 3/2 by raising both sides to its reciprocal, 2/3: (x^(3/2))^(2/3) = 27^(2/3).",
     "The left side is x^1 = x. For the right side, ∛27 = 3, so 27^(2/3) = 3² = 9.",
     "x = 9",
     "Check: 9^(3/2) = (√9)³ = 3³ = 27"],
    "x = 9", lambda p: ok_solve(p, x ** sp.Rational(3, 2) - 27), roots=[9])

# ---------------------------------------------------------------- radical operations
S = C + "radical operations (simplifying, ordering, operations)"

add(S, "Write √72 and ∛54 as simplified radicals.",
    ["For a square root, look for the largest perfect square factor: 72 = 36 · 2.",
     "√72 = √36 · √2 = 6√2",
     "For a cube root, look for the largest perfect cube factor: 54 = 27 · 2.",
     "∛54 = ∛27 · ∛2 = 3∛2"],
    "√72 = 6√2 and ∛54 = 3∛2",
    lambda p: (equiv("sqrt(72)", "6√2"), equiv("cbrt(54)", "3∛2"), has_final(p, "6√2", "3∛2")))

add(S, "Write 4√3 as an entire radical (a single square root).",
    ["Write the 4 as a square root: 4 = √16.",
     "4√3 = √16 · √3",
     "√16 · √3 = √48"],
    "√48", lambda p: (equiv("4√3", fin(p)), 16 * 3 == 48))


def _order_check(p):
    vals = {"5": 5.0, "3√3": float(3 * sp.sqrt(3)), "2√7": float(2 * sp.sqrt(7)), "4√2": float(4 * sp.sqrt(2))}
    order = sorted(vals, key=vals.get)
    assert [s.strip() for s in fin(p).split(",")] == order, order


add(S, "Order from least to greatest: 4√2, 5, 3√3, 2√7.",
    ["Write each number as a single square root so they can be compared.",
     "4√2 = √(16 · 2) = √32, 5 = √25, 3√3 = √(9 · 3) = √27, 2√7 = √(4 · 7) = √28",
     "Order the radicands: 25 < 27 < 28 < 32",
     "So the order is √25, √27, √28, √32."],
    "5, 3√3, 2√7, 4√2", _order_check)

add(S, "Between which two consecutive integers does √47 lie? Then estimate √47 to the nearest tenth without a calculator.",
    ["6² = 36 and 7² = 49, so 6 < √47 < 7.",
     "47 is close to 49, so try 6.8 and 6.9: 6.8² = 46.24 and 6.9² = 47.61.",
     "47 − 46.24 = 0.76 and 47.61 − 47 = 0.61, so 47 is closer to 6.9².",
     "So √47 is between 6 and 7, and √47 ≈ 6.9."],
    "between 6 and 7; √47 ≈ 6.9", lambda p: (6 < math.sqrt(47) < 7, round(math.sqrt(47), 1) == 6.9,
                                              close(6.8 ** 2, 46.24, 1e-9), close(6.9 ** 2, 47.61, 1e-9),
                                              has_final(p, "6 and 7", "6.9")))

add(S, "Simplify 3√20 + √45 − 2√5.",
    ["Simplify each radical: √20 = 2√5, so 3√20 = 6√5.",
     "√45 = √(9 · 5) = 3√5",
     "Now they are like radicals: 6√5 + 3√5 − 2√5 = (6 + 3 − 2)√5",
     "(6 + 3 − 2)√5 = 7√5"],
    "7√5", lambda p: equiv("3*sqrt(20) + sqrt(45) - 2*sqrt(5)", fin(p)))

add(S, "Expand and simplify (2 + 3√5)(2 − √5).",
    ["Multiply each term in the first bracket by each term in the second.",
     "2 · 2 = 4, 2 · (−√5) = −2√5, 3√5 · 2 = 6√5, 3√5 · (−√5) = −3 · 5 = −15",
     "4 − 2√5 + 6√5 − 15 = −11 + 4√5"],
    "−11 + 4√5", lambda p: equiv("(2 + 3*sqrt(5))*(2 - sqrt(5))", fin(p)))

add(S, "Rationalize the denominator: [[6//√3 + 1]].",
    ["Multiply top and bottom by the conjugate of the denominator, √3 − 1.",
     "Denominator: (√3 + 1)(√3 − 1) = 3 − 1 = 2",
     "Numerator: 6(√3 − 1)",
     "6(√3 − 1) / 2 = 3(√3 − 1) = 3√3 − 3"],
    "3√3 − 3", lambda p: equiv("6/(sqrt(3)+1)", fin(p)))

add(S, "Simplify √(48x³y²), where x ≥ 0 and y ≥ 0.",
    ["Split the radicand into perfect squares and what is left: 48x³y² = 16 · 3 · x² · x · y².",
     "Take the square roots of the perfect squares: √16 = 4, √(x²) = x, √(y²) = y.",
     "What stays inside is 3x, so the result is 4xy√(3x)."],
    "4xy√(3x)", lambda p: equiv("sqrt(48*x^3*y^2)", "4*x*y*sqrt(3*x)"))

# ---------------------------------------------------------------- radical equations
S = C + "radical equations (algebraic and graphical, domain, extraneous roots)"

add(S, "Solve √(x + 7) = 5.",
    ["Square both sides: x + 7 = 25",
     "x = 18",
     "Check: √(18 + 7) = √25 = 5"],
    "x = 18", lambda p: ok_solve(p, sp.sqrt(x + 7) - 5), roots=[18])

add(S, "Solve 2√(x − 1) + 3 = 11.",
    ["Isolate the radical: 2√(x − 1) = 8, so √(x − 1) = 4.",
     "Square both sides: x − 1 = 16",
     "x = 17",
     "Check: 2√16 + 3 = 8 + 3 = 11"],
    "x = 17", lambda p: ok_solve(p, 2 * sp.sqrt(x - 1) + 3 - 11), roots=[17])

add(S, "Solve 5 − √(2x + 1) = 2.",
    ["Isolate the radical: −√(2x + 1) = −3, so √(2x + 1) = 3.",
     "Square both sides: 2x + 1 = 9",
     "2x = 8, so x = 4",
     "Check: 5 − √9 = 5 − 3 = 2"],
    "x = 4", lambda p: ok_solve(p, 5 - sp.sqrt(2 * x + 1) - 2), roots=[4])

add(S, "Solve x = √(x + 6). Reject any extraneous roots.",
    ["Square both sides: x² = x + 6",
     "x² − x − 6 = 0",
     "(x − 3)(x + 2) = 0, so x = 3 or x = −2.",
     "Check x = 3: √(3 + 6) = √9 = 3, which equals x. Keep it.",
     "Check x = −2: √(−2 + 6) = 2, but x = −2. Reject it."],
    "x = 3 (x = −2 is extraneous)",
    lambda p: (same_set(sol(p), sp.solve(x - sp.sqrt(x + 6), x)), sp.solve(x**2 - x - 6, x) == [-2, 3],
               has_final(p, "x = −2 is extraneous")),
    roots=[3])

add(S, "Solve √(2x − 1) = x − 2. Reject any extraneous roots.",
    ["Square both sides: 2x − 1 = (x − 2)² = x² − 4x + 4",
     "0 = x² − 6x + 5",
     "0 = (x − 1)(x − 5), so x = 1 or x = 5.",
     "Check x = 1: left √1 = 1, right 1 − 2 = −1. They differ, so reject.",
     "Check x = 5: left √9 = 3, right 5 − 2 = 3. Keep it."],
    "x = 5 (x = 1 is extraneous)",
    lambda p: (same_set(sol(p), sp.solve(sp.sqrt(2 * x - 1) - (x - 2), x)), sp.solve((2 * x - 1) - (x - 2) ** 2, x) == [1, 5],
               has_final(p, "x = 1 is extraneous")), roots=[5])

add(S, "State the domain of y = √(5 − 2x) and of y = 3 + √(x + 4).",
    ["A square root needs a radicand that is 0 or positive.",
     "5 − 2x ≥ 0 gives −2x ≥ −5. Dividing by −2 flips the sign: x ≤ 5/2.",
     "x + 4 ≥ 0 gives x ≥ −4. Adding 3 outside the root does not change the domain."],
    "x ≤ 5/2 for the first, x ≥ −4 for the second",
    lambda p: (sp.solve_univariate_inequality(5 - 2 * x >= 0, x, relational=False) == sp.Interval(-sp.oo, sp.Rational(5, 2)),
               sp.solve_univariate_inequality(x + 4 >= 0, x, relational=False) == sp.Interval(-4, sp.oo),
               has_final(p, "x ≤ 5/2", "x ≥ −4")))


def _inter_check(p):
    sols = [v for v in sp.solve(sp.sqrt(x + 4) - (x - 2), x)]
    assert sols == [5] and sp.sqrt(5 + 4) == 3 and 5 - 2 == 3
    has_final(p, "(5, 3)")


add(S, "The graphs of y = √(x + 4) and y = x − 2 cross at one point. Find it.",
    ["At a crossing point the y-values are equal: √(x + 4) = x − 2.",
     "Square both sides: x + 4 = x² − 4x + 4",
     "x² − 5x = 0",
     "x(x − 5) = 0, so x = 0 or x = 5.",
     "x = 0 gives √4 = 2 but 0 − 2 = −2, so reject. x = 5 gives √9 = 3 and 5 − 2 = 3, so y = 3."],
    "(5, 3)", _inter_check, roots=[5])

add(S, "An object dropped from rest takes t = √(h / 4.9) seconds to fall h metres, ignoring air resistance. From what height must it be dropped to take 3 s to land?",
    ["Substitute t = 3: 3 = √(h / 4.9)",
     "Square both sides: 9 = h / 4.9",
     "h = 9 · 4.9 = 44.1",
     "Check: √(44.1 / 4.9) = √9 = 3"],
    "44.1 m", lambda p: (close(sp.Rational(441, 10), 9 * 4.9, 1e-9), close(math.sqrt(44.1 / 4.9), 3, 1e-9),
                         has_final(p, "44.1")), roots=[sp.Rational(441, 10)], var=h)


# ---------------------------------------------------------------- polynomial factoring
S = C + "polynomial factoring"


def full_factor(p, orig):
    """final_answer must be the complete factorization of orig (same factors as sympy.factor)."""
    text = fin(p)
    assert sp.expand(Z(text) - Z(orig)) == 0, "factored form does not multiply back to the original"
    # every bracket must be irreducible over the rationals with no number left inside it
    groups, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch == "(":
            if depth == 0:
                start = i
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                groups.append(text[start + 1:i])
    assert groups, "no bracketed factors"
    for g in groups:
        content, facs = sp.factor_list(Z(g))
        assert len(facs) == 1 and facs[0][1] == 1 and abs(content) == 1, f"bracket ({g}) can still be factored"


add(S, "Factor completely: 12x³y − 18x²y² + 6xy.",
    ["GCF of the numbers 12, 18, 6 is 6. The lowest power of x is x¹ and of y is y¹, so the GCF is 6xy.",
     "Divide each term by 6xy: 12x³y ÷ 6xy = 2x², −18x²y² ÷ 6xy = −3xy, 6xy ÷ 6xy = 1.",
     "12x³y − 18x²y² + 6xy = 6xy(2x² − 3xy + 1)",
     "Check by expanding: 6xy · 2x² = 12x³y, 6xy · (−3xy) = −18x²y², 6xy · 1 = 6xy."],
    "6xy(2x² − 3xy + 1)", lambda p: full_factor(p, "12x^3 y - 18x^2 y^2 + 6x y"))

add(S, "Factor: x² + 7x + 12.",
    ["a = 1, so look for two numbers with product 12 and sum 7.",
     "Pairs with product 12: 1 and 12, 2 and 6, 3 and 4. Only 3 + 4 = 7.",
     "x² + 7x + 12 = (x + 3)(x + 4)",
     "Check: (x + 3)(x + 4) = x² + 4x + 3x + 12 = x² + 7x + 12"],
    "(x + 3)(x + 4)", lambda p: full_factor(p, "x^2 + 7x + 12"))

add(S, "Factor: x² − 3x − 28.",
    ["Look for two numbers with product −28 and sum −3. The product is negative, so the signs differ.",
     "Try 4 and 7: the larger one must carry the minus sign, so −7 and 4: (−7)(4) = −28 and −7 + 4 = −3.",
     "x² − 3x − 28 = (x − 7)(x + 4)"],
    "(x − 7)(x + 4)", lambda p: full_factor(p, "x^2 - 3x - 28"))

add(S, "Factor: 2x² + 7x + 3.",
    ["Multiply a and c: 2 · 3 = 6. Find two numbers with product 6 and sum 7: 1 and 6.",
     "Split the middle term: 2x² + x + 6x + 3",
     "Group in pairs: x(2x + 1) + 3(2x + 1)",
     "Factor out the common bracket: (2x + 1)(x + 3)"],
    "(2x + 1)(x + 3)", lambda p: full_factor(p, "2x^2 + 7x + 3"))

add(S, "Factor: 6x² − 11x − 10.",
    ["a · c = 6 · (−10) = −60. Find two numbers with product −60 and sum −11: −15 and 4.",
     "Split the middle term: 6x² − 15x + 4x − 10",
     "Group in pairs: 3x(2x − 5) + 2(2x − 5)",
     "Factor out the common bracket: (2x − 5)(3x + 2)",
     "Check the middle term: (2x)(2) + (−5)(3x) = 4x − 15x = −11x"],
    "(2x − 5)(3x + 2)", lambda p: full_factor(p, "6x^2 - 11x - 10"))

add(S, "Factor: 12x² + x − 6.",
    ["a · c = 12 · (−6) = −72. Find two numbers with product −72 and sum 1: 9 and −8.",
     "Split the middle term: 12x² + 9x − 8x − 6",
     "Group in pairs: 3x(4x + 3) − 2(4x + 3)",
     "Factor out the common bracket: (4x + 3)(3x − 2)"],
    "(3x − 2)(4x + 3)", lambda p: full_factor(p, "12x^2 + x - 6"))

add(S, "Factor: 49x² − 64y².",
    ["Both terms are perfect squares: 49x² = (7x)² and 64y² = (8y)².",
     "Difference of squares: a² − b² = (a − b)(a + b), with a = 7x and b = 8y.",
     "49x² − 64y² = (7x − 8y)(7x + 8y)"],
    "(7x − 8y)(7x + 8y)", lambda p: full_factor(p, "49x^2 - 64y^2"))

add(S, "Factor completely: 3x² − 27.",
    ["Take out the GCF first: 3x² − 27 = 3(x² − 9).",
     "x² − 9 is a difference of squares: x² − 9 = (x − 3)(x + 3).",
     "3x² − 27 = 3(x − 3)(x + 3)"],
    "3(x − 3)(x + 3)", lambda p: full_factor(p, "3x^2 - 27"))

add(S, "Factor completely: x⁴ − 81.",
    ["x⁴ = (x²)² and 81 = 9², so this is a difference of squares: (x² − 9)(x² + 9).",
     "x² − 9 is again a difference of squares: (x − 3)(x + 3).",
     "x² + 9 is a sum of squares and does not factor over the real numbers.",
     "x⁴ − 81 = (x − 3)(x + 3)(x² + 9)"],
    "(x − 3)(x + 3)(x² + 9)", lambda p: full_factor(p, "x^4 - 81"))

add(S, "Factor: (x + 2)² + 5(x + 2) + 6.",
    ["The bracket x + 2 repeats, so let u = x + 2. The expression becomes u² + 5u + 6.",
     "Product 6 and sum 5 gives 2 and 3: u² + 5u + 6 = (u + 2)(u + 3).",
     "Replace u by x + 2: (x + 2 + 2)(x + 2 + 3) = (x + 4)(x + 5)."],
    "(x + 4)(x + 5)", lambda p: full_factor(p, "(x+2)^2 + 5(x+2) + 6"))

add(S, "Factor completely: (2x + 1)² − 9.",
    ["9 = 3², so this is a difference of squares with a = 2x + 1 and b = 3.",
     "(2x + 1 − 3)(2x + 1 + 3) = (2x − 2)(2x + 4)",
     "Take a 2 out of each bracket: 2(x − 1) · 2(x + 2)",
     "(2x + 1)² − 9 = 4(x − 1)(x + 2)"],
    "4(x − 1)(x + 2)", lambda p: full_factor(p, "(2x+1)^2 - 9"))

add(S, "Factor: 2(x − 1)² − 7(x − 1) − 4.",
    ["Let u = x − 1. The expression becomes 2u² − 7u − 4.",
     "a · c = −8; the numbers with product −8 and sum −7 are −8 and 1.",
     "2u² − 8u + u − 4 = 2u(u − 4) + 1(u − 4) = (2u + 1)(u − 4)",
     "Replace u by x − 1: (2(x − 1) + 1)((x − 1) − 4) = (2x − 1)(x − 5)."],
    "(2x − 1)(x − 5)", lambda p: full_factor(p, "2(x-1)^2 - 7(x-1) - 4"))

# ---------------------------------------------------------------- rational expressions and equations
S = C + "rational expressions and equations"


def npv_of(p):
    tail = fin(p).split("x ≠", 1)[1]
    return [Zq(s) for s in re.split(r",|\s+and\s+(?:x ≠)?", tail) if s.strip() and s.strip() != "x ≠"]


def rat_check(p, orig, dens):
    """final = '<expression>, x ≠ ...'. Expression must equal orig; NPVs must be the zeros of every denominator."""
    expr = fin(p).split(", x ≠")[0]
    assert equiv(orig, expr), f"{expr} is not equivalent to {orig}"
    want = set()
    for d in dens:
        want |= set(sp.solve(Z(d), x))
    same_set(npv_of(p), list(want))


add(S, "Simplify and state the non-permissible values: [[x² − 9//x² + x − 6]].",
    ["Factor the top and bottom: (x − 3)(x + 3) / ((x + 3)(x − 2)).",
     "Non-permissible values come from the ORIGINAL denominator: (x + 3)(x − 2) = 0 gives x = −3 and x = 2.",
     "Cancel the common factor (x + 3): (x − 3) / (x − 2)."],
    "(x − 3)/(x − 2), x ≠ −3, 2", lambda p: rat_check(p, "(x^2-9)/(x^2+x-6)", ["x^2+x-6"]))

add(S, "Simplify and state the non-permissible values: [[x + 1//x² − 4x − 5]].",
    ["Factor the denominator: x² − 4x − 5 = (x − 5)(x + 1).",
     "The denominator is zero when x = 5 or x = −1, so those are non-permissible.",
     "Cancel the common factor (x + 1): 1 / (x − 5)."],
    "1/(x − 5), x ≠ 5, −1", lambda p: rat_check(p, "(x+1)/(x^2-4x-5)", ["x^2-4x-5"]))

add(S, "Multiply and simplify, then state the non-permissible values: [[x² − 4//x² + 3x]] · [[x//x + 2]].",
    ["Factor everything: (x − 2)(x + 2) / (x(x + 3)) · x / (x + 2).",
     "Non-permissible values: x(x + 3) = 0 gives x = 0 and x = −3; x + 2 = 0 gives x = −2.",
     "Cancel (x + 2) and x: what remains is (x − 2) / (x + 3)."],
    "(x − 2)/(x + 3), x ≠ −3, 0, −2",
    lambda p: rat_check(p, "((x^2-4)/(x^2+3x))*(x/(x+2))", ["x^2+3x", "x+2"]))

add(S, "Divide and simplify, then state the non-permissible values: [[x² − 1//x + 3]] ÷ [[x + 1//x² − 9]].",
    ["Multiply by the reciprocal: (x² − 1)/(x + 3) · (x² − 9)/(x + 1).",
     "Factor: (x − 1)(x + 1)/(x + 3) · (x − 3)(x + 3)/(x + 1).",
     "Cancel (x + 1) and (x + 3): (x − 1)(x − 3).",
     "Non-permissible values: x + 3 = 0, x² − 9 = 0, and the divisor x + 1 may not be 0, so x ≠ −3, 3, −1."],
    "(x − 1)(x − 3), x ≠ −3, 3, −1",
    lambda p: rat_check(p, "((x^2-1)/(x+3))/((x+1)/(x^2-9))", ["x+3", "x^2-9", "x+1"]))

add(S, "Add and state the non-permissible values: [[3//x − 2]] + [[2//x + 1]].",
    ["The lowest common denominator is (x − 2)(x + 1).",
     "3(x + 1) / ((x − 2)(x + 1)) + 2(x − 2) / ((x − 2)(x + 1))",
     "Numerator: 3x + 3 + 2x − 4 = 5x − 1",
     "Sum: (5x − 1) / ((x − 2)(x + 1))",
     "Non-permissible values: x ≠ 2 and x ≠ −1."],
    "(5x − 1)/((x − 2)(x + 1)), x ≠ 2, −1", lambda p: rat_check(p, "3/(x-2)+2/(x+1)", ["x-2", "x+1"]))

add(S, "Subtract and simplify, then state the non-permissible values: [[x//x² − 9]] − [[1//x − 3]].",
    ["Factor the first denominator: x² − 9 = (x − 3)(x + 3). That is the common denominator.",
     "Rewrite the second fraction: 1/(x − 3) = (x + 3) / ((x − 3)(x + 3)).",
     "Subtract numerators: x − (x + 3) = −3. Keep the brackets so the minus applies to both terms.",
     "Difference: −3 / ((x − 3)(x + 3)), which does not simplify further.",
     "Non-permissible values: x ≠ 3 and x ≠ −3."],
    "−3/((x − 3)(x + 3)), x ≠ 3, −3", lambda p: rat_check(p, "x/(x^2-9) - 1/(x-3)", ["x^2-9", "x-3"]))

add(S, "Simplify and state the non-permissible values: [[2x² + 5x − 3//4x² − 1]].",
    ["Factor the top: 2x² + 5x − 3 = (2x − 1)(x + 3). Factor the bottom: 4x² − 1 = (2x − 1)(2x + 1).",
     "Non-permissible values: (2x − 1)(2x + 1) = 0 gives x = 1/2 and x = −1/2.",
     "Cancel (2x − 1): (x + 3) / (2x + 1)."],
    "(x + 3)/(2x + 1), x ≠ 1/2, −1/2", lambda p: rat_check(p, "(2x^2+5x-3)/(4x^2-1)", ["4x^2-1"]))

add(S, "Solve: [[6//x]] − [[5//x + 2]] = 1.",
    ["Non-permissible values: x ≠ 0 and x ≠ −2.",
     "Multiply every term by x(x + 2): 6(x + 2) − 5x = x(x + 2)",
     "x + 12 = x² + 2x",
     "0 = x² + x − 12",
     "0 = (x + 4)(x − 3), so x = −4 or x = 3. Neither is a non-permissible value.",
     "Check x = 3: 6/3 − 5/5 = 2 − 1 = 1"],
    "x = 3 or x = −4", lambda p: ok_solve(p, 6 / x - 5 / (x + 2) - 1), roots=[3, -4])

add(S, "Solve: [[x//x − 4]] = 2 + [[4//x − 4]].",
    ["Non-permissible value: x ≠ 4.",
     "Multiply every term by (x − 4): x = 2(x − 4) + 4",
     "x = 2x − 4",
     "x = 4",
     "But x = 4 is the non-permissible value (it makes the denominators 0), so it is extraneous."],
    "no solution (x = 4 is extraneous)",
    lambda p: (sp.solve(x / (x - 4) - 2 - 4 / (x - 4), x) == [], has_final(p, "no solution")), roots=[4])

add(S, "Two printers finish a job in 4 hours working together. Printer B alone needs 6 hours more than printer A alone. How long does each need alone?",
    ["Let printer A need x hours alone, so printer B needs x + 6 hours.",
     "In one hour they do 1/x and 1/(x + 6) of the job, and together 1/4: 1/x + 1/(x + 6) = 1/4",
     "Multiply every term by 4x(x + 6): 4(x + 6) + 4x = x(x + 6)",
     "8x + 24 = x² + 6x",
     "x² − 2x − 24 = 0",
     "(x − 6)(x + 4) = 0, so x = 6 (reject x = −4, a time cannot be negative).",
     "Check: 1/6 + 1/12 = 2/12 + 1/12 = 3/12 = 1/4"],
    "A: 6 hours, B: 12 hours",
    lambda p: (sp.solve(1 / x + 1 / (x + 6) - sp.Rational(1, 4), x) == [-4, 6], has_final(p, "6 hours", "12 hours")),
    roots=[6])


# ---------------------------------------------------------------- quadratic functions and equations
def U(v):
    """Format a sympy number the way the answers are written (Unicode minus)."""
    return str(sp.nsimplify(v)).replace("-", "−")


def quad_features(expr):
    """vertex, x-intercepts and y-intercept of a parabola, computed from calculus and sp.solve."""
    f = sp.sympify(expr)
    xv = sp.solve(sp.diff(f, x), x)[0]
    return {"vertex": (xv, sp.simplify(f.subs(x, xv))), "xint": sorted(sp.solve(f, x), key=lambda v: float(sp.N(v))),
            "yint": f.subs(x, 0), "a": sp.Poly(f, x).LC()}


S = C + "quadratic functions: characteristics of graphs (vertex, intercepts, domain and range, extrema)"


def _q1(p):
    f = quad_features((x - 3) ** 2 - 4)
    assert f["vertex"] == (3, -4) and f["xint"] == [1, 5] and f["yint"] == 5
    has_final(p, "Vertex (3, −4)", "axis x = 3", "range y ≥ −4", "x-intercepts 1, 5", "y-intercept 5")


add(S, "For y = (x − 3)² − 4, find the vertex, the axis of symmetry, the range, the x-intercepts and the y-intercept.",
    ["Vertex form y = a(x − p)² + q has vertex (p, q), so the vertex is (3, −4) and the axis is x = 3.",
     "a = 1 > 0, so the parabola opens up and the minimum value is −4. Range: y ≥ −4.",
     "x-intercepts: set y = 0, so (x − 3)² = 4 and x − 3 = ±2, giving x = 5 or x = 1.",
     "y-intercept: set x = 0, so y = (−3)² − 4 = 9 − 4 = 5."],
    "Vertex (3, −4); axis x = 3; range y ≥ −4; x-intercepts 1, 5; y-intercept 5", _q1)


def _q2(p):
    fx = -2 * (x + 1) ** 2 + 8
    f = quad_features(fx)
    assert f["vertex"] == (-1, 8) and f["xint"] == [-3, 1] and f["yint"] == 6 and f["a"] < 0
    has_final(p, "Vertex (−1, 8)", "maximum 8", "range y ≤ 8", "x-intercepts −3, 1", "y-intercept 6")


add(S, "For f(x) = −2(x + 1)² + 8, find the vertex, whether it is a maximum or a minimum, the range, the x-intercepts and the y-intercept.",
    ["Write x + 1 as x − (−1): the vertex is (−1, 8).",
     "a = −2 < 0, so the parabola opens down and 8 is the maximum value. Range: y ≤ 8.",
     "x-intercepts: −2(x + 1)² + 8 = 0 gives (x + 1)² = 4, so x + 1 = ±2 and x = 1 or x = −3.",
     "y-intercept: f(0) = −2(1)² + 8 = 6."],
    "Vertex (−1, 8), maximum 8; range y ≤ 8; x-intercepts −3, 1; y-intercept 6", _q2)


def _q3(p):
    f = quad_features(x ** 2 + 4 * x - 5)
    assert f["vertex"] == (-2, -9) and f["xint"] == [-5, 1] and f["yint"] == -5
    has_final(p, "Vertex (−2, −9)", "x-intercepts −5, 1", "y-intercept −5", "range y ≥ −9")


add(S, "Complete the square on y = x² + 4x − 5 to find the vertex, then find the intercepts and the range.",
    ["Half of 4 is 2, and 2² = 4: y = (x² + 4x + 4) − 4 − 5.",
     "y = (x + 2)² − 9, so the vertex is (−2, −9) and the range is y ≥ −9.",
     "x-intercepts: x² + 4x − 5 = (x + 5)(x − 1) = 0 gives x = −5 or x = 1.",
     "y-intercept: set x = 0, so y = −5."],
    "Vertex (−2, −9); x-intercepts −5, 1; y-intercept −5; range y ≥ −9", _q3)


def _q4(p):
    f = quad_features(2 * x ** 2 - 8 * x + 3)
    assert f["vertex"] == (2, -5) and f["yint"] == 3
    has_final(p, "Vertex (2, −5)", "axis x = 2", "range y ≥ −5", "y-intercept 3")


add(S, "Find the axis of symmetry, the vertex, the range and the y-intercept of f(x) = 2x² − 8x + 3, using x = −b / (2a).",
    ["a = 2, b = −8, so the axis is x = −(−8) / (2 · 2) = 8/4 = 2.",
     "The vertex lies on the axis, so substitute x = 2: f(2) = 2(4) − 8(2) + 3 = 8 − 16 + 3 = −5.",
     "Vertex (2, −5). Since a = 2 > 0 the parabola opens up, so the range is y ≥ −5.",
     "y-intercept: f(0) = 3."],
    "Vertex (2, −5); axis x = 2; range y ≥ −5; y-intercept 3", _q4)


def _q5(p):
    f = lambda v: v ** 2 - 3 * v + 1  # noqa: E731
    assert f(-2) == 11
    assert sp.expand(f(a + 1) - (a ** 2 - a - 1)) == 0
    has_final(p, "f(−2) = 11", "a² − a − 1")


add(S, "If f(x) = x² − 3x + 1, find f(−2) and f(a + 1).",
    ["Replace every x with −2 (use brackets): f(−2) = (−2)² − 3(−2) + 1 = 4 + 6 + 1 = 11.",
     "Replace every x with (a + 1): f(a + 1) = (a + 1)² − 3(a + 1) + 1.",
     "Expand: a² + 2a + 1 − 3a − 3 + 1",
     "Collect like terms: a² − a − 1."],
    "f(−2) = 11 and f(a + 1) = a² − a − 1", _q5)


def _q6(p):
    f = quad_features((x - 2) * (x + 6))
    assert f["xint"] == [-6, 2] and f["vertex"] == (-2, -16) and f["yint"] == -12
    has_final(p, "x-intercepts 2, −6", "x = −2", "(−2, −16)", "y-intercept −12")


add(S, "For y = (x − 2)(x + 6), find the x-intercepts, the axis of symmetry, the vertex and the y-intercept.",
    ["x-intercepts: (x − 2)(x + 6) = 0 gives x = 2 or x = −6.",
     "The axis of symmetry is halfway between the intercepts: (2 + (−6)) / 2 = −4/2 = −2, so x = −2.",
     "Vertex: y = (−2 − 2)(−2 + 6) = (−4)(4) = −16, so the vertex is (−2, −16).",
     "y-intercept: set x = 0, so y = (−2)(6) = −12."],
    "x-intercepts 2, −6; axis x = −2; vertex (−2, −16); y-intercept −12", _q6)


def _q7(p):
    assert sp.expand(3 * (x + 2) ** 2 - 5 - (3 * x ** 2 + 12 * x + 7)) == 0
    has_final(p, "y = 3(x + 2)² − 5", "(−2, −5)")


add(S, "Write y = 3x² + 12x + 7 in vertex form and state the vertex.",
    ["Factor the 3 out of the x-terms only: y = 3(x² + 4x) + 7.",
     "Complete the square inside: x² + 4x + 4 − 4, so y = 3(x² + 4x + 4 − 4) + 7.",
     "Move the −4 out of the bracket, where it is multiplied by 3: y = 3(x + 2)² − 12 + 7.",
     "y = 3(x + 2)² − 5, so the vertex is (−2, −5)."],
    "y = 3(x + 2)² − 5; vertex (−2, −5)", _q7)

S = C + "quadratic functions: exploring transformations"


def _t1(p):
    f = quad_features(-sp.Rational(1, 2) * (x - 4) ** 2 + 3)
    assert f["vertex"] == (4, 3) and f["a"] == sp.Rational(-1, 2)
    has_final(p, "Reflected in the x-axis", "factor 1/2", "right 4", "up 3", "(4, 3)")


add(S, "Describe how the graph of y = −(1/2)(x − 4)² + 3 is obtained from the graph of y = x².",
    ["Compare with y = a(x − p)² + q: a = −1/2, p = 4, q = 3.",
     "The negative sign in a reflects the parabola in the x-axis, so it opens down.",
     "|a| = 1/2 is less than 1, so the graph is compressed vertically by a factor of 1/2 (it is wider).",
     "p = 4 shifts it right 4 and q = 3 shifts it up 3, so the vertex moves from (0, 0) to (4, 3)."],
    "Reflected in the x-axis, vertical compression by factor 1/2, right 4, up 3; vertex (4, 3)", _t1)


def _t2(p):
    fx = Z(fin(p).split("=")[1])
    assert fx.subs(x, 2) == -3 and fx.subs(x, 4) == 5 and sp.diff(fx, x).subs(x, 2) == 0
    assert equiv(fx, "2(x-2)^2-3")


add(S, "A parabola has vertex (2, −3) and passes through the point (4, 5). Write its equation in vertex form.",
    ["Start with vertex form using the vertex (p, q) = (2, −3): y = a(x − 2)² − 3.",
     "Substitute the point (4, 5): 5 = a(4 − 2)² − 3.",
     "5 = 4a − 3, so 4a = 8 and a = 2.",
     "Check: 2(4 − 2)² − 3 = 2(4) − 3 = 5"],
    "y = 2(x − 2)² − 3", _t2)


def _t3(p):
    fx = Z(fin(p).split("=")[1])
    assert fx.subs(x, -1) == 0 and fx.subs(x, 5) == 0 and fx.subs(x, 3) == -16
    assert equiv(fx, "2(x+1)(x-5)")


add(S, "A parabola has x-intercepts −1 and 5 and passes through (3, −16). Write its equation in factored form.",
    ["Use the intercepts: y = a(x + 1)(x − 5).",
     "Substitute (3, −16): −16 = a(3 + 1)(3 − 5).",
     "−16 = a(4)(−2) = −8a, so a = 2.",
     "Check: 2(3 + 1)(3 − 5) = 2(4)(−2) = −16, and at x = 5 the product is 0."],
    "y = 2(x + 1)(x − 5)", _t3)


def _t4(p):
    fx = -(x + 3) ** 2 + 4
    assert fx.subs(x, -1) == 0 and sp.diff(fx, x).subs(x, -3) == 0
    assert sp.expand(fx) == -x ** 2 - 6 * x - 5
    has_final(p, "y = −(x + 3)² + 4", "−x² − 6x − 5")


add(S, "A parabola has vertex (−3, 4) and passes through (−1, 0). Write its equation in vertex form, then expand it to standard form.",
    ["Vertex form with (p, q) = (−3, 4): y = a(x + 3)² + 4.",
     "Substitute (−1, 0): 0 = a(−1 + 3)² + 4, so 0 = 4a + 4 and a = −1.",
     "y = −(x + 3)² + 4",
     "Expand: (x + 3)² = x² + 6x + 9, so y = −x² − 6x − 9 + 4 = −x² − 6x − 5."],
    "y = −(x + 3)² + 4 = −x² − 6x − 5", _t4)

S = C + "quadratic equations: solving (factoring, quadratic formula, completing the square, square root method)"

add(S, "Solve 3(x − 2)² = 48 using the square root method.",
    ["Divide both sides by 3: (x − 2)² = 16.",
     "Take the square root of both sides, keeping both signs: x − 2 = 4 or x − 2 = −4.",
     "x = 6 or x = −2",
     "Check x = −2: 3(−2 − 2)² = 3(16) = 48"],
    "x = 6 or x = −2", lambda p: ok_solve(p, 3 * (x - 2) ** 2 - 48), roots=[6, -2])

add(S, "Solve by factoring: 2x² − 5x − 12 = 0.",
    ["a · c = −24; the numbers with product −24 and sum −5 are −8 and 3.",
     "2x² − 8x + 3x − 12 = 0",
     "2x(x − 4) + 3(x − 4) = 0",
     "(x − 4)(2x + 3) = 0, so x − 4 = 0 or 2x + 3 = 0.",
     "x = 4 or x = −3/2"],
    "x = 4 or x = −3/2", lambda p: ok_solve(p, 2 * x ** 2 - 5 * x - 12), roots=[4, sp.Rational(-3, 2)])

add(S, "Solve with the quadratic formula: 3x² − 4x − 2 = 0. Give exact answers.",
    ["a = 3, b = −4, c = −2.",
     "x = (−b ± √(b² − 4ac)) / (2a) = (4 ± √(16 + 24)) / 6",
     "√40 = √(4 · 10) = 2√10, so x = (4 ± 2√10) / 6.",
     "Divide top and bottom by 2: x = (2 ± √10) / 3."],
    "x = (2 + √10)/3 or x = (2 − √10)/3", lambda p: ok_solve(p, 3 * x ** 2 - 4 * x - 2),
    roots=[(2 + sp.sqrt(10)) / 3, (2 - sp.sqrt(10)) / 3])

add(S, "Solve by completing the square: x² + 6x − 1 = 0. Give exact answers.",
    ["Move the constant: x² + 6x = 1.",
     "Half of 6 is 3 and 3² = 9. Add 9 to both sides: x² + 6x + 9 = 1 + 9.",
     "(x + 3)² = 10",
     "x + 3 = ±√10, so x = −3 + √10 or x = −3 − √10."],
    "x = −3 + √10 or x = −3 − √10", lambda p: ok_solve(p, x ** 2 + 6 * x - 1),
    roots=[-3 + sp.sqrt(10), -3 - sp.sqrt(10)])

add(S, "Solve by completing the square: 2x² − 12x + 7 = 0. Give exact answers.",
    ["Divide every term by 2 so the x² coefficient is 1: x² − 6x + 7/2 = 0.",
     "Move the constant: x² − 6x = −7/2.",
     "Half of −6 is −3 and (−3)² = 9. Add 9 to both sides: x² − 6x + 9 = 9 − 7/2.",
     "(x − 3)² = 11/2",
     "x − 3 = ±√(11/2) = ±√22/2, since √(11/2) = √11/√2 = √22/2.",
     "x = 3 + √22/2 or x = 3 − √22/2"],
    "x = 3 + √22/2 or x = 3 − √22/2", lambda p: ok_solve(p, 2 * x ** 2 - 12 * x + 7),
    roots=[3 + sp.sqrt(22) / 2, 3 - sp.sqrt(22) / 2])

add(S, "Solve x(x + 5) = 14.",
    ["Expand and move everything to one side: x² + 5x = 14, so x² + 5x − 14 = 0.",
     "Factor: product −14, sum 5 gives 7 and −2: (x + 7)(x − 2) = 0.",
     "x = −7 or x = 2",
     "Check x = −7: (−7)(−7 + 5) = (−7)(−2) = 14"],
    "x = −7 or x = 2", lambda p: ok_solve(p, x * (x + 5) - 14), roots=[-7, 2])


def _disc(p):
    assert 36 - 4 * 9 == 0
    assert (-3) ** 2 - 4 * 2 * 5 == -31
    assert sp.solve(x ** 2 + 6 * x + 9, x) == [-3]
    assert sp.solve(2 * x ** 2 - 3 * x + 5, x, dict=False) != [] and all(not v.is_real for v in sp.solve(2 * x ** 2 - 3 * x + 5, x))
    has_final(p, "k = 9", "no real roots")


add(S, "(a) For what value of k does x² + 6x + k = 0 have exactly one real root? (b) How many real roots does 2x² − 3x + 5 = 0 have?",
    ["Use the discriminant D = b² − 4ac: D > 0 gives two real roots, D = 0 gives one, D < 0 gives none.",
     "(a) a = 1, b = 6, c = k: D = 36 − 4k. Set D = 0: 36 = 4k, so k = 9.",
     "Check: x² + 6x + 9 = (x + 3)² = 0 has the single root x = −3.",
     "(b) a = 2, b = −3, c = 5: D = (−3)² − 4(2)(5) = 9 − 40 = −31.",
     "D is negative, so there are no real roots."],
    "(a) k = 9   (b) no real roots", _disc)

add(S, "Solve x² + 4x + 5 = 0 by completing the square. What does your result tell you about the graph of y = x² + 4x + 5?",
    ["Move the constant: x² + 4x = −5.",
     "Add (4/2)² = 4 to both sides: x² + 4x + 4 = −5 + 4.",
     "(x + 2)² = −1",
     "A real number squared is never negative, so there is no real solution.",
     "Vertex form is y = (x + 2)² + 1: the vertex (−2, 1) is above the x-axis and the parabola opens up, so it never touches the x-axis."],
    "no real solution; the parabola has no x-intercepts",
    lambda p: (sp.solve(x ** 2 + 4 * x + 5, x, dict=False) != [] and all(not v.is_real for v in sp.solve(x ** 2 + 4 * x + 5, x)),
               sp.expand((x + 2) ** 2 + 1 - (x ** 2 + 4 * x + 5)) == 0))

S = C + "quadratic equations and functions: solving problems in context"


def _ball(p):
    hh = -5 * t ** 2 + 20 * t + 1
    tv = sp.solve(sp.diff(hh, t), t)[0]
    assert tv == 2 and hh.subs(t, 2) == 21
    assert sorted(sp.solve(hh - 16, t)) == [1, 3]
    has_final(p, "21 m", "t = 2", "t = 1", "t = 3")


add(S, "A ball is thrown so that its height in metres after t seconds is h = −5t² + 20t + 1. (a) Find the maximum height and when it happens. (b) When is the ball 16 m high?",
    ["(a) The maximum is at the vertex, where t = −b / (2a) = −20 / (2 · (−5)) = 2.",
     "h(2) = −5(2)² + 20(2) + 1 = −20 + 40 + 1 = 21, so the maximum height is 21 m after 2 s.",
     "(b) Set h = 16: −5t² + 20t + 1 = 16, so −5t² + 20t − 15 = 0.",
     "Divide by −5: t² − 4t + 3 = 0, so (t − 1)(t − 3) = 0.",
     "The ball is 16 m high at t = 1 s (going up) and t = 3 s (coming down)."],
    "(a) 21 m at t = 2 s   (b) t = 1 s and t = 3 s", _ball)


def _jackets(p):
    n_ = sp.symbols("n_")
    rev = (60 + 2 * n_) * (200 - 4 * n_)
    nv = sp.solve(sp.diff(rev, n_), n_)[0]
    assert nv == 10 and rev.subs(n_, 10) == 12800 and 60 + 2 * nv == 80
    has_final(p, "$80", "$12,800")


add(S, "A store sells 200 jackets a week at $60. For every $2 increase in price, it sells 4 fewer jackets. What price gives the greatest weekly revenue, and what is that revenue?",
    ["Let n be the number of $2 increases. Price: 60 + 2n. Jackets sold: 200 − 4n.",
     "Revenue R = (60 + 2n)(200 − 4n) = 12000 − 240n + 400n − 8n² = −8n² + 160n + 12000.",
     "Vertex: n = −160 / (2 · (−8)) = 10.",
     "Price = 60 + 2(10) = $80. Revenue = (80)(200 − 40) = 80 · 160 = $12,800."],
    "$80 per jacket, revenue $12,800", _jackets)


def _fence(p):
    w_ = sp.symbols("w_")
    area = w_ * (40 - 2 * w_)
    wv = sp.solve(sp.diff(area, w_), w_)[0]
    assert wv == 10 and area.subs(w_, 10) == 200 and 40 - 2 * wv == 20
    has_final(p, "10 m", "20 m", "200 m²")


add(S, "A farmer has 40 m of fence to enclose a rectangular pen against a straight river. No fence is needed along the river. What dimensions give the greatest area?",
    ["Let w be the width (the two sides touching the river). The side parallel to the river is 40 − 2w.",
     "Area A = w(40 − 2w) = −2w² + 40w.",
     "Vertex: w = −40 / (2 · (−2)) = 10.",
     "Parallel side: 40 − 2(10) = 20. Area: 10 · 20 = 200."],
    "10 m by 20 m (20 m along the river), area 200 m²", _fence)

add(S, "Two numbers add to 14 and multiply to 48. Find them.",
    ["Let one number be x. The other is 14 − x.",
     "Product: x(14 − x) = 48, so 14x − x² = 48 and x² − 14x + 48 = 0.",
     "(x − 6)(x − 8) = 0, so x = 6 or x = 8.",
     "The two numbers are 6 and 8: 6 + 8 = 14 and 6 · 8 = 48."],
    "6 and 8", lambda p: (sorted(sp.solve(x * (14 - x) - 48, x)) == [6, 8], has_final(p, "6", "8")), roots=[6, 8])

add(S, "A garden is 12 m by 8 m. A path of the same width is built all the way around it. The garden and path together cover 192 m². How wide is the path?",
    ["Let the path be w metres wide. The outside rectangle is (12 + 2w) by (8 + 2w).",
     "(12 + 2w)(8 + 2w) = 192",
     "96 + 24w + 16w + 4w² = 192, so 4w² + 40w − 96 = 0.",
     "Divide by 4: w² + 10w − 24 = 0, so (w + 12)(w − 2) = 0.",
     "w = 2 (reject w = −12, a width cannot be negative).",
     "Check: (12 + 4)(8 + 4) = 16 · 12 = 192"],
    "2 m", lambda p: (sp.solve((12 + 2 * w) * (8 + 2 * w) - 192, w) == [-12, 2], has_final(p, "2 m")), roots=[2], var=w)


def _profit(p):
    P = -2 * n ** 2 + 80 * n - 600
    assert sorted(sp.solve(P, n)) == [10, 30]
    nv = sp.solve(sp.diff(P, n), n)[0]
    assert nv == 20 and P.subs(n, 20) == 200
    has_final(p, "$10 and $30", "$20", "$200")


add(S, "A school club's profit in dollars is P = −2n² + 80n − 600, where n is the ticket price in dollars. Find the ticket prices at which the club breaks even, and the price that gives the greatest profit.",
    ["Break even means P = 0: −2n² + 80n − 600 = 0.",
     "Divide by −2: n² − 40n + 300 = 0, so (n − 10)(n − 30) = 0 and n = 10 or n = 30.",
     "The maximum is halfway between the break-even prices: n = (10 + 30) / 2 = 20.",
     "P(20) = −2(400) + 80(20) − 600 = −800 + 1600 − 600 = 200."],
    "Break even at $10 and $30; greatest profit $200 at $20", _profit)


# ---------------------------------------------------------------- linear and quadratic inequalities
S = C + "linear and quadratic inequalities (single variable, interval notation, sign analysis, restrictions)"
R = sp.S.Reals


def ineq_set(expr_rel):
    return sp.solve_univariate_inequality(expr_rel, x, relational=False)


add(S, "Solve 3x − 7 ≤ −4 and write the answer in interval notation.",
    ["Add 7 to both sides: 3x ≤ 3",
     "Divide by 3 (positive, so the sign stays): x ≤ 1",
     "Interval notation: (−∞, 1], with a square bracket because 1 is included.",
     "Check x = 0: 3(0) − 7 = −7 ≤ −4"],
    "x ≤ 1, or (−∞, 1]", lambda p: (ineq_set(3 * x - 7 <= -4) == sp.Interval(-sp.oo, 1), has_final(p, "x ≤ 1", "(−∞, 1]")))

add(S, "Solve −2x + 5 > 11 and write the answer in interval notation.",
    ["Subtract 5 from both sides: −2x > 6",
     "Divide by −2. Dividing by a negative number flips the inequality sign: x < −3",
     "Interval notation: (−∞, −3), with a round bracket because −3 is not included.",
     "Check x = −4: −2(−4) + 5 = 13 > 11"],
    "x < −3, or (−∞, −3)", lambda p: (ineq_set(-2 * x + 5 > 11) == sp.Interval.open(-sp.oo, -3), has_final(p, "x < −3", "(−∞, −3)")))

add(S, "Solve [[2x − 1//3]] ≥ x − 2.",
    ["Multiply both sides by 3 (positive, so the sign stays): 2x − 1 ≥ 3(x − 2)",
     "2x − 1 ≥ 3x − 6",
     "Subtract 3x from both sides and add 1: −x ≥ −5",
     "Divide by −1 and flip the sign: x ≤ 5",
     "Check x = 5: 9/3 = 3 and 5 − 2 = 3, so 3 ≥ 3 is true."],
    "x ≤ 5, or (−∞, 5]", lambda p: (ineq_set((2 * x - 1) / 3 >= x - 2) == sp.Interval(-sp.oo, 5), has_final(p, "x ≤ 5", "(−∞, 5]")))

add(S, "Solve x² − 5x + 6 > 0 using sign analysis.",
    ["Factor: (x − 2)(x − 3) > 0. The zeros are x = 2 and x = 3.",
     "The zeros split the number line into x < 2, 2 < x < 3 and x > 3. Test one value in each.",
     "x = 0: (−2)(−3) = 6, positive. x = 2.5: (0.5)(−0.5) = −0.25, negative. x = 4: (2)(1) = 2, positive.",
     "We want positive, and the zeros themselves give 0 (not > 0), so x < 2 or x > 3."],
    "x < 2 or x > 3, i.e. (−∞, 2) ∪ (3, ∞)",
    lambda p: (ineq_set(x ** 2 - 5 * x + 6 > 0) == sp.Union(sp.Interval.open(-sp.oo, 2), sp.Interval.open(3, sp.oo)),
               has_final(p, "x < 2 or x > 3", "(−∞, 2) ∪ (3, ∞)")))

add(S, "Solve x² + 2x − 8 ≤ 0 and write the answer in interval notation.",
    ["Factor: (x + 4)(x − 2) ≤ 0. The zeros are x = −4 and x = 2.",
     "The parabola y = x² + 2x − 8 opens up, so it is below the x-axis between the zeros.",
     "The zeros are included because the sign is ≤: −4 ≤ x ≤ 2.",
     "Check x = 0: 0 + 0 − 8 = −8 ≤ 0"],
    "−4 ≤ x ≤ 2, or [−4, 2]", lambda p: (ineq_set(x ** 2 + 2 * x - 8 <= 0) == sp.Interval(-4, 2), has_final(p, "−4 ≤ x ≤ 2", "[−4, 2]")))

add(S, "Solve 2x² − x − 6 ≥ 0 and write the answer in interval notation.",
    ["Factor: a · c = −12; the numbers with product −12 and sum −1 are −4 and 3.",
     "2x² − 4x + 3x − 6 = 2x(x − 2) + 3(x − 2) = (x − 2)(2x + 3) ≥ 0. The zeros are x = 2 and x = −3/2.",
     "The parabola opens up, so it is above the x-axis outside the zeros.",
     "Zeros are included: x ≤ −3/2 or x ≥ 2."],
    "x ≤ −3/2 or x ≥ 2, i.e. (−∞, −3/2] ∪ [2, ∞)",
    lambda p: (ineq_set(2 * x ** 2 - x - 6 >= 0) == sp.Union(sp.Interval(-sp.oo, sp.Rational(-3, 2)), sp.Interval(2, sp.oo)),
               has_final(p, "x ≤ −3/2 or x ≥ 2")))


def _sign(p):
    f = -x ** 2 + 4 * x - 3
    assert sp.solve(f, x) == [1, 3]
    assert ineq_set(f > 0) == sp.Interval.open(1, 3)
    assert ineq_set(f < 0) == sp.Union(sp.Interval.open(-sp.oo, 1), sp.Interval.open(3, sp.oo))
    has_final(p, "positive for 1 < x < 3", "negative for x < 1 or x > 3", "zero at x = 1 and x = 3")


add(S, "For f(x) = −x² + 4x − 3, find the intervals where f is positive, negative and zero.",
    ["Factor: f(x) = −(x² − 4x + 3) = −(x − 1)(x − 3). The zeros are x = 1 and x = 3.",
     "a = −1 < 0, so the parabola opens down: it is above the x-axis between the zeros and below it outside them.",
     "Test x = 2: f(2) = −4 + 8 − 3 = 1 > 0. Test x = 0: f(0) = −3 < 0. Test x = 4: f(4) = −16 + 16 − 3 = −3 < 0."],
    "f is positive for 1 < x < 3, negative for x < 1 or x > 3, zero at x = 1 and x = 3", _sign)

add(S, "Solve x² − 6x + 9 ≤ 0.",
    ["Factor: (x − 3)² ≤ 0.",
     "A square is never negative, so (x − 3)² ≤ 0 can only be true when (x − 3)² = 0.",
     "x − 3 = 0, so x = 3.",
     "Picture: the parabola y = (x − 3)² touches the x-axis at its vertex (3, 0) and is above it everywhere else."],
    "x = 3 only", lambda p: (ineq_set(x ** 2 - 6 * x + 9 <= 0) == sp.FiniteSet(3), has_final(p, "x = 3")))


def _profit_ineq(p):
    P = -3 * n ** 2 + 90 * n - 600
    assert sp.solve_univariate_inequality(P > 0, n, relational=False) == sp.Interval.open(10, 20)
    assert P.subs(n, 15) == 75
    has_final(p, "between $10 and $20")


add(S, "A drama club's profit in dollars is P = −3n² + 90n − 600, where n is the ticket price in dollars. For which ticket prices does the club make a profit?",
    ["A profit means P > 0: −3n² + 90n − 600 > 0.",
     "Divide by −3 and flip the sign: n² − 30n + 200 < 0, so (n − 10)(n − 20) < 0.",
     "The zeros are n = 10 and n = 20. A positive-opening parabola is below the axis between its zeros.",
     "So 10 < n < 20. Check n = 15: −675 + 1350 − 600 = 75 > 0."],
    "Ticket prices between $10 and $20", _profit_ineq)


def _dom_range(p):
    hh = -5 * t ** 2 + 20 * t
    assert sp.solve(hh, t) == [0, 4] and hh.subs(t, 2) == 20
    has_final(p, "0 ≤ t ≤ 4", "0 ≤ h ≤ 20")


add(S, "A ball is kicked from the ground so that its height in metres after t seconds is h = −5t² + 20t. State the domain and range that make sense in this situation.",
    ["The ball is in the air while h ≥ 0: −5t² + 20t ≥ 0, so −5t(t − 4) ≥ 0.",
     "The zeros are t = 0 and t = 4, and the parabola opens down, so h ≥ 0 between them: domain 0 ≤ t ≤ 4.",
     "The maximum is at t = 2: h = −5(4) + 20(2) = −20 + 40 = 20.",
     "The height goes from 0 up to 20 and back to 0, so the range is 0 ≤ h ≤ 20."],
    "Domain 0 ≤ t ≤ 4 (seconds); range 0 ≤ h ≤ 20 (metres)", _dom_range)

# ---------------------------------------------------------------- trigonometry
S = C + "trigonometry: angles in standard position, reference and coterminal angles, terminal arm"


def sd(a_):
    return math.sin(math.radians(a_))


def cd(a_):
    return math.cos(math.radians(a_))


def td(a_):
    return math.tan(math.radians(a_))


def degs(p):
    return [float(v) for v in re.findall(r"(-?\d+(?:\.\d+)?)°", fin(p).replace("−", "-"))]


def _t1(p):
    a0 = 210
    assert 180 < a0 < 270 and a0 - 180 == 30 and a0 + 360 == 570 and a0 - 360 == -150
    has_final(p, "Quadrant III", "30°", "570°", "−150°")


add(S, "The angle 210° is in standard position. Name its quadrant, its reference angle, and the two coterminal angles found by adding one full turn and by subtracting one full turn.",
    ["Standard position: vertex at the origin, initial arm on the positive x-axis, rotating counterclockwise.",
     "180° < 210° < 270°, so the terminal arm is in Quadrant III.",
     "Reference angle = 210° − 180° = 30°.",
     "One full turn is 360°. Add it: 210° + 360° = 570°. Subtract it: 210° − 360° = −150°."],
    "Quadrant III; reference angle 30°; coterminal angles 570° and −150°", _t1)


def _t2(p):
    r_ = math.hypot(-3, 4)
    assert r_ == 5
    assert close(math.degrees(math.atan2(4, -3)), 126.87, 0.01)
    has_final(p, "r = 5", "sin θ = 4/5", "cos θ = −3/5", "tan θ = −4/3", "126.9°")


add(S, "The point P(−3, 4) is on the terminal arm of an angle θ in standard position. Find r, sin θ, cos θ, tan θ and θ to the nearest tenth of a degree (0° ≤ θ < 360°).",
    ["r = √((−3)² + 4²) = √(9 + 16) = √25 = 5.",
     "sin θ = y/r = 4/5, cos θ = x/r = −3/5, tan θ = y/x = 4/(−3) = −4/3.",
     "Reference angle: tan⁻¹(4/3) ≈ 53.1°.",
     "x < 0 and y > 0, so P is in Quadrant II: θ = 180° − 53.1° = 126.9°."],
    "r = 5; sin θ = 4/5, cos θ = −3/5, tan θ = −4/3; θ ≈ 126.9°", _t2)


def _t3(p):
    ang = sp.rad(150)
    assert sp.simplify(sp.sin(ang) - sp.Rational(1, 2)) == 0
    assert sp.simplify(sp.cos(ang) + sp.sqrt(3) / 2) == 0
    assert sp.simplify(sp.tan(ang) + sp.sqrt(3) / 3) == 0
    has_final(p, "sin 150° = 1/2", "cos 150° = −√3/2", "tan 150° = −√3/3")


add(S, "Use a 30-60-90 triangle to find the exact values of sin 150°, cos 150° and tan 150°.",
    ["150° is in Quadrant II, and its reference angle is 180° − 150° = 30°.",
     "In a 30-60-90 triangle with hypotenuse 2, the sides are 1 (opposite 30°), √3 (opposite 60°).",
     "So sin 30° = 1/2, cos 30° = √3/2, tan 30° = 1/√3 = √3/3.",
     "In Quadrant II, sine is positive and cosine and tangent are negative.",
     "sin 150° = 1/2, cos 150° = −√3/2, tan 150° = −√3/3"],
    "sin 150° = 1/2, cos 150° = −√3/2, tan 150° = −√3/3", _t3)


def _t4(p):
    ang = sp.rad(225)
    assert sp.simplify(sp.sin(ang) + sp.sqrt(2) / 2) == 0 and sp.simplify(sp.cos(ang) + sp.sqrt(2) / 2) == 0
    assert sp.simplify(sp.tan(ang) - 1) == 0
    has_final(p, "sin 225° = −√2/2", "cos 225° = −√2/2", "tan 225° = 1")


add(S, "Use a 45-45-90 triangle to find the exact values of sin 225°, cos 225° and tan 225°.",
    ["225° is in Quadrant III, and its reference angle is 225° − 180° = 45°.",
     "In a 45-45-90 triangle with hypotenuse 1, each leg is √2/2, so sin 45° = cos 45° = √2/2 and tan 45° = 1.",
     "In Quadrant III, sine and cosine are negative and tangent is positive.",
     "sin 225° = −√2/2, cos 225° = −√2/2, tan 225° = 1"],
    "sin 225° = −√2/2, cos 225° = −√2/2, tan 225° = 1", _t4)


def _t5(p):
    assert -400 + 720 == 320 and 320 > 270 and 360 - 320 == 40
    has_final(p, "320°", "Quadrant IV", "40°")


add(S, "For the angle −400° in standard position, find the coterminal angle between 0° and 360°, the quadrant, and the reference angle.",
    ["A negative angle rotates clockwise. Add full turns of 360° until the angle is between 0° and 360°.",
     "−400° + 360° = −40°, which is still negative, so add 360° again: −40° + 360° = 320°.",
     "270° < 320° < 360°, so the terminal arm is in Quadrant IV.",
     "Reference angle = 360° − 320° = 40°."],
    "Coterminal angle 320°; Quadrant IV; reference angle 40°", _t5)


def _t6(p):
    s_ = sp.Rational(5, 13)
    c_ = -sp.sqrt(1 - s_ ** 2)
    assert c_ == sp.Rational(-12, 13) and s_ / c_ == sp.Rational(-5, 12)
    has_final(p, "cos θ = −12/13", "tan θ = −5/12")


add(S, "Angle θ is in Quadrant II and sin θ = 5/13. Find cos θ and tan θ.",
    ["Draw a right triangle with opposite side 5 and hypotenuse 13. The adjacent side is √(13² − 5²) = √(169 − 25) = √144 = 12.",
     "In Quadrant II the x-coordinate is negative, so the adjacent side is −12.",
     "cos θ = x/r = −12/13",
     "tan θ = y/x = 5/(−12) = −5/12"],
    "cos θ = −12/13, tan θ = −5/12", _t6)

S = C + "trigonometry: unit circle"


def _u1(p):
    assert sp.Rational(-3, 5) ** 2 + sp.Rational(-4, 5) ** 2 == 1
    assert close(180 + math.degrees(math.atan(4 / 3)), 233.13, 0.01)
    has_final(p, "233.1°", "sin θ = −4/5")


add(S, "The point (−3/5, −4/5) is on the unit circle. Verify it, then find sin θ, cos θ and the angle θ (0° ≤ θ < 360°) to the nearest tenth of a degree.",
    ["Check: (−3/5)² + (−4/5)² = 9/25 + 16/25 = 25/25 = 1, so it is on the unit circle.",
     "On the unit circle, the point is (cos θ, sin θ), so cos θ = −3/5 and sin θ = −4/5.",
     "Both coordinates are negative: Quadrant III. Reference angle = tan⁻¹((4/5)/(3/5)) = tan⁻¹(4/3) ≈ 53.1°.",
     "θ = 180° + 53.1° = 233.1°"],
    "cos θ = −3/5, sin θ = −4/5, θ ≈ 233.1°", _u1)


def _u2(p):
    val = sp.sin(sp.rad(240)) + sp.cos(sp.rad(300)) - sp.tan(sp.rad(135))
    assert sp.simplify(val - (3 - sp.sqrt(3)) / 2) == 0
    has_final(p, "(3 − √3)/2")


add(S, "Find the exact value of sin 240° + cos 300° − tan 135°.",
    ["sin 240°: Quadrant III, reference angle 60°, sine negative: −√3/2.",
     "cos 300°: Quadrant IV, reference angle 60°, cosine positive: 1/2.",
     "tan 135°: Quadrant II, reference angle 45°, tangent negative: −1.",
     "−√3/2 + 1/2 − (−1) = −√3/2 + 1/2 + 1 = 3/2 − √3/2",
     "3/2 − √3/2 = (3 − √3)/2"],
    "(3 − √3)/2", _u2)


def _u3(p):
    ang = sp.rad(300)
    assert sp.simplify(sp.cos(ang) - sp.Rational(1, 2)) == 0 and sp.simplify(sp.sin(ang) + sp.sqrt(3) / 2) == 0
    assert sp.Rational(1, 4) + sp.Rational(3, 4) == 1
    has_final(p, "(1/2, −√3/2)")


add(S, "Find the exact coordinates of the point where the terminal arm of 300° meets the unit circle.",
    ["On the unit circle, the point for angle θ is (cos θ, sin θ).",
     "300° is in Quadrant IV with reference angle 360° − 300° = 60°.",
     "cos 60° = 1/2 and sin 60° = √3/2. In Quadrant IV, x is positive and y is negative.",
     "Point: (1/2, −√3/2). Check: (1/2)² + (√3/2)² = 1/4 + 3/4 = 1."],
    "(1/2, −√3/2)", _u3)


def _u4(p):
    xv = -math.sqrt(1 - 0.6 ** 2)
    assert math.isclose(xv, -0.8, abs_tol=1e-12)
    assert close(180 - math.degrees(math.asin(0.6)), 143.13, 0.01)
    has_final(p, "x = −0.8", "143.1°")


add(S, "A point (x, 0.6) is on the unit circle in Quadrant II. Find x, and find the angle θ to the nearest tenth of a degree (0° ≤ θ < 360°).",
    ["Every point on the unit circle satisfies x² + y² = 1, so x² + 0.6² = 1.",
     "x² = 1 − 0.36 = 0.64, so x = ±0.8. Quadrant II has negative x, so x = −0.8.",
     "Here sin θ = y = 0.6, so the reference angle is sin⁻¹(0.6) ≈ 36.9°.",
     "θ = 180° − 36.9° = 143.1°"],
    "x = −0.8, θ ≈ 143.1°", _u4)

S = C + "trigonometry: simple trigonometric equations"


def eq_check(p, vals):
    got = sorted(degs(p))
    assert len(got) == len(vals) and all(close(g, v, 0.051) for g, v in zip(got, sorted(vals))), (got, vals)


add(S, "Solve sin θ = 1/2 for 0° ≤ θ < 360°.",
    ["sin 30° = 1/2, so the reference angle is 30°.",
     "Sine is positive in Quadrants I and II.",
     "Quadrant I: θ = 30°. Quadrant II: θ = 180° − 30° = 150°."],
    "θ = 30° or θ = 150°", lambda p: (eq_check(p, [30, 150]), sd(30) == 0.49999999999999994 or close(sd(150), 0.5, 1e-9)))

add(S, "Solve 2cos θ + √2 = 0 for 0° ≤ θ < 360°.",
    ["Isolate cosine: 2cos θ = −√2, so cos θ = −√2/2.",
     "cos 45° = √2/2, so the reference angle is 45°.",
     "Cosine is negative in Quadrants II and III.",
     "Quadrant II: 180° − 45° = 135°. Quadrant III: 180° + 45° = 225°."],
    "θ = 135° or θ = 225°", lambda p: (eq_check(p, [135, 225]), all(close(2 * cd(v) + math.sqrt(2), 0, 1e-9) for v in (135, 225))))

add(S, "Solve tan θ = −1 for 0° ≤ θ < 360°.",
    ["tan 45° = 1, so the reference angle is 45°.",
     "Tangent is negative in Quadrants II and IV.",
     "Quadrant II: 180° − 45° = 135°. Quadrant IV: 360° − 45° = 315°.",
     "Check: tan 135° = sin 135° / cos 135° = (√2/2) / (−√2/2) = −1"],
    "θ = 135° or θ = 315°", lambda p: (eq_check(p, [135, 315]), all(close(td(v), -1, 1e-9) for v in (135, 315))))

add(S, "Solve cos θ = 0.3 for 0° ≤ θ < 360°. Give answers to the nearest tenth of a degree.",
    ["Reference angle: cos⁻¹(0.3) ≈ 72.5° (use the positive value to find it).",
     "Cosine is positive in Quadrants I and IV.",
     "Quadrant I: θ ≈ 72.5°. Quadrant IV: θ ≈ 360° − 72.5° = 287.5°.",
     "Check: cos 287.5° ≈ 0.30"],
    "θ ≈ 72.5° or θ ≈ 287.5°", lambda p: (eq_check(p, [72.5, 287.5]), all(close(cd(v), 0.3, 0.001) for v in (72.5, 287.5))))

add(S, "Solve 4 sin θ − 3 = 0 for 0° ≤ θ < 360°. Give answers to the nearest tenth of a degree.",
    ["Isolate sine: 4 sin θ = 3, so sin θ = 3/4 = 0.75.",
     "Reference angle: sin⁻¹(0.75) ≈ 48.6°.",
     "Sine is positive in Quadrants I and II.",
     "Quadrant I: θ ≈ 48.6°. Quadrant II: θ ≈ 180° − 48.6° = 131.4°."],
    "θ ≈ 48.6° or θ ≈ 131.4°", lambda p: (eq_check(p, [48.6, 131.4]), all(close(4 * sd(v) - 3, 0, 0.003) for v in (48.6, 131.4))))

S = C + "trigonometry: sine law and cosine law (non-right triangles, ambiguous case, contextual problems)"

add(S, "In triangle ABC, ∠A = 50°, ∠B = 70° and a = 12 cm. Find side b to the nearest tenth.",
    ["Side a is opposite ∠A and side b is opposite ∠B. Use the sine law: a / sin A = b / sin B.",
     "12 / sin 50° = b / sin 70°",
     "b = 12 sin 70° / sin 50°",
     "b ≈ 12(0.9397) / 0.7660 ≈ 14.7"],
    "b ≈ 14.7 cm", lambda p: (close(12 * sd(70) / sd(50), 14.7), has_final(p, "14.7")))

add(S, "In triangle ABC, ∠A = 110°, a = 15 cm and b = 9 cm. Find ∠B to the nearest tenth of a degree. Is there more than one triangle?",
    ["Sine law: sin B / b = sin A / a, so sin B = 9 sin 110° / 15.",
     "sin B ≈ 9(0.9397) / 15 ≈ 0.5638",
     "B = sin⁻¹(0.5638) ≈ 34.3°. The other angle with this sine is 180° − 34.3° = 145.7°.",
     "145.7° + 110° = 255.7° is more than 180°, so it is impossible. ∠A is obtuse, so ∠B must be acute. Only one triangle."],
    "∠B ≈ 34.3°; only one triangle",
    lambda p: (close(math.degrees(math.asin(9 * sd(110) / 15)), 34.3), 145.7 + 110 > 180, has_final(p, "34.3°", "one triangle")))


def _amb(p):
    A_, a_, b_ = 30, 8, 11
    sB = b_ * sd(A_) / a_
    B1 = math.degrees(math.asin(sB))
    B2 = 180 - B1
    C1, C2 = 180 - A_ - B1, 180 - A_ - B2
    c1, c2 = a_ * sd(C1) / sd(A_), a_ * sd(C2) / sd(A_)
    assert b_ * sd(A_) < a_ < b_  # height < a < b : two triangles
    assert close(B1, 43.4) and close(C1, 106.6) and close(c1, 15.3) and close(B2, 136.6) and close(C2, 13.4) and close(c2, 3.7)
    has_final(p, "43.4°", "106.6°", "15.3", "136.6°", "13.4°", "3.7")


add(S, "In triangle ABC, ∠A = 30°, a = 8 cm and b = 11 cm. How many triangles are possible? Find every missing angle and side, to the nearest tenth.",
    ["Compare a with the height h = b sin A = 11 sin 30° = 5.5. Since h < a < b, there are two triangles.",
     "sin B = 11 sin 30° / 8 = 0.6875, so B ≈ 43.4° or B = 180° − 43.4° = 136.6°.",
     "Triangle 1: C = 180° − 30° − 43.4° = 106.6°, and c = 8 sin 106.6° / sin 30° ≈ 15.3.",
     "Triangle 2: C = 180° − 30° − 136.6° = 13.4°, and c = 8 sin 13.4° / sin 30° ≈ 3.7."],
    "Two: B = 43.4°, C = 106.6°, c ≈ 15.3 cm; or B = 136.6°, C = 13.4°, c ≈ 3.7 cm", _amb)


def _none(p):
    assert 10 * sd(40) / 5 > 1 and close(10 * sd(40), 6.43, 0.01)
    has_final(p, "No triangle")


add(S, "In triangle ABC, ∠A = 40°, a = 5 cm and b = 10 cm. How many triangles are possible?",
    ["Find the height from C to side c: h = b sin A = 10 sin 40° ≈ 6.43.",
     "Side a = 5 is shorter than h ≈ 6.43, so it cannot reach the base.",
     "The sine law agrees: sin B = 10 sin 40° / 5 ≈ 1.29, which is greater than 1, and no angle has that sine."],
    "No triangle is possible", _none)

add(S, "Two sides of a triangle are 5 cm and 8 cm and the angle between them is 60°. Find the third side.",
    ["Cosine law: c² = a² + b² − 2ab cos C.",
     "c² = 5² + 8² − 2(5)(8) cos 60° = 25 + 64 − 80(0.5)",
     "c² = 89 − 40 = 49",
     "c = √49 = 7"],
    "7 cm", lambda p: (math.isclose(math.sqrt(25 + 64 - 2 * 5 * 8 * cd(60)), 7, abs_tol=1e-9), has_final(p, "7 cm")))

add(S, "A triangle has sides 7 cm, 8 cm and 13 cm. Find its largest angle.",
    ["The largest angle is opposite the longest side, 13 cm. Call it C.",
     "Cosine law: c² = a² + b² − 2ab cos C, so cos C = (a² + b² − c²) / (2ab).",
     "cos C = (49 + 64 − 169) / (2 · 7 · 8) = −56 / 112 = −0.5",
     "C = cos⁻¹(−0.5) = 120° (obtuse, because the cosine is negative)."],
    "120°", lambda p: (close(math.degrees(math.acos((49 + 64 - 169) / (2 * 7 * 8))), 120, 1e-9), has_final(p, "120°")))

add(S, "Two hikers leave the same trailhead on trails that are 120° apart. After two hours, one has walked 6 km and the other 10 km. How far apart are they?",
    ["Draw a triangle: the two trails are sides of length 6 and 10, and the angle between them is 120°.",
     "Cosine law: d² = 6² + 10² − 2(6)(10) cos 120°",
     "cos 120° = −0.5, so d² = 36 + 100 − 120(−0.5) = 136 + 60 = 196",
     "d = √196 = 14"],
    "14 km", lambda p: (math.isclose(math.sqrt(36 + 100 - 120 * cd(120)), 14, abs_tol=1e-9), has_final(p, "14 km")))


def _river(p):
    A_, B_, AB = 70, 50, 50
    C_ = 180 - A_ - B_
    AC = AB * sd(B_) / sd(C_)
    width = AC * sd(A_)
    assert C_ == 60 and close(AC, 44.2, 0.06) and close(width, 41.6, 0.06)
    has_final(p, "41.6")


add(S, "To find the width of a river, a surveyor marks points A and B 50 m apart on one bank. She sights a tree C on the opposite bank: ∠CAB = 70° and ∠CBA = 50°. How wide is the river, to the nearest tenth of a metre?",
    ["Third angle: ∠C = 180° − 70° − 50° = 60°.",
     "Sine law to find AC (opposite ∠B): AC / sin 50° = 50 / sin 60°, so AC = 50 sin 50° / sin 60° ≈ 44.2 m.",
     "The width is the distance from C straight to line AB, which is the height of the triangle.",
     "Width = AC sin 70° ≈ 44.2 · 0.9397 ≈ 41.6 m."],
    "≈ 41.6 m", _river)


def _tower(p):
    P1T = 40 * sd(30) / sd(15)
    height = P1T * sd(45)
    assert close(height, 54.64, 0.01) and close(20 * (math.sqrt(3) + 1), 54.64, 0.01)
    has_final(p, "54.6")


add(S, "From a point on level ground the angle of elevation to the top of a tower is 30°. After walking 40 m straight toward the tower, the angle of elevation is 45°. How tall is the tower, to the nearest tenth of a metre?",
    ["Label the first point P, the second point Q (40 m closer) and the top of the tower T.",
     "At Q the interior angle PQT is 180° − 45° = 135°, so ∠PTQ = 180° − 30° − 135° = 15°.",
     "Sine law in triangle PQT: QT / sin 30° = PQ / sin 15°, so QT = 40 sin 30° / sin 15° ≈ 77.3 m.",
     "In the right triangle at Q, height = QT sin 45° ≈ 77.3 · 0.7071 ≈ 54.6 m."],
    "≈ 54.6 m", _tower)


# ---------------------------------------------------------------- financial literacy
S = C + "financial literacy: compound interest, investments and loans, buy/lease"


def money(p):
    """Dollar amounts in final_answer, in order, with thousands separators removed."""
    return [float(v.replace(",", "").replace(" ", "")) for v in re.findall(r"\$([\d][\d, ]*(?:\.\d+)?)", fin(p))]


def money_is(p, *wanted):
    got = money(p)
    assert len(got) == len(wanted) and all(abs(g - w_) <= 0.0051 for g, w_ in zip(got, wanted)), (got, wanted)


add(S, "You invest $2000 at 6% per year compounded monthly for 5 years. How much is it worth at the end?",
    ["Use A = P(1 + i)^N, where i = 0.06 / 12 = 0.005 per month and N = 12 × 5 = 60 months.",
     "A = 2000(1.005)^60",
     "(1.005)^60 ≈ 1.34885",
     "A ≈ 2000 × 1.34885 ≈ $2,697.70"],
    "$2,697.70", lambda p: (money_is(p, round(2000 * 1.005 ** 60, 2)), has_steps(p, f"{1.005 ** 60:.5f}")))

add(S, "How much should you deposit today at 4% per year compounded quarterly to have $5000 in 6 years?",
    ["Solve A = P(1 + i)^N for P: P = A / (1 + i)^N.",
     "i = 0.04 / 4 = 0.01 per quarter and N = 4 × 6 = 24 quarters.",
     "(1.01)^24 ≈ 1.26973",
     "P = 5000 / 1.26973 ≈ $3,937.83"],
    "$3,937.83", lambda p: (money_is(p, round(5000 / 1.01 ** 24, 2)), has_steps(p, f"{1.01 ** 24:.5f}")))

add(S, "An investment earns 7.2% per year compounded annually. Using a calculator and trial and error, find the smallest whole number of years in which it at least doubles.",
    ["Doubling means A = 2P, so P(1.072)^n = 2P. Divide by P: (1.072)^n = 2.",
     "Try n = 8: (1.072)^8 ≈ 1.74405, which is less than 2.",
     "Try n = 9: (1.072)^9 ≈ 1.86962, which is still less than 2.",
     "Try n = 10: (1.072)^10 ≈ 2.00423, which is more than 2.",
     "The value first passes 2 at n = 10 years."],
    "10 years",
    lambda p: (1.072 ** 9 < 2 <= 1.072 ** 10, min(k_ for k_ in range(1, 30) if 1.072 ** k_ >= 2) == 10,
               has_final(p, "10 years"),
               has_steps(p, f"{1.072 ** 8:.5f}", f"{1.072 ** 9:.5f}", f"{1.072 ** 10:.5f}")))

add(S, "Which is worth more after 10 years: $1000 at 5% per year compounded annually, or $1000 at 4.9% per year compounded monthly?",
    ["Annual: A = 1000(1.05)^10 ≈ 1000 × 1.62889 ≈ $1,628.89.",
     "Monthly: i = 0.049 / 12 ≈ 0.004083 and N = 12 × 10 = 120.",
     "A = 1000(1 + 0.049/12)^120 ≈ 1000 × 1.63069 ≈ $1,630.69.",
     "$1,630.69 is more than $1,628.89, so the 4.9% account compounded monthly wins by about $1.80."],
    "The 4.9% monthly account: $1,630.69 versus $1,628.89",
    lambda p: (money_is(p, round(1000 * (1 + 0.049 / 12) ** 120, 2), round(1000 * 1.05 ** 10, 2)),
               1000 * (1 + 0.049 / 12) ** 120 > 1000 * 1.05 ** 10,
               has_steps(p, f"{1.05 ** 10:.5f}", f"{(1 + 0.049 / 12) ** 120:.5f}")))


def _ear(p):
    ear = 1.01 ** 12 - 1
    assert close(ear * 100, 12.68, 0.005)
    has_final(p, "12.68%")
    has_steps(p, f"{1.01 ** 12:.5f}")


add(S, "A credit card charges 12% per year compounded monthly. What is the effective annual rate?",
    ["Monthly rate: i = 0.12 / 12 = 0.01.",
     "Growth in one year: (1.01)^12 ≈ 1.12683",
     "Effective annual rate = 1.12683 − 1 = 0.12683, about 12.68%.",
     "It is higher than 12% because interest is charged on interest."],
    "12.68% per year", _ear)


def _annuity(p):
    fv = 200 * ((1.005 ** 48 - 1) / 0.005)
    money_is(p, round(fv, 2))
    has_steps(p, f"{1.005 ** 48:.5f}", f"{(1.005 ** 48 - 1) / 0.005:.4f}")


add(S, "You save $200 at the end of every month for 4 years in an account paying 6% per year compounded monthly. How much is in the account at the end?",
    ["Regular payments use the future value of an annuity: FV = PMT × ((1 + i)^N − 1) / i.",
     "PMT = 200, i = 0.06 / 12 = 0.005, N = 12 × 4 = 48.",
     "(1.005)^48 ≈ 1.27049, so ((1.005)^48 − 1) / 0.005 ≈ 0.27049 / 0.005 ≈ 54.0978.",
     "FV ≈ 200 × 54.0978 ≈ $10,819.57"],
    "≈ $10,819.57", _annuity)


def _loan(p):
    pmt = 18000 * 0.005 / (1 - 1.005 ** -60)
    assert round(pmt, 2) == 347.99
    total = round(347.99 * 60, 2)
    assert total == 20879.4 and round(total - 18000, 2) == 2879.4
    money_is(p, 347.99, 20879.40, 2879.40)
    has_steps(p, f"{1.005 ** -60:.5f}")


add(S, "A $18,000 car loan is at 6% per year compounded monthly over 5 years. Find the monthly payment, the total paid and the total interest.",
    ["Loan payment: PMT = PV × i / (1 − (1 + i)^(−N)).",
     "PV = 18000, i = 0.06 / 12 = 0.005, N = 12 × 5 = 60.",
     "(1.005)^(−60) ≈ 0.74137, so the bottom is 1 − 0.74137 = 0.25863.",
     "PMT = 18000 × 0.005 / 0.25863 = 90 / 0.25863 ≈ $347.99 per month.",
     "Total paid = 60 × 347.99 = $20,879.40, so the interest is 20879.40 − 18000 = $2,879.40."],
    "Payment $347.99; total paid $20,879.40; interest $2,879.40", _loan)

add(S, "Compare the total cost over 4 years of leasing or buying a car. Lease: $1800 up front plus $420 a month for 48 months. Buy: $2000 down plus $640 a month for 48 months, and the car is then worth $15,000. Which costs less?",
    ["Lease: you own nothing at the end. Total = 1800 + 48 × 420 = 1800 + 20160 = $21,960.",
     "Buy cash paid: 2000 + 48 × 640 = 2000 + 30720 = $32,720.",
     "But you still own a car worth $15,000, so the real cost of buying is 32720 − 15000 = $17,720.",
     "17,720 is less than 21,960, so buying costs $4,240 less over the 4 years."],
    "Buying: $17,720 versus leasing: $21,960",
    lambda p: (money_is(p, 17720, 21960), 2000 + 48 * 640 - 15000 == 17720, 1800 + 48 * 420 == 21960, 21960 - 17720 == 4240,
               has_steps(p, "$4,240")))


if __name__ == "__main__":
    main()
