# Working on Kira

- Domain logic lives in `Kira/Packages/KiraCore` (Foundation only). Run `swift test` there after any change; all money is integer sen.
- iOS UI must follow Apple's Human Interface Guidelines. `docs/DESIGN.md` records each rule and where it's implemented. Liquid Glass is for the functional layer only (bars, menus, controls), never content.
- For any SwiftUI work, use the `swiftui-expert-skill` in `.claude/skills/` and satisfy its correctness checklist. For motion and design polish, see `apple-design` and `emil-design-eng`. For Swift language and concurrency, see `write-swift`.
- Gate iOS 26+ APIs with `#available` (deployment target is iOS 18). Shared helpers are in `Kira/DesignSystem/LiquidGlass.swift`.
- Never present unconfirmed payments as confirmed, or forecasts as balances.
