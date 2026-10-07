import sys, glob, os, numpy as np
a, b = sys.argv[1], sys.argv[2]
for fa in sorted(glob.glob(a + '/*.npz')):
    fb = b + '/' + os.path.basename(fa)
    if not os.path.exists(fb):
        continue
    x, y = np.load(fa), np.load(fb)
    d = np.abs(x['f']-y['f'])
    print(f"{os.path.basename(fa)[:-4]:28s} bitwise {np.array_equal(x['f'], y['f'])} max|dF| {d.max():.3g} dE {float(y['e'])-float(x['e']):.4g} (E {float(x['e']):.6g})")
