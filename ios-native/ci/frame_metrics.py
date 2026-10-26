#!/usr/bin/env python3
"""Frame metrics of the CI simulator demos (ios-native/.github workflow, sim-smoke job).

Reads results/app-<demo>.log for every demo named on the command line and prints one table:
  loop side  (what the app controls: simulation, input, HUD, audio on the main thread)
    avg / min fps over the measured window (from 1.2 s after "scene ready"), worst tick, and the loop hitches
    (ticks > 50 ms) at 1.2 s <= td <= the demo's length
  GPU side   (frames the GPU completed; on the simulator the host GPU stalls now and then)
    drawn avg / min per second, the longest time one image stayed up, the slowest command buffer (commit -> done)
  frame graph (WP1 «Кадр», `hb gpu` lines and the `metal: world target` allocation lines)
    gpu ema   median of the per-second smoothed GPU time per frame in the window (simulator: the host GPU — a tripwire
              for pathological regressions only, never a budget; device budgets are in Frame/RenderQuality.swift; the
              median, because a host stall inflates a command buffer's GPU span for a second or two)
    allocs    world-target allocations in the run (the targets are allocated once; dynamic resolution moves a viewport)
    drs       dynamic-resolution sweep steps logged (`quality: drs sweep step k/10`, the probe demo / -drsSweep)

Gate (exit 1 with --gate), the plan's common gate for every package:
  warm 60 Hz demos    loop avg >= 59.5, min >= 58 fps (>= 55 when the run's only long ticks are host stalls), worst
                      loop tick <= 43 ms, no loop hitch > 50 ms after 1 s
  menu demos (30 Hz)  no loop hitch
  host stalls         a long tick in which the app's main thread worked < 10 ms is the simulator host's, not the app's:
                      app work = upd + draw minus the time the thread spent off the CPU inside SKRenderer (hud − its cpu)
                      and inside the world encode (`metal: slow world encode N ms (thread cpu M ms)`, logged by
                      MetalRenderer for encodes > 2 ms; without such a line the encode took < 2 ms and the rest of
                      FrameLoop's `world` span is the thread waiting in makeCommandBuffer). Such ticks are listed (`host-stalls`), not counted as hitches
                      and not held to the worst-tick limit. A tick of 35–50 ms (no hitch line; under 44 ms it only
                      matters for the second's fps: e.g. sk=32ms with skcpu=1ms, the HUD thread off the CPU) counts as a host stall
                      when the app's own maxima in that heartbeat second (`hb ms … max`, the slowest HUD render's CPU
                      `skcpu=`, the main thread's drawable wait — at most 3 ms by design —, a world encode > 2 ms) add
                      up to < 10 ms
  cold first launch   worst loop tick <= --cold-max-ms; the renderer's share of the loading — the time the scene waited
                      for the Metal preload (`metal world ready in N ms`) less the simulator's shader-compiler start-up
                      (`first request N ms` beyond 0.3 s) — <= 0.5 s; the loading itself is reported against 1.6 s and
                      fails only beyond the warm median + 2.5 s (a tripwire: on a cold launch the simulator's host GPU
                      can return ~5 frames/s for seconds while the cover waits for 20 — the same commit 535ce21 loaded
                      in 1.43 s and in 2.73 s on two runs; the cover GPU frames/s are printed)
  gpu-drawn           avg >= 55 in --drawn-gated demos (swarm3x, release-combat); when the host GPU stalls on its own
                      (the same run's unloaded `calm` demo draws < 57/s) at least calm − 2
  host-stall seconds  when a demo misses avg / min fps or the drawn floor, the same numbers are taken again without the
                      heartbeat seconds the host stalled — a host-stall tick inside (loop side; ± 0.05 s, the heartbeat's
                      td= is printed to 0.1 s), or a command buffer that
                      took > 100 ms, over 10x the slowest frame's own GPU span (GPU side) — and pass if those
                      hold over >= 4 clean seconds and the demo has no app hitch (noted in the row)
  frame graph         simulator GPU ema <= --gpu-ema-max (1.0 ms); one world-target allocation per launch; a DRS
                      sweep (when present) has 10 steps and no second with a scale step has a loop tick > 34 ms that
                      the step can own: with that second's frames fast on the GPU (< 8 ms), a host-stall tick, or one
                      under 50 ms in a second where the app's own maxima add up to < 10 ms, is the host's; from any
                      other the second's maxima of the sections a scale step does not touch (sim, ev, cam, hud, au, the
                      HUD render's CPU, the drawable wait) are taken away first (the rest is reported as `step share`)
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
cold_renderer = 0.5
cold_tripwire = 2.5
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
rx_hitch_work = re.compile(r'upd=(\d+)ms draw=(\d+)ms(?: \(drawable \d+ world (\d+) hud (\d+) \(cpu (\d+)\))?')
rx_hitch_wall = re.compile(r'wall=([0-9.]+)')
rx_slow_enc = re.compile(r'metal: slow world encode (\d+) ms \(thread cpu ([0-9.]+) ms\) wall=([0-9.]+)')
rx_first_req = re.compile(r'pipelines built in \d+ ms \(.*first request (\d+) ms')
rx_ready_wait = re.compile(r'metal world ready in (\d+) ms')
rx_enc_log = re.compile(r'world encodes > (\d+) ms logged')
rx_hb_drawn = re.compile(r'hb t=[0-9.]+ .*?drawn=(\d+)')
rx_hb_skcpu = re.compile(r' skcpu=(\d+)ms')
rx_hb_drw = re.compile(r' drw=(\d+)ms')
rx_hb_max = re.compile(r'hb ms .*\| max (.*)$')
rx_hb_sec = re.compile(r'hb t=[0-9.]+ td=([0-9.-]+) fps=([0-9.]+) worst=\d+ms drawn=(\d+)')
rx_hb_gpumax = re.compile(r' gpumax=([0-9.]+)ms')
rx_hb_cbmax = re.compile(r' cbmax=(\d+)ms')
rx_cb = re.compile(r'cb=(\d+)ms')
rx_hb = re.compile(r'hb t=.* td=' + num + r' .*gap=' + num + r'ms.* cbmax=' + num + 'ms')
rx_hb_td = re.compile(r'hb t=' + num + ' td=' + num)
rx_gpu = re.compile(r'hb gpu frame=' + num + ' max=' + num + r'.*\| ema=' + num + r' tier=(\w+) scale=' + num)
rx_alloc = re.compile(r'metal: world target \d+x\d+ px')
rx_sweep = re.compile(r'quality: drs sweep step (\d+)/10')
rx_hb_worst = re.compile(r'hb t=[0-9.]+ td=[0-9.-]+ fps=[0-9.]+ worst=(\d+)ms')

rows, failed = [], []
gpu_avg = []
# median warm loading time of the run (a slow runner slows every launch; the cold launch adds the shader compile)
warm_loads = []
for d in demos:
    if d in cold:
        continue
    try:
        lm0 = rx_load.search(open(f'{results}/app-{d}.log', encoding='utf-8', errors='replace').read())
    except OSError:
        lm0 = None
    if lm0:
        warm_loads.append(float(lm0.group(1)))
warm_median = sorted(warm_loads)[len(warm_loads) // 2] if warm_loads else None
# frames the host GPU completed per second in the unloaded `calm` demo of the same run: when the host itself stalls
# (calm < 57/s) a gated demo has to draw no fewer than calm − 2, else 55
drawn_floor = 55.0
try:
    mc = rx_done.search(open(f'{results}/app-calm.log', encoding='utf-8', errors='replace').read())
    if mc and mc.group(5):
        drawn_floor = min(55.0, float(mc.group(5)) - 2)
except OSError:
    pass
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
    # slow world encodes: (wall stamp, ms off the CPU); the logging threshold of this build (None: older logs)
    el = rx_enc_log.search(text)
    enc_log_ms = float(el.group(1)) if el else None
    slow_enc = []
    for line in lines:
        e = rx_slow_enc.search(line)
        if e:
            slow_enc.append((float(e.group(3)), max(0.0, float(e.group(1)) - float(e.group(2)))))
    hitches, host_stalls, stall_tds = [], [], []
    for line in lines:
        h = rx_hitch.search(line)
        # (classified up to 1 s past the window: the app's own worst / min fps can include the tick that ends it)
        if not h or not (0.2 <= float(h.group(2)) <= secs + 1):
            continue
        # the app's own work in the long tick: update + draw, minus the time its thread was off the CPU inside
        # SKRenderer (hud wall − hud cpu) and inside the world encode (the slow-encode line logged in that tick)
        wk = rx_hitch_work.search(line)
        if wk:
            work = int(wk.group(1)) + int(wk.group(2))
            if wk.group(4) is not None:
                work -= max(0, int(wk.group(4)) - int(wk.group(5)))
            hw = rx_hitch_wall.search(line)
            if hw and wk.group(3) is not None:
                w = float(hw.group(1))
                off = [o for (t, o) in slow_enc if w - 0.3 <= t <= w + 0.01]
                if off:
                    work -= min(int(wk.group(3)), off[-1])
                elif enc_log_ms is not None:
                    # no slow-encode line in this tick: the encode itself took < enc_log_ms, the rest of FrameLoop's
                    # `world` span is the thread waiting in makeCommandBuffer
                    work -= max(0, int(wk.group(3)) - enc_log_ms)
            if work < 10:
                host_stalls.append(int(h.group(1)))
                stall_tds.append(float(h.group(2)))
                continue
        if not (1.2 <= float(h.group(2)) <= secs):
            continue
        cb = rx_cb.search(line)
        hitches.append((int(h.group(1)), float(h.group(2)), cb.group(1) if cb else '-'))
    # long ticks under the hitch threshold (no hitch line): a heartbeat second whose worst tick is 35–50 ms (one that drops
    # a frame at 60 Hz; under 44 ms it only matters for the second's fps, the worst-tick limit is 43; menus at 30 Hz from
    # 44 ms) while the
    # app's own maxima in that second — the `hb ms … max` sections, the slowest HUD render's CPU time (skcpu=), the
    # main thread's drawable wait (≤ 3 ms by design) and any logged world encode (> 2 ms) (`metal: slow world encode`) — add up
    # to < 10 ms was stalled by the host
    enc_in_second = 0.0
    for k, line in enumerate(lines):
        se = rx_slow_enc.search(line)
        if se:
            enc_in_second = max(enc_in_second, float(se.group(1)))
            continue
        hw = rx_hb_worst.search(line)
        if not hw:
            continue
        enc_max, enc_in_second = enc_in_second, 0.0
        if not ((43 if d in menus else 34) < int(hw.group(1)) <= 50):
            continue
        tdm = rx_hb_td.search(line)
        if not tdm or not (0.2 <= float(tdm.group(2)) <= secs):
            continue
        # (the HUD render's CPU time — its wall time beyond that is the thread off the CPU inside SKRenderer; the
        # drawable call runs on a queue the main thread waits on for at most 3 ms)
        sk, dw = rx_hb_skcpu.search(line), rx_hb_drw.search(line)
        work = (int(sk.group(1)) if sk else 99) + (min(3, int(dw.group(1))) if dw else 99)
        nxt = lines[k + 1] if k + 1 < len(lines) else ''
        mm = rx_hb_max.search(nxt)
        if mm is None:
            continue
        work += sum(int(v) for v in re.findall(r'=(\d+)', mm.group(1))) + enc_max
        if work < 10:
            host_stalls.append(int(hw.group(1)))
            stall_tds.append(float(tdm.group(2)) - 0.5)
    # per heartbeat second in the window: loop fps, GPU frames drawn, and whether the host stalled it — the loop (a host
    # stall tick inside the second) or the GPU (a command buffer waited > 50 ms while the slowest frame's own GPU time
    # stayed < 5 ms: the simulator host did not schedule it)
    per_sec = []
    for line in lines:
        b = rx_hb_sec.search(line)
        if not b:
            continue
        tsec = float(b.group(1))
        if not (1.2 <= tsec <= secs + 0.5):
            continue
        # (the heartbeat prints td= to 0.1 s, so the second it closes can end up to 0.05 s past the printed value: a
        # host-stall tick logged at td=15.32 belongs to the heartbeat printed «td=15.3» that counted it)
        loop_stall = any(tsec - 1.05 <= t0 <= tsec + 0.05 for t0 in stall_tds)
        gm, cm = rx_hb_gpumax.search(line), rx_hb_cbmax.search(line)
        gpu_stall = bool(gm and cm and float(cm.group(1)) > 100 and float(gm.group(1)) * 10 < float(cm.group(1)))
        per_sec.append((float(b.group(2)), int(b.group(3)), loop_stall, gpu_stall))
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
    td, emas, tiers, scales = -1.0, [], set(), set()
    for line in lines:
        t = rx_hb_td.search(line)
        if t:
            td = float(t.group(2))
        g = rx_gpu.search(line)
        if g:
            tiers.add(g.group(4))
            scales.add(g.group(5))
            if 1.2 <= td <= secs + 1:
                emas.append(float(g.group(3)))
    ema = sorted(emas)[len(emas) // 2] if emas else None
    allocs = sum(1 for line in lines if rx_alloc.search(line))
    sweep = max((int(s.group(1)) for line in lines for s in [rx_sweep.search(line)] if s), default=0)
    # the worst loop tick of each second that holds a DRS sweep step (the heartbeat after the step's line), and the part
    # of it the step can own. A scale step moves the viewport (MetalWorld.update → prepareViewport) and changes what the
    # world encode and the GPU draw; it does not touch the simulation, the event drain, the camera, the HUD or audio.
    # A long tick is the host's when the GPU drew that second's frames fast (slowest frame < 8 ms — a GPU-side cost of
    # the step would show there) and either it is a host-stall tick classified above, or — under the hitch line's 50 ms
    # — the app's own maxima in that second (every `hb ms … max` section, the HUD render's CPU, the drawable wait ≤ 3
    # ms, a logged world encode) add up to < 10 ms. From any other long tick the second's maxima of the sections the
    # step does not touch (sim, ev, cam, hud, au), the HUD render's CPU (skcpu=) and the drawable wait are taken away;
    # what remains — an upper bound of the step's own share — must stay ≤ 34 ms
    stall_pairs = list(zip(host_stalls, stall_tds))
    sweep_worst, sweep_own, sweep_host, sweep_other, pending, enc_sec = 0, 0, 0, 0, False, 0.0
    for k, line in enumerate(lines):
        se = rx_slow_enc.search(line)
        if se:
            enc_sec = max(enc_sec, float(se.group(1)))
            continue
        if rx_sweep.search(line):
            pending = True
            continue
        hw = rx_hb_worst.search(line)
        if not hw:
            continue
        enc_max, enc_sec = enc_sec, 0.0
        if not pending:
            continue
        pending = False
        w = int(hw.group(1))
        sweep_worst = max(sweep_worst, w)
        if w <= 34:
            sweep_own = max(sweep_own, w)
            continue
        tdm, gm = rx_hb_td.search(line), rx_hb_gpumax.search(line)
        t_end = float(tdm.group(2)) if tdm else None
        gpu_fast = gm is not None and float(gm.group(1)) < 8
        nxt = lines[k + 1] if k + 1 < len(lines) else ''
        mm = rx_hb_max.search(nxt)
        sk, dw = rx_hb_skcpu.search(line), rx_hb_drw.search(line)
        loop_other = (int(sk.group(1)) if sk else 99) + (min(3, int(dw.group(1))) if dw else 99)
        sections = dict((n, 0) for n in ('sim', 'ev', 'cam', 'hud', 'au'))
        app = None
        if mm:
            scene, _, world_sub = mm.group(1).partition(' / ')
            for n, v in re.findall(r'(\w+)=(\d+)', scene):
                if n in sections:
                    sections[n] += int(v)
            app = sum(int(v) for v in re.findall(r'=(\d+)', mm.group(1))) + loop_other + enc_max
        stalled = t_end is not None and any(abs(w - ms) <= 1 and t_end - 1.2 < t0 <= t_end + 0.05 for ms, t0 in stall_pairs)
        if gpu_fast and (stalled or (w <= 50 and app is not None and app < 10)):
            sweep_host += 1
            continue
        own = max(0, w - sum(sections.values()) - (loop_other if loop_other < 99 else 0))
        if own <= 34:
            sweep_other += 1
        sweep_own = max(sweep_own, own)
    worst_h = max((h[0] for h in hitches), default=0)
    if drawn_avg != '-' and d not in menus and d not in cold:
        gpu_avg.append((d, float(drawn_avg)))
    verdict = 'ok'
    bad, notes = [], []
    if d in cold:
        verdict = 'cold'
        # a cold first launch: its worst loop tick after the first second (looser limit) and its loading time
        if cold_max is not None and worst > cold_max:
            bad.append(f'cold worstFrame {worst:.0f} ms > {cold_max:.0f}')
        if lm:
            cl = float(lm.group(1))
            # what the renderer adds to a cold launch: the time the scene waited for the Metal preload (meshes +
            # pipelines), less what the simulator's shader compiler service spent starting up (first request > 0.3 s)
            fr, rw = rx_first_req.search(text), rx_ready_wait.search(text)
            wait = float(rw.group(1)) / 1000 if rw else 0.0
            svc = min(wait, max(0.0, float(fr.group(1)) / 1000 - 0.3)) if fr else 0.0
            own = wait - svc
            # GPU frames completed per second while the cover was up (it waits for 20 of them)
            drawn_cover = []
            for line in lines:
                if 'loading took' in line:
                    break
                hd = rx_hb_drawn.search(line)
                if hd:
                    drawn_cover.append(hd.group(1))
            note = f'renderer wait {own:.2f} s' + (f' + compiler start-up {svc:.2f} s' if svc > 0 else '') \
                + (f', cover GPU frames/s {"/".join(drawn_cover)}' if drawn_cover else '')
            if own > cold_renderer:
                bad.append(f'cold launch: the scene waited {own:.2f} s for the Metal preload (> {cold_renderer:.1f})')
            if cl > cold_load:
                if warm_median is not None and cl - warm_median > cold_tripwire:
                    bad.append(f'cold load {cl:.2f} s, {cl - warm_median:.2f} s over the warm median (> {cold_tripwire:.1f}; {note})')
                else:
                    verdict = f'cold {cl:.2f} s > {cold_load:.1f} on this runner ({note})'
            else:
                verdict = f'cold {cl:.2f} s ({note})'
    else:
        if d not in menus:
            # the loop's fps without the seconds a host stall fell into (only when the app's own numbers miss)
            clean = [f for (f, _, ls, _) in per_sec if not ls]
            excl = len(per_sec) - len(clean)
            c_avg = sum(clean) / len(clean) if clean else avg
            c_min = min(clean) if clean else mn
            if avg < 59.5 and not (excl and len(clean) >= 4 and c_avg >= 59.5 and not hitches):
                bad.append(f'avgFps {avg:.1f} < 59.5')
            if mn < 58 and not (excl and len(clean) >= 4 and c_min >= 58 and not hitches):
                bad.append(f'minFps {mn:.1f} < 58')
            if excl and (avg < 59.5 or mn < 58) and not hitches:
                notes.append(f'loop fps {c_avg:.1f} avg / {c_min:.0f} min without {excl} host-stall second(s)')
            # (a worst tick that is a host stall — no app work in it — is the simulator's, not the app's)
            if worst > 43 and not any(abs(worst - st) <= 1 for st in host_stalls):
                bad.append(f'worstFrame {worst:.0f} ms > 43')
        if hitches:
            bad.append(f'{len(hitches)} loop hitch(es) > 50 ms after 1 s, worst {worst_h} ms')
        if d in drawn_gated and drawn_avg != '-' and float(drawn_avg) < drawn_floor:
            # the frames drawn per second without the seconds the host GPU stalled
            gclean = [dr for (_, dr, _, gs) in per_sec if not gs]
            gex = len(per_sec) - len(gclean)
            g_avg = sum(gclean) / len(gclean) if gclean else 0
            if gex and len(gclean) >= 4 and g_avg >= drawn_floor:
                notes.append(f'gpu drawn {g_avg:.1f}/s without {gex} host-GPU-stall second(s)')
            else:
                bad.append(f'gpu drawn avg {float(drawn_avg):.1f} < {drawn_floor:.1f}')
    if ema is not None and ema > gpu_ema_max:
        bad.append(f'simulator gpu ema {ema:.2f} ms > {gpu_ema_max:.1f} (tripwire)')
    if allocs > 1:
        bad.append(f'{allocs} world-target allocations (want 1 per launch)')
    if sweep:
        if sweep < 10:
            bad.append(f'drs sweep stopped at step {sweep}/10')
        if sweep_own > 34:
            bad.append(f'drs sweep: a {sweep_worst} ms tick in a second with a scale step, up to {sweep_own} ms of it '
                       f'not the simulation / events / HUD (> 34)')
    if bad:
        verdict = 'FAIL: ' + '; '.join(bad)
        failed.append(f'{d}: ' + '; '.join(bad))
    elif notes:
        verdict += ' (' + '; '.join(notes) + ')'
    fg = (f'gpu ema {ema:.2f} ms' if ema is not None else 'gpu ema -') + f' allocs {allocs}' \
        + (f' tier {"/".join(sorted(tiers))} scale {"/".join(sorted(scales))}' if tiers else '') + (f' drs {sweep}/10 worst {sweep_worst} ms' if sweep else '') \
        + (f' (step share <= {sweep_own} ms' + (f', host {sweep_host}' if sweep_host else '')
           + (f', sim/events {sweep_other}' if sweep_other else '') + ')' if sweep and sweep_worst > 34 else '')
    rows.append((d, f'load {lm.group(1) if lm else "-"} s | loop avg {avg:.1f} min {mn:.1f} worst {worst:.0f} ms '
                    f'hitches {len(hitches)}' + (f' host-stalls {len(host_stalls)} ({max(host_stalls)} ms)' if host_stalls else '')
                    + f' | gpu drawn avg {drawn_avg} min {drawn_min} gap {gap} ms '
                    f'stall-s {stalls} cbmax {cbmax:.0f} ms | {fg} | {verdict}'))

w = max(len(r[0]) for r in rows) if rows else 10
for d, s in rows:
    print(f'{d:<{w}}  {s}')
# GPU side (report only except --drawn-gated: the simulator host's GPU stalls on its own, see the calm baseline)
low = [f'{d} {a:.1f}' for d, a in gpu_avg if a < 55]
print('\nGPU side (gated only in ' + ', '.join(sorted(drawn_gated)) + f', floor {drawn_floor:.1f}): drawn avg < 55/s in ' + (', '.join(low) if low else 'none')
      + (f' (calm baseline {dict(gpu_avg)["calm"]:.1f})' if 'calm' in dict(gpu_avg) else ''))
if failed:
    print('\nGATE: ' + ('FAILED' if gate else 'would fail') + '\n  ' + '\n  '.join(failed))
    sys.exit(1 if gate else 0)
print('\nGATE: passed')
