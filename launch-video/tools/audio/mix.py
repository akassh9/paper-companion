"""Builds the film's soundtrack (48 kHz stereo WAV) from the 78 and the drawing's pen events.

python3 -I tools/audio/mix.py <launch-video dir> <out.wav>

Edit (film time <- recording time), all cut points found from the record's own chord attacks:
  0.00-9.40   <- 0.00-9.40     needle drop, then the three chords at 2.64 / 4.00 / 5.45
  9.40-52.68  <- 93.75-137.03  the Agitato, from its first attack to a downbeat of the climax (hard stop)
  52.68-62.7  crackle bed from the lead-in groove; at 54.2 one soft chord from the coda (200.54)
Under it: pen scratches and marker swipes timed to every drawn stroke, a soft paper sound for prints.
"""
import json, subprocess, sys
import numpy as np

root, out = sys.argv[1], sys.argv[2]
SR = 48000
LENGTH = 62.7
N = int(LENGTH * SR)
rng = np.random.default_rng(1921)

def decode(path):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)

rec = decode(f"{root}/assets/music/rachmaninoff-prelude-csharp-minor-1921.flac")
rec = rec - np.mean(rec)

def seg(a, b):
    return rec[int(a * SR):int(b * SR)].copy()

def fade(x, fin=0.0, fout=0.0):
    n = len(x)
    if fin > 0:
        k = min(n, int(fin * SR)); x[:k] *= np.sin(np.linspace(0, np.pi / 2, k)) ** 2
    if fout > 0:
        k = min(n, int(fout * SR)); x[n - k:] *= np.cos(np.linspace(0, np.pi / 2, k)) ** 2
    return x

def place(track, x, t):
    i = int(round(t * SR)); j = min(len(track), i + len(x))
    track[i:j] += x[:j - i]

def bandpass_noise(n, lo, hi, seed):
    r = np.random.default_rng(seed)
    spec = np.fft.rfft(r.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / SR)
    # Smooth band edges (raised cosine over an octave-ish skirt).
    lo_w = np.clip((f - lo * 0.6) / (lo * 0.4), 0, 1); hi_w = np.clip((hi * 1.5 - f) / (hi * 0.5), 0, 1)
    spec *= (0.5 - 0.5 * np.cos(np.pi * lo_w)) * (0.5 - 0.5 * np.cos(np.pi * hi_w))
    x = np.fft.irfft(spec, n)
    return x / (np.std(x) + 1e-12)

# ---------------------------------------------------------------- music edit
music = np.zeros(N)
a = fade(seg(0.0, 9.42), fout=0.06)
place(music, a, 0.0)
CUT_IN, ATTACK, STOP = 9.40, 93.75, 137.03
b = fade(seg(ATTACK - 0.03, STOP + 0.22), fin=0.02, fout=0.11)
place(music, b, CUT_IN - 0.03)
# A whisper of reverb tail after the hard stop comes from the room below; the record itself stops dead.

def tame(x):
    """Gentle 78 cleanup: high-pass near 60 Hz, and roll off the hiss and crackle above ~6 kHz (the piano
    has little up there on a 1921 acoustic-era transfer). Leaves the record's character, removes the edge."""
    n = len(x); size = 1 << (n - 1).bit_length()
    X = np.fft.rfft(x, size); f = np.fft.rfftfreq(size, 1 / SR)
    hp = np.clip((f - 35) / 40, 0, 1)
    lp = 1 / (1 + (f / 6000) ** 6)
    return np.fft.irfft(X * hp * lp, size)[:n]

# The end chord, from the coda.
chord = fade(seg(200.54 - 0.04, 200.54 + 8.2), fin=0.03, fout=1.6)
place(music, chord * 1.15, 54.2 - 0.04)
music = tame(music)

# Crackle bed: the groove before the first chord (no music in it), looped with crossfades.
groove = tame(seg(0.25, 2.5))
bed = np.zeros(N)
t, L = 52.6, len(groove) / SR
while t < LENGTH:
    place(bed, fade(groove.copy(), fin=0.25, fout=0.25), t)
    t += L - 0.25
bed_env = np.zeros(N)
i0 = int(52.72 * SR)
bed_env[i0:] = 1
k = int(0.08 * SR); bed_env[i0:i0 + k] = np.linspace(0, 1, k)
k2 = int(0.9 * SR); bed_env[N - k2:] *= np.linspace(1, 0, k2)
bed *= bed_env * 0.32

# ---------------------------------------------------------------- room
def reverb_ir(seconds=2.2, predelay=0.018, seed=7):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir = np.zeros((n, 2))
    for c in range(2):
        noise = bandpass_noise(n, 120, 7000, seed + c)
        ir[:, c] = noise * np.exp(-6.9 * t / seconds)
    d = int(predelay * SR)
    ir = np.vstack([np.zeros((d, 2)), ir])
    return ir / np.sqrt((ir ** 2).sum(axis=0))

def convolve(x, ir):
    n = len(x) + len(ir) - 1
    size = 1 << (n - 1).bit_length()
    X = np.fft.rfft(x, size)
    return np.stack([np.fft.irfft(X * np.fft.rfft(ir[:, c], size), size)[:len(x)] for c in range(ir.shape[1])], axis=1)

ir = reverb_ir()
music_st = np.stack([music, music], axis=1)
wet = convolve(music, ir)
music_st = music_st * 0.9 + wet * 0.2

# ---------------------------------------------------------------- pen and paper
events = json.load(open(f"{root}/render/events.json"))
pen_src = bandpass_noise(N, 1800, 7500, 11)
marker_src = bandpass_noise(N, 600, 2600, 12)
thud_src = bandpass_noise(N, 90, 700, 13)
# Paper tooth: a fast random flutter on the scratch.
flutter = np.abs(bandpass_noise(N, 25, 90, 14)) * 0.5 + 0.6

pen_env = np.zeros(N); marker_env = np.zeros(N); thud_env = np.zeros(N); web_env = np.zeros(N)
for e in events:
    i = int(e["t"] * SR); dur = max(0.035, e["d"])
    n = int(dur * SR)
    if i >= N: continue
    if e["kind"] == "print":
        m = int(0.35 * SR); env = np.exp(-np.arange(m) / (0.07 * SR)); env[:int(0.004 * SR)] *= np.linspace(0, 1, int(0.004 * SR))
        j = min(N, i + m); thud_env[i:j] += env[:j - i] * (0.5 if e["web"] else 1.0)
        continue
    env = np.ones(n)
    att, rel = min(n, int(0.008 * SR)), min(n, int(0.03 * SR))
    env[:att] *= np.linspace(0, 1, att); env[n - rel:] *= np.linspace(1, 0, rel)
    # Faster, longer strokes are louder; hairline text dashes are quiet.
    speed = e["len"] / dur if dur > 0 else 0
    amp = np.clip(0.25 + e["w"] / 12, 0.3, 1.0) * np.clip(speed / 3500, 0.35, 1.0)
    j = min(N, i + n)
    target = web_env if e["web"] else (marker_env if e["kind"] == "marker" else pen_env)
    target[i:j] += env[:j - i] * amp

def soft(x, k=1.2): return x / (1 + k * x)
pen = pen_src * flutter * (soft(pen_env) + soft(web_env, 2.0) * 0.55)
marker = marker_src * flutter * soft(marker_env) * 0.7
thud = thud_src * thud_env
fx = pen * 0.034 + marker * 0.036 + thud * 0.11
# Pen sounds sit slightly off-centre, like a hand on a desk.
fx_st = np.stack([fx * 0.92, fx * 1.0], axis=1)
fx_st += convolve(fx, reverb_ir(0.6, 0.006, 21)) * 0.12

# ---------------------------------------------------------------- mix and level
mix = music_st + fx_st + np.stack([bed, bed], axis=1) * 0.9
peak = np.max(np.abs(mix))
mix *= 0.89 / peak    # -1 dBFS peak; loudness is set at mux time
pcm = (np.clip(mix, -1, 1) * 32767).astype("<i2")
import wave
with wave.open(out, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
print("wrote", out, f"{LENGTH:.1f}s", "music rms", 20 * np.log10(np.std(music_st) + 1e-12), "fx rms", 20 * np.log10(np.std(fx_st) + 1e-12))
