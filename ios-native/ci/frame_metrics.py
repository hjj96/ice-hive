#!/usr/bin/env python3
"""Frame metrics of the CI simulator demos (ios-native/.github workflow, sim-smoke job).

Reads results/app-<demo>.log for every demo named on the command line and prints one table:
  loop side  (what the app controls: simulation, input, HUD, audio on the main thread)
    avg / min fps over the measured window (from 1.2 s after "scene ready"), worst tick, and the loop hitches
    (ticks > 50 ms) at 1.2 s <= td <= the demo's length
  GPU side   (frames the GPU completed; on the simulator the host GPU stalls now and then)
    drawn avg / min per second, the longest time one image stayed up, the slowest command buffer (commit -> done)
  frame graph (WP1 «Кадр», `hb gpu` lines and the `metal: world target` allocation lines)
    gpu ema   worst smoothed GPU time per frame in the window (simulator: the host GPU — a tripwire for pathological
              regressions only, never a budget; device budgets are in Frame/RenderQuality.swift)
    allocs    world-target allocations in the run (the targets are allocated once; dynamic resolution moves a viewport)
    drs       dynamic-resolution sweep steps logged (`quality: drs sweep step k/10`, the probe demo / -drsSweep)

Gate (exit 1 with --gate), the plan's common gate for every package:
  warm 60 Hz demos    loop avg >= 59.5, min >= 58 fps, worst loop tick <= 43 ms (unless that tick is a logged host stall:
                      a hitch line whose app work, upd + draw, is < 10 ms), no loop hitch > 50 ms after 1 s
  menu demos (30 Hz)  no loop hitch
  cold first launch   worst loop tick <= --cold-max-ms, loading <= --cold-load-s (1.6 s)
  gpu-drawn           avg >= 55 in --drawn-gated demos (swarm3x, release-combat)
  frame graph         simulator GPU ema <= --gpu-ema-max (1.0 ms); one world-target allocation per launch; a DRS
                      sweep (when present) has 10 steps and its run's worst loop tick <= 34 ms
Usage: frame_metrics.py [--gate] [--menus a,b] [--cold a,b] [--cold-max-ms N] [--cold-load-s S] [--drawn-gated a,b]
                        [--gpu-ema-max MS] <results dir> <demo> [<demo> ...]
"""
import re
import sys

args = sys.argv[1:]
gate = False
menus, cold = set(), set()
cold_max = None
cold_load = 1.6
drawn_gated = {'swarm3x', 'release-combat'}
gpu_ema_max = 1.0
while args and args[0].startswith('--'):
    a = args.pop(0)
    if a == '--gate':
        gate = True
    elif a == '--menus':
        menus = set(args.pop(0).split(','))
    elif a == '--cold':
        cold = set(args.pop(0).split(','))
    elif a == '--cold-max-ms':
        cold_max = float(args.pop(0))
    elif a == '--cold-load-s':
        cold_load = float(args.pop(0))
    elif a == '--drawn-gated':
        drawn_gated = set(x for x in args.pop(0).split(',') if x)
    elif a == '--gpu-ema-max':
        gpu_ema_max = float(args.pop(0))
results, demos = args[0], args[1:]

num = r'(-?[0-9.]+)'
rx_done = re.compile(r'demo done after (\d+)s avgFps=' + num + ' minFps=' + num + ' worstFrame=' + num + 'ms'
                     r'(?: drawnAvg=' + num + ' drawnMin=' + num + ' worstGap=' + num + 'ms)?')
rx_load = re.compile(r'loading took ' + num + ' s')
rx_hitch = re.compile(r'hitch (\d+) ms td=' + num)
rx_hitch_work = re.compile(r'upd=(\d+)ms draw=(\d+)ms')
rx_cb = re.compile(r'cb=(\d+)ms')
rx_hb = re.compile(r'hb t=.* td=' + num + r' .*gap=' + num + r'ms.* cbmax=' + num + 'ms')
rx_hb_td = re.compile(r'hb t=' + num + ' td=' + num)
rx_gpu = re.compile(r'hb gpu frame=' + num + ' max=' + num + r'.*\| ema=' + num + r' tier=(\w+) scale=' + num)
rx_alloc = re.compile(r'metal: world target \d+x\d+ px')
rx_sweep = re.compile(r'quality: drs sweep step (\d+)/10')

rows, failed = [], []
gpu_avg = []
for d in demos:
    try:
        text = open(f'{results}/app-{d}.log', encoding='utf-8', errors='replace').read()
    except OSError:
        rows.append((d, 'no log'))
        failed.append(f'{d}: no log')
        continue
    m = rx_done.search(text)
    lm = rx_load.search(text)
    if not m:
        rows.append((d, 'no "demo done" line'))
        failed.append(f'{d}: no demo done')
        continue
    secs = float(m.group(1))
    avg, mn, worst = float(m.group(2)), float(m.group(3)), float(m.group(4))
    drawn_avg = m.group(5) or '-'
    drawn_min = m.group(6) or '-'
    gap = m.group(7) or '-'
    lines = text.splitlines()
    hitches, host_stalls = [], []
    for line in lines:
        h = rx_hitch.search(line)
        if h and 1.2 <= float(h.group(2)) <= secs:
            cb = rx_cb.search(line)
            hitches.append((int(h.group(1)), float(h.group(2)), cb.group(1) if cb else '-'))
        # a long tick in which the app itself worked < 10 ms (update + draw): the simulator host did not schedule it
        wk = rx_hitch_work.search(line) if h else None
        if h and wk and int(wk.group(1)) + int(wk.group(2)) < 10 and 0.2 <= float(h.group(2)) <= secs:
            host_stalls.append(int(h.group(1)))
    # GPU-side stalls in the window: heartbeats whose longest gap between completed frames exceeded 50 ms
    stalls, cbmax = 0, 0.0
    for line in lines:
        b = rx_hb.search(line)
        if b and 1.2 <= float(b.group(1)) <= secs + 1:
            if float(b.group(2)) > 50:
                stalls += 1
            cbmax = max(cbmax, float(b.group(3)))
    # frame graph: worst GPU ema in the window (an `hb gpu` line follows its loop heartbeat), tier / scale seen,
    # world-target allocations, DRS sweep steps
    td, ema, tiers, scales = -1.0, None, set(), set()
    for line in lines:
        t = rx_hb_td.search(line)
        if t:
            td = float(t.group(2))
        g = rx_gpu.search(line)
        if g:
            tiers.add(g.group(4))
            scales.add(g.group(5))
            if 1.2 <= td <= secs + 1:
                ema = max(ema or 0.0, float(g.group(3)))
    allocs = sum(1 for line in lines if rx_alloc.search(line))
    sweep = max((int(s.group(1)) for line in lines for s in [rx_sweep.search(line)] if s), default=0)
    worst_h = max((h[0] for h in hitches), default=0)
    if drawn_avg != '-' and d not in menus and d not in cold:
        gpu_avg.append((d, float(drawn_avg)))
    verdict = 'ok'
    bad = []
    if d in cold:
        verdict = 'cold'
        # a cold first launch: its worst loop tick after the first second (looser limit) and its loading time
        if cold_max is not None and worst > cold_max:
            bad.append(f'cold worstFrame {worst:.0f} ms > {cold_max:.0f}')
        if lm and float(lm.group(1)) > cold_load:
            bad.append(f'cold load {float(lm.group(1)):.2f} s > {cold_load:.1f}')
    else:
        if d not in menus:
            if avg < 59.5:
                bad.append(f'avgFps {avg:.1f} < 59.5')
            if mn < 58:
                bad.append(f'minFps {mn:.1f} < 58')
            # (a worst tick that is a logged host stall — no app work in it — is the simulator's, not the app's)
            if worst > 43 and not any(abs(worst - st) <= 1 for st in host_stalls):
                bad.append(f'worstFrame {worst:.0f} ms > 43')
        if hitches:
            bad.append(f'{len(hitches)} loop hitch(es) > 50 ms after 1 s, worst {worst_h} ms')
        if d in drawn_gated and drawn_avg != '-' and float(drawn_avg) < 55:
            bad.append(f'gpu drawn avg {float(drawn_avg):.1f} < 55')
    if ema is not None and ema > gpu_ema_max:
        bad.append(f'simulator gpu ema {ema:.2f} ms > {gpu_ema_max:.1f} (tripwire)')
    if allocs > 1:
        bad.append(f'{allocs} world-target allocations (want 1 per launch)')
    if sweep:
        if sweep < 10:
            bad.append(f'drs sweep stopped at step {sweep}/10')
        if worst > 34:
            bad.append(f'drs sweep run worstFrame {worst:.0f} ms > 34')
    if bad:
        verdict = 'FAIL: ' + '; '.join(bad)
        failed.append(f'{d}: ' + '; '.join(bad))
    fg = (f'gpu ema {ema:.2f} ms' if ema is not None else 'gpu ema -') + f' allocs {allocs}' \
        + (f' tier {"/".join(sorted(tiers))} scale {"/".join(sorted(scales))}' if tiers else '') + (f' drs {sweep}/10' if sweep else '')
    rows.append((d, f'load {lm.group(1) if lm else "-"} s | loop avg {avg:.1f} min {mn:.1f} worst {worst:.0f} ms '
                    f'hitches {len(hitches)} | gpu drawn avg {drawn_avg} min {drawn_min} gap {gap} ms '
                    f'stall-s {stalls} cbmax {cbmax:.0f} ms | {fg} | {verdict}'))

w = max(len(r[0]) for r in rows) if rows else 10
for d, s in rows:
    print(f'{d:<{w}}  {s}')
# GPU side (report only except --drawn-gated: the simulator host's GPU stalls on its own, see the calm baseline)
low = [f'{d} {a:.1f}' for d, a in gpu_avg if a < 55]
print('\nGPU side (gated only in ' + ', '.join(sorted(drawn_gated)) + '): drawn avg < 55/s in ' + (', '.join(low) if low else 'none')
      + (f' (calm baseline {dict(gpu_avg)["calm"]:.1f})' if 'calm' in dict(gpu_avg) else ''))
if failed:
    print('\nGATE: ' + ('FAILED' if gate else 'would fail') + '\n  ' + '\n  '.join(failed))
    sys.exit(1 if gate else 0)
print('\nGATE: passed')
