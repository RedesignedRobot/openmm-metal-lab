"""Export schema of an xctrace .trace: every table in the table of contents, its columns and row count.

usage: DEVELOPER_DIR=<Xcode-beta> python xschema.py <trace> [rows to show, default 2]
Runs `xctrace export --toc`, then `xctrace export --xpath` per table into a temporary file, and streams it, since a
Metal System Trace table can run to hundreds of MB. Prints markdown: per table the schema name and attributes, the
row count, and each column's mnemonic, name and engineering type with the first rows' formatted values. xctrace
writes a repeated value once with an id and later as ref="id"; refs are resolved to the first value's text.
Run it outside the lease: export reads the trace and never touches the GPU.
"""
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

trace = sys.argv[1]
shown = int(sys.argv[2]) if len(sys.argv) > 2 else 2

def xctrace(*args):
    return subprocess.run(["xcrun", "xctrace", "export", "--input", trace, *args], check=True, capture_output=True).stdout

toc = ET.fromstring(xctrace("--toc"))
for run in toc.iter("run"):
    number = run.get("number")
    info = run.find("info")
    summary = info.find("summary") if info is not None else None
    print(f"\n## Run {number}")
    if summary is not None:
        for field in summary:
            print(f"- {field.tag}: {(field.text or '').strip()}")
    for table in run.iter("table"):
        schema = table.get("schema")
        attributes = ", ".join(f"{k}={v}" for k, v in table.attrib.items() if k != "schema")
        xpath = f'/trace-toc/run[@number="{number}"]/data/table[@schema="{schema}"]'
        if attributes:
            xpath = xpath[:-1] + "".join(f' and @{k}="{v}"' for k, v in table.attrib.items() if k != "schema") + "]"
        with tempfile.NamedTemporaryFile(suffix=".xml", delete=False) as handle:
            path = handle.name
        try:
            subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath, "--output", path],
                           check=True, capture_output=True)
            columns, rows, texts, sample = [], 0, {}, []
            for _, element in ET.iterparse(path, events=("end",)):
                if element.get("id") is not None:
                    texts[element.get("id")] = element.get("fmt") or (element.text or "").strip()
                if element.tag == "col":
                    columns.append(tuple((element.findtext(tag) or "").strip() for tag in ("mnemonic", "name", "engineering-type")))
                elif element.tag == "row":
                    rows += 1
                    if len(sample) < shown:
                        values = []
                        for cell in element:
                            ref = cell.get("ref")
                            values.append(texts.get(ref, "?") if ref else (cell.get("fmt") or (cell.text or "").strip()))
                        sample.append(values)
                    element.clear()
        finally:
            os.unlink(path)
        print(f"\n### {schema}" + (f" ({attributes})" if attributes else "") + f", {rows} rows")
        print("\n| mnemonic | name | engineering type | " + " | ".join(f"row {i+1}" for i in range(len(sample))) + " |")
        print("|---|---|---|" + "---|" * len(sample))
        for i, (mnemonic, name, kind) in enumerate(columns):
            values = [s[i] if i < len(s) else "" for s in sample]
            print(f"| {mnemonic} | {name} | {kind} | " + " | ".join(v.replace("|", "/")[:60] for v in values) + " |")
