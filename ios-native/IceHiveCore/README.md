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
- `game.beacons`, `game.stage`, `game.objectiveText`, `game.objectiveProgress`, `game.objectiveMarker`,
  `game.contextHint`, `game.liftRise`, `game.kills`, `game.time`, `game.comboShown`, `game.xpLevel`, `game.xp/xpNext`.
- `game.laserLength(marine)`, `game.turretLaserLength`, `game.raycastBugs(...)`, `game.bugsInCircle(...)`,
  `game.bugCountNear(center)` (громкость стрекота роя), `game.assistedAim(angle, strength:)`, `game.setVisibleArea(...)`
  (аим-ассист не выбирает жуков за краем экрана).

### События (`GameEvent`)
Накапливаются за тики и забираются `drainEvents`: смерть жука (тип, место, заморожен, кто убил, поворот,
масштаб — для трупов и пятен), взрывы, попадания пуль, выстрелы, перегрев, перезарядка, урон/падение/подъём
бойцов, рывки, способности, телеграфы, кислота, аптечки, орды, маяки, лифт, уровень, комбо, победа/поражение,
тосты и баннеры (русский текст), `sound(SoundID, …)` с теми же именами, что `sfx()` веб-версии,
`haptic`, `shake`, `hitStop`, `screenFlash`, `damageFlash`, `hordeFlash`.

### Отладка (аналог `window.__dbg`)
`debugState`, `debugSpawn(n, type:)`, `debugSkip()`, `godMode`, `autopilot`, `fastForward(seconds:)`,
`debugLevelUp()`, `debugHorde(n)`, `debugTeleport(x, z)`, `benchmark(counts:)`, `setQuality(_:)`,
`directorEnabled`. Замедление/ускорение времени — на стороне приложения (сколько тиков вызвать за кадр).

### Детерминизм
Вся случайность идёт через один `SeededRNG` (mulberry32). Одинаковые seed, класс, конфигурация и
последовательность ввода дают одинаковый прогон на одной платформе.

## Точки расширения для v1.1
- `Difficulty` — таблица сложности («Новобранец / Ветеран / Кошмар»); `Difficulty.standard` равен v1.0,
  предварительные строки `recruit / veteran / nightmare` взяты из плана v1.1.
- `LevelSource` → `LevelLayout` — генератор станций по сиду вместо фиксированной `KelvinStation`.
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
| `GameDirector.swift` | этапы миссии, орды, опыт, улучшения |
| `GameHUD.swift` | тексты задачи и подсказок, статистика, лазеры |
| `GameDebug.swift` | отладочные хуки, бенчмарк |
