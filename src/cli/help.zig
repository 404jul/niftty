const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");

// Note that this options struct doesn't implement the `help` decl like other
// actions. That is because the help command is special and wants to handle its
// own logic around help detection.
pub const Options = struct {
    /// This must be registered so that it isn't an error to pass `--help`
    help: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

/// One-line summaries for every action, shown by `niftty help`. Keep in
/// sync with the `Action` enum; the comptime block below enforces it.
const commands = [_]struct { name: []const u8, desc: []const u8 }{
    .{ .name = "ssh", .desc = "Wrap ssh to set up Niftty integration on remote hosts" },
    .{ .name = "ssh-cache", .desc = "Manage the terminfo install cache for ssh hosts" },
    .{ .name = "ssh-upload", .desc = "Upload files over an active ssh session" },
    .{ .name = "ssh-forward", .desc = "List, add, or cancel port forwards for an active session" },
    .{ .name = "ssh-files", .desc = "List and download files over an active ssh session" },
    .{ .name = "new-window", .desc = "Open a new window in the running Niftty" },
    .{ .name = "new-tab", .desc = "Open a new tab in the running Niftty" },
    .{ .name = "toggle-quick-terminal", .desc = "Toggle the quick terminal" },
    .{ .name = "edit-config", .desc = "Edit the configuration file in your editor" },
    .{ .name = "show-config", .desc = "Print the loaded configuration" },
    .{ .name = "explain-config", .desc = "Explain a single configuration option" },
    .{ .name = "validate-config", .desc = "Validate a configuration file" },
    .{ .name = "list-fonts", .desc = "List available fonts" },
    .{ .name = "list-keybinds", .desc = "List configured keybinds" },
    .{ .name = "list-themes", .desc = "List available themes" },
    .{ .name = "list-colors", .desc = "List the named RGB palette colors" },
    .{ .name = "list-actions", .desc = "List keybind actions" },
    .{ .name = "show-face", .desc = "Show which font face renders a codepoint" },
    .{ .name = "crash-report", .desc = "List and inspect crash reports" },
    .{ .name = "version", .desc = "Print version information" },
    .{ .name = "help", .desc = "Print this help" },
    .{ .name = "boo", .desc = "Boo!" },
};

comptime {
    @setEvalBranchQuota(10000);
    const fields = @typeInfo(Action).@"enum".fields;
    if (commands.len != fields.len) {
        @compileError("help command table is out of sync with the Action enum");
    }
    for (fields) |field| {
        var found = false;
        for (commands) |cmd| {
            if (std.mem.eql(u8, cmd.name, field.name)) found = true;
        }
        if (!found) {
            @compileError("missing help description for action: " ++ field.name);
        }
    }
}

/// The `help` command shows general help about Ghostty. Recognized as either
/// `-h`, `--help`, or like other actions `+help`. The bare `help` command is
/// promoted to `+help` before detection (see `action.promoteBareCommand`).
///
/// You can also specify `--help` or `-h` along with any action such as
/// `+list-themes` to see help for a specific action.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\Usage: niftty [<command>] [options]
        \\
        \\Commands run with or without the leading `+`:
        \\
        \\  niftty ssh gx10        same as: niftty +ssh gx10
        \\  niftty help            same as: niftty +help
        \\
        \\With no command, Niftty runs the terminal emulator. On macOS,
        \\launch it with `open -na Niftty.app` (pass configuration with
        \\`--args --key=value`, e.g. `--args --font-size=12`).
        \\
        \\A special argument `-e <command>` runs the command inside a new
        \\terminal window, e.g. `niftty -e top`.
        \\
        \\Run `niftty <command> --help` for help on a specific command.
        \\
        \\Commands:
        \\
        \\
    );

    inline for (commands) |cmd| {
        try stdout.print("  {s: <25}{s}\n", .{ cmd.name, cmd.desc });
    }

    try stdout.flush();

    return 0;
}
