# Stage 2 «Manifold» — packages (design.md §3.5 items R8–R10)

Order and dependencies (two packages at a time):
- critical lane: B1 boss-core → B4 threader-core → B5 threader-game
- second lane: M1 missions-length (starts with B1) → B2 threader-asset → B3 boss-intro (after B1) → D1 dig-in (after
  B1) → S1 shaft9-core → S2 shaft9-game
- infrastructure, alongside the first two: C1 ci-split (sim-smoke split into two parallel jobs — the review's open issue 9)
- small fix in C1's slot once it lands: H1 hud-queue (the first minute's HUD overlaps — the review's open issue 1)
- then in the same slot: V1 overhead-read (the overhead reads subtle at phone size — the review's open issue 5 and the
  film's open issue 1; proposed to the owner on Nov 11 with the film: «do it unless you say otherwise»)
- then an independent review and a film for the owner.
Shared files (README, DemoScript.swift, the CI workflow, GameDirector / GameWaves / GameMission, Tuning, Calibration,
Localizable.xcstrings, assets.md5) are merged on both sides. Every package keeps the classic mission and the Stage 1
mission presets byte-identical (ctx.md «Guards»).

---

> Rebuilt Nov 14 after the machine reset: the intro and the sections B5, D1, S1, S2 are the original text. The finished packages' sections (M1, C1, H1, B1, B2, B4, C2) are gone — their README sections and reports describe what was built. B3 «Boss intro and boss name» and V1 «The overhead reads at phone size» are in flight: their scope is in prompts/B3.md and prompts/V1.md.

## B5 — The Threader in the game (slug: threader-game) — after B2, B3, B4
Scope: design.md §1.5 (look, telegraphs, radio), §1.1.4 (the drop language), §1.1.7 (parallax); tech.md §5.2 (render and
assets: the segment IHV drawn along the path, emissive nodes, the lure as a fifth volume cone, arena kit pieces; swarm
draws grow by up to 3 per boss type and LOD). Draw the Threader from B4's state with B2's assets: segments placed and
oriented along the body path gripping the trunks, the head and its clips, nodes lit / popped, the lure beam (a fifth
volume cone, hot white on lock), every telegraph (lock ring, coil ring, rime lane, squeeze gauge needle + hiss, pull-down
lane and dust, falling frost along the body before a Shed); the Manifold arena render (B2's kit, the trunks through
R3's overhead path with its cutaway — a boss arena allows crossings over the island; the cutaway keeps the squad
visible), audio (scrape, moan, scream, slam; the height timbre), B3's intro for the Threader, the boss name in the HUD,
the radio lines; the start path `-mission manifold`; CI: a `manifold` demo with shots (P1 lure lock, the head down, P2
coil, P3 pull down) in the frame, look and squad-visibility gates; bursts.
Owns: App/Sources/Metal (boss drawing in the swarm / a new WorldBoss, the lure cone in VolumeCones, telegraph FX),
App/Sources/Game (the mission start, the intro hookup), audio assets, CI (the demo, shots, bursts, gates), README.
Acceptance: the Threader readable at phone size in every phase; telegraphs readable (lock, coil, rime, squeeze, pull
down); the squad never hidden (visibility gate on the manifold shots); frame gate green within budget (+draws / triangles
/ ms reported vs the tech estimate); calibration unchanged; CI green; native-metal fast-forwarded. Owner deliverable:
next-plan/stage2/B5/threader.mp4 (the fight in three phases at phone size) + strips.

## D1 — Dig In (slug: dig-in) — after B1
Scope: design.md §1.6 (Dig In: HOLD waves until the squad falls, at the Lift; score; bank the score at waves 5 / 10),
§3.3 replay variety; next-plan/stage1/reports/R1.md «Handoffs → R10» (HoldStep(time: .infinity) is safe; a boss rider in
an endless hold never comes — its own arrival rule). The holdout template on the Lift arena: escalating waves with the
director's lulls and peaks (and the overhead), a wave counter, the Queen (through B1's framework) as a periodic peak by
its own arrival rule, banking at waves 5 and 10 (a banked score survives the fall), the score and report lines (waves
held, banked, best), first-sighting / loss tips through the catalog; the start path `-mission dig-in`; informational
calibration rows (waves reached per tier: Recruit / Veteran / Nightmare medians in bands you propose and justify; AFK
band) gated so that later packages cannot silently change them; a CI demo with shots (a wave peak, the bank moment).
Owns: IceHiveCore (the holdout template, wave escalation, banking, score, tests, its preset), the report lines, catalog
keys, DemoScript entry, CI demo, README.
Acceptance: core tests (endless hold never soft-locks or NaNs, wave escalation, banking, the Queen's arrival rule,
determinism); the Dig In rows in their bands; classic and other presets byte-identical; CI green; native-metal
fast-forwarded. Owner deliverable: next-plan/stage2/D1/dig-in.jpg (phone-size shots: early wave, a peak, the bank, the
report).

## S1 — Shaft 9: the ride (slug: shaft9-core) — after D1 (shares the director)
Scope: design.md §1.3 A (Shaft 9), §1.6 (Going Down: RING ×2 → RIDE Shaft 9 → RING in the lower sector → EXTRACT);
tech.md §3 «Moving platforms» (keep the simulation arena static on the platform, the rim becomes the spawn edge, timed
route segments for gantries / cables), §1.9–1.10; R1.md «Handoffs → R9» (add a RIDE case to MissionModule). In
IceHiveCore: the RIDE module (the lift disc as a moving arena, 90–120 s, 2–3 landings that stop 12–15 s with a door
opening on one side and a column horde from a corridor mouth), the WALL spawn mode (bugs crawl down the shaft wall and
leap onto the rim), runners and Droppers sliding down the four lift cables (timed route segments on R2's routes),
falling debris with the drop language, packs timed to the light pulses (every 6 s; a landing is the peak, the open ride
the build-up); SECTOR CHAINING (the next layout loaded behind the arrival; the squad, its state and the mission plan
carried across; the lower sector a hand-made Kelvin-9 sector or a curated generated one — say which and why); the Going
Down mission template with its calibration preset and gate rows inside the classic bands; bots and autopilot; text keys
(objective lines, banners, radio).
Owns: IceHiveCore (RIDE, wall spawns, cable slides, landings, sector chaining, the Going Down template and preset,
tests), catalog keys, README. The look is S2's (a debug stand-in only if CI needs one).
Acceptance: core tests (the ride timeline, landings, wall spawns, cable slides, chaining keeps the squad / plan /
score, determinism); the Going Down preset in the bands; classic and other presets byte-identical; CI green; native-metal
fast-forwarded. Handoffs for S2.

## S2 — Shaft 9: the look (slug: shaft9-game) — after S1
Scope: design.md §1.3 A (the far shaft wall rising up-screen and scrolling upward as the lift descends; the near wall
behind the camera; light sweeps every 6 s with horror-beam darkness between; landings; falling debris); tech.md §3
(scroll environment segments — kit pieces — with per-draw offsets, recycled in the fog; parallax walls; air streaks;
audio), §1.8 (camera and cinematics: the arrival cut). Render the shaft from S1's state: the scrolling wall from the
station kit (pipes, ribs, cable trays, landing doors), the four cables, the sweep lights, debris telegraphs, bugs on the
wall and the cables, the landing doors opening, the arrival cut that hides loading the next sector (behind the cover,
within the loading rules); audio (rumble, air, the lift's groan, the sweep); the start path `-mission going-down`; CI: a
`shaft9` demo with shots (the open ride in the dark between sweeps, a sweep, a landing horde, the arrival) in the
frame, look and squad-visibility gates; bursts.
Owns: App/Sources/Metal (the shaft wall, sweeps, cables), App/Sources/Game (the ride camera, the arrival cut), audio, CI,
README.
Acceptance: the descent reads at phone size (motion, depth, the squad visible in the dark between sweeps); the arrival
cut has no hitch over the frame gate's limits; frame / look / visibility gates green; calibration unchanged; CI green;
native-metal fast-forwarded. Owner deliverable: next-plan/stage2/S2/shaft9.mp4.
Shell cwd was reset to /home/user