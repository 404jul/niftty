const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");

/// The mosh wrapper defines no options of its own: every argument
/// belongs to the installed mosh client (see `run`).
pub const Options = struct {};

/// The `mosh` action runs the locally installed `mosh` client in this
/// terminal, passing every argument after the command through unchanged.
///
/// Usage: niftty mosh [options] [--] [user@]host [command...]
///
/// The `mosh` executable must be installed and on PATH; Niftty bundles
/// no Mosh client of its own. On macOS install it with:
///
///   brew install mosh
///
/// The remote host must have `mosh-server` installed, a UTF-8 locale,
/// and UDP ports reachable between the two machines (by default
/// 60000-61000). Mosh keeps ownership of SSH authentication and
/// bootstrap, its UDP transport, roaming, and local echo prediction;
/// Niftty only dispatches the command, so none of the SSH session
/// features that `niftty ssh` provides apply here.
///
/// The wrapper owns only a first-position `-h` or `--help`, which prints
/// this help without requiring mosh to be installed. Every other
/// argument, including a leading `--`, long options, `+`-prefixed
/// words, and `--version`, is passed to the installed client verbatim.
/// A `--` delimiter keeps its upstream meaning: everything after it is
/// treated as the remote command.
///
/// The client inherits this terminal's stdin, stdout, and stderr, so it
/// runs interactively just like `niftty ssh` and returns you to your
/// local shell when it exits.
///
/// Examples:
///
///   niftty mosh user@example.com
///   niftty mosh --predict=never user@example.com
///   niftty mosh --ssh='ssh -p 2222' --port=60001 user@example.com
///   niftty mosh --version
pub fn run(alloc: Allocator) !u8 {
    // The iterator owns the argument memory and the child argv below
    // borrows slices from it, so it must stay alive through the wait.
    var iter: std.process.Args.Iterator = try .initAllocator(global.args(), alloc);
    defer iter.deinit();

    // argv[0] is the niftty binary itself.
    _ = iter.next();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "mosh");

    // Drop only the first exact `+mosh` selector. A later `+mosh` is an
    // argument for the wrapped command and must be preserved.
    var selector = true;
    while (iter.next()) |arg| {
        if (selector and std.mem.eql(u8, arg, "+mosh")) {
            selector = false;
            continue;
        }
        try argv.append(alloc, arg);
    }

    var buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    const stderr = &stderr_writer.interface;

    // With nothing beyond the selector there is nothing to hand to the
    // installed client.
    if (argv.items.len == 1) {
        try stderr.writeAll(
            \\Error: no mosh arguments provided.
            \\
            \\Usage: niftty mosh [options] [--] [user@]host [command...]
            \\
        );
        try stderr.flush();
        return 2;
    }

    // Wrapper help only in first position; a `-h`/`--help` anywhere
    // else belongs to the installed client.
    const first = argv.items[1];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return Action.help_error;
    }

    // A plain spawn resolves "mosh" on PATH and inherits environment,
    // cwd, and process group along with the terminal fds.
    var child = std.process.spawn(global.io(), .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try stderr.writeAll(
                    "Error: could not execute mosh. Install Mosh and ensure it is on PATH (macOS: brew install mosh).\n",
                );
                try stderr.flush();
                return 127;
            },
            else => {
                try stderr.print("Error: failed to run mosh: {t}\n", .{err});
                try stderr.flush();
                return 1;
            },
        }
    };

    // kill is a no-op after a successful wait; it only acts if the wait
    // below fails, preventing a leaked child.
    defer child.kill(global.io());

    const term = child.wait(global.io()) catch |err| {
        try stderr.print("Error: failed to wait for mosh: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };

    return exitCode(term);
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @as(u8, 128) + @as(u8, @intCast(@min(@intFromEnum(sig), 127))),
        .stopped, .unknown => 1,
    };
}
