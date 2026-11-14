#!/usr/bin/env python3
"""Build the eval pages: 30 synthetic "handwritten" BC Math 9 pages with known answers.

Not real handwriting. Pages are drawn with handwriting-style fonts with per-glyph size, baseline, rotation and spacing
jitter, a per-page slant, uneven line spacing and the odd stray mark. The glyph jitter and fraction drawing are adapted from
tutor-timing-test/endpoint/make_set.py (the 2026-11-13 messy-page set); this version matches what the app sends instead:

  * PNG, white background, 1024 x 544 (the size real iPad looks used: device logs show image_px 1024x544)
  * faint grey line numbers in the left margin, as PageSnapshotter draws them
  * `lines` boxes computed from the ink, in image pixels

Three kinds of page, each with a known truth:
  correct_finished    every line right, solved to the end                        -> the tutor should wait
  correct_unfinished  every line written so far is right, the work stops midway   -> the tutor should wait
                      (some end in a half-written line)
  wrong               the first wrong line is known (sign, distribution, combining like terms, one side only,
                      moving a term); later lines follow from the mistake        -> interrupt on exactly that line

Needs Pillow and macOS system fonts. Deterministic (fixed seeds).
Run: python3 server/eval/make_fixtures.py   (writes server/eval/fixtures/*.png and fixtures/manifest.json)
"""
import io
import json
import math
import os
import random
import re

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")
W, H = 1024, 544
BG = (255, 255, 255)
FONTS = {
    "bradley": ("/System/Library/Fonts/Supplemental/Bradley Hand Bold.ttf", 0, 46),
    "noteworthy": ("/System/Library/Fonts/Noteworthy.ttc", 1, 42),
    "chalkboard": ("/System/Library/Fonts/Supplemental/ChalkboardSE.ttc", 0, 40),
    "marker": ("/System/Library/Fonts/MarkerFelt.ttc", 0, 40),
}
INKS = [(20, 24, 40), (30, 30, 36), (22, 34, 76), (44, 40, 52)]  # dark pencil / pen colours on white
NUM_FONT = "/System/Library/Fonts/Helvetica.ttc"

# ---------------------------------------------------------------- the pages
# "{n/d}" is a stacked fraction. Line 1 is the student copying the problem.
# Each entry: (id, problem_id, category, error_type, rows, wrong_line, half) ; half = cut the LAST row after this fraction
CLEAN = {
    "u3-01": ["7x – 4 = 3x + 16", "7x – 3x – 4 = 16", "4x – 4 = 16", "4x = 16 + 4", "4x = 20", "x = 5"],
    "u3-04": ["–4(2p + 5) = 12", "–8p – 20 = 12", "–8p = 12 + 20", "–8p = 32", "p = –4"],
    "u3-05": ["–(y – 6) = 10", "–y + 6 = 10", "–y = 4", "y = –4"],
    "u3-06": ["{a/3} + {a/4} = 14", "LCD = 12", "12·{a/3} + 12·{a/4} = 12·14", "4a + 3a = 168", "7a = 168", "a = 24"],
    "u3-07": ["{2k/5} – 3 = 1", "all ·5:  2k – 15 = 5", "2k = 20", "k = 10"],
    "u3-10": ["8 – 3(x + 2) = 5", "8 – 3x – 6 = 5", "2 – 3x = 5", "–3x = 3", "x = –1"],
    "u3-11": ["6(x – 2) – 4(x + 1) = 10", "6x – 12 – 4x – 4 = 10", "2x – 16 = 10", "2x = 26", "x = 13"],
    "u3-12": ["3(2r + 5) = –(r – 6) + 23", "6r + 15 = –r + 6 + 23", "6r + 15 = –r + 29", "6r + r = 29 – 15", "7r = 14", "r = 2"],
    "u3-13": ["{x + 4/3} = {x – 2/2}", "2(x + 4) = 3(x – 2)", "2x + 8 = 3x – 6", "8 + 6 = 3x – 2x", "14 = x"],
    "u3-15": ["{2/3}(x – 1) = {1/2}(x + 3)", "4(x – 1) = 3(x + 3)", "4x – 4 = 3x + 9", "4x – 3x = 9 + 4", "x = 13"],
    "u3-19": ["{5/6}v + 2 = {1/3}v + 7", "5v + 12 = 2v + 42", "5v – 2v = 42 – 12", "3v = 30", "v = 10"],
    "u3-20": ["–2(3 – 4x) + 5 = 3(x + 4) + 2", "–6 + 8x + 5 = 3x + 12 + 2", "8x – 1 = 3x + 14", "8x – 3x = 14 + 1", "5x = 15", "x = 3"],
}

PAGES = []


def correct_finished(pid):
    PAGES.append(dict(problem_id=pid, category="correct_finished", error_type=None, rows=list(CLEAN[pid]), wrong_line=None, half=None))


def correct_unfinished(pid, lines, half=None, last=None):
    rows = list(CLEAN[pid][:lines])
    if last is not None:
        rows.append(last)
    PAGES.append(dict(problem_id=pid, category="correct_unfinished", error_type=None, rows=rows, wrong_line=None, half=half))


def wrong(pid, error_type, rows, wrong_line):
    PAGES.append(dict(problem_id=pid, category="wrong", error_type=error_type, rows=rows, wrong_line=wrong_line, half=None))


for _pid in ("u3-01", "u3-04", "u3-05", "u3-07", "u3-10", "u3-12", "u3-15", "u3-19"):
    correct_finished(_pid)

correct_unfinished("u3-06", 3)                                        # stopped after a complete line
correct_unfinished("u3-11", 2)
correct_unfinished("u3-13", 3)
correct_unfinished("u3-20", 2, half=0.82, last="8x – 1 = 3x + 14")   # third line half written, stops at "8x – 1 = 3x +"
correct_unfinished("u3-01", 3, half=0.85, last="4x = 16 + 4")        # fourth line half written, stops at "4x = 16 +" (not a complete wrong equation)
correct_unfinished("u3-10", 2, half=0.5, last="2 – 3x = 5")         # "2 – 3x =" with the right side missing
correct_unfinished("u3-04", 1, half=0.55, last="–8p – 20 = 12")     # second line half written

wrong("u3-04", "sign", ["–4(2p + 5) = 12", "–8p + 20 = 12", "–8p = –8", "p = 1"], 2)
wrong("u3-05", "sign", ["–(y – 6) = 10", "–y – 6 = 10"], 2)  # the wrong line is the latest one
wrong("u3-11", "sign", ["6(x – 2) – 4(x + 1) = 10", "6x – 12 – 4x + 4 = 10", "2x – 8 = 10", "2x = 18"], 2)
wrong("u3-20", "sign", ["–2(3 – 4x) + 5 = 3(x + 4) + 2", "–6 – 8x + 5 = 3x + 12 + 2", "–8x – 1 = 3x + 14", "–8x – 3x = 14 + 1"], 2)
wrong("u3-01", "combine like terms", ["7x – 4 = 3x + 16", "7x – 3x – 4 = 16", "10x – 4 = 16"], 3)  # latest
wrong("u3-12", "combine like terms", ["3(2r + 5) = –(r – 6) + 23", "6r + 15 = –r + 6 + 23", "6r + 15 = –r + 28"], 3)  # latest
wrong("u3-11", "combine like terms", ["6(x – 2) – 4(x + 1) = 10", "6x – 12 – 4x – 4 = 10", "10x – 16 = 10", "10x = 26"], 3)
wrong("u3-20", "move a term without flipping its sign", ["–2(3 – 4x) + 5 = 3(x + 4) + 2", "–6 + 8x + 5 = 3x + 12 + 2", "8x – 1 = 3x + 14", "8x – 3x = 14 – 1", "5x = 13"], 4)
wrong("u3-04", "distribution (second term forgotten)", ["–4(2p + 5) = 12", "–8p + 5 = 12", "–8p = 7", "p = –{7/8}"], 2)
wrong("u3-10", "distribution (second term forgotten)", ["8 – 3(x + 2) = 5", "8 – 3x + 2 = 5", "10 – 3x = 5"], 2)
wrong("u3-07", "multiply only some terms by the LCD", ["{2k/5} – 3 = 1", "all ·5:  2k – 3 = 5", "2k = 8", "k = 4"], 2)
wrong("u3-01", "divide only one side", ["7x – 4 = 3x + 16", "7x – 3x – 4 = 16", "4x – 4 = 16", "4x = 20", "x = 20"], 5)  # latest
wrong("u3-19", "divide only one side", ["{5/6}v + 2 = {1/3}v + 7", "5v + 12 = 2v + 42", "5v – 2v = 42 – 12", "3v = 30", "v = 30"], 5)  # latest
wrong("u3-15", "distribution (second term forgotten)", ["{2/3}(x – 1) = {1/2}(x + 3)", "4(x – 1) = 3(x + 3)", "4x – 4 = 3x + 3", "4x – 3x = 3 + 4", "x = 7"], 3)
wrong("u3-13", "sign", ["{x + 4/3} = {x – 2/2}", "2(x + 4) = 3(x – 2)", "2x + 8 = 3x + 6", "8 – 6 = 3x – 2x"], 3)


# ---------------------------------------------------------------- handwriting
def parse(text):
    """Tokens: ('c', char) or ('f', num, den)."""
    out = []
    for part in re.split(r"(\{[^}]*/[^}]*\})", text):
        if not part:
            continue
        if part.startswith("{"):
            n, d = part[1:-1].rsplit("/", 1)
            out.append(("f", n, d))
        else:
            out.extend(("c", c) for c in part)
    return out


class Pen:
    """Lays out one row of handwriting as drawing ops with random-but-fixed jitter."""

    def __init__(self, font_key, slant):
        self.path, self.idx, self.size = FONTS[font_key]
        self.slant = slant
        self._fonts = {}

    def font(self, size):
        size = max(10, int(round(size)))
        if size not in self._fonts:
            self._fonts[size] = ImageFont.truetype(self.path, size, index=self.idx)
        return self._fonts[size]

    def glyph(self, ch, size, rot, shear):
        f = self.font(size)
        pad = int(size * 0.5)
        im = Image.new("L", (int(size * 1.7), int(size * 2.2)), 0)
        base = (pad, int(size * 1.4))
        ImageDraw.Draw(im).text(base, ch, font=f, fill=255, anchor="ls")
        a = math.radians(rot)
        c, s = math.cos(a), math.sin(a)
        ox, oy = base
        ra = (c, s, ox - c * ox - s * oy, -s, c, oy + s * ox - c * oy)  # inverse rotation about the baseline origin
        sa = (1, shear, -shear * oy, 0, 1, 0)  # inverse shear about the baseline
        affine = (sa[0] * ra[0] + sa[1] * ra[3], sa[0] * ra[1] + sa[1] * ra[4], sa[0] * ra[2] + sa[1] * ra[5] + sa[2], ra[3], ra[4], ra[5])
        return im.transform(im.size, Image.AFFINE, affine, resample=Image.BICUBIC), base

    def layout_row(self, text, row_seed, max_w):
        toks = parse(text)
        for attempt in range(6):
            ops, ends, x, has_frac = self._layout(toks, row_seed, 1.0 - 0.07 * attempt)
            if x <= max_w:
                break
        return ops, ends, x, has_frac

    def _layout(self, toks, row_seed, scale):
        rng = random.Random(row_seed)
        ops, ends = [], []
        x, has_frac = 0.0, False
        base_sz = self.size * scale
        run_scale, run_dy, run_shear = 1.0, 0.0, self.slant
        for ti, t in enumerate(toks):
            if t[0] == "c" and t[1] == " ":
                x += base_sz * rng.uniform(0.22, 0.36)
                run_scale = rng.uniform(0.92, 1.10)
                run_dy = rng.uniform(-3, 3)
                run_shear = self.slant + rng.uniform(-0.05, 0.05)
                ends.append(len(ops))
                continue
            if t[0] == "c":
                ch = t[1]
                sz = base_sz * run_scale * rng.uniform(0.95, 1.05)
                im, base = self.glyph(ch, sz, rng.uniform(-5, 5), run_shear + rng.uniform(-0.04, 0.04))
                ops.append((ti, "mask", (im, x - base[0], run_dy + rng.uniform(-2.2, 2.2) - base[1])))
                adv = self.font(sz).getlength(ch) * rng.uniform(0.88, 1.06)
                if ch == "·":
                    adv *= 0.9
                x += adv + rng.uniform(-1.5, 2.5)
            else:
                has_frac = True
                _, n, d = t
                fs = base_sz * 0.74
                axis = base_sz * 0.34
                nw = sum(self.font(fs).getlength(c) for c in n)
                dw = sum(self.font(fs).getlength(c) for c in d)
                bw = max(nw, dw) + 14
                x += 5
                for part, yb, pw in ((n, -axis - fs * 0.20, nw), (d, -axis + fs * 0.78, dw)):
                    px = x + (bw - pw) / 2 + rng.uniform(-2, 2)
                    for c in part:
                        if c == " ":
                            px += fs * 0.28
                            continue
                        im, base = self.glyph(c, fs * rng.uniform(0.95, 1.05), rng.uniform(-4, 4), self.slant * 0.5)
                        ops.append((ti, "mask", (im, px - base[0], yb + rng.uniform(-1.5, 1.5) - base[1])))
                        px += self.font(fs).getlength(c) * rng.uniform(0.9, 1.05) + rng.uniform(-1, 1.5)
                tilt = rng.uniform(-2.5, 2.5)
                ops.append((ti, "line", ([(x, -axis - tilt), (x + bw, -axis + tilt)], 3)))
                x += bw + 7
            ends.append(len(ops))
        return ops, ends, x, has_frac


def draw_ops(page, ox, oy, ops, upto_tok, ink):
    """Draw ops with token index < upto_tok at origin (ox, baseline oy). Returns the ink bounding box or None."""
    d = ImageDraw.Draw(page)
    box = None
    for ti, kind, pl in ops:
        if ti >= upto_tok:
            continue
        if kind == "mask":
            im, dx, dy = pl
            px, py = int(round(ox + dx)), int(round(oy + dy))
            page.paste(Image.new("RGB", im.size, ink), (px, py), im)
            bb = im.getbbox()
            if not bb:
                continue
            b = (px + bb[0], py + bb[1], px + bb[2], py + bb[3])
        else:
            pts, wd = pl
            pts = [(ox + a, oy + b) for a, b in pts]
            d.line(pts, fill=ink, width=wd)
            b = (min(p[0] for p in pts) - 1, min(p[1] for p in pts) - 2, max(p[0] for p in pts) + 1, max(p[1] for p in pts) + 2)
        box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    return box


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


def render(page_spec, index):
    seed = 9000 + index
    rng = random.Random(seed)
    font_key = list(FONTS)[index % 4]
    ink = INKS[(index // 4) % len(INKS)]
    slant = rng.uniform(-0.10, 0.22)
    pen = Pen(font_key, slant)
    img = Image.new("RGB", (W, H), BG)
    label_font = ImageFont.truetype(NUM_FONT, 12)
    d = ImageDraw.Draw(img)

    rows = page_spec["rows"]
    y, prev_frac = 74, False
    lines_meta = []
    for r, text in enumerate(rows):
        has_frac = "{" in text
        y += (0 if r == 0 else rng.uniform(70, 84)) + (22 if (has_frac or prev_frac) and r > 0 else 0)
        prev_frac = has_frac
        x0 = 62 + rng.randint(-4, 16)
        ops, ends, width, _ = pen.layout_row(text, seed * 1000 + r * 37 + sum(map(ord, text)), W - x0 - 30)
        last = r == len(rows) - 1
        ntok = len(ends)
        if last and page_spec["half"]:
            ntok = max(2, int(len(ends) * page_spec["half"]))
            while ntok < len(ends) and parse(text)[ntok][0] == "c" and parse(text)[ntok][1] != " ":
                ntok += 1
            ntok = min(ntok, len(ends) - 1)
        box = draw_ops(img, x0, int(y), ops, ntok, ink)
        if box is None:
            continue
        pad = 6
        bx, by = max(0, int(box[0]) - pad), max(0, int(box[1]) - pad)
        lines_meta.append(dict(index=r + 1, box=dict(x=bx, y=by, w=int(box[2] - box[0]) + 2 * pad, h=int(box[3] - box[1]) + 2 * pad)))
        mid = (box[1] + box[3]) / 2
        d.text((4, mid - 7), str(r + 1), font=label_font, fill=(140, 140, 140))  # PageSnapshotter's margin number
    if rng.random() < 0.4:
        stray_mark(img, rng.choice(["dots", "tick", "squiggle", "dash"]), rng.randint(780, 960), rng.randint(440, 520), ink, rng)
    img = img.filter(ImageFilter.GaussianBlur(0.35))
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue(), lines_meta, font_key


def main():
    problems = {p["id"]: p for p in json.load(open(os.path.join(HERE, "..", "..", "shared", "problems.json")))}
    os.makedirs(OUT, exist_ok=True)
    for name in os.listdir(OUT):
        os.remove(os.path.join(OUT, name))
    manifest = []
    for i, spec in enumerate(PAGES):
        assert spec["problem_id"] in problems, spec["problem_id"]
        png, lines, font_key = render(spec, i)
        assert len(png) < 400 * 1024, (i, len(png))
        pid = spec["problem_id"]
        name = f"{i + 1:02d}-{pid}-{spec['category']}" + (f"-w{spec['wrong_line']}" if spec["wrong_line"] else "") + ".png"
        open(os.path.join(OUT, name), "wb").write(png)
        manifest.append(dict(
            id=name[:-4], file=name, problem_id=pid, category=spec["category"], error_type=spec["error_type"],
            wrong_line=spec["wrong_line"], wrong_line_is_latest=bool(spec["wrong_line"]) and spec["wrong_line"] == len(spec["rows"]),
            half_written_last_line=bool(spec["half"]), font=font_key, width=W, height=H, bytes=len(png),
            lines=lines, rows=spec["rows"],
        ))
    json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=1, ensure_ascii=False)
    by = {}
    for m in manifest:
        by[m["category"]] = by.get(m["category"], 0) + 1
    print(len(manifest), "pages", by, "largest", max(m["bytes"] for m in manifest), "bytes")


if __name__ == "__main__":
    main()
