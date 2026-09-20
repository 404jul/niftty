---
name: stage-safe
description: >-
  Stage only files that belong to the current change. Never git add .
  or git add -A. Update .gitignore for build artifacts, editor files,
  and local tooling. Use when staging, committing, git add, finishing
  a change, or when untracked junk appears.
---

# Stage Safe

The user should not need `git add .`. You stage the files.

## Do

1. Stage by explicit path: only files you changed for this task.
2. If a file is local, generated, or tooling, add a `.gitignore` rule
   instead of staging it.
3. Commit only when asked. Never push.

## Never stage

- Build products: `*.xcframework`, `*.a`, `zig-out/`, `DerivedData/`,
  `*.xcarchive`
- Editor/agent local: `.v2c/`, `.zcodeignore`, `.DS_Store`, `.vscode/`
- Secrets: `*.pem`, `*.p12`, `*.key`, `*.p8`
- `skills-lock.json` unless that skill is in the same commit
- Unrelated dirty files already in the working tree

## Never run

`git add .`  `git add -A`  `git add --all`  `git add *`

## After a task

`git add path/to/file ...` for the change. Leave everything else unstaged.
