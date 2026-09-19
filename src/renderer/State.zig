//! This is the render state that is given to a renderer.

const State = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");
const renderer = @import("../renderer.zig");

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Io.Mutex,

/// The terminal data.
terminal: *terminalpkg.Terminal,

/// The terminal inspector, if any. This will be null while the inspector
/// is not active and will be set when it is active.
inspector: ?*Inspector = null,

/// Dead key state. This will render the current dead key preedit text
/// over the cursor. This currently only ever renders a single codepoint.
/// Preedit can in theory be multiple codepoints long but that is left as
/// a future exercise.
preedit: ?Preedit = null,

/// The prediction candidate state. See Surface.predictionSubmit for more
/// information. This is render-owned state, mutated by the surface under
/// the state mutex, exactly like the preedit.
prediction: ?Prediction = null,

/// Mouse state. This only contains state relevant to what renderers
/// need about the mouse.
mouse: Mouse = .{},

/// The number of threads currently waiting to acquire `mutex` via
/// `lockDemand`. This is not protected by the mutex; it is read by
/// hot lock/unlock loops (the IO parse thread) in `yieldToDemand` to
/// decide whether to hand the mutex off before relocking it.
demand: std.atomic.Value(u32) = .init(0),

/// Handoff generation counter. Incremented (with a futex wake) by
/// `unlockDemand` after a demanding waiter releases the mutex, so that
/// `yieldToDemand` knows the waiter had its turn.
handoff_gen: std.atomic.Value(u32) = .init(0),

/// How long `yieldToDemand` sleeps waiting for a demanding waiter to
/// take its turn before giving up. This bounds how long the IO parse
/// thread can stall if a wake is lost or the waiter is descheduled; a
/// demanding critical section (the renderer's frame snapshot) is
/// microseconds, so one millisecond is generous.
const handoff_timeout_ns = 1 * std.time.ns_per_ms;

/// Acquire `mutex` while signaling demand for it. Use this instead of
/// locking the mutex directly on threads that must not be starved by
/// a hot lock/unlock loop (the renderer's frame snapshot). Must be
/// released with `unlockDemand`; releasing with `mutex.unlock` keeps
/// the data safe but makes parked `yieldToDemand` callers wait out
/// their full timeout.
///
/// Both `std.Thread.Mutex` and os_unfair_lock are unfair: a running
/// thread that unlocks and immediately relocks beats a sleeping
/// waiter every time, because the waiter must first be woken and
/// scheduled. Under sustained pty output the IO parse thread is
/// exactly such a loop, so without this signal the renderer can
/// starve for as long as the output lasts.
pub fn lockDemand(self: *State, io: std.Io) void {
    _ = self.demand.fetchAdd(1, .monotonic);
    self.mutex.lockUncancelable(io);
    const prev = self.demand.fetchSub(1, .monotonic);
    assert(prev > 0);
}

/// Release `mutex` acquired via `lockDemand` and notify hot loops
/// parked in `yieldToDemand` that the demanding waiter had its turn.
pub fn unlockDemand(self: *State, io: std.Io) void {
    self.mutex.unlock(io);
    _ = self.handoff_gen.fetchAdd(1, .monotonic);
    io.futexWake(@TypeOf(self.handoff_gen), &self.handoff_gen, 1);
}

/// Called by hot lock/unlock loops between critical sections, with
/// `mutex` NOT held: if a `lockDemand` waiter exists, sleep until it
/// has acquired and released the mutex (or the timeout passes). This
/// is the handoff that unfair mutexes never do on their own.
///
/// The orderings here are all monotonic because these atomics are a
/// scheduling heuristic, not a synchronization boundary: the mutex
/// itself orders the protected data, and the timeout bounds any
/// staleness.
pub fn yieldToDemand(self: *State, io: std.Io) void {
    if (self.demand.load(.monotonic) == 0) return;

    // Snapshot the generation before rechecking demand: if the waiter
    // acquires and releases between our check and the wait below, the
    // generation no longer matches and timedWait returns immediately.
    const gen = self.handoff_gen.load(.monotonic);
    if (self.demand.load(.monotonic) == 0) return;
    io.futexWaitTimeout(
        @TypeOf(self.handoff_gen),
        &self.handoff_gen,
        .init(gen),
        .{ .duration = .{ .raw = .fromNanoseconds(handoff_timeout_ns), .clock = .awake } },
    ) catch {};
}

pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminalpkg.point.Coordinate = null,

    /// The mods that are currently active for the last mouse event.
    /// This could really just be mods in general and we probably will
    /// move it out of mouse state at some point.
    mods: inputpkg.Mods = .{},
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// Deinit this preedit that was cre
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator..
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    /// Range returns the start and end x position of the preedit text
    /// along with any codepoint offset necessary to fit the preedit
    /// into the available space.
    pub fn range(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) struct {
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        cp_offset: usize,
    } {
        // If our width is greater than the number of cells we have
        // then we need to adjust our codepoint start to a point where
        // our width would be less than the number of cells we have.
        const w, const cp_offset = width: {
            // max is inclusive, so we need to add 1 to it.
            const max_width = max - start + 1;

            // Rebuild our width in reverse order. This is because we want
            // to offset by the end cells, not the start cells (if we have to).
            var w: terminalpkg.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }

            // Width fit in the max width so no offset necessary.
            break :width .{ w, 0 };
        };

        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};

/// The prediction candidate for the surface. This is the render-owned
/// data for Niftty's inline prediction layer: a candidate supplied by
/// the embedding application that is rendered as faint ghost text at
/// the cursor while the shell sits at a prompt. The text is the
/// remaining suffix of the predicted line when the user has already
/// typed a prefix. See Surface.predictionSubmit for the submission and
/// validation flow.
pub const Prediction = struct {
    /// The maximum length in bytes of the candidate insertion text.
    pub const max_text_len = 4096;

    /// The maximum length in bytes of the candidate ID.
    pub const max_id_len = 255;

    /// The prediction context revision this candidate was submitted for.
    /// Any event that invalidates the prediction context increments the
    /// surface's revision, making a candidate with an older revision
    /// stale: it can no longer be accepted.
    revision: u64,

    /// The candidate ID copied from the submission. Used to key terminal
    /// outcomes reported back to the embedding application.
    id: []const u8 = &.{},

    /// The insertion text copied from the submission. This is exactly the
    /// bytes that are written to the pty when the candidate is accepted,
    /// never anything more (no Enter is synthesized).
    text: []const u8 = &.{},

    /// The renderable view of the insertion text: codepoints with their
    /// resolved cell widths, computed once at submission time. Zero-width
    /// codepoints are dropped from the render view (they are still part of
    /// the inserted text).
    codepoints: []const Codepoint = &.{},

    /// A single codepoint to render as ghost text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    pub const ValidationError = error{
        Empty,
        TooLong,
        InvalidUtf8,
        ControlCharacter,
    };

    /// Validate candidate insertion text. The text must be non-empty,
    /// valid UTF-8, no longer than `max_text_len` bytes, and contain no
    /// C0 or C1 control codepoints (nor DEL). This is what keeps the
    /// candidate plain insertion text rather than an executable command:
    /// tabs, newlines, carriage returns, escapes, and NULs are all
    /// rejected.
    pub fn validateText(text: []const u8) ValidationError!void {
        if (text.len == 0) return error.Empty;
        if (text.len > max_text_len) return error.TooLong;

        const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp <= 0x1F) return error.ControlCharacter; // C0
            if (cp >= 0x7F and cp <= 0x9F) return error.ControlCharacter; // DEL, C1
        }
    }
    /// Build an owned candidate. The ID must be non-empty and no longer
    /// than `max_id_len` bytes; the text must pass `validateText`. The
    /// renderable codepoint view is resolved here, once, using the same
    /// width rules as the preedit.
    pub fn init(
        alloc: Allocator,
        id: []const u8,
        revision: u64,
        text: []const u8,
    ) (ValidationError || Allocator.Error)!Prediction {
        if (id.len == 0) return error.Empty;
        if (id.len > max_id_len) return error.TooLong;
        try validateText(text);

        const id_dup = try alloc.dupe(u8, id);
        errdefer alloc.free(id_dup);
        const text_dup = try alloc.dupe(u8, text);
        errdefer alloc.free(text_dup);

        var codepoints: std.ArrayListUnmanaged(Codepoint) = .empty;
        errdefer codepoints.deinit(alloc);

        const unicode = @import("../unicode/main.zig");
        const view = std.unicode.Utf8View.init(text) catch unreachable;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            // Match the preedit behavior: zero-width codepoints have no
            // cell to draw in so they are skipped in the render view.
            const width: usize = @intCast(unicode.table.get(cp).width);
            if (width == 0) continue;

            try codepoints.append(alloc, .{
                .codepoint = cp,
                .wide = width >= 2,
            });
        }

        return .{
            .revision = revision,
            .id = id_dup,
            .text = text_dup,
            .codepoints = try codepoints.toOwnedSlice(alloc),
        };
    }

    /// Free the memory of this candidate.
    pub fn deinit(self: *const Prediction, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.text);
        alloc.free(self.codepoints);
    }

    /// Clone only the codepoint view for rendering into a per-frame
    /// arena. The rest of the candidate stays render-owned.
    pub fn cloneView(
        self: *const Prediction,
        alloc: Allocator,
    ) Allocator.Error![]const Codepoint {
        return alloc.dupe(Codepoint, self.codepoints);
    }

    /// A cell position within the viewport grid.
    pub const Position = struct { x: usize, y: usize };

    /// The result of advancing a ghost text cursor by one codepoint.
    pub const Advance = union(enum) {
        /// The position the codepoint starts at. A wide codepoint
        /// occupies this cell and the one to its right.
        cell: Position,

        /// The codepoint does not fit on the grid and is clipped.
        clipped,
    };

    /// Place the next codepoint given the current running position and
    /// its width, wrapping at the right grid edge and clipping at the
    /// bottom of the viewport. A wide codepoint that does not fit in the
    /// remaining columns of its row wraps to the next row whole, matching
    /// terminal soft-wrap behavior. Returns the cell the codepoint starts
    /// at and the next running position.
    pub fn placeNext(
        pos: Position,
        wide: bool,
        cols: usize,
        rows: usize,
    ) struct { advance: Advance, next: Position } {
        var p = pos;

        // A wide codepoint needs two cells. If it can't fit on this row
        // it wraps to the start of the next row whole; if the grid is
        // itself too narrow to ever fit it, it is clipped.
        if (wide) {
            if (cols < 2) return .{ .advance = .clipped, .next = pos };
            if (p.x + 1 >= cols) p = .{ .x = 0, .y = p.y + 1 };
        }

        if (p.y >= rows or p.x >= cols) return .{
            .advance = .clipped,
            .next = p,
        };

        const cell: Position = p;
        p.x += if (wide) 2 else 1;
        if (p.x >= cols) {
            p = .{ .x = 0, .y = p.y + 1 };
        }

        return .{ .advance = .{ .cell = cell }, .next = p };
    }
};

test "prediction validateText accepts plain and unicode text" {
    try Prediction.validateText("git status");
    try Prediction.validateText("echo 'hi; there' \"friend\"");
    try Prediction.validateText("echo \u{e9}\u{1F600}");
    try Prediction.validateText("x" ** Prediction.max_text_len);
}

test "prediction validateText rejects bad candidates" {
    const testing = std.testing;

    try testing.expectError(error.Empty, Prediction.validateText(""));
    try testing.expectError(error.TooLong, Prediction.validateText("x" ** (Prediction.max_text_len + 1)));
    try testing.expectError(error.InvalidUtf8, Prediction.validateText("\xff\xfe"));

    // C0 controls, including the ones called out by the plan.
    for ([_]u8{ 0x00, 0x09, 0x0A, 0x0D, 0x1B }) |b| {
        try testing.expectError(
            error.ControlCharacter,
            Prediction.validateText(&.{ 'a', b, 'b' }),
        );
    }

    // DEL and C1 controls must be encoded as UTF-8 codepoints.
    try testing.expectError(error.ControlCharacter, Prediction.validateText("\u{7F}"));
    try testing.expectError(error.ControlCharacter, Prediction.validateText("\u{85}"));
    try testing.expectError(error.ControlCharacter, Prediction.validateText("\u{9F}"));
}

test "prediction init builds owned candidate" {
    const testing = std.testing;

    var candidate = try Prediction.init(
        testing.allocator,
        "provider-1",
        7,
        "echo h\u{e9}",
    );
    defer candidate.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 7), candidate.revision);
    try testing.expectEqualStrings("provider-1", candidate.id);
    try testing.expectEqualStrings("echo h\u{e9}", candidate.text);
    try testing.expectEqual(@as(usize, 7), candidate.codepoints.len);

    try testing.expectError(error.Empty, Prediction.init(
        testing.allocator,
        "",
        1,
        "x",
    ));
    try testing.expectError(error.TooLong, Prediction.init(
        testing.allocator,
        "x" ** (Prediction.max_id_len + 1),
        1,
        "x",
    ));
}

test "prediction placeNext wraps at right edge and clips at bottom" {
    const testing = std.testing;

    // Narrow text wraps after the last column.
    {
        const r = Prediction.placeNext(.{ .x = 3, .y = 0 }, false, 4, 10);
        try testing.expectEqual(@as(usize, 3), r.advance.cell.x);
        try testing.expectEqual(@as(usize, 0), r.advance.cell.y);
        try testing.expectEqual(@as(usize, 0), r.next.x);
        try testing.expectEqual(@as(usize, 1), r.next.y);
    }

    // Wide codepoint at the last column wraps whole to the next row.
    {
        const r = Prediction.placeNext(.{ .x = 3, .y = 0 }, true, 4, 10);
        try testing.expectEqual(@as(usize, 0), r.advance.cell.x);
        try testing.expectEqual(@as(usize, 1), r.advance.cell.y);
        try testing.expectEqual(@as(usize, 2), r.next.x);
        try testing.expectEqual(@as(usize, 1), r.next.y);
    }

    // Wide codepoint fits with two remaining columns.
    {
        const r = Prediction.placeNext(.{ .x = 2, .y = 0 }, true, 4, 10);
        try testing.expectEqual(@as(usize, 2), r.advance.cell.x);
        try testing.expectEqual(@as(usize, 0), r.advance.cell.y);
    }

    // Clipped once past the bottom row.
    {
        const r = Prediction.placeNext(.{ .x = 0, .y = 10 }, false, 4, 10);
        try testing.expect(r.advance == .clipped);
    }

    // Wide codepoint on a degenerate single-column grid is clipped rather
    // than looping forever.
    {
        const r = Prediction.placeNext(.{ .x = 0, .y = 0 }, true, 1, 10);
        try testing.expect(r.advance == .clipped);
    }
}

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

test "preedit range covers exact cell width" {
    const testing = std.testing;

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}

test "preedit range shifts left at right edge" {
    const testing = std.testing;

    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
}
