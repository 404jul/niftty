const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const cli_args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const global = @import("../global.zig");
const ssh_session = @import("ssh_session.zig");
const ssh_sftp = @import("ssh_sftp.zig");

const usage =
    \\Usage: niftty +ssh-files --pid=<pid> list <absolute-remote-directory>
    \\       niftty +ssh-files --pid=<pid> stat <absolute-remote-path>
    \\       niftty +ssh-files --pid=<pid> download <absolute-remote-file> <absolute-local-path>
    \\       niftty +ssh-files --pid=<pid> mkdir <absolute-remote-directory>
    \\       niftty +ssh-files --pid=<pid> rename <absolute-old-path> <absolute-new-path>
    \\       niftty +ssh-files --pid=<pid> delete <absolute-remote-path>
    \\
    \\File operations over the SFTP subsystem of an active `niftty +ssh` session.
    \\`--pid` is the foreground `+ssh` process. List and stat output is tab-separated
    \\with Base64-encoded names. Download emits `P` progress records then `D`.
    \\
;

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    pid: ?u64 = null,
    _args: std.ArrayList([]const u8) = .empty,
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(_: Options) !void {
        return Action.help_error;
    }

    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) Allocator.Error!bool {
        if (std.mem.eql(u8, arg, "--")) {
            while (iter.next()) |rest| try self._args.append(alloc, try alloc.dupe(u8, rest));
            return false;
        }
        if (!std.mem.startsWith(u8, arg, "--")) {
            try self._args.append(alloc, try alloc.dupe(u8, arg));
            while (iter.next()) |rest| try self._args.append(alloc, try alloc.dupe(u8, rest));
            return false;
        }
        return true;
    }
};

const Command = union(enum) {
    list: []const u8,
    stat: []const u8,
    download: struct { remote: []const u8, local: []const u8 },
    mkdir: []const u8,
    rename: struct { old: []const u8, new: []const u8 },
    delete: []const u8,
};

fn absoluteRemote(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

fn parseCommand(args: []const []const u8) error{InvalidArgs}!Command {
    if (args.len == 0) return error.InvalidArgs;
    const verb = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, verb, "list")) {
        if (rest.len != 1 or !absoluteRemote(rest[0])) return error.InvalidArgs;
        return .{ .list = rest[0] };
    }
    if (std.mem.eql(u8, verb, "stat")) {
        if (rest.len != 1 or !absoluteRemote(rest[0])) return error.InvalidArgs;
        return .{ .stat = rest[0] };
    }
    if (std.mem.eql(u8, verb, "download")) {
        if (rest.len != 2 or !absoluteRemote(rest[0]) or !std.fs.path.isAbsolute(rest[1])) {
            return error.InvalidArgs;
        }
        return .{ .download = .{ .remote = rest[0], .local = rest[1] } };
    }
    if (std.mem.eql(u8, verb, "mkdir")) {
        if (rest.len != 1 or !absoluteRemote(rest[0])) return error.InvalidArgs;
        return .{ .mkdir = rest[0] };
    }
    if (std.mem.eql(u8, verb, "rename")) {
        if (rest.len != 2 or !absoluteRemote(rest[0]) or !absoluteRemote(rest[1])) {
            return error.InvalidArgs;
        }
        return .{ .rename = .{ .old = rest[0], .new = rest[1] } };
    }
    if (std.mem.eql(u8, verb, "delete")) {
        if (rest.len != 1 or !absoluteRemote(rest[0])) return error.InvalidArgs;
        return .{ .delete = rest[0] };
    }
    return error.InvalidArgs;
}

/// File operations through the multiplexed connection owned by an active
/// `niftty +ssh` process.
///
/// `--pid` identifies the foreground `+ssh` process. Each invocation
/// preflights that process's OpenSSH control master, then opens a
/// short-lived SFTP channel on the already-authenticated connection.
/// Nothing is installed or persisted on the remote host.
///
/// Commands:
///
///   * `list <dir>`: one `E` record per directory entry, skipping `.`
///     and `..`. Names are standard padded Base64.
///
///   * `stat <path>`: one `S` record from `LSTAT` (the final symlink is
///     not followed).
///
///   * `download <remote> <local>`: read the remote file (symlinks are
///     followed) into a temporary sibling of `<local>`, then rename it
///     into place. Progress is `P <bytes> <total-or-zero> <base64-path>`
///     followed by `D <bytes>`.
///
///   * `mkdir <dir>`: create one directory. An existing path is an error.
///
///   * `rename <old> <new>`: standard SFTP v3 rename, which does not
///     overwrite the destination.
///
///   * `delete <path>`: `LSTAT` then `RMDIR` for a directory or `REMOVE`
///     otherwise. Non-recursive.
///
/// Record fields after the tag are tab-separated: kind (`file`,
/// `directory`, `symlink`, `other`), size, mtime, mode, then the
/// Base64 name or path. Missing attributes are `-`.
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
        try stderr.print("Error: invalid +ssh-files arguments.\n\n{s}", .{usage});
        return 2;
    }
    const pid = opts.pid orelse {
        try stderr.print("Error: --pid is required.\n\n{s}", .{usage});
        return 2;
    };
    const command = parseCommand(opts._args.items) catch {
        try stderr.print("Error: invalid +ssh-files arguments.\n\n{s}", .{usage});
        return 2;
    };

    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const session = ssh_session.load(alloc, pid) catch |err| {
        try stderr.print("Error: no active Ghostty SSH session for pid {d}: {t}\n", .{ pid, err });
        return 1;
    };
    if (!checkMaster(alloc, session)) {
        try stderr.print("Error: SSH session is not active\n", .{});
        return 1;
    }

    return runSftp(alloc, session, command) catch |err| {
        try stderr.print("Error: {t}\n", .{err});
        return 1;
    };
}

fn checkMaster(alloc: Allocator, session: ssh_session.Info) bool {
    const result = std.process.run(alloc, global.io(), .{
        .argv = &.{ session.ssh, "-S", session.control_path, "-O", "check", session.destination },
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runSftp(
    alloc: Allocator,
    session: ssh_session.Info,
    command: Command,
) !u8 {
    var child = try std.process.spawn(global.io(), .{
        .argv = &.{
            session.ssh,
            "-o",
            "BatchMode=yes",
            "-S",
            session.control_path,
            "-s",
            session.destination,
            "sftp",
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var waited = false;
    defer {
        if (child.stdin) |file| {
            file.close(global.io());
            child.stdin = null;
        }
        if (!waited and child.id != null) {
            _ = child.wait(global.io()) catch {};
        }
    }

    var write_buffer: [64 * 1024]u8 = undefined;
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_writer = child.stdin.?.writer(global.io(), &write_buffer);
    var file_reader = child.stdout.?.reader(global.io(), &read_buffer);
    var client = ssh_sftp.Client{
        .alloc = alloc,
        .writer = &file_writer.interface,
        .reader = &file_reader.interface,
    };
    try client.handshake();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(global.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;

    switch (command) {
        .list => |path| try listDir(&client, path, stdout),
        .stat => |path| try statPath(&client, path, stdout),
        .download => |paths| try downloadFile(&client, alloc, paths.remote, paths.local, stdout),
        .mkdir => |path| try client.mkdir(path),
        .rename => |paths| try client.rename(paths.old, paths.new),
        .delete => |path| try deletePath(&client, path),
    }
    try stdout.flush();
    try file_writer.interface.flush();

    if (child.stdin) |file| {
        file.close(global.io());
        child.stdin = null;
    }
    const term = try child.wait(global.io());
    waited = true;
    switch (term) {
        .exited => |code| if (code != 0) return error.SftpChildFailed,
        else => return error.SftpChildFailed,
    }
    return 0;
}

fn listDir(client: *ssh_sftp.Client, path: []const u8, stdout: *std.Io.Writer) !void {
    const handle = try client.openDir(path);
    defer client.alloc.free(handle);
    defer client.close(handle) catch {};
    while (try client.readdir(handle)) |payload| {
        defer client.alloc.free(payload);
        var names = try ssh_sftp.NameIter.init(payload);
        while (try names.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            try writeRecord(stdout, 'E', entry.attrs, entry.name);
            try stdout.flush();
        }
    }
}

fn statPath(client: *ssh_sftp.Client, path: []const u8, stdout: *std.Io.Writer) !void {
    const attrs = try client.lstat(path);
    try writeRecord(stdout, 'S', attrs, path);
}

fn downloadFile(
    client: *ssh_sftp.Client,
    alloc: Allocator,
    remote_path: []const u8,
    local_path: []const u8,
    stdout: *std.Io.Writer,
) !void {
    const remote_stat = try client.stat(remote_path);
    const total: u64 = remote_stat.size orelse 0;
    const handle = try client.openRead(remote_path);
    defer alloc.free(handle);

    const temporary = try std.fmt.allocPrint(
        alloc,
        "{s}.niftty-download-{d}",
        .{ local_path, ssh_session.currentPid() },
    );
    var created = false;
    errdefer if (created) std.Io.Dir.deleteFileAbsolute(global.io(), temporary) catch {};

    const file = try std.Io.Dir.createFileAbsolute(global.io(), temporary, .{
        .exclusive = true,
        .truncate = true,
    });
    created = true;

    var completed: u64 = 0;
    var copy_err: ?anyerror = null;
    {
        defer file.close(global.io());
        var offset: u64 = 0;
        while (true) {
            const chunk = client.read(handle, offset, 32 * 1024) catch |err| {
                copy_err = err;
                break;
            } orelse break;
            defer alloc.free(chunk);
            file.writeStreamingAll(global.io(), chunk) catch |err| {
                copy_err = err;
                break;
            };
            offset += chunk.len;
            completed = offset;
            stdout.print("P\t{d}\t{d}\t", .{ offset, total }) catch |err| {
                copy_err = err;
                break;
            };
            std.base64.standard.Encoder.encodeWriter(stdout, remote_path) catch |err| {
                copy_err = err;
                break;
            };
            stdout.writeByte('\n') catch |err| {
                copy_err = err;
                break;
            };
            stdout.flush() catch |err| {
                copy_err = err;
                break;
            };
        }
    }
    client.close(handle) catch |err| {
        if (copy_err == null) copy_err = err;
    };
    if (copy_err) |err| return err;

    try std.Io.Dir.renameAbsolute(temporary, local_path, global.io());
    created = false;
    try stdout.print("D\t{d}\n", .{completed});
}

fn deletePath(client: *ssh_sftp.Client, path: []const u8) !void {
    const attrs = try client.lstat(path);
    if (attrs.kind == .directory) {
        try client.rmdir(path);
    } else {
        try client.remove(path);
    }
}

fn writeRecord(writer: *std.Io.Writer, tag: u8, attrs: ssh_sftp.Attrs, name: []const u8) !void {
    try writer.print("{c}\t{s}\t", .{ tag, @tagName(attrs.kind) });
    if (attrs.size) |size| try writer.print("{d}\t", .{size}) else try writer.writeAll("-\t");
    if (attrs.mtime) |mtime| try writer.print("{d}\t", .{mtime}) else try writer.writeAll("-\t");
    if (attrs.mode) |mode| try writer.print("{d}\t", .{mode}) else try writer.writeAll("-\t");
    try std.base64.standard.Encoder.encodeWriter(writer, name);
    try writer.writeByte('\n');
}

fn parseTestArgs(alloc: Allocator, opts: *Options, line: []const u8) !void {
    var iter = try std.process.Args.IteratorGeneral(.{}).init(alloc, line);
    defer iter.deinit();
    try cli_args.parse(Options, alloc, opts, &iter);
}

test "ssh-files parse: list requires pid and absolute path" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "--pid=42 list /tmp");
    try testing.expectEqual(@as(?u64, 42), opts.pid);
    const command = try parseCommand(opts._args.items);
    try testing.expectEqualStrings("/tmp", command.list);
}

test "ssh-files parse: download arity and absolute local path" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "--pid=7 download /remote/file /tmp/out");
    const command = try parseCommand(opts._args.items);
    try testing.expectEqualStrings("/remote/file", command.download.remote);
    try testing.expectEqualStrings("/tmp/out", command.download.local);
}

test "ssh-files parse: rejects relative remote paths" {
    const testing = std.testing;
    try testing.expect(!absoluteRemote(""));
    try testing.expect(!absoluteRemote("relative"));
    try testing.expect(absoluteRemote("/abs"));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{ "list", "relative" }));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{ "stat", "foo" }));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{ "mkdir", "foo" }));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{ "delete", "foo" }));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{ "rename", "/a", "b" }));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{ "download", "/a", "out" }));
}

test "ssh-files parse: rejects unknown verb and wrong arity" {
    const testing = std.testing;
    try testing.expectError(error.InvalidArgs, parseCommand(&.{}));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{"list"}));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{ "list", "/a", "/b" }));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{"explode"}));
    try testing.expectError(error.InvalidArgs, parseCommand(&.{ "rename", "/a" }));
}

test "ssh-files list framing base64-encodes names" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeRecord(&writer, 'E', .{ .kind = .file, .size = 4, .mtime = 1, .mode = 33188 }, "a\tb\n");
    const out = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "E\tfile\t4\t1\t33188\t"));
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
    const encoded = out["E\tfile\t4\t1\t33188\t".len .. out.len - 1];
    var decoded: [8]u8 = undefined;
    const n = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    try std.base64.standard.Decoder.decode(decoded[0..n], encoded);
    try testing.expectEqualStrings("a\tb\n", decoded[0..n]);
}

test "ssh-files smoke: stub sftp-server" {
    const testing = std.testing;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const server = "/usr/libexec/sftp-server";
    std.Io.Dir.accessAbsolute(testing.io, server, .{}) catch return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const tmp_path = path_buf[0..n];

    const stub_path = try std.fs.path.join(alloc, &.{ tmp_path, "ssh-stub" });
    const stub = try std.Io.Dir.createFileAbsolute(global.io(), stub_path, .{
        .permissions = .fromMode(0o755),
    });
    try stub.writeStreamingAll(global.io(),
        \\#!/bin/sh
        \\for arg in "$@"; do
        \\    if [ "$arg" = "check" ]; then exit 0; fi
        \\done
        \\for arg in "$@"; do
        \\    if [ "$arg" = "sftp" ]; then exec /usr/libexec/sftp-server; fi
        \\done
        \\exit 1
        \\
    );
    stub.close(global.io());

    const payload = "ssh-files-smoke-bytes\n";
    const remote_file = try std.fs.path.join(alloc, &.{ tmp_path, "payload.txt" });
    {
        const file = try std.Io.Dir.createFileAbsolute(global.io(), remote_file, .{});
        defer file.close(global.io());
        try file.writeStreamingAll(global.io(), payload);
    }

    const pid: u64 = 89199199;
    ssh_session.remove(alloc, pid);
    try ssh_session.write(alloc, pid, .{
        .control_path = "/dev/null",
        .destination = "unused",
        .ssh = stub_path,
    });
    defer ssh_session.remove(alloc, pid);

    const session = try ssh_session.load(alloc, pid);
    try testing.expect(checkMaster(alloc, session));

    var child = try std.process.spawn(global.io(), .{
        .argv = &.{
            session.ssh,
            "-o",
            "BatchMode=yes",
            "-S",
            session.control_path,
            "-s",
            session.destination,
            "sftp",
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer {
        if (child.stdin) |file| {
            file.close(global.io());
            child.stdin = null;
        }
        if (child.id != null) {
            _ = child.wait(global.io()) catch {};
        }
    }

    var write_buffer: [64 * 1024]u8 = undefined;
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_writer = child.stdin.?.writer(global.io(), &write_buffer);
    var file_reader = child.stdout.?.reader(global.io(), &read_buffer);
    var client = ssh_sftp.Client{
        .alloc = alloc,
        .writer = &file_writer.interface,
        .reader = &file_reader.interface,
    };
    try client.handshake();

    var out: std.Io.Writer.Allocating = .init(alloc);
    try listDir(&client, tmp_path, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "E\tfile\t") != null);

    const local_out = try std.fs.path.join(alloc, &.{ tmp_path, "got.txt" });
    try downloadFile(&client, alloc, remote_file, local_out, &out.writer);
    {
        const got_file = try std.Io.Dir.openFileAbsolute(global.io(), local_out, .{});
        defer got_file.close(global.io());
        var reader = got_file.reader(global.io(), &.{});
        const got = try reader.interface.allocRemaining(alloc, .limited(64));
        try testing.expectEqualStrings(payload, got);
    }
    try testing.expect(std.mem.indexOf(u8, out.written(), "D\t") != null);

    const renamed = try std.fs.path.join(alloc, &.{ tmp_path, "renamed.txt" });
    try client.rename(remote_file, renamed);
    try deletePath(&client, renamed);
    try testing.expectError(error.NotFound, client.lstat(renamed));

    const empty = try std.fs.path.join(alloc, &.{ tmp_path, "empty-dir" });
    try client.mkdir(empty);
    try deletePath(&client, empty);
    try testing.expectError(error.NotFound, client.lstat(empty));

    var dir = try std.Io.Dir.openDirAbsolute(global.io(), tmp_path, .{ .iterate = true });
    defer dir.close(global.io());
    var iterator = dir.iterate();
    while (try iterator.next(global.io())) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, "niftty-download") == null);
        try testing.expect(std.mem.indexOf(u8, entry.name, "remote-server") == null);
        try testing.expect(std.mem.indexOf(u8, entry.name, "warp") == null);
    }
}
