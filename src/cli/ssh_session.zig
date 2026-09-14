const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xdg = @import("../os/main.zig").xdg;
const build_config = @import("../build_config.zig");

const max_state_size = 16 * 1024;

pub const Info = struct {
    control_path: []const u8,
    destination: []const u8,
    ssh: []const u8,

    pub fn deinit(self: Info, alloc: Allocator) void {
        alloc.free(self.control_path);
        alloc.free(self.destination);
        alloc.free(self.ssh);
    }
};

pub fn currentPid() u64 {
    if (comptime builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetCurrentProcessId();
    }
    return @intCast(std.c.getpid());
}

/// Resolve the directory holding per-session state files.
///
/// This deliberately resolves from HOME rather than XDG_STATE_HOME: the
/// directory must be computed identically by the `+ssh` writer (shell
/// environment), the app-spawned `+ssh-upload` loader, and the app's own
/// drag-and-drop detector (both app environment). A GUI app cannot observe
/// XDG_STATE_HOME values set in shell rc files, so honoring it here would
/// make writer and readers disagree and uploads would silently never activate.
fn stateDir(alloc: Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        return try xdg.state(global.io(), alloc, environ, .{
            .subdir = build_config.app_id ++ "/ssh-sessions",
        });
    }

    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(alloc, "{s}/.local/state/" ++ build_config.app_id ++ "/ssh-sessions", .{home});
}

pub fn pathForPid(alloc: Allocator, pid: u64) ![]u8 {
    var environ = try global.environMap();
    defer environ.deinit();
    const state_dir = try stateDir(alloc, &environ);
    defer alloc.free(state_dir);
    return std.fmt.allocPrint(alloc, "{s}/{d}", .{ state_dir, pid });
}

pub fn tunnelsPathForPid(alloc: Allocator, pid: u64) ![]u8 {
    const path = try pathForPid(alloc, pid);
    defer alloc.free(path);
    return std.fmt.allocPrint(alloc, "{s}.tunnels", .{path});
}

pub fn write(alloc: Allocator, pid: u64, info: Info) !void {
    if (std.mem.indexOfScalar(u8, info.control_path, '\n') != null or
        std.mem.indexOfScalar(u8, info.destination, '\n') != null or
        std.mem.indexOfScalar(u8, info.ssh, '\n') != null)
    {
        return error.InvalidSessionValue;
    }

    const path = try pathForPid(alloc, pid);
    defer alloc.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(global.io(), dir);
    }

    const file = try std.Io.Dir.createFileAbsolute(global.io(), path, .{
        .truncate = true,
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
    });
    defer file.close(global.io());

    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(global.io(), &buffer);
    try file_writer.interface.print("1\n{s}\n{s}\n{s}\n", .{
        info.control_path,
        info.destination,
        info.ssh,
    });
    try file_writer.interface.flush();
}

pub fn remove(alloc: Allocator, pid: u64) void {
    const path = pathForPid(alloc, pid) catch return;
    defer alloc.free(path);
    std.Io.Dir.deleteFileAbsolute(global.io(), path) catch {};
    const tunnels = std.fmt.allocPrint(alloc, "{s}.tunnels", .{path}) catch return;
    defer alloc.free(tunnels);
    std.Io.Dir.deleteFileAbsolute(global.io(), tunnels) catch {};
}

pub fn load(alloc: Allocator, pid: u64) !Info {
    const path = try pathForPid(alloc, pid);
    defer alloc.free(path);
    const file = try std.Io.Dir.openFileAbsolute(global.io(), path, .{});
    defer file.close(global.io());

    var reader = file.reader(global.io(), &.{});
    const data = try reader.interface.allocRemaining(alloc, .limited(max_state_size));
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidSession, "1")) {
        return error.InvalidSession;
    }
    const control_path = lines.next() orelse return error.InvalidSession;
    const destination = lines.next() orelse return error.InvalidSession;
    const ssh = lines.next() orelse return error.InvalidSession;
    if (control_path.len == 0 or destination.len == 0 or ssh.len == 0) {
        return error.InvalidSession;
    }

    const control_copy = try alloc.dupe(u8, control_path);
    errdefer alloc.free(control_copy);
    const destination_copy = try alloc.dupe(u8, destination);
    errdefer alloc.free(destination_copy);
    return .{
        .control_path = control_copy,
        .destination = destination_copy,
        .ssh = try alloc.dupe(u8, ssh),
    };
}

test "session state round trip" {
    const testing = std.testing;
    const pid = currentPid();
    remove(testing.allocator, pid);
    defer remove(testing.allocator, pid);

    try write(testing.allocator, pid, .{
        .control_path = "/tmp/control.sock",
        .destination = "alice@example.com",
        .ssh = "ssh",
    });
    const result = try load(testing.allocator, pid);
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/control.sock", result.control_path);
    try testing.expectEqualStrings("alice@example.com", result.destination);
    try testing.expectEqualStrings("ssh", result.ssh);
}
