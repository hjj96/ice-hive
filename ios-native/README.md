# Ледяной Улей 2.0 — нативная версия (Swift + SpriteKit)

Нативный порт веб-игры (three.js, папка `game/`) на Swift + SpriteKit. Веб-версия — эталон и спецификация:
тот же геймплей, тот же русский интерфейс, тот же визуальный стиль.

## Сборка на Mac

```bash
brew install xcodegen
cd ios-native
xcodegen generate
open IceHive.xcodeproj
```

В Xcode: таргет **IceHive** → *Signing & Capabilities* → выберите свою **Team**, затем запустите на iPhone или симуляторе (⌘R).

Проект `IceHive.xcodeproj` генерируется из `project.yml` и в git не хранится — после изменения `project.yml`
или добавления файлов снова выполните `xcodegen generate`.

Аргументы запуска (Edit Scheme → Run → Arguments):

| Аргумент | Что делает |
|---|---|
| `-demo combat` | миссия штурмовиком, отряд неуязвим, автопилот, ~600 жуков вокруг (добавляются по ходу) |
| `-demo beacon` | миссия, отряд у маяка «Альфа», толпа жуков |
| `-demo title` | титульный экран (за ним — станция в режиме демонстрации) |
| `-demo smoke` | то же, что `combat` |
| `-seconds N` | через N секунд пишет в лог `demo done … avgFps=… minFps=…` |
| `-debugHUD` | отладочная панель (fps, время симуляции и отрисовки, жуки на экране, частицы, узлы) |
| `-class assault\|pyro\|cryo\|gunner`, `-seed N`, `-mute`, `-orient portrait\|landscape` | класс, сид, без звука, фиксированная ориентация |

Управление: левая половина экрана — плавающий стик бега, правая — прицел и огонь, кнопки способности и рывка справа.
С клавиатуры (симулятор): WASD/стрелки — бег, IJKL — прицел и огонь, пробел — рывок, Q/E — способность, Esc — пауза.

## Структура

| Путь | Что это |
|---|---|
| `project.yml` | спецификация XcodeGen (iOS 16+, только iPhone, bundle id `com.hjj96.icehive`, версия 2.0.0) |
| `IceHiveCore/` | Swift-пакет с чистой игровой логикой (только Foundation + simd), тесты: `cd IceHiveCore && swift test` |
| `App/Sources/App/` | AppDelegate, SceneDelegate, `GameViewController` (SKView, клавиатура), аргументы запуска, лог |
| `App/Sources/Game/` | `GameScene` — единственная сцена: фиксированный шаг 60 Гц с аккумулятором, события ядра, режимы (титул / миссия / карты улучшений / пауза / отчёт); `DemoScript` — сценарии CI |
| `App/Sources/Render/` | `Iso` (ортопроекция 3/4 из манифеста, z-слои), `SpriteAssets` (атласы + манифест), `WorldRenderer` и слои `LevelLayer` (станция из тайлов), `BugLayer`, `MarineLayer`, `FxLayer` + `GroundFx` + `Particles` (эффекты, пятна, трупы, телеграфы), `LightingLayer` (темнота и фонари — SKShader), `CameraController` |
| `App/Sources/UI/` | HUD (счёт, задача, отряд, броня, кнопки, стики, баннеры, таблички над бойцами), экраны титула / улучшений / паузы / отчёта |
| `App/Sources/Input/` | двойные стики (мультитач) и клавиатура |
| `App/Sources/Audio/` | звук на AVAudioPlayer по `Sounds/sounds-manifest.json` |
| `App/Resources/` | `Assets.xcassets` (иконка, атласы `*.spriteatlas`), `Info.plist`, `PrivacyInfo.xcprivacy`, `LaunchScreen.storyboard`, шрифты, звуки |
| `tools/` | node-скрипты, которые пре-рендерят ассеты из веб-игры |
| `ci/` | вспомогательные скрипты CI |

## CI

`.github/workflows/native-ios.yml` запускается на push в ветки `native*` (macOS-раннер GitHub): `swift test` для ядра,
сборка под симулятор, затем на симуляторе по очереди `-demo combat`, `beacon`, `title` и `combat` в альбомной ориентации
со скриншотами. Результаты коммитятся в ветку `ci-results` в папку `<ветка>/<короткий sha>/` (`status.json`,
`build.log`, `core-tests.log`, `combat-10s.png` … `landscape-14s.png`, `app-<демо>.log`, `fps.txt`, `alive.txt`, `app.log`).
