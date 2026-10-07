"""Reproducible census-based cost model. These are predictions, not timings.

S is post-r2 spread cost, I interpolation, F complete FFT/convolution cost.
Only apoa1pme S=100 is measured after r2. Large-system S values are the
consult's assumptions. Upper S bounds use the old census corrected for
sampling, before the spread improvement. Small-system estimates subtract
the r2 whole-step saving, attributing all of it to spread, as a sensitivity
model. The fused pme/dhfr FFT is estimated as .54 times the old block.
"""
import json
import math
from pathlib import Path
from analyze import GRIDS

ROOT = Path(__file__).resolve().parent
MODELS = {
    'pme': (36.0, 14.06, 20.10, 55.71),
    'amber20-dhfr': (37.5, 14.58, 19.0, 59.09),
    'apoa1pme': (100.0, 37.53, 64.09, 209.29),
    'apoa1ljpme': (136.0, 62.60, 64.09+0.54*(96.45-64.09), 296.40*2/1.95),
    'amber20-cellulose': (330.0, 138.96, 135.35*6/5.97+13.91, 630.26/.73),
    'amber20-stmv': (1400.0, 340.68/.86, 369.37*6/5.75+34.29/.96, 970.86/.47),
}


def fft_ratio(grid, base):
    v, v0 = math.prod(grid), math.prod(base)
    return v*math.log(v)/(v0*math.log(v0))


def saving(name, order, grid, base, upper=False):
    s, i, f, s_upper = MODELS[name]
    if upper:
        s = s_upper
    ratio = fft_ratio(grid, base)
    # The fused small-grid path ceases to apply above 63. Its old VkFFT
    # census then gives a more generous cost prediction than a fake fusion.
    if name in ('pme', 'amber20-dhfr') and max(grid) > 63:
        f_new = {'pme': 37.23, 'amber20-dhfr': 35.01}[name]*ratio
    else:
        f_new = f*ratio
    return (1-(order/5)**3)*(s+i)-(f_new-f)


def lj_saving(coulomb_order, coulomb_grid, dispersion_order, dispersion_grid):
    # Census subtraction estimates the dispersion contribution; this is
    # uncertain because the two census traces were different runs. r2's
    # three-pass FFT also applies to the 49^3 dispersion grid.
    fc, fd = 64.09, 0.54*(96.45-64.09)
    def fused(grid):
        for size in grid:
            if size > 63:
                return False
            for factor in (2, 3, 5, 7):
                while size % factor == 0:
                    size //= factor
            if size != 1:
                return False
        return True
    new_fc = fc*(0.54 if fused(coulomb_grid) else 1)*fft_ratio(coulomb_grid, (98,)*3)
    new_fd = (fd if fused(dispersion_grid) else 96.45-64.09)*fft_ratio(dispersion_grid, (49,)*3)
    return ((1-(coulomb_order/5)**3)*(100+37.53)
            +(1-(dispersion_order/5)**3)*(36+25.07)
            -(new_fc+new_fd-fc-fd))


def summarize():
    result = []
    for path in sorted(ROOT.glob('*-sweep.jsonl')):
        rows = [json.loads(s) for s in path.read_text().splitlines()]
        for channel in sorted({r['channel'] for r in rows}):
            selected = [r for r in rows if r['channel'] == channel]
            base_grid = (49,)*3 if channel == 'dispersion' else GRIDS[selected[0]['test']]
            baseline = {r['frame']: r for r in selected
                        if r['order'] == 5 and tuple(r['grid']) == base_grid}
            pairs = sorted({(r['order'], tuple(r['grid'])) for r in selected})
            for order, grid in pairs:
                rr = {r['frame']: r for r in selected if r['order'] == order and tuple(r['grid']) == grid}
                if set(rr) != set(baseline):
                    continue
                ratios = {key: max(r[key]/baseline[frame][key] for frame, r in rr.items())
                          for key in ('rms_relative', 'max_relative', 'max_atom_relative')}
                first = next(iter(rr.values()))
                name = first['test']
                row = {'test': name, 'channel': channel, 'order': order, 'grid': grid,
                       'frames': len(rr), 'error_ratios_to_order5': ratios,
                       'passes_rms_and_max': ratios['rms_relative'] <= 1 and ratios['max_relative'] <= 1,
                       'passes_all_force_metrics': max(ratios.values()) <= 1,
                       'worst_rms_relative': max(r['rms_relative'] for r in rr.values()),
                       'worst_max_relative': max(r['max_relative'] for r in rr.values()),
                       'worst_abs_energy_error': max(abs(r['energy_error']) for r in rr.values())}
                if channel == 'coulomb' and name != 'apoa1ljpme':
                    base = next(iter(baseline.values()))['grid']
                    row['saving_us'] = saving(name, order, grid, base)
                    row['optimistic_saving_us'] = saving(name, order, grid, base, upper=True)
                    row['required_spread_us_to_break_even'] = (
                        (MODELS[name][0]-row['saving_us']/(1-(order/5)**3))
                        if order < 5 else None)
                result.append(row)
    (ROOT/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
    for row in result:
        print(json.dumps(row))


if __name__ == '__main__':
    summarize()
