---
name: navigating-niftty
description: >-
  Locates existing features and traces implementations in Niftty. Activates
  when changing, debugging, or explaining a feature, behavior, subsystem,
  user-visible command, configuration option, terminal behavior, renderer
  behavior, window/tab/split behavior, keyboard handling, or a Swift-to-Zig
  boundary.
---

# Navigating Niftty

Use this map before searching the repository. Start from the narrowest stable
entry point, then follow definitions and references with the language server.
Use text search only when the map and symbol graph do not identify the owner.

## Architecture

```text
macOS event or view (`macos/Sources`)
    <-> embedded C API (`src/apprt/embedded.zig`, `include/ghostty.h`)
    <-> application/surface coordination (`src/App.zig`, `src/Surface.zig`)
    <-> terminal I/O (`src/termio`)
    <-> terminal state (`src/terminal`)
    -> render snapshot (`src/renderer/State.zig`)
    -> renderer (`src/renderer`)
```

The GTK runtime lives under `src/apprt/gtk`. Shared behavior belongs in the Zig
core unless it genuinely depends on a platform API or platform presentation.

## Feature map

| Request language | Start here | Continue through |
|---|---|---|
| macOS application lifecycle, menus, global shortcuts | `macos/Sources/App/AppDelegate.swift` | `macos/Sources/Ghostty/Ghostty.App.swift`, `src/App.zig` |
| Terminal window, tab, title, restoration | `macos/Sources/Features/Terminal/` | `BaseTerminalController.swift`, `TerminalController.swift`, `src/apprt/action.zig` |
| Splits | `macos/Sources/Features/Splits/` | `BaseTerminalController.swift`, `src/Surface.zig` |
| Zen mode | `macos/Sources/Features/Zen/` | `Ghostty.App.swift`, `src/apprt/action.zig` |
| Quick terminal | `macos/Sources/Features/QuickTerminal/` | `Ghostty.App.swift`, `src/input/Binding.zig` |
| Command palette | `macos/Sources/Features/Command Palette/` | `src/input/Binding.zig`, `src/Surface.zig` |
| Settings and config GUI | `macos/Sources/Features/Settings/` | `src/config/Config.zig`, `src/config/CApi.zig` |
| Keybindings and bindable commands | `src/input/Binding.zig` | `src/Surface.zig`, `src/apprt/action.zig`, platform action dispatch |
| Keyboard encoding | `src/input/` | `src/Surface.zig`, platform event conversion |
| PTY, subprocess, byte stream | `src/termio/Termio.zig` | `src/termio/stream_handler.zig`, `src/termio/Thread.zig` |
| Escape sequence or terminal semantics | `src/terminal/Parser.zig` and `src/terminal/stream_terminal.zig` | `src/terminal/Terminal.zig`, `Screen.zig`, protocol-specific files |
| Grid, selection, scrollback, search | `src/terminal/` | `PageList.zig`, `Screen.zig`, `Selection.zig`, `search/` |
| Drawing, cells, images, shaders | `src/renderer/generic.zig` | `cell.zig`, `image.zig`, `shaders/`, backend implementation |
| macOS Metal backend | `src/renderer/Metal.zig` | `src/renderer/metal/`, `macos/Sources/Helpers/MetalView.swift` |
| GTK runtime or OpenGL | `src/apprt/gtk/` | `src/renderer/OpenGL.zig`, `src/renderer/opengl/` |
| C or embedding API | `include/ghostty.h` | `src/main_c.zig`, `src/apprt/embedded.zig` |
| Shell integration | `src/shell-integration/` | `src/termio/shell_integration.zig`, terminal OSC handlers |

## Tracing rules

1. Identify the owning layer from the table.
2. Read that file's containing construct, not an isolated match.
3. For known symbols, use LSP definition, implementation, and references. Before
   changing an exported symbol, inspect every reference.
4. Trace both directions across a boundary: producer and consumer, action sender
   and handler, config declaration and derived config, state mutation and render.
5. Search narrowly only for protocol strings, config key spellings, C enum names,
   notification names, or other data that LSP cannot follow.
6. Reuse the existing boundary and message type. Do not create a second route for
   an action, setting, or state update.

## User-facing feature gate

Before considering a user-facing feature complete, follow the **Feature
Integration** rules in the repository `AGENTS.md`.

- If the behavior is a sensible repeatable command, make it a documented action
  in `src/input/Binding.zig`; the keybind editor catalog is generated from that
  union by `src/config/CApi.zig`.
- If the feature is configurable, expose its option in `src/config/Config.zig`
  and ensure `SettingsModel.category(for:)` puts it in the intended graphical
  Settings section.
- Trace platform dispatch for any app-runtime action and update the C ABI when
  the action crosses it.
- If either integration is intentionally inapplicable, record the concrete
  reason in the final report rather than silently omitting it.

## More specific skills

Read the matching skill before editing:

- `.agents/skills/working-on-macos-ui/SKILL.md`
- `.agents/skills/working-on-terminal-core/SKILL.md`
- `.agents/skills/working-on-configuration/SKILL.md`
- `.agents/skills/working-on-rendering/SKILL.md`
