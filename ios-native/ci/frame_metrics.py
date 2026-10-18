#!/usr/bin/env python3
"""Frame metrics of the CI simulator demos (ios-native/.github workflow, sim-smoke job).

Reads results/app-<demo>.log for every demo named on the command line and prints one table:
  loop side  (what the app controls: simulation, input, HUD, audio on the main thread)
    avg / min fps over the measured window (from 1.2 s after "scene ready"), worst tick, and the loop hitches
    (ticks > 50 ms) at 1.2 s <= td <= the demo's length
  GPU side   (frames the GPU completed; on the simulator the host GPU stalls now and then)
    drawn avg / min per second, the longest time one image stayed up, the slowest command buffer (commit -> done)

Gate (exit 1 with --gate): every warm demo needs minFps >= 55 and no loop hitch > 50 ms after the first second;
menu demos (30 Hz by design) only the hitch rule; cold first launches only their worst loop tick (--cold-max-ms).
The GPU side is reported, not gated (the simulator host's GPU stalls on its own: see the calm baseline).
Usage: frame_metrics.py [--gate] [--menus a,b] [--cold a,b] [--cold-max-ms N] <results dir> <demo> [<demo> ...]
"""
import re
import sys

args = sys.argv[1:]
gate = False
menus, cold = set(), set()
cold_max = None
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
results, demos = args[0], args[1:]

num = r'(-?[0-9.]+)'
rx_done = re.compile(r'demo done after (\d+)s avgFps=' + num + ' minFps=' + num + ' worstFrame=' + num + 'ms'
                     r'(?: drawnAvg=' + num + ' drawnMin=' + num + ' worstGap=' + num + 'ms)?')
rx_load = re.compile(r'loading took ' + num + ' s')
rx_hitch = re.compile(r'hitch (\d+) ms td=' + num)
rx_cb = re.compile(r'cb=(\d+)ms')
rx_hb = re.compile(r'hb t=.* td=' + num + r' .*gap=' + num + r'ms.* cbmax=' + num + 'ms')

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
    hitches = []
    for line in text.splitlines():
        h = rx_hitch.search(line)
        if h and 1.2 <= float(h.group(2)) <= secs:
            cb = rx_cb.search(line)
            hitches.append((int(h.group(1)), float(h.group(2)), cb.group(1) if cb else '-'))
    # GPU-side stalls in the window: heartbeats whose longest gap between completed frames exceeded 50 ms
    stalls, cbmax = 0, 0.0
    for line in text.splitlines():
        b = rx_hb.search(line)
        if b and 1.2 <= float(b.group(1)) <= secs + 1:
            if float(b.group(2)) > 50:
                stalls += 1
            cbmax = max(cbmax, float(b.group(3)))
    worst_h = max((h[0] for h in hitches), default=0)
    if drawn_avg != '-' and d not in menus and d not in cold:
        gpu_avg.append((d, float(drawn_avg)))
    verdict = 'ok'
    if d in cold:
        verdict = 'cold'
        # a cold first launch: only its worst loop tick after the first second is held to a (looser) limit
        if cold_max is not None and worst > cold_max:
            verdict = f'FAIL: cold worstFrame {worst:.0f} ms > {cold_max:.0f}'
            failed.append(f'{d}: cold worstFrame {worst:.0f} ms > {cold_max:.0f}')
    else:
        bad = []
        if d not in menus and mn < 55:
            bad.append(f'minFps {mn:.1f} < 55')
        if hitches:
            bad.append(f'{len(hitches)} loop hitch(es) > 50 ms after 1 s, worst {worst_h} ms')
        if bad:
            verdict = 'FAIL: ' + '; '.join(bad)
            failed.append(f'{d}: ' + '; '.join(bad))
    rows.append((d, f'load {lm.group(1) if lm else "-"} s | loop avg {avg:.1f} min {mn:.1f} worst {worst:.0f} ms '
                    f'hitches {len(hitches)} | gpu drawn avg {drawn_avg} min {drawn_min} gap {gap} ms '
                    f'stall-s {stalls} cbmax {cbmax:.0f} ms | {verdict}'))

w = max(len(r[0]) for r in rows) if rows else 10
for d, s in rows:
    print(f'{d:<{w}}  {s}')
# GPU side (report only: the simulator host's GPU stalls on its own, see the calm baseline)
low = [f'{d} {a:.1f}' for d, a in gpu_avg if a < 55]
print('\nGPU side (report only): drawn avg < 55/s in ' + (', '.join(low) if low else 'none')
      + (f' (calm baseline {dict(gpu_avg)["calm"]:.1f})' if 'calm' in dict(gpu_avg) else ''))
if failed:
    print('\nGATE: ' + ('FAILED' if gate else 'would fail') + '\n  ' + '\n  '.join(failed))
    sys.exit(1 if gate else 0)
print('\nGATE: passed')
