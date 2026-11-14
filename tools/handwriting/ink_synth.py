"""Turn lines of math text into pen strokes that look handwritten.

Pipeline: text -> token tree (fractions, exponents, roots, matrices) -> boxes of single-stroke Hershey polylines
-> per-glyph handwriting variation (slant, jitter, bowing, size, baseline drift) -> resampled points with pen speed,
pauses and pressure.

The single-stroke font is the Hershey set (Roman Simplex for letters, digits and punctuation; the math set for the
symbols). Licence: see HERSHEY-LICENSE.txt in this folder. Standard library only.

Coordinates leave this module in "page points from the top-left of the first screen": x right, y down, as the app's
canvas uses them. Time is seconds from the start of the script.
"""
from __future__ import annotations

import json
import math
import os
import random
import re
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))
_GLYPHS: dict[int, dict] | None = None


def glyphs() -> dict[int, dict]:
    global _GLYPHS
    if _GLYPHS is None:
        with open(os.path.join(HERE, "data", "hershey-occidental.json"), encoding="utf-8") as handle:
            _GLYPHS = {g["charcode"]: g for g in json.load(handle)}
    return _GLYPHS


# ---------------------------------------------------------------------------------------------- the character table
CAP_UNITS = 21.0   # Hershey capital height (y from -12 to 9); the baseline is y = 9
BASE_Y = 9.0

CHAR_TO_GLYPH: dict[str, int] = {}
for _i, _c in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):
    CHAR_TO_GLYPH[_c] = 501 + _i
for _i, _c in enumerate("abcdefghijklmnopqrstuvwxyz"):
    CHAR_TO_GLYPH[_c] = 601 + _i
for _i, _c in enumerate("0123456789"):
    CHAR_TO_GLYPH[_c] = 700 + _i
CHAR_TO_GLYPH.update({
    ".": 710, ",": 711, ":": 712, ";": 713, "!": 714, "?": 715, "'": 716, "′": 716, '"': 717, "°": 718,
    "$": 719, "/": 720, "[": 2223, "]": 2224, "{": 2225, "}": 2226, "(": 721, ")": 722, "|": 723, "-": 724, "−": 724, "–": 724, "+": 725, "=": 726,
    "×": 2235, "*": 728, "·": 2236, "÷": 2237, "±": 2233, "∓": 2234, "≠": 2239,
    "<": 2241, ">": 2242, "≤": 2243, "≥": 2244, "∞": 2270, "→": 2261, "↑": 2262,
    "←": 2263, "∫": 2268, "∂": 2265, "∈": 2260, "%": 2271, "≈": 2246, "~": 2246,
    "α": 627, "β": 628, "γ": 629, "δ": 630, "ε": 631, "θ": 634, "λ": 637,
    "μ": 638, "π": 642, "ρ": 643, "σ": 644, "τ": 645, "φ": 647, "ω": 650,
    "Δ": 530, "Σ": 544, "Ω": 550, "Π": 542,
})
SUPERSCRIPTS = {"²": "2", "³": "3", "¹": "1", "⁰": "0", "⁴": "4", "⁵": "5", "⁶": "6",
                "⁷": "7", "⁸": "8", "⁹": "9", "ⁿ": "n", "⁻": "-", "⁺": "+"}
SUBSCRIPTS = {"₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6",
              "₇": "7", "₈": "8", "₉": "9"}
SPACE_UNITS = 11.0


class Unsupported(Exception):
    """The text has a character the synthesizer cannot draw. The caller picks a different problem."""


# -------------------------------------------------------------------------------------------------- boxes and units
Poly = list  # list of (x, y)


@dataclass
class Box:
    """Units in writing order; each unit is one glyph (or bar, radical, bracket) made of 1+ polylines. y is up-negative,
    baseline at 0. `w` is the advance width."""
    units: list = field(default_factory=list)   # list[list[Poly]]
    w: float = 0.0

    def extent(self):
        ys = [p[1] for unit in self.units for poly in unit for p in poly]
        xs = [p[0] for unit in self.units for poly in unit for p in poly]
        if not ys:
            return 0.0, 0.0, 0.0, 0.0
        return min(xs), max(xs), -min(ys), max(ys)   # x0, x1, ascent (positive up), descent (positive down)

    @property
    def asc(self):
        return max(self.extent()[2], 0.0)

    @property
    def desc(self):
        return max(self.extent()[3], 0.0)

    def shifted(self, dx, dy) -> "Box":
        units = [[[(x + dx, y + dy) for x, y in poly] for poly in unit] for unit in self.units]
        return Box(units, self.w)


def _glyph_unit(char: str, scale: float):
    code = CHAR_TO_GLYPH.get(char)
    if code is None:
        raise Unsupported(char)
    g = glyphs().get(code)
    if g is None:
        raise Unsupported(char)
    polys = [[((x - g["left"]) * scale, (y - BASE_Y) * scale) for x, y in line] for line in g["lines"] if len(line) > 1]
    return polys, (g["right"] - g["left"]) * scale


def _glyph_box(char: str, scale: float) -> Box:
    if char == " ":
        return Box([], SPACE_UNITS * scale)
    polys, width = _glyph_unit(char, scale)
    return Box([polys] if polys else [], width)


# ------------------------------------------------------------------------------------------------ the token tree
@dataclass
class Tok:
    kind: str                      # char | sup | sub | group | sqrt | matrix | frac
    ch: str = ""
    kids: list = field(default_factory=list)   # for group / sup / sub / sqrt / frac(num, den as 2 lists)
    paren: bool = False
    rows: list = field(default_factory=list)   # matrix: list of rows; row: list of cells (token lists), 'aug' index
    aug: int = -1


def _match(text: str, start: int, open_ch: str, close_ch: str) -> int:
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i
    return -1


def tokenize(text: str) -> list:
    out: list = []
    i = 0
    while i < len(text):
        c = text[i]
        if c in SUPERSCRIPTS:
            j = i
            chars = []
            while j < len(text) and text[j] in SUPERSCRIPTS:
                chars.append(SUPERSCRIPTS[text[j]])
                j += 1
            out.append(Tok("sup", kids=[Tok("char", ch=x) for x in chars]))
            i = j
        elif c in SUBSCRIPTS:
            j = i
            chars = []
            while j < len(text) and text[j] in SUBSCRIPTS:
                chars.append(SUBSCRIPTS[text[j]])
                j += 1
            out.append(Tok("sub", kids=[Tok("char", ch=x) for x in chars]))
            i = j
        elif c == "^" and i + 1 < len(text):
            if text[i + 1] in "{(":
                close = "}" if text[i + 1] == "{" else ")"
                end = _match(text, i + 1, text[i + 1], close)
                end = end if end > 0 else len(text) - 1
                out.append(Tok("sup", kids=tokenize(text[i + 2:end])))
                i = end + 1
            else:
                j = i + 1
                if text[j] in "-−":
                    j += 1
                while j < len(text) and (text[j].isalnum()):
                    j += 1
                    break
                out.append(Tok("sup", kids=tokenize(text[i + 1:j])))
                i = j
        elif c == "_" and i + 1 < len(text):
            j = i + 1
            while j < len(text) and text[j].isalnum():
                j += 1
                break
            out.append(Tok("sub", kids=tokenize(text[i + 1:j])))
            i = j
        elif c == "√":
            if i + 1 < len(text) and text[i + 1] == "(":
                end = _match(text, i + 1, "(", ")")
                end = end if end > 0 else len(text) - 1
                out.append(Tok("sqrt", kids=tokenize(text[i + 2:end])))
                i = end + 1
            else:
                j = i + 1
                while j < len(text) and (text[j].isalnum() or text[j] in SUPERSCRIPTS):
                    j += 1
                out.append(Tok("sqrt", kids=tokenize(text[i + 1:j])))
                i = j
        elif c == "[":
            end = _match(text, i, "[", "]")
            inner = text[i + 1:end] if end > 0 else ""
            if end > 0 and (";" in inner or "|" in inner) and re.search(r"\d", inner):
                rows, aug = [], -1
                for raw_row in inner.split(";"):
                    cells = []
                    if "|" in raw_row:
                        left, right = raw_row.split("|", 1)
                        aug = len(left.split())
                        parts = left.split() + right.split()
                    else:
                        parts = raw_row.split()
                    for part in parts:
                        cells.append(tokenize(part))
                    rows.append(cells)
                out.append(Tok("matrix", rows=rows, aug=aug))
                i = end + 1
            else:
                out.append(Tok("char", ch="["))
                i += 1
        elif c == "(":
            end = _match(text, i, "(", ")")
            if end < 0:
                out.append(Tok("char", ch="("))
                i += 1
            else:
                out.append(Tok("group", kids=tokenize(text[i + 1:end]), paren=True))
                i = end + 1
        else:
            out.append(Tok("char", ch=c))
            i += 1
    return _fractions(out)


def _is_atom_char(t: Tok) -> bool:
    return t.kind in ("char", "sup", "sub", "sqrt") and (t.kind != "char" or t.ch.isalnum() or t.ch == ".")


def _fractions(toks: list) -> list:
    """a/b becomes a stacked fraction when both sides are a bracketed group or a plain alphanumeric run."""
    out: list = []
    i = 0
    while i < len(toks):
        t = toks[i]
        if t.kind == "char" and t.ch == "/" and out and i + 1 < len(toks):
            # numerator: the group just written, or the run of alphanumerics just written
            num: list | None = None
            popped: list = []
            if out[-1].kind == "group" and out[-1].paren and not (len(out) >= 2 and _is_atom_char(out[-2]) and out[-2].kind == "char"):
                group = out.pop()
                popped = [group]
                num = group.kids
            elif _is_atom_char(out[-1]):
                run = []
                while out and _is_atom_char(out[-1]):
                    run.insert(0, out.pop())
                popped = list(run)
                num = run
            # denominator: the group after, or the run of alphanumerics after
            den: list | None = None
            j = i + 1
            if num is not None:
                if toks[j].kind == "group" and toks[j].paren:
                    den = toks[j].kids
                    j += 1
                elif _is_atom_char(toks[j]):
                    run = []
                    while j < len(toks) and _is_atom_char(toks[j]):
                        run.append(toks[j])
                        j += 1
                    den = run
            if num is not None and den is not None:
                out.append(Tok("frac", kids=[num, den]))
                i = j
                continue
            out.extend(popped)       # could not pair: put the numerator back untouched
        out.append(t)
        i += 1
    return out


# --------------------------------------------------------------------------------------------------------- layout
class Layout:
    def __init__(self, cap_pt: float):
        self.s = cap_pt / CAP_UNITS     # points per Hershey unit at size 1.0
        self.cap = cap_pt

    def row(self, toks: list, size: float = 1.0) -> Box:
        box = Box([], 0.0)
        x = 0.0
        for index, t in enumerate(toks):
            piece = self.token(t, size, toks, index, x)
            box.units.extend(piece.shifted(x, 0.0).units)
            x += piece.w
        box.w = x
        return box

    def token(self, t: Tok, size: float, siblings: list, index: int, x: float) -> Box:
        s = self.s * size
        if t.kind == "char":
            return _glyph_box(t.ch, s)
        if t.kind == "sup":
            inner = self.row(t.kids, size * 0.62)
            return _raise(inner, 0.5, -0.62 * self.cap * size)
        if t.kind == "sub":
            inner = self.row(t.kids, size * 0.62)
            return _raise(inner, 0.5, 0.22 * self.cap * size)
        if t.kind == "group":
            inner = self.row(t.kids, size)
            return self._parens(inner, size)
        if t.kind == "frac":
            return self._frac(t, size)
        if t.kind == "sqrt":
            return self._sqrt(t, size)
        if t.kind == "matrix":
            return self._matrix(t, size)
        raise Unsupported(t.kind)

    def _parens(self, inner: Box, size: float) -> Box:
        s = self.s * size
        tall = inner.asc + inner.desc > 1.45 * self.cap * size
        if not tall:
            left, lw = _glyph_unit("(", s)
            right, rw = _glyph_unit(")", s)
            box = Box([left], lw)
            body = inner.shifted(lw, 0.0)
            box.units.extend(body.units)
            right_box = Box([right], rw).shifted(lw + inner.w, 0.0)
            box.units.extend(right_box.units)
            box.w = lw + inner.w + rw
            return box
        top, bottom = -(inner.asc + 3), inner.desc + 3
        height = bottom - top
        pad = 5.5 * size
        bulge = height * 0.06
        left = [(pad - bulge * math.sin(math.pi * k / 10), top + height * k / 10) for k in range(11)]
        right = [(pad * 3 + inner.w + bulge * math.sin(math.pi * k / 10), top + height * k / 10) for k in range(11)]
        box = Box([[left]], 0.0)
        box.units.extend(inner.shifted(pad * 2, 0.0).units)
        box.units.append([right])
        box.w = inner.w + pad * 4
        return box

    def _frac(self, t: Tok, size: float) -> Box:
        fs = size * 0.82
        num = self.row(t.kids[0], fs)
        den = self.row(t.kids[1], fs)
        width = max(num.w, den.w) + 8 * self.s * size
        axis = 0.36 * self.cap * size          # the bar sits at the height of the minus sign
        gap = 4.0 * size
        box = Box([], width)
        num_y = -(axis + gap + num.desc)
        den_y = -axis + gap + den.asc
        box.units.extend(num.shifted((width - num.w) / 2, num_y).units)
        box.units.append([[(2.0, -axis), (width - 2.0, -axis)]])
        box.units.extend(den.shifted((width - den.w) / 2, den_y).units)
        return box

    def _sqrt(self, t: Tok, size: float) -> Box:
        inner = self.row(t.kids, size)
        top = -(max(inner.asc, 0.8 * self.cap * size) + 4)
        bottom = max(inner.desc, 0.0) + 2
        k = size * (self.cap / 26)
        width_sign = 14.0 * k
        bar = [(0.0, -0.30 * self.cap * size), (3.2 * k, -0.38 * self.cap * size), (9.7 * k, bottom),
               (width_sign, top), (width_sign + inner.w + 4, top)]
        box = Box([[bar]], 0.0)
        box.units.extend(inner.shifted(width_sign + 2, 0.0).units)
        box.w = width_sign + inner.w + 6
        return box

    def _matrix(self, t: Tok, size: float) -> Box:
        cells = [[self.row(cell, size) for cell in row] for row in t.rows]
        columns = max(len(r) for r in cells)
        col_w = [max((r[c].w for r in cells if c < len(r)), default=0.0) for c in range(columns)]
        gap = 16.0 * size
        pitch = 1.65 * self.cap * size
        rows = len(cells)
        height = pitch * (rows - 1) + self.cap * size
        axis = 0.36 * self.cap * size
        top = -axis - height / 2 - 4
        bottom = -axis + height / 2 + 4
        left_pad = 10.0
        box = Box([], 0.0)
        # left bracket
        box.units.append([[(left_pad - 1, top), (2, top), (2, bottom), (left_pad - 1, bottom)]])
        x_cols, x = [], left_pad + 6
        for c in range(columns):
            x_cols.append(x)
            x += col_w[c] + gap
        for r, row in enumerate(cells):
            baseline = (-axis - height / 2) + self.cap * size + r * pitch
            for c, cell in enumerate(row):
                box.units.extend(cell.shifted(x_cols[c] + (col_w[c] - cell.w) / 2, baseline).units)
        right_x = x - gap + 10
        if t.aug >= 1 and t.aug < columns:
            bar_x = x_cols[t.aug] - gap / 2
            box.units.append([[(bar_x, top + 2), (bar_x, bottom - 2)]])
        box.units.append([[(right_x - 9, top), (right_x, top), (right_x, bottom), (right_x - 9, bottom)]])
        box.w = right_x + 6
        return box


def _raise(inner: Box, dx: float, dy: float) -> Box:
    moved = inner.shifted(dx, dy)
    moved.w = inner.w + dx + 1.0
    return moved


def layout_text(text: str, cap_pt: float) -> Box:
    return Layout(cap_pt).row(tokenize(text))


def count_visual_rows(text: str) -> int:
    """How many lines of ink a text makes when written: a matrix is one row of ink per matrix row."""
    best = 1
    for t in tokenize(text):
        if t.kind == "matrix":
            best = max(best, len(t.rows))
    return best


# --------------------------------------------------------------------------------------- handwriting + timing
@dataclass
class Writer:
    """One imaginary student. Same seed, same hand."""
    seed: int
    slant: float = 0.0
    size: float = 1.0
    jitter: float = 1.0
    speed: float = 260.0        # points per second along a stroke
    think: float = 1.0          # multiplier on the pause between lines

    @classmethod
    def make(cls, seed: int, speed: float | None = None, think: float = 1.0) -> "Writer":
        rng = random.Random(seed * 7919 + 13)
        return cls(seed=seed, slant=rng.gauss(0.13, 0.05), size=rng.uniform(0.94, 1.08), jitter=rng.uniform(0.8, 1.25),
                   speed=speed or rng.uniform(210, 330), think=think)


def _resample(poly: list, spacing: float) -> list:
    if len(poly) < 2:
        return list(poly)
    out = [poly[0]]
    carry = 0.0
    for a, b in zip(poly, poly[1:]):
        seg = math.dist(a, b)
        if seg == 0:
            continue
        d = spacing - carry
        while d <= seg:
            f = d / seg
            out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
            d += spacing
        carry = seg - (d - spacing)
    if math.dist(out[-1], poly[-1]) > 0.4:
        out.append(poly[-1])
    return out


def _smooth(points: list, passes: int = 1) -> list:
    """Chaikin-free light smoothing: three-point average, ends fixed. Rounds the Hershey corners a little."""
    pts = list(points)
    for _ in range(passes):
        if len(pts) < 3:
            return pts
        pts = [pts[0]] + [((a[0] + 2 * b[0] + c[0]) / 4, (a[1] + 2 * b[1] + c[1]) / 4)
                          for a, b, c in zip(pts, pts[1:], pts[2:])] + [pts[-1]]
    return pts


def _unit_centre(unit: list):
    xs = [p[0] for poly in unit for p in poly]
    ys = [p[1] for poly in unit for p in poly]
    return (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2


def write_line(box: Box, origin: tuple, writer: Writer, rng: random.Random, t0: float, tilt: float) -> tuple:
    """Draws one laid-out line starting at `origin` (page x, baseline y). Returns (strokes, t_end, bbox).
    A stroke is a list of [x, y, t, force]."""
    strokes = []
    t = t0
    ox, oy = origin
    drift_phase = rng.uniform(0, 6.28)
    drift_amp = rng.uniform(0.6, 2.2) * writer.jitter
    prev_right = None
    bbox = [1e9, 1e9, -1e9, -1e9]
    for unit_index, unit in enumerate(box.units):
        cx, cy = _unit_centre(unit)
        rot = rng.gauss(0, 0.035 * writer.jitter)
        sc = rng.uniform(0.93, 1.07) * writer.size
        dx = rng.gauss(0, 1.3 * writer.jitter)
        dy = rng.gauss(0, 1.1 * writer.jitter)
        # pause before this unit: more between glyphs than between the strokes of one glyph (units are glyphs)
        left = min(p[0] for poly in unit for p in poly)
        if prev_right is None:
            t += 0.0
        else:
            gap = left - prev_right
            t += rng.uniform(0.07, 0.16) if gap < 4 else rng.uniform(0.16, 0.42)
        right_edge = prev_right
        for poly_index, poly in enumerate(unit):
            if poly_index > 0:
                t += rng.uniform(0.05, 0.13)        # pen up between the strokes of one glyph
            pts = []
            bow = rng.gauss(0, 0.9 * writer.jitter)
            sa = rng.gauss(0, 0.16)
            for k, (x, y) in enumerate(poly):
                # scale + rotate about the glyph centre, then slant, then drift
                px, py = (x - cx) * sc, (y - cy) * sc
                rx = px * math.cos(rot) - py * math.sin(rot) + cx
                ry = px * math.sin(rot) + py * math.cos(rot) + cy
                pts.append((rx + dx - ry * (writer.slant + sa * 0.0), ry + dy))
            pts = _resample(pts, 2.6)
            if len(pts) < 2:
                continue
            n = len(pts)
            # bowing: a gentle sideways bulge along the stroke, plus slow correlated wobble
            out = []
            wob_phase = rng.uniform(0, 6.28)
            for k, (x, y) in enumerate(pts):
                u = k / (n - 1)
                bump = bow * math.sin(math.pi * u)
                wob = 0.35 * writer.jitter * math.sin(k * 0.9 + wob_phase)
                gx = ox + x + bump * 0.6 + wob
                gy = oy + y + bump * 0.8 + wob * 0.7 + tilt * x + drift_amp * math.sin((x + ox) / 170.0 + drift_phase)
                out.append((gx, gy))
            out = _smooth(out, 1)
            speed = max(90.0, rng.gauss(writer.speed, 45.0))
            stroke = []
            for k, (gx, gy) in enumerate(out):
                u = k / (len(out) - 1)
                if k > 0:
                    ds = math.dist(out[k - 1], out[k])
                    local = speed * (0.4 + 0.75 * math.sin(math.pi * u) ** 0.7)
                    t += ds / local
                force = 0.18 + 0.62 * math.sin(math.pi * u) ** 0.55 + rng.gauss(0, 0.04)
                force = min(1.0, max(0.08, force * (0.9 + 0.2 * writer.jitter / 1.25)))
                stroke.append([round(gx, 2), round(gy, 2), round(t, 4), round(force, 3)])
                bbox[0], bbox[1] = min(bbox[0], gx), min(bbox[1], gy)
                bbox[2], bbox[3] = max(bbox[2], gx), max(bbox[3], gy)
            strokes.append(stroke)
        prev_right = max(p[0] for poly in unit for p in poly)
    return strokes, t, bbox
