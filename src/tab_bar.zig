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
const open_duration = 200 * std.time.ns_per_ms;
const close_duration = 180 * std.time.ns_per_ms;

/// The remaining distance under ease-out cubic at the given monotonic time.
fn remaining(start: u64, now: u64, length: u64) f64 {
    const fraction = 1 - progress(start, now, length);
    return fraction * fraction * fraction;
}

fn progress(start: u64, now: u64, length: u64) f64 {
    const elapsed = @min(length, now -| start);
    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(length));
}

fn interpolate(target: u31, from: u31, weight: f64) u31 {
    return @intFromFloat(@round(std.math.lerp(@as(f64, @floatFromInt(target)), @as(f64, @floatFromInt(from)), weight)));
}

/// Animates the terminal area beneath a stationary tab strip.
pub const ContentTransition = struct {
    pub const Direction = enum { left, right };
    pub const Kind = union(enum) { slide: Direction, open, close };

    id: u64,
    kind: Kind,
    /// Vertical travel in physical pixels before clipping to the terminal.
    vertical_travel: u31 = 0,
    start: ?u64 = null,

    pub const Frame = struct {
        pub const Span = struct { src_x: u31, dst_x: u31, width: u31 };
        pub const Fade = struct {
            foreground: enum { incoming, outgoing },
            /// Vertical displacement in physical pixels, down on open and up on close.
            offset: u31,
            /// Weight of the moving page on a 0–256 scale.
            opacity: u16,
        };

        id: u64,
        width: u31,
        top: u31,
        height: u31,
        effect: union(enum) {
            slide: struct { direction: Direction, outgoing_width: u31 },
            fade: Fade,
        },

        pub fn outgoing(self: Frame) Span {
            const slide = self.effect.slide;
            const traveled = self.width - slide.outgoing_width;
            return switch (slide.direction) {
                .left => .{ .src_x = traveled, .dst_x = 0, .width = slide.outgoing_width },
                .right => .{ .src_x = 0, .dst_x = traveled, .width = slide.outgoing_width },
            };
        }

        pub fn incoming(self: Frame) Span {
            const slide = self.effect.slide;
            const traveled = self.width - slide.outgoing_width;
            return switch (slide.direction) {
                .left => .{ .src_x = 0, .dst_x = slide.outgoing_width, .width = traveled },
                .right => .{ .src_x = slide.outgoing_width, .dst_x = 0, .width = traveled },
            };
        }
    };

    pub fn frame(self: ContentTransition, now: u64, width: u31, top: u31, height: u31) ?Frame {
        if (width == 0 or height == 0) return null;
        const start = self.start orelse now;
        const length: u64 = switch (self.kind) {
            .slide => duration,
            .open => open_duration,
            .close => close_duration,
        };
        if (now -| start >= length) return null;

        const weight = remaining(start, now, length);
        const travel = @min(self.vertical_travel, height / 4);
        const effect: @FieldType(Frame, "effect") = switch (self.kind) {
            .slide => |direction| slide: {
                const outgoing_width = interpolate(0, width, weight);
                if (outgoing_width == 0) return null;
                break :slide .{ .slide = .{ .direction = direction, .outgoing_width = outgoing_width } };
            },
            .open => .{ .fade = .{
                .foreground = .incoming,
                .offset = interpolate(0, travel, weight),
                .opacity = @intCast(interpolate(256, 0, weight)),
            } },
            .close => .{ .fade = .{
                .foreground = .outgoing,
                .offset = interpolate(travel, 0, weight),
                .opacity = @intCast(interpolate(0, 256, weight)),
            } },
        };
        return .{ .id = self.id, .width = width, .top = top, .height = height, .effect = effect };
    }
};

test "tab content slides in from either edge with no gap and settles" {
    const now = 90 * std.time.ns_per_ms;
    var slide: ContentTransition = .{ .id = 1, .kind = .{ .slide = .left } };
    const first = slide.frame(now, 80, 12, 50).?;
    try std.testing.expectEqual(@as(u31, 80), first.outgoing().width);
    try std.testing.expectEqual(@as(u31, 0), first.incoming().width);

    slide.start = 0;
    const left = slide.frame(now, 80, 12, 50).?;
    try std.testing.expectEqual(ContentTransition.Frame.Span{ .src_x = 70, .dst_x = 0, .width = 10 }, left.outgoing());
    try std.testing.expectEqual(ContentTransition.Frame.Span{ .src_x = 0, .dst_x = 10, .width = 70 }, left.incoming());

    slide.kind = .{ .slide = .right };
    const right = slide.frame(now, 80, 12, 50).?;
    try std.testing.expectEqual(ContentTransition.Frame.Span{ .src_x = 0, .dst_x = 70, .width = 10 }, right.outgoing());
    try std.testing.expectEqual(ContentTransition.Frame.Span{ .src_x = 10, .dst_x = 0, .width = 70 }, right.incoming());
    try std.testing.expect(slide.frame(duration, 80, 12, 50) == null);
}

test "opening moves down and fades in while closing moves up and fades out" {
    const open: ContentTransition = .{ .id = 1, .kind = .open, .vertical_travel = 48, .start = 0 };
    const opening = open.frame(open_duration / 2, 800, 50, 600).?.effect.fade;
    try std.testing.expectEqual(ContentTransition.Frame.Fade{ .foreground = .incoming, .offset = 6, .opacity = 224 }, opening);
    try std.testing.expect(open.frame(open_duration, 800, 50, 600) == null);

    const close: ContentTransition = .{ .id = 2, .kind = .close, .vertical_travel = 48, .start = 0 };
    const closing = close.frame(close_duration / 2, 800, 50, 600).?.effect.fade;
    try std.testing.expectEqual(ContentTransition.Frame.Fade{ .foreground = .outgoing, .offset = 42, .opacity = 32 }, closing);
    try std.testing.expect(close.frame(close_duration, 800, 50, 600) == null);
}

pub const Label = struct {
    id: u64,
    index: usize,
    title: []const u8,
    bounds: Highlight,
};

/// Retains label text through the closing animation, independent of the PTY.
pub const Transition = struct {
    pub const Membership = enum { unchanged, opened, closed };

    const Track = struct {
        label: Label,
        from: Highlight,
        to: Highlight,
        from_opacity: u8,
        to_opacity: u8,
    };

    tracks: std.ArrayList(Track) = .empty,
    start: u64 = 0,
    length: u64 = duration,
    highlight_id: ?u64 = null,

    pub const Frame = struct {
        tracks: []const Track,
        weight: f64,
        highlight_id: ?u64,

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

        fn closing(self: Frame, i: usize) bool {
            const to = self.tracks[i].to;
            return to.left == to.right;
        }

        pub fn labelOpacity(self: Frame, i: usize) u8 {
            const track = self.tracks[i];
            return @intCast(interpolate(track.to_opacity, track.from_opacity, self.weight));
        }

        pub fn highlightIndex(self: Frame) ?usize {
            const id = self.highlight_id orelse return null;
            for (self.tracks, 0..) |track, i| {
                if (track.label.id == id) return i;
            }
            return null;
        }

        pub fn hit(self: Frame, x: u31) ?u64 {
            var i = self.tracks.len;
            while (i > 0) {
                i -= 1;
                if (self.closing(i)) continue;
                const label = self.labelAt(i);
                if (x >= label.bounds.left and x < label.bounds.right) return label.id;
            }
            return null;
        }
    };

    pub fn frame(self: Transition, now: u64) ?Frame {
        if (self.tracks.items.len == 0 or now -| self.start >= self.length) return null;
        return .{ .tracks = self.tracks.items, .weight = remaining(self.start, now, self.length), .highlight_id = self.highlight_id };
    }

    pub fn deinit(self: *Transition, alloc: std.mem.Allocator) void {
        for (self.tracks.items) |track| alloc.free(track.label.title);
        self.tracks.deinit(alloc);
        self.* = .{};
    }

    pub fn retarget(
        self: *Transition,
        alloc: std.mem.Allocator,
        now: u64,
        old: []const Label,
        new: []const Label,
        membership: Membership,
        active_id: u64,
        previous_id: u64,
    ) !void {
        const current_frame = self.frame(now);
        var next: Transition = .{
            .start = now,
            .length = switch (membership) {
                .opened => open_duration,
                .closed => close_duration,
                .unchanged => if (current_frame != null) self.length - (now -| self.start) else duration,
            },
            .highlight_id = switch (membership) {
                .opened => active_id,
                .closed => if (active_id != previous_id) previous_id else null,
                .unchanged => if (current_frame != null and active_id == previous_id) self.highlight_id else null,
            },
        };
        errdefer next.deinit(alloc);
        var previous: std.ArrayList(Label) = .empty;
        defer previous.deinit(alloc);
        if (current_frame) |current| {
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
                const opacity = previousOpacity(current_frame, label.id) orelse 255;
                try next.append(alloc, closing, label.bounds, label.bounds.collapsed(), opacity, 0);
            }
        }
        var changed = next.tracks.items.len != 0;
        for (new) |label| {
            const old_label = find(source, label.id);
            const from = if (old_label) |entry| entry.bounds else label.bounds.collapsed();
            const opacity = previousOpacity(current_frame, label.id) orelse if (old_label != null) @as(u8, 255) else 0;
            try next.append(alloc, label, from, label.bounds, opacity, 255);
            changed = changed or !std.meta.eql(from, label.bounds) or opacity != 255;
        }
        if (!changed) next.deinit(alloc);
        self.deinit(alloc);
        self.* = next;
    }

    fn append(self: *Transition, alloc: std.mem.Allocator, label: Label, from: Highlight, to: Highlight, from_opacity: u8, to_opacity: u8) !void {
        var owned = label;
        owned.title = try alloc.dupe(u8, label.title);
        self.tracks.appendAssumeCapacity(.{ .label = owned, .from = from, .to = to, .from_opacity = from_opacity, .to_opacity = to_opacity });
    }

    fn previousOpacity(previous: ?Frame, id: u64) ?u8 {
        const current = previous orelse return null;
        for (current.tracks, 0..) |track, i| if (track.label.id == id) return current.labelOpacity(i);
        return null;
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
        return slide.from.sample(target, remaining(slide.start, now, duration));
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
    const first: Label = .{ .id = 1, .index = 1, .title = "first", .bounds = .{ .left = 8, .right = 88 } };
    const second: Label = .{ .id = 2, .index = 2, .title = "second", .bounds = .{ .left = 88, .right = 168 } };
    const moved: Label = .{ .id = 2, .index = 1, .title = "second", .bounds = first.bounds };
    var transition: Transition = .{};
    defer transition.deinit(alloc);

    try transition.retarget(alloc, 0, &.{first}, &.{ first, second }, .opened, 2, 1);
    try std.testing.expectEqual(second.bounds.collapsed(), transition.frame(0).?.labelAt(1).bounds);
    try std.testing.expectEqual(@as(?usize, 1), transition.frame(0).?.highlightIndex());
    try std.testing.expectEqual(@as(u8, 0), transition.frame(0).?.labelOpacity(1));
    const halfway = transition.frame(open_duration / 2).?;
    try std.testing.expectEqual(Highlight{ .left = 88, .right = 158 }, halfway.labelAt(1).bounds);
    try std.testing.expectEqual(@as(?u64, 2), halfway.hit(100));

    const close_start = open_duration / 2;
    try transition.retarget(alloc, close_start, &.{ first, second }, &.{moved}, .closed, 2, 1);
    const start = transition.frame(close_start).?;
    try std.testing.expectEqual(first.bounds, start.labelAt(0).bounds);
    try std.testing.expectEqual(Highlight{ .left = 88, .right = 158 }, start.labelAt(1).bounds);
    try std.testing.expectEqual(@as(u8, 223), start.labelOpacity(1));
    try std.testing.expectEqual(@as(?usize, 0), start.highlightIndex());
    try std.testing.expectEqual(@as(?u64, null), start.hit(40));
    const closing = transition.frame(close_start + close_duration / 2).?;
    try std.testing.expectEqual(Highlight{ .left = 8, .right = 18 }, closing.labelAt(0).bounds);
    try std.testing.expectEqual(Highlight{ .left = 18, .right = 97 }, closing.labelAt(1).bounds);
    try std.testing.expectEqual(@as(u8, 32), closing.labelOpacity(0));
    try std.testing.expect(transition.frame(close_start + close_duration) == null);
}
