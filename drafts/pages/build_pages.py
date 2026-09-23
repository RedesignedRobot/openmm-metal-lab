"""Inline the stylesheet and figures into each page template.

usage: python3 build_pages.py <out-dir>
A template marks insertions with <!--css-->, <!--fig:NAME--> (NAME.svg in ../figures) and
<!--icon:NAME--> (a 24-unit line icon from ICONS).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIGS = os.path.join(HERE, "../figures")
FONTS = ('<link rel="preconnect" href="https://fonts.googleapis.com">'
         '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
         '<link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700'
         '&family=Geist+Mono:wght@400;500;600&family=Instrument+Serif:ital@0;1&display=swap" rel="stylesheet">')
ICONS = {
    "gauge": '<path d="M12 14l4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/>',
    "trend": '<polyline points="22 7 13.5 15.5 8.5 10.5 2 17"/><polyline points="16 7 22 7 22 13"/>',
    "target": '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>',
    "check": '<path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/>',
    "alert": '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>'
             '<line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>',
    "branch": '<line x1="6" y1="3" x2="6" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/>'
              '<path d="M18 9a9 9 0 0 1-9 9"/>',
    "flask": '<path d="M9 3h6"/><path d="M10 3v6L4.5 19a1.5 1.5 0 0 0 1.3 2h12.4a1.5 1.5 0 0 0 1.3-2L14 9V3"/>',
    "route": '<circle cx="6" cy="19" r="3"/><path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15"/>'
             '<circle cx="18" cy="5" r="3"/>',
    "spark": '<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/><path d="M19 17l.8 2.2L22 20l-2.2.8L19 23l-.8-2.2L16 20l2.2-.8z"/>',
    "layers": '<polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/>'
              '<polyline points="2 12 12 17 22 12"/>',
    "chip": '<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/>'
            '<path d="M9 1v3M15 1v3M9 20v3M15 20v3M20 9h3M20 14h3M1 9h3M1 14h3"/>',
}


def icon(name):
    return ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
            f'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{ICONS[name]}</svg>')


def read(path):
    with open(path) as f:
        return f.read()


def build(template, out_dir):
    css = read(os.path.join(HERE, "page.css")) + read(os.path.join(FIGS, "figures.css"))
    html = read(os.path.join(HERE, template)).replace("<!--css-->", f"{FONTS}<style>\n{css}</style>")
    html = re.sub(r"<!--fig:([\w-]+)-->", lambda m: read(os.path.join(FIGS, f"{m.group(1)}.svg")), html)
    html = re.sub(r"<!--icon:(\w+)-->", lambda m: icon(m.group(1)), html)
    with open(os.path.join(out_dir, template), "w") as f:
        f.write(html)


def main():
    out_dir = sys.argv[1]
    for name in sorted(os.listdir(HERE)):
        if name.endswith(".html"):
            build(name, out_dir)


if __name__ == "__main__":
    main()
