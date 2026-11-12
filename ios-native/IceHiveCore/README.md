# IceHiveCore

Чистая игровая логика «Ледяного Улья» v2.0: симуляция роя, отряд, оружие, ИИ и режиссёр миссии.
Только Foundation (никаких UIKit/SpriteKit), Swift 5, iOS 16 / macOS 13. Это порт веб-версии
(`game/js/05-sim.js`, `06-marines.js`, `08-director.js` и частей `04-level.js`, `10-input.js`, `12-main.js`)
с теми же числами баланса и тем же поведением.

## Сборка и тесты

```sh
cd ios-native/IceHiveCore
swift test                 # все тесты (debug)
swift test -c release      # те же тесты с оптимизацией: замер производительности с порогом 2 мс/тик
```

Производительность (1500 жуков, мс на тик): CI Mac без оптимизации ≈ 1,7; с `-c release` ≈ 0,3 (Linux x86).
Автопилот выигрывает миссию за 5:30–5:40 игрового времени на всех классах — как веб-версия
(эталон: пулемётчик, маяки 6,5 / 78 / 148 с, удержание лифта с 228 с, победа на 333 с, 8650 убитых).

Тесты: юнит-тесты хеша, лучей и потоковых полей; игровые проверки (ввод, способности, особые жуки,
падение/подъём, уровни, этапы миссии); полная миссия на автопилоте для каждого класса (победа за ≤ 8
минут игрового времени, без NaN, в пределах лимита жуков); бенчмарк 500/1500/3000 жуков (`[perf]` в логе).

## Как пользоваться

```swift
import IceHiveCore

var cfg = GameConfig()
cfg.quality = .med                     // лимит живых жуков 1400 (low 700, high 2500)
let game = Game(seed: 42, playerClass: .assault, config: cfg)

// каждый кадр
game.setPlayerInput(move: Game.worldFromScreen(stickX, stickY),   // мировые координаты XZ
                    aim: aimStickActive ? Game.angle(of: Game.worldFromScreen(ax, ay)) : nil,
                    fire: aimStickActive, ability: abilityTapped, dash: dashTapped,
                    assist: 0.75)                                     // аим-ассист как на тач-экране
accumulator += frameDt * hitStopScale
while accumulator >= SIM_DT { game.tick(); accumulator -= SIM_DT }   // шаг 1/60 с
game.drainEvents { event in /* эффекты, звук, вибрация, тосты */ }
if game.wantsLevelUp { let cards = game.rollUpgrades(); /* показать 3 карты */ game.chooseUpgrade(k) }
switch game.phase { case .won, .lost: /* экран итогов: game.stats */ default: break }
```

Пока открыт выбор карт улучшений, паузу держит приложение (как в веб-версии): `tick()` не вызывается.
После победы или поражения `tick()` ничего не делает. Объект `Game` не потокобезопасен — вызывайте его из одного потока.

### Координаты
Мир — плоскость XZ (`Vec2 = SIMD2<Float>`, `.x` = x, `.y` = z), сетка 128×128 клеток по 1 м, x и z в [-64, 64).
Высота пола берётся из `game.level.groundY(x, z)` (лестницы, пандусы, лифт на −6 м). Угол прицела `aim`
задаёт направление `(sin aim, cos aim)`. `Game.worldFromScreen` переводит экранный стик (x вправо, y вниз)
в мир под камерой веб-версии (рыскание 45°).

### Состояние для рендера (только чтение)
- `game.bugs` — жуки в виде структуры массивов: слоты `0..<count`, мёртвые пропускать (`isDead(i)`);
  указатели `xs`, `zs` (и `prevXs`, `prevZs` — позиции начала тика для интерполяции на 120 Гц), `heights`, `headings`, `scales`, `types`, `states`, `flashes`, `burnTimers`,
  `freezeTimers`, `chills`, `stateTimers`, `gaitPhases`, `variations` и т. д.
- `game.marines` (`player` = индекс 0): позиция и позиция прошлого тика (`px/pz` для интерполяции), прицел,
  скорость, HP, ранен/подъём, рывок, неуязвимость, вспышка выстрела, нагрев/энергия/патроны (`bar`), раскрутка.
- `game.projectiles`, `game.globs` (кислота в полёте), `game.grenades`, `game.napalms`, `game.turret`, `game.medkits`.
- `game.telegraphs` — предупреждения на полу со временем жизни: кольца, полосы тарана, заполняющиеся круги.
- Верхний ярус (Stage 1 R2, `Overhead.swift` / `GameOverhead.swift`): маршруты — `game.level.layout.overhead` (узлы с
  абсолютной высотой, рёбра) и `game.level.overhead` (длины, окна прыжка, входы); у жуков в состояниях `high`…`fall`
  `heights` — абсолютная высота (`bugs.hasAbsoluteHeight(i)`), `isOverhead(i)`, `routeEdges` / `routeParams`;
  `game.dropZones` (телеграфы прыжков: точка, радиус, время, откуда), `game.routeAlive`, `game.overheadStats`,
  `projectiles.aimedUp(k)` (выстрел вверх).
- Жуки яруса (Stage 1 R4, `GameOverheadBugs.swift`): пятый тип `BugType.dropper` (`BugType.allCases` — сколько типов
  рисовать; `BUG_TYPES` = 5), состояния `pin` (11: Dropper прижал бойца, на палубе) и `perch` (12: плевун на насесте);
  `marine.pinned` / `pinT`, `game.pinnedBy(k)` (uid прижавшего), `game.droppersAlive`, `zone.dropper` у телеграфа прыжка;
  `game.perchPoints` (узлы-насесты графа), `game.perchTaken(k)`; `game.ducts` (`DuctState`: узел, точка, HP, `open`,
  `rattleT` — дребезг перед стаей, `shutT` — сколько ещё закрыто, `health`); `globs.launchHeight(k)` (плевок с насеста
  летит с высоты). Статистика — новые поля `overheadStats` (прижимы и чем сняты, насесты, плевки, дребезг, закрытия).
- Интерактивы (Stage 1 R6, `Props.swift` / `GameProps.swift`): данные — `game.level.layout.props` (паровые клапаны с
  пролётом завесы, цепи света с рубильником и палубами, шкафчики снабжения; `PropLayout.kelvin` — набор «Кельвина-9»),
  лампы станции с цепями — `game.level.lamps` (то же правило, что у столбов `WorldLevel`); состояние — `game.valves`
  (фаза ready / burst / venting / recharge, `gauge`, `hot`), `game.circuits` (питание, лампы, горящие, кольцо, `lit`,
  `needsRestore`, `restoredAt`), `game.lamps` (`on`, `hp`, `changedAt` — для мерцания), `game.lockers`, `game.lightsLit`,
  `game.lit(x, z)` (освещённая палуба — круги «без прыжков» верхнего яруса), `game.propStats`.
- «Кельвин-9» Mk II (Stage 1 R5, `KelvinMk2.swift`): станция классической миссии — `KelvinStation.mk2` (маршруты
  `OverheadLayout.kelvinMk2` + `PropLayout.kelvin`; приложение строит её для каждого запуска, кроме витрин), голый
  `KelvinStation()` — раскладка v1.0 (`GameConfig.levelSource` по умолчанию: тесты механик, строка legacy); именованные узлы
  набора — `KelvinMk2` (стояк и устье над мостом, устья, насесты площади, мачты лифта, полоса длины 150–450 м). Калибровка:
  `CalibRun.mk2` (классические строки пресетов `gate` / `full` на Mk II), CLI `--kelvin mk2|props|bare`.
- Миссии I (Stage 1 R7, `MissionsKelvin.swift`): шаблоны `MissionTemplate.breakerRun` / `.ventPurge` (`missions`,
  `playable` — классика и эти две; у шаблона своя станция `station` — `KelvinStation.missions` = `.mk2`, «Кельвин-9» Mk II
  классики — и имя `name`), пломба — `SwitchSite.duct` / `.vent` (устье воздуховода R4 / вентиляция палубы: заварены
  навсегда; сначала устья, у Mk II — три), состояние — `game.switchesThrown`, `game.ventShut` (вентиляции, заваренные пломбами),
  `game.streamK` (поток улья: × каждой пломбы), `game.beaconInPlan` (маяки, которые заряжает план), отчёт —
  `RunSummary.switchLine` / `strip` (своя полоса этапов плана); события `.ventSealed(index:)`, `.ventPour(index:count:)`.
- Боссы (Stage 2 B1, `Boss.swift` / `GameBoss.swift` / `GameBossBody.swift`; Матка — `GameQueen.swift`): `game.boss`
  (`BossState`: вид, uid, пришёл / жив / убит, ярость, фаза, здоровье 0…1, предупреждение, позиция, высота и курс головы,
  неуязвимость, оглушение, блок, хрупкость, прибытия), `game.bossSpec` (строка босса шага), `game.bossHpFraction`;
  тело-цепь — `game.bossPartCount`, `game.bossPart(k)` (`BossPartView`), `game.bossBodyPoint(behind:)`; у слотов
  `bugs.isBoss(i)`, `bugs.bossPart(i)` (часть цепи, −1 — нет), состояние `boss` (13: абсолютная высота). Формы телеграфов
  `cone`, `beam`, `drop` (причина `bossMove`).
- `game.mission` (план), `game.missionStep`, `game.stepPhase`, `game.switches`, `game.missionZone`, `game.objectiveKey`,
  `game.beacons`, `game.stage`, `game.objective`, `game.objectiveProgress`, `game.objectiveMarker`,
  `game.contextHint`, `game.liftRise`, `game.kills`, `game.time`, `game.comboShown`, `game.xpLevel`, `game.xp/xpNext`.
- `game.laserLength(marine)`, `game.turretLaserLength`, `game.raycastBugs(...)`, `game.bugsInCircle(...)`,
  `game.bugCountNear(center)` (громкость стрекота роя), `game.assistedAim(angle, strength:)`, `game.setVisibleArea(...)`
  (аим-ассист не выбирает жуков за краем экрана).

### События (`GameEvent`)
Накапливаются за тики и забираются `drainEvents`: смерть жука (тип, место, заморожен, кто убил, поворот,
масштаб — для трупов и пятен), взрывы, попадания пуль, выстрелы, перегрев, перезарядка, урон/падение/подъём
бойцов, рывки, способности, телеграфы, кислота, аптечки, орды, маяки, лифт, уровень, комбо, победа/поражение,
ярус R4 (`pinned`, `pinBroken` с причиной `PinBreak` dash / fire / timeout / down / release и освободителем,
`ductRattle`, `ductHit`, `ductSealed`, `ductOpened`, `perched`, `acidFromPerch`), боссы (`bossWarning`, `bossSpawned`,
`bossPhase`, `bossKilled`, `bossMove`, `bossWindow`, `bossPartPopped`, `bossPartFrozen` — у каждого `kind: BossKind`),
тосты и баннеры (русский текст), `sound(SoundID, …)` с теми же именами, что `sfx()` веб-версии,
`haptic`, `shake`, `hitStop`, `screenFlash`, `damageFlash`, `hordeFlash`.

### Отладка (аналог `window.__dbg`)
`debugState`, `debugSpawn(n, type:)`, `debugSkip()`, `debugBoss(hp:)` (босс шага сейчас), `godMode`, `autopilot`, `fastForward(seconds:)`,
`debugLevelUp()`, `debugHorde(n)`, `debugTeleport(x, z)`, `benchmark(counts:)`, `setQuality(_:)`,
`directorEnabled`; верхний ярус — `debugRoutePack(n, entry:)`, `debugSpawnRouteBug(entry:)`,
`debugSetNoDropZones(_:)`, `debugHoldFire`; R4 — `debugRoutePack(n, entry:, rate:, type:)` (тип стаи),
`debugRouteFocus` (все маршрутные жуки целят в этого бойца; −1 — обычное правило), `debugPinMarine`, `debugHurtDuct`;
интерактивы — `debugBurstValve(k, by:)`, `debugCutCircuit(k)`, `debugRestoreCircuit(k)`, `debugBreakLamp(k)`,
`debugSpawnLine(n, type:, from:, to:)`; миссии (R7) — `debugSwitchProgress(p)`, `debugVentPour(k, count:)` (излив устья —
`debugRoutePack(n, entry: ducts[d].node)`). Замедление/ускорение времени — на стороне приложения (сколько тиков вызвать за
кадр).

### Детерминизм
Вся случайность идёт через один `SeededRNG` (mulberry32). Одинаковые seed, класс, конфигурация и
последовательность ввода дают одинаковый прогон на одной платформе.

## Точки расширения для v1.1
- `Difficulty` — таблица сложности («Новобранец / Ветеран / Кошмар»); `Difficulty.standard` равен v1.0,
  предварительные строки `recruit / veteran / nightmare` взяты из плана v1.1.
- `LevelSource` → `LevelLayout` — генератор станций по сиду вместо фиксированной `KelvinStation`.
- Боссы — строка `BossSpec` на уровень в `Difficulty`, свой файл с `bossOwnTick` / `bossOwnMove` / `bossOwnPart`
  (`GameBoss.swift` переключает по `BossKind`), шаг плана `BossStep` или наездник удержания `BossRider` (правило
  прибытия `BossArrival`).
- Давление улья, часы застоя и «Матка» встраиваются в `tickDirector` (`GameDirector.swift`): темп
  подкрепления, орды, выбор типа жука (`pickType`) и спавн (`spawnBug`, `queueBurst`) — отдельные функции,
  новые события добавляются в `GameEvent`.

## Файлы
| Файл | Что внутри |
|---|---|
| `Core.swift` | константы, математика, `SeededRNG` |
| `Tuning.swift` | жуки, классы, качество, `Difficulty`, карты улучшений |
| `Level.swift` | `LevelLayout`, `LevelSource`, `KelvinStation`, `Level` (сетка, высоты, края-спавны) |
| `Swarm.swift` | хранилище жуков (структура массивов, уплотнение) |
| `Spatial.swift` | пространственный хеш (сортировка подсчётом), запросы, лучи, потоковые поля (BFS) |
| `Marine.swift` | боец, модификаторы |
| `Events.swift` | `GameEvent`, звуки, вибрация, телеграфы |
| `Game.swift` | фасад `Game`, конфигурация, тик, пулы снарядов/способностей |
| `GameSwarm.swift` | спавн, урон, взрывы, кислота, обновление роя |
| `GameMarines.swift` | движение, урон, подъём, оружие, снаряды, способности |
| `GameAI.swift` | ввод игрока, аим-ассист, ИИ ботов и автопилот |
| `Mission.swift` | план миссии из модулей (RING, SWITCH, HOLD, BOSS, EXTRACT), шаблоны (`coldLight`, учения), их калибровка |
| `MissionsKelvin.swift` | миссии на «Кельвине-9» (Stage 1 R7): «Breaker Run», «Vent Purge», их станция и пресеты калибровки |
| `GameMission.swift` | исполнение плана: шаги и фазы, модули, запросы для режиссёра, HUD, ботов и калибровки |
| `Overhead.swift` / `GameOverhead.swift` | верхний ярус (Stage 1 R2): маршруты и их индекс, жуки наверху, прыжки, контригра, канал режиссёра |
| `Props.swift` / `GameProps.swift` | интерактивы (Stage 1 R6): клапаны и завеса, цепи света и лампы, шкафчики; боты, советы, отладка |
| `GameDirector.swift` | темп роя (поток, орды, давление улья), опыт, улучшения; этапы миссии — план (`missionTick`) |
| `GameHUD.swift` | тексты задачи и подсказок, статистика, лазеры |
| `GameDebug.swift` | отладочные хуки, бенчмарк |
| `GameOverheadBugs.swift` | жуки яруса (R4): прижим Dropper, плевуны на насестах, устья коробов (дребезг, закрытие огнём) |
| `Boss.swift` | каркас боссов (Stage 2 B1): `BossSpec` (тело, фазы, ходы, иммунитеты, крючки арены, награда), `BossState`, `BossKind` |
| `GameBoss.swift` | рантайм боссов: предупреждение, появление, `bossTick`, фазы, ходы с телеграфами, урон частей, смерть, прибытия |
| `GameBossBody.swift` | тело-цепь: история пути головы, сегменты по длине дуги, слоты частей, вид для рендера |
| `GameQueen.swift` | Матка на каркасе: её строки `BossSpec.queen(…)` |
| `KelvinMk2.swift` | «Кельвин-9» Mk II (R5): маршруты верхнего яруса ручной карты, `KelvinStation.mk2` — станция классической миссии |
