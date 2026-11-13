#!/usr/bin/env python3
"""The Threader's sounds (Stage 2 B5; design §1.5 «a deep scrape and a long moan», §1.1.7 «sound for height»): six
procedural one-shots, rendered deterministically with numpy (fixed seeds — the same bytes on every run) into
App/Resources/Sounds as WAV 44.1 kHz mono 16-bit, each peak-normalised to -1 dBFS like the web sounds (sounds-manifest.json:
the `boss` section gives their base gain, distance attenuation and minimum gap; AudioEngine.playBoss).

  scrape  claws dragged along a 0.9 m steel pipe: stick-slip noise bursts through the pipe's ringing partials
  moan    the long, deep moan from inside the pipes: a gliding pulse tone through a closed vowel, slow tremolo, a sub rumble
  scream  the hive's screech: a descending FM chirp with a rattling amplitude, breath noise
  slam    the head's slam / a trunk crashing on the deck: a falling thump, an inharmonic clang, a noise burst
  creak   steel under strain (the coil tightening, a trunk being crushed or ripped): a jittery low saw through a resonance
  hiss    steam escaping a burst valve: high-passed noise, a fast attack and a long tail

  python3 tools/audio/make_boss_sounds.py [OUT_DIR]   (default: App/Resources/Sounds next to this tool's ios-native)
  python3 tools/audio/make_boss_sounds.py --check      exit 1 if the committed files differ from a fresh render
"""
import hashlib
import io
import os
import sys
import wave

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), 'App', 'Resources', 'Sounds')


def env(n, a, d, sustain=0.0, curve=3.0):
    """attack `a` s, then an exponential decay to `sustain` over the rest (n samples)"""
    t = np.arange(n) / SR
    e = np.minimum(1.0, t / max(a, 1e-4))
    rest = np.clip((t - a) / max(d, 1e-4), 0, None)
    return np.where(t < a, e, sustain + (1 - sustain) * np.exp(-curve * rest))


def fade(x, a=0.01, b=0.08):
    n = len(x)
    na, nb = int(a * SR), int(b * SR)
    w = np.ones(n)
    w[:na] = np.linspace(0, 1, na)
    w[n - nb:] = np.linspace(1, 0, nb) ** 2
    return x * w


def bandpass(x, f, q):
    """a 2-pole resonator (biquad band-pass, constant 0 dB peak)"""
    w0 = 2 * np.pi * f / SR
    al = np.sin(w0) / (2 * q)
    b0, b2 = al, -al
    a0, a1, a2 = 1 + al, -2 * np.cos(w0), 1 - al
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    b0, b2, a1, a2 = b0 / a0, b2 / a0, a1 / a0, a2 / a0
    for i in range(len(x)):
        v = b0 * x[i] + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, x[i]
        y2, y1 = y1, v
        y[i] = v
    return y


def onepole(x, f, high=False):
    a = np.exp(-2 * np.pi * f / SR)
    y = np.zeros_like(x)
    p = 0.0
    for i in range(len(x)):
        p = (1 - a) * x[i] + a * p
        y[i] = p
    return x - y if high else y


def scrape(rng):
    n = int(1.25 * SR)
    t = np.arange(n) / SR
    noise = rng.standard_normal(n)
    # stick-slip: irregular bursts ~13 Hz, each a short sharp grain
    gate = np.zeros(n)
    k = 0
    while k < n:
        L = int(SR * rng.uniform(0.03, 0.09))
        amp = rng.uniform(0.4, 1.0)
        g = np.exp(-np.linspace(0, 6, L)) * amp
        gate[k:k + L] += g[:max(0, min(L, n - k))]
        k += int(SR * rng.uniform(0.05, 0.11))
    x = noise * gate
    ring = bandpass(x, 182, 18) * 2.6 + bandpass(x, 463, 14) * 1.6 + bandpass(x, 1170, 9) * 0.6 + bandpass(x, 2870, 6) * 0.15
    body = onepole(noise * gate, 600) * 0.6
    y = onepole(onepole(ring + body, 3000), 3000)
    y *= env(n, 0.05, 1.0, 0.0, 2.2)
    return fade(y, 0.02, 0.2)


def moan(rng):
    n = int(2.7 * SR)
    t = np.arange(n) / SR
    f = 50 + 9 * np.sin(np.pi * t / 2.7) - 6 * t / 2.7 + 0.8 * np.sin(2 * np.pi * 5.3 * t)
    ph = 2 * np.pi * np.cumsum(f) / SR
    # a soft pulse wave (odd and even partials), its brightness breathing
    src = np.zeros(n)
    for h in range(1, 14):
        src += np.sin(h * ph) / h * (0.65 if h % 2 == 0 else 1.0)
    vowel = bandpass(src, 310, 4) * 1.6 + bandpass(src, 760, 6) * 0.9 + bandpass(src, 2400, 8) * 0.12
    trem = 0.75 + 0.25 * np.sin(2 * np.pi * 2.1 * t + 0.7)
    sub = np.sin(2 * np.pi * np.cumsum(f * 0.5) / SR) * 0.5
    breath = onepole(onepole(rng.standard_normal(n), 400), 400) * 0.05
    y = onepole(onepole(vowel * trem + sub + breath, 1100), 1100) * env(n, 0.35, 2.4, 0.0, 1.6)
    return fade(y, 0.05, 0.4)


def scream(rng):
    n = int(1.45 * SR)
    t = np.arange(n) / SR
    f = 2300 * np.exp(-1.1 * t) + 650
    mod = 1 + 0.55 * np.sin(2 * np.pi * np.cumsum(f * 0.5) / SR)
    car = np.sin(2 * np.pi * np.cumsum(f) / SR + 2.4 * np.sin(2 * np.pi * np.cumsum(f * 1.5) / SR))
    rattle = 0.55 + 0.45 * np.sign(np.sin(2 * np.pi * (52 + 18 * t) * t))
    hiss = bandpass(rng.standard_normal(n), 3400, 2) * 0.5
    y = (car * mod * 0.8 + hiss) * rattle
    y = bandpass(y, 1600, 0.8) * 1.5 + y * 0.3
    y *= env(n, 0.03, 1.3, 0.0, 2.4)
    return fade(y, 0.005, 0.25)


def slam(rng):
    n = int(1.15 * SR)
    t = np.arange(n) / SR
    f = 38 + 60 * np.exp(-18 * t)
    thump = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-5.5 * t) * 1.6
    clang = np.zeros(n)
    for fr, a, d in ((217, 0.6, 4.0), (489, 0.45, 5.5), (811, 0.35, 7.0), (1297, 0.22, 9.0), (2063, 0.12, 12.0)):
        clang += a * np.sin(2 * np.pi * fr * t + rng.uniform(0, 6.28)) * np.exp(-d * t)
    burst = onepole(onepole(rng.standard_normal(n), 1200), 1800) * np.exp(-28 * t) * 1.4
    grit = bandpass(rng.standard_normal(n), 140, 1.5) * np.exp(-7 * t) * 0.8
    y = thump + clang * 0.9 + burst + grit
    return fade(y, 0.002, 0.3)


def creak(rng):
    n = int(1.6 * SR)
    t = np.arange(n) / SR
    f = 78 + 18 * np.sin(2 * np.pi * 0.7 * t) + np.cumsum(rng.standard_normal(n)) * 0.004
    saw = 2 * ((np.cumsum(f) / SR) % 1.0) - 1
    stick = (rng.random(n) < (14 / SR)).astype(float)
    crack = bandpass(stick * 8 + rng.standard_normal(n) * 0.05, 1900, 6)
    y = bandpass(saw, 240, 5) * 1.4 + bandpass(saw, 610, 8) * 0.7 + crack * 0.8
    y *= env(n, 0.2, 1.3, 0.0, 1.8) * (0.7 + 0.3 * np.sin(2 * np.pi * 3.3 * t))
    return fade(y, 0.03, 0.3)


def hiss(rng):
    n = int(1.05 * SR)
    t = np.arange(n) / SR
    x = onepole(rng.standard_normal(n), 2200, high=True)
    x = x + bandpass(rng.standard_normal(n), 5200, 1.5) * 0.6
    sputter = 0.8 + 0.2 * np.sign(np.sin(2 * np.pi * 23 * t + np.sin(2 * np.pi * 3 * t)))
    y = x * sputter * env(n, 0.03, 0.95, 0.12, 2.0)
    return fade(y, 0.005, 0.25)


SOUNDS = [('threader_scrape', scrape, 11), ('threader_moan', moan, 12), ('threader_scream', scream, 13),
          ('threader_slam', slam, 14), ('threader_creak', creak, 15), ('threader_hiss', hiss, 16)]


def render():
    out = {}
    for name, fn, seed in SOUNDS:
        y = fn(np.random.default_rng(seed))
        y = y / max(1e-9, np.max(np.abs(y))) * (10 ** (-1 / 20))
        pcm = np.round(y * 32767).astype('<i2')
        b = io.BytesIO()
        with wave.open(b, 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        out[name + '.wav'] = (b.getvalue(), len(pcm) / SR)
    return out


def main():
    args = sys.argv[1:]
    files = render()
    if '--check' in args:
        bad = []
        for f, (data, _) in files.items():
            p = os.path.join(OUT, f)
            if not os.path.exists(p) or open(p, 'rb').read() != data:
                bad.append(f)
        print('boss sounds: ' + ('ok' if not bad else 'DIFFER: ' + ', '.join(bad)))
        sys.exit(1 if bad else 0)
    out = args[0] if args else OUT
    os.makedirs(out, exist_ok=True)
    for f, (data, dur) in files.items():
        open(os.path.join(out, f), 'wb').write(data)
        print(f'{f}: {dur:.2f} s, {len(data) // 1024} KB, md5 {hashlib.md5(data).hexdigest()}')


if __name__ == '__main__':
    main()
