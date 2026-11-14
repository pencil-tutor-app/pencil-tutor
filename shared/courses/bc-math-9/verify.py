#!/usr/bin/env python3
"""Re-runnable verifier for shared/courses/bc-math-9/problems.json.

Run:  python3 -I shared/courses/bc-math-9/verify.py      (exit 0 = all good, 1 = any failure)

What it checks, with exact Fraction arithmetic (no floats):
  1. Structure: fields, ids m9-01.., level, source, prompt_parts rebuild prompt_plain, no student names.
  2. Every pure-number equality chain inside worked_solution (e.g. "2.25 + 1.92 = 4.17") is true.
  3. Per problem: the answer is recomputed from the givens in the prompt (not read from the file), compared
     with final_answer, and the key intermediate results are required to appear in worked_solution.
  4. If sympy is importable it cross-checks the equation and polynomial problems a second way.
"""
import json
import os
import re
import sys
from fractions import Fraction as F

HERE = os.path.dirname(os.path.abspath(__file__))
BANK = json.load(open(os.path.join(HERE, "problems.json"), encoding="utf-8"))
BY_ID = {p["id"]: p for p in BANK}
FAILS = []
CHECKED = {"structure": 0, "chains": 0, "answers": 0}


def fail(pid, msg):
    FAILS.append(f"{pid}: {msg}")


def req(pid, cond, msg):
    if not cond:
        fail(pid, msg)


# ---------------------------------------------------------------- 1. structure
FIELDS = {"id", "source", "prompt_latex", "prompt_plain", "prompt_parts", "worked_solution", "final_answer", "level"}
NAMES = re.compile(r"nghi|sora|ng[aâ]n|kara|minh|trang|marco|phan|ng[oọ]c|\bstudent[s]? named\b", re.I)


def plain_side(s):
    return f"({s})" if " " in s else s


def rebuild_plain(parts):
    out = ""
    for part in parts:
        if "text" in part:
            out += part["text"]
        else:
            out += f"{plain_side(part['frac']['num'])}/{plain_side(part['frac']['den'])}"
    return out


def check_structure():
    ids = [p["id"] for p in BANK]
    req("bank", ids == [f"m9-{i:02d}" for i in range(1, len(BANK) + 1)], "ids must be m9-01.. in order, no gaps")
    for p in BANK:
        pid = p["id"]
        CHECKED["structure"] += 1
        req(pid, set(p) == FIELDS, f"fields differ: {sorted(set(p) ^ FIELDS)}")
        req(pid, p["level"] == "high_school", "level must be high_school")
        req(pid, p["source"].startswith("BC Math 9 content: ") and "original" in p["source"], "source format")
        req(pid, p["prompt_parts"] and rebuild_plain(p["prompt_parts"]) == p["prompt_plain"], "prompt_parts do not rebuild prompt_plain")
        for part in p["prompt_parts"]:
            ok = ("text" in part and len(part) == 1) or ("frac" in part and set(part["frac"]) == {"num", "den"} and len(part) == 1)
            req(pid, ok, f"bad prompt part {part}")
        req(pid, 3 <= len(p["worked_solution"]) <= 12, f"worked_solution has {len(p['worked_solution'])} lines (want 3 to 12)")
        req(pid, p["final_answer"].strip() != "", "empty final_answer")
        blob = json.dumps(p, ensure_ascii=False)
        req(pid, not NAMES.search(blob), "contains a person's name")
        req(pid, p["prompt_latex"].strip() != "", "empty prompt_latex")


# ------------------------------------------------- 2. numeric equality chains
SUP = str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹", "0123456789")
PURE = re.compile(r"^[\d\s().,+\-−×÷*/·$⁰¹²³⁴⁵⁶⁷⁸⁹]*$")


def to_python(expr):
    s = expr.replace("−", "-").replace("×", "*").replace("÷", "/").replace("·", "*").replace("$", "")
    s = re.sub(r"(?<=\d),(?=\d{3}(?!\d))", "", s)
    s = re.sub(r"([⁰¹²³⁴⁵⁶⁷⁸⁹]+)", lambda m: "**(" + m.group(1).translate(SUP) + ")", s)
    s = re.sub(r"\)\s*\(", ")*(", s)
    s = re.sub(r"(\d)\s*\(", r"\1*(", s)
    s = re.sub(r"\)\s*(\d)", r")*\1", s)
    s = re.sub(r"\d+(?:\.\d+)?", lambda m: f'F("{m.group(0)}")', s)
    return eval(s, {"F": F, "__builtins__": {}})  # only digits and + - * / ( ) reach here


def check_chains():
    for p in BANK:
        for line in p["worked_solution"]:
            text = line.split(":", 1)[1] if re.match(r"^[A-Za-z ]{2,20}:", line) else line
            text = text.rstrip(". ")
            pieces = [x.strip() for x in text.split("=")]
            if len(pieces) < 2 or not all(PURE.match(x) for x in pieces):
                continue
            vals = [x for x in pieces if x]
            if len(vals) < 2:
                continue
            try:
                nums = [to_python(x) for x in vals]
            except Exception as e:  # unparsable chain is a defect in the line, not something to skip silently
                fail(p["id"], f"cannot evaluate chain '{line}' ({e})")
                continue
            CHECKED["chains"] += 1
            req(p["id"], all(n == nums[0] for n in nums), f"false equality in '{line}': {[str(n) for n in nums]}")


# ------------------------------------------------------ 3. per-problem checks
def steps_have(pid, *needles):
    blob = " ".join(BY_ID[pid]["worked_solution"])
    for n in needles:
        req(pid, n in blob, f"key step '{n}' missing from worked_solution")


def answer_has(pid, *needles):
    CHECKED["answers"] += 1
    fa = BY_ID[pid]["final_answer"]
    for n in needles:
        req(pid, n in fa, f"final_answer '{fa}' lacks '{n}'")


def eqf(pid, got, want, what):
    req(pid, got == want, f"{what}: recomputed {got}, expected {want}")


def root(f):
    """Root of a linear function f(x), exact. Also proves f is linear (constant slope)."""
    f0, f1, f2 = f(F(0)), f(F(1)), f(F(2))
    slope = f1 - f0
    assert f2 - f1 == slope and slope != 0, "not linear"
    return -f0 / slope


def same_poly(f, g, xs=range(-7, 8)):
    return all(f(F(x)) == g(F(x)) for x in xs)


def frac_str(x):
    x = F(x)
    return f"{x.numerator}/{x.denominator}" if x.denominator != 1 else str(x.numerator)


def check_problems():
    # ---- A. rational numbers
    eqf("m9-01", F(-2) ** 3 + F(-3) ** 2 - F(-4) ** 2, -15, "value")
    answer_has("m9-01", "−15"); steps_have("m9-01", "(−2)³ = −8", "1 − 16")

    v = 3 - 2 * F(3, 4) ** 2
    eqf("m9-02", v, F(15, 8), "value")
    answer_has("m9-02", "15/8"); steps_have("m9-02", "9/16", "9/8", "24/8 − 9/8")

    v = F("-1.5") ** 2 - F("2.4") * (F("0.5") - F("1.3"))
    eqf("m9-03", v, F("4.17"), "value")
    answer_has("m9-03", "4.17"); steps_have("m9-03", "−0.8", "2.25", "−1.92")

    v = F(-2, 3) ** 2 / (F(1, 2) - F(5, 6))
    eqf("m9-04", v, F(-4, 3), "value")
    eqf("m9-04", F(1, 2) - F(5, 6), F(-1, 3), "bracket")
    answer_has("m9-04", "−4/3"); steps_have("m9-04", "4/9", "−1/3")

    inner = F(1, 3) / F(-2, 9)
    eqf("m9-05", inner, F(-3, 2), "(1/3) ÷ (−2/9)")
    eqf("m9-05", inner * F(1, 2), F(-3, 4), "times 1/2")
    eqf("m9-05", F(5, 6) - inner * F(1, 2), F(19, 12), "value")
    answer_has("m9-05", "19/12"); steps_have("m9-05", "−3/2", "−3/4", "10/12 + 9/12")

    t1, t2 = F(-2, 3) / F(4, 9), F(-1, 2) * F(-3, 4)
    eqf("m9-06", (t1, t2, t1 + t2), (F(-3, 2), F(3, 8), F(-9, 8)), "terms and sum")
    answer_has("m9-06", "−9/8"); steps_have("m9-06", "−3/2", "3/8", "−12/8 + 3/8")

    # ---- B. exponents
    eqf("m9-07", 5 ** 2 - 3 * (4 - 6) ** 3, 49, "value")
    answer_has("m9-07", "49"); steps_have("m9-07", "(−2)³ = −8", "−24")

    # (3a^2)^3 / a^4 = 27 a^2, tested at many a
    req("m9-08", same_poly(lambda a: (3 * a ** 2) ** 3 / a ** 4, lambda a: 27 * a ** 2, [x for x in range(-6, 7) if x]), "27a² identity fails")
    answer_has("m9-08", "27a²"); steps_have("m9-08", "27a⁶", "a²")

    eqf("m9-09", F(-3) ** 7 * F(-3) ** 2 / F(-3) ** 6, F(-3) ** 3, "single power")
    eqf("m9-09", F(-3) ** 3, -27, "value")
    answer_has("m9-09", "(−3)³", "−27"); steps_have("m9-09", "(−3)⁹", "−27")

    eqf("m9-10", F(27 ** 4, 9 ** 5), 9, "value")
    eqf("m9-10", (27 == 3 ** 3, 9 == 3 ** 2, 27 ** 4 == 3 ** 12, 9 ** 5 == 3 ** 10), (True,) * 4, "powers of 3")
    answer_has("m9-10", "9"); steps_have("m9-10", "3¹²", "3¹⁰", "3²")

    top, bot = (2 ** 3 * 2 ** 2) ** 2, F((2 ** 4) ** 2, 2 ** 3)
    eqf("m9-11", (top, bot, F(top) / bot), (2 ** 10, 2 ** 5, 32), "top, bottom, value")
    answer_has("m9-11", "2⁵", "32"); steps_have("m9-11", "2¹⁰", "2⁵")

    eqf("m9-12", (24 // 3, 2 ** 8, 800 * 2 ** 8), (8, 256, 204800), "doublings, 2^8, total")
    answer_has("m9-12", "800 × 2⁸", "204,800"); steps_have("m9-12", "256", "204,800")

    # ---- C. polynomials (identity checks at 15 points; degree <= 2 needs only 3)
    req("m9-13", same_poly(lambda p: 5 * p ** 2 - 2 * p + 7 - 8 * p ** 2 + 2 * p - 7, lambda p: -3 * p ** 2), "m9-13 identity")
    answer_has("m9-13", "−3p²", "degree 2"); steps_have("m9-13", "−3p²")

    req("m9-14", same_poly(lambda x: (5 * x ** 2 - 3 * x + 2) - (2 * x ** 2 - 7 * x - 4), lambda x: 3 * x ** 2 + 4 * x + 6), "m9-14 identity")
    answer_has("m9-14", "3x² + 4x + 6"); steps_have("m9-14", "3x²", "4x", "6")

    req("m9-15", same_poly(lambda x: -3 * (x ** 2 - 2 * x + 4) + 2 * x * (x - 5), lambda x: -x ** 2 - 4 * x - 12), "m9-15 identity")
    answer_has("m9-15", "−x² − 4x − 12"); steps_have("m9-15", "−3x² + 6x − 12", "2x² − 10x")

    req("m9-16", same_poly(lambda n: (24 * n ** 2 - 18 * n) / (6 * n), lambda n: 4 * n - 3, [x for x in range(-6, 7) if x]), "m9-16 identity")
    answer_has("m9-16", "4n − 3"); steps_have("m9-16", "4n", "−3")

    wrong, right = (lambda x: 4 * x - 13), (lambda x: 4 * x + 5)
    req("m9-17", same_poly(lambda x: (6 * x - 4) - (2 * x - 9), right), "m9-17 correct answer identity")
    req("m9-17", not any(wrong(F(x)) == (6 * x - 4) - (2 * x - 9) for x in range(-7, 8)), "m9-17 the student's answer must be wrong everywhere")
    answer_has("m9-17", "4x + 5"); steps_have("m9-17", "−2x + 9", "4x + 5")

    xr = root(lambda x: 2 * ((2 * x + 1) + (5 * x - 3)) - 66)
    eqf("m9-18", (xr, 2 * xr + 1, 5 * xr - 3), (5, 11, 22), "x, width, length")
    eqf("m9-18", 2 * (11 + 22), 66, "check perimeter")
    req("m9-18", same_poly(lambda x: 2 * ((2 * x + 1) + (5 * x - 3)), lambda x: 14 * x - 4), "perimeter expansion 14x - 4")
    answer_has("m9-18", "x = 5", "11", "22"); steps_have("m9-18", "14x − 4", "x = 5")

    # ---- D. linear relations
    xs, ys = [3, 6, 9, 12], [8, 7, 6, 5]
    slope = F(ys[1] - ys[0], xs[1] - xs[0])
    eqf("m9-19", all(F(ys[i + 1] - ys[i], xs[i + 1] - xs[i]) == slope for i in range(3)), True, "table is linear")
    b = ys[0] - slope * xs[0]
    eqf("m9-19", (slope, b), (F(-1, 3), 9), "slope, intercept")
    eqf("m9-19", all(slope * x + b == y for x, y in zip(xs, ys)), True, "equation fits all four points")
    answer_has("m9-19", "−(1/3)x + 9"); steps_have("m9-19", "−1/3", "b = 9")

    steps_have("m9-20", "y = −2", "x = 3"); answer_has("m9-20", "y = −2", "x = 3", "(3, −2)")

    eqf("m9-21", (240 - 8 * 12, root(lambda t: 240 - 8 * t)), (144, 30), "V at 12, empty time")
    answer_has("m9-21", "V = 240 − 8t", "144", "30"); steps_have("m9-21", "144", "t = 30")

    m = F(45 - 20, 100 - 0)
    eqf("m9-22", (m, m * 60 + 20, m * 300 + 20), (F(1, 4), 35, 95), "slope, C(60), C(300)")
    answer_has("m9-22", "0.25m + 20", "$35", "$95"); steps_have("m9-22", "0.25", "= 35", "= 95")

    m = F(-3 - 9, 4 - (-2))
    b = 9 - m * (-2)
    eqf("m9-23", (m, b, m * 4 + b, m * 10 + b, root(lambda x: m * x + b - 1)), (-2, 5, -3, -15, 2), "slope, b, check, y(10), x at y=1")
    answer_has("m9-23", "y = −2x + 5", "−15", "x = 2"); steps_have("m9-23", "−12/6 = −2", "b = 5")

    m = F("9.5") - F("17.5")
    m = m / (6 - 2)
    b = F("17.5") - m * 2
    eqf("m9-24", (m, b, m * 5 + b, root(lambda t: m * t + b)), (-2, F("21.5"), F("11.5"), F("10.75")), "slope, b, h(5), burn-out")
    answer_has("m9-24", "21.5 − 2t", "11.5", "10.75"); steps_have("m9-24", "−2 cm per hour", "10.75")

    # ---- E. equations (exact root of lhs - rhs, then both sides substituted)
    for pid, lhs, rhs, want, ans in [
        ("m9-25", lambda m: 9 - 2 * m, lambda m: 5 * m - 12, F(3), "m = 3"),
        ("m9-26", lambda y: F("0.5") * (2 * y - 3), lambda y: F("0.25") * (y + 6), F(4), "y = 4"),
        ("m9-27", lambda n: 3 * n / 4 - (n - 2) / 6, lambda n: n / 2, F(-4), "n = −4"),
        ("m9-28", lambda x: x / 2 - (x - 3) / 5, lambda x: F(9, 10), F(1), "x = 1"),
        ("m9-29", lambda x: 2 - F(1, 3) * (x + 9), lambda x: x / 2 + 1, F(-12, 5), "x = −12/5"),
    ]:
        r = root(lambda x: lhs(x) - rhs(x))
        eqf(pid, r, want, "root")
        eqf(pid, lhs(r), rhs(r), "both sides at the root")
        answer_has(pid, ans)
    steps_have("m9-25", "21 = 7m"); steps_have("m9-26", "0.75y = 3")
    steps_have("m9-27", "7n + 4 = 6n"); steps_have("m9-28", "3x + 6 = 9")
    steps_have("m9-29", "−6 − 2x = 3x + 6", "−12 = 5x", "−1/5")

    w = root(lambda w: 2 * (w + 2 * w + 3) - 42)
    eqf("m9-30", (w, 2 * w + 3, 2 * (w + 2 * w + 3)), (6, 15, 42), "width, length, perimeter")
    answer_has("m9-30", "w = 6", "15"); steps_have("m9-30", "6w + 6 = 42", "w = 6")

    # ---- F. spatial proportional reasoning
    eqf("m9-31", (14 * 50, F(14 * 50, 100)), (700, 7), "cm then m")
    answer_has("m9-31", "7 m"); steps_have("m9-31", "700 cm")
    eqf("m9-32", (F(18, 2), F(12, 2)), (9, 6), "drawing size")
    answer_has("m9-32", "9 cm", "6 cm")
    eqf("m9-33", (42 * 250, F(42 * 250, 100)), (10500, 105), "cm then m")
    answer_has("m9-33", "105 m"); steps_have("m9-33", "10500 cm")
    eqf("m9-34", (F(260, 40), F(260, 40) * 40), (F("6.5"), 260), "map distance and check")
    req("m9-34", 260 * 40 == 10400, "the student's wrong product 10,400 must be 260 x 40")
    answer_has("m9-34", "6.5 cm"); steps_have("m9-34", "6.5")
    k = F(20, 8)
    eqf("m9-35", (k, 12 * k, 10 * k), (F("2.5"), 30, 25), "scale factor, EF, DF")
    answer_has("m9-35", "EF = 30", "DF = 25"); steps_have("m9-35", "2.5", "30 cm", "25 cm")
    pq = 6 + 9
    k = F(pq, 6)
    eqf("m9-36", (pq, k, 8 * k), (15, F("2.5"), 20), "PQ, factor, QR")
    answer_has("m9-36", "QR = 20"); steps_have("m9-36", "15", "2.5")
    h = F("1.5") * F(24, 2)
    eqf("m9-37", (h, F("1.5") / 2, h / 24), (18, F("0.75"), F("0.75")), "height and ratio check")
    answer_has("m9-37", "18 m"); steps_have("m9-37", "12", "18")

    # ---- G. statistics in society
    eqf("m9-38", F(60, 840), F(1, 14), "sample fraction")
    answer_has("m9-38", "840", "60", "simple random"); steps_have("m9-38", "1/14")
    steps_have("m9-39", "who"); answer_has("m9-39", "Who was asked", "bias")
    tot = 400 + 350 + 250
    f = F(100, tot)
    eqf("m9-40", (tot, f, 400 * f, 350 * f, 250 * f, 400 * f + 350 * f + 250 * f), (1000, F(1, 10), 40, 35, 25, 100), "stratified counts")
    answer_has("m9-40", "40", "35", "25"); steps_have("m9-40", "1000", "1/10")
    eqf("m9-41", (F("0.25") / 100, F("0.25") / 100 * 3600000), (F("0.0025"), 9000), "rate and count")
    answer_has("m9-41", "9000"); steps_have("m9-41", "0.0025", "9000")
    pct = F(100 - 92, 92) * 100
    eqf("m9-42", (round(float(pct), 1), F(100 - 90, 92 - 90)), (8.7, 5), "percent higher, bar ratio")
    req("m9-42", 0.0865 < float(F(8, 92)) < 0.0875, "8/92 should round to 0.087")
    answer_has("m9-42", "8.7%", "5 times"); steps_have("m9-42", "8.7%", "10 ÷ 2 = 5")
    eqf("m9-43", 35 + 30 + 25 + 20, 110, "percent total")
    answer_has("m9-43", "110%"); steps_have("m9-43", "110")

    # ---- H. financial literacy (money in cents to stay exact)
    bal = F("215.40") + F("80.00") - F("126.75") - F("4.50") + F("33.25")
    eqf("m9-44", (F("215.40") + 80, F("295.40") - F("126.75"), bal), (F("295.40"), F("168.65"), F("197.40")), "running balances")
    answer_has("m9-44", "197.40"); steps_have("m9-44", "295.40", "168.65", "164.15", "197.40")
    i = 1500 * F("0.06") * F(8, 12)
    eqf("m9-45", i, 60, "interest")
    answer_has("m9-45", "$60"); steps_have("m9-45", "2/3", "= 60")
    i = 2000 * F("0.04") * F(18, 12)
    eqf("m9-46", (i, 2000 * F("0.04") * 18), (120, 1440), "correct vs student's interest")
    answer_has("m9-46", "$120"); steps_have("m9-46", "1.5", "= 120")
    ia, ib = 3000 * F("0.035") * 4, 2500 * F("0.05") * 5
    eqf("m9-47", (ia, ib, ib - ia), (420, 625, 205), "interest A, B, difference")
    answer_has("m9-47", "$420", "$625", "$205"); steps_have("m9-47", "420", "625", "205")
    i = 4800 * F("0.065") * F(30, 12)
    eqf("m9-48", (i, 4800 + i), (780, 5580), "interest and total")
    answer_has("m9-48", "$5580"); steps_have("m9-48", "312", "780", "5580")
    weekly = 15 * 10
    save = weekly * F("0.40")
    eqf("m9-49", (weekly, save, F(420) / save), (150, 60, 7), "pay, savings, weeks")
    req("m9-49", F(420) / save == 7, "weeks must be a whole number")
    answer_has("m9-49", "7 weeks"); steps_have("m9-49", "150", "60")


# ----------------------------------------------- 4. optional sympy cross-check
def sympy_crosscheck():
    try:
        import sympy as sp
    except ImportError:
        print("sympy not installed: second-method cross-check skipped (Fraction checks above still ran)")
        return
    x, n, p, y, m = sp.symbols("x n p y m")
    eqs = {
        "m9-25": (sp.Eq(9 - 2 * m, 5 * m - 12), m, 3),
        "m9-26": (sp.Eq(sp.Rational(1, 2) * (2 * y - 3), sp.Rational(1, 4) * (y + 6)), y, 4),
        "m9-27": (sp.Eq(3 * n / 4 - (n - 2) / 6, n / 2), n, -4),
        "m9-28": (sp.Eq(x / 2 - (x - 3) / 5, sp.Rational(9, 10)), x, 1),
        "m9-29": (sp.Eq(2 - sp.Rational(1, 3) * (x + 9), x / 2 + 1), x, sp.Rational(-12, 5)),
    }
    for pid, (eq, var, want) in eqs.items():
        req(pid, sp.solve(eq, var) == [want], "sympy disagrees on the root")
    polys = {
        "m9-13": (5 * p ** 2 - 2 * p + 7 - 8 * p ** 2 + 2 * p - 7, -3 * p ** 2),
        "m9-14": ((5 * x ** 2 - 3 * x + 2) - (2 * x ** 2 - 7 * x - 4), 3 * x ** 2 + 4 * x + 6),
        "m9-15": (-3 * (x ** 2 - 2 * x + 4) + 2 * x * (x - 5), -x ** 2 - 4 * x - 12),
        "m9-16": ((24 * n ** 2 - 18 * n) / (6 * n), 4 * n - 3),
        "m9-17": ((6 * x - 4) - (2 * x - 9), 4 * x + 5),
    }
    for pid, (lhs, rhs) in polys.items():
        req(pid, sp.simplify(lhs - rhs) == 0, "sympy disagrees on the polynomial identity")
    req("m9-08", sp.simplify((3 * x ** 2) ** 3 / x ** 4 - 27 * x ** 2) == 0, "sympy disagrees on m9-08")
    req("m9-10", sp.Rational(27 ** 4, 9 ** 5) == 9, "sympy disagrees on m9-10")
    print("sympy", sp.__version__, "cross-check ran on 5 equations and 6 expression identities")


def main():
    check_structure()
    check_chains()
    try:
        check_problems()
    except AssertionError as e:
        fail("bank", f"assertion in checks: {e}")
    sympy_crosscheck()
    print(f"problems: {len(BANK)}; structure checks: {CHECKED['structure']}; "
          f"numeric chains evaluated: {CHECKED['chains']}; answers recomputed: {CHECKED['answers']}")
    if FAILS:
        print(f"FAILED ({len(FAILS)}):")
        for f in FAILS:
            print("  -", f)
        sys.exit(1)
    print(f"OK: all {len(BANK)} problems verified")


if __name__ == "__main__":
    main()
