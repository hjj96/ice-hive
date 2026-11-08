#!/usr/bin/env python3
"""Look gates of the CI shots (WP7 «Режиссура»; the plan's frame_stats.py, landscape).

Per scene of ci/golden/thresholds.json, the first shot that exists in the results folder is measured:
  median / mean / p95   sRGB Rec.709 luma (0–255) of the world (the left 6.5 % — the Dynamic Island strip of an upright
                        landscape-right screenshot — cut off)
  p95/p50               contrast: the lit highlights against the body of the frame
  dark                  near-black %: luma < 16
  clip                  clipped white %: min channel ≥ 235
  specks                pink-white gland specks: 4-connected blobs of 2–80 px with R ≥ 170, B ≥ 120, R − G ≥ 45
  warm / cold           mean R − B of the brightest 5 % / the darkest 50 % (split tone: warm lights, cold shadows)
  colorf                Hasler–Süsstrunk colourfulness
  deck median           (scene with a `-deckMask` shot of the same framing) median luma of the HUD-off shot under the
                        green deck tops; and every snow-blue mask pixel must have deck within 30 px (no drift past a rail)
A HUD-off shot (`*-nohud-*`, FrameLoop -hideHUD) is gated; a HUD-on shot is measured inside the HUD mask (top bar,
thumb areas, armour bar and debug text cut out) and only reported — its numbers include HUD glow and are not the gate's.
Also: the brightness option at its maximum (calm vs calm-bright, ≥ +15 luma at the deck or the frame median) and the
punch-in's entry (the worst loop tick of the heartbeat seconds the shot runs in, app-punchin.log, ≤ 34 ms).

Usage: look_metrics.py [--gate] [--golden DIR] [--json OUT] [--only s1,s2] [--failed OUT] <results dir>
Writes the table to stdout; --json writes the numbers for ci/twoup.py. Exit 1 with --gate when a gated check fails.
--only measures just those scenes (no brightness / punch-in rows unless their base scene is listed); --failed writes the
HUD-off shots of the scenes that failed a gate, one file name per line — sim-smoke re-shoots each of them once before
the look-gate job measures the final shots (a HUD-off shot is one frozen moment: a blast's peak, a cinematic camera
dodging a flashlight cone; a real regression fails the re-shoot too).
"""
import json
import os
import re
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))


def load(path):
    return np.asarray(Image.open(path).convert('RGB')).astype(np.float32)


def count_blobs(m, lo, hi):
    """4-connected components of a sparse boolean mask with lo..hi pixels."""
    ys, xs = np.nonzero(m)
    todo = set(zip(ys.tolist(), xs.tolist()))
    n = 0
    while todo:
        stack = [todo.pop()]
        size = 0
        while stack:
            y, x = stack.pop()
            size += 1
            for q in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                if q in todo:
                    todo.remove(q)
                    stack.append(q)
        n += lo <= size <= hi
    return n


def region_mask(shape, crop, hud_rects=None):
    h, w = shape[:2]
    m = np.ones((h, w), dtype=bool)
    m[:, :int(round(crop.get('left', 0) * w))] = False
    r = int(round(crop.get('right', 0) * w))
    if r:
        m[:, w - r:] = False
    t = int(round(crop.get('top', 0) * h))
    if t:
        m[:t] = False
    b = int(round(crop.get('bottom', 0) * h))
    if b:
        m[h - b:] = False
    for x0, y0, x1, y1 in hud_rects or []:
        m[int(y0 * h):int(np.ceil(y1 * h)), int(x0 * w):int(np.ceil(x1 * w))] = False
    return m


def stats(a, m):
    R, G, B = a[..., 0], a[..., 1], a[..., 2]
    Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
    y = Y[m]
    r, g, b = R[m], G[m], B[m]
    clip = float((np.minimum(np.minimum(r, g), b) >= 235).mean() * 100)
    dark = float((y < 16).mean() * 100)
    sp = (R >= 170) & (B >= 120) & (R - G >= 45) & m
    specks = count_blobs(sp, 2, 80)
    rg = r - g
    yb = 0.5 * (r + g) - b
    colorf = float(np.sqrt(rg.std() ** 2 + yb.std() ** 2) + 0.3 * np.sqrt(rg.mean() ** 2 + yb.mean() ** 2))
    p50, p95 = float(np.percentile(y, 50)), float(np.percentile(y, 95))
    hi = y >= p95
    lo = y <= p50
    return dict(median=p50, mean=float(y.mean()), p95=p95, p95_p50=p95 / max(p50, 1e-3), dark=dark, clip=clip,
                specks=int(specks), colorf=colorf, warm=float((r - b)[hi].mean()), cold=float((r - b)[lo].mean()))


def deck_stats(shot, mask_shot):
    """Median luma of `shot` under the green deck tops of `mask_shot` (same framing), and the snow outside the deck."""
    a, k = load(shot), load(mask_shot)
    if a.shape != k.shape:
        return None
    R, G, B = k[..., 0], k[..., 1], k[..., 2]
    # the mask's flat colours after the composite (tone curve, grade, vignette): deck green ≈ (91, 217, 37), snow blue,
    # icicles red; the void stays a dark navy (≈ (26, 46, 80)) and must not count as snow
    deck = (G > 140) & (G > R + 80) & (G > B + 100)
    snow = (B > 140) & (B > G + 80) & (B > R + 100)
    if deck.sum() < 1000:
        return None
    Y = 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]
    out = dict(deck_median=float(np.median(Y[deck])), deck_pct=float(deck.mean() * 100))
    if snow.any():
        # a snow pixel with no deck within 30 px (a box dilation of the deck by 30 px, separable max filter)
        d = deck.copy()
        for axis in (0, 1):
            acc = d.copy()
            for s in range(1, 31):
                acc |= np.roll(d, s, axis=axis) | np.roll(d, -s, axis=axis)
            d = acc
        out['snow_px'] = int(snow.sum())
        out['snow_off_deck'] = int((snow & ~d).sum())
    return out


rx_hb = re.compile(r'hb t=[0-9.]+ td=([0-9.-]+) fps=([0-9.]+) worst=(\d+)ms')
rx_shot = re.compile(r'demo punchin: shot started td=([0-9.]+)')
rx_dil = re.compile(r'cine punchin end dilation x([0-9.]+) for ([0-9.]+) s')


def punchin_entry(path, window):
    if not os.path.exists(path):
        return None
    start, worst, secs, dil = None, 0, 0, None
    lines = open(path, errors='replace').read().splitlines()
    for line in lines:
        m = rx_shot.search(line)
        if m and start is None:
            start = float(m.group(1))
        d = rx_dil.search(line)
        if d and dil is None:
            dil = (float(d.group(1)), float(d.group(2)))
    if start is None:
        return dict(start=None)
    for line in lines:
        m = rx_hb.search(line)
        if not m:
            continue
        td = float(m.group(1))
        # the heartbeat at td covers the second before it
        if start < td <= start + window + 1.0:
            worst = max(worst, int(m.group(3)))
            secs += 1
    return dict(start=start, worst=worst, seconds=secs, dilation=dil)


def fmt_range(r):
    lo, hi = r
    if lo is not None and hi is not None:
        return f'{lo:g}–{hi:g}'
    return f'≥ {lo:g}' if lo is not None else f'≤ {hi:g}'


def check(v, r):
    lo, hi = r
    return (lo is None or v >= lo) and (hi is None or v <= hi)


def main():
    args = sys.argv[1:]
    gate, golden, jout, only, fout = False, os.path.join(HERE, 'golden'), None, None, None
    while args and args[0].startswith('--'):
        a = args.pop(0)
        if a == '--gate':
            gate = True
        elif a == '--only':
            only = set(x for x in args.pop(0).split(',') if x)
        elif a == '--failed':
            fout = args.pop(0)
        elif a == '--golden':
            golden = args.pop(0)
        elif a == '--json':
            jout = args.pop(0)
    if len(args) != 1:
        print(__doc__)
        return 2
    res = args[0]
    cfg = json.load(open(os.path.join(golden, 'thresholds.json')))
    crop = cfg.get('crop', {})
    hud = cfg.get('hud_mask', [])
    failures, out, failed_shots = [], {'scenes': {}}, []
    print('LOOK (ci/look_metrics.py; gates: ci/golden/thresholds.json — HUD-off shots gated, HUD-on shots masked and reported)')
    for name, sc in cfg['scenes'].items():
        if only is not None and name not in only:
            continue
        shot = next((s for s in sc['shots'] if os.path.exists(os.path.join(res, s))), None)
        if not shot:
            print(f'{name:10s} no shot ({", ".join(sc["shots"])})')
            continue
        hud_off = '-nohud' in shot
        a = load(os.path.join(res, shot))
        m = region_mask(a.shape, crop, None if hud_off else hud)
        s = stats(a, m)
        row = dict(shot=shot, hud_off=hud_off, **s)
        if hud_off:
            for mk in sc.get('deck_mask', []):
                p = os.path.join(res, mk)
                if os.path.exists(p):
                    d = deck_stats(os.path.join(res, shot), p)
                    if d:
                        row.update(d)
                    break
        bad = []
        for k, r in sc.get('gates', {}).items():
            if k not in row:
                continue
            if not check(row[k], r):
                bad.append(f'{k} {row[k]:.2f} not {fmt_range(r)}')
        if 'snow_off_deck' in row and row['snow_off_deck'] > 0:
            bad.append(f'snow off deck {row["snow_off_deck"]} px')
        row['fails'] = bad
        out['scenes'][name] = row
        tag = 'gated' if hud_off else 'HUD on, masked: reported only'
        extra = ''
        if 'deck_median' in row:
            extra = f' deck {row["deck_median"]:.1f} ({row["deck_pct"]:.0f} % of frame)'
            if 'snow_px' in row:
                extra += f' snow {row["snow_px"]} px, {row["snow_off_deck"]} off deck'
        plan = f' (plan {fmt_range(sc["plan_median"])})' if 'plan_median' in sc else ''
        verdict = ('FAIL: ' + '; '.join(bad)) if bad else 'ok'
        if not hud_off:
            verdict = ('would fail: ' + '; '.join(bad)) if bad else 'in range'
        print(f'{name:10s} {shot:28s} median {s["median"]:5.1f}{plan} mean {s["mean"]:5.1f} p95 {s["p95"]:5.1f} '
              f'p95/p50 {s["p95_p50"]:4.2f} dark {s["dark"]:4.1f}% clip {s["clip"]:4.2f}% specks {s["specks"]:4d} '
              f'R-B hi {s["warm"]:+5.1f} lo {s["cold"]:+5.1f} colorf {s["colorf"]:4.1f}{extra} [{tag}] {verdict}')
        if bad and hud_off:
            failures.append(f'{name}: ' + '; '.join(bad))
            failed_shots.append(shot)
    # the brightness option at its maximum
    b = cfg.get('brightness')
    if b and (only is None or b['base'] in only):
        base = out['scenes'].get(b['base'])
        shot = next((s for s in b['shots'] if os.path.exists(os.path.join(res, s))), None)
        if base and shot:
            hud_off = '-nohud' in shot
            a = load(os.path.join(res, shot))
            m = region_mask(a.shape, crop, None if hud_off else hud)
            s = stats(a, m)
            key, ref, now = 'median', base['median'], s['median']
            lift = now - ref
            ok = lift >= b['min_lift'] and hud_off == base['hud_off']
            out['brightness'] = dict(shot=shot, gamma=b['gamma'], base=ref, bright=now, lift=lift)
            print(f'brightness gamma {b["gamma"]}: frame median {ref:.1f} → {now:.1f} (+{lift:.1f}, need ≥ +{b["min_lift"]}) '
                  f'[{"gated" if hud_off else "HUD on, reported only"}] {"ok" if ok else "FAIL"}')
            if not ok and hud_off:
                failures.append(f'brightness: +{lift:.1f} < +{b["min_lift"]}')
                failed_shots.append(shot)
        else:
            print('brightness: no shots')
    # the punch-in's entry
    p = cfg.get('punchin_entry')
    if p and only is None:
        e = punchin_entry(os.path.join(res, p['log']), p['window_s'])
        if e is None:
            print('punch-in entry: no log')
        elif e['start'] is None:
            print('punch-in entry: FAIL — no «demo punchin: shot started» line')
            failures.append('punch-in: never started')
        else:
            ok = e['worst'] <= p['max_tick_ms']
            dil = e['dilation']
            dtxt = f', dilation ×{dil[0]:.2f} for {dil[1]:.2f} s' if dil else ', no dilation line'
            print(f'punch-in entry: started td={e["start"]:.2f}, worst loop tick {e["worst"]} ms over {e["seconds"]} heartbeat s '
                  f'(need ≤ {p["max_tick_ms"]}){dtxt} {"ok" if ok else "FAIL"}')
            out['punchin_entry'] = e
            if not ok:
                failures.append(f'punch-in entry: worst tick {e["worst"]} ms > {p["max_tick_ms"]}')
    if fout:
        with open(fout, 'w') as f:
            f.write(''.join(x + '\n' for x in failed_shots))
    if jout:
        with open(jout, 'w') as f:
            json.dump(out, f, indent=1, ensure_ascii=False)
    if failures:
        print('LOOK GATE: ' + ('FAILED' if gate else 'would fail') + ' — ' + ' | '.join(failures))
    else:
        print('LOOK GATE: passed')
    return 1 if (gate and failures) else 0


if __name__ == '__main__':
    sys.exit(main())
