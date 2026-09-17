const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const DetectError = error{
    /// Multiple actions were detected. You can specify at most one
    /// action on the CLI otherwise the behavior desired is ambiguous.
    MultipleActions,

    /// An unknown action was specified.
    InvalidAction,
};

/// Detect the action from CLI args.
pub fn detectArgs(comptime E: type, alloc: Allocator, args: std.process.Args) !?E {
    var iter = try args.iterateAllocator(alloc);
    defer iter.deinit();
    return try detectIter(E, &iter);
}

/// Detect the action from any iterator. Each iterator value should yield
/// a CLI argument such as "--foo".
///
/// The comptime type E must be an enum with the available actions.
/// If the type E has a decl `detectSpecialCase`, then it will be called
/// for each argument to allow handling of special cases. The function
/// signature for `detectSpecialCase` should be:
///
///   fn detectSpecialCase(arg: []const u8) ?SpecialCase(E)
///
pub fn detectIter(
    comptime E: type,
    iter: anytype,
) DetectError!?E {
    var fallback: ?E = null;
    var pending: ?E = null;
    while (iter.next()) |arg| {
        // Allow handling of special cases.
        if (@hasDecl(E, "detectSpecialCase")) special: {
            const special = E.detectSpecialCase(arg) orelse break :special;
            switch (special) {
                .action => |a| return a,
                .fallback => |a| fallback = a,
                .abort_if_no_action => if (pending == null) return null,
            }
        }

        // Commands must start with "+"
        if (arg.len == 0 or arg[0] != '+') continue;
        if (pending != null) return DetectError.MultipleActions;
        pending = std.meta.stringToEnum(E, arg[1..]) orelse
            return DetectError.InvalidAction;
    }

    // If we have an action, we always return that action, even if we've
    // seen "--help" or "-h" because the action may have its own help text.
    if (pending != null) return pending;

    // If we have no action but we have a fallback, then we return that.
    if (fallback) |a| return a;

    return null;
}

/// The action enum E can implement the decl `detectSpecialCase` to
/// return this enum in order to perform various special case actions.
pub fn SpecialCase(comptime E: type) type {
    return union(enum) {
        /// Immediately return this action.
        action: E,

        /// Return this action if no other action is found.
        fallback: E,

        /// If there is no pending action (we haven't seen an action yet)
        /// then we should return no action. This is kind of weird but is
        /// a special case to allow "-e" in Ghostty.
        abort_if_no_action,
    };
}

/// Promote the bare command alias `niftty <command>` to the canonical
/// `niftty +<command>` form so that all downstream parsing (action
/// detection, per-action option parsing) sees one shape.
///
/// Only the first argument is considered, and only if it is a bare word
/// that exactly names an action. Anything else — flags, config files,
/// `-e`, an explicit `+action` — is returned unchanged so existing
/// semantics are preserved.
///
/// The returned `Args` references memory allocated from `alloc` that is
/// intentionally leaked: process args live for the lifetime of the
/// process.
pub fn promoteBareCommand(
    comptime E: type,
    alloc: Allocator,
    args: std.process.Args,
) Allocator.Error!std.process.Args {
    switch (builtin.os.tag) {
        // Unsupported vector shapes: Windows is WTF-16 encoded, WASI
        // without libc has no vector, freestanding has no args.
        .windows, .freestanding => return args,
        .wasi => if (!builtin.link_libc) return args,
        else => {},
    }

    if (args.vector.len < 2) return args;
    const first = std.mem.span(args.vector[1]);

    // Only a bare word (no leading dash or plus) can be promoted.
    if (first.len == 0 or first[0] == '-' or first[0] == '+') return args;

    // Only a bare word that names an action is promoted; anything else
    // (e.g. a config file path) keeps its existing meaning.
    if (std.meta.stringToEnum(E, first) == null) return args;

    const plus = try std.fmt.allocPrintSentinel(alloc, "+{s}", .{first}, 0);
    const copy = try alloc.dupe([*:0]const u8, args.vector);
    copy[1] = plus.ptr;
    return .{ .vector = copy };
}

test "promoteBareCommand promotes bare action" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Enum = enum { foo, bar };
    const args: std.process.Args = .{ .vector = &.{ "prog", "foo", "--a=1" } };

    const promoted = try promoteBareCommand(Enum, arena.allocator(), args);
    try testing.expectEqual(@as(usize, 3), promoted.vector.len);
    try testing.expectEqualStrings("+foo", std.mem.span(promoted.vector[1]));
    try testing.expectEqual(args.vector[0], promoted.vector[0]);
    try testing.expectEqual(args.vector[2], promoted.vector[2]);
}

test "promoteBareCommand leaves non-bare args unchanged" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Enum = enum { foo, bar };

    // Explicit action.
    {
        const args: std.process.Args = .{ .vector = &.{ "prog", "+foo" } };
        const result = try promoteBareCommand(Enum, arena.allocator(), args);
        try testing.expectEqual(args.vector, result.vector);
    }

    // Flags first.
    {
        const args: std.process.Args = .{ .vector = &.{ "prog", "-e", "foo" } };
        const result = try promoteBareCommand(Enum, arena.allocator(), args);
        try testing.expectEqual(args.vector, result.vector);
    }

    // Unknown word (e.g. a config file).
    {
        const args: std.process.Args = .{ .vector = &.{ "prog", "config" } };
        const result = try promoteBareCommand(Enum, arena.allocator(), args);
        try testing.expectEqual(args.vector, result.vector);
    }

    // No args beyond argv0.
    {
        const args: std.process.Args = .{ .vector = &.{"prog"} };
        const result = try promoteBareCommand(Enum, arena.allocator(), args);
        try testing.expectEqual(args.vector, result.vector);
    }
}

test "detect direct match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum { foo, bar, baz };

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "+foo",
    );
    defer iter.deinit();
    const result = try detectIter(Enum, &iter);
    try testing.expectEqual(Enum.foo, result.?);
}

test "detect invalid match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum { foo, bar, baz };

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "+invalid",
    );
    defer iter.deinit();
    try testing.expectError(
        DetectError.InvalidAction,
        detectIter(Enum, &iter),
    );
}

test "detect multiple actions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum { foo, bar, baz };

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "+foo +bar",
    );
    defer iter.deinit();
    try testing.expectError(
        DetectError.MultipleActions,
        detectIter(Enum, &iter),
    );
}

test "detect no match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum { foo, bar, baz };

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "--some-flag",
    );
    defer iter.deinit();
    const result = try detectIter(Enum, &iter);
    try testing.expect(result == null);
}

test "detect special case action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,

        fn detectSpecialCase(arg: []const u8) ?SpecialCase(@This()) {
            return if (std.mem.eql(u8, arg, "--special"))
                .{ .action = .foo }
            else
                null;
        }
    };

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special +bar",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.foo, result.?);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar --special",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.foo, result.?);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.bar, result.?);
    }
}

test "detect special case fallback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,

        fn detectSpecialCase(arg: []const u8) ?SpecialCase(@This()) {
            return if (std.mem.eql(u8, arg, "--special"))
                .{ .fallback = .foo }
            else
                null;
        }
    };

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.foo, result.?);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar --special",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.bar, result.?);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special +bar",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.bar, result.?);
    }
}

test "detect special case abort_if_no_action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,

        fn detectSpecialCase(arg: []const u8) ?SpecialCase(@This()) {
            return if (std.mem.eql(u8, arg, "-e"))
                .abort_if_no_action
            else
                null;
        }
    };

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "-e",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expect(result == null);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+foo -e",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.foo, result.?);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "-e +bar",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expect(result == null);
    }
}
