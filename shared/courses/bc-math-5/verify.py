#!/usr/bin/env python3
"""BC Mathematics 5 problem bank: source of truth + mechanical checker.

  python3 -I verify.py --write   regenerate problems.json from the source below
  python3 -I verify.py           check problems.json matches the source AND that every
                                 final answer / key intermediate matches an independent
                                 Python computation (ints, Fraction, Decimal, datetime).
Exits non-zero on any failure.  Last run: see README.md.
"""
import json
import sys
from datetime import datetime, timedelta
from decimal import Decimal as D
from fractions import Fraction as F
from itertools import count
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "problems.json"


def n(x):
    """Canadian style: thin-space groups from 5 digits up; decimals as plain strings."""
    if isinstance(x, F):
        return f"{x.numerator}/{x.denominator}" if x.denominator != 1 else n(x.numerator)
    if isinstance(x, D):
        s = format(x.normalize(), "f")
        if "." not in s:
            return n(int(s))
        a, b = s.split(".")
        return n(int(a)) + "." + b
    if isinstance(x, int):
        s = str(abs(x))
        if len(s) >= 5:
            g = []
            while s:
                g.insert(0, s[-3:])
                s = s[:-3]
            s = " ".join(g)
        return ("-" if x < 0 else "") + s
    return str(x)


def money(x):
    return "$" + format(D(x).quantize(D("0.01")), "f")


def clock(dt):
    h = dt.hour % 12 or 12
    return f"{h}:{dt.minute:02d} {'a.m.' if dt.hour < 12 else 'p.m.'}"


STD = {
    "S1": "Number concepts to 1 000 000 (counting, comparing/ordering, estimating, place value)",
    "S2": "Decimals to thousandths",
    "S3": "Equivalent fractions",
    "S4": "Whole-number, fraction and decimal benchmarks; comparing and ordering fractions and decimals",
    "S5": "Addition and subtraction of whole numbers to 1 000 000 (incl. estimating)",
    "S6": "Multiplication and division to three digits, including division with remainders",
    "S7": "Addition and subtraction of decimals to thousandths (incl. estimating)",
    "S8": "Addition and subtraction facts to 20 (extending computational fluency)",
    "S9": "Multiplication and division facts to 100 (emerging computational fluency)",
    "S10": "Rules for increasing and decreasing patterns (words, numbers, symbols, variables)",
    "S11": "One-step equations with variables",
    "S12": "Area of squares and rectangles; relationships between area and perimeter",
    "S13": "Duration, using measurement of time",
    "S14": "Classification of prisms and pyramids (3D objects, 2D shapes, quadrilaterals)",
    "S15": "Single transformations (slide/translation, flip/reflection, turn/rotation)",
    "S16": "One-to-one and many-to-one correspondence, using double bar graphs",
    "S17": "Probability experiments: single events or outcomes",
    "S18": "Financial literacy: monetary calculations, making change, simple financial plans",
}

PROBLEMS = []  # (std, prompt_plain, parts_or_None, steps, answer, checks)


def P(std, prompt, steps, answer, checks, parts=None):
    PROBLEMS.append((std, prompt, parts, steps, answer, checks))


def frac(a, b):
    return {"frac": {"num": str(a), "den": str(b)}}


# ---------------------------------------------------------------- S1
P("S1", "In the number 482 539, what is the value of the digit 8?",
  ["Read the places from the right: 9 ones, 3 tens, 5 hundreds, 2 thousands, 8 ten-thousands, 4 hundred-thousands.",
   "The 8 is in the ten-thousands place, so its value is 8 × 10 000.",
   f"8 × 10 000 = {n(8*10000)}"],
  f"{n(8*10000)}", [n(80000), n(8*10000)])
P("S1", "Write 400 000 + 7000 + 60 + 2 as a standard numeral.",
  ["Line up the places: 4 hundred-thousands, 0 ten-thousands, 7 thousands, 0 hundreds, 6 tens, 2 ones.",
   "A 0 holds each empty place: 4 0 7 0 6 2.",
   f"{n(400000+7000+60+2)}"],
  f"{n(400000+7000+60+2)}", [n(400000 + 7000 + 60 + 2)])
_o = sorted([245310, 254130, 245130, 254310])
P("S1", "Put these numbers in order from least to greatest: 245 310, 254 130, 245 130, 254 310.",
  ["All four have 6 digits. Compare the hundred-thousands: all are 2.",
   "Compare the ten-thousands: 245 130 and 245 310 have 4; 254 130 and 254 310 have 5. So the 4s come first.",
   "Between 245 130 and 245 310, the thousands match (5), so look at the hundreds: 1 < 3.",
   "Between 254 130 and 254 310, the hundreds again: 1 < 3.",
   "Order: " + ", ".join(n(v) for v in _o)],
  ", ".join(n(v) for v in _o), [", ".join(n(v) for v in _o)])
P("S1", "Round 674 829 to the nearest ten thousand.",
  ["The ten-thousands digit is 7. Look at the digit to its right, the thousands: 4.",
   "4 is less than 5, so round down and keep the 7.",
   f"Everything to the right becomes 0: {n(round(674829, -4))}"],
  n(round(674829, -4)), [n(670000)])
P("S1", "Skip count by 25 000 starting at 100 000. What is the 5th number you say?",
  ["Say each number by adding 25 000.",
   "1st: 100 000, 2nd: 125 000, 3rd: 150 000, 4th: 175 000.",
   "5th: 175 000 + 25 000 = 200 000"],
  n(100000 + 4*25000), [n(100000 + 4*25000), n(175000)])
P("S1", "How many ten thousands are in 530 000?",
  ["Think: how many groups of 10 000 fit in 530 000?",
   "530 000 ÷ 10 000 = 53",
   "Check: 53 × 10 000 = 530 000"],
  str(530000 // 10000), [530000 // 10000, n(53*10000)])

# ---------------------------------------------------------------- S2
P("S2", "What is the value of the digit 6 in 4.768?",
  ["The places after the decimal point are tenths, hundredths, thousandths.",
   "4.768: the 7 is in tenths, the 6 is in hundredths, the 8 is in thousandths.",
   "The 6 stands for 6 hundredths, which is 6/100 = 0.06"],
  "6 hundredths (0.06)", ["0.06", "6/100"])
P("S2", "Write as a decimal: 2 ones, 0 tenths, 7 hundredths, 4 thousandths.",
  ["Write the ones, then the decimal point: 2.",
   "Tenths 0, hundredths 7, thousandths 4: 2.074",
   "Check by adding: 2 + 0.07 + 0.004 = 2.074"],
  "2.074", [n(D(2) + D("0.07") + D("0.004"))])
_d = sorted([D("0.38"), D("0.308"), D("0.83"), D("0.083")])
P("S2", "Order from least to greatest: 0.38, 0.308, 0.83, 0.083.",
  ["Give each one three decimal places: 0.380, 0.308, 0.830, 0.083.",
   "Compare as if they were whole numbers: 83 < 308 < 380 < 830.",
   "Order: " + ", ".join(n(v) for v in _d)],
  ", ".join(n(v) for v in _d), [", ".join(n(v) for v in _d)])
P("S2", "Write 0.275 as a fraction in simplest form.",
  ["0.275 means 275 thousandths, so it is 275/1000.",
   "Both numbers divide by 25: 275 ÷ 25 = 11 and 1000 ÷ 25 = 40.",
   f"Answer: {n(F(275,1000))}"],
  n(F(275, 1000)), [n(F(275, 1000)), 275 // 25, 1000 // 25])

# ---------------------------------------------------------------- S3
P("S3", "Fill in the missing number: 3/5 = ?/20",
  ["The denominator went from 5 to 20. 20 ÷ 5 = 4, so multiply by 4.",
   "Do the same to the numerator: 3 × 4 = 12",
   "3/5 = 12/20"],
  "12", [20 // 5, 3 * (20 // 5)], parts=[frac(3, 5), {"text": " = "}, frac("?", 20)])
P("S3", "Write 18/24 in simplest form.",
  ["Find the biggest number that divides both: 6 goes into 18 and into 24.",
   "18 ÷ 6 = 3 and 24 ÷ 6 = 4",
   f"18/24 = {n(F(18,24))}"],
  n(F(18, 24)), [n(F(18, 24)), 18 // 6, 24 // 6])
P("S3", "Are 4/6 and 10/15 equivalent fractions? Show why.",
  ["Simplify 4/6: divide top and bottom by 2 to get 2/3.",
   "Simplify 10/15: divide top and bottom by 5 to get 2/3.",
   "Both equal 2/3, so they are equivalent."],
  "Yes, both equal 2/3", [n(F(4, 6)), n(F(10, 15)), F(4, 6) == F(10, 15)])
P("S3", "Find a and b: 2/3 = a/12 = 14/b",
  ["For a: 3 × 4 = 12, so a = 2 × 4 = 8.",
   "For b: 2 × 7 = 14, so b = 3 × 7 = 21.",
   "Check: 8/12 = 2/3 and 14/21 = 2/3"],
  "a = 8, b = 21", [12 // 3 * 2, 14 // 2 * 3, F(8, 12) == F(2, 3) == F(14, 21)])
P("S3", "Mia ate 6/8 of a small pizza. Jon ate 3/4 of an identical pizza. Who ate more?",
  ["Write 3/4 with a denominator of 8: 3/4 = 6/8 (multiply top and bottom by 2).",
   "Mia ate 6/8 and Jon ate 6/8.",
   "They ate the same amount."],
  "They ate the same amount", [F(6, 8) == F(3, 4), 3 * 2])

# ---------------------------------------------------------------- S4
P("S4", "Which is greater, 3/8 or 1/2? Use a benchmark.",
  ["Use 1/2 as the benchmark. Write 1/2 as 4/8.",
   "3/8 has fewer eighths than 4/8.",
   "So 3/8 < 1/2, and 1/2 is greater."],
  "1/2 is greater", [F(3, 8) < F(1, 2), 4])
_f = sorted([F(3, 4), F(2, 5), F(7, 8)])
P("S4", "Order from least to greatest: 3/4, 2/5, 7/8.",
  ["Use 1/2 as a benchmark: 2/5 is less than 1/2 (half of 5 is 2.5), so it is smallest.",
   "Write 3/4 as 6/8. Now compare 6/8 and 7/8: 6/8 < 7/8.",
   "Order: 2/5, 3/4, 7/8"],
  ", ".join(n(v) for v in _f), [", ".join(n(v) for v in _f), F(3, 4) == F(6, 8)])
P("S4", "Which is greater, 0.7 or 3/5?",
  ["Turn 3/5 into tenths: multiply top and bottom by 2 to get 6/10.",
   "6/10 = 0.6",
   "0.7 > 0.6, so 0.7 is greater."],
  "0.7 is greater", [F(3, 5) == D("0.6"), D("0.7") > D("0.6")])
P("S4", "Is 7/12 closest to 0, to 1/2, or to 1?",
  ["Write 1/2 with a denominator of 12: 1/2 = 6/12.",
   "7/12 is only 1/12 more than 6/12.",
   "It is far from 0 (0/12) and from 1 (12/12), so it is closest to 1/2."],
  "1/2", [F(7, 12) - F(1, 2) == F(1, 12), F(1, 2) == F(6, 12)])
P("S4", "Which number is closer to 1 whole, 0.9 or 7/8?",
  ["Find how far each is from 1.",
   "1 − 0.9 = 0.1, which is 1/10.",
   "1 − 7/8 = 1/8",
   "Eighths are bigger pieces than tenths, so 1/8 > 1/10.",
   "7/8 is 1/8 away from 1 and 0.9 is only 1/10 away, so 0.9 is closer to 1."],
  "0.9", [D(1) - D("0.9"), F(1) - F(7, 8), F(1, 8) > F(1, 10), D("0.9") > D(7) / D(8)])

# ---------------------------------------------------------------- S5
P("S5", "Find 348 765 + 219 487.",
  ["Add the ones: 5 + 7 = 12. Write 2, carry 1 ten.",
   "Tens: 6 + 8 + 1 = 15. Write 5, carry 1 hundred.",
   "Hundreds: 7 + 4 + 1 = 12. Write 2, carry 1 thousand.",
   "Thousands: 8 + 9 + 1 = 18. Write 8, carry 1 ten-thousand.",
   "Ten-thousands: 4 + 1 + 1 = 6. Hundred-thousands: 3 + 2 = 5.",
   f"348 765 + 219 487 = {n(348765+219487)}"],
  n(348765 + 219487), [n(568252)])
P("S5", "Find 700 000 − 256 389.",
  ["Count up from 256 389 to 700 000 in easy jumps.",
   "256 389 + 11 = 256 400",
   "256 400 + 43 600 = 300 000",
   "300 000 + 400 000 = 700 000",
   "Add the jumps: 11 + 43 600 + 400 000 = 443 611"],
  n(700000 - 256389), [n(443611), 300000 - 256400, 11 + 43600 + 400000])
P("S5", "A city had 482 350 people. This year 37 905 more people moved in. How many people live there now?",
  ["Add: 482 350 + 37 905.",
   "482 350 + 30 000 = 512 350",
   "512 350 + 7 905 = 520 255",
   "Check by estimating: 480 000 + 40 000 = 520 000, which is close."],
  f"{n(482350+37905)} people", [n(520255), n(512350)])
P("S5", "Estimate 8764 + 3198 by rounding to the nearest thousand. Then find the exact sum.",
  ["Round: 8764 → 9000 and 3198 → 3000.",
   "Estimate: 9000 + 3000 = 12 000",
   "Exact: 8764 + 3198 = 8764 + 3000 + 198 = 11 764 + 198 = 11 962",
   "11 962 is close to the estimate of 12 000."],
  f"Estimate {n(12000)}; exact {n(8764+3198)}", [n(12000), n(11962), 8764 + 3000, round(8764, -3) + round(3198, -3)])
P("S5", "500 000 − □ = 174 250. Find the missing number.",
  ["Subtraction and addition undo each other: □ = 500 000 − 174 250.",
   "174 250 + 25 750 = 200 000",
   "200 000 + 300 000 = 500 000",
   "□ = 25 750 + 300 000 = 325 750",
   "Check: 500 000 − 325 750 = 174 250"],
  n(500000 - 174250), [n(325750), 25750 + 300000, 500000 - 325750 == 174250])

# ---------------------------------------------------------------- S6
P("S6", "Find 237 × 4.",
  ["Break 237 into 200 + 30 + 7.",
   "200 × 4 = 800",
   "30 × 4 = 120",
   "7 × 4 = 28",
   "800 + 120 + 28 = 948"],
  n(237 * 4), [800, 120, 28, 948])
P("S6", "Find 36 × 24.",
  ["Break 24 into 20 + 4.",
   "36 × 20 = 720",
   "36 × 4 = 144",
   "720 + 144 = 864"],
  n(36 * 24), [720, 144, 864])
P("S6", "Find 156 ÷ 6.",
  ["Think of multiplication: how many 6s make 156?",
   "6 × 20 = 120, and 156 − 120 = 36",
   "6 × 6 = 36",
   "20 + 6 = 26",
   "Check: 6 × 26 = 156"],
  str(156 // 6), [156 - 120, 20 + 6, 6 * 26 == 156, 156 % 6 == 0])
P("S6", "Find 487 ÷ 5. Write the answer with a remainder.",
  ["5 × 90 = 450, and 487 − 450 = 37",
   "5 × 7 = 35, and 37 − 35 = 2",
   "90 + 7 = 97 with 2 left over.",
   "Check: 5 × 97 + 2 = 485 + 2 = 487"],
  f"{487//5} R {487%5}", [487 - 450, 37 - 35, 5 * 97 + 2, f"{487//5} R {487%5}"][:3])
P("S6", "250 students go on a trip. Each bus holds 48 students. How many buses are needed?",
  ["Divide: 250 ÷ 48.",
   "48 × 5 = 240, and 250 − 240 = 10",
   "So 5 full buses with 10 students left over.",
   "Those 10 students still need a ride, so one more bus.",
   "5 + 1 = 6 buses"],
  "6 buses", [48 * 5, 250 - 240, -(-250 // 48)])

# ---------------------------------------------------------------- S7
P("S7", "Find 3.482 + 2.75.",
  ["Line up the decimal points and add a zero: 3.482 + 2.750.",
   "Thousandths: 2 + 0 = 2. Hundredths: 8 + 5 = 13, write 3 and carry 1.",
   "Tenths: 4 + 7 + 1 = 12, write 2 and carry 1. Ones: 3 + 2 + 1 = 6.",
   f"3.482 + 2.750 = {n(D('3.482') + D('2.75'))}"],
  n(D("3.482") + D("2.75")), [n(D("6.232"))])
P("S7", "Find 8 − 3.275.",
  ["Count up from 3.275 to 8 in jumps.",
   "3.275 + 0.725 = 4 (the jump to the next whole number)",
   "4 + 4 = 8 (the jump from 4 to 8)",
   "Add the jumps: 0.725 + 4 = 4.725",
   "Check: 4.725 + 3.275 = 8.000"],
  n(D(8) - D("3.275")), [n(D("4.725")), D("0.725") + 4, D("4.725") + D("3.275") == 8, D("3.275") + D("0.725") == 4])
P("S7", "A jug holds 1.25 L of juice. Another holds 0.875 L. How much juice is there in all?",
  ["Add: 1.25 + 0.875. Write 1.25 as 1.250.",
   "1.250 + 0.875",
   "Thousandths: 0 + 5 = 5. Hundredths: 5 + 7 = 12, write 2 and carry 1.",
   "Tenths: 2 + 8 + 1 = 11, write 1 and carry 1. Ones: 1 + 0 + 1 = 2.",
   "Total: 2.125 L"],
  f"{n(D('1.25') + D('0.875'))} L", [n(D("2.125"))])
P("S7", "Estimate 6.89 + 4.12 by rounding each to the nearest whole number. Then find the exact sum.",
  ["6.89 is close to 7 and 4.12 is close to 4.",
   "Estimate: 7 + 4 = 11",
   "Exact: 6.89 + 4 = 10.89",
   "10.89 + 0.12 = 11.01",
   "11.01 is close to the estimate of 11."],
  f"Estimate 11; exact {n(D('6.89') + D('4.12'))}", [11, n(D("10.89")), n(D("11.01")), round(D("6.89")) + round(D("4.12"))])
P("S7", "12.5 − □ = 7.842. Find the missing number.",
  ["□ = 12.5 − 7.842. Write 12.5 as 12.500.",
   "7.842 + 0.158 = 8",
   "8 + 4.5 = 12.5",
   "□ = 0.158 + 4.5 = 4.658",
   "Check: 12.5 − 4.658 = 7.842"],
  n(D("12.5") - D("7.842")), [n(D("4.658")), D("8") - D("7.842"), D("12.5") - D("4.658") == D("7.842")])

# ---------------------------------------------------------------- S8
P("S8", "Use 8 + 7 to find 800 + 700.",
  ["8 + 7 = 15",
   "800 + 700 is 8 hundreds + 7 hundreds = 15 hundreds.",
   "15 hundreds = 1500"],
  n(800 + 700), [8 + 7, 800 + 700])
P("S8", "Use 15 − 8 to find 150 000 − 80 000.",
  ["15 − 8 = 7",
   "150 000 is 15 ten-thousands and 80 000 is 8 ten-thousands.",
   "15 ten-thousands − 8 ten-thousands = 7 ten-thousands = 70 000"],
  n(150000 - 80000), [15 - 8, n(70000)])
P("S8", "Add 9 + 6 + 4 + 1 by making tens.",
  ["Look for pairs that make 10: 9 + 1 = 10 and 6 + 4 = 10.",
   "10 + 10 = 20"],
  "20", [9 + 1, 6 + 4, 9 + 6 + 4 + 1])
P("S8", "Tom had 16 hockey cards and gave 7 away. How many cards does he have left?",
  ["16 − 7: take 6 to reach 10, then take 1 more.",
   "16 − 6 = 10, and 10 − 1 = 9",
   "Check: 9 + 7 = 16"],
  "9 cards", [16 - 6, 10 - 1, 9 + 7])

# ---------------------------------------------------------------- S9
P("S9", "Find 7 × 8.",
  ["Split 8 into 5 + 3.",
   "7 × 5 = 35 and 7 × 3 = 21",
   "35 + 21 = 56"],
  str(7 * 8), [35, 21, 56])
P("S9", "Find 63 ÷ 9.",
  ["Think: 9 times what number is 63?",
   "9 × 7 = 63",
   "So 63 ÷ 9 = 7"],
  str(63 // 9), [9 * 7, 63 % 9 == 0])
P("S9", "6 × □ = 54. Find the missing number.",
  ["Use the related division fact: □ = 54 ÷ 6.",
   "6 × 9 = 54, so 54 ÷ 6 = 9",
   "Check: 6 × 9 = 54"],
  str(54 // 6), [54 // 6, 6 * 9])
P("S9", "Use doubling and halving to find 4 × 15.",
  ["Halve the 4 to get 2, and double the 15 to get 30.",
   "2 × 30 = 60",
   "Check: 4 × 15 = 10 × 4 + 5 × 4 = 40 + 20 = 60"],
  str(4 * 15), [4 // 2, 15 * 2, 2 * 30, 40 + 20])
P("S9", "72 eggs are packed in cartons of 9. How many cartons are filled?",
  ["Divide: 72 ÷ 9.",
   "9 × 8 = 72",
   "72 ÷ 9 = 8 cartons"],
  "8 cartons", [72 // 9, 9 * 8])

# ---------------------------------------------------------------- S10
_t = [5 + 4 * i for i in range(7)]
P("S10", "Look at the pattern 5, 9, 13, 17. State the rule, then write the next three numbers.",
  ["Find the change: 9 − 5 = 4, 13 − 9 = 4, 17 − 13 = 4.",
   "Rule: start at 5 and add 4 each time (increasing pattern).",
   "17 + 4 = 21, 21 + 4 = 25, 25 + 4 = 29"],
  f"Add 4; next numbers {_t[4]}, {_t[5]}, {_t[6]}", [_t[4], _t[5], _t[6], 9 - 5])
P("S10", "A pattern table: term number 1, 2, 3, 4 gives values 7, 12, 17, 22. The rule is value = 5 × term number + 2. What is the value for term number 10?",
  ["Check the rule on term 1: 5 × 1 + 2 = 7. It matches.",
   "Term 10: 5 × 10 + 2",
   "= 50 + 2 = 52"],
  str(5 * 10 + 2), [5 * 1 + 2, [5 * k + 2 for k in range(1, 5)] == [7, 12, 17, 22], 5 * 10])
_s = [100 - 12 * i for i in range(7)]
P("S10", "A decreasing pattern starts 100, 88, 76, 64. What is the 7th number?",
  ["The change is 88 − 100 = −12, so subtract 12 each time.",
   "5th: 64 − 12 = 52, 6th: 52 − 12 = 40",
   "7th: 40 − 12 = 28"],
  str(_s[6]), [_s[4], _s[5], _s[6], 100 - 88])
P("S10", "A rule says: multiply the term number n by 3, then subtract 1. Write the rule with a letter, then find the value when n = 8.",
  ["Rule: value = 3 × n − 1",
   "Put in n = 8: 3 × 8 − 1",
   "= 24 − 1 = 23"],
  f"value = 3 × n − 1; for n = 8 the value is {3*8-1}", [3 * 8, 3 * 8 - 1])
P("S10", "Using value = 5 × n + 2, which term number n gives a value of 62?",
  ["We need 5 × n + 2 = 62.",
   "Undo the + 2: 62 − 2 = 60, so 5 × n = 60.",
   "n = 60 ÷ 5 = 12",
   "Check: 5 × 12 + 2 = 62"],
  str((62 - 2) // 5), [62 - 2, 60 // 5, 5 * 12 + 2])

# ---------------------------------------------------------------- S11
P("S11", "Solve x + 17 = 40.",
  ["Undo adding 17 by subtracting 17 from both sides.",
   "x = 40 − 17 = 23",
   "Check: 23 + 17 = 40"],
  f"x = {40-17}", [40 - 17, 23 + 17])
P("S11", "Solve 9 × n = 72.",
  ["Undo multiplying by 9 by dividing both sides by 9.",
   "n = 72 ÷ 9 = 8",
   "Check: 9 × 8 = 72"],
  f"n = {72//9}", [72 // 9, 9 * 8])
P("S11", "Solve y ÷ 6 = 12.",
  ["Undo dividing by 6 by multiplying both sides by 6.",
   "y = 12 × 6 = 72",
   "Check: 72 ÷ 6 = 12"],
  f"y = {12*6}", [12 * 6, 72 // 6])
P("S11", "Sam had some stickers. His friend gave him 24 more, and now he has 65. Write an equation using s, then solve it.",
  ["Equation: s + 24 = 65",
   "Subtract 24 from both sides: s = 65 − 24",
   "s = 41",
   "Check: 41 + 24 = 65"],
  f"s + 24 = 65, so s = {65-24}", [65 - 24, 41 + 24])
P("S11", "Solve 150 − k = 87.",
  ["k is the amount taken away. To find it, subtract the answer from 150.",
   "k = 150 − 87 = 63",
   "Check: 150 − 63 = 87"],
  f"k = {150-87}", [150 - 87, 150 - 63])

# ---------------------------------------------------------------- S12
P("S12", "A rectangle is 9 cm long and 6 cm wide. Find its area and its perimeter.",
  ["Area = length × width = 9 × 6 = 54 cm²",
   "Perimeter = 9 + 6 + 9 + 6 = 30 cm"],
  f"Area {9*6} cm², perimeter {2*(9+6)} cm", [9 * 6, 2 * (9 + 6)])
P("S12", "A square has sides of 8 m. Find its area and its perimeter.",
  ["Area = 8 × 8 = 64 m²",
   "Perimeter = 4 × 8 = 32 m"],
  f"Area {8*8} m², perimeter {4*8} m", [8 * 8, 4 * 8])
P("S12", "A rectangle has an area of 72 cm² and a length of 12 cm. What is its width?",
  ["Area = length × width, so 12 × □ = 72.",
   "□ = 72 ÷ 12 = 6",
   "Check: 12 × 6 = 72"],
  f"{72//12} cm", [72 // 12, 12 * 6])
P("S12", "A rectangle has a perimeter of 36 cm and a width of 7 cm. What is its length?",
  ["The two widths use 7 + 7 = 14 cm.",
   "The two lengths use 36 − 14 = 22 cm.",
   "One length = 22 ÷ 2 = 11 cm",
   "Check: 11 + 7 + 11 + 7 = 36"],
  f"{(36-14)//2} cm", [7 + 7, 36 - 14, 22 // 2, 11 + 7 + 11 + 7])
P("S12", "Garden A is 8 m by 3 m. Garden B is 6 m by 5 m. Which has the greater perimeter? Which has the greater area?",
  ["Garden A perimeter: 8 + 3 + 8 + 3 = 22 m. Garden B perimeter: 6 + 5 + 6 + 5 = 22 m.",
   "The perimeters are the same.",
   "Garden A area: 8 × 3 = 24 m². Garden B area: 6 × 5 = 30 m².",
   "Garden B has the greater area, by 30 − 24 = 6 m²."],
  "Same perimeter (22 m); Garden B has the greater area (30 m² vs 24 m²)",
  [2 * (8 + 3), 2 * (6 + 5), 8 * 3, 6 * 5, 30 - 24])
P("S12", "An L-shaped floor is made from a 10 m by 6 m rectangle with a 4 m by 3 m corner cut out. Find the area of the floor.",
  ["Area of the big rectangle: 10 × 6 = 60 m²",
   "Area of the cut-out corner: 4 × 3 = 12 m²",
   "Floor area = 60 − 12 = 48 m²"],
  f"{10*6-4*3} m²", [10 * 6, 4 * 3, 10 * 6 - 4 * 3])

# ---------------------------------------------------------------- S13
_a = datetime(2026, 1, 1, 14, 35)
_b = datetime(2026, 1, 1, 16, 10)
P("S13", "A class starts reading at 2:35 p.m. and stops at 4:10 p.m. How long did they read?",
  ["Count up to the next hour: 2:35 to 3:00 is 25 minutes.",
   "3:00 to 4:00 is 1 hour.",
   "4:00 to 4:10 is 10 minutes.",
   "25 + 10 = 35 minutes, plus 1 hour: 1 h 35 min."],
  f"{(_b-_a).seconds//3600} h {(_b-_a).seconds%3600//60} min", [25, 10, (_b - _a) == timedelta(hours=1, minutes=35)])
_s13 = datetime(2026, 1, 1, 18, 45) + timedelta(hours=2, minutes=20)
P("S13", "A movie starts at 6:45 p.m. and lasts 2 hours 20 minutes. When does it end?",
  ["Add the hours first: 6:45 p.m. + 2 h = 8:45 p.m.",
   "Add 20 minutes: 8:45 + 15 min = 9:00, then 5 more minutes = 9:05.",
   "The movie ends at 9:05 p.m."],
  clock(_s13), [clock(_s13), clock(datetime(2026, 1, 1, 20, 45))])
_d1 = datetime(2026, 1, 1, 11, 50)
_d2 = datetime(2026, 1, 1, 14, 25)
P("S13", "A bus leaves at 11:50 a.m. and arrives at 2:25 p.m. How long is the trip?",
  ["11:50 a.m. to 12:00 noon is 10 minutes.",
   "12:00 noon to 2:00 p.m. is 2 hours.",
   "2:00 p.m. to 2:25 p.m. is 25 minutes.",
   "10 + 25 = 35 minutes, so the trip is 2 h 35 min."],
  f"{(_d2-_d1).seconds//3600} h {(_d2-_d1).seconds%3600//60} min", [10, 25, (_d2 - _d1) == timedelta(hours=2, minutes=35)])
_end = datetime(2026, 1, 1, 17, 15)
_start = _end - timedelta(hours=3, minutes=40)
P("S13", "Dad finished baking at 5:15 p.m. The bread took 3 hours 40 minutes from start to finish. When did he start?",
  ["Work backwards. Subtract the hours first: 5:15 p.m. − 3 h = 2:15 p.m.",
   "Subtract 40 minutes: 2:15 − 15 min = 2:00, then 25 more minutes = 1:35.",
   "He started at 1:35 p.m."],
  clock(_start), [clock(_start), clock(datetime(2026, 1, 1, 14, 15))])
_day = (datetime(2026, 11, 9) - datetime(2026, 10, 28)).days
P("S13", "A science project is handed out on October 28 and is due on November 9. October has 31 days. How many days is that?",
  ["Days left in October after the 28th: 31 − 28 = 3 days.",
   "Then 9 days in November, up to the 9th.",
   "3 + 9 = 12 days"],
  f"{_day} days", [31 - 28, 3 + 9, _day])

# ---------------------------------------------------------------- S14
def faces_edges_verts(f, e, v):
    return f - e + v == 2  # Euler's check, V - E + F = 2


P("S14", "A rectangular prism is a box shape. How many faces, edges and vertices does it have?",
  ["Faces: top, bottom, front, back, left, right = 6.",
   "Edges: 4 on the top, 4 on the bottom, 4 going up = 12.",
   "Vertices (corners): 4 on the top + 4 on the bottom = 8."],
  "6 faces, 12 edges, 8 vertices", [faces_edges_verts(6, 12, 8), 4 + 4 + 4, 4 + 4])
P("S14", "How many faces, edges and vertices does a triangular prism have?",
  ["Faces: 2 triangle bases + 3 rectangle sides = 5.",
   "Edges: 3 on each base + 3 joining them = 9.",
   "Vertices: 3 on each base = 6."],
  "5 faces, 9 edges, 6 vertices", [faces_edges_verts(5, 9, 6), 2 + 3, 3 + 3 + 3, 3 + 3])
P("S14", "How many faces, edges and vertices does a square pyramid have?",
  ["Faces: 1 square base + 4 triangle sides = 5.",
   "Edges: 4 around the base + 4 going up to the tip = 8.",
   "Vertices: 4 corners of the base + 1 tip = 5."],
  "5 faces, 8 edges, 5 vertices", [faces_edges_verts(5, 8, 5), 1 + 4, 4 + 4, 4 + 1])
P("S14", "A prism has two bases that are hexagons (6 sides each). How many faces, edges and vertices does it have?",
  ["Faces: 2 hexagon bases + 6 rectangle sides = 8.",
   "Edges: 6 on each base + 6 joining them = 18.",
   "Vertices: 6 on each base = 12."],
  "8 faces, 18 edges, 12 vertices", [faces_edges_verts(8, 18, 12), 2 + 6, 6 + 6 + 6, 6 + 6])
P("S14", "A quadrilateral has exactly one pair of parallel sides. What is its name?",
  ["A quadrilateral has 4 sides.",
   "A parallelogram, rectangle, rhombus and square all have 2 pairs of parallel sides.",
   "A shape with exactly 1 pair of parallel sides is a trapezoid."],
  "A trapezoid", ["definition check (manual)"])

# ---------------------------------------------------------------- S15
P("S15", "Point A is at (1, 1) on a grid, where the first number is across and the second is up. Slide A 4 units right and 2 units up. Where does it land?",
  ["Right 4 changes the across number: 1 + 4 = 5.",
   "Up 2 changes the up number: 1 + 2 = 3.",
   "A lands at (5, 3)."],
  f"({1+4}, {1+2})", [1 + 4, 1 + 2])
P("S15", "Point B is at (2, 5). It is flipped (reflected) over the vertical line that goes through 4 on the across axis. Where does B land?",
  ["B is 4 − 2 = 2 units to the left of the line.",
   "Its image is the same distance on the other side: 2 units to the right of the line.",
   "4 + 2 = 6. The up number stays 5.",
   "B lands at (6, 5)."],
  f"({4+(4-2)}, 5)", [4 - 2, 4 + 2])
_dirs = ["up", "right", "down", "left"]
P("S15", "A flag points up. It is turned a quarter turn clockwise, three times in a row. Which way does it point at the end?",
  ["One quarter turn clockwise: up → right.",
   "Second quarter turn: right → down.",
   "Third quarter turn: down → left.",
   "It points left. (Three quarter turns is 270° clockwise.)"],
  _dirs[3 % 4], [_dirs[1], _dirs[2], _dirs[3], 3 * 90])
P("S15", "A triangle has corners at (6, 2), (8, 2) and (6, 5). After one transformation the corners are at (2, 2), (4, 2) and (2, 5). The triangle was not flipped or turned. Name the transformation and describe the move.",
  ["Compare each corner before and after: (6, 2) → (2, 2), (8, 2) → (4, 2), (6, 5) → (2, 5).",
   "The up numbers did not change. Each across number went down by 4: 6 − 2 = 4 and 8 − 4 = 4.",
   "The whole shape moved the same way with no flip or turn, so it is a slide (translation) 4 units left."],
  "A slide (translation) 4 units left", [6 - 2, 8 - 4])
P("S15", "Point C is at (1, 4). It is flipped over the horizontal line that goes through 2 on the up axis. Where does C land?",
  ["C is 4 − 2 = 2 units above the line.",
   "Its image is 2 units below the line: 2 − 2 = 0.",
   "The across number stays 1.",
   "C lands at (1, 0)."],
  f"(1, {2-(4-2)})", [4 - 2, 2 - 2])

# ---------------------------------------------------------------- S16
P("S16", "In a bar graph, each square on the bar stands for 5 students. The bar for \"Soccer\" is 7 squares tall. How many students chose soccer?",
  ["Each square is worth 5 students.",
   "7 squares × 5 = 35",
   "35 students chose soccer."],
  f"{7*5} students", [7 * 5])
P("S16", "A double bar graph shows favourite fruit. Apples: Grade 4 bar is 30, Grade 5 bar is 45. How many more Grade 5 students chose apples than Grade 4 students?",
  ["Read both bars: Grade 5 is 45 and Grade 4 is 30.",
   "Subtract: 45 − 30 = 15"],
  f"{45-30} more students", [45 - 30])
P("S16", "In a bar graph, each square stands for 10 people. The bar for Saturday at the park is 4 squares tall and the bar for Sunday is 6 squares tall. How many people came in all?",
  ["Saturday: 4 × 10 = 40 people.",
   "Sunday: 6 × 10 = 60 people.",
   "Total: 40 + 60 = 100 people."],
  f"{4*10+6*10} people", [4 * 10, 6 * 10, 4 * 10 + 6 * 10])
_sport = {"Soccer": (25, 40), "Hockey": (35, 30), "Swimming": (20, 45)}
_diffs = {k: abs(a - b) for k, (a, b) in _sport.items()}
_big = max(_diffs, key=_diffs.get)
P("S16", "A double bar graph compares Grade 4 and Grade 5 favourite sports. Soccer: 25 and 40. Hockey: 35 and 30. Swimming: 20 and 45. Which sport has the biggest difference between the two grades, and what is it?",
  ["Soccer: 40 − 25 = 15",
   "Hockey: 35 − 30 = 5",
   "Swimming: 45 − 20 = 25",
   "The biggest difference is swimming, 25."],
  f"{_big}, {_diffs[_big]}", [_diffs["Soccer"], _diffs["Hockey"], _diffs["Swimming"]])
P("S16", "In a pictograph one star stands for 4 books. Ella's row has 9 stars. Zoe read 52 books. How many more stars does Zoe's row need than Ella's row?",
  ["One star stands for 4 books.",
   "Zoe's stars: 52 ÷ 4 = 13",
   "Ella has 9 stars, so Zoe needs 13 − 9 = 4 more.",
   "Check: 13 × 4 = 52"],
  f"{52//4 - 9} more stars", [52 // 4, 13 - 9, 13 * 4])

# ---------------------------------------------------------------- S17
P("S17", "A spinner has 8 equal sections. 3 are red, 2 are blue and 3 are green. What is the probability of landing on red?",
  ["Probability = favourable outcomes ÷ total outcomes.",
   "3 sections are red out of 8 sections.",
   "Probability of red = 3/8"],
  "3/8", [F(3, 8), 3 + 2 + 3])
P("S17", "You roll one fair six-sided die. What is the probability of rolling an even number?",
  ["Even numbers on the die: 2, 4, 6. That is 3 outcomes.",
   "There are 6 outcomes in all.",
   "Probability of an even number = 3/6 = 1/2"],
  n(F(3, 6)), [len([k for k in range(1, 7) if k % 2 == 0]), F(3, 6)])
P("S17", "A bag has 4 red, 5 blue and 3 green marbles. You pick one without looking. What is the probability it is blue?",
  ["Total marbles: 4 + 5 + 3 = 12.",
   "Blue marbles: 5.",
   "Probability of blue = 5/12"],
  "5/12", [4 + 5 + 3, F(5, 12)])
P("S17", "A bag has 4 red, 5 blue and 3 green marbles. You pick one without looking. What is the probability the marble is NOT green?",
  ["Marbles that are not green: 4 + 5 = 9, out of 12 in all.",
   "Probability of not green = 9/12",
   "Simplify: divide top and bottom by 3 to get 3/4.",
   "Check: probability of green = 3/12 = 1/4, and 1/4 + 3/4 = 1."],
  n(F(9, 12)), [4 + 5, F(9, 12), F(3, 12) + F(9, 12) == 1])
P("S17", "A spinner has 10 equal sections. You want the probability of landing on yellow to be 1/5. How many sections should be yellow?",
  ["1/5 as tenths: multiply top and bottom by 2 to get 2/10.",
   "So 2 out of the 10 sections should be yellow.",
   "Check: 2/10 = 1/5"],
  "2 sections", [F(1, 5) == F(2, 10), 10 // 5])

# ---------------------------------------------------------------- S18
P("S18", "A book costs $37.85. You pay with a $50 bill. How much change do you get?",
  ["Count up from $37.85 to $38: 15 cents.",
   "$38 to $50: $12.",
   "$12 + $0.15 = $12.15"],
  money(D(50) - D("37.85")), [D(38) - D("37.85"), 50 - 38, money(D("12.15"))])
P("S18", "One notebook costs $12.49. What do 3 notebooks cost?",
  ["Think of $12.49 as $12 + $0.49.",
   "3 × $12 = $36",
   "3 × $0.49 = $1.47",
   "$36 + $1.47 = $37.47"],
  money(D("12.49") * 3), [36, D("0.49") * 3, money(D("37.47"))])
P("S18", "Ava wants a $240 bike. She has saved $75 and will save $15 each week. How many weeks until she can buy it?",
  ["Amount still needed: $240 − $75 = $165.",
   "Weeks: $165 ÷ $15 = 11.",
   "Check: 11 × $15 = $165, and $75 + $165 = $240."],
  f"{(240-75)//15} weeks", [240 - 75, 165 // 15, 11 * 15, 165 % 15 == 0])
P("S18", "Ben gets $120 this month. His expenses are $45.50, $28.75 and $19.00. Make a budget: how much are his total expenses, and how much money is left?",
  ["Total expenses: $45.50 + $28.75 + $19.00.",
   "$45.50 + $28.75 = $74.25",
   "$74.25 + $19.00 = $93.25",
   "Money left: $120.00 − $93.25 = $26.75"],
  f"Expenses {money(D('45.50')+D('28.75')+D('19.00'))}, left {money(D(120)-(D('45.50')+D('28.75')+D('19.00')))}",
  [money(D("93.25")), money(D("74.25")), money(D("26.75"))])
P("S18", "Lena buys a snack for $4.75 and a juice for $2.60. She pays with a $10 bill. How much change does she get?",
  ["Total cost: $4.75 + $2.60 = $7.35",
   "Count up from $7.35 to $8: 65 cents.",
   "$8 to $10: $2.",
   "$2 + $0.65 = $2.65"],
  money(D(10) - D("7.35")), [money(D("7.35")), D(8) - D("7.35"), 10 - 8, money(D("2.65"))])


# ---------------------------------------------------------------- build / verify
def build():
    out, ids = [], {}
    c = count(1)
    for std, prompt, parts, steps, answer, _ in PROBLEMS:
        pid = f"m5-{next(c):02d}"
        ids.setdefault(std, []).append(pid)
        text = parts or [{"text": prompt}]
        out.append({
            "id": pid,
            "source": f"BC Math 5 content standard: {STD[std]}; original",
            "prompt_latex": "\\text{" + prompt.replace("$", "\\$") + "}" if not parts else "",
            "prompt_plain": prompt,
            "prompt_parts": text,
            "worked_solution": steps,
            "final_answer": answer,
            "level": "elementary",
        })
    return out, ids


def fix_parts(items):
    # fraction-prompt problems: derive latex/plain from parts
    for it in items:
        if not it["prompt_latex"]:
            lat, pl = [], []
            for p in it["prompt_parts"]:
                if "text" in p:
                    lat.append(p["text"]); pl.append(p["text"])
                else:
                    a, b = p["frac"]["num"], p["frac"]["den"]
                    lat.append(f"\\dfrac{{{a}}}{{{b}}}"); pl.append(f"{a}/{b}")
            it["prompt_latex"] = "".join(lat)
            it["prompt_plain"] = "".join(pl)
    return items


def verify():
    expected, ids = build()
    expected = fix_parts(expected)
    for it in expected:  # parts-based plain prompt differs from the raw prompt string; fine
        pass
    on_disk = json.loads(OUT.read_text(encoding="utf-8"))
    failures = []
    if on_disk != expected:
        failures.append("problems.json differs from the source in verify.py (run --write)")
    mech = manual = 0
    for it, (std, prompt, parts, steps, answer, checks) in zip(on_disk, PROBLEMS):
        blob = " ".join(it["worked_solution"]) + " " + it["final_answer"]
        norm = blob.replace(" ", "").replace(" ", "")
        bad = []
        for chk in checks:
            if chk is True:
                continue
            if chk is False:
                bad.append("a Python identity was False")
            elif isinstance(chk, str) and chk.startswith("definition check"):
                continue
            elif isinstance(chk, (int, str, F, D)):
                key = n(chk) if not isinstance(chk, str) else chk
                if key.replace(" ", "") not in norm:
                    bad.append(f"expected {key!r} not found in solution")
            elif isinstance(chk, (D,)):
                pass
        if checks and isinstance(checks[0], str) and checks[0].startswith("definition check"):
            manual += 1
        else:
            mech += 1
        if len(it["worked_solution"]) < 2 or len(it["worked_solution"]) > 14:
            bad.append("worked_solution length out of range")
        if it["level"] != "elementary":
            bad.append("level")
        if bad:
            failures.append(f"{it['id']}: " + "; ".join(bad))
    total = len(on_disk)
    print(f"problems: {total}  mechanically verified: {mech}  definition-only (manual): {manual}  failures: {len(failures)}")
    for f in failures:
        print("FAIL", f)
    return 1 if failures else 0


if __name__ == "__main__":
    if "--write" in sys.argv:
        items, ids = build()
        items = fix_parts(items)
        OUT.write_text(json.dumps(items, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {len(items)} problems")
        for s, v in ids.items():
            print(s, v[0], "-", v[-1])
        sys.exit(0)
    sys.exit(verify())
