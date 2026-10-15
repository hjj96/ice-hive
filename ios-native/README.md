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

Аргументы запуска (Edit Scheme → Run → Arguments): `-debugHUD` (FPS/ноды/draw calls; в Debug всегда включено),
`-demo <имя>` (сценарий демо, CI использует `-demo smoke`), `-seconds N` (длительность сценария).

## Структура

| Путь | Что это |
|---|---|
| `project.yml` | спецификация XcodeGen (iOS 16+, только iPhone, bundle id `com.hjj96.icehive`, версия 2.0.0) |
| `IceHiveCore/` | Swift-пакет с чистой игровой логикой (только Foundation + simd), тесты: `cd IceHiveCore && swift test` |
| `App/Sources/` | приложение: UIKit + SpriteKit |
| `App/Resources/` | `Assets.xcassets` (иконка, атласы `*.spriteatlas`), `Info.plist`, `PrivacyInfo.xcprivacy`, `LaunchScreen.storyboard`, шрифты, звуки |
| `tools/` | node-скрипты, которые пре-рендерят ассеты из веб-игры |
| `ci/` | вспомогательные скрипты CI |

## CI

`.github/workflows/native-ios.yml` запускается на push в ветки `native*` (macOS-раннер GitHub): `swift test` для ядра,
сборка под симулятор, smoke-запуск на симуляторе со скриншотами. Результаты коммитятся в ветку `ci-results`
в папку `<ветка>/<короткий sha>/` (`status.json`, `build.log`, `core-tests.log`, `sim-*.png`, `app.log`).
