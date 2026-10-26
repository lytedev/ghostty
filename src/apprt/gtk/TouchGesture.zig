const TouchGesture = @This();
const std = @import("std");

pub const hold_milliseconds = 500;
pub const movement_threshold = 8;

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
origin: Point = .{ .x = 0, .y = 0 },
position: Point = .{ .x = 0, .y = 0 },

pub fn begin(self: *TouchGesture, position: Point) void {
    self.* = .{ .phase = .pending, .origin = position, .position = position };
}

pub fn update(self: *TouchGesture, position: Point) Action {
    const previous = self.position;
    self.position = position;
    switch (self.phase) {
        .idle => return .none,
        .pending => {
            const horizontal_distance = position.x - self.origin.x;
            const vertical_distance = position.y - self.origin.y;
            if (horizontal_distance * horizontal_distance + vertical_distance * vertical_distance <
                movement_threshold * movement_threshold) return .none;
            self.phase = .scrolling;
            return .{ .scroll = .{ .x = horizontal_distance, .y = vertical_distance } };
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
    gesture.begin(.{ .x = 40, .y = 80 });
    try expectContract(Finish{ .tap = .{ .x = 40, .y = 80 } }, gesture.finish(), "A short touch must click its own coordinates rather than the physical mouse position.");
    try expectContract(Finish.none, gesture.finish(), "Finishing the same touch twice must not emit a second click.");
}

test "small finger jitter preserves the tap and uses the release position" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 });
    try expectContract(Action.none, gesture.update(.{ .x = 42, .y = 83 }), "Movement below the threshold must not scroll or select.");
    try expectContract(Finish{ .tap = .{ .x = 42, .y = 83 } }, gesture.finish(), "A tap with minor jitter must click at the final touch position.");
}

test "movement at the threshold scrolls without sending a button press or release" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 });
    try expectContract(Action{ .scroll = .{ .x = 0, .y = -8 } }, gesture.update(.{ .x = 40, .y = 72 }), "The first threshold-crossing motion must include all accumulated movement as scrolling.");
    try expectContract(Action{ .scroll = .{ .x = 0, .y = -12 } }, gesture.update(.{ .x = 40, .y = 60 }), "Later scroll updates must contain only the movement since the previous update.");
    try expectContract(Finish.none, gesture.finish(), "Releasing after scrolling must not click or release an unpressed selection button.");
}

test "a scrolling touch cannot turn into selection when the hold timer fires" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 });
    _ = gesture.update(.{ .x = 40, .y = 60 });
    try expectContract(@as(?Point, null), gesture.hold(), "Once movement commits to scrolling, a late hold timer must not begin selection.");
}

test "holding before dragging selects from the original position and never scrolls" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 });
    _ = gesture.update(.{ .x = 42, .y = 83 });
    try expectContract(@as(?Point, .{ .x = 40, .y = 80 }), gesture.hold(), "A hold must anchor selection at the original touch position despite minor finger jitter.");
    try expectContract(Action{ .select = .{ .x = 100, .y = 140 } }, gesture.update(.{ .x = 100, .y = 140 }), "Moving after a hold must extend selection rather than scroll.");
    try expectContract(Finish{ .release_selection = .{ .x = 100, .y = 140 } }, gesture.finish(), "Lifting after selection must release the button at the final selection position.");
}

test "cancelling a pending touch does not click" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 });
    try expectContract(Finish.none, gesture.cancel(), "A cancelled touch must never be interpreted as a tap.");
    try expectContract(@as(?Point, null), gesture.hold(), "A late timer after cancellation must not start selection.");
}

test "cancelling a selection releases exactly once and resets the next touch" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 });
    _ = gesture.hold();
    try expectContract(Finish{ .release_selection = .{ .x = 40, .y = 80 } }, gesture.cancel(), "Cancelling selection must release its synthetic left button.");
    try expectContract(Finish.none, gesture.cancel(), "Repeated cancellation must not release the selection twice.");
    gesture.begin(.{ .x = 10, .y = 20 });
    try expectContract(Finish{ .tap = .{ .x = 10, .y = 20 } }, gesture.finish(), "After cancellation the next short touch must behave as a fresh tap.");
}

test "a completed hold cannot start another selection from a late timeout" {
    var gesture: TouchGesture = .{};
    gesture.begin(.{ .x = 40, .y = 80 });
    _ = gesture.hold();
    try expectContract(@as(?Point, null), gesture.hold(), "The hold callback must start selection only once per touch.");
    _ = gesture.finish();
    try expectContract(@as(?Point, null), gesture.hold(), "A timer firing after release must not restart selection.");
}
