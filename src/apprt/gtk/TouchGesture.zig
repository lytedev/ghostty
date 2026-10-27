const TouchGesture = @This();
const std = @import("std");

/// Defaults matching the compiled-in GTK defaults for `gtk-long-press-time`
/// and `gtk-dnd-drag-threshold`, which is what a touch on a terminal should
/// feel like when the user has not overridden the settings. Cited here because
/// these are external constraints on the timing rather than decisions this
/// gesture makes:
/// https://gitlab.gnome.org/GNOME/gtk/-/blob/4.22.4/gtk/gtksettings.c#L940
/// https://gitlab.gnome.org/GNOME/gtk/-/blob/4.22.4/gtk/gtksettings.c#L427
pub const default_hold_milliseconds: c_uint = 500;
pub const default_movement_threshold_pixels: c_uint = 8;

/// Limits read from GtkSettings at touch begin so that accessibility
/// adjustments to the platform long-press delay and drag threshold apply.
pub const Limits = struct {
    hold_milliseconds: c_uint = default_hold_milliseconds,
    movement_threshold_pixels: c_uint = default_movement_threshold_pixels,
};

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const Phase = enum { idle, pending, scrolling, selecting };
pub const Action = union(enum) {
    none,
    scroll: Point,
    select: Point,
};
pub const Finish = union(enum) {
    none,
    tap: Point,
    release_selection: Point,
};

phase: Phase = .idle,
limits: Limits = .{},
origin: Point = .{ .x = 0, .y = 0 },
position: Point = .{ .x = 0, .y = 0 },

pub fn begin(self: *TouchGesture, position: Point, limits: Limits) void {
    self.* = .{ .phase = .pending, .limits = limits, .origin = position, .position = position };
}

/// True once either axis has moved further than the threshold, using the same
/// per-axis rule as GTK's `gtk_drag_check_threshold_double`
/// (https://gitlab.gnome.org/GNOME/gtk/-/blob/4.22.4/gtk/gtkdragsource.c#L832)
/// so a touch commits to scrolling exactly where a GTK text view would start a
/// drag. Diagonal motion must not be excused by a combined distance.
fn movedPastMovementThreshold(self: *TouchGesture) bool {
    const horizontal_pixels = @abs(self.position.x - self.origin.x);
    const vertical_pixels = @abs(self.position.y - self.origin.y);
    const threshold: f64 = @floatFromInt(self.limits.movement_threshold_pixels);
    return horizontal_pixels > threshold or vertical_pixels > threshold;
}

pub fn update(self: *TouchGesture, position: Point) Action {
    const previous = self.position;
    self.position = position;
    switch (self.phase) {
        .idle => return .none,
        .pending => {
            if (!self.movedPastMovementThreshold()) return .none;
            self.phase = .scrolling;
            return .{ .scroll = .{
                .x = position.x - self.origin.x,
                .y = position.y - self.origin.y,
            } };
        },
        .scrolling => return .{ .scroll = .{
            .x = position.x - previous.x,
            .y = position.y - previous.y,
        } },
        .selecting => return .{ .select = position },
    }
}

pub fn hold(self: *TouchGesture) ?Point {
    if (self.phase != .pending) return null;
    self.phase = .selecting;
    return self.origin;
}

pub fn finish(self: *TouchGesture) Finish {
    defer self.phase = .idle;
    return switch (self.phase) {
        .idle, .scrolling => .none,
        .pending => .{ .tap = self.position },
        .selecting => .{ .release_selection = self.position },
    };
}

pub fn cancel(self: *TouchGesture) Finish {
    defer self.phase = .idle;
    return switch (self.phase) {
        .selecting => .{ .release_selection = self.position },
        .idle, .pending, .scrolling => .none,
    };
}

fn expectContract(expected: anytype, actual: @TypeOf(expected), contract: []const u8) !void {
    std.testing.expectEqualDeep(expected, actual) catch |err| {
        std.log.err("{s} Expected {any}, but received {any}.", .{ contract, expected, actual });
        return err;
    };
}

test "a short stationary touch produces exactly one tap at the touched position" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    try expectContract(Finish{ .tap = .{ .x = 40, .y = 80 } }, gesture.finish(), "A short touch must click its own coordinates rather than the physical mouse position.");
    try expectContract(Finish.none, gesture.finish(), "Finishing the same touch twice must not emit a second click.");
}

test "small finger jitter preserves the tap and uses the release position" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    try expectContract(Action.none, gesture.update(.{ .x = 42, .y = 83 }), "Movement below the threshold must not scroll or select.");
    try expectContract(Finish{ .tap = .{ .x = 42, .y = 83 } }, gesture.finish(), "A tap with minor jitter must click at the final touch position.");
}

test "movement past the threshold scrolls without sending a button press or release" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    try expectContract(Action{ .scroll = .{ .x = 0, .y = -9 } }, gesture.update(.{ .x = 40, .y = 71 }), "Movement one pixel past the threshold must include all accumulated movement as scrolling.");
    try expectContract(Action{ .scroll = .{ .x = 0, .y = -11 } }, gesture.update(.{ .x = 40, .y = 60 }), "Later scroll updates must contain only the movement since the previous update.");
    try expectContract(Finish.none, gesture.finish(), "Releasing after scrolling must not click or release an unpressed selection button.");
}

test "movement of exactly the threshold stays pending because GTK requires exceeding it" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    try expectContract(Action.none, gesture.update(.{ .x = 40, .y = 72 }), "GTK's long-press gesture cancels its hold at more than the threshold, so exactly 8 px of jitter must remain a tap.");
    try expectContract(Finish{ .tap = .{ .x = 40, .y = 72 } }, gesture.finish(), "Jitter that merely reaches the threshold must still tap.");
}

test "diagonal movement is judged per axis rather than by combined distance" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    try expectContract(Action.none, gesture.update(.{ .x = 48, .y = 72 }), "8 px on each axis totals 11.3 px diagonally, but GTK compares axes separately, so this must remain a tap rather than scroll.");
    try expectContract(Action{ .scroll = .{ .x = 9, .y = -12 } }, gesture.update(.{ .x = 49, .y = 68 }), "Once an axis exceeds the threshold the accumulated movement on both axes must scroll.");
}

test "accessibility overrides of the GTK timing apply to this touch" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{ .hold_milliseconds = 1_200, .movement_threshold_pixels = 20 });
    try expectContract(@as(c_uint, 1_200), gesture.limits.hold_milliseconds, "The hold timer must be armed with the user's gtk-long-press-time rather than the GTK default.");
    try expectContract(Action.none, gesture.update(.{ .x = 49, .y = 71 }), "Movement that would scroll at the default threshold must stay pending at the user's larger 20 px threshold.");
    try expectContract(Action{ .scroll = .{ .x = 21, .y = 0 } }, gesture.update(.{ .x = 61, .y = 80 }), "Movement past the user's 20 px threshold must scroll.");
}

test "a scrolling touch cannot turn into selection when the hold timer fires" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    _ = gesture.update(.{ .x = 40, .y = 60 });
    try expectContract(@as(?Point, null), gesture.hold(), "Once movement commits to scrolling, a late hold timer must not begin selection.");
}

test "holding before dragging selects from the original position and never scrolls" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    _ = gesture.update(.{ .x = 42, .y = 83 });
    try expectContract(@as(?Point, .{ .x = 40, .y = 80 }), gesture.hold(), "A hold must anchor selection at the original touch position despite minor finger jitter.");
    try expectContract(Action{ .select = .{ .x = 100, .y = 140 } }, gesture.update(.{ .x = 100, .y = 140 }), "Moving after a hold must extend selection rather than scroll.");
    try expectContract(Finish{ .release_selection = .{ .x = 100, .y = 140 } }, gesture.finish(), "Lifting after selection must release the button at the final selection position.");
}

test "cancelling a pending touch does not click" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    try expectContract(Finish.none, gesture.cancel(), "A cancelled touch must never be interpreted as a tap.");
    try expectContract(@as(?Point, null), gesture.hold(), "A late timer after cancellation must not start selection.");
}

test "cancelling a selection releases exactly once and resets the next touch" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    _ = gesture.hold();
    try expectContract(Finish{ .release_selection = .{ .x = 40, .y = 80 } }, gesture.cancel(), "Cancelling selection must release its synthetic left button.");
    try expectContract(Finish.none, gesture.cancel(), "Repeated cancellation must not release the selection twice.");
    gesture.begin(.{ .x = 10, .y = 20 }, .{});
    try expectContract(Finish{ .tap = .{ .x = 10, .y = 20 } }, gesture.finish(), "After cancellation the next short touch must behave as a fresh tap.");
}

test "a completed hold cannot start another selection from a late timeout" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 }, .{});
    _ = gesture.hold();
    try expectContract(@as(?Point, null), gesture.hold(), "The hold callback must start selection only once per touch.");
    _ = gesture.finish();
    try expectContract(@as(?Point, null), gesture.hold(), "A timer firing after release must not restart selection.");
}
