# Kira — Malaysian personal finance tracker (iOS)

Native SwiftUI app (iOS 18+) plus `KiraCore`, a platform-independent Swift package that holds all financial logic.

## Requirements
- Xcode 16 or later (Swift 6 toolchain, iOS 18 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & run
```sh
cd Kira
xcodegen generate          # creates Kira.xcodeproj from project.yml
open Kira.xcodeproj        # set your Development Team, then Run on an iOS 18 simulator or device
```
The scheme uses `Kira/Resources/Kira.storekit`, so subscriptions can be tested locally without App Store Connect.

## Tests
```sh
# Domain logic — runs on macOS or Linux (no simulator needed)
cd Kira/Packages/KiraCore && swift test

# App integration + UI tests — in Xcode: Product › Test (⌘U), or:
xcodebuild test -project Kira.xcodeproj -scheme Kira -destination 'platform=iOS Simulator,name=iPhone 16'
```
UI tests launch with `-uiTesting`, which uses an in-memory store and skips onboarding.

## Status of this build
- `KiraCore`: built and **122/122 tests passing** with Swift 6.0.3 (Linux CI container).
- iOS app target: **not compiled in the authoring environment** (no Xcode there). Expect to fix minor compile issues on first build. See `docs/BACKLOG.md` B-1.
- Real-device-only items (Wallet automation, camera, Face ID, file protection) are listed in `docs/FEASIBILITY.md`.

## Docs
`../docs/`: PRD, ARCHITECTURE, FEASIBILITY (integration matrix & limitations), DATA_MODEL, SCREENS, BACKLOG, SECURITY (threat model), PRIVACY_POLICY_DRAFT, APP_STORE_CHECKLIST.
