# ICE HIVE 2.0 — App Store Connect listing (English, primary language)

Every text that goes into App Store Connect sits in its own copy block: copy the whole block. The owner reviews and
approves this copy before 2.0 is submitted. Lengths, banned words and the facts are checked by
`npm run check:store` (`scripts/check-store.mjs`).

App Store Connect counts every field in characters (a line break counts as one) except **Keywords, which are limited to
100 bytes of UTF-8** (plain Latin letters and commas are one byte each).

Placeholders the owner must fill are square brackets that start with `OWNER:`. `npm run check:store` lists them;
`npm run check:store -- --release` fails while any is left.

| Field | Limit | Now |
|---|---|---|
| Name | 30 | 8 |
| Subtitle | 30 | 27 |
| Promotional Text | 170 | 162 |
| Description | 4000 | 2856 |
| Keywords | 100 **bytes** | 96 bytes |
| What's New | 4000 | 640 |
| App Review Notes | 4000 | 2757 |

Facts this listing relies on (checked against `ios-native/project.yml` and `Info.plist` by the script): version
**2.0.0**, iPhone only, **iOS 16.0** or later, **landscape only** (both sides), native Swift with a Metal renderer and a
SpriteKit interface drawn into the same Metal pass, no web view, no networking code, fonts under the SIL Open Font
License, single player with three AI squadmates.

---

## 1. Name — **8 / 30** characters

<!-- field: name -->
```
Ice Hive
```

Matches the name under the icon (`CFBundleDisplayName` = `Ice Hive` on the English build). App Store names are unique
across the store. If App Store Connect says the name is taken, use a fallback below; the icon can keep the short
`Ice Hive`, because a store name that starts with the icon name is accepted.

Fallback A — **24 / 30** characters:

<!-- field: name-fallback-a -->
```
Ice Hive: Squad vs Swarm
```

Fallback B — **18 / 30** characters:

<!-- field: name-fallback-b -->
```
Ice Hive: Kelvin-9
```

## 2. Subtitle — **27 / 30** characters

<!-- field: subtitle -->
```
Squad shooter vs. bug swarm
```

The subtitle is indexed for search, so its words (squad, shooter, bug, swarm) are not repeated in the keywords.

## 3. Promotional Text — **162 / 170** characters

Promotional text can be changed at any time without a new build or review.

<!-- field: promo -->
```
Four guns, three beacons, hundreds of ice bugs. Hold the ring, call the lift, get off Kelvin-9 alive. Rebuilt for landscape on native Metal. No ads, no purchases.
```

## 4. Description — **2856 / 4000** characters

Honest by design: a single-player game whose three squadmates are AI. The check script rejects words that promise play
with other people, other platforms, prices or rankings.

<!-- field: description -->
```
Kelvin-9 went silent six hours ago. Something is moving under the grates.

ICE HIVE is an isometric horde shooter for one player. Your squad of four drops into a frozen research station at −94 °C with one job: light three beacons, call the cargo lift and hold out until extraction — while hundreds of bugs pour out of the dark.

YOUR SQUAD
You control one soldier. The other three are AI squadmates with call-signs like CUPCAKE, SHADOW and DONUT. They hold the flanks, fire their abilities into the pack and pull you back to your feet when you go down. Stay close — you can do the same for them.

FOUR CLASSES
• ASSAULT — Pulse Rifle with piercing shots, plus a Frag Grenade.
• PYRO — Torch Flamethrower and a Napalm Ring. Fire spreads through the swarm.
• CRYO — the Cryo Beam slows and freezes; frozen bugs shatter into shards. Ability: Ice Wave.
• GUNNER — a Rotary Cannon that spins up, plus an Auto-Turret to hold a flank.
Whichever class you pick, the squad brings the other three, so every fight uses the full arsenal.

THE SWARM
Runners flood out of the abyss. Spitters lob acid. Brutes charge in a straight line. Boomers burst right next to your squad. Hordes roll in waves, and every beacon you light makes the hive angrier. Hold the lift long enough and the Queen climbs out to meet you.

THE MISSION
• Find beacons ALPHA, BETA and GAMMA. Stand in the ring while it charges and keep the swarm out.
• Call the cargo lift and survive on the platform until it leaves.
• A run takes about six minutes — one mission fits in a coffee break.

GROW STRONGER EVERY RUN
Kill, earn XP, and at every level pick one of three upgrades: Caliber, Rapid Bolt, Armor-Piercing, Nanobandages, Cluster Grenade, Sticky Napalm, Brittle Ice, Turret Mk2 and more — 19 in all, some for one class only. Between missions every class climbs ten ranks from Private to Major and earns a badge for each difficulty it gets out alive on.

THREE DIFFICULTIES
RECRUIT for your first drop. VETERAN as designed: you will go down, and the Queen is deadly. NIGHTMARE for the few who outlive her. A short tutorial walks you through your first mission.

BUILT FOR IPHONE
• A native engine on Metal: real-time lights and shadows, flashlight beams cutting through frost and haze, GPU particles for fire, ice, acid and sparks.
• Landscape, two-thumb controls: the left thumb moves, the right thumb aims and fires, ability and dash buttons sit on the right.
• Haptics on hits and explosions, plus graphics, brightness and volume settings. Reduce Motion in iOS calms the camera shake.

NO STRINGS ATTACHED
• Plays fully offline, anywhere.
• No ads, no in-app purchases, no account, no sign-in.
• No data collected: your settings, ranks and records stay on your iPhone.

ICE HIVE is a single-player game. Your squadmates are controlled by the game, so you never wait for anyone — just drop in.
```

## 5. Keywords — **96 / 100** bytes

Comma-separated, no spaces after the commas, every keyword longer than two characters, no other games' names or brands,
no words already in the name or subtitle (Apple indexes those itself), no category names and no price words.

<!-- field: keywords -->
```
horde,alien,insects,survival,top-down,twin-stick,offline,sci-fi,roguelite,flamethrower,isometric
```

## 6. Category

| App Store Connect field | Value |
|---|---|
| Primary Category | **Games** |
| Game subcategory 1 | **Action** |
| Game subcategory 2 | **Arcade** |
| Secondary Category | optional; leave empty |

With Games as the primary category App Store Connect offers up to two game subcategories. `LSApplicationCategoryType =
public.app-category.action-games` in Info.plist is only a hint; the store uses what is chosen in App Store Connect.

## 7. Age Rating

Answers for App Information → Age Rating → Edit. The question names follow the App Store Connect form.

| Section / question | Answer | Why |
|---|---|---|
| **In-App Controls:** Parental Controls | No | The game has no parental controls |
| **In-App Controls:** Age Assurance | No | No age check |
| **Capabilities:** Unrestricted Web Access | No | No browser or web view; the app makes no network requests |
| **Capabilities:** User-Generated Content | No | None |
| **Capabilities:** Messaging and Chat | No | None |
| **Capabilities:** Advertising | No | No ads |
| **Violence:** Cartoon or Fantasy Violence | **Frequent/Intense** | Constant gunfire, fire and explosions against alien insects |
| **Violence:** Realistic Violence | None | No humans or real animals are hurt on screen; a downed soldier is revived or the mission ends |
| **Violence:** Prolonged Graphic or Sadistic Realistic Violence | None | — |
| **Violence:** Guns or Other Weapons (if the form asks) | Frequent | Sci-fi weapons: pulse rifle, flamethrower, cryo beam, rotary cannon |
| **Mature Themes:** Horror/Fear Themes | Infrequent/Mild | A dark station and an insect swarm; no jump scares or gore scenes |
| **Mature Themes:** Profanity or Crude Humor | None | — |
| **Mature Themes:** Alcohol, Tobacco, or Drug Use or References | None | — |
| **Medical or Wellness:** Medical or Treatment Information | None | "Nanobandages" is a game upgrade name, not medical information |
| **Medical or Wellness:** Health or Wellness Topics | No | — |
| **Sexuality or Nudity:** every question | None | — |
| **Gambling:** Simulated Gambling | None | — |
| **Gambling:** Contests | None | — |
| **Gambling:** Gambling (real money) | No | — |
| **Gambling:** Loot Boxes | No | Upgrades are picked openly from three visible cards; nothing is bought |
| Made for Kids | No | Not a Kids category game |

Blood: the splashes are insect ichor and stains on the deck; no human blood or dismemberment, so a separate blood
question (if the form adds one) is None or Mild.

**Expected result: 13+** on Apple's current scale (4+, 9+, 13+, 16+, 18+). App Store Connect shows the result right after
the form; if it differs, compare the answers with this table.

## 8. App Privacy and compliance

App Store Connect → the app → **App Privacy** → Get Started:

1. "Do you or your third-party partners collect data from this app?" → **No, we do not collect data from this app.**
2. Save, then **Publish**. The listing shows **Data Not Collected**.
3. Privacy Policy URL → the published `store/privacy-policy.html` (section 13).

Why this is true for 2.0: the app is native Swift with no third-party SDKs, no analytics, no ads, no accounts and no
networking code (the check script scans `ios-native` for networking, web-view, ad and tracking APIs). Settings, records
and the player profile live only on the device, in `UserDefaults` (the full list is in the privacy policy).
`PrivacyInfo.xcprivacy` declares `NSPrivacyTracking = false`, no collected data types, no tracking domains, and the
required-reason APIs `UserDefaults` (CA92.1) and system boot time (35F9.1, frame timing).

Other questions:
- **Content Rights** ("contains, shows, or accesses third-party content?") → **No.** The bundled fonts are licensed
  under the SIL Open Font License, and their license texts ship in the app (`Resources/Fonts/OFL-*.txt`). Models,
  textures, sounds and code are the project's own.
- **Export Compliance**: answered by `ITSAppUsesNonExemptEncryption = NO` in Info.plist; no question at upload.
- **Advertising Identifier (IDFA)**: not used. No App Tracking Transparency prompt.
- **Apple silicon Mac and Apple Vision Pro availability**: the game is built for touch on iPhone in landscape and has
  not been tested on a Mac or on Vision Pro. Recommended: Pricing and Availability → uncheck **Make this app available**
  for Mac (and for Vision Pro if that section is shown) until it has been tested there.

## 9. Copyright

<!-- field: copyright -->
```
2026 [OWNER: COPYRIGHT HOLDER NAME]
```

Replace the bracket with your name (individual developer account) or company name, exactly as the seller name in Apple
Developer. Do not type ©: App Store Connect adds it.

## 10. App Review Notes — **2757 / 4000** characters

App Review Information → Sign-in required: **No** (leave unchecked). Contact information: the owner's name, phone and
e-mail. Notes: the block below.

<!-- field: review-notes -->
```
ICE HIVE 2.0 is a single-player isometric horde shooter written natively in Swift. The world is drawn by the game's own Metal renderer and the interface is a SpriteKit scene drawn into the same Metal pass. There is no web view and no downloaded content: all code, 3D models, sounds and fonts (SIL Open Font License) are in the app bundle.

KEY FACTS
- iPhone only, iOS 16.0 or later, landscape only (both sides). On iPad it runs in iPhone compatibility mode.
- Fully offline: the app makes no network requests.
- No account, no sign-in, no in-app purchases, no ads, no tracking, no third-party SDKs, no permission prompts. No demo account is needed.
- Settings, records and the player profile are stored on the device only (UserDefaults). App Privacy: Data Not Collected.
- The player controls one soldier; the three squadmates (CUPCAKE, SHADOW, DONUT, MUFFIN, depending on the classes in play) are computer-controlled. There is no multiplayer and no chat.
- Version 2.0 replaces the earlier 1.x app on the same bundle ID; an update keeps the player's record and settings.

HOW TO REACH EVERY SCREEN
1. Launch: a short loading cover, then the title screen.
2. Title: four class cards (ASSAULT, PYRO, CRYO, GUNNER), the difficulty row (RECRUIT, VETERAN, NIGHTMARE) and START. The very first mission always runs on RECRUIT with a five-step tutorial; SKIP on the tutorial card ends it.
3. Mission: the left thumb moves, the right thumb aims and fires automatically, and the round buttons on the right are the class ability and DASH. A hardware keyboard also works: WASD move, IJKL aim and fire, Space dash, Q or E ability, Esc pause.
4. Level-up: when the XP bar fills (usually within the first minute) the game pauses on three upgrade cards; tap one to continue.
5. Pause: the button in the top-right corner. It holds RESUME, TUTORIAL (replays the tutorial), QUIT MISSION and the settings: sound, volume, graphics, brightness and haptics.
6. Objective: walk into a beacon ring and stay inside until the OBJECTIVE bar fills. After beacons ALPHA, BETA and GAMMA, go to the cargo lift and hold it for 100 seconds. About 30 seconds into the hold the Queen climbs onto the platform; the lift leaves only after she is killed.
7. Extraction: a short cinematic while the lift rises, then the mission report (score, rank, records) with GO AGAIN and CHANGE CLASS. The title screen then shows the rank and best score.

A full run takes about 6 minutes; RECRUIT is the easiest difficulty. The fastest way to the mission report is Pause → QUIT MISSION → confirm (it counts as a loss).

If the squad falls, the mission ends with the same report. Graphics adapt to the device: Pause → Graphics switches between auto, low, medium and high. Haptics can be turned off in Pause.
```

## 11. What's New in version 2.0 — **640 / 4000** characters

App Store Connect shows this field for every version after the first one that was released. If 1.x never reached the
store, 2.0.0 is the first version: the field is not shown and this text is not used.

<!-- field: whats-new -->
```
ICE HIVE 2.0 is a complete rebuild.

• A new native engine on Metal: real-time lights and shadows, flashlight beams through the frost, GPU particles for fire, ice and acid.
• New 3D squad and swarm with new animations.
• Landscape only, with two-thumb controls.
• The game is now in English, with a new interface.
• Three difficulties — RECRUIT, VETERAN, NIGHTMARE — and the Queen waiting at the lift.
• Ten ranks for every class, badges for each difficulty, a mission report after every run.
• A tutorial for your first drop and a new brightness setting.

Your record and settings from the previous version carry over. See you on Kelvin-9.
```

## 12. Screenshots

The screenshots are taken after the interface overhaul, from a Release build with `-storeShot`. Which ten landscape
shots, the staging for each and the caption texts are in **`store/screenshot-plan-en.md`**. Sizes:

| App Store Connect slot | Landscape size (px) | Simulator (points × 3) |
|---|---|---|
| iPhone 6.9" Display | 2868 × 1320 | 956 × 440 |
| iPhone 6.5" Display | 2778 × 1284 | 926 × 428 |
| iPhone 6.3" Display | 2622 × 1206 | 874 × 402 |

The 1.x screenshots in `store/screenshots/` are history (see `store/DEPRECATED-ru.md`) and must not be uploaded for 2.0.

## 13. Other fields

| Field | Value |
|---|---|
| Bundle ID | `com.hjj96.icehive` |
| SKU | `icehive-ios-1` (any unique code; players never see it) |
| Primary Language | **English (U.S.)** — see the note below |
| Version / Build | 2.0.0 / 1 (raise the build number on every upload) |
| Devices | iPhone only, iOS 16.0 or later |
| Support URL (required) | `[OWNER: SUPPORT URL]` — a public https page with real contacts: the e-mail and anything local law requires (often a postal address and phone; for the EU the same details as the DSA trader status). The published privacy policy works if its Contact section carries those details. |
| Marketing URL (optional) | `[OWNER: MARKETING URL or leave empty]` |
| Privacy Policy URL (required) | `[OWNER: PUBLIC URL OF store/privacy-policy.html]` |
| Price | **Free** (Pricing and Availability → Price: Free); no in-app purchases |
| Contact e-mail (privacy policy, App Review) | zviaginzevandrew@gmail.com |

**Primary language.** The game ships in English only. If the app record in App Store Connect was created with Russian as
the primary language (1.x), add the English (U.S.) localization, fill it from this file, make it the primary language
(App Information → Primary Language), and remove the Russian localization so the Russian store page does not promise a
Russian game. The Russian 1.x texts stay in the repository as history (`store/app-store-ru.md`, deprecated).
