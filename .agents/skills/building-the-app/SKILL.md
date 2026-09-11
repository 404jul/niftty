---
name: building-the-app
description: >-
  Builds, rebuilds, runs, or locates the Niftty macOS application.
  Activates when the user asks to build, compile, rebuild, run, launch,
  or verify changes with an application build.
---

# Building the Application

Use the repository's Zig build graph as the single entry point. It prepares
all Zig libraries and resources, invokes Xcode for the Swift application, and
installs the completed bundle at a stable path.

## Canonical build

Run this from the repository root:

```sh
zig build
```

This is the complete debug application build. Do not add an optimization flag
unless the user requests an optimized build.

The canonical output is:

```text
zig-out/Niftty.app
```

Verify that the command succeeds and that both the bundle and its executable
exist at:

```text
zig-out/Niftty.app/Contents/MacOS/niftty
```

Report `zig-out/Niftty.app` as the build artifact. Xcode's
`macos/build/Debug/Niftty.app` is an intermediate product, not the canonical
artifact.

## Other build modes

- Optimized local app, only when requested:

  ```sh
  zig build -Doptimize=ReleaseFast
  ```

  The canonical output remains `zig-out/Niftty.app`; the Xcode intermediate
  uses `macos/build/ReleaseLocal/Niftty.app`.

- Build and run for a developer smoke test:

  ```sh
  zig build run
  ```

  This builds a native-architecture app and runs it from the Xcode intermediate
  directory. It does not replace `zig build` when the task requires the
  canonical `zig-out/Niftty.app` artifact.

- Zig/core-only build when the macOS app is explicitly unnecessary:

  ```sh
  zig build -Demit-macos-app=false
  ```

  Never use this mode to verify Swift, AppKit, SwiftUI, application packaging,
  or a request to build the app. Never claim that it produced an app bundle.

## Rules

- Always run build commands from the repository root.
- Use the Zig version required by `build.zig.zon` and the Xcode toolchain
  required by `HACKING.md`.
- Do not invoke `xcodebuild` or `swift build` directly for a complete app
  build. They bypass part of the Zig-owned dependency and install graph. Use
  them only when a task explicitly requests isolated Xcode-layer work.
- Do not pass `--prefix` for a normal local app build; it changes the canonical
  output location.
- Do not copy or move the resulting bundle to a different output directory
  unless the user explicitly requests it.
- Tests are separate from the app build. Use the targeted `zig build test`
  commands in `AGENTS.md`; a test command is not evidence that
  `zig-out/Niftty.app` was built.
- In the final report, name the exact build command used and the artifact path.
  If only a core-only build or test ran, state that no application bundle was
  produced.
