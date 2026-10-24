"""Port the C filter design + MDF to Python and check against known signals."""
import numpy as np

FS = 2000.0
HPF, LPF, NOTCH, NOTCH_Q = 20.0, 450.0, 60.0, 30.0
Q_BW = 0.70710678
NFFT = 512


def design_highpass(fs, fc, q):
    w0 = 2 * np.pi * fc / fs
    c, a = np.cos(w0), np.sin(w0) / (2 * q)
    a0 = 1 + a
    return [((1 + c) / 2) / a0, (-(1 + c)) / a0, ((1 + c) / 2) / a0,
            (-2 * c) / a0, (1 - a) / a0]


def design_lowpass(fs, fc, q):
    w0 = 2 * np.pi * fc / fs
    c, a = np.cos(w0), np.sin(w0) / (2 * q)
    a0 = 1 + a
    return [((1 - c) / 2) / a0, (1 - c) / a0, ((1 - c) / 2) / a0,
            (-2 * c) / a0, (1 - a) / a0]


def design_notch(fs, fc, q):
    w0 = 2 * np.pi * fc / fs
    c, a = np.cos(w0), np.sin(w0) / (2 * q)
    a0 = 1 + a
    return [1 / a0, (-2 * c) / a0, 1 / a0, (-2 * c) / a0, (1 - a) / a0]


def biquad(x, co):
    """y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]"""
    b0, b1, b2, a1, a2 = co
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for n in range(len(x)):
        v = b0 * x[n] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, x[n]
        y2, y1 = y1, v
        y[n] = v
    return y


CHAIN = [design_highpass(FS, HPF, Q_BW),
         design_lowpass(FS, LPF, Q_BW),
         design_notch(FS, NOTCH, NOTCH_Q)]


def run_chain(x):
    for co in CHAIN:
        x = biquad(x, co)
    return x


def gain_at(freq, settle=4000, measure=4000):
    t = np.arange(settle + measure) / FS
    y = run_chain(np.sin(2 * np.pi * freq * t))[settle:]
    return np.sqrt(np.mean(y ** 2)) * np.sqrt(2)


def compute_mdf(window):
    """Mirror of compute_mdf() in emg_dsp.c, interpolation included."""
    w = window * np.hanning(len(window))
    spec = np.fft.fft(w)
    nb = NFFT // 2
    bin_hz = FS / NFFT
    power = np.abs(spec[:nb]) ** 2
    lo, hi = int(HPF / bin_hz), int(LPF / bin_hz)
    total = power[lo:hi + 1].sum()
    if total <= 0:
        return 0.0
    half = total * 0.5
    running = 0.0
    for i in range(lo, hi + 1):
        running += power[i]
        if running >= half:
            prev = running - power[i]
            frac = (half - prev) / power[i] if power[i] > 0 else 0.0
            return (i + frac) * bin_hz
    return hi * bin_hz


print("=== Filter chain magnitude response ===")
checks = [
    (1,   "DC drift",        None, 0.05),
    (10,  "below HPF",       None, 0.60),
    (20,  "HPF corner",      0.50, 0.95),
    (60,  "mains notch",     None, 0.15),
    (100, "passband",        0.85, 1.05),
    (250, "passband",        0.85, 1.05),
    (450, "LPF corner",      0.50, 0.95),
    (800, "above LPF",       None, 0.45),
]
ok = True
for f, label, lo, hi in checks:
    g = gain_at(f)
    passed = (lo is None or g >= lo) and g <= hi
    ok &= passed
    print(f"  {f:4d} Hz  {label:14s}  gain {g:6.3f}   {'ok' if passed else 'FAIL'}")

print("\n=== Median frequency ===")
rng = np.random.default_rng(1)
for target in (80.0, 150.0, 300.0):
    t = np.arange(NFFT) / FS
    sig = run_chain(np.sin(2 * np.pi * target * t))
    mdf = compute_mdf(sig)
    err = abs(mdf - target)
    passed = err < 8.0
    ok &= passed
    print(f"  pure {target:5.0f} Hz -> MDF {mdf:6.1f} Hz  (err {err:4.1f})  "
          f"{'ok' if passed else 'FAIL'}")

# Broadband 20-450 Hz noise: MDF should land near the band midpoint.
noise = run_chain(rng.standard_normal(NFFT * 8))
mdfs = [compute_mdf(noise[i:i + NFFT]) for i in range(0, NFFT * 7, NFFT // 2)]
mean_mdf = float(np.mean(mdfs))
passed = 180 < mean_mdf < 300
ok &= passed
print(f"  broadband 20-450 -> MDF {mean_mdf:6.1f} Hz (expect ~235)  "
      f"{'ok' if passed else 'FAIL'}")

# Fatigue simulation: as the spectrum shifts down, MDF must track it down.
print("\n=== Fatigue trend (spectrum shifting down) ===")
prev = None
mono = True
for shift in (1.00, 0.90, 0.80, 0.70):
    acc = []
    for _ in range(6):
        w = rng.standard_normal(NFFT * 2)
        lp = biquad(w, design_lowpass(FS, 400 * shift, Q_BW))
        acc.append(compute_mdf(run_chain(lp)[NFFT:]))
    m = float(np.mean(acc))
    arrow = ""
    if prev is not None:
        if m >= prev:
            mono = False
        arrow = f"  ({m - prev:+.1f} Hz)"
    print(f"  spectrum x{shift:.2f} -> MDF {m:6.1f} Hz{arrow}")
    prev = m
ok &= mono
print(f"  monotonically decreasing: {'ok' if mono else 'FAIL'}")

print("\nRESULT:", "all checks passed" if ok else "FAILURES PRESENT")
