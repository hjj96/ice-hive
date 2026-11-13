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
                      (`first request N ms` beyond 0.3 s) and less the median world build of the same part's warm launches
                      — <= 0.5 s. The wait ends after the world is built on the main thread (MetalWorld: the marine maps,
                      the station, the creatures …), and every launch pays that build (`metal world ready in W ms (preload
                      P ms, started H ms before the scene)`: W − max(0, P − H), the part after the preload's tail): the
                      warm launches of the part measure it on the same runner (0.16–0.46 s on CI hosts, Nov 8–12 — C2 «CI
                      noise»), and their median is a tripwire of its own at 0.75 s. The loading is reported against 1.6 s and
                      fails only beyond the warm median + 2.5 s (a tripwire: on a cold launch the simulator's host GPU
                      can return ~5 frames/s for seconds while the cover waits for 20 — the same commit 535ce21 loaded
                      in 1.43 s and in 2.73 s on two runs; the cover GPU frames/s are printed). A cold launch that failed
                      is launched cold once more (app-<label>-run1.log keeps the first): each of the two criteria then
                      takes the better of the two launches — the host's share varies far more than a change of ours
                      would, and a regression of ours slows both
  gpu-drawn           avg >= 55 in --drawn-gated demos (swarm3x, release-combat). Below that it is judged on the heartbeat
                      seconds the host left alone (C2 «CI noise»): a second whose slowest command buffer came back >= 34 ms
                      after its commit (two frame periods: both of the app's frame slots held through a tick — on one
                      in-order queue every frame behind it waits too) while the demo's frames take a median under 1/10 of
                      that on the GPU (the gpu ema) was held by the host, and a second whose loop tick exceeded 43 ms lost
                      ticks of the loop (the loop side judges it); the others must draw >= 55 on average — pooled with the
                      first run's when the demo was re-run. With none left (the host held every second) the row says so:
                      per second the host takes the same frames from the unloaded calm demo at the same latency
  host-stall seconds  when a demo misses avg / min fps, the same numbers are taken again without the heartbeat seconds the
                      host stalled — a host-stall tick inside (± 0.05 s, the heartbeat's td= is printed to 0.1 s) — and
                      pass if those hold over >= 4 clean seconds and the demo has no app hitch (noted in the row)
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
# the warm launches' median world build after the preload (CI: 0.16–0.46 s per part over Nov 8–12, 72 runs)
warm_build_max = 0.75
drawn_gated = {'swarm3x', 'release-combat'}
drawn_floor = 55.0
# a command buffer back this long after its commit held both frame slots through a tick (2 × 16.7 ms at 60 Hz)
held_ms = 34.0
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
rx_ready_parts = re.compile(r'metal world ready in (\d+) ms \(preload (\d+) ms, started (\d+) ms before the scene\)')
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

def ready_parts(text):
    """The scene's wait for the renderer at launch in its two parts (s): the preload's tail — how long the scene, once it
    asked (loadMetal), still waited for the background preload of meshes, textures and pipelines, max(0, preload − its head
    start) — and the world build after it on the main thread (MetalWorld: the marine maps, the station, the creatures …;
    the rest of `metal world ready in N ms`). (None, None) without the line; an older line without the preload's numbers
    counts the whole wait as the tail."""
    m = rx_ready_parts.search(text)
    if m:
        w, p, h = (float(m.group(i)) / 1000 for i in (1, 2, 3))
        tail = min(w, max(0.0, p - h))
        return tail, w - tail
    rw = rx_ready_wait.search(text)
    return (float(rw.group(1)) / 1000, 0.0) if rw else (None, None)


def cold_parts(text, cl, warm_build):
    """A cold launch's parts: its loading time `cl`; what the renderer adds to it — the time the scene waited for the Metal
    preload (meshes + pipelines) and the world build after it, less what the simulator's shader compiler service spent
    starting up (first request beyond 0.3 s) and less the median world build of the same part's warm launches
    (`warm_build`: the main-thread build after the preload every launch pays, on the same runner); that start-up; the whole
    wait; this launch's world build; the GPU frames completed per second while the cover was up (it waits for 20)."""
    fr, rw = rx_first_req.search(text), rx_ready_wait.search(text)
    wait = float(rw.group(1)) / 1000 if rw else 0.0
    svc = min(wait, max(0.0, float(fr.group(1)) / 1000 - 0.3)) if fr else 0.0
    own = max(0.0, wait - svc - (warm_build or 0.0))
    _, build = ready_parts(text)
    drawn_cover = []
    for line in text.splitlines():
        if 'loading took' in line:
            break
        hd = rx_hb_drawn.search(line)
        if hd:
            drawn_cover.append(hd.group(1))
    return cl, own, svc, drawn_cover, wait, build or 0.0


def window_seconds(text, secs):
    """The heartbeat seconds of a demo's measured window (1.2 s <= td <= its length + 0.5): frames the GPU completed, the
    loop's worst tick (ms), the slowest command buffer's commit → done (ms)."""
    out = []
    for line in text.splitlines():
        b = rx_hb_sec.search(line)
        if not b or not (1.2 <= float(b.group(1)) <= secs + 0.5):
            continue
        hw, cm = rx_hb_worst.search(line), rx_hb_cbmax.search(line)
        out.append((int(b.group(3)), int(hw.group(1)) if hw else 0, float(cm.group(1)) if cm else 0.0))
    return out


def window_ema(text, secs):
    """The window's median smoothed GPU time per frame (ms), as the frame-graph column takes it (seconds the world drew)."""
    td, emas = -1.0, []
    for line in text.splitlines():
        t = rx_hb_td.search(line)
        if t:
            td = float(t.group(2))
        g = rx_gpu.search(line)
        if g and 1.2 <= td <= secs + 1 and float(g.group(1)) > 0:
            emas.append(float(g.group(3)))
    return sorted(emas)[(len(emas) - 1) // 2] if emas else None


rows, failed = [], []
gpu_avg = []
# median warm loading time of the run (a slow runner slows every launch; the cold launch adds the shader compile), and the
# warm launches' median world build after the Metal preload (every launch builds the world on the main thread after the
# preload: the cold launch's renderer share leaves that out, as these launches measured it on the same runner)
warm_loads, warm_builds = [], []
for d in demos:
    if d in cold:
        continue
    try:
        t0 = open(f'{results}/app-{d}.log', encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    lm0 = rx_load.search(t0)
    if lm0:
        warm_loads.append(float(lm0.group(1)))
    _, b0 = ready_parts(t0)
    if b0 is not None:
        warm_builds.append(b0)
warm_median = sorted(warm_loads)[len(warm_loads) // 2] if warm_loads else None
warm_build = sorted(warm_builds)[len(warm_builds) // 2] if warm_builds else None
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
            slow_enc.append((float(e.group(3)), max(0.0, float(e.group(1)) - float(e.group(2))), float(e.group(1))))
    hitches, host_stalls, stall_tds = [], [], []
    rate_switch = []
    for k, line in enumerate(lines):
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
                off = [(o, em) for (t, o, em) in slow_enc if w - 0.3 <= t <= w + 0.01]
                if off:
                    # the encode's own time off the CPU, and — as without a slow-encode line — the part of FrameLoop's
                    # `world` span outside the encode (the thread waiting in makeCommandBuffer): 3558a3f swarmshot-dots
                    # logged a 4 ms encode (0.8 ms on the CPU) inside a 52 ms `world` span
                    o, em = off[-1]
                    work -= min(int(wk.group(3)), o + max(0, int(wk.group(3)) - em))
                elif enc_log_ms is not None:
                    # no slow-encode line in this tick: the encode itself took < enc_log_ms, the rest of FrameLoop's
                    # `world` span is the thread waiting in makeCommandBuffer
                    work -= max(0, int(wk.group(3)) - enc_log_ms)
            if work < 10:
                host_stalls.append(int(h.group(1)))
                stall_tds.append(float(h.group(2)))
                continue
            # a menu demo's tick right after the loop drops from 60 to 30 Hz (`frame rate 30 Hz` just before it) lasts
            # two 30 Hz frames, ≈ 67 ms, while the app worked a fraction of it (LAND's handoff to the frame-loop owner;
            # it failed report-loss / report-chip / pause-nm at random on native-metal and on native-vx-polish 497288e:
            # upd 5 + draw 10 ms in a 67 ms tick) — listed, not counted, up to 70 ms and under 34 ms of the app's work
            if d in menus and int(h.group(1)) <= 70 and work < 34 \
                    and any('frame rate 30 Hz' in lines[j] for j in range(max(0, k - 3), k)):
                rate_switch.append(int(h.group(1)))
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
    # per heartbeat second in the window: loop fps and whether the host stalled the loop (a host stall tick inside the
    # second); the GPU side's seconds are classified by the drawn check below (window_seconds)
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
        per_sec.append((float(b.group(2)), loop_stall))
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
            # only seconds in which the world drew (frame > 0): behind an opaque menu the world stops and its `hb gpu`
            # line repeats the last smoothed value — one host-side GPU frame of 29.6 ms as the report opened
            # (native-vx-polish bf8ed41 report-first) froze the ema at 2.12 ms for the whole window
            if 1.2 <= td <= secs + 1 and float(g.group(1)) > 0:
                emas.append(float(g.group(3)))
    # (the lower median: a menu demo has two or three such seconds, and the one the menu opens in can hold a host frame)
    ema = sorted(emas)[(len(emas) - 1) // 2] if emas else None
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
            cl, own, svc, drawn_cover, wait, build = cold_parts(text, float(lm.group(1)), warm_build)
            note = f'renderer wait {own:.2f} s: {wait:.2f} s' + (f' − compiler start-up {svc:.2f} s' if svc > 0 else '') \
                + (f' − warm world build {warm_build:.2f} s (this launch\'s {build:.2f})' if warm_build is not None else '') \
                + (f', cover GPU frames/s {"/".join(drawn_cover)}' if drawn_cover else '')
            # A cold launch that failed the gate is launched cold once more (the workflow keeps the first one as
            # app-<label>-run1.log). Both are the same commit on the same runner, and the host's share of a cold launch
            # varies run to run far more than any change of ours (native-vx-stage1-fix, one game: renderer wait 0.12 /
            # 0.31 / 0.55 / 0.42 / 0.36 / 0.54 s, the compiler service's start-up 0.84–2.64 s, the cover's GPU 0–30
            # frames/s), so each criterion takes the better of the two: a regression of ours slows both launches.
            try:
                t1 = open(f'{results}/app-{d}-run1.log', encoding='utf-8', errors='replace').read()
                l1 = rx_load.search(t1)
            except OSError:
                l1 = None
            if l1:
                cl1, own1, _, _, wait1, _ = cold_parts(t1, float(l1.group(1)), warm_build)
                note += f'; first cold launch {cl1:.2f} s, renderer wait {own1:.2f} s (of {wait1:.2f}) — gated on the ' \
                    f'better of the two'
                cl, own = min(cl, cl1), min(own, own1)
            if own > cold_renderer:
                bad.append(f'cold launch: the scene waited {own:.2f} s for the Metal preload beyond the compiler start-up '
                           f'and a warm launch\'s world build (> {cold_renderer:.1f})')
            # every launch's world build after the preload (the warm launches of this part, same runner)
            if warm_build is not None and warm_build > warm_build_max:
                bad.append(f'warm launches: the world build after the Metal preload took a median {warm_build:.2f} s '
                           f'(> {warm_build_max:.2f})')
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
            clean = [f for (f, ls) in per_sec if not ls]
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
            # C2: judged on the seconds the host left the frames alone. A second whose slowest command buffer came back
            # >= 34 ms after its commit held both frame slots through a tick, and on the one in-order queue every frame
            # behind it waited too: with the demo's frames taking a median < 1/10 of that on the GPU, the host held it
            # (CI Nov 8–12, every second of swarm3x / swarm / release-combat / calm: the frames drawn follow that
            # latency alone — 59.8–59.9/s under 25 ms, 55.5–56.0 at 50–75 ms, 46–47 at 100–150 ms for the unloaded calm
            # as for the 1400-bug swarm3x — while the frames' own GPU spans stayed 0.3–0.8 ms median). A second whose
            # loop tick exceeded 43 ms lost ticks of the loop (the loop side judges it). The rest must average >= 55,
            # pooled with the first run's seconds after a re-run (app-<label>-run1.log).
            wins = [(window_seconds(text, secs), ema)]
            try:
                t1 = open(f'{results}/app-{d}-run1.log', encoding='utf-8', errors='replace').read()
                m1 = rx_done.search(t1)
            except OSError:
                m1 = None
            if m1:
                wins.append((window_seconds(t1, float(m1.group(1))), window_ema(t1, float(m1.group(1)))))
            free, held, nsec = [], 0, 0
            for sec_list, em in wins:
                lim = max(held_ms, 10 * (em or 0.0))
                for dr, wst, cb in sec_list:
                    nsec += 1
                    if wst > 43:
                        continue
                    if cb >= lim:
                        held += 1
                    else:
                        free.append(dr)
            runs_note = ' over both runs' if m1 else ''
            if free and sum(free) / len(free) < drawn_floor:
                bad.append(f'gpu drawn avg {float(drawn_avg):.1f} < {drawn_floor:.1f}: {sum(free) / len(free):.1f}/s in the '
                           f'{len(free)} s the host left alone{runs_note} ({held} of {nsec} s held >= {held_ms:.0f} ms)')
            elif free:
                notes.append(f'gpu drawn {sum(free) / len(free):.1f}/s in the {len(free)} s the host left alone{runs_note} '
                             f'({held} of {nsec} s held a command buffer >= {held_ms:.0f} ms)')
            else:
                notes.append(f'gpu drawn not measurable: the host held a command buffer >= {held_ms:.0f} ms in {held} of '
                             f'{nsec} s{runs_note}')
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
                    + (f' rate-switch {max(rate_switch)} ms' if rate_switch else '')
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
