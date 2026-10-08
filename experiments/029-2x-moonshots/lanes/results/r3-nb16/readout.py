"""Read paired nonbonded counters. Parser adapted from infra M0 kill.py."""
import json
import statistics
import sys

from pathlib import Path
M = Path(__file__).resolve().parent/"counters"


def docs(s):
    dec, i, found = json.JSONDecoder(), 0, []
    while i < len(s):
        if s[i] in " \r\n\t":
            i += 1
            continue
        try:
            obj, i = dec.raw_decode(s, i)
            found.append(obj)
        except ValueError:
            nl = s.find("\n", i)
            if nl < 0:
                break
            i = nl + 1
    return found


def num(v):
    if v is None:
        return None
    s = str(v).replace(",", "").replace("%", "").split()[0]
    try:
        return float(s)
    except ValueError:
        return None


def load(label):
    lists, infos = {}, {}
    for line in open(f"{M}/{label}/target.jsonl"):
        r = json.loads(line)
        for d in docs(r["out"]):
            if not isinstance(d, dict):
                continue
            if isinstance(d.get("children"), list):
                if len(d["children"]) >= len(lists.get(r["path"], [])):
                    lists[r["path"]] = d["children"]
            elif r["cmd"][-1] == "info --all":
                infos[r["path"]] = d
    return lists, infos


def values(children):
    out = {}
    for c in children:
        vals = [v.get("value") for v in c.get("values") or [] if isinstance(v, dict)]
        out[c["name"]] = vals[0] if vals else None
    return out


def readout(label):
    lists, infos = load(label)
    matches = [name for name, fn in values(lists["/performance/shaders"]).items() if fn == "computeNonbonded"]
    if len(matches) != 1:
        raise ValueError(f"expected one active computeNonbonded shader: {matches}")
    comp = matches[0]
    shader = infos[f"/performance/shaders/{comp}"]
    disp = [p for p in infos if p.startswith("/performance/commands/disp") and infos[p].get("Shaders") == "computeNonbonded"]
    instr = [num(infos[p]["Instructions"]) for p in disp]
    ck = {}
    for p in disp:
        for k, v in values(lists.get(p + "/counters/compute_kernel", [])).items():
            if num(v) is not None:
                ck.setdefault(k, []).append(num(v))
    enc = [p.rsplit("/", 1)[0] for p, kids in lists.items() if p.endswith("/commands") and p.startswith(
        "/performance/encoders/") and any('computeNonbonded' in json.dumps(c) for c in kids)]
    groups = {}
    for e in enc:
        for g in ("performance_limiters", "memory", "compute_kernel"):
            for k, v in values(lists.get(f"{e}/counters/{g}", [])).items():
                if num(v) is not None:
                    groups.setdefault(k, []).append(num(v))
    tl = {}
    for p, kids in lists.items():
        if p.startswith("/performance/timeline/counters/"):
            for k, v in values(kids).items():
                if num(v) is not None:
                    tl[k] = num(v)
    enc_names = {e.rsplit("/", 1)[1] for e in enc}
    durs = [c["values"][3]["value"] for c in lists["/performance/timeline/encoders"] if c["name"] in enc_names]
    return {"shader": shader, "instr": instr, "dur": durs, "ck": {k: statistics.median(v) for k, v in ck.items()},
            "enc": {k: statistics.median(v) for k, v in groups.items()}, "n_enc": len(enc), "tl": tl}


if __name__ == "__main__":
    metadata = {}
    for label in ("control", "compact"):
        records = [json.loads(line) for line in (M/label/"replay.log").read_text().splitlines() if line.startswith("{")]
        metadata[label] = next(r for r in records if "positions_sha256" in r)
    for key in ("positions_sha256", "compact_sha256", "old_tiles", "packets"):
        if metadata["control"][key] != metadata["compact"][key]:
            raise ValueError("paired capture mismatch: "+key)
    results = {label: readout(label) for label in ("control", "compact")}
    a, b = results["control"], results["compact"]
    if min(len(a["instr"]), len(b["instr"]), len(a["dur"]), len(b["dur"])) < 6:
        raise ValueError("insufficient force dispatches in capture")
    instruction_ratio = statistics.median(b["instr"])/statistics.median(a["instr"])
    time_ratio = statistics.median(b["dur"])/statistics.median(a["dur"])
    result = dict(metadata=metadata, results=results, instruction_ratio=instruction_ratio,
                  force_time_ratio=time_ratio, instruction_gate=instruction_ratio <= .85,
                  force_only_upper_bound_gate=time_ratio <= .90,
                  emitter_included=False)
    print(json.dumps(result, indent=2))
