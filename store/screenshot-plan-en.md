# ICE HIVE 2.0 — App Store screenshot plan (English, landscape)

The screenshots are taken **after the interface overhaul** (plan phase U4), from a Release build with `-storeShot`
(no debug panel), so they show the final Cryo Glass interface and the English text. This file fixes what is shot, how
each moment is staged and the caption for each; `npm run check:store` checks the caption lengths and words.

## Sizes and slots

Ten shots per size, all landscape, PNG, RGB without alpha, exactly these pixel sizes:

| App Store Connect slot | Size (px) | Simulator, points (× 3) | Notes |
|---|---|---|---|
| iPhone 6.9" Display | 2868 × 1320 | 956 × 440 — iPhone 16 Pro Max / 17 Pro Max | the required slot when only one set is uploaded |
| iPhone 6.5" Display | 2778 × 1284 | 926 × 428 — iPhone 14 Plus / 13 Pro Max | needs an older simulator runtime on the runner |
| iPhone 6.3" Display | 2622 × 1206 | 874 × 402 — iPhone 16 Pro / 17 Pro | the size CI already shoots |

Shoot every size natively on its own simulator (the layouts differ by width and safe area; never scale one set into
another). Which slot is required changes from time to time: upload all three sets so no slot depends on scaling, and
follow what App Store Connect marks as required on the version page.

Orientation for every shot: `-orient right` (the Dynamic Island or notch on the left, as the app launches). The status
bar is hidden by the app.

## Rules for every shot

- Everything on screen comes from the app: the world, the HUD and the menus are exactly what a player sees. Nothing is
  painted in, moved or retouched. The caption bar (below) is the only addition and sits outside the game frame.
- Graphics **high** (Pause → Graphics, kept from the previous run; the swarm demos already use high), brightness normal,
  `-storeShot`.
- Bug counts stay within what the game shows on a mid-range iPhone on high (≤ 900 for the 6.5" device class, ≤ 1400
  elsewhere), so the store never shows more than a player gets.
- Staged runs use the demo scripts (squad held alive, time frozen at ×0.02 for the capture). Numbers that a staged run
  inflates (kills, combo, score) are only shown from the report fixtures (`-demo report -report win`) with the
  `returning` profile, whose figures a real player reaches.
- The HUD stays visible in gameplay shots (it shows the real controls). Cinematic moments (letterbox bars, film-title
  type) hide it by design.
- Call-signs on the nameplates are the final ones (CUPCAKE / SHADOW / DONUT / the Gunner's call-sign once confirmed).

## Caption bar (recommended layout)

Each shot is placed on a dark frosted backdrop at **80 %** of the canvas size, centred horizontally, its bottom edge
3 % of the height above the bottom. The 17 % band above it carries the caption:

- headline: Saira (the interface font, SIL Open Font License), bold, caps, ice white, height ≈ 5.4 % of the canvas
  height (6.9": 72 px), left-aligned at 10 % of the width;
- subline: Saira medium, ≈ 2.6 % of the height (6.9": 34 px), ice blue at 80 %, right-aligned at 90 % of the width,
  on the headline's baseline;
- backdrop: the Cryo Glass palette (deep blue-black with a faint frost gradient), no logos of Apple devices, no
  device frames.

For 6.9" (2868 × 1320) the game frame is 2294 × 1056 at x 287, y 224. The same ratios give the other two sizes.
The alternative (owner decision) is clean full-bleed shots without captions.

## The ten shots

### 1. Hold the light — the swarm

Caption: `HOLD THE LIGHT`
Subline: `Hundreds of bugs. One squad. Six minutes.`

Gunner and the squad in a corridor junction, the swarm closing in from two sides, flashlight beams cutting through
haze, tracers and muzzle flashes, the HUD in its combat state. Staging: `-demo swarmshot` (Gunner, 600 bugs, fire
up-left, time frozen). First shot: it is the one shown in search results.

### 2. Four classes — title and class select

Caption: `FOUR CLASSES. ONE SQUAD.`
Subline: `Assault, Pyro, Cryo, Gunner — pick your gun.`

The title screen: the ICE HIVE logo, OPERATION COLD LIGHT, the four class cards with their weapon and ability icons,
the difficulty row (RECRUIT / VETERAN / NIGHTMARE) and START, the squad standing on the deck behind. Staging:
`-demo title -profile returning` (rank chips and a best score on the profile line).

### 3. Light the beacons

Caption: `LIGHT THREE BEACONS`
Subline: `Stand in the ring. Keep the swarm out.`

The squad inside beacon ALPHA's ring at the moment it comes online: the beam column, the cinematic punch-in, the
BEACON ONLINE film title with letterbox bars (concept C moment). Staging: `-demo punchin` (frozen on the peak).

### 4. The Queen

Caption: `FACE THE QUEEN`
Subline: `She climbs out when you call the lift.`

The Queen on the cargo lift platform, the boss bar at the top, the squad firing from the rim, acid telegraphs on the
deck. Staging: `-demo queen -queenHp 1000000 -tier 1` (Veteran).

### 5. Pyro

Caption: `BURN THROUGH THE HORDE`
Subline: `Torch Flamethrower and a ring of napalm.`

Pyro close to a pack of Runners, the flame cone and a Napalm Ring burning, fire spreading through the swarm.
Staging: `-demo combat -class pyro`, ability fired, frozen at ×0.02 (needs a pyro capture hook like `swarmshot`).

### 6. Cryo

Caption: `FREEZE. SHATTER. REPEAT.`
Subline: `The Cryo Beam turns bugs into ice shards.`

Cryo's beam on a Brute, frozen bugs breaking into shards, an Ice Wave ring expanding. Staging: `-demo combat
-class cryo`, frozen on a shatter (needs a cryo capture hook).

### 7. The squad

Caption: `NEVER FIGHT ALONE`
Subline: `Three AI squadmates cover your flanks.`

A closer camera on the four soldiers back to back, the nameplates with call-signs (YOU, CUPCAKE, SHADOW, DONUT or the
Gunner's call-sign), one squadmate reviving another, a Boomer bursting at the edge. Staging: a squad close-up hook in
the U4 package (`-demo punchin` framing without the beacon, or a new `squadshot`).

### 8. Level-up

Caption: `UPGRADE EVERY LEVEL`
Subline: `19 upgrades. Pick one of three each time.`

The level-up screen over the frozen battle: three cards with icons, stat changes and a class upgrade, the XP bar.
Staging: `-demo levelup -class assault`.

### 9. Extraction

Caption: `RIDE THE LIFT OUT`
Subline: `Hold for 100 seconds. Then get off Kelvin-9.`

The cargo lift rising out of the swarm, letterbox bars and the EXTRACTION film title, the squad on the platform, bugs
falling away below. Staging: `-demo extract-cine` (the rise held for the capture).

### 10. Ranks and the report

Caption: `EARN YOUR RANK`
Subline: `Ten ranks per class. Three difficulties.`

The mission report after an extraction: score count-up finished, the rank card with the fill and a new rank, the
stage strip (beacons, lift, Queen, extraction), a new badge, GO AGAIN. Staging: `-demo report -report win -profile
returning`.

## Files and order

Save as `store/screenshots-2.0/<size>/<n>-<slug>.png` with `<size>` = `6.9`, `6.5`, `6.3` and the numbers and slugs
above (`1-swarm`, `2-title`, `3-beacon`, `4-queen`, `5-pyro`, `6-cryo`, `7-squad`, `8-levelup`, `9-extraction`,
`10-report`). Upload each set to its own slot in that order. The raw captures (before the caption bar) go next to them
as `<n>-<slug>-raw.png` so a caption change never needs a re-shoot.

Hooks the U4 package adds (nothing else in the app changes for screenshots): capture freezes for the pyro, cryo and
squad shots, and the caption-bar compositor (a small script reading this file's captions).
