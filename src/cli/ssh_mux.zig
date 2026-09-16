const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const build_config = @import("../build_config.zig");

const log = std.log.scoped(.ssh_mux);

const key_bytes = 16;
pub const key_hex_len = key_bytes * 2;
const lock_stale_secs: i64 = 60;
const sock_path_limit = 80;

pub const Role = enum { master, client, legacy };

pub const Session = struct {
    control_path: []const u8,
    destination: []const u8,
    key: ?[]const u8,
    role: Role,
    lock_dir: ?[]const u8,
};

fn muxDir(alloc: Allocator) ![]u8 {
    var environ = try global.environMap();
    defer environ.deinit();
    if (builtin.os.tag == .windows) {
        const xdg = @import("../os/main.zig").xdg;
        return xdg.state(global.io(), alloc, &environ, .{
            .subdir = build_config.app_id ++ "/ssh-mux",
        });
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(
        alloc,
        "{s}/.local/state/" ++ build_config.app_id ++ "/ssh-mux",
        .{home},
    );
}

pub fn ensureMuxDir(alloc: Allocator) ![]u8 {
    const dir = try muxDir(alloc);
    std.Io.Dir.cwd().createDirPath(global.io(), dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return dir;
}

fn muxFile(alloc: Allocator, key: []const u8, suffix: []const u8) ![]u8 {
    const dir = try ensureMuxDir(alloc);
    defer alloc.free(dir);
    return std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ dir, key, suffix });
}

pub fn sockPath(alloc: Allocator, key: []const u8) ![]u8 {
    const in_state = try muxFile(alloc, key, ".sock");
    if (in_state.len <= sock_path_limit) return in_state;
    alloc.free(in_state);
    return std.fmt.allocPrint(alloc, "/tmp/niftty-{s}.sock", .{key});
}

pub fn tunnelsPath(alloc: Allocator, key: []const u8) ![]u8 {
    return muxFile(alloc, key, ".tunnels");
}

pub fn watchPath(alloc: Allocator, key: []const u8) ![]u8 {
    return muxFile(alloc, key, ".watch");
}

pub fn lockPath(alloc: Allocator, key: []const u8) ![]u8 {
    return muxFile(alloc, key, ".lock");
}

pub fn infoPath(alloc: Allocator, key: []const u8) ![]u8 {
    return muxFile(alloc, key, ".info");
}

/// Parse `ssh -G` stdout into a 32-hex destination key.
/// Identity is `user@host` with `:port` only when port is not 22.
/// Missing hostname → null.
pub fn keyFromG(alloc: Allocator, stdout: []const u8) ?[]u8 {
    var user: []const u8 = "";
    var host: []const u8 = "";
    var port: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (std.mem.eql(u8, key, "user")) {
            user = value;
        } else if (std.mem.eql(u8, key, "hostname")) {
            host = value;
        } else if (std.mem.eql(u8, key, "port")) {
            port = value;
        }
    }
    if (host.len == 0) return null;

    const omit_port = port.len == 0 or std.mem.eql(u8, port, "22");
    const identity = if (user.len == 0)
        if (omit_port)
            alloc.dupe(u8, host) catch return null
        else
            std.fmt.allocPrint(alloc, "{s}:{s}", .{ host, port }) catch return null
    else if (omit_port)
        std.fmt.allocPrint(alloc, "{s}@{s}", .{ user, host }) catch return null
    else
        std.fmt.allocPrint(alloc, "{s}@{s}:{s}", .{ user, host, port }) catch return null;
    defer alloc.free(identity);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(identity, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..key_bytes].*, .lower);
    return alloc.dupe(u8, &hex) catch null;
}

pub fn destinationKey(alloc: Allocator, ssh: []const u8, dest: []const u8) !?[]u8 {
    const result = std.process.run(alloc, global.io(), .{
        .argv = &.{ ssh, "-G", dest },
    }) catch return null;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |rc| if (rc != 0) return null,
        else => return null,
    }
    return keyFromG(alloc, result.stdout);
}

pub fn writeInfo(alloc: Allocator, key: []const u8, ssh: []const u8, dest: []const u8) void {
    const path = infoPath(alloc, key) catch return;
    defer alloc.free(path);
    const file = std.Io.Dir.createFileAbsolute(global.io(), path, .{
        .truncate = true,
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
    }) catch return;
    defer file.close(global.io());
    var buffer: [512]u8 = undefined;
    var writer = file.writer(global.io(), &buffer);
    writer.interface.print("{s}\n{s}\n", .{ ssh, dest }) catch return;
    writer.interface.flush() catch {};
}

fn dirPerms() std.Io.Dir.Permissions {
    if (builtin.os.tag != .windows and std.posix.mode_t != u0) {
        return .fromMode(0o700);
    }
    return .default_dir;
}

pub fn lockIsStale(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(global.io(), path, .{}) catch return true;
    const now = std.Io.Timestamp.now(global.io(), .real).toSeconds();
    const mtime = stat.mtime.toSeconds();
    return now > mtime and (now - mtime) >= lock_stale_secs;
}

pub fn tryLock(alloc: Allocator, key: []const u8) !?[]u8 {
    const path = try lockPath(alloc, key);
    std.Io.Dir.createDirAbsolute(global.io(), path, dirPerms()) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (lockIsStale(path)) {
                std.Io.Dir.deleteDirAbsolute(global.io(), path) catch {};
                std.Io.Dir.createDirAbsolute(global.io(), path, dirPerms()) catch {
                    alloc.free(path);
                    return null;
                };
                return path;
            }
            alloc.free(path);
            return null;
        },
        else => {
            alloc.free(path);
            return err;
        },
    };
    return path;
}

pub fn unlock(path: []const u8) void {
    std.Io.Dir.deleteDirAbsolute(global.io(), path) catch {};
}

fn pidAlive(pid: u64) bool {
    if (builtin.os.tag == .windows) return true;
    const owner: std.posix.pid_t = @intCast(@min(pid, std.math.maxInt(std.posix.pid_t)));
    if (std.posix.kill(owner, @enumFromInt(0))) |_| return true else |err| switch (err) {
        error.PermissionDenied => return true,
        else => return false,
    }
}

fn readWatchPid(alloc: Allocator, path: []const u8) ?u64 {
    const file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch return null;
    defer file.close(global.io());
    var buf: [32]u8 = undefined;
    var reader = file.reader(global.io(), &.{});
    const n = reader.interface.readSliceShort(&buf) catch return null;
    const line = std.mem.trim(u8, buf[0..n], " \r\n");
    _ = alloc;
    return std.fmt.parseUnsigned(u64, line, 10) catch null;
}

pub fn watchOwnerAlive(alloc: Allocator, key: []const u8) bool {
    const path = watchPath(alloc, key) catch return false;
    defer alloc.free(path);
    const pid = readWatchPid(alloc, path) orelse return false;
    return pidAlive(pid);
}

/// Atomically claim `<key>.watch` for `pid`. Returns true if this process owns it.
pub fn tryClaimWatch(alloc: Allocator, key: []const u8, pid: u64) bool {
    if (watchOwnerAlive(alloc, key)) return false;
    const path = watchPath(alloc, key) catch return false;
    defer alloc.free(path);
    const tmp = std.fmt.allocPrint(alloc, "{s}.{d}", .{ path, pid }) catch return false;
    defer alloc.free(tmp);
    const file = std.Io.Dir.createFileAbsolute(global.io(), tmp, .{
        .truncate = true,
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
    }) catch return false;
    {
        defer file.close(global.io());
        var buffer: [32]u8 = undefined;
        var writer = file.writer(global.io(), &buffer);
        writer.interface.print("{d}\n", .{pid}) catch {
            std.Io.Dir.deleteFileAbsolute(global.io(), tmp) catch {};
            return false;
        };
        writer.interface.flush() catch {
            std.Io.Dir.deleteFileAbsolute(global.io(), tmp) catch {};
            return false;
        };
    }
    std.Io.Dir.renameAbsolute(tmp, path, global.io()) catch {
        std.Io.Dir.deleteFileAbsolute(global.io(), tmp) catch {};
        return false;
    };
    const owner = readWatchPid(alloc, path) orelse return false;
    return owner == pid;
}

pub fn unlinkMuxFiles(alloc: Allocator, key: []const u8, control_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(global.io(), control_path) catch {};
    const suffixes = [_][]const u8{ ".tunnels", ".info", ".watch" };
    for (suffixes) |suffix| {
        const path = muxFile(alloc, key, suffix) catch continue;
        defer alloc.free(path);
        std.Io.Dir.deleteFileAbsolute(global.io(), path) catch {};
    }
    const lock = lockPath(alloc, key) catch return;
    defer alloc.free(lock);
    unlock(lock);
}

test "keyFromG: port 22 elided, non-22 kept" {
    const testing = std.testing;
    const a = keyFromG(testing.allocator,
        \\user alice
        \\hostname example.com
        \\port 22
        \\
    );
    defer testing.allocator.free(a.?);
    try testing.expectEqual(@as(usize, key_hex_len), a.?.len);

    const b = keyFromG(testing.allocator,
        \\hostname example.com
        \\user alice
        \\port 22
        \\
    );
    defer testing.allocator.free(b.?);
    try testing.expectEqualStrings(a.?, b.?);

    const c = keyFromG(testing.allocator,
        \\user alice
        \\hostname example.com
        \\port 2222
        \\
    );
    defer testing.allocator.free(c.?);
    try testing.expect(c.?.len == key_hex_len);
    try testing.expect(!std.mem.eql(u8, a.?, c.?));
}

test "keyFromG: missing hostname is null" {
    const testing = std.testing;
    try testing.expectEqual(
        @as(?[]u8, null),
        keyFromG(testing.allocator, "user alice\nport 22\n"),
    );
}

test "keyFromG: alias and hostname with same identity match" {
    const testing = std.testing;
    const via_alias = keyFromG(testing.allocator,
        \\user bob
        \\hostname 10.0.0.8
        \\port 22
        \\
    );
    defer testing.allocator.free(via_alias.?);
    const via_host = keyFromG(testing.allocator,
        \\port 22
        \\hostname 10.0.0.8
        \\user bob
        \\
    );
    defer testing.allocator.free(via_host.?);
    try testing.expectEqualStrings(via_alias.?, via_host.?);
}

test "sockPath stays under unix socket limit" {
    const testing = std.testing;
    const key = "0123456789abcdef0123456789abcdef";
    const path = try sockPath(testing.allocator, key);
    defer testing.allocator.free(path);
    try testing.expect(path.len + 17 < 104);
}
