---
name: working-on-terminal-core
description: >-
  Guides changes to terminal parsing, escape sequences, screen and grid state,
  scrollback, selection, search, clipboard protocols, terminal I/O, PTY, and
  input encoding in Niftty's Zig core.
---

# Working on the Terminal Core

Keep protocol semantics and renderer-independent terminal state under
`src/terminal`. Keep subprocess, PTY, byte-stream, and worker-thread behavior
under `src/termio`. `src/Surface.zig` coordinates terminal I/O, UI requests,
bindable actions, and renderer state.

## Entry points

| Concern | Start here |
|---|---|
| Public terminal types | `src/terminal/main.zig` |
| Parser state machine | `src/terminal/Parser.zig`, `src/terminal/parse_table.zig` |
| Parser-to-terminal application | `src/terminal/stream_terminal.zig` |
| Terminal model | `src/terminal/Terminal.zig` |
| Main/alternate screen state | `src/terminal/Screen.zig`, `ScreenSet.zig` |
| Pages and scrollback | `src/terminal/PageList.zig`, `page.zig` |
| Selection | `src/terminal/Selection.zig`, `SelectionGesture.zig` |
| Search | `src/terminal/search/` |
| OSC protocols | `src/terminal/osc.zig`, `src/terminal/osc/parsers/` |
| Kitty protocols | `src/terminal/kitty/` |
| Terminal I/O state | `src/termio/Termio.zig` |
| Stream callback bridge | `src/termio/stream_handler.zig` |
| I/O messages and thread | `src/termio/message.zig`, `Thread.zig` |
| Surface coordination/actions | `src/Surface.zig` |
| Keyboard encoding | `src/input/key_encode.zig` |

## Data flow

```text
PTY bytes
  -> termio backend/thread
  -> terminal stream parser
  -> stream handler
  -> Terminal/Screen/PageList mutation under renderer-state mutex
  -> renderer wakeup
  -> renderer snapshots terminal state
```

For input, platform events become `input.KeyEvent`, pass through keybinding
resolution, and otherwise reach terminal encoding and the PTY.

## Rules

- Put escape-sequence parsing in the protocol parser and state mutation in the
  terminal handler/model. Do not teach the UI to interpret terminal protocols.
- Preserve parser fragmentation behavior: an escape sequence may arrive across
  arbitrary read boundaries.
- Treat terminal/page pins, selections, and renderer snapshots according to
  their documented lifetime and locking requirements.
- Avoid allocation and copying on the byte-stream and frame paths. Reuse buffers
  and existing mailbox payload types.
- When a terminal event requires UI work, send it through the existing surface
  mailbox or `apprt.Action`; never call a platform UI directly from an I/O or
  renderer thread.
- Use the closest targeted Zig test command from `AGENTS.md`; libghostty-vt files
  use `zig build test-lib-vt -Dtest-filter=<filter>`.

## User-facing feature integration

If terminal-core work creates a user-invoked operation, evaluate it as a
`Binding.Action` in `src/input/Binding.zig` and implement it through
`Surface.performBindingAction`. A documented action is automatically included in
the graphical keybind editor catalog unless it is the internal `cursor_key`
action.

If behavior is configurable, declare and document it in `src/config/Config.zig`,
thread it into the smallest derived config that consumes it, and ensure the
macOS graphical Settings page categorizes it. Read
`.agents/skills/working-on-configuration/SKILL.md`.
