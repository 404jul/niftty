# macOS Niftty Application

- Use `swiftlint` for formatting and linting Swift code.
- For every macOS app build, follow
  `.agents/skills/building-the-app/SKILL.md`.
- Run the canonical `zig build` command from the repository root. The app
  artifact is `zig-out/Niftty.app`.
- Run macOS unit tests through unfiltered `zig build test` from the repository
  root. `-Dtest-filter` filters Zig tests and skips the Xcode test suite.

## AppleScript

- The AppleScript scripting definition is in `macos/Ghostty.sdef`.
- Guard AppleScript entry points and object accessors with the
  `macos-applescript` configuration (use `NSApp.isAppleScriptEnabled`
  and `NSApp.validateScript(command:)` where applicable).
- In `macos/Ghostty.sdef`, keep top-level definitions in this order:
  1. Classes
  2. Records
  3. Enums
  4. Commands
- Test AppleScript support:
  (1) Build with `zig build` from the repository root.
  (2) Launch and activate the app via osascript using the absolute path
      to the built app bundle:
      `osascript -e 'tell application "<absolute path to zig-out/Niftty.app>" to activate'`
  (3) Wait a few seconds for the app to fully launch and open a terminal.
  (4) Run test scripts with `osascript`, always targeting the app by
      its absolute path (not by name) to avoid calling the wrong
      application.
  (5) When done, quit via:
      `osascript -e 'tell application "<absolute path to zig-out/Niftty.app>" to quit'`
