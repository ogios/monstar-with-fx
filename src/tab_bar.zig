//! Geometry, colors, and timing for the tab strip.

const std = @import("std");
const RGB = @import("ghostty-vt").color.RGB;

pub const Colors = struct {
    background: RGB = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
    active_background: RGB = .{ .r = 0xcb, .g = 0xa6, .b = 0xf7 },
    active_title: RGB = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
    inactive_title: RGB = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4 },
    active_index: RGB = .{ .r = 0x58, .g = 0x5b, .b = 0x70 },
    inactive_index: RGB = .{ .r = 0x93, .g = 0x99, .b = 0xb2 },
};

pub fn inset(cell_height: u31) u31 {
    return @intCast((@as(u64, cell_height) * 12 + 26) / 53);
}

pub fn stripHeight(cell_height: u31) u31 {
    return cell_height +| (2 * inset(cell_height));
}

/// Corner inset at a subpixel distance from the horizontal edge. Both axes
/// scale with the label row, with a short straight edge between the corners.
pub fn cornerInset(width: u31, height: u31, distance: f64) f64 {
    const h: f64 = @floatFromInt(height);
    const radius_x = @min(h * (24.8 / 53.0), @as(f64, @floatFromInt(width)) / 2);
    const radius_y = h * (23.1 / 53.0);
    const u = 1 - @sqrt(std.math.clamp(distance / radius_y, 0, 1));
    return radius_x * std.math.pow(f64, u, 2.14);
}

/// Horizontal edges in physical pixels relative to the tab strip.
pub const Highlight = struct {
    left: u31,
    right: u31,

    fn collapsed(self: Highlight) Highlight {
        return .{ .left = self.left, .right = self.left };
    }

    fn sample(from: Highlight, to: Highlight, weight: f64) Highlight {
        return .{
            .left = interpolate(to.left, from.left, weight),
            .right = interpolate(to.right, from.right, weight),
        };
    }
};

const duration = 180 * std.time.ns_per_ms;

fn remaining(start: u64, now: u64) f64 {
    const elapsed = @min(duration, now -| start);
    const fraction = 1 - @as(f64, @floatFromInt(elapsed)) / duration;
    return fraction * fraction * fraction;
}

fn interpolate(target: u31, from: u31, weight: f64) u31 {
    return @intFromFloat(@round(std.math.lerp(@as(f64, @floatFromInt(target)), @as(f64, @floatFromInt(from)), weight)));
}

pub const Label = struct {
    id: u64,
    index: usize,
    title: []const u8,
    bounds: Highlight,
};

/// Retains label text through the closing animation, independent of the PTY.
pub const Transition = struct {
    const Track = struct {
        label: Label,
        from: Highlight,
        to: Highlight,
    };

    tracks: std.ArrayList(Track) = .empty,
    start: u64 = 0,

    pub const Frame = struct {
        tracks: []const Track,
        weight: f64,

        pub fn labelAt(self: Frame, i: usize) Label {
            const track = self.tracks[i];
            var label = track.label;
            label.bounds = track.from.sample(track.to, self.weight);
            return label;
        }

        pub fn labelWidth(self: Frame, i: usize) u31 {
            const bounds = self.tracks[i].label.bounds;
            return bounds.right - bounds.left;
        }

        pub fn hit(self: Frame, x: u31) ?u64 {
            var i = self.tracks.len;
            while (i > 0) {
                i -= 1;
                const track = self.tracks[i];
                if (track.to.left == track.to.right) continue;
                const label = self.labelAt(i);
                if (x >= label.bounds.left and x < label.bounds.right) return label.id;
            }
            return null;
        }
    };

    pub fn frame(self: Transition, now: u64) ?Frame {
        if (self.tracks.items.len == 0 or now -| self.start >= duration) return null;
        return .{ .tracks = self.tracks.items, .weight = remaining(self.start, now) };
    }

    pub fn deinit(self: *Transition, alloc: std.mem.Allocator) void {
        for (self.tracks.items) |track| alloc.free(track.label.title);
        self.tracks.deinit(alloc);
        self.* = .{};
    }

    pub fn retarget(self: *Transition, alloc: std.mem.Allocator, now: u64, old: []const Label, new: []const Label) !void {
        var next: Transition = .{ .start = now };
        errdefer next.deinit(alloc);
        var previous: std.ArrayList(Label) = .empty;
        defer previous.deinit(alloc);
        if (self.frame(now)) |current| {
            try previous.ensureTotalCapacity(alloc, current.tracks.len);
            for (0..current.tracks.len) |i| previous.appendAssumeCapacity(current.labelAt(i));
        }
        const source = if (previous.items.len != 0) previous.items else old;
        try next.tracks.ensureTotalCapacity(alloc, source.len + new.len);
        for (source) |label| {
            if (label.bounds.left != label.bounds.right and find(new, label.id) == null) {
                // Keep the label's layout width while its visible box closes.
                var closing = label;
                if (previous.items.len != 0) {
                    if (findTrack(self.tracks.items, label.id)) |track| closing.bounds = track.label.bounds;
                }
                try next.append(alloc, closing, label.bounds, label.bounds.collapsed());
            }
        }
        var changed = next.tracks.items.len != 0;
        for (new) |label| {
            const from = if (find(source, label.id)) |old_label| old_label.bounds else label.bounds.collapsed();
            try next.append(alloc, label, from, label.bounds);
            changed = changed or !std.meta.eql(from, label.bounds);
        }
        if (!changed) next.deinit(alloc);
        self.deinit(alloc);
        self.* = next;
    }

    fn append(self: *Transition, alloc: std.mem.Allocator, label: Label, from: Highlight, to: Highlight) !void {
        var owned = label;
        owned.title = try alloc.dupe(u8, label.title);
        self.tracks.appendAssumeCapacity(.{ .label = owned, .from = from, .to = to });
    }

    fn find(labels: []const Label, id: u64) ?Label {
        for (labels) |label| if (label.id == id) return label;
        return null;
    }

    fn findTrack(tracks: []const Track, id: u64) ?Track {
        for (tracks) |track| if (track.label.id == id) return track;
        return null;
    }
};

pub const Animation = struct {
    const Slide = struct { from: Highlight, start: u64 };

    active_id: u64 = 0,
    target: ?Highlight = null,
    slide: ?Slide = null,

    pub fn retarget(self: *Animation, now: u64, active_id: u64, target: ?Highlight, snap: bool, layout_moving: bool) void {
        if (snap or target == null) {
            self.slide = null;
        } else if ((active_id != self.active_id or layout_moving) and !std.meta.eql(self.target, target)) {
            self.slide = if (self.bounds(now)) |from|
                if (!std.meta.eql(from, target.?)) .{ .from = from, .start = now } else null
            else
                null;
        } else if (!std.meta.eql(self.target, target)) {
            self.slide = null;
        }
        self.active_id = active_id;
        self.target = target;
    }

    pub fn moving(self: Animation, now: u64) bool {
        const slide = self.slide orelse return false;
        return now -| slide.start < duration;
    }

    pub fn bounds(self: Animation, now: u64) ?Highlight {
        const target = self.target orelse return null;
        const slide = self.slide orelse return target;
        if (!self.moving(now)) return target;
        return slide.from.sample(target, remaining(slide.start, now));
    }
};

test "tab highlight interpolates both edges and retargets from its current position" {
    const ms = std.time.ns_per_ms;
    const first: Highlight = .{ .left = 8, .right = 88 };
    const second: Highlight = .{ .left = 168, .right = 312 };
    var animation: Animation = .{};
    animation.retarget(0, 1, first, true, false);
    animation.retarget(10 * ms, 2, second, false, false);
    try std.testing.expectEqual(first, animation.bounds(10 * ms).?);
    const midway: Highlight = .{ .left = 148, .right = 284 };
    try std.testing.expectEqual(midway, animation.bounds(100 * ms).?);
    try std.testing.expectEqual(second, animation.bounds(190 * ms).?);
    try std.testing.expect(!animation.moving(190 * ms));

    animation.retarget(100 * ms, 1, first, false, false);
    try std.testing.expectEqual(midway, animation.bounds(100 * ms).?);
    try std.testing.expectEqual(first, animation.bounds(280 * ms).?);
    animation.retarget(120 * ms, 2, second, true, false);
    try std.testing.expectEqual(second, animation.bounds(120 * ms).?);
    try std.testing.expect(!animation.moving(120 * ms));
}

test "tab labels reveal, collapse, and close the gap from their current positions" {
    const alloc = std.testing.allocator;
    const ms = std.time.ns_per_ms;
    const first: Label = .{ .id = 1, .index = 1, .title = "first", .bounds = .{ .left = 8, .right = 88 } };
    const second: Label = .{ .id = 2, .index = 2, .title = "second", .bounds = .{ .left = 88, .right = 168 } };
    const moved: Label = .{ .id = 2, .index = 1, .title = "second", .bounds = first.bounds };
    var transition: Transition = .{};
    defer transition.deinit(alloc);

    try transition.retarget(alloc, 0, &.{first}, &.{ first, second });
    try std.testing.expectEqual(second.bounds.collapsed(), transition.frame(0).?.labelAt(1).bounds);
    const halfway = transition.frame(90 * ms).?;
    try std.testing.expectEqual(Highlight{ .left = 88, .right = 158 }, halfway.labelAt(1).bounds);
    try std.testing.expectEqual(@as(?u64, 2), halfway.hit(100));

    try transition.retarget(alloc, 90 * ms, &.{ first, second }, &.{moved});
    const start = transition.frame(90 * ms).?;
    try std.testing.expectEqual(first.bounds, start.labelAt(0).bounds);
    try std.testing.expectEqual(Highlight{ .left = 88, .right = 158 }, start.labelAt(1).bounds);
    try std.testing.expectEqual(@as(?u64, null), start.hit(40));
    const closing = transition.frame(180 * ms).?;
    try std.testing.expectEqual(Highlight{ .left = 8, .right = 18 }, closing.labelAt(0).bounds);
    try std.testing.expectEqual(Highlight{ .left = 18, .right = 97 }, closing.labelAt(1).bounds);
    try std.testing.expect(transition.frame(270 * ms) == null);
}
