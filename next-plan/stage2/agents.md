# Stage 2 «Manifold» — orchestration log (rebuilt Nov 14 after the machine reset; the old log was lost)

## State before the reset (from the orchestrator's memory)
- native = 0c861b4 (Stage 1 as reviewed). native-metal = a174327.
- Landed on native-metal, in order: C1 ci-split 3924aee · B1 boss-core e1c14ea · Stage 1 review a047ef5 · M1
  missions-length 8da373d · B4 threader-core c9a2e7d · H1 hud-queue + C2 ci-noise (CI results diet) d4119f7 (fast-forwarded
  by the orchestrator) · B2 threader-asset a174327.
- Calibration baselines (seven md5s): see ctx.md.
- Repository: ~89 GiB, «approaching its size quota»; result sets ~130 MB since the diet; pushes to native-metal / native
  start no CI. Owner question pending since Nov 13 ~09:40: prune old ci-results history? — do nothing without «да».
- In flight at the reset: B3 boss-intro (origin 76fbeed; run 43472168024 sim-smoke (b) FAILED), V1 overhead-read
  (origin b4b9481; run 43479066946 sim-smoke (b) CANCELLED, (a) green), B5 threader-game (origin 52f84da; run 43480686191
  build CANCELLED), D1 dig-in (nothing pushed — lost). All four agents had stopped on the usage limit (~18:00–19:00 UTC
  Nov 13, reset 20:30) before the machine was replaced (~01:10 UTC Nov 14).
- Notes for later prompts:
  - D1: a gated template joins MissionCalib.preset (default `missions`) — own preset name + CI step (B4).
  - B5 (in prompts/B5.md): H1's HUD.keep / ToastThing notes; B2's lantern socket vs B4's ThreaderView.lantern.
  - S1/S2: the ride's moving deck is not .hold — add its shape to HUD.keep (H1); dynamic walk grid and blocked route
    edges are reusable (B4).
  - C2 open issues: look gate's punch-in single-tick (≤ 34 ms) host flake; cold-load tripwire re-runs; stale tracked
    ios-native/ci/__pycache__/*.pyc; `end` demo switch-tick rule.
  - Idea for the owner: banners outside the hold still sit at 30 % height (H1) — a one-line change.
- Lanes: critical B5 → Stage 2 review → film; second lane D1 → S1 → S2.

## Nov 14 ~01:10 UTC — the reset
- Lost: old scratchpad (design.md / tech.md, Stage 1 + B1 / C1 / M1 reports, deliverables, Blender venv, Swift
  toolchain swiftdl), all worktrees, unpushed commits, the agents' transcripts (agents cannot be resumed).
- Recovered from the orchestrator's transcript: reports B4, B2, H1, C2; briefs B3, V1, B5, D1; packages.md (intro + B5,
  D1, S1, S2); ctx.md rebuilt (adds the wip/ backup rule and the reset map to README sections).
- Clone: fresh full clone at /home/user/ice-hive (main); fetch refspec now excludes ci-results; promisor blob:none for new
  fetches; gc off. git push works; gh API calls work (gh auth status complains).
- download.swift.org is blocked (CONNECT 403); no apt swiftlang on noble → no local Swift until the owner allows the host.

## Nov 14 ~01:40 UTC — restarted agents
- B3 boss-intro a87b0b9ccc4054f3a (continue from 76fbeed; diagnose run 43472168024 part b failure).
- V1 overhead-read a97df8cf18281fdbf (continue from b4b9481; part b cancel likely host; rebuild deliverables).
- B5 threader-game a7f227a7f3356967f (continue from 52f84da; never built on CI yet).
- D1 dig-in a8b870fd20cda4046 (from scratch on a174327; CI as compiler until a Swift toolchain exists).
- Plan docs backed up to the repo branch wip/stage2-plan (no CI on wip/*).
