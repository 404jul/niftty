---
name: working-on-macos-ui
description: >-
  Guides changes to Niftty's macOS Swift, SwiftUI, AppKit, windows, tabs,
  splits, menus, settings, action dispatch, restoration, and Zig bridge.
  Activates for macOS UI or Apple-platform application behavior.
---

# Working on the macOS UI

Read `macos/AGENTS.md` before changing files in `macos/`. Keep reusable terminal
and application behavior in Zig; keep Cocoa presentation and Apple APIs here.

## Entry points

| Concern | Canonical owner |
|---|---|
| Application startup, menu wiring, config reload | `macos/Sources/App/AppDelegate.swift` |
| Zig callback and action dispatch | `macos/Sources/Ghostty/Ghostty.App.swift` |
| Swift wrappers for config, surface, input | `macos/Sources/Ghostty/` |
| Window and tab behavior | `macos/Sources/Features/Terminal/` |
| Split presentation and model | `macos/Sources/Features/Splits/` |
| Settings window | `macos/Sources/Features/Settings/` |
| Surface/AppKit input and display | `macos/Sources/Surface View/SurfaceView_AppKit.swift` |
| SwiftUI surface composition | `macos/Sources/Surface View/SurfaceView.swift` |
| Menu definitions | `macos/Sources/App/MainMenu.xib` |
| Restorable terminal state | `macos/Sources/Features/Terminal/TerminalRestorable.swift` |

## Action path

Bindable actions originate in `src/input/Binding.zig`. Surface-local behavior is
handled by `Surface.performBindingAction` in `src/Surface.zig`. Platform behavior
is converted to `src/apprt/action.zig`, crosses the embedded C ABI, and reaches
`Ghostty.App.action` in `macos/Sources/Ghostty/Ghostty.App.swift`.

When adding a platform action:

1. Prefer an existing `apprt.Action` and target.
2. If a new app-runtime action is necessary, append it as directed by the guide
   in `src/apprt/action.zig`; preserve enum order and ABI layout.
3. Update `include/ghostty.h` in the same order.
4. Handle it in `Ghostty.App.action`; return `false` when the operation is not
   supported or cannot be performed.
5. Check other runtimes for exhaustive switches and intentional unsupported
   behavior.

Do not bypass the action path with a parallel Swift notification or singleton
when the core already owns the command.

## Feature integration

For every new user-visible macOS feature:

- Decide whether invoking or toggling it is a sensible repeatable command. If
  yes, add a documented `Binding.Action`; this registers it in the graphical
  keybind editor automatically through `ghostty_config_keybind_data`.
- Decide which state is user-configurable. Add the corresponding shared config
  option and ensure it appears in the graphical Settings page under the correct
  category. Read `.agents/skills/working-on-configuration/SKILL.md`.
- If an action or setting is intentionally inappropriate, state why in the final
  report.
- Update restoration when the feature changes persistent window, tab, split, or
  workspace state.
- Update menu state/validation when a command is also represented in a menu.

## Swift constraints

- Support the repository's pinned CI Xcode, not only the local compiler.
- Private nested structs with private stored properties need an explicit `init`.
- Follow existing controller/model ownership. Avoid introducing another global
  source of truth.
- Perform AppKit view/window mutations on the main thread.
- Use `swiftlint lint --strict --fix` for Swift formatting as directed by
  `macos/AGENTS.md`.

## Verification

A macOS source change requires the canonical app build from the repository root
as described by `.agents/skills/building-the-app/SKILL.md`. Follow the repository
policy in `.agents/skills/user-runs-testing/SKILL.md` for interactive testing.
