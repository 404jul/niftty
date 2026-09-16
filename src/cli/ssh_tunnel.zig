const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");

const log = std.log.scoped(.ssh_tunnel);

pub const loopback = "127.0.0.1";
pub const max_auto_forwards: usize = 20;
const ledger_version = "1";

pub const Tunnel = struct {
    local_host: []const u8,
    local_port: u16,
    remote_host: []const u8,
    remote_port: u16,

    pub fn deinit(self: Tunnel, alloc: Allocator) void {
        alloc.free(self.local_host);
        alloc.free(self.remote_host);
    }

    pub fn displayHost(self: Tunnel, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}:{d}", .{ self.local_host, self.local_port });
    }

    pub fn displayRemote(self: Tunnel, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}:{d}", .{ self.remote_host, self.remote_port });
    }
};

pub const Ledger = struct {
    alloc: Allocator,
    tunnels: std.ArrayList(Tunnel) = .empty,
    ignored: std.ArrayList(u16) = .empty,

    pub fn deinit(self: *Ledger) void {
        for (self.tunnels.items) |tunnel| tunnel.deinit(self.alloc);
        self.tunnels.deinit(self.alloc);
        self.ignored.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn hasRemote(self: Ledger, remote_port: u16) bool {
        for (self.tunnels.items) |tunnel| {
            if (tunnel.remote_port == remote_port) return true;
        }
        return false;
    }

    pub fn ignores(self: Ledger, remote_port: u16) bool {
        return std.mem.indexOfScalar(u16, self.ignored.items, remote_port) != null;
    }

    pub fn add(
        self: *Ledger,
        local_host: []const u8,
        local_port: u16,
        remote_host: []const u8,
        remote_port: u16,
    ) !void {
        if (self.hasRemote(remote_port)) return;
        const local_copy = try self.alloc.dupe(u8, local_host);
        errdefer self.alloc.free(local_copy);
        const remote_copy = try self.alloc.dupe(u8, remote_host);
        errdefer self.alloc.free(remote_copy);
        try self.tunnels.append(self.alloc, .{
            .local_host = local_copy,
            .local_port = local_port,
            .remote_host = remote_copy,
            .remote_port = remote_port,
        });
        if (std.mem.indexOfScalar(u16, self.ignored.items, remote_port)) |idx| {
            _ = self.ignored.orderedRemove(idx);
        }
    }

    pub fn remove(self: *Ledger, local_port: u16, remote_port: u16) bool {
        for (self.tunnels.items, 0..) |tunnel, i| {
            if (tunnel.local_port != local_port or tunnel.remote_port != remote_port) continue;
            var removed = self.tunnels.orderedRemove(i);
            removed.deinit(self.alloc);
            if (std.mem.indexOfScalar(u16, self.ignored.items, remote_port) == null) {
                self.ignored.append(self.alloc, remote_port) catch {};
            }
            return true;
        }
        return false;
    }

    pub fn removeRemote(self: *Ledger, remote_port: u16) bool {
        var found = false;
        var i: usize = 0;
        while (i < self.tunnels.items.len) {
            if (self.tunnels.items[i].remote_port != remote_port) {
                i += 1;
                continue;
            }
            var removed = self.tunnels.orderedRemove(i);
            removed.deinit(self.alloc);
            found = true;
        }
        if (found and std.mem.indexOfScalar(u16, self.ignored.items, remote_port) == null) {
            self.ignored.append(self.alloc, remote_port) catch {};
        }
        return found;
    }
};

pub fn load(alloc: Allocator, path: []const u8) !Ledger {
    const file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .alloc = alloc },
        else => return err,
    };
    defer file.close(global.io());
    var reader = file.reader(global.io(), &.{});
    const data = try reader.interface.allocRemaining(alloc, .limited(64 * 1024));
    defer alloc.free(data);
    return parseLedger(alloc, data);
}

pub fn save(alloc: Allocator, path: []const u8, ledger: Ledger) !void {
    _ = alloc;
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(global.io(), dir);
    }
    const file = try std.Io.Dir.createFileAbsolute(global.io(), path, .{
        .truncate = true,
        .permissions = if (@import("builtin").os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
    });
    defer file.close(global.io());
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(global.io(), &buffer);
    try writeLedger(&file_writer.interface, ledger);
    try file_writer.interface.flush();
}

pub fn parseLedger(alloc: Allocator, data: []const u8) !Ledger {
    var ledger: Ledger = .{ .alloc = alloc };
    errdefer ledger.deinit();

    var lines = std.mem.splitScalar(u8, data, '\n');
    const version = std.mem.trim(u8, lines.next() orelse return error.InvalidLedger, " \r");
    if (!std.mem.eql(u8, version, ledger_version)) return error.InvalidLedger;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = fields.next() orelse continue;
        if (std.mem.eql(u8, tag, "F")) {
            const local_host = fields.next() orelse continue;
            const local_port = std.fmt.parseUnsigned(u16, fields.next() orelse continue, 10) catch continue;
            const remote_host = fields.next() orelse continue;
            const remote_port = std.fmt.parseUnsigned(u16, fields.next() orelse continue, 10) catch continue;
            try ledger.add(local_host, local_port, remote_host, remote_port);
        } else if (std.mem.eql(u8, tag, "X")) {
            const remote_port = std.fmt.parseUnsigned(u16, fields.next() orelse continue, 10) catch continue;
            if (!ledger.ignores(remote_port)) {
                try ledger.ignored.append(alloc, remote_port);
            }
        }
    }
    return ledger;
}

pub fn writeLedger(writer: *std.Io.Writer, ledger: Ledger) !void {
    try writer.print("{s}\n", .{ledger_version});
    for (ledger.tunnels.items) |tunnel| {
        try writer.print(
            "F {s} {d} {s} {d}\n",
            .{ tunnel.local_host, tunnel.local_port, tunnel.remote_host, tunnel.remote_port },
        );
    }
    for (ledger.ignored.items) |port| {
        try writer.print("X {d}\n", .{port});
    }
}

pub fn openLocal(
    alloc: Allocator,
    ssh: []const u8,
    control_path: []const u8,
    destination: []const u8,
    remote_port: u16,
    local_port: ?u16,
) !u16 {
    if (local_port) |port| {
        if (try request(alloc, ssh, control_path, destination, .forward, port, remote_port)) {
            return port;
        }
        return error.ForwardFailed;
    }

    if (try request(alloc, ssh, control_path, destination, .forward, remote_port, remote_port)) {
        return remote_port;
    }

    const address = try std.Io.net.IpAddress.parseIp4(loopback, 0);
    var reservation = try address.listen(global.io(), .{});
    const chosen = reservation.socket.address.getPort();
    reservation.deinit(global.io());
    if (!try request(alloc, ssh, control_path, destination, .forward, chosen, remote_port)) {
        return error.ForwardFailed;
    }
    return chosen;
}

pub fn closeLocal(
    alloc: Allocator,
    ssh: []const u8,
    control_path: []const u8,
    destination: []const u8,
    local_port: u16,
    remote_port: u16,
) !bool {
    return request(alloc, ssh, control_path, destination, .cancel, local_port, remote_port);
}

const MuxOp = enum { forward, cancel };

fn request(
    alloc: Allocator,
    ssh: []const u8,
    control_path: []const u8,
    destination: []const u8,
    op: MuxOp,
    local_port: u16,
    remote_port: u16,
) !bool {
    const spec = try std.fmt.allocPrint(
        alloc,
        "{s}:{d}:{s}:{d}",
        .{ loopback, local_port, loopback, remote_port },
    );
    defer alloc.free(spec);
    const result = try std.process.run(alloc, global.io(), .{
        .argv = &.{
            ssh,
            "-S",
            control_path,
            "-O",
            @tagName(op),
            "-L",
            spec,
            destination,
        },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const ok = exitCode(result.term) == 0;
    if (!ok) {
        log.debug("ssh -O {s} {s} failed", .{ @tagName(op), spec });
    }
    return ok;
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @as(u8, 128) + @as(u8, @intCast(@min(@intFromEnum(sig), 127))),
        .stopped, .unknown => 1,
    };
}

test "parseLedger: forwards and ignored remotes" {
    const testing = std.testing;
    const data =
        \\1
        \\F 127.0.0.1 3000 127.0.0.1 3000
        \\F 127.0.0.1 8081 127.0.0.1 8080
        \\X 5432
        \\
    ;
    var ledger = try parseLedger(testing.allocator, data);
    defer ledger.deinit();
    try testing.expectEqual(@as(usize, 2), ledger.tunnels.items.len);
    try testing.expectEqual(@as(u16, 3000), ledger.tunnels.items[0].local_port);
    try testing.expectEqual(@as(u16, 8081), ledger.tunnels.items[1].local_port);
    try testing.expectEqual(@as(u16, 8080), ledger.tunnels.items[1].remote_port);
    try testing.expect(ledger.hasRemote(3000));
    try testing.expect(ledger.ignores(5432));
    try testing.expect(!ledger.ignores(3000));
}

test "parseLedger: reject unknown version" {
    const testing = std.testing;
    try testing.expectError(error.InvalidLedger, parseLedger(testing.allocator, "2\n"));
}

test "Ledger.add skips duplicates and clears ignore" {
    const testing = std.testing;
    var ledger: Ledger = .{ .alloc = testing.allocator };
    defer ledger.deinit();
    try ledger.ignored.append(testing.allocator, 3000);
    try ledger.add(loopback, 3000, loopback, 3000);
    try ledger.add(loopback, 3001, loopback, 3000);
    try testing.expectEqual(@as(usize, 1), ledger.tunnels.items.len);
    try testing.expect(!ledger.ignores(3000));
}

test "Ledger.remove records ignore so auto-forward will not reopen" {
    const testing = std.testing;
    var ledger: Ledger = .{ .alloc = testing.allocator };
    defer ledger.deinit();
    try ledger.add(loopback, 3000, loopback, 3000);
    try testing.expect(ledger.remove(3000, 3000));
    try testing.expectEqual(@as(usize, 0), ledger.tunnels.items.len);
    try testing.expect(ledger.ignores(3000));
}

test "writeLedger round trip" {
    const testing = std.testing;
    var ledger: Ledger = .{ .alloc = testing.allocator };
    defer ledger.deinit();
    try ledger.add(loopback, 3000, loopback, 3000);
    try ledger.ignored.append(testing.allocator, 6379);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeLedger(&buf.writer, ledger);

    var parsed = try parseLedger(testing.allocator, buf.written());
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.tunnels.items.len);
    try testing.expectEqual(@as(u16, 3000), parsed.tunnels.items[0].remote_port);
    try testing.expect(parsed.ignores(6379));
}

test "load/save path round trip" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "led.tunnels" });
    defer testing.allocator.free(path);

    var ledger: Ledger = .{ .alloc = testing.allocator };
    defer ledger.deinit();
    try ledger.add(loopback, 4000, loopback, 4000);
    try save(testing.allocator, path, ledger);

    var loaded = try load(testing.allocator, path);
    defer loaded.deinit();
    try testing.expectEqual(@as(u16, 4000), loaded.tunnels.items[0].remote_port);
}
