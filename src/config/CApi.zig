const builtin = @import("builtin");
const std = @import("std");
const inputpkg = @import("../input.zig");
const global = @import("../global.zig");
const String = @import("../main_c.zig").String;

const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const formatter = @import("formatter.zig");
const help_strings = @import("help_strings");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc()) catch |err| {
        log.err("error creating config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc().destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(global.alloc()) catch |err| {
        log.err("error cloning config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    const path_slice = std.mem.span(path);
    self.loadFile(global.alloc(), path_slice) catch |err| {
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

export fn ghostty_config_open_path() String {
    const path = edit.openPath(global.alloc()) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

/// Return the complete effective configuration as JSON for graphical editors.
/// The returned string must be freed with ghostty_string_free.
export fn ghostty_config_editor_data(self: *Config) String {
    return configEditorData(self) catch |err| {
        log.err("error generating config editor data err={}", .{err});
        return .empty;
    };
}

/// Return the keybinding state for graphical editors as JSON. This includes
/// every effective binding (defaults plus user configuration), whether each
/// binding matches the built-in defaults, and a catalog of all bindable
/// actions with their documentation. The returned string must be freed with
/// ghostty_string_free.
export fn ghostty_config_keybind_data(self: *Config) String {
    return configKeybindData(self) catch |err| {
        log.err("error generating config keybind data err={}", .{err});
        return .empty;
    };
}

/// Parse and validate a single `keybind =` line value (for example
/// `cmd+shift+c=copy_to_clipboard`) using the same parser as the real
/// configuration. Returns JSON describing the canonical form of the binding,
/// or an error message if it is invalid. Table prefixes (`name/`) are not
/// handled here; callers validate the binding portion and re-add the prefix.
/// The returned string must be freed with ghostty_string_free.
export fn ghostty_keybind_parse(str: [*]const u8, len: usize) String {
    return keybindParse(str[0..len]) catch |err| {
        log.err("error parsing keybind err={}", .{err});
        return .empty;
    };
}

/// One flattened keybinding: a full trigger sequence (sequences are joined
/// with `>`) mapped to one or more actions (chained actions), within an
/// optional key table.
const KeybindEntry = struct {
    table: ?[]const u8,
    trigger: []const u8,
    actions: []const []const u8,
    flags: inputpkg.Binding.Flags,
};

fn keybindEntries(
    alloc: Allocator,
    keybinds: Config.Keybinds,
) Allocator.Error![]KeybindEntry {
    var list: std.ArrayList(KeybindEntry) = .empty;
    errdefer list.deinit(alloc);
    try keybindEntriesSet(alloc, &keybinds.set, null, "", &list);
    var table_iter = keybinds.tables.iterator();
    while (table_iter.next()) |table_entry| {
        try keybindEntriesSet(
            alloc,
            &table_entry.value_ptr.*,
            table_entry.key_ptr.*,
            "",
            &list,
        );
    }
    return list.toOwnedSlice(alloc);
}

fn keybindEntriesSet(
    alloc: Allocator,
    set: *const inputpkg.Binding.Set,
    table: ?[]const u8,
    prefix: []const u8,
    list: *std.ArrayList(KeybindEntry),
) Allocator.Error!void {
    var iter = set.bindings.iterator();
    while (iter.next()) |entry| {
        var trigger: std.Io.Writer.Allocating = .init(alloc);
        defer trigger.deinit();
        trigger.writer.writeAll(prefix) catch return error.OutOfMemory;
        trigger.writer.print("{f}", .{entry.key_ptr.*}) catch return error.OutOfMemory;

        switch (entry.value_ptr.*) {
            .leader => |sub| try keybindEntriesSet(
                alloc,
                sub,
                table,
                try std.fmt.allocPrint(alloc, "{s}>", .{trigger.written()}),
                list,
            ),

            .leaf, .leaf_chained => {
                const generic = switch (entry.value_ptr.*) {
                    .leaf => |*leaf| leaf.generic(),
                    .leaf_chained => |*leaf| leaf.generic(),
                    else => unreachable,
                };
                var actions: std.ArrayList([]const u8) = .empty;
                errdefer actions.deinit(alloc);
                for (generic.actionsSlice()) |action| {
                    var formatted: std.Io.Writer.Allocating = .init(alloc);
                    errdefer formatted.deinit();
                    action.format(&formatted.writer) catch return error.OutOfMemory;
                    actions.append(alloc, try formatted.toOwnedSlice()) catch
                        return error.OutOfMemory;
                }
                list.append(alloc, .{
                    .table = table,
                    .trigger = try alloc.dupe(u8, trigger.written()),
                    .actions = try actions.toOwnedSlice(alloc),
                    .flags = generic.flags,
                }) catch return error.OutOfMemory;
            },
        }
    }
}

fn keybindEntryIsDefault(
    self: KeybindEntry,
    defaults: []const KeybindEntry,
) bool {
    for (defaults) |default| {
        if (default.table == null and self.table != null) continue;
        if (default.table != null and self.table == null) continue;
        if (self.table) |t| {
            if (!std.mem.eql(u8, t, default.table.?)) continue;
        }
        if (!std.mem.eql(u8, self.trigger, default.trigger)) continue;
        if (self.actions.len != default.actions.len) continue;
        for (self.actions, default.actions) |a, b| {
            if (!std.mem.eql(u8, a, b)) continue;
        }
        if (self.flags.cval() != default.flags.cval()) continue;
        return true;
    }
    return false;
}

fn configKeybindData(self: *Config) !String {
    const alloc = global.alloc();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var defaults = try Config.default(arena);
    try defaults.finalize();
    const default_entries = try keybindEntries(arena, defaults.keybind);
    const current_entries = try keybindEntries(arena, self.keybind);

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };

    try json.beginObject();
    try json.objectField("bindings");
    try json.beginArray();
    for (current_entries) |entry| {
        try json.beginObject();
        try json.objectField("trigger");
        try json.write(entry.trigger);
        try json.objectField("actions");
        try json.beginArray();
        for (entry.actions) |action| try json.write(action);
        try json.endArray();
        try json.objectField("table");
        try json.write(entry.table);
        try json.objectField("default");
        try json.write(keybindEntryIsDefault(entry, default_entries));
        try json.objectField("flags");
        try json.beginObject();
        try json.objectField("all");
        try json.write(entry.flags.all);
        try json.objectField("global");
        try json.write(entry.flags.global);
        try json.objectField("consumed");
        try json.write(entry.flags.consumed);
        try json.objectField("performable");
        try json.write(entry.flags.performable);
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("actions");
    try json.beginArray();
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(inputpkg.Binding.Action).@"union".fields) |field| {
        // cursor_key bindings cannot be expressed in configuration text
        // (Action.parse rejects them) so they are not offered.
        if (field.type == inputpkg.Binding.Action.CursorKey) continue;

        try json.beginObject();
        try json.objectField("name");
        try json.write(field.name);
        try json.objectField("docs");
        try json.write(if (@hasDecl(help_strings.KeybindAction, field.name))
            @field(help_strings.KeybindAction, field.name)
        else
            "");
        try json.objectField("parameter");
        try json.write(switch (field.type) {
            void => "none",
            []const u8 => "required",
            else => parameter: {
                switch (@typeInfo(field.type)) {
                    .@"struct", .@"union", .@"enum" => {
                        if (comptime @hasDecl(field.type, "default")) {
                            break :parameter "optional";
                        }
                    },
                    else => {},
                }
                break :parameter "required";
            },
        });
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();

    return .fromSlice(try output.toOwnedSlice());
}

fn keybindParseError(alloc: Allocator, message: []const u8) !String {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("ok");
    try json.write(false);
    try json.objectField("error");
    try json.write(message);
    try json.endObject();
    return .fromSlice(try output.toOwnedSlice());
}

fn keybindParse(str: []const u8) !String {
    const alloc = global.alloc();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser = inputpkg.Binding.Parser.init(str) catch |err| {
        return keybindParseError(alloc, switch (err) {
            error.InvalidFormat => "invalid keybind format",
            error.InvalidAction => "unknown action or invalid action parameter",
        });
    };

    var triggers: std.ArrayList([]const u8) = .empty;
    var actions: std.ArrayList([]const u8) = .empty;
    var flags: inputpkg.Binding.Flags = .{};
    var chain = false;
    while (true) {
        const elem = parser.next() catch |err| {
            return keybindParseError(alloc, switch (err) {
                error.InvalidFormat => "invalid keybind format",
                error.InvalidAction => "unknown action or invalid action parameter",
            });
        } orelse break;

        switch (elem) {
            .leader => |trigger| {
                var formatted: std.Io.Writer.Allocating = .init(arena);
                try formatted.writer.print("{f}", .{trigger});
                try triggers.append(arena, try arena.dupe(u8, formatted.written()));
            },
            .binding => |binding| {
                var formatted: std.Io.Writer.Allocating = .init(arena);
                try formatted.writer.print("{f}", .{binding.trigger});
                try triggers.append(arena, try arena.dupe(u8, formatted.written()));
                var action: std.Io.Writer.Allocating = .init(arena);
                try binding.action.format(&action.writer);
                try actions.append(arena, try arena.dupe(u8, action.written()));
                flags = binding.flags;
            },
            .chain => |action| {
                chain = true;
                var formatted: std.Io.Writer.Allocating = .init(arena);
                try action.format(&formatted.writer);
                try actions.append(arena, try arena.dupe(u8, formatted.written()));
            },
        }
    }

    if (actions.items.len == 0) {
        return keybindParseError(alloc, "invalid keybind format");
    }

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("ok");
    try json.write(true);
    try json.objectField("trigger");
    try json.write(std.mem.join(arena, ">", triggers.items) catch
        return error.OutOfMemory);
    try json.objectField("actions");
    try json.beginArray();
    for (actions.items) |action| try json.write(action);
    try json.endArray();
    try json.objectField("chain");
    try json.write(chain);
    try json.objectField("flags");
    try json.beginObject();
    try json.objectField("all");
    try json.write(flags.all);
    try json.objectField("global");
    try json.write(flags.global);
    try json.objectField("consumed");
    try json.write(flags.consumed);
    try json.objectField("performable");
    try json.write(flags.performable);
    try json.endObject();
    try json.endObject();
    return .fromSlice(try output.toOwnedSlice());
}

/// Compile a ShaderToy-style GLSL shader file to Metal Shading Language
/// source that can be used to build an MTLLibrary. The returned string
/// must be freed with ghostty_string_free.
export fn ghostty_shader_msl(path: [*:0]const u8) String {
    const shadertoy = @import("../renderer/shadertoy.zig");

    const msl = shadertoy.loadFromFile(
        global.alloc(),
        std.mem.span(path),
        .msl,
    ) catch |err| {
        log.err("error compiling shader to msl path={s} err={}", .{ path, err });
        return .empty;
    };

    return .fromSlice(msl);
}

fn configEditorData(self: *Config) !String {
    const alloc = global.alloc();
    var defaults = try Config.default(alloc);
    defer defaults.deinit();
    try defaults.finalize();

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };

    try json.beginArray();
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;

        const current = try editorValue(
            alloc,
            field.type,
            field.name,
            @field(self, field.name),
        );
        defer alloc.free(current);
        const default = try editorValue(
            alloc,
            field.type,
            field.name,
            @field(defaults, field.name),
        );
        defer alloc.free(default);

        const Field = switch (@typeInfo(field.type)) {
            .optional => |optional| optional.child,
            else => field.type,
        };

        try json.beginObject();
        try json.objectField("name");
        try json.write(field.name);
        try json.objectField("description");
        try json.write(if (@hasDecl(help_strings.Config, field.name))
            @field(help_strings.Config, field.name)
        else
            "");
        try json.objectField("value");
        try json.write(current);
        try json.objectField("defaultValue");
        try json.write(default);
        try json.objectField("kind");
        try json.write(switch (@typeInfo(Field)) {
            .bool => "boolean",
            .@"enum" => "enum",
            else => "text",
        });
        try json.objectField("repeatable");
        try json.write(
            std.mem.indexOf(u8, @typeName(Field), "Repeatable") != null or
                std.mem.eql(u8, field.name, "keybind") or
                std.mem.eql(u8, field.name, "key-remap"),
        );
        try json.objectField("options");
        try json.beginArray();
        switch (@typeInfo(Field)) {
            .bool => {
                try json.write("true");
                try json.write("false");
            },
            .@"enum" => |info| inline for (info.fields) |enum_field| {
                try json.write(enum_field.name);
            },
            else => {},
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    return .fromSlice(try output.toOwnedSlice());
}

fn editorValue(
    alloc: std.mem.Allocator,
    comptime T: type,
    name: []const u8,
    value: T,
) ![]u8 {
    var formatted: std.Io.Writer.Allocating = .init(alloc);
    defer formatted.deinit();
    try formatter.formatEntry(T, name, value, &formatted.writer);

    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();
    const prefix_len = name.len + " = ".len;
    var lines = std.mem.splitScalar(u8, formatted.written(), '\n');
    var first = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!first) try result.writer.writeByte('\n');
        first = false;
        try result.writer.writeAll(line[@min(prefix_len, line.len)..]);
    }
    return result.toOwnedSlice();
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "ghostty_config_editor_data includes effective values and enum options" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    cfg.maximize = true;

    const data = ghostty_config_editor_data(&cfg);
    defer data.deinit();
    const json = data.ptr.?[0..data.len];

    try testing.expect(std.mem.indexOf(u8, json,
        \\{"name":"maximize","description":
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"value":"true","defaultValue":"false","kind":"boolean","repeatable":false
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"name":"window-theme"
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"options":["auto","system","light","dark","ghostty"]
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"name":"font-family"
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"kind":"text","repeatable":true
    ) != null);
}

test "ghostty_config_keybind_data: default config" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    const data = ghostty_config_keybind_data(&cfg);
    defer data.deinit();
    const json = data.ptr.?[0..data.len];

    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expect(std.mem.indexOf(u8, json,
            \\{"trigger":"super+c","actions":["copy_to_clipboard:mixed"],"table":null,"default":true
        ) != null);
    }

    // Predictions default to performable Tab and Right acceptance.
    try testing.expect(std.mem.indexOf(u8, json,
        \\{"trigger":"arrow_right","actions":["accept_prediction"],"table":null,"default":true
    ) != null);

    // The action catalog documents payload requirements.
    try testing.expect(std.mem.indexOf(u8, json,
        \\{"name":"ignore","docs":
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"parameter":"none"
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"parameter":"required"
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"parameter":"optional"
    ) != null);

    // cursor_key cannot be set through configuration text.
    try testing.expect(std.mem.indexOf(u8, json, "\\\"cursor_key\\\"") == null);
}

test "ghostty_config_keybind_data: user overrides are not defaults" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Override a default binding and add a brand new one.
    try cfg.keybind.parseCLI(cfg.arenaAlloc(), "super+c=paste_from_clipboard");
    try cfg.keybind.parseCLI(cfg.arenaAlloc(), "super+x=new_window");
    try cfg.keybind.parseCLI(cfg.arenaAlloc(), "ctrl+a>ctrl+b=reset_font_size");

    const data = ghostty_config_keybind_data(&cfg);
    defer data.deinit();
    const json = data.ptr.?[0..data.len];

    try testing.expect(std.mem.indexOf(u8, json,
        \\{"trigger":"super+c","actions":["paste_from_clipboard"],"table":null,"default":false
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\{"trigger":"super+x","actions":["new_window"],"table":null,"default":false
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\{"trigger":"ctrl+a>ctrl+b","actions":["reset_font_size"],"table":null,"default":false
    ) != null);
}

test "ghostty_config_keybind_data: table bindings" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    try cfg.keybind.parseCLI(cfg.arenaAlloc(), "mytable/a=text:hello");

    const data = ghostty_config_keybind_data(&cfg);
    defer data.deinit();
    const json = data.ptr.?[0..data.len];

    try testing.expect(std.mem.indexOf(u8, json,
        \\{"trigger":"a","actions":["text:hello"],"table":"mytable","default":false
    ) != null);
}

fn keybindParseTest(str: []const u8) String {
    return ghostty_keybind_parse(str.ptr, str.len);
}

test "ghostty_keybind_parse: valid bindings canonicalize" {
    const testing = std.testing;

    {
        const result = keybindParseTest("cmd+shift+c=copy_to_clipboard");
        defer result.deinit();
        const json = result.ptr.?[0..result.len];
        try testing.expect(std.mem.indexOf(u8, json,
            \\{"ok":true,"trigger":"super+shift+c","actions":["copy_to_clipboard:mixed"],"chain":false
        ) != null);
    }
    {
        const result = keybindParseTest("ctrl+a>ctrl+b=goto_tab:2");
        defer result.deinit();
        const json = result.ptr.?[0..result.len];
        try testing.expect(std.mem.indexOf(u8, json,
            \\{"ok":true,"trigger":"ctrl+a>ctrl+b","actions":["goto_tab:2"],"chain":false
        ) != null);
    }
    {
        const result = keybindParseTest(
            "global:unconsumed:ctrl+shift+t=new_window",
        );
        defer result.deinit();
        const json = result.ptr.?[0..result.len];
        try testing.expect(std.mem.indexOf(u8, json,
            \\"flags":{"all":false,"global":true,"consumed":false,"performable":false}
        ) != null);
    }
}

test "ghostty_keybind_parse: invalid bindings report errors" {
    const testing = std.testing;

    {
        const result = keybindParseTest("ctrl+a");
        defer result.deinit();
        const json = result.ptr.?[0..result.len];
        try testing.expect(std.mem.indexOf(u8, json,
            \\{"ok":false,"error":"invalid keybind format"}
        ) != null);
    }
    {
        const result = keybindParseTest("ctrl+a=not_an_action");
        defer result.deinit();
        const json = result.ptr.?[0..result.len];
        try testing.expect(std.mem.indexOf(u8, json,
            \\{"ok":false,"error":"unknown action or invalid action parameter"}
        ) != null);
    }
    {
        const result = keybindParseTest("");
        defer result.deinit();
        const json = result.ptr.?[0..result.len];
        try testing.expect(std.mem.indexOf(u8, json,
            \\{"ok":false,"error":"invalid keybind format"}
        ) != null);
    }
}

test "ghostty_config_trigger: default keybind" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Default commands should be fetchable through config_trigger_
    {
        const trigger = try config_trigger_(&cfg, "open_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    {
        const trigger = try config_trigger_(&cfg, "reload_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    // Performable bindings are not tracked in the reverse map,
    // so config_trigger_ should return a default (empty) trigger.
    if (comptime builtin.target.os.tag.isDarwin()) {
        const next = try config_trigger_(&cfg, "navigate_search:next");
        try testing.expectEqual(.physical, next.tag);
        try testing.expectEqual(.unidentified, next.key.physical);

        const prev = try config_trigger_(&cfg, "navigate_search:previous");
        try testing.expectEqual(.physical, prev.tag);
        try testing.expectEqual(.unidentified, prev.key.physical);
    }
    {
        const trigger = try config_trigger_(&cfg, "adjust_selection:left");
        try testing.expectEqual(.physical, trigger.tag);
        try testing.expectEqual(.unidentified, trigger.key.physical);
    }
}

test "ghostty_shader_msl" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    const msl = ghostty_shader_msl("src/config/testdata/shader_smoke.glsl");
    defer _ = @import("../main_c.zig").ghostty_string_free(msl);

    try std.testing.expect(msl.ptr != null);
    if (msl.ptr) |ptr| {
        const source = ptr[0..msl.len];
        try std.testing.expect(std.mem.indexOf(u8, source, "main0") != null);
        try std.testing.expect(
            std.mem.indexOf(u8, source, "fragment") != null,
        );
    }
}
