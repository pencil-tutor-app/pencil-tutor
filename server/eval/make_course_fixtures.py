#!/usr/bin/env python3
"""Build the course eval pages: synthetic "handwritten" pages for the 14 new courses (grades 5-12 and college).

For each course, 3 problems spread across topics and difficulty. Each problem gets 2 pages:
  correct  the worked solution as a student would write it, solved to the end          -> the tutor should wait
  wrong    the same work with ONE planted, realistic mistake in a known line, and every
           later line carried forward consistently from the mistake                    -> interrupt on exactly that line

42 problems -> 84 pages (the 15th manifest entry, bc-math-9-unit-3, is the old set and is skipped).

Not real handwriting. Same approach as make_fixtures.py (the 30-page BC Math 9 set): handwriting-style glyphs with per-glyph
size, baseline, rotation and spacing jitter, a per-page slant, faint grey line numbers in the left margin as PageSnapshotter
draws them, `lines` boxes computed from the ink in image pixels. Differences:
  * Fonts are Google Fonts under the SIL Open Font License (Patrick Hand, Kalam, Caveat, Indie Flower), downloaded on first run
    into server/eval/fonts/ (git-ignored). Noto Sans Math (also OFL) fills glyphs a handwriting font lacks (theta, arrows, set
    and logic symbols); those few glyphs look typeset, not handwritten.
  * The layout understands the maths students write: stacked fractions, superscripts and subscripts, square and cube roots with
    an overbar, and matrices with brackets. Row spacing follows the row height. Pages are 1024 px wide and as tall as the work
    needs (never over 1024 px, the app's longest side).

Markup in a row (everything else is a plain character; "-" is drawn as a minus dash):
  {top/bottom}   stacked fraction (the LAST top-level slash splits it)      {x+1/2}
  ^2  ^{12}      superscript            _0  _{n+1}   subscript
  \\r{...}        square root           \\c{...}      cube root
  \\m{a|b;c|d}    matrix (cells split by |, rows by ;)

Limits, stated plainly: a font cannot reproduce a real child's slips, crossings-out, uneven fractions or a matrix drawn with
tall hand-drawn brackets; the brackets and radical signs here are neat polylines with small jitter. Real handwriting will be
harder to read than this, so the catch rates measured on these pages are an upper bound on legibility.

Needs Pillow. Deterministic (fixed seeds).  Run: python3 server/eval/make_course_fixtures.py
Writes server/eval/fixtures/courses/*.png and server/eval/fixtures/courses/manifest.json
"""
import io
import json
import math
import os
import random
import sys
import urllib.request

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
# --messy writes a second, harder set to fixtures/courses-messy: bigger glyph and baseline jitter, rows that drift, grey pencil,
# paper noise, extra blur and a 0.78 downscale, so the same 84 pages test how the tutor copes when the writing is worse than a font.
MESSY = "--messy" in sys.argv
OUT = os.path.join(HERE, "fixtures", "courses-messy" if MESSY else "courses")
FONT_DIR = os.path.join(HERE, "fonts")
W = 1024
MAX_H = 1024
GF = "https://raw.githubusercontent.com/google/fonts/main/ofl/"
FONT_FILES = {
    "patrick": ("patrickhand/PatrickHand-Regular.ttf", 44),
    "kalam": ("kalam/Kalam-Regular.ttf", 38),
    "caveat": ("caveat/Caveat%5Bwght%5D.ttf", 54),
    "indie": ("indieflower/IndieFlower-Regular.ttf", 40),
}
FALLBACK_FILE = "notosansmath/NotoSansMath-Regular.ttf"
NUM_FONT = "/System/Library/Fonts/Helvetica.ttc"  # only for the faint margin numbers, as PageSnapshotter's system font
INKS = [(20, 24, 40), (30, 30, 36), (22, 34, 76), (44, 40, 52)]


# ---------------------------------------------------------------- the pages
# Each problem: course, problem id, correct rows, then the mistake variant (rows, wrong_line, error_type, what was planted).
# Line 1 is the student copying or setting up the problem. wrong_line counts from 1 like the margin numbers.
P = []


def prob(course, pid, correct, wrong, wrong_line, error_type, planted):
    P.append(dict(course=course, problem_id=pid, correct=correct, wrong=wrong, wrong_line=wrong_line, error_type=error_type, planted=planted))


# ---- BC Math 5
prob("bc-math-5", "m5-26",
     ["36 × 24", "24 = 20 + 4", "36 × 20 = 720", "36 × 4 = 144", "720 + 144 = 864"],
     ["36 × 24", "24 = 20 + 4", "36 × 20 = 720", "36 × 4 = 124", "720 + 124 = 844"], 4,
     "arithmetic slip", "36 x 4 written as 124 (should be 144)")
prob("bc-math-5", "m5-33",
     ["1.25 + 0.875", "1.250 + 0.875", "thousandths 0+5 = 5, hundredths 5+7 = 12 write 2 carry 1",
      "tenths 2+8+1 = 11 write 1 carry 1, ones 1+0+1 = 2", "2.125 L"],
     ["1.25 + 0.875", "1.250 + 0.875", "thousandths 0+5 = 5, hundredths 5+7 = 12 write 2 carry 1",
      "tenths 2+8 = 10 write 0 carry 1, ones 1+0+1 = 2", "2.025 L"], 4,
     "dropped carry", "carry from the hundredths forgotten in the tenths column")
prob("bc-math-5", "m5-58",
     ["P = 36, width = 7", "2 widths: 7 + 7 = 14", "36 – 14 = 22", "22 ÷ 2 = 11", "length = 11 cm"],
     ["P = 36, width = 7", "2 widths: 7 + 7 = 14", "36 + 14 = 50", "50 ÷ 2 = 25", "length = 25 cm"], 3,
     "wrong operation", "added the widths to the perimeter instead of subtracting")

# ---- BC Math 6
prob("bc-math-6", "m6-12",
     ["20 – 6 × (9 – 4) ÷ 4", "20 – 6 × 5 ÷ 4", "20 – 30 ÷ 4", "20 – 7.5", "12.5"],
     ["20 – 6 × (9 – 4) ÷ 4", "20 – 6 × 5 ÷ 4", "14 × 5 ÷ 4", "70 ÷ 4", "17.5"], 3,
     "order of operations", "subtracted 20 - 6 before multiplying")
prob("bc-math-6", "m6-27",
     ["cats : dogs = 5 : 3, total 40", "5 + 3 = 8 parts", "40 ÷ 8 = 5 in each part", "dogs = 3 × 5 = 15", "15 dogs"],
     ["cats : dogs = 5 : 3, total 40", "5 + 3 = 8 parts", "40 ÷ 8 = 6 in each part", "dogs = 3 × 6 = 18", "18 dogs"], 3,
     "arithmetic slip", "40 / 8 written as 6 (should be 5)")
prob("bc-math-6", "m6-55",
     ["A = (a + b) × h ÷ 2", "(6 + 10) × 5 ÷ 2", "16 × 5 = 80", "80 ÷ 2 = 40", "40 cm^2"],
     ["A = (a + b) × h ÷ 2", "(6 × 10) × 5 ÷ 2", "60 × 5 = 300", "300 ÷ 2 = 150", "150 cm^2"], 2,
     "misapplied formula", "multiplied the parallel sides instead of adding them")

# ---- BC Math 7
prob("bc-math-7", "m7-08",
     ["3 + (-4) × (2 – 6)", "3 + (-4) × (-4)", "3 + 16", "19"],
     ["3 + (-4) × (2 – 6)", "3 + (-4) × (-4)", "3 + (-16)", "-13"], 3,
     "sign error", "negative times negative written as negative")
prob("bc-math-7", "m7-28",
     ["3k + 4 = 25", "3k = 25 – 4", "3k = 21", "k = 7", "check: 3(7) + 4 = 25", "7 km"],
     ["3k + 4 = 25", "3k = 25 + 4", "3k = 29", "k = {29/3}", "k ≈ 9.7 km"], 2,
     "wrong inverse operation", "added 4 to the right side instead of subtracting")
prob("bc-math-7", "m7-63",
     ["100% – 20% = 80%", "0.8 × P = 36", "P = 36 ÷ 0.8", "P = 45", "$45"],
     ["100% – 20% = 80%", "0.8 × P = 36", "P = 36 × 0.8", "P = 28.8", "$28.80"], 3,
     "wrong operation", "multiplied by 0.8 instead of dividing")

# ---- BC Math 8
prob("bc-math-8", "m8-16",
     ["3 + 5 + 7 = 15 parts", "105 ÷ 15 = 7 cm", "3 × 7 = 21", "5 × 7 = 35", "7 × 7 = 49", "21 cm, 35 cm, 49 cm"],
     ["3 + 5 + 7 = 15 parts", "105 ÷ 15 = 7 cm", "3 × 7 = 21", "5 × 7 = 30", "7 × 7 = 49", "21 cm, 30 cm, 49 cm"], 4,
     "arithmetic slip", "5 x 7 written as 30 (should be 35)")
prob("bc-math-8", "m8-34",
     ["2(a + 3b) – c, a = 4, b = -2, c = 5", "2(4 + 3(-2)) – 5", "2(4 – 6) – 5", "2(-2) – 5", "-4 – 5", "= -9"],
     ["2(a + 3b) – c, a = 4, b = -2, c = 5", "2(4 + 3(-2)) – 5", "2(4 + 6) – 5", "2(10) – 5", "20 – 5", "= 15"], 3,
     "sign error", "3 times (-2) written as +6")
prob("bc-math-8", "m8-49",
     ["a^2 + b^2 = c^2", "a^2 + 5^2 = 13^2", "a^2 + 25 = 169", "a^2 = 144", "a = 12 cm"],
     ["a^2 + b^2 = c^2", "a^2 + 5^2 = 13^2", "a^2 + 10 = 169", "a^2 = 159", "a ≈ 12.6 cm"], 3,
     "arithmetic slip", "5 squared written as 10 (doubled instead of squared)")

# ---- BC Math 9
prob("bc-math-9", "m9-08",
     ["{(3a^2)^3/a^4}", "{3^3 · a^6/a^4}", "{27a^6/a^4}", "27a^2"],
     ["{(3a^2)^3/a^4}", "{3 · a^6/a^4}", "{3a^6/a^4}", "3a^2"], 2,
     "misapplied power rule", "cubed only the variable part, left the coefficient 3 uncubed")
prob("bc-math-9", "m9-14",
     ["(5x^2 – 3x + 2) – (2x^2 – 7x – 4)", "5x^2 – 3x + 2 – 2x^2 + 7x + 4", "(5x^2 – 2x^2) + (-3x + 7x) + (2 + 4)", "3x^2 + 4x + 6"],
     ["(5x^2 – 3x + 2) – (2x^2 – 7x – 4)", "5x^2 – 3x + 2 – 2x^2 + 7x – 4", "(5x^2 – 2x^2) + (-3x + 7x) + (2 – 4)", "3x^2 + 4x – 2"], 2,
     "dropped sign when removing brackets", "the minus changed the first two terms but not the last")
prob("bc-math-9", "m9-26",
     ["0.5(2y – 3) = 0.25(y + 6)", "y – 1.5 = 0.25y + 1.5", "0.75y – 1.5 = 1.5", "0.75y = 3", "y = 4"],
     ["0.5(2y – 3) = 0.25(y + 6)", "y – 3 = 0.25y + 1.5", "0.75y – 3 = 1.5", "0.75y = 4.5", "y = 6"], 2,
     "distribution (second term forgotten)", "0.5 multiplied the 2y but not the 3")

# ---- BC Foundations of Math and Pre-calculus 10
prob("bc-fmpc-10", "f10-03",
     ["{12m^5n^{-2} / 4m^2n^{-5}}", "12 ÷ 4 = 3", "m^{5–2} = m^3", "n^{-2–(-5)} = n^3", "3m^3n^3"],
     ["{12m^5n^{-2} / 4m^2n^{-5}}", "12 ÷ 4 = 3", "m^{5–2} = m^3", "n^{-2–5} = n^{-7}", "3m^3n^{-7} = {3m^3/n^7}"], 4,
     "sign error with negative exponents", "subtracted 5 instead of subtracting -5")
prob("bc-fmpc-10", "f10-21",
     ["y = 2x – 5, point (3, 4)", "parallel so m = 2", "y – 4 = 2(x – 3)", "y – 4 = 2x – 6", "y = 2x – 2"],
     ["y = 2x – 5, point (3, 4)", "parallel so m = -{1/2}", "y – 4 = -{1/2}(x – 3)", "y – 4 = -{1/2}x + {3/2}", "y = -{1/2}x + {11/2}"], 2,
     "misapplied rule", "used the perpendicular slope for a parallel line")
prob("bc-fmpc-10", "f10-31",
     ["2x + 3y = 11", "5x – 3y = 17", "add: 7x = 28", "x = 4", "2(4) + 3y = 11", "3y = 11 – 8", "3y = 3", "y = 1"],
     ["2x + 3y = 11", "5x – 3y = 17", "add: 7x = 28", "x = 4", "2(4) + 3y = 11", "3y = 11 + 8", "3y = 19", "y = {19/3}"], 6,
     "moved term with wrong sign", "added 8 to the right side instead of subtracting")

# ---- BC Foundations of Math 11
prob("bc-fm-11", "fm11-11",
     ["angles add to 180°", "x + (2x + 10) + (3x – 10) = 180", "6x = 180", "x = 30", "2(30) + 10 = 70, 3(30) – 10 = 80", "30°, 70°, 80°"],
     ["angles add to 180°", "x + (2x + 10) + (3x – 10) = 180", "5x = 180", "x = 36", "2(36) + 10 = 82, 3(36) – 10 = 98", "36°, 82°, 98°"], 3,
     "combining like terms", "1 + 2 + 3 written as 5 for the x coefficient")
prob("bc-fm-11", "fm11-27",
     ["x^2 – 4x + 3 = x – 1", "x^2 – 5x + 4 = 0", "(x – 1)(x – 4) = 0", "x = 1 or x = 4", "y = x – 1: y = 0, y = 3", "(1, 0) and (4, 3)"],
     ["x^2 – 4x + 3 = x – 1", "x^2 – 5x + 4 = 0", "(x + 1)(x + 4) = 0", "x = -1 or x = -4", "y = x – 1: y = -2, y = -5", "(-1, -2) and (-4, -5)"], 3,
     "factoring sign error", "factored with plus signs where both brackets need minus")
prob("bc-fm-11", "fm11-39",
     ["mean = {2+4+4+4+5+5+7+9/8} = {40/8} = 5", "squared deviations: 9, 1, 1, 1, 0, 0, 4, 16", "sum = 32", "variance = {32/8} = 4", "σ = \\r{4} = 2"],
     ["mean = {2+4+4+4+5+5+7+9/8} = {40/8} = 5", "squared deviations: 9, 1, 1, 1, 0, 0, 4, 4", "sum = 20", "variance = {20/8} = 2.5", "σ = \\r{2.5} ≈ 1.58"], 2,
     "skipped a squaring step", "9 - 5 = 4 written without squaring (4 instead of 16)")

# ---- BC Pre-calculus 11
prob("bc-pc-11", "pc11-26",
     ["\\r{2x – 1} = x – 2", "2x – 1 = (x – 2)^2", "2x – 1 = x^2 – 4x + 4", "0 = x^2 – 6x + 5", "0 = (x – 1)(x – 5), x = 1, 5",
      "x = 1: \\r{1} = 1 but x – 2 = -1, reject", "x = 5 works"],
     ["\\r{2x – 1} = x – 2", "2x – 1 = (x – 2)^2", "2x – 1 = x^2 – 4", "0 = x^2 – 2x – 3", "0 = (x – 3)(x + 1), x = 3, -1", "x = 3 or x = -1"], 3,
     "squaring a binomial", "(x - 2)^2 expanded as x^2 - 4 (middle term lost)")
prob("bc-pc-11", "pc11-67",
     ["2x^2 – 12x + 7 = 0", "x^2 – 6x + {7/2} = 0", "x^2 – 6x = -{7/2}", "x^2 – 6x + 9 = 9 – {7/2}", "(x – 3)^2 = {11/2}", "x – 3 = ±\\r{{11/2}}", "x = 3 ± {\\r{22}/2}"],
     ["2x^2 – 12x + 7 = 0", "x^2 – 6x + 7 = 0", "x^2 – 6x = -7", "x^2 – 6x + 9 = 9 – 7", "(x – 3)^2 = 2", "x – 3 = ±\\r{2}", "x = 3 ± \\r{2}"], 2,
     "dropped term", "divided 2x^2 and 12x by 2 but left the 7 undivided")
prob("bc-pc-11", "pc11-94",
     ["sin 240° = -{\\r{3}/2}", "cos 300° = {1/2}", "tan 135° = -1", "-{\\r{3}/2} + {1/2} – (-1)", "-{\\r{3}/2} + {1/2} + 1", "{3 – \\r{3}/2}"],
     ["sin 240° = -{\\r{3}/2}", "cos 300° = {1/2}", "tan 135° = 1", "-{\\r{3}/2} + {1/2} – 1", "-{\\r{3}/2} – {1/2}", "{-\\r{3} – 1/2}"], 3,
     "wrong quadrant sign", "tan 135 degrees written as positive (it is negative in quadrant II)")

# ---- BC Calculus 12
prob("bc-calc-12", "ca12-22",
     ["f'(x) = lim_{h→0} {f(x+h) – f(x)/h}", "f(x+h) = x^2 + 2xh + h^2 – 3x – 3h", "f(x+h) – f(x) = 2xh + h^2 – 3h", "{2xh + h^2 – 3h/h} = 2x + h – 3", "h → 0: f'(x) = 2x – 3"],
     ["f'(x) = lim_{h→0} {f(x+h) – f(x)/h}", "f(x+h) = x^2 + 2xh + h^2 – 3x + 3h", "f(x+h) – f(x) = 2xh + h^2 + 3h", "{2xh + h^2 + 3h/h} = 2x + h + 3", "h → 0: f'(x) = 2x + 3"], 2,
     "sign error", "-3(x + h) expanded as -3x + 3h")
prob("bc-calc-12", "ca12-28",
     ["y = {x + 1/x – 2}", "u = x + 1, v = x – 2, u' = 1, v' = 1", "y' = {(1)(x – 2) – (x + 1)(1)/(x – 2)^2}", "= {x – 2 – x – 1/(x – 2)^2}", "= {-3/(x – 2)^2}"],
     ["y = {x + 1/x – 2}", "u = x + 1, v = x – 2, u' = 1, v' = 1", "y' = {(x + 1)(1) – (1)(x – 2)/(x – 2)^2}", "= {x + 1 – x + 2/(x – 2)^2}", "= {3/(x – 2)^2}"], 3,
     "misapplied rule", "quotient rule numerator written as u v' - u' v (reversed)")
prob("bc-calc-12", "ca12-74",
     ["{dy/dx} = 2xy", "{dy/y} = 2x dx", "ln|y| = x^2 + C", "y = Ae^{x^2}", "y(0) = 3 so A = 3", "y = 3e^{x^2}"],
     ["{dy/dx} = 2xy", "{dy/y} = 2x dx", "ln|y| = 2x^2 + C", "y = Ae^{2x^2}", "y(0) = 3 so A = 3", "y = 3e^{2x^2}"], 3,
     "integration slip", "antiderivative of 2x written as 2x^2")

# ---- BC Foundations of Math 12
prob("bc-fm-12", "fm12-01",
     ["A(1, 2)  B(7, 6)", "midpoint = ({1+7/2}, {2+6/2}) = (4, 4)", "slope AB = {6–2/7–1} = {4/6} = {2/3}", "perp slope = -{3/2}", "y – 4 = -{3/2}(x – 4)", "y = -{3/2}x + 10"],
     ["A(1, 2)  B(7, 6)", "midpoint = ({1+7/2}, {2+6/2}) = (4, 4)", "slope AB = {6–2/7–1} = {4/6} = {2/3}", "perp slope = {3/2}", "y – 4 = {3/2}(x – 4)", "y = {3/2}x – 2"], 4,
     "sign error", "perpendicular slope was the reciprocal but lost its negative sign")
prob("bc-fm-12", "fm12-20",
     ["y = a · b^x", "(0, 50): a = 50", "(3, 400): 50b^3 = 400", "b^3 = 8 so b = 2", "y = 50(2)^x", "y(5) = 50(2)^5 = 50(32) = 1600"],
     ["y = a · b^x", "(0, 50): a = 50", "(3, 400): 50b^3 = 400", "b^3 = 8 so b = {8/3}", "y = 50({8/3})^x", "y(5) = 50({8/3})^5 ≈ 6742"], 4,
     "misapplied root", "took the cube root of 8 as 8 divided by 3")
prob("bc-fm-12", "fm12-37",
     ["n = 6, k = 4, p = {1/2}", "P = C(6,4)({1/2})^4({1/2})^2", "C(6,4) = 15", "({1/2})^6 = {1/64}", "P = {15/64}"],
     ["n = 6, k = 4, p = {1/2}", "P = C(6,4)({1/2})^4({1/2})^2", "C(6,4) = 6 · 4 = 24", "({1/2})^6 = {1/64}", "P = {24/64} = {3/8}"], 3,
     "misapplied counting formula", "C(6,4) computed as 6 times 4")

# ---- BC Pre-calculus 12
prob("bc-pc-12", "pc12-37",
     ["log_3 x + log_3 (x – 2) = 1", "log_3 [x(x – 2)] = 1", "x(x – 2) = 3", "x^2 – 2x – 3 = 0", "(x – 3)(x + 1) = 0, x = 3 or -1", "x = -1 rejected, log of a negative", "x = 3"],
     ["log_3 x + log_3 (x – 2) = 1", "log_3 [x(x – 2)] = 1", "x(x – 2) = 1", "x^2 – 2x – 1 = 0", "x = {2 ± \\r{8}/2} = 1 ± \\r{2}", "x = 1 + \\r{2} (1 – \\r{2} is negative)", "x = 1 + \\r{2}"], 3,
     "misapplied log rule", "log equals 1 turned into argument equals 1 instead of 3^1")
prob("bc-pc-12", "pc12-08",
     ["y = {2x + 1/x – 3}", "x = {2y + 1/y – 3}", "x(y – 3) = 2y + 1", "xy – 3x = 2y + 1", "xy – 2y = 3x + 1", "y(x – 2) = 3x + 1", "y = {3x + 1/x – 2}"],
     ["y = {2x + 1/x – 3}", "x = {2y + 1/y – 3}", "x(y – 3) = 2y + 1", "xy – 3x = 2y + 1", "xy + 2y = 3x + 1", "y(x + 2) = 3x + 1", "y = {3x + 1/x + 2}"], 5,
     "moved term with wrong sign", "2y moved across the equals sign without changing its sign")
prob("bc-pc-12", "pc12-84",
     ["sin 2x = sin x", "2 sin x cos x = sin x", "2 sin x cos x – sin x = 0", "sin x (2 cos x – 1) = 0", "sin x = 0: x = 0, π", "cos x = {1/2}: x = {π/3}, {5π/3}"],
     ["sin 2x = sin x", "2 sin x cos x = sin x", "2 cos x = 1", "cos x = {1/2}", "x = {π/3}, {5π/3}"], 3,
     "divided by a factor (lost roots)", "divided both sides by sin x, losing x = 0 and x = pi")

# ---- Calculus I
prob("calculus-1", "c1-01",
     ["lim_{x→-3} {x^2 + 5x + 6/x^2 – 9}", "plug in: {0/0}, so factor", "= lim {(x + 2)(x + 3)/(x – 3)(x + 3)}", "= lim {x + 2/x – 3}", "= {-3 + 2/-3 – 3}", "= {-1/-6} = {1/6}"],
     ["lim_{x→-3} {x^2 + 5x + 6/x^2 – 9}", "plug in: {0/0}, so factor", "= lim {(x + 2)(x + 3)/(x – 3)(x + 3)}", "= lim {x + 2/x – 3}", "= {-3 + 2/-3 – 3}", "= {-1/-6} = -{1/6}"], 6,
     "sign error", "negative over negative written as negative")
prob("calculus-1", "c1-30",
     ["y = (sin 4x)^3", "y' = 3(sin 4x)^2 · {d/dx}(sin 4x)", "{d/dx}(sin 4x) = cos 4x · 4", "y' = 3 sin^2(4x) · 4 cos(4x)", "y' = 12 sin^2(4x) cos(4x)"],
     ["y = (sin 4x)^3", "y' = 3(sin 4x)^2 · {d/dx}(sin 4x)", "{d/dx}(sin 4x) = cos 4x", "y' = 3 sin^2(4x) · cos(4x)", "y' = 3 sin^2(4x) cos(4x)"], 3,
     "chain rule omission", "forgot the inner derivative 4")
prob("calculus-1", "c1-42",
     ["f'(x) = 6x^2 – 18x + 12", "= 6(x – 1)(x – 2)", "critical: x = 1, 2", "f(0) = 0, f(1) = 5", "f(2) = 16 – 36 + 24 = 4", "f(3) = 54 – 81 + 36 = 9", "max 9 at x = 3, min 0 at x = 0"],
     ["f'(x) = 6x^2 – 18x + 12", "= 6(x – 1)(x – 2)", "critical: x = 1, 2", "f(0) = 0, f(1) = 5", "f(2) = 16 – 36 + 24 = -4", "f(3) = 54 – 81 + 36 = 9", "max 9 at x = 3, min -4 at x = 2"], 5,
     "arithmetic slip", "16 - 36 + 24 written as -4 (should be 4)")

# ---- Discrete Mathematics
prob("discrete-math", "dm-31",
     ["1274 = 2·504 + 266", "504 = 1·266 + 238", "266 = 1·238 + 28", "238 = 8·28 + 14", "28 = 2·14 + 0", "gcd = 14"],
     ["1274 = 2·504 + 266", "504 = 1·266 + 238", "266 = 1·238 + 28", "238 = 8·28 + 12", "28 = 2·12 + 4", "12 = 3·4 + 0", "gcd = 4"], 4,
     "arithmetic slip", "238 - 8*28 written as 12 (should be 14)")
prob("discrete-math", "dm-52",
     ["at least 2 W = all – 0 W – 1 W", "all: C(13,5) = 1287", "0 W: C(7,5) = 21", "1 W: 6 · C(7,4) = 6 · 35 = 210", "1287 – 21 – 210 = 1056"],
     ["at least 2 W = all – 0 W – 1 W", "all: C(13,5) = 1287", "0 W: C(7,5) = 21", "1 W: C(6,1) = 6", "1287 – 21 – 6 = 1260"], 4,
     "dropped factor", "chose the woman but forgot to choose the 4 men")
prob("discrete-math", "dm-41",
     ["n = 0: 7^0 – 1 = 0 = 6 · 0", "assume 7^m – 1 = 6t", "7^{m+1} – 1 = 7 · 7^m – 1", "= 7(7^m – 1) + 6", "= 7(6t) + 6 = 6(7t + 1)", "multiple of 6, done"],
     ["n = 0: 7^0 – 1 = 0 = 6 · 0", "assume 7^m – 1 = 6t", "7^{m+1} – 1 = 7^m + 7 – 1", "= (7^m – 1) + 6", "= 6t + 6 = 6(t + 1)", "multiple of 6, done"], 3,
     "misapplied exponent law", "7^(m+1) written as 7^m + 7")

# ---- Linear Algebra
prob("linear-algebra", "la-07",
     ["A = \\m{2|-1;0|3}  B = \\m{1|4;-2|5}", "AB = \\m{2+2|8–5;0–6|0+15}", "AB = \\m{4|3;-6|15}", "BA = \\m{2+0|-1+12;-4+0|2+15}", "BA = \\m{2|11;-4|17}", "AB ≠ BA"],
     ["A = \\m{2|-1;0|3}  B = \\m{1|4;-2|5}", "AB = \\m{2–2|8–5;0–6|0+15}", "AB = \\m{0|3;-6|15}", "BA = \\m{2+0|-1+12;-4+0|2+15}", "BA = \\m{2|11;-4|17}", "AB ≠ BA"], 2,
     "sign error", "(-1)(-2) written as -2 so 2 + 2 became 2 - 2")
prob("linear-algebra", "la-61",
     ["A = \\m{4|1;2|3}", "det(A – λI) = (4 – λ)(3 – λ) – (1)(2)", "= λ^2 – 7λ + 12 – 2", "= λ^2 – 7λ + 10", "= (λ – 2)(λ – 5)", "λ = 2, 5"],
     ["A = \\m{4|1;2|3}", "det(A – λI) = (4 – λ)(3 – λ) + (1)(2)", "= λ^2 – 7λ + 12 + 2", "= λ^2 – 7λ + 14", "disc = 49 – 56 = -7 < 0", "no real eigenvalues"], 2,
     "misapplied determinant formula", "added the off-diagonal product instead of subtracting it")
prob("linear-algebra", "la-36",
     ["point (4, 0, 1), plane 2x – 2y + z = 3", "d = {|ax_0 + by_0 + cz_0 – d| / \\r{a^2 + b^2 + c^2}}", "top: |2(4) – 2(0) + 1 – 3| = |8 + 1 – 3| = 6", "bottom: \\r{4 + 4 + 1} = \\r{9} = 3", "d = {6/3} = 2"],
     ["point (4, 0, 1), plane 2x – 2y + z = 3", "d = {|ax_0 + by_0 + cz_0 – d| / \\r{a^2 + b^2 + c^2}}", "top: |2(4) – 2(0) + 1 + 3| = |8 + 1 + 3| = 12", "bottom: \\r{4 + 4 + 1} = \\r{9} = 3", "d = {12/3} = 4"], 3,
     "sign error", "the plane's constant 3 added instead of subtracted")


# ---------------------------------------------------------------- parsing
def find_close(s, i):
    """s[i] is '{'; return the index of its matching '}'."""
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                return j
    raise ValueError(f"unbalanced braces in {s!r}")


def split_top(s, seps):
    """Split s on any char in seps that sits outside braces. Returns (parts, which) with which = the sep char found."""
    depth, parts, cur, found = 0, [], "", []
    for ch in s:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if depth == 0 and ch in seps:
            parts.append(cur)
            found.append(ch)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return parts, found


def parse(s):
    nodes, i = [], 0
    while i < len(s):
        ch = s[i]
        if ch == "{":
            j = find_close(s, i)
            inner = s[i + 1 : j]
            parts, _ = split_top(inner, "/")
            if len(parts) >= 2:
                top = "/".join(parts[:-1])
                nodes.append(("frac", parse(top), parse(parts[-1])))
            else:
                nodes.extend(parse(inner))
            i = j + 1
        elif ch in "^_":
            kind = "sup" if ch == "^" else "sub"
            if s[i + 1] == "{":
                j = find_close(s, i + 1)
                nodes.append((kind, parse(s[i + 2 : j])))
                i = j + 1
            else:
                nodes.append((kind, [("c", s[i + 1])]))
                i += 2
        elif ch == "\\" and s[i + 1] in "rc":
            j = find_close(s, i + 2)
            nodes.append(("sqrt", parse(s[i + 3 : j]), 3 if s[i + 1] == "c" else None))
            i = j + 1
        elif ch == "\\" and s[i + 1] == "m":
            j = find_close(s, i + 2)
            rows = [[parse(c) for c in r.split("|")] for r in s[i + 3 : j].split(";")]
            nodes.append(("mat", rows))
            i = j + 1
        elif ch == "-":
            nodes.append(("c", "–"))
            i += 1
        elif ch == " ":
            nodes.append(("sp",))
            i += 1
        else:
            nodes.append(("c", ch))
            i += 1
    return nodes


# ---------------------------------------------------------------- fonts
def ensure_font(rel):
    path = os.path.join(FONT_DIR, os.path.basename(rel).replace("%5B", "").replace("%5D", "").replace("wght", ""))
    if not os.path.exists(path):
        os.makedirs(FONT_DIR, exist_ok=True)
        print("downloading", rel)
        urllib.request.urlretrieve(GF + rel, path)
    return path


class Face:
    """A handwriting font plus the math fallback; picks per character which one has the glyph."""

    def __init__(self, key):
        rel, size = FONT_FILES[key]
        self.path = ensure_font(rel)
        self.fallback = ensure_font(FALLBACK_FILE)
        self.size = size
        self._f = {}
        self._cov = {}

    def has(self, path, ch):
        if path not in self._cov:
            from fontTools.ttLib import TTFont  # Pillow cannot say which glyphs a font has

            self._cov[path] = set(TTFont(path).getBestCmap().keys())
        return ord(ch) in self._cov[path]

    def font_for(self, ch, size):
        path = self.path if self.has(self.path, ch) else self.fallback
        size = max(10, int(round(size)))
        key = (path, size)
        if key not in self._f:
            f = ImageFont.truetype(path, size)
            if path == self.path and "Caveat" in path:
                try:
                    f.set_variation_by_axes([500])
                except Exception:
                    pass
            self._f[key] = f
        return self._f[key]


def glyph(face, ch, size, rot, shear):
    f = face.font_for(ch, size)
    pad = int(size * 0.5)
    im = Image.new("L", (int(size * 1.9), int(size * 2.4)), 0)
    base = (pad, int(size * 1.5))
    ImageDraw.Draw(im).text(base, ch, font=f, fill=255, anchor="ls")
    a = math.radians(rot)
    c, s = math.cos(a), math.sin(a)
    ox, oy = base
    ra = (c, s, ox - c * ox - s * oy, -s, c, oy + s * ox - c * oy)
    sa = (1, shear, -shear * oy, 0, 1, 0)
    affine = (sa[0] * ra[0] + sa[1] * ra[3], sa[0] * ra[1] + sa[1] * ra[4], sa[0] * ra[2] + sa[1] * ra[5] + sa[2], ra[3], ra[4], ra[5])
    return im.transform(im.size, Image.AFFINE, affine, resample=Image.BICUBIC), base, f.getlength(ch)


# ---------------------------------------------------------------- layout
# An op is ("mask", im, dx, dy) or ("line", [(x, y), ...], width); coordinates are relative to the row origin
# (x = 0 at the left, y = 0 on the baseline, y grows downward).
def op_box(op):
    if op[0] == "mask":
        bb = op[1].getbbox()
        if not bb:
            return None
        return (op[2] + bb[0], op[3] + bb[1], op[2] + bb[2], op[3] + bb[3])
    pts = op[1]
    return (min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts))


def ops_box(ops):
    boxes = [b for b in (op_box(o) for o in ops) if b]
    if not boxes:
        return None
    return (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))


def shift(ops, dx, dy):
    out = []
    for o in ops:
        if o[0] == "mask":
            out.append(("mask", o[1], o[2] + dx, o[3] + dy))
        else:
            out.append(("line", [(x + dx, y + dy) for x, y in o[1]], o[2]))
    return out


def tilt(ops, slope):
    """Let a row drift up or down as it runs to the right (slope = rise per pixel), as a hand does on an unruled page."""
    out = []
    for o in ops:
        if o[0] == "mask":
            out.append(("mask", o[1], o[2], o[3] + slope * o[2]))
        else:
            out.append(("line", [(x, y + slope * x) for x, y in o[1]], o[2]))
    return out


class Writer:
    def __init__(self, face, slant, rng):
        self.face = face
        self.slant = slant
        self.rng = rng

    def layout(self, nodes, size):
        """Returns (ops, width). Origin at the left of the first node, baseline y = 0."""
        rng, face = self.rng, self.face
        ops, x = [], 0.0
        run_scale, run_dy, run_shear = 1.0, 0.0, self.slant
        for n in nodes:
            kind = n[0]
            if kind == "sp":
                x += size * rng.uniform(0.20, 0.34)
                run_scale = rng.uniform(0.94, 1.08)
                run_dy = rng.uniform(-2.5, 2.5)
                run_shear = self.slant + rng.uniform(-0.05, 0.05)
            elif kind == "c":
                ch = n[1]
                sz = size * run_scale * rng.uniform(0.95, 1.05)
                wild = 2.2 if MESSY else 1.0  # messy: glyphs tilt and bob about twice as much
                im, base, adv = glyph(face, ch, sz, rng.uniform(-5, 5) * wild, run_shear + rng.uniform(-0.04, 0.04) * wild)
                ops.append(("mask", im, x - base[0], run_dy + rng.uniform(-2, 2) * wild - base[1]))
                adv *= rng.uniform(0.9, 1.06)
                if ch in "·.,":
                    adv *= 0.9
                x += adv + rng.uniform(-1.2, 2.2)
            elif kind in ("sup", "sub"):
                sub_ops, w = self.layout(n[1], size * 0.62)
                dy = -size * 0.46 if kind == "sup" else size * 0.20
                ops += shift(sub_ops, x + 1, dy + run_dy)
                x += w + 3
            elif kind == "frac":
                fs = size * 0.80
                num_ops, nw = self.layout(n[1], fs)
                den_ops, dw = self.layout(n[2], fs)
                bw = max(nw, dw) + 14
                axis = size * 0.34
                nb = ops_box(num_ops) or (0, -fs, 0, 0)
                db = ops_box(den_ops) or (0, 0, 0, fs)
                num_y = -axis - 7 - nb[3]            # numerator's lowest ink sits 7 px above the bar
                den_y = -axis + 9 - db[1]            # denominator's highest ink sits 9 px below the bar
                ops += shift(num_ops, x + 7 + (bw - 14 - nw) / 2 + rng.uniform(-2, 2), num_y)
                ops += shift(den_ops, x + 7 + (bw - 14 - dw) / 2 + rng.uniform(-2, 2), den_y)
                tilt = rng.uniform(-2.2, 2.2)
                ops.append(("line", [(x + 1, -axis - tilt), (x + bw - 1, -axis + tilt)], 3))
                x += bw + 4
            elif kind == "sqrt":
                inner, w = self.layout(n[1], size)
                ib = ops_box(inner) or (0, -size * 0.8, 0, 0)
                top = min(-size * 0.92, ib[1] - 7)
                lead = size * 0.62
                if n[2]:
                    idx_ops, _ = self.layout([("c", str(n[2]))], size * 0.42)
                    ops += shift(idx_ops, x + 1, top + size * 0.55)
                j = lambda: rng.uniform(-1.5, 1.5)  # noqa: E731
                pts = [(x + 2, -size * 0.34 + j()), (x + size * 0.14, -size * 0.40 + j()), (x + size * 0.32, 4 + j()), (x + lead - 4, top + j()), (x + lead + w + 6, top + j())]
                ops.append(("line", pts, 3))
                ops += shift(inner, x + lead + 1, 0)
                x += lead + w + 8
            elif kind == "mat":
                rows = n[1]
                cell_ops = [[self.layout(c, size * 0.9) for c in r] for r in rows]
                ncol = max(len(r) for r in cell_ops)
                colw = [max((r[c][1] for r in cell_ops if c < len(r)), default=0) for c in range(ncol)]
                rowh = size * 1.12
                nrow = len(rows)
                total_h = rowh * nrow
                cx = x + 14
                for ri, r in enumerate(cell_ops):
                    base_y = (ri - (nrow - 1) / 2) * rowh + size * 0.30
                    cx2 = cx
                    for ci, (cops, cw) in enumerate(r):
                        ops += shift(cops, cx2 + (colw[ci] - cw) / 2, base_y)
                        cx2 += colw[ci] + size * 0.45
                width = sum(colw) + size * 0.45 * (ncol - 1)
                top, bot = -total_h / 2 + size * 0.14, total_h / 2 + size * 0.12
                for bx, d in ((x + 2, 1), (x + width + 26, -1)):
                    ops.append(("line", [(bx + d * 9 + rng.uniform(-1, 1), top), (bx + rng.uniform(-1, 1), top + 2), (bx + rng.uniform(-1, 1), bot - 2), (bx + d * 9 + rng.uniform(-1, 1), bot)], 3))
                x += width + 32
        return ops, x


# ---------------------------------------------------------------- drawing a page
def paste_ops(img, ops, ox, oy, ink):
    d = ImageDraw.Draw(img)
    for o in ops:
        if o[0] == "mask":
            img.paste(Image.new("RGB", o[1].size, ink), (int(round(ox + o[2])), int(round(oy + o[3]))), o[1])
        else:
            d.line([(ox + a, oy + b) for a, b in o[1]], fill=ink, width=o[2], joint="curve")


def stray_mark(page, kind, x, y, ink, rng):
    d = ImageDraw.Draw(page)
    if kind == "dots":
        for _ in range(rng.randint(2, 4)):
            r = rng.uniform(1.5, 3)
            px, py = x + rng.uniform(-12, 12), y + rng.uniform(-8, 8)
            d.ellipse((px - r, py - r, px + r, py + r), fill=ink)
    elif kind == "tick":
        d.line([(x, y), (x + 9, y + 14), (x + 30, y - 18)], fill=ink, width=3)
    elif kind == "squiggle":
        d.line([(x + i * 9, y + (6 if i % 2 else -6) + rng.uniform(-2, 2)) for i in range(7)], fill=ink, width=2)
    elif kind == "dash":
        d.line([(x, y), (x + 38, y + rng.uniform(-3, 3))], fill=ink, width=3)


def render(rows, seed, font_key):
    rng = random.Random(seed)
    face = Face(font_key)
    ink = (86, 88, 100) if MESSY else INKS[seed % len(INKS)]  # messy: soft grey pencil instead of dark pen
    slant = rng.uniform(-0.08, 0.20)
    writer = Writer(face, slant, rng)
    label_font = ImageFont.truetype(NUM_FONT, 12)

    laid = []
    for r, text in enumerate(rows):
        nodes = parse(text)
        x0 = 64 + rng.randint(-4, 14)
        for attempt in range(8):
            ops, width = writer.layout(nodes, face.size * (1.0 - 0.06 * attempt))
            if width <= W - x0 - 30:
                break
        if MESSY:
            ops = tilt(ops, rng.uniform(-0.045, 0.045))
        laid.append((x0, ops, ops_box(ops)))

    # baselines: each row is placed so its ink clears the one above by at least ~26 px, and rows are never closer than 70 px
    y, ys, prev_bottom = 0.0, [], None
    for r, (_, _, box) in enumerate(laid):
        top, bottom = (box[1], box[3]) if box else (-30, 12)
        if r == 0:
            y = 48 - top
        else:
            y = max(y + 70 + rng.uniform(0, 10), prev_bottom_y + 26 - top)
        ys.append(y)
        prev_bottom_y = y + bottom
    height = int(min(MAX_H, max(544, prev_bottom_y + 60)))
    if prev_bottom_y + 40 > MAX_H:
        raise ValueError(f"page too tall ({prev_bottom_y:.0f} px) for rows {rows[:2]}")

    img = Image.new("RGB", (W, height), (255, 255, 255))
    d = ImageDraw.Draw(img)
    lines_meta = []
    for r, ((x0, ops, box), by) in enumerate(zip(laid, ys)):
        paste_ops(img, ops, x0, by, ink)
        if not box:
            continue
        pad = 6
        l, t, rr, b = x0 + box[0], by + box[1], x0 + box[2], by + box[3]
        lines_meta.append(dict(index=r + 1, box=dict(x=max(0, int(l) - pad), y=max(0, int(t) - pad), w=int(rr - l) + 2 * pad, h=int(b - t) + 2 * pad)))
        d.text((4, (t + b) / 2 - 7), str(r + 1), font=label_font, fill=(140, 140, 140))
    if rng.random() < 0.4:
        stray_mark(img, rng.choice(["dots", "tick", "squiggle", "dash"]), rng.randint(780, 960), rng.randint(height - 90, height - 30), ink, rng)
    if MESSY:
        img = img.filter(ImageFilter.GaussianBlur(0.9))
        grain = Image.effect_noise(img.size, 14).point(lambda v: 232 + max(0, min(23, (v - 100) // 6)))  # paper grain, 232..255
        img = ImageChops.multiply(img, Image.merge("RGB", [grain] * 3))
        k = 0.78  # a zoomed-out page: the app shrinks big pages to fit 1024 px
        img = img.resize((int(W * k), int(height * k)), Image.LANCZOS)
        for m in lines_meta:
            b = m["box"]
            m["box"] = dict(x=int(b["x"] * k), y=int(b["y"] * k), w=int(b["w"] * k), h=int(b["h"] * k))
        W_out, height = img.width, img.height
    else:
        img = img.filter(ImageFilter.GaussianBlur(0.35))
        W_out = W
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue(), lines_meta, height, W_out


def plain(row):
    """The row as readable text for the manifest (markup stripped to something a person can read)."""
    return row.replace("\\r", "sqrt").replace("\\c", "cbrt").replace("\\m", "matrix")


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in os.listdir(OUT):
        os.remove(os.path.join(OUT, name))
    fonts = list(FONT_FILES)
    manifest, n = [], 0
    for pi, p in enumerate(P):
        for variant in ("correct", "wrong"):
            rows = p["correct"] if variant == "correct" else p["wrong"]
            font_key = fonts[(pi + (1 if variant == "wrong" else 0) * 2) % len(fonts)]  # the two pages of a problem use different pens
            seed = 31000 + pi * 7 + (3 if variant == "wrong" else 0)
            png, lines, height, width = render(rows, seed + (500 if MESSY else 0), font_key)
            assert len(png) < 400 * 1024, (p["problem_id"], len(png))
            pid = p["problem_id"]
            name = f"{p['course']}__{pid}__{variant}" + (f"-w{p['wrong_line']}" if variant == "wrong" else "")
            open(os.path.join(OUT, name + ".png"), "wb").write(png)
            wl = p["wrong_line"] if variant == "wrong" else None
            manifest.append(dict(
                id=name, file=name + ".png", course=p["course"], problem_id=pid,
                category="wrong" if variant == "wrong" else "correct_finished",
                error_type=p["error_type"] if variant == "wrong" else None,
                planted=p["planted"] if variant == "wrong" else None,
                wrong_line=wl, wrong_line_is_latest=bool(wl) and wl == len(rows),
                half_written_last_line=False, font=font_key, width=width, height=height, bytes=len(png),
                lines=lines, rows=[plain(r) for r in rows],
            ))
            n += 1
    json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=1, ensure_ascii=False)
    courses = sorted({m["course"] for m in manifest})
    print(n, "pages,", len(P), "problems,", len(courses), "courses; tallest", max(m["height"] for m in manifest), "px; largest", max(m["bytes"] for m in manifest), "bytes")


if __name__ == "__main__":
    main()
