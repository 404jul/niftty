const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_packet_size = 1024 * 1024;

pub const Kind = enum { file, directory, symlink, other };

pub const Attrs = struct {
    kind: Kind = .other,
    size: ?u64 = null,
    mtime: ?u32 = null,
    mode: ?u32 = null,
};

const ssh_fxp_init: u8 = 1;
const ssh_fxp_version: u8 = 2;
const ssh_fxp_open: u8 = 3;
const ssh_fxp_close: u8 = 4;
const ssh_fxp_read: u8 = 5;
const ssh_fxp_write: u8 = 6;
const ssh_fxp_lstat: u8 = 7;
const ssh_fxp_opendir: u8 = 11;
const ssh_fxp_readdir: u8 = 12;
const ssh_fxp_remove: u8 = 13;
const ssh_fxp_mkdir: u8 = 14;
const ssh_fxp_rmdir: u8 = 15;
const ssh_fxp_stat: u8 = 17;
const ssh_fxp_rename: u8 = 18;
const ssh_fxp_readlink: u8 = 19;
const ssh_fxp_symlink: u8 = 20;
const ssh_fxp_status: u8 = 101;
const ssh_fxp_handle: u8 = 102;
const ssh_fxp_data: u8 = 103;
const ssh_fxp_name: u8 = 104;
const ssh_fxp_attrs: u8 = 105;
const ssh_fxp_extended: u8 = 200;

const ssh_fxf_read: u32 = 0x00000001;
const ssh_fxf_write: u32 = 0x00000002;
const ssh_fxf_creat: u32 = 0x00000008;
const ssh_fxf_trunc: u32 = 0x00000010;

const attr_size: u32 = 0x00000001;
const attr_uidgid: u32 = 0x00000002;
const attr_permissions: u32 = 0x00000004;
const attr_acmodtime: u32 = 0x00000008;
const attr_extended: u32 = 0x80000000;

const s_ifmt: u32 = 0o170000;
const s_ifdir: u32 = 0o040000;
const s_ifreg: u32 = 0o100000;
const s_iflnk: u32 = 0o120000;

pub const Client = struct {
    alloc: Allocator,
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    next_id: u32 = 1,
    posix_rename: bool = false,

    pub fn handshake(self: *Client) !void {
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_init);
        try putU32(&body.writer, 3);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (response.len < 5 or response[0] != ssh_fxp_version or getU32(response[1..5]) != 3) {
            return error.UnsupportedSftpVersion;
        }
        var packet = PacketReader{ .data = response[5..] };
        while (packet.remaining() > 0) {
            const name = packet.string() catch return error.InvalidSftpPacket;
            _ = packet.string() catch return error.InvalidSftpPacket;
            if (std.mem.eql(u8, name, "posix-rename@openssh.com")) {
                self.posix_rename = true;
            }
        }
    }

    pub fn mkdir(self: *Client, path: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_mkdir);
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try putU32(&body.writer, 0);
        try self.send(body.written());
        try self.expectOk(id);
    }

    pub fn remove(self: *Client, path: []const u8) !void {
        try self.pathOp(ssh_fxp_remove, path);
    }

    pub fn rmdir(self: *Client, path: []const u8) !void {
        try self.pathOp(ssh_fxp_rmdir, path);
    }

    pub fn rename(self: *Client, old_path: []const u8, new_path: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_rename);
        try putU32(&body.writer, id);
        try putString(&body.writer, old_path);
        try putString(&body.writer, new_path);
        try self.send(body.written());
        try self.expectOk(id);
    }

    pub fn posixRename(self: *Client, old_path: []const u8, new_path: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_extended);
        try putU32(&body.writer, id);
        try putString(&body.writer, "posix-rename@openssh.com");
        try putString(&body.writer, old_path);
        try putString(&body.writer, new_path);
        try self.send(body.written());
        try self.expectOk(id);
    }

    /// OpenSSH SFTP v3: SSH_FXP_SYMLINK arguments are target, then link path
    /// (reversed from the IETF draft).
    pub fn symlink(self: *Client, target: []const u8, link_path: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try encodeSymlinkRequest(&body.writer, id, target, link_path);
        try self.send(body.written());
        try self.expectOk(id);
    }

    pub fn readLink(self: *Client, path: []const u8) ![]u8 {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_readlink);
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        try expectType(response, id, ssh_fxp_name);
        if (response.len < 13) return error.InvalidSftpPacket;
        if (getU32(response[5..9]) < 1) return error.InvalidSftpPacket;
        var packet = PacketReader{ .data = response[9..] };
        return self.alloc.dupe(u8, try packet.string());
    }

    pub fn openWrite(self: *Client, path: []const u8) ![]u8 {
        return self.open(path, ssh_fxf_write | ssh_fxf_creat | ssh_fxf_trunc);
    }

    pub fn openRead(self: *Client, path: []const u8) ![]u8 {
        return self.open(path, ssh_fxf_read);
    }

    pub fn write(self: *Client, handle: []const u8, offset: u64, data: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_write);
        try putU32(&body.writer, id);
        try putString(&body.writer, handle);
        try putU64(&body.writer, offset);
        try putString(&body.writer, data);
        try self.send(body.written());
        try self.expectOk(id);
    }

    /// Returns owned file bytes. Null means SFTP EOF.
    pub fn read(self: *Client, handle: []const u8, offset: u64, len: u32) !?[]u8 {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_read);
        try putU32(&body.writer, id);
        try putString(&body.writer, handle);
        try putU64(&body.writer, offset);
        try putU32(&body.writer, len);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (isStatus(response, id)) {
            const code = try statusCode(response, id);
            if (code == 1) return null;
            return statusError(code);
        }
        try expectType(response, id, ssh_fxp_data);
        var packet = PacketReader{ .data = response[5..] };
        const data: ?[]u8 = try self.alloc.dupe(u8, try packet.string());
        return data;
    }

    pub fn openDir(self: *Client, path: []const u8) ![]u8 {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_opendir);
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try self.send(body.written());
        return self.expectHandle(id);
    }

    /// Returns the NAME payload after type+id, or null on EOF. Caller frees.
    pub fn readdir(self: *Client, handle: []const u8) !?[]u8 {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_readdir);
        try putU32(&body.writer, id);
        try putString(&body.writer, handle);
        try self.send(body.written());
        const response = try self.receive();
        errdefer self.alloc.free(response);
        if (isStatus(response, id)) {
            const code = try statusCode(response, id);
            self.alloc.free(response);
            if (code == 1) return null;
            return statusError(code);
        }
        try expectType(response, id, ssh_fxp_name);
        const payload: ?[]u8 = try self.alloc.dupe(u8, response[5..]);
        self.alloc.free(response);
        return payload;
    }

    pub fn close(self: *Client, handle: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_close);
        try putU32(&body.writer, id);
        try putString(&body.writer, handle);
        try self.send(body.written());
        try self.expectOk(id);
    }

    pub fn stat(self: *Client, path: []const u8) !Attrs {
        return self.statPath(ssh_fxp_stat, path);
    }

    pub fn lstat(self: *Client, path: []const u8) !Attrs {
        return self.statPath(ssh_fxp_lstat, path);
    }

    fn open(self: *Client, path: []const u8, pflags: u32) ![]u8 {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(ssh_fxp_open);
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try putU32(&body.writer, pflags);
        try putU32(&body.writer, 0);
        try self.send(body.written());
        return self.expectHandle(id);
    }

    fn pathOp(self: *Client, kind: u8, path: []const u8) !void {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(kind);
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try self.send(body.written());
        try self.expectOk(id);
    }

    fn statPath(self: *Client, kind: u8, path: []const u8) !Attrs {
        const id = self.takeId();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        try body.writer.writeByte(kind);
        try putU32(&body.writer, id);
        try putString(&body.writer, path);
        try self.send(body.written());
        const response = try self.receive();
        defer self.alloc.free(response);
        if (isStatus(response, id)) return statusError(try statusCode(response, id));
        try expectType(response, id, ssh_fxp_attrs);
        var packet = PacketReader{ .data = response[5..] };
        return parseAttrs(&packet);
    }

    fn expectHandle(self: *Client, id: u32) ![]u8 {
        const response = try self.receive();
        defer self.alloc.free(response);
        if (isStatus(response, id)) return statusError(try statusCode(response, id));
        try expectType(response, id, ssh_fxp_handle);
        var packet = PacketReader{ .data = response[5..] };
        return self.alloc.dupe(u8, try packet.string());
    }

    fn expectOk(self: *Client, id: u32) !void {
        const response = try self.receive();
        defer self.alloc.free(response);
        const code = try statusCode(response, id);
        if (code != 0) return statusError(code);
    }

    fn send(self: *Client, body: []const u8) !void {
        try putU32(self.writer, @intCast(body.len));
        try self.writer.writeAll(body);
        try self.writer.flush();
    }

    fn receive(self: *Client) ![]u8 {
        var length_bytes: [4]u8 = undefined;
        try self.reader.readSliceAll(&length_bytes);
        const length = getU32(&length_bytes);
        if (length == 0 or length > max_packet_size) return error.InvalidSftpPacket;
        const packet = try self.alloc.alloc(u8, length);
        errdefer self.alloc.free(packet);
        try self.reader.readSliceAll(packet);
        return packet;
    }

    fn takeId(self: *Client) u32 {
        defer self.next_id +%= 1;
        return self.next_id;
    }
};

pub const NameIter = struct {
    reader: PacketReader,
    remaining: u32,

    pub fn init(payload: []const u8) !NameIter {
        var reader = PacketReader{ .data = payload };
        const count = try reader.get32();
        const leftover = reader.remaining();
        if (count > leftover / 12) return error.InvalidSftpPacket;
        return .{ .reader = reader, .remaining = count };
    }

    pub fn next(self: *NameIter) !?struct { name: []const u8, attrs: Attrs } {
        if (self.remaining == 0) {
            if (self.reader.remaining() != 0) return error.InvalidSftpPacket;
            return null;
        }
        self.remaining -= 1;
        const name = try self.reader.string();
        _ = try self.reader.string();
        const attrs = try parseAttrs(&self.reader);
        return .{ .name = name, .attrs = attrs };
    }
};

const PacketReader = struct {
    data: []const u8,
    offset: usize = 0,

    fn remaining(self: PacketReader) usize {
        return self.data.len - self.offset;
    }

    fn get32(self: *PacketReader) !u32 {
        if (self.remaining() < 4) return error.InvalidSftpPacket;
        const value = getU32(self.data[self.offset..][0..4]);
        self.offset += 4;
        return value;
    }

    fn get64(self: *PacketReader) !u64 {
        if (self.remaining() < 8) return error.InvalidSftpPacket;
        const value = std.mem.readInt(u64, self.data[self.offset..][0..8], .big);
        self.offset += 8;
        return value;
    }

    fn string(self: *PacketReader) ![]const u8 {
        const length = try self.get32();
        if (length > self.remaining()) return error.InvalidSftpPacket;
        defer self.offset += length;
        return self.data[self.offset..][0..length];
    }
};

fn encodeSymlinkRequest(writer: *std.Io.Writer, id: u32, target: []const u8, link_path: []const u8) !void {
    try writer.writeByte(ssh_fxp_symlink);
    try putU32(writer, id);
    try putString(writer, target);
    try putString(writer, link_path);
}

fn parseAttrs(packet: *PacketReader) !Attrs {
    const flags = try packet.get32();
    var attrs: Attrs = .{};
    if (flags & attr_size != 0) {
        attrs.size = try packet.get64();
    }
    if (flags & attr_uidgid != 0) {
        _ = try packet.get32();
        _ = try packet.get32();
    }
    if (flags & attr_permissions != 0) {
        const mode = try packet.get32();
        attrs.mode = mode;
        attrs.kind = kindFromMode(mode);
    }
    if (flags & attr_acmodtime != 0) {
        _ = try packet.get32();
        attrs.mtime = try packet.get32();
    }
    if (flags & attr_extended != 0) {
        const count = try packet.get32();

        if (count > packet.remaining() / 8) return error.InvalidSftpPacket;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            _ = try packet.string();
            _ = try packet.string();
        }
    }
    return attrs;
}

fn kindFromMode(mode: u32) Kind {
    return switch (mode & s_ifmt) {
        s_ifdir => .directory,
        s_ifreg => .file,
        s_iflnk => .symlink,
        else => .other,
    };
}

fn isStatus(response: []const u8, id: u32) bool {
    return response.len >= 5 and response[0] == ssh_fxp_status and getU32(response[1..5]) == id;
}

fn expectType(response: []const u8, id: u32, kind: u8) !void {
    if (response.len < 5 or response[0] != kind or getU32(response[1..5]) != id) {
        return error.InvalidSftpPacket;
    }
}

fn statusCode(response: []const u8, id: u32) !u32 {
    if (response.len < 9 or response[0] != ssh_fxp_status or getU32(response[1..5]) != id) {
        return error.InvalidSftpStatus;
    }
    return getU32(response[5..9]);
}

fn statusError(code: u32) error{ Eof, NotFound, PermissionDenied, Unsupported, Failure } {
    return switch (code) {
        1 => error.Eof,
        2 => error.NotFound,
        3 => error.PermissionDenied,
        8 => error.Unsupported,
        else => error.Failure,
    };
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

test "SFTP packet integer encoding" {
    var bytes: [12]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try putU32(&writer, 0x01020304);
    try putU64(&writer, 0x05060708090a0b0c);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, writer.buffered());
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

test "SFTP truncated attributes are rejected" {
    const testing = std.testing;
    var size_only = PacketReader{ .data = &.{ 0, 0, 0, 1 } };
    try testing.expectError(error.InvalidSftpPacket, parseAttrs(&size_only));

    var mode_only = PacketReader{ .data = &.{ 0, 0, 0, 4, 0, 0 } };
    try testing.expectError(error.InvalidSftpPacket, parseAttrs(&mode_only));

    var extended = PacketReader{ .data = &.{ 0x80, 0, 0, 0, 0, 0, 0, 2 } };
    try testing.expectError(error.InvalidSftpPacket, parseAttrs(&extended));
}

test "SFTP truncated NAME count is rejected" {
    const testing = std.testing;
    try testing.expectError(error.InvalidSftpPacket, NameIter.init(&.{ 0, 0, 0, 1 }));
    var iter = try NameIter.init(&.{ 0, 0, 0, 0 });
    try testing.expect(try iter.next() == null);
}

test "SFTP oversized DATA length is rejected" {
    var packet = PacketReader{ .data = &.{ 0, 0, 0, 8, 1, 2, 3 } };
    try std.testing.expectError(error.InvalidSftpPacket, packet.string());
}

test "SFTP OpenSSH sftp-server file operations" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const server = "/usr/libexec/sftp-server";
    std.Io.Dir.accessAbsolute(testing.io, server, .{}) catch return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const tmp_path = path_buf[0..n];

    const file_path = try std.fs.path.join(alloc, &.{ tmp_path, "payload.bin" });
    defer alloc.free(file_path);
    const link_path = try std.fs.path.join(alloc, &.{ tmp_path, "payload.link" });
    defer alloc.free(link_path);
    const nested = try std.fs.path.join(alloc, &.{ tmp_path, "nested" });
    defer alloc.free(nested);
    const empty_dir = try std.fs.path.join(alloc, &.{ tmp_path, "empty" });
    defer alloc.free(empty_dir);
    const renamed_dir = try std.fs.path.join(alloc, &.{ tmp_path, "renamed" });
    defer alloc.free(renamed_dir);

    var payload: [40 * 1024]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);
    {
        const file = try std.Io.Dir.createFileAbsolute(testing.io, file_path, .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, &payload);
    }

    var child = std.process.spawn(testing.io, .{
        .argv = &.{server},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer {
        if (child.stdin) |file| {
            file.close(testing.io);
            child.stdin = null;
        }
        _ = child.wait(testing.io) catch {};
    }

    var write_buffer: [64 * 1024]u8 = undefined;
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_writer = child.stdin.?.writer(testing.io, &write_buffer);
    var file_reader = child.stdout.?.reader(testing.io, &read_buffer);
    var client = Client{
        .alloc = alloc,
        .writer = &file_writer.interface,
        .reader = &file_reader.interface,
    };
    try client.handshake();

    try client.symlink("payload.bin", link_path);
    const got_link = try client.readLink(link_path);
    defer alloc.free(got_link);
    try testing.expectEqualStrings("payload.bin", got_link);

    const file_stat = try client.stat(file_path);
    try testing.expectEqual(Kind.file, file_stat.kind);
    try testing.expectEqual(@as(?u64, payload.len), file_stat.size);
    try testing.expect(file_stat.mtime != null);
    try testing.expect(file_stat.mode != null);

    const link_stat = try client.lstat(link_path);
    try testing.expectEqual(Kind.symlink, link_stat.kind);

    var saw_file = false;
    var saw_link = false;
    var saw_dot = false;
    const dir_handle = try client.openDir(tmp_path);
    defer alloc.free(dir_handle);
    while (try client.readdir(dir_handle)) |payload_names| {
        defer alloc.free(payload_names);
        var names = try NameIter.init(payload_names);
        while (try names.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                saw_dot = true;
                continue;
            }
            if (std.mem.eql(u8, entry.name, "payload.bin")) {
                saw_file = true;
                try testing.expectEqual(Kind.file, entry.attrs.kind);
                try testing.expectEqual(@as(?u64, payload.len), entry.attrs.size);
            } else if (std.mem.eql(u8, entry.name, "payload.link")) {
                saw_link = true;
                try testing.expectEqual(Kind.symlink, entry.attrs.kind);
            }
        }
    }
    try client.close(dir_handle);
    try testing.expect(saw_file);
    try testing.expect(saw_link);

    const read_handle = try client.openRead(file_path);
    defer alloc.free(read_handle);
    var downloaded: std.Io.Writer.Allocating = .init(alloc);
    defer downloaded.deinit();
    var offset: u64 = 0;
    while (try client.read(read_handle, offset, 32 * 1024)) |chunk| {
        defer alloc.free(chunk);
        try downloaded.writer.writeAll(chunk);
        offset += chunk.len;
    }
    try client.close(read_handle);
    try testing.expectEqualSlices(u8, &payload, downloaded.written());

    try client.mkdir(nested);
    try client.mkdir(empty_dir);
    try testing.expectError(error.Failure, client.mkdir(empty_dir));
    try client.rename(empty_dir, renamed_dir);
    try testing.expectError(error.Failure, client.rename(nested, renamed_dir));

    const nested_stat = try client.lstat(nested);
    try testing.expectEqual(Kind.directory, nested_stat.kind);

    try client.remove(file_path);
    try client.remove(link_path);
    try client.rmdir(renamed_dir);
    try testing.expectError(error.NotFound, client.lstat(file_path));
    try testing.expectError(error.NotFound, client.lstat(link_path));
    try testing.expectError(error.NotFound, client.lstat(renamed_dir));
    try client.rmdir(nested);
}
