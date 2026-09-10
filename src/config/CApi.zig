const builtin = @import("builtin");
const std = @import("std");
const inputpkg = @import("../input.zig");
const global = @import("../global.zig");
const String = @import("../main_c.zig").String;

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
        \\"value":"true","defaultValue":"false","kind":"boolean"
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"name":"window-theme"
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"options":["auto","system","light","dark","ghostty"]
    ) != null);
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
