---
name: working-on-configuration
description: >-
  Guides changes to Niftty configuration fields, parsing, formatting, defaults,
  derived config, graphical Settings pages, graphical keybind editor, config
  reload, and configuration documentation.
---

# Working on Configuration

`src/config/Config.zig` is the source of truth for configuration fields,
defaults, and user-facing documentation. Do not create a platform-only setting
when the core can own the same behavior.

## Configuration path

```text
Config field and docs (`src/config/Config.zig`)
  -> generated key/help metadata
  -> parsing/finalization (`src/config`)
  -> derived config in the consuming subsystem
  -> graphical editor JSON (`src/config/CApi.zig`)
  -> Swift wrapper (`macos/Sources/Ghostty/Ghostty.Config.swift`)
  -> Settings model/view (`macos/Sources/Features/Settings/`)
```

## Adding or changing an option

1. Add the field and complete documentation to `src/config/Config.zig` using the
   established naming, type, and default conventions.
2. Update parsing, cloning, formatting, finalization, conditional handling, or
   C getters only when the field's type requires it. Reuse an existing config
   type rather than creating a parallel parser.
3. Copy the value into the smallest subsystem `DerivedConfig` that needs it.
   Config pointers are not long-lived state.
4. Apply reload behavior through the existing config-change path. Distinguish
   settings that require new surfaces or application restart in their docs.
5. Confirm the graphical editor representation from `configEditorData` in
   `src/config/CApi.zig`:
   - booleans become a true/false picker;
   - enums become a picker with a custom-value escape hatch;
   - other types become text;
   - repeatable values serialize as multiple lines.
6. Ensure `SettingsModel.category(for:)` in
   `macos/Sources/Features/Settings/SettingsModel.swift` places the option in the
   intended Settings section. Do not allow a new option to fall into `Terminal`
   accidentally.
7. If the generic editor cannot represent the setting safely, add a dedicated
   page using the existing `Shaders` or `Keybinds` ownership pattern rather than
   silently omitting it.

Every non-private `Config` field is reflected into the graphical editor by
`configEditorData`; underscore-prefixed fields are excluded. `SettingsModel`
filters the raw `keybind` field because the dedicated Keybinds page owns it.

## Keybind editor registration

The bindable action catalog is not a hand-maintained Swift list. It is generated
by `configKeybindData` in `src/config/CApi.zig`, which reflects over
`input.Binding.Action` from `src/input/Binding.zig` and reads the generated help
text.

To add a keybindable operation:

1. Add a semantically named union field to `Binding.Action`.
2. Give it complete doc comments; those docs are displayed in the editor.
3. Use an existing parameter type and its `default` convention where possible.
4. Implement action scope and execution in the existing `Binding.Action`
   helpers and `Surface.performBindingAction`/application path.
5. If it crosses the app-runtime boundary, update `src/apprt/action.zig`,
   `include/ghostty.h`, and each relevant runtime dispatcher.
6. Do not add `cursor_key`-style internal actions to the editor; it is explicitly
   excluded because it cannot be expressed in configuration text.

The macOS editor loads this catalog through
`Ghostty.Config.keybindData()` and `KeybindsModel.reload()`. Do not duplicate the
catalog in Swift.

## Feature gate

Every new user-facing feature must be evaluated for both integrations:

- a documented bindable action when invocation/toggling is meaningful;
- a graphical Settings entry for every user-configurable option.

If either is deliberately inapplicable, include the reason in the final report.
