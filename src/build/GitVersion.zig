const Version = @This();

const std = @import("std");

/// The short hash (7 characters) of the latest commit.
short_hash: []const u8,

/// True if there was a diff at build time.
changes: bool,

/// The tag -- if any -- that this commit is a part of.
tag: ?[]const u8,

/// The branch that was checked out at the time of the build.
branch: []const u8,

/// Initialize the version and detect it from the Git environment. This
/// allocates using the build allocator and doesn't free.
pub fn detect(b: *std.Build) !Version {
    // Execute a bunch of git commands to determine the automatic version.
    var code: u8 = 0;
    const branch: []const u8 = b: {
        const tmp: []u8 = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "rev-parse", "--abbrev-ref", "HEAD" },
            &code,
            .ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            error.ExitCodeFailure => return error.GitNotRepository,
            else => return err,
        };

        // Replace characters that are not valid in semantic version
        // pre-release identifiers (which only allow [0-9A-Za-z-]).
        // Slashes would also mess up dist tarball paths.
        for (tmp) |*c| {
            if (!std.ascii.isAlphanumeric(c.*) and c.* != '-') c.* = '-';
        }

        break :b tmp;
    };

    const short_hash = short_hash: {
        const output = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "-c", "log.showSignature=false", "log", "--pretty=format:%h", "-n", "1" },
            &code,
            .ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => return err,
        };

        break :short_hash std.mem.trimEnd(u8, output, "\r\n ");
    };

    const tag = b.runAllowFail(
        &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "describe", "--exact-match", "--tags" },
        &code,
        .ignore,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => "", // expected
        else => return err,
    };

    _ = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "diff",
        "--quiet",
        "--exit-code",
    }, &code, .ignore) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => {}, // expected
        else => return err,
    };
    const changes = code != 0;

    return .{
        .short_hash = short_hash,
        .changes = changes,
        .tag = if (tag.len > 0) std.mem.trimEnd(u8, tag, "\r\n ") else null,
        .branch = std.mem.trimEnd(u8, branch, "\r\n "),
    };
}

/// Parse a Niftty release tag in strict vX.Y.Z form.
///
/// Niftty release versions are independent of the inherited Ghostty version
/// in build.zig.zon, so the exact Git tag is the release version source.
pub fn parseReleaseTag(tag: []const u8) error{InvalidReleaseTag}!std.SemanticVersion {
    if (tag.len < 2 or tag[0] != 'v') return error.InvalidReleaseTag;

    const version = std.SemanticVersion.parse(tag[1..]) catch
        return error.InvalidReleaseTag;
    if (version.pre != null or version.build != null) {
        return error.InvalidReleaseTag;
    }

    return version;
}

test "parseReleaseTag accepts a stable Niftty release" {
    const expected = try std.SemanticVersion.parse("0.5.1");
    try std.testing.expectEqualDeep(expected, try parseReleaseTag("v0.5.1"));
}

test "parseReleaseTag rejects anything except stable vX.Y.Z" {
    const invalid_tags = [_][]const u8{
        "",
        "0.5.1",
        "v0.5",
        "v0.5.1-rc.1",
        "v0.5.1+build.1",
        "vv0.5.1",
    };

    inline for (invalid_tags) |tag| {
        try std.testing.expectError(error.InvalidReleaseTag, parseReleaseTag(tag));
    }
}
