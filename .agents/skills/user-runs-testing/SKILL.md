---
name: user-runs-testing
description: >-
  Repository testing policy: agents build but do not test the app.
  Activates when the agent finishes or wants to verify a change by
  running, screenshotting, scripting, or otherwise exercising the app.
---

# The User Runs Testing

Develop and build features normally (`zig build`, see the
`building-the-app` skill), then stop. The user does all manual testing.

## Rules

- Do NOT run the app to verify your changes: no `zig build run`, no
  launching `zig-out/Niftty.app` or the Xcode intermediate bundle.
- Do NOT drive the app with AppleScript/`osascript`, System Events,
  accessibility APIs, or any other UI automation.
- Do NOT take screenshots or screen recordings to check your work, and
  do not use any browser/automation tooling against the app.
- Do NOT spawn watchers, replays, or long-running processes that wait
  for app behavior.

## What verification looks like instead

- A successful `zig build` (or the appropriate mode from the
  `building-the-app` skill) is your build verification.
- Plain `zig build test -Dtest-filter=<name>` is allowed when a change
  is covered by an existing unit test, but do not author new tests or
  test harnesses for the purpose of verifying UI/behavioral changes.
- Read the code you changed and reason about correctness. State what
  the user should check when they test.

## Reporting

When done, report what you built, the exact build command and result,
and a short list of what the user should try manually. Do not claim
behavioral verification you did not (and must not) perform.
