"""Inline the stylesheet and figures into each page template.

usage: python3 build_pages.py <out-dir>
A template marks insertions with <!--css--> and <!--fig:NAME--> (NAME.svg in ../figures).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIGS = os.path.join(HERE, "../figures")


def read(path):
    with open(path) as f:
        return f.read()


def build(template, out_dir):
    css = read(os.path.join(HERE, "page.css")) + read(os.path.join(FIGS, "figures.css"))
    html = read(os.path.join(HERE, template)).replace("<!--css-->", f"<style>\n{css}</style>")
    html = re.sub(r"<!--fig:([\w-]+)-->", lambda m: read(os.path.join(FIGS, f"{m.group(1)}.svg")), html)
    with open(os.path.join(out_dir, template), "w") as f:
        f.write(html)


def main():
    out_dir = sys.argv[1]
    for name in sorted(os.listdir(HERE)):
        if name.endswith(".html"):
            build(name, out_dir)


if __name__ == "__main__":
    main()
