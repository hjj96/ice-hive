# Stage 2 «Manifold» — shared rules for every package agent (rebuilt Nov 14 after a machine reset)

## The project
ICE HIVE: an original landscape-only iPhone horde shooter. Native Swift; the world is drawn with Metal, the HUD and
menus are a SpriteKit scene in the same Metal pass; the game is English-only. Repository github.com/hjj96/ice-hive
(public); the app is ios-native/: App/Sources (Metal/, Game/, UI/), IceHiveCore (the deterministic simulation and its
calibration), tools/blender (the asset pipeline), ci/ (CI scripts). Goal: an App Store release. Never use or imitate the
names DarkSwarm, Bitfire or Chryos. No model names or model identifiers anywhere in the repository (code, comments,
commit messages, README).

## The reset of Nov 14 — read this first
Around 01:10 UTC on Nov 14 the machine was replaced. Every local file was lost: the old scratchpad (next-plan: the
Stage 2 design docs design.md / tech.md, the Stage 1 reports R0–R7 / review / film, the Stage 2 reports B1 / C1 / M1,
every owner deliverable), the Blender venv, the local Swift typecheck toolchain, all worktrees and every commit that had
not been pushed. What survived: GitHub (every pushed branch, ci-results); ios-native/README.md, which has a section per
package with its systems, numbers and handoffs («Передача …»); the reports recovered into next-plan/stage2/reports/
(B4, B2, H1, C2); the package briefs in next-plan/stage2/prompts/; the package descriptions in
next-plan/stage2/packages.md. (All next-plan paths are under
/tmp/claude-0/-home-user/541c4a39-d6f7-5a78-a46f-07211ae92b10/scratchpad/next-plan/.)
When a brief points to a file that is gone, read this instead:
- R1 → README «Миссии: план из модулей (R1, native-vx-missions-core)»; R2 → «Верхний ярус: ядро»; R3 → «Верхний ярус:
  вид»; R4 → «Верхний ярус: жуки»; R0 → «Правки по фильму»; R6 → «Интерактивы: клапаны, свет, шкафчики»; R5 →
  «"Кельвин-9" Mk II»; R7 → «Миссии I: "Breaker Run", "Vent Purge"»; the Stage 1 review → «Ревью Stage 1 "Overhead"»;
  C1 → «CI: sim-smoke в две части»; B1 → «Каркас боссов (native-vx-boss-core, Stage 2 B1)»; M1 → «Миссии I в полную
  длину»; B4 / B2 / H1 / C2 → their recovered reports and README sections.
- design.md / tech.md (the Threader and the Manifold §1.5, mission variety §1.6, Dig In, Shaft 9, bosses tech §5): the
  package description in packages.md and your brief, plus the code that implements the design as tuned (B4's
  GameThreader.swift, GameThreaderAI.swift, Manifold.swift; B2's assets). Where the design is now silent, decide inside
  your package's lines and say so in your report.
- the Stage 1 film's frames: re-shoot them from CI (every scene is a demo).

## Where native-metal is
native-metal is 196efb2 (Nov 14 ~04:20). Landed in order: C1 3924aee · B1 e1c14ea · the Stage 1 review a047ef5 · M1 8da373d · B4 c9a2e7d · H1 + C2 (the CI results diet) d4119f7 · B2 a174327 · B3 «Boss intro and boss name» d42e2a6 (report reports/B3.md) · D1 «Dig In» 196efb2 (report reports/D1.md; its preset `holdout`). native is 0c861b4 (Stage 1 as reviewed). Merge origin/native-metal whenever it moves.

## Git and branches
- /home/user/ice-hive is the shared clone (main is checked out — never edit, commit or check out anything there). It is
  a full clone whose fetch refspec EXCLUDES ci-results (`^refs/heads/ci-results`); new fetches are blob-less (promisor,
  filter blob:none); gc and maintenance are off — never run git gc or repack. NEVER fetch ci-results (≈ 90 GB). Fetch
  named branches only: git -C /home/user/ice-hive fetch origin native-metal <your branch>.
- Your worktree: git -C /home/user/ice-hive worktree add /home/user/ice-hive-vx/<slug> -b native-vx-<slug> <base>
  (to continue a pushed branch, use origin/native-vx-<slug> as the base). Work only there, with git -C <path>.
- Push only your own branch native-vx-<slug> and your backup branch. Never push to main or native; never force-push;
  never rewrite pushed history (merge, do not rebase). native-metal moves only by fast-forward
  (git push origin HEAD:native-metal) to a head that is green on your branch and contains origin/native-metal; if that
  push is rejected, merge origin/native-metal again and run CI again when the merge brought changes.
- BACKUP (new after the reset): local commits die with the machine. After every significant step and before every long
  wait, push your HEAD to wip/native-vx-<slug> (git push origin HEAD:refs/heads/wip/native-vx-<slug>). CI does not run on
  wip/* and it costs no results space. Keep it a fast-forward of your own history.
- Every commit message ends with exactly these two lines:
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01MsBWwZ33zyWdAdE8yfSazp

## CI
- .github/workflows/native-ios.yml runs on pushes to native-vx-* (not native-metal, native or wip/*): core-tests (unit
  tests and the calibration gates), build, assets (gates.py: every shipped asset against assets.md5), sim-smoke (a) — the
  world — and (b) — title, menus, layout runs (the labels in SMOKE_B) — each ≤ 60 min, and report (merges the parts, the
  look gate, publishes ci-results/<branch>/<sha7>/, status.json last). A run takes ~45–70 min, more when the macOS pool is
  busy. A push cancels your branch's run in progress.
- Job re-runs are impossible from here (403). A run that fails only on host noise (a frame-gate row, a look re-shoot, a
  lost runner, a part hitting its 60-min limit) needs a new push with a REAL change — batch your next change; never
  push an empty commit.
- Reading results: gh run list -R hjj96/ice-hive --branch <b>; gh run view <id> -R hjj96/ice-hive --json jobs (gh API
  calls work even though `gh auth status` complains; artifact downloads are blocked). Files:
  curl -sS https://raw.githubusercontent.com/hjj96/ice-hive/ci-results/<branch>/<sha7>/<file> — status.json,
  core-tests.log, calib*.txt / calib*.jsonl, metrics.txt, gate-run1.txt, gate-reruns.txt, look.txt, verify.txt, v11.txt,
  assets.txt, app-<demo>.log, shots <demo>-<s>s.jpg (JPEG since C2), bursts burst-<name>.mp4 (one H.264 clip per burst;
  frame NN = video frame NN: ffmpeg -i burst-<name>.mp4 -start_number 0 f-%02d.png). List a folder with
  gh api "repos/hjj96/ice-hive/contents/<branch>/<sha7>?ref=ci-results" (a big folder can answer 500 — then fetch the
  files you need by name). Older runs keep PNG shots and frame JPEGs. A native-metal sha's results live in the folder of
  the package branch that tested it.
- Waiting: poll in a background Bash with run_in_background and timeout 7200000 (the 30-min default kills a background
  wait), e.g. a loop on gh run list --branch <b> -L 1 every 120 s until the run you pushed is completed. Short shas are 7
  characters (git rev-parse HEAD | cut -c1-7).
- README «CI» explains every gate (the frame gate with C2's rules, the look gate and its goldens, squad visibility,
  both layout runs, the pseudo-localised run, check_strings, Verify) and «Как добавить демо и выбрать его часть»
  (keep the two sim-smoke parts balanced).

## Repository size
GitHub answers pushes with «Repository is approaching its size quota» (~89 GiB, mostly old CI results). Each CI run
adds ~130 MB. Push native-vx-* only when you have a real change to test; batch fixes. Never delete or rewrite anything
on ci-results (the owner decides about old results).

## Calibration guard
The core's calibration outputs stay BYTE-IDENTICAL to native-metal's unless your brief says otherwise — compare md5s in
CI's calib*.jsonl (and locally if you can build the core):
- calib.jsonl (the classic mission) 32dbdb4fbfb886d50ce632cabd1e9e22
- calib-missions.jsonl (Breaker Run, Vent Purge; re-tuned by M1) ea6b8aaa88ea9b2418f1bb631392577b
- calib-stations.jsonl f96d34456a741fbf88e98c5aaba9d01a
- calib-drills.jsonl 8f15dbe7f5e157eb73a76dfaafb5ea5c
- calib-overhead.jsonl e53aeef699dfbf22f404b699504a1153
- calib-props.jsonl 5547b7c8c2fb1df06628ae2b27b96940
- calib-bosses.jsonl (the Manifold; B4) b935bffceea2de8be27f310b6cda01e5
- calib-holdout.jsonl (Dig In; D1) ce068676a94592986026cd8a23022488 (calib-holdout-x5k.jsonl is informational)
The classic gate (README «Калибровка») stays green. New missions and bosses get their own preset (in
Calibration.presetNames), gate rows and CI step — a gated mission template joins MissionCalib.preset (default
`missions`) unless you name its own. Boss bands: Recruit wins ≥ 90 %; on Veteran the boss reached ≥ 75 % and killed in
its own share of the fights that reach it (the Queen ≥ 85 %, the Threader ≥ 80 % with a kill median of 60–100 s);
Nightmare wins ≤ 30 %.

## Text
Player-facing text only through the string catalog (README «L10n "English"»): English, the approved voice, a context
comment and a max width per key; check_strings, both layout runs and the pseudo-localised run green. List every new or
changed key with its English in your report.

## Owner deliverables
Save evidence under next-plan/stage2/<package id>/ (phone-size contact sheets, strips, short H.264 clips ≤ 20 MB where
motion matters — ffmpeg is installed), LOOK at each (Read the image at phone size and in 100 % crops), and list them in
the report with the CI run they come from (a reset can wipe the scratchpad again; CI results are the durable source).

## Machine limits
- Disk: ~30 GB free after the reset, shared with other agents. df -h / before anything large; keep ≥ 5 GB free; delete
  CI downloads, frames, renders and builds once used.
- CPU: 4 cores shared with up to three other agents. Never run two heavy local processes at once yourself (Blender,
  ffmpeg, a Swift build, a calibration run); check ps for another agent's Blender or build before starting one; kill
  what you start.
- Local tools now: python3.13, python3.12 and ffmpeg. The Blender venv is gone — if your package needs Blender, check
  whether /tmp/claude-0/-home-user/541c4a39-d6f7-5a78-a46f-07211ae92b10/scratchpad/visual/pipeline/venv exists (another
  agent may be creating it — wait if a pip process is running); otherwise create it there once: python3.13 -m venv <that
  path> && <that path>/bin/pip install -r ios-native/tools/blender/requirements.txt (bpy 5.2.2). There is no local Swift
  toolchain (its download host is blocked; the orchestrator has asked the owner to allow it): until you are told it is at
  /tmp/claude-0/-home-user/541c4a39-d6f7-5a78-a46f-07211ae92b10/scratchpad/swiftdl, rely on CI's build and core-tests
  and batch your changes so each run tests a lot.

## Resuming
If you stop (a usage limit, a restart, a reset), the orchestrator resumes you or starts a fresh agent on your branch:
keep native-vx-<slug> and wip/native-vx-<slug> pushed, keep a report draft in next-plan/stage2/reports/<id>.md, and say
in your commit messages what is done and what is next.

## Your report
Before you finish, write your report to next-plan/stage2/reports/<package id>.md (summary; branch; final native-metal
sha; CI runs with results; acceptance item by item with evidence; calibration md5s; new text keys; owner deliverables;
handoffs to later packages; open issues), then return the same report as your final message (if writing the file is
refused, return the text).
