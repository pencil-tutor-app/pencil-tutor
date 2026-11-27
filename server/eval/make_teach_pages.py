#!/usr/bin/env python3
"""Draw the pages for server/eval/run-teach-flow.ts with the course fixture renderer (make_course_fixtures.py).

Input: a spec file {"pages": [{"concept": 0, "kind": "correct" | "slip", "rows": ["..."], "planted_line": 3}]}, where rows are the lines
a student would write, in the renderer's markup ({top/bottom} fractions, ^2 powers, \\r{...} roots, \\m{a|b;c|d} matrices). Output: the
PNGs and <out>/b.json, the file the flow script is waiting for. Same limits as the fixtures: fonts with jitter, not real handwriting.

Needs Pillow. Run: python3 -I server/eval/make_teach_pages.py <spec.json> <out dir>
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_course_fixtures as fixtures  # noqa: E402  (importing it draws nothing: its main() is behind __main__)


def main(spec_path, out_dir):
    spec = json.load(open(spec_path))
    os.makedirs(out_dir, exist_ok=True)
    fonts = list(fixtures.FONT_FILES)
    pages = []
    for i, page in enumerate(spec["pages"]):
        font_key = page.get("font") or fonts[i % len(fonts)]
        png, lines, height, width = fixtures.render(page["rows"], page.get("seed", 41000 + i), font_key)
        name = f"teach-{page['concept']}-{page['kind']}.png"
        path = os.path.join(out_dir, name)
        open(path, "wb").write(png)
        pages.append(dict(concept=page["concept"], kind=page["kind"], file=path, width=width, height=height, lines=lines, planted_line=page.get("planted_line"), font=font_key, bytes=len(png)))
    json.dump({"pages": pages}, open(os.path.join(out_dir, "b.json.tmp"), "w"), indent=1)
    os.replace(os.path.join(out_dir, "b.json.tmp"), os.path.join(out_dir, "b.json"))
    print(len(pages), "pages written to", out_dir)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
