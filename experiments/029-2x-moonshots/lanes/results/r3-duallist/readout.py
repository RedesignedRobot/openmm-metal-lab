"""Read counter-attributed list time and force instructions from paired captures.

Per-encoder GPU durations come from the counter replay timeline. The command
cost fractions partition those durations. Report this attribution explicitly;
it is not host-clock step timing. Every command between findBlockBounds and
copyInteractionCounts belongs to the list family, including all sort passes.
"""
import collections
import json
import pathlib
import re
import sys


def docs(text):
    decoder = json.JSONDecoder()
    while text.strip():
        text = text.lstrip()
        try:
            obj, end = decoder.raw_decode(text)
            yield obj
            text = text[end:]
        except ValueError:
            if '\n' not in text:
                return
            text = text.split('\n', 1)[1]


def active_dispatches(samples):
    """Separate full kernel executions from flag-only returns by instruction gap."""
    if not samples:
        return [], None
    ordered = sorted(samples, key=lambda item: item[1])
    gaps = [(right[1]/max(1, left[1]), i) for i, (left, right) in
            enumerate(zip(ordered, ordered[1:]))]
    gap, index = max(gaps, default=(1, -1))
    if gap < 5:
        raise ValueError(f"cannot distinguish full execution from flag-only returns: instruction range {ordered[0][1]}..{ordered[-1][1]}, largest gap {gap:.2f}x")
    threshold = (ordered[index][1]+ordered[index+1][1])/2
    return [item for item in samples if item[1] > threshold], threshold


def read(path):
    tables, infos, links = {}, {}, {}
    for line in pathlib.Path(path).read_text().splitlines():
        row = json.loads(line)
        for doc in docs(row['out']):
            if not isinstance(doc, dict):
                continue
            if isinstance(doc.get('children'), list):
                if len(doc['children']) >= len(tables.get(row['path'], [])):
                    tables[row['path']] = doc['children']
                if row['path'].startswith('/performance/commands/') and 'pe' in doc.get('links', {}):
                    links[row['path']] = '/' + doc['links']['pe']
            elif row['cmd'][-1] == 'info --all':
                infos[row['path']] = doc
    durations = {c['name']: float(c['values'][3]['value']) for c in tables['/performance/timeline/encoders']}
    family_ns = 0.0
    families = collections.defaultdict(float)
    dispatch_ns = {}
    list_steps = 0
    for path, commands in tables.items():
        if not path.startswith('/performance/encoders/') or not path.endswith('/commands'):
            continue
        commands = sorted(commands, key=lambda c: int(re.search(r'\d+$', c['name'])[0]))
        cost = sum(float(c['values'][2]['value']) for c in commands)
        if cost == 0:
            continue
        duration = durations[path.split('/')[3]]
        in_list = False
        for cmd in commands:
            name = str(cmd['values'][0]['value']).strip('"')
            if name == 'findBlockBounds':
                in_list = True
                list_steps += 1
            if in_list:
                elapsed = duration*float(cmd['values'][2]['value'])/cost
                family_ns += elapsed
                families[name] += elapsed
                dispatch_ns[path+'/'+cmd['name']] = elapsed
            if name == 'copyInteractionCounts':
                in_list = False
        assert not in_list, f'list spans encoders: {path}'
    force_instr, search_instr, prune_instr = [], [], []
    for path, info in infos.items():
        if not path.startswith('/performance/commands/disp'):
            continue
        value = int(str(info.get('Instructions', '0')).replace(',', ''))
        if info.get('Shaders') == 'computeNonbonded':
            force_instr.append(value)
        elif info.get('Shaders') == 'findBlocksWithInteractions':
            search_instr.append((links[path], value))
        elif info.get('Shaders') == 'pruneNeighborList':
            prune_instr.append((links[path], value))
    assert len(force_instr) == list_steps == 32, (len(force_instr), list_steps)
    active_search, search_threshold = active_dispatches(search_instr)
    active_prune, prune_threshold = active_dispatches(prune_instr)
    assert len(search_instr) == len(prune_instr) == list_steps, (len(search_instr), len(prune_instr), list_steps)
    missing = [name for name, _ in active_prune+active_search if name not in dispatch_ns]
    assert not missing, (missing[:8], list(dispatch_ns)[:8])
    prune_us = sum(dispatch_ns[name] for name, _ in active_prune)/1000
    return {'steps': list_steps, 'list_us_per_step': family_ns/(1000*list_steps),
            'force_instructions_per_step': sum(force_instr)/len(force_instr),
            'outer_rebuilds': len(active_search), 'outer_steps_per_rebuild': list_steps/len(active_search) if active_search else None,
            'outer_instruction_range': [min(v for _, v in search_instr), max(v for _, v in search_instr)],
            'outer_active_threshold': search_threshold,
            'prune_calls': len(active_prune), 'prune_us_per_call': prune_us/len(active_prune) if active_prune else None,
            'prune_instruction_range': [min(v for _, v in prune_instr), max(v for _, v in prune_instr)],
            'prune_active_threshold': prune_threshold,
            'family_us_per_step': {k: v/(1000*list_steps) for k, v in families.items()}}


if __name__ == '__main__':
    if len(sys.argv) == 2:
        print(json.dumps(read(sys.argv[1]), indent=2))
        sys.exit(0)
    control, dual = (read(p) for p in sys.argv[1:3])
    ratio = dual['list_us_per_step']/control['list_us_per_step']
    force_ratio = dual['force_instructions_per_step']/control['force_instructions_per_step']
    print(json.dumps({'control': control, 'dual': dual, 'list_ratio': ratio, 'force_instructions_ratio': force_ratio,
                      'verdict': 'DEAD' if ratio > 0.70 or force_ratio > 1.05 else 'PASS'}, indent=2))
