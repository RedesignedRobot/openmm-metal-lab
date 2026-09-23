"""Render every figure SVG to a 2x PNG on the pages' black background, for the GitHub PR body.

usage: python3 export_png.py   (needs Google Chrome; writes png/<name>.png next to this file)
"""
import pathlib
import re
import subprocess
import tempfile

HERE = pathlib.Path(__file__).parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TOKENS = ":root{--bg:#000;--text:#f5f5f7;--muted:#86868b;--line:#1f1f23;--sans:'Geist',-apple-system,sans-serif}"
FONTS = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&display=swap">'
PAD = 24


def export(svg_path, tmp):
    svg = svg_path.read_text()
    w, h = (float(v) for v in re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg).groups())
    page = tmp / f"{svg_path.stem}.html"
    page.write_text(
        f"<!doctype html><meta charset=utf-8>{FONTS}<style>{TOKENS}{(HERE / 'figures.css').read_text()}"
        f"html,body{{margin:0;background:#000}}body{{padding:{PAD}px}}svg{{display:block;width:{w}px}}</style>{svg}"
    )
    out = HERE / "png" / f"{svg_path.stem}.png"
    subprocess.run(
        [CHROME, "--headless=new", "--hide-scrollbars", "--force-device-scale-factor=2",
         "--virtual-time-budget=3000", f"--window-size={int(w) + 2 * PAD},{int(h) + 2 * PAD}",
         f"--screenshot={out}", page.as_uri()],
        check=True, capture_output=True,
    )
    return out


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as d:
        for svg_path in sorted(HERE.glob("*.svg")):
            print(export(svg_path, pathlib.Path(d)))
