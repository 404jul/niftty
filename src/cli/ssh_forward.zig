const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const cli_args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const global = @import("../global.zig");
const ssh_session = @import("ssh_session.zig");
const ssh_tunnel = @import("ssh_tunnel.zig");

const usage =
    \\Usage: ghostty +ssh-forward --pid=<pid> [--list]
    \\       ghostty +ssh-forward --pid=<pid> --add [--local=<port>] --remote=<port>
    \\       ghostty +ssh-forward --pid=<pid> --cancel [--local=<port>] --remote=<port>
    \\
    \\List, add, or close loopback tunnels on an active `ghostty +ssh` session.
    \\`--pid` is the foreground `+ssh` process. List output is tab-separated:
    \\  D <destination>
    \\  T <local-host> <local-port> <remote-host> <remote-port>
    \\
;

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    pid: ?u64 = null,
    list: bool = false,
    add: bool = false,
    cancel: bool = false,
    local: ?u16 = null,
    remote: ?u16 = null,
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(_: Options) !void {
        return Action.help_error;
    }
};

/// List, add, or cancel local forwards on the multiplexed connection owned
/// by an active `ghostty +ssh` process.
///
/// This action is normally launched by Ghostty's macOS SSH Ports panel.
/// `--pid` identifies the foreground `+ssh` process. `--list` is the default
/// when neither `--add` nor `--cancel` is given.
///
/// Adding a tunnel runs `ssh -O forward -L` on the existing control socket
/// and records it so the Ports panel and auto-forwarder stay in sync. Closing
/// a tunnel runs `ssh -O cancel -L` and records the remote port as ignored
/// so auto-forward will not reopen it for the rest of the session.
///
/// Available since: 1.4.0
pub fn run(gpa: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    {
        var iter = try cli_args.argsIterator(gpa, global.args());
        defer iter.deinit();
        try cli_args.parse(Options, gpa, &opts, &iter);
    }

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    if (!opts._diagnostics.empty()) {
        try stderr.print("Error: invalid +ssh-forward arguments.\n\n{s}", .{usage});
        return 2;
    }
    const pid = opts.pid orelse {
        try stderr.print("Error: --pid is required.\n\n{s}", .{usage});
        return 2;
    };

    // A dead owner process leaves its state files behind; refuse to serve
    // stale tunnels from a session that no longer exists.
    const owner: std.posix.pid_t = @intCast(@min(pid, std.math.maxInt(std.posix.pid_t)));
    if (std.posix.kill(owner, @enumFromInt(0))) |_| {} else |err| switch (err) {
        // The process exists but belongs to another user.
        error.PermissionDenied => {},
        else => {
            try stderr.print("Error: no active Ghostty SSH session for pid {d}.\n", .{pid});
            return 1;
        },
    }
    if (@intFromBool(opts.add) + @intFromBool(opts.cancel) > 1) {
        try stderr.print("Error: --add and --cancel cannot be combined.\n\n{s}", .{usage});
        return 2;
    }

    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const session = ssh_session.load(alloc, pid) catch |err| {
        try stderr.print("Error: no active Ghostty SSH session for pid {d}: {t}\n", .{ pid, err });
        return 1;
    };

    if (opts.add) {
        const remote = opts.remote orelse {
            try stderr.print("Error: --remote is required with --add.\n\n{s}", .{usage});
            return 2;
        };
        return addTunnel(gpa, alloc, pid, session, opts.local, remote, stderr);
    }
    if (opts.cancel) {
        const remote = opts.remote orelse {
            try stderr.print("Error: --remote is required with --cancel.\n\n{s}", .{usage});
            return 2;
        };
        return cancelTunnel(gpa, alloc, pid, session, opts.local, remote, stderr);
    }
    return listTunnels(gpa, alloc, pid, session);
}

fn listTunnels(
    gpa: Allocator,
    alloc: Allocator,
    pid: u64,
    session: ssh_session.Info,
) !u8 {
    var ledger = try ssh_tunnel.load(gpa, pid);
    defer ledger.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(global.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("D\t{s}\n", .{session.destination});
    for (ledger.tunnels.items) |tunnel| {
        try stdout.print(
            "T\t{s}\t{d}\t{s}\t{d}\n",
            .{ tunnel.local_host, tunnel.local_port, tunnel.remote_host, tunnel.remote_port },
        );
    }
    try stdout.flush();
    _ = alloc;
    return 0;
}

fn addTunnel(
    gpa: Allocator,
    alloc: Allocator,
    pid: u64,
    session: ssh_session.Info,
    local_port: ?u16,
    remote_port: u16,
    stderr: *std.Io.Writer,
) !u8 {
    var ledger = try ssh_tunnel.load(gpa, pid);
    defer ledger.deinit();
    if (ledger.hasRemote(remote_port)) return 0;

    const opened = ssh_tunnel.openLocal(
        alloc,
        session.ssh,
        session.control_path,
        session.destination,
        remote_port,
        local_port,
    ) catch |err| {
        try stderr.print("Error: failed to add forward: {t}\n", .{err});
        return 1;
    };
    try ledger.add(ssh_tunnel.loopback, opened, ssh_tunnel.loopback, remote_port);
    ssh_tunnel.save(gpa, pid, ledger) catch |err| {
        _ = ssh_tunnel.closeLocal(
            alloc,
            session.ssh,
            session.control_path,
            session.destination,
            opened,
            remote_port,
        ) catch {};
        try stderr.print("Error: failed to record forward: {t}\n", .{err});
        return 1;
    };
    return 0;
}

fn cancelTunnel(
    gpa: Allocator,
    alloc: Allocator,
    pid: u64,
    session: ssh_session.Info,
    local_port: ?u16,
    remote_port: u16,
    stderr: *std.Io.Writer,
) !u8 {
    var ledger = try ssh_tunnel.load(gpa, pid);
    defer ledger.deinit();

    if (local_port) |local| {
        if (!ledger.remove(local, remote_port)) {
            _ = ledger.removeRemote(remote_port);
        }
        _ = ssh_tunnel.closeLocal(
            alloc,
            session.ssh,
            session.control_path,
            session.destination,
            local,
            remote_port,
        ) catch |err| {
            try stderr.print("Error: failed to cancel forward: {t}\n", .{err});
            return 1;
        };
    } else {
        var local: ?u16 = null;
        for (ledger.tunnels.items) |tunnel| {
            if (tunnel.remote_port == remote_port) {
                local = tunnel.local_port;
                break;
            }
        }
        _ = ledger.removeRemote(remote_port);
        if (local) |port| {
            _ = ssh_tunnel.closeLocal(
                alloc,
                session.ssh,
                session.control_path,
                session.destination,
                port,
                remote_port,
            ) catch |err| {
                try stderr.print("Error: failed to cancel forward: {t}\n", .{err});
                return 1;
            };
        }
    }

    ssh_tunnel.save(gpa, pid, ledger) catch |err| {
        try stderr.print("Error: failed to record cancel: {t}\n", .{err});
        return 1;
    };
    return 0;
}

fn parseTestArgs(alloc: Allocator, opts: *Options, line: []const u8) !void {
    var iter = try std.process.Args.IteratorGeneral(.{}).init(alloc, line);
    defer iter.deinit();
    try cli_args.parse(Options, alloc, opts, &iter);
}

test "parse: list is default" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "--pid=42");
    try testing.expectEqual(@as(?u64, 42), opts.pid);
    try testing.expectEqual(false, opts.add);
    try testing.expectEqual(false, opts.cancel);
}

test "parse: add with local and remote" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "--pid=7 --add --local=3001 --remote=3000");
    try testing.expectEqual(true, opts.add);
    try testing.expectEqual(@as(?u16, 3001), opts.local);
    try testing.expectEqual(@as(?u16, 3000), opts.remote);
}
