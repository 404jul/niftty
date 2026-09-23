---
name: working-on-rendering
description: >-
  Guides changes to Niftty rendering, cells, glyphs, images, cursors, overlays,
  shaders, Metal, OpenGL, renderer threads, frame state, and GPU resources.
---

# Working on Rendering

The renderer consumes terminal state; it does not own terminal semantics.
Protocol parsing and screen mutation stay under `src/terminal`. Platform window
setup stays in the application runtime.

## Entry points

| Concern | Canonical owner |
|---|---|
| Public renderer selection/types | `src/renderer.zig` |
| Shared terminal/render state and locking | `src/renderer/State.zig` |
| Render thread and mailbox | `src/renderer/Thread.zig`, `message.zig` |
| Backend-independent frame construction | `src/renderer/generic.zig` |
| Cell and row generation | `src/renderer/cell.zig`, `row.zig` |
| Images | `src/renderer/image.zig` |
| Cursor and overlays | `src/renderer/cursor.zig`, `Overlay.zig` |
| Metal adapter | `src/renderer/Metal.zig`, `src/renderer/metal/` |
| OpenGL adapter | `src/renderer/OpenGL.zig`, `src/renderer/opengl/` |
| Shader sources | `src/renderer/shaders/` |
| Surface draw trigger | `src/Surface.zig` |
| macOS layer/view host | `macos/Sources/Helpers/MetalView.swift`, `macos/Sources/Surface View/` |

`generic.Renderer(GraphicsAPI)` defines the backend contract. Keep shared frame
logic there; put only API resource and command encoding details in Metal or
OpenGL implementations.

## Invariants

- Hold `generic.Renderer.draw_mutex` whenever accessing state used by
  `drawFrame`.
- Follow `renderer.State.lockDemand`/`unlockDemand` for demanding terminal-state
  readers; the renderer-state mutex is the synchronization boundary.
- Respect GPU resource lifecycle: no creation while the display is unrealized,
  and hidden surfaces may release their swap chain.
- Avoid per-frame allocation, buffer recreation, redundant state conversion, or
  terminal-state copying. Reuse swap-chain frame state and dirty flags.
- Keep Metal and OpenGL output behavior aligned unless the feature is explicitly
  backend-specific.
- A render-thread event that needs UI work must use the existing mailbox/action
  path; never mutate AppKit or GTK state directly.
- Update both hand-written Metal shaders and generated/GLSL paths when the
  pipeline contract is shared.

## User-facing feature integration

A rendering feature that users can toggle or invoke should expose a documented
`Binding.Action` when that interaction is meaningful. Any tunable renderer
behavior must have a documented `Config` field and an entry in the graphical
Settings page; ensure `SettingsModel.category(for:)` places it under Appearance
or another deliberate category. Read
`.agents/skills/working-on-configuration/SKILL.md` for both registration paths.
