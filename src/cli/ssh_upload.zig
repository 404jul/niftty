const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const cli_args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const global = @import("../global.zig");
const ssh_session = @import("ssh_session.zig");

const usage =
    \\Usage: ghostty +ssh-upload --pid=<pid> --remote-dir=<path> [--verbose=<bool>] <paths...>
    \\
    \\Uploads files and directories through the active multiplexed SSH session.
    \\Progress is emitted as tab-separated `P <bytes> <total> <base64-name>` records.
    \\
;

/// Read a boolean flag from the environment. Unset or any value other
/// than "0" counts as enabled, matching `+ssh`'s env flag handling.
fn envFlagEnabled(name: []const u8) bool {
    var environ = global.environMap() catch return true;
    defer environ.deinit();
    return !std.mem.eql(u8, environ.get(name) orelse return true, "0");
}

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    pid: ?u64 = null,
    @"remote-dir": ?[]const u8 = null,
    verbose: bool = true,
    _paths: std.ArrayList([]const u8) = .empty,
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
            while (iter.next()) |rest| try self._paths.append(alloc, try alloc.dupe(u8, rest));
            return false;
        }
        if (!std.mem.startsWith(u8, arg, "--")) {
            try self._paths.append(alloc, try alloc.dupe(u8, arg));
            while (iter.next()) |rest| try self._paths.append(alloc, try alloc.dupe(u8, rest));
            return false;
        }
        return true;
    }
};

const Entry = struct {
    local_path: []const u8,
    remote_relative: []const u8,
    kind: enum { directory, file, sym_link },
    size: u64 = 0,
    symlink_target: []const u8 = "",
};

/// Upload local files and directories through the multiplexed connection
/// owned by an active `ghostty +ssh` process.
///
/// This action is normally launched by Ghostty's macOS drag-and-drop UI.
/// `--pid` identifies the foreground `+ssh` process, `--remote-dir` is the
/// OSC 7 working directory reported by the remote shell, and remaining
/// arguments are absolute local paths.
///
/// The upload first uses the remote SFTP subsystem through the existing
/// authenticated SSH connection. If SFTP is unavailable, it streams each file
/// to a temporary remote path and atomically renames it into place.
///
/// Available since: 1.4.0
pub fn run(gpa: Allocator) !u8 {
    var opts: Options = .{};
    // The surface injects GHOSTTY_SSH_UPLOAD_VERBOSE (from the
    // `ssh-upload-verbose` config option) into the shell environment.
    // It seeds the default; an explicit --verbose flag overrides it.
    opts.verbose = envFlagEnabled("GHOSTTY_SSH_UPLOAD_VERBOSE");
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
        try stderr.print("Error: invalid +ssh-upload arguments.\n\n{s}", .{usage});
        return 2;
    }
    const pid = opts.pid orelse {
        try stderr.print("Error: --pid is required.\n\n{s}", .{usage});
        return 2;
    };
    const remote_dir = opts.@"remote-dir" orelse {
        try stderr.print("Error: --remote-dir is required.\n\n{s}", .{usage});
        return 2;
    };
    if (!usableRemoteDir(remote_dir)) {
        try stderr.print("Error: unusable remote directory: {s}\n", .{remote_dir});
        return 1;
    }
    if (opts._paths.items.len == 0) {
        try stderr.print("Error: at least one path is required.\n\n{s}", .{usage});
        return 2;
    }

    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const session = ssh_session.load(alloc, pid) catch |err| {
        try stderr.print("Error: no active Ghostty SSH session for pid {d}: {t}\n", .{ pid, err });
        return 1;
    };

    var entries: std.ArrayList(Entry) = .empty;
    var total: u64 = 0;
    for (opts._paths.items) |path| {
        if (!std.fs.path.isAbsolute(path)) {
            try stderr.print("Error: dropped path is not absolute: {s}\n", .{path});
            return 1;
        }
        gatherPath(alloc, path, std.fs.path.basename(path), &entries, &total) catch |err| {
            try stderr.print("Error: unsupported or unreadable path {s}: {t}\n", .{ path, err });
            return 1;
        };
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(global.io(), &stdout_buffer);
    const progress = &stdout_writer.interface;

    uploadSftp(alloc, session, remote_dir, entries.items, total, opts.verbose, progress) catch |sftp_err| {
        try stderr.print("SFTP unavailable ({t}); using SSH stream fallback.\n", .{sftp_err});
        uploadFallback(alloc, session, remote_dir, entries.items, total, opts.verbose, progress) catch |err| {
            switch (err) {
                error.RemoteCommandFailed => {},
                else => try stderr.print("Error: upload failed: {t}\n", .{err}),
            }
            return 1;
        };
    };
    if (opts.verbose) {
        try progress.print("D\t{d}\n", .{total});
        try progress.flush();
    }
    return 0;
}

fn gatherPath(
    alloc: Allocator,
    local_path: []const u8,
    relative: []const u8,
    entries: *std.ArrayList(Entry),
    total: *u64,
) !void {
    const stat = try std.Io.Dir.cwd().statFile(global.io(), local_path, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .file => {
            try entries.append(alloc, .{
                .local_path = try alloc.dupe(u8, local_path),
                .remote_relative = try alloc.dupe(u8, relative),
                .kind = .file,
                .size = stat.size,
            });
            total.* = try std.math.add(u64, total.*, stat.size);
        },
        .directory => {
            try entries.append(alloc, .{
                .local_path = try alloc.dupe(u8, local_path),
                .remote_relative = try alloc.dupe(u8, relative),
                .kind = .directory,
            });
            var dir = try std.Io.Dir.openDirAbsolute(global.io(), local_path, .{ .iterate = true });
            defer dir.close(global.io());
            var iterator = dir.iterate();
            while (try iterator.next(global.io())) |child| {
                const child_local = try std.fs.path.join(alloc, &.{ local_path, child.name });
                const child_relative = try remoteJoin(alloc, relative, child.name);
                try gatherPath(alloc, child_local, child_relative, entries, total);
            }
        },
        .sym_link => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = try std.Io.Dir.readLinkAbsolute(global.io(), local_path, &buf);
            try entries.append(alloc, .{
                .local_path = try alloc.dupe(u8, local_path),
                .remote_relative = try alloc.dupe(u8, relative),
                .kind = .sym_link,
                .symlink_target = try alloc.dupe(u8, buf[0..n]),
            });
        },
        else => return error.SpecialFileNotSupported,
    }
}

fn remoteJoin(alloc: Allocator, parent: []const u8, child: []const u8) ![]u8 {
    return if (std.mem.endsWith(u8, parent, "/"))
        std.fmt.allocPrint(alloc, "{s}{s}", .{ parent, child })
    else
        std.fmt.allocPrint(alloc, "{s}/{s}", .{ parent, child });
}

fn reportProgress(
    verbose: bool,
    writer: *std.Io.Writer,
    completed: u64,
    total: u64,
    name: []const u8,
) !void {
    if (!verbose) return;
    try writer.print("P\t{d}\t{d}\t", .{ completed, total });
    try std.base64.standard.Encoder.encodeWriter(writer, name);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Close stdin and wait if the child has not already been reaped.
/// `Child.wait` asserts `id != null` and is not idempotent: wait cleanup
/// nulls `id`, so a second wait panics with `reached unreachable code`.
fn reap(child: *std.process.Child) void {
    if (child.stdin) |file| {
        file.close(global.io());
        child.stdin = null;
    }
    if (child.id != null) {
        _ = child.wait(global.io()) catch {};
    }
}

fn usableRemoteDir(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (std.mem.indexOf(u8, path, "readlink:") != null) return false;
    if (std.mem.startsWith(u8, path, "/proc/") and
        std.mem.indexOf(u8, path, "/cwd") != null) return false;
    return true;
}

fn drainPipe(file: std.Io.File, buf: []u8) usize {
    var n: usize = 0;
    while (n < buf.len) {
        const rest = buf[n..];
        const got = file.readStreaming(global.io(), &.{rest}) catch return n;
        if (got == 0) return n;
        n += got;
    }
    var scratch: [512]u8 = undefined;
    while (true) {
        const got = file.readStreaming(global.io(), &.{&scratch}) catch break;
        if (got == 0) break;
    }
    return n;
}

fn printRemoteError(detail: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var file = std.Io.File.stderr();
    var writer = file.writer(global.io(), &buffer);
    const stderr = &writer.interface;
    const line = if (std.mem.indexOfScalar(u8, detail, '\n')) |i| detail[0..i] else detail;
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) {
        stderr.print("Error: upload failed: RemoteCommandFailed\n", .{}) catch return;
    } else {
        stderr.print("Error: upload failed: {s}\n", .{trimmed}) catch return;
    }
    stderr.flush() catch {};
}

fn uploadSftp(
    alloc: Allocator,
    session: ssh_session.Info,
    remote_dir: []const u8,
    entries: []const Entry,
    total: u64,
    verbose: bool,
    progress: *std.Io.Writer,
) !void {
    var child = try std.process.spawn(global.io(), .{
        .argv = &.{ session.ssh, "-S", session.control_path, "-s", session.destination, "sftp" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer reap(&child);

    var write_buffer: [64 * 1024]u8 = undefined;
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_writer = child.stdin.?.writer(global.io(), &write_buffer);
    var file_reader = child.stdout.?.reader(global.io(), &read_buffer);
    var client = SftpClient{
        .alloc = alloc,
        .writer = &file_writer.interface,
        .reader = &file_reader.interface,
    };
    try client.handshake();

    var completed: u64 = 0;
    for (entries, 0..) |entry, index| {
        const remote_path = try remoteJoin(alloc, remote_dir, entry.remote_relative);
        switch (entry.kind) {
            .directory => try client.mkdir(remote_path),
            .sym_link => {
                const parent = std.fs.path.dirname(remote_path) orelse remote_dir;
                try client.mkdir(parent);
                const temporary = try std.fmt.allocPrint(
                    alloc,
                    "{s}.ghostty-upload-{d}-{d}",
                    .{ remote_path, ssh_session.currentPid(), index },
                );
                try client.symlink(entry.symlink_target, temporary);
                client.posixRename(temporary, remote_path) catch |err| {
                    client.remove(temporary) catch {};
                    return err;
                };
            },
            .file => {
                const parent = std.fs.path.dirname(remote_path) orelse remote_dir;
                try client.mkdir(parent);
                const temporary = try std.fmt.allocPrint(
                    alloc,
                    "{s}.ghostty-upload-{d}-{d}",
                    .{ remote_path, ssh_session.currentPid(), index },
                );
                try client.uploadFile(entry.local_path, temporary, &completed, total, verbose, progress);
                try client.posixRename(temporary, remote_path);
            },
        }
    }
    try file_writer.interface.flush();
}

const SftpClient = struct {
    alloc: Allocator,
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    next_id: u32 = 1,

    const max_packet_size = 1024 * 1024;

    fn handshake(self: *SftpClient) !void {
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(1); // SSH_FXP_INIT
        try putU32(&body.writer, 3);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (response.len < 5 or response[0] != 2 or getU32(response[1..5]) != 3) {
            return error.UnsupportedSftpVersion;
        }
    }

    fn mkdir(self: *SftpClient, path: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(14); // SSH_FXP_MKDIR
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try putU32(&body.writer, 0); // empty attrs
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        const status = try statusCode(response, id);
        // OpenSSH reports generic failure when the directory already exists.
        if (status != 0 and status != 4) return error.SftpMkdirFailed;
    }

    fn remove(self: *SftpClient, path: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(13); // SSH_FXP_REMOVE
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (try statusCode(response, id) != 0) return error.SftpRemoveFailed;
    }

    fn uploadFile(
        self: *SftpClient,
        local_path: []const u8,
        remote_path: []const u8,
        completed: *u64,
        total: u64,
        verbose: bool,
        progress: *std.Io.Writer,
    ) !void {
        const handle = try self.open(remote_path);
        defer self.alloc.free(handle);

        const file = try std.Io.Dir.openFileAbsolute(global.io(), local_path, .{});
        defer file.close(global.io());
        var offset: u64 = 0;
        var buffer: [32 * 1024]u8 = undefined;
        while (true) {
            const amount = file.readStreaming(global.io(), &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (amount == 0) break;
            try self.write(handle, offset, buffer[0..amount]);
            offset += amount;
            completed.* += amount;
            try reportProgress(verbose, progress, completed.*, total, local_path);
        }
        try self.close(handle);
    }

    fn open(self: *SftpClient, path: []const u8) ![]u8 {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(3); // SSH_FXP_OPEN
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try putU32(&body.writer, 0x1a); // WRITE | CREAT | TRUNC
        try putU32(&body.writer, 0); // empty attrs
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (response.len < 9 or response[0] != 102 or getU32(response[1..5]) != id) {
            return error.SftpOpenFailed;
        }
        var packet = PacketReader{ .data = response[5..] };
        return self.alloc.dupe(u8, try packet.string());
    }

    fn write(self: *SftpClient, handle: []const u8, offset: u64, data: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(6); // SSH_FXP_WRITE
        try putU32(&body.writer, id);
        try putString(&body.writer, handle);
        try putU64(&body.writer, offset);
        try putString(&body.writer, data);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (try statusCode(response, id) != 0) return error.SftpWriteFailed;
    }

    fn close(self: *SftpClient, handle: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(4); // SSH_FXP_CLOSE
        try putU32(&body.writer, id);
        try putString(&body.writer, handle);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (try statusCode(response, id) != 0) return error.SftpCloseFailed;
    }

    fn posixRename(self: *SftpClient, old_path: []const u8, new_path: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(200); // SSH_FXP_EXTENDED
        try putU32(&body.writer, id);
        try putString(&body.writer, "posix-rename@openssh.com");
        try putString(&body.writer, old_path);
        try putString(&body.writer, new_path);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (try statusCode(response, id) != 0) return error.SftpAtomicRenameFailed;
    }

    /// OpenSSH SFTP v3: SSH_FXP_SYMLINK arguments are target, then link path
    /// (reversed from the IETF draft). Message type 20; 18 is RENAME.
    fn symlink(self: *SftpClient, target: []const u8, link_path: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try encodeSymlinkRequest(&body.writer, id, target, link_path);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (try statusCode(response, id) != 0) return error.SftpSymlinkFailed;
    }

    fn readLink(self: *SftpClient, path: []const u8) ![]u8 {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(19); // SSH_FXP_READLINK
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (response.len < 13 or response[0] != 104 or getU32(response[1..5]) != id) {
            return error.SftpReadLinkFailed;
        }
        if (getU32(response[5..9]) < 1) return error.SftpReadLinkFailed;
        var packet = PacketReader{ .data = response[9..] };
        return self.alloc.dupe(u8, try packet.string());
    }

    fn send(self: *SftpClient, body: []const u8) !void {
        try putU32(self.writer, @intCast(body.len));
        try self.writer.writeAll(body);
        try self.writer.flush();
    }

    fn receive(self: *SftpClient) ![]u8 {
        var length_bytes: [4]u8 = undefined;
        try self.reader.readSliceAll(&length_bytes);
        const length = getU32(&length_bytes);
        if (length == 0 or length > max_packet_size) return error.InvalidSftpPacket;
        const packet = try self.alloc.alloc(u8, length);
        errdefer self.alloc.free(packet);
        try self.reader.readSliceAll(packet);
        return packet;
    }

    fn takeId(self: *SftpClient) u32 {
        defer self.next_id +%= 1;
        return self.next_id;
    }
};

const PacketReader = struct {
    data: []const u8,
    offset: usize = 0,

    fn string(self: *PacketReader) ![]const u8 {
        if (self.data.len - self.offset < 4) return error.InvalidSftpPacket;
        const length = getU32(self.data[self.offset..][0..4]);
        self.offset += 4;
        if (length > self.data.len - self.offset) return error.InvalidSftpPacket;
        defer self.offset += length;
        return self.data[self.offset..][0..length];
    }
};

const ssh_fxp_symlink: u8 = 20;

fn encodeSymlinkRequest(writer: *std.Io.Writer, id: u32, target: []const u8, link_path: []const u8) !void {
    try writer.writeByte(ssh_fxp_symlink);
    try putU32(writer, id);
    try putString(writer, target);
    try putString(writer, link_path);
}

fn statusCode(response: []const u8, id: u32) !u32 {
    if (response.len < 9 or response[0] != 101 or getU32(response[1..5]) != id) {
        return error.InvalidSftpStatus;
    }
    return getU32(response[5..9]);
}

fn putU32(writer: *std.Io.Writer, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try writer.writeAll(&bytes);
}

fn putU64(writer: *std.Io.Writer, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    try writer.writeAll(&bytes);
}

fn putString(writer: *std.Io.Writer, value: []const u8) !void {
    try putU32(writer, @intCast(value.len));
    try writer.writeAll(value);
}

fn getU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

fn uploadFallback(
    alloc: Allocator,
    session: ssh_session.Info,
    remote_dir: []const u8,
    entries: []const Entry,
    total: u64,
    verbose: bool,
    progress: *std.Io.Writer,
) !void {
    var completed: u64 = 0;
    for (entries, 0..) |entry, index| {
        const remote_path = try remoteJoin(alloc, remote_dir, entry.remote_relative);
        switch (entry.kind) {
            .directory => {
                const quoted = try shellQuote(alloc, remote_path);
                const command = try std.fmt.allocPrint(alloc, "mkdir -p -- {s}", .{quoted});
                try runRemote(session, command, null, null, false, progress, &completed, total);
            },
            .sym_link => {
                const parent = std.fs.path.dirname(remote_path) orelse remote_dir;
                const quoted_parent = try shellQuote(alloc, parent);
                const quoted_dest = try shellQuote(alloc, remote_path);
                const quoted_target = try shellQuote(alloc, entry.symlink_target);
                const temporary = try std.fmt.allocPrint(
                    alloc,
                    "{s}.ghostty-upload-{d}-{d}",
                    .{ remote_path, ssh_session.currentPid(), index },
                );
                const quoted_temp = try shellQuote(alloc, temporary);
                const command = try std.fmt.allocPrint(
                    alloc,
                    "mkdir -p -- {s} && rm -f -- {s} && ln -s -- {s} {s} && " ++
                        "if [ -d {s} ] && [ ! -L {s} ]; then rm -f -- {s}; exit 1; fi && " ++
                        "mv -f -- {s} {s} || {{ rm -f -- {s}; exit 1; }}",
                    .{
                        quoted_parent,
                        quoted_temp,
                        quoted_target,
                        quoted_temp,
                        quoted_dest,
                        quoted_dest,
                        quoted_temp,
                        quoted_temp,
                        quoted_dest,
                        quoted_temp,
                    },
                );
                try runRemote(session, command, null, null, false, progress, &completed, total);
            },
            .file => {
                const parent = std.fs.path.dirname(remote_path) orelse remote_dir;
                const quoted_parent = try shellQuote(alloc, parent);
                const quoted_dest = try shellQuote(alloc, remote_path);
                const temporary = try std.fmt.allocPrint(
                    alloc,
                    "{s}.ghostty-upload-{d}-{d}",
                    .{ remote_path, ssh_session.currentPid(), index },
                );
                const quoted_temp = try shellQuote(alloc, temporary);
                const command = try std.fmt.allocPrint(
                    alloc,
                    "umask 077; mkdir -p -- {s} && cat > {s} && " ++
                        "[ \"$(wc -c < {s})\" -eq {d} ] && mv -f -- {s} {s}",
                    .{ quoted_parent, quoted_temp, quoted_temp, entry.size, quoted_temp, quoted_dest },
                );
                try runRemote(
                    session,
                    command,
                    entry.local_path,
                    entry.local_path,
                    verbose,
                    progress,
                    &completed,
                    total,
                );
            },
        }
    }
}

fn runRemote(
    session: ssh_session.Info,
    command: []const u8,
    local_path: ?[]const u8,
    display_name: ?[]const u8,
    verbose: bool,
    progress: *std.Io.Writer,
    completed: *u64,
    total: u64,
) !void {
    var child = try std.process.spawn(global.io(), .{
        .argv = &.{ session.ssh, "-S", session.control_path, session.destination, command },
        .stdin = if (local_path != null) .pipe else .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer reap(&child);
    errdefer child.kill(global.io());
    if (local_path) |path| {
        const file = try std.Io.Dir.openFileAbsolute(global.io(), path, .{});
        defer file.close(global.io());
        var buffer: [32 * 1024]u8 = undefined;
        while (true) {
            const amount = file.readStreaming(global.io(), &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (amount == 0) break;
            try child.stdin.?.writeStreamingAll(global.io(), buffer[0..amount]);
            completed.* += amount;
            try reportProgress(verbose, progress, completed.*, total, display_name.?);
        }
        child.stdin.?.close(global.io());
        child.stdin = null;
    }

    var err_buf: [4096]u8 = undefined;
    const err_n = if (child.stderr) |file| drainPipe(file, &err_buf) else 0;

    const term = try child.wait(global.io());
    if (switch (term) {
        .exited => |code| code != 0,
        else => true,
    }) {
        printRemoteError(err_buf[0..err_n]);
        return error.RemoteCommandFailed;
    }
}

fn shellQuote(alloc: Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return alloc.dupe(u8, "''");
    if (std.mem.indexOfAny(u8, value, " \\()[]{}<>\"'`!#$&;|*?\t\r\n") == null) {
        return alloc.dupe(u8, value);
    }
    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();
    try writer.writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') try writer.writer.writeAll("'\"'\"'") else try writer.writer.writeByte(byte);
    }
    try writer.writer.writeByte('\'');
    return writer.toOwnedSlice();
}

test "SFTP packet integer encoding" {
    var bytes: [12]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try putU32(&writer, 0x01020304);
    try putU64(&writer, 0x05060708090a0b0c);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, writer.buffered());
}

test "shell quoting protects remote paths" {
    const quoted = try shellQuote(std.testing.allocator, "a'b c");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'a'\"'\"'b c'", quoted);
}

test "runRemote non-zero exit does not panic" {
    const testing = std.testing;
    const session = ssh_session.Info{
        .control_path = "/dev/null",
        .destination = "unused",
        .ssh = "/usr/bin/false",
    };
    var completed: u64 = 0;
    var buf: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expectError(
        error.RemoteCommandFailed,
        runRemote(session, "true", null, null, false, &writer, &completed, 0),
    );
}

test "usableRemoteDir rejects lsof readlink failures" {
    const testing = std.testing;
    try testing.expect(usableRemoteDir("/home/julian/src"));
    try testing.expect(usableRemoteDir("/tmp"));
    try testing.expect(!usableRemoteDir(""));
    try testing.expect(!usableRemoteDir("relative"));
    try testing.expect(!usableRemoteDir("/proc/3107671/cwd"));
    try testing.expect(!usableRemoteDir("/proc/3107671/cwd (readlink: Permission denied)"));
}

test "uploadFallback succeeds when SFTP subsystem is unavailable" {
    const testing = std.testing;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_n = try tmp.dir.realPath(testing.io, &path_buf);
    const tmp_path = path_buf[0..tmp_n];

    const stub_path = try std.fs.path.join(alloc, &.{ tmp_path, "ssh-stub" });
    const stub_file = try std.Io.Dir.createFileAbsolute(global.io(), stub_path, .{
        .permissions = .fromMode(0o755),
    });
    try stub_file.writeStreamingAll(global.io(),
        \\#!/bin/sh
        \\for arg in "$@"; do
        \\    if [ "$arg" = "-s" ]; then exit 1; fi
        \\done
        \\cmd=""
        \\for arg in "$@"; do cmd="$arg"; done
        \\eval "$cmd"
        \\
    );
    stub_file.close(global.io());

    const payload = "fallback-probe\n";
    const local_path = try std.fs.path.join(alloc, &.{ tmp_path, "local.txt" });
    const local_file = try std.Io.Dir.createFileAbsolute(global.io(), local_path, .{});
    try local_file.writeStreamingAll(global.io(), payload);
    local_file.close(global.io());

    const dest_dir = try std.fs.path.join(alloc, &.{ tmp_path, "dest" });
    try std.Io.Dir.cwd().createDirPath(global.io(), dest_dir);

    const session = ssh_session.Info{
        .control_path = "/dev/null",
        .destination = "unused",
        .ssh = stub_path,
    };
    const entries = [_]Entry{.{
        .local_path = local_path,
        .remote_relative = "probe.txt",
        .kind = .file,
        .size = payload.len,
    }};

    var progress_buf: [256]u8 = undefined;
    var progress: std.Io.Writer = .fixed(&progress_buf);
    uploadSftp(alloc, session, dest_dir, &entries, payload.len, false, &progress) catch {
        try uploadFallback(alloc, session, dest_dir, &entries, payload.len, false, &progress);
    };

    const uploaded = try std.fs.path.join(alloc, &.{ dest_dir, "probe.txt" });
    const got_file = try std.Io.Dir.openFileAbsolute(global.io(), uploaded, .{});
    defer got_file.close(global.io());
    var reader = got_file.reader(global.io(), &.{});
    const got = try reader.interface.allocRemaining(alloc, .limited(32));
    try testing.expectEqualStrings(payload, got);
}

test "SFTP symlink request is type 20 with OpenSSH argument order" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeSymlinkRequest(&writer, 3, "A", "Current");
    const out = writer.buffered();
    try testing.expectEqual(@as(u8, 20), out[0]);
    try testing.expectEqual(@as(u32, 3), getU32(out[1..5]));
    try testing.expectEqual(@as(u32, 1), getU32(out[5..9]));
    try testing.expectEqualStrings("A", out[9..10]);
    try testing.expectEqual(@as(u32, 7), getU32(out[10..14]));
    try testing.expectEqualStrings("Current", out[14..21]);
}

test "OpenSSH sftp-server round-trips symlink" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const server = "/usr/libexec/sftp-server";
    std.Io.Dir.accessAbsolute(testing.io, server, .{}) catch return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const tmp_path = path_buf[0..n];
    const link_path = try std.fs.path.join(alloc, &.{ tmp_path, "Current" });
    defer alloc.free(link_path);

    var child = std.process.spawn(global.io(), .{
        .argv = &.{server},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer {
        if (child.stdin) |file| {
            file.close(global.io());
            child.stdin = null;
        }
        _ = child.wait(global.io()) catch {};
    }

    var write_buffer: [4096]u8 = undefined;
    var read_buffer: [4096]u8 = undefined;
    var file_writer = child.stdin.?.writer(global.io(), &write_buffer);
    var file_reader = child.stdout.?.reader(global.io(), &read_buffer);
    var client = SftpClient{
        .alloc = alloc,
        .writer = &file_writer.interface,
        .reader = &file_reader.interface,
    };
    try client.handshake();
    try client.symlink("A", link_path);
    const got = try client.readLink(link_path);
    defer alloc.free(got);
    try testing.expectEqualStrings("A", got);
}
