//! Neovide-style animated terminal cursor.
//!
//! The cursor is a quad defined by four corners. Each corner chases its
//! destination through a critically damped spring (a PD controller), so a
//! jump to a new cell is smoothed into a glide rather than a step. Corners
//! aligned with the direction of travel animate faster (the "leading" edge)
//! while corners behind it lag (the "trailing" edge), stretching the quad
//! across the intervening cells — the signature Neovide trail.
//!
//! Positions are in grid pixel space. The destination is the top-left pixel
//! of the cursor cell; the caller supplies the cell pixel size and whether
//! the cursor is on a wide character.

const std = @import("std");

/// Terminal cursor shapes, mapped to the four SVG-style relative corners.
pub const Shape = enum {
    /// Full-cell rectangle.
    block,
    /// Narrow bar occupying the whole cell height.
    bar,
    /// Underline stripe at the bottom of the cell.
    underline,
    /// Unfocused block rendered as an outline.
    hollow,
};

/// Fraction of the cell the bar occupies width-wise.
pub const default_bar_percentage: f32 = 1.0 / 8.0;

/// Indices 0..3 = top-left, top-right, bottom-right, bottom-left.
const standard_corners = [_][2]f32{
    .{ -0.5, -0.5 },
    .{ 0.5, -0.5 },
    .{ 0.5, 0.5 },
    .{ -0.5, 0.5 },
};

fn lerp(start: f32, end: f32, t: f32) f32 {
    return start + (end - start) * t;
}

/// Critically damped spring (PD controller) used by every corner axis.
/// See https://gdcvault.com/play/1027059/Math-In-Game-Development-Summit
const Spring = struct {
    position: f32 = 0,
    velocity: f32 = 0,

    fn reset(self: *Spring) void {
        self.position = 0;
        self.velocity = 0;
    }

    /// Advance by `dt` seconds, converging within 2% of zero in `length`
    /// seconds. Returns true while still moving.
    fn update(self: *Spring, dt: f32, length: f32) bool {
        if (length <= dt) {
            self.reset();
            return false;
        }
        if (self.position == 0) return false;

        const zeta: f32 = 1;
        const omega: f32 = 4.0 / (zeta * length);
        const a = self.position;
        const b = self.position * omega + self.velocity;
        const c = @exp(-omega * dt);

        self.position = (a + b * dt) * c;
        self.velocity = c * (-a * omega - b * dt * omega + b);

        if (@abs(self.position) < 0.05) {
            self.reset();
            return false;
        }
        return true;
    }
};

pub const Corner = struct {
    /// Current absolute grid-pixel position.
    current: [2]f32,
    /// Cell-relative offset in unit fractions from the cursor center.
    relative: [2]f32,
    /// The destination this corner last snapped to, to detect jumps.
    previous_destination: [2]f32,
    spring_x: Spring = .{},
    spring_y: Spring = .{},
    /// Animation length for the current jump; derived from alignment.
    animation_length: f32 = 0,

    /// Advance both springs by `dt`. Returns true while still moving.
    fn update(self: *Corner, dt: f32) bool {
        var animating = self.spring_x.update(dt, self.animation_length);
        animating = self.spring_y.update(dt, self.animation_length) or animating;
        self.current[0] = self.previous_destination[0] - self.spring_x.position;
        self.current[1] = self.previous_destination[1] - self.spring_y.position;
        return animating;
    }
};

pub const Settings = struct {
    /// Overall animation duration for a long jump, in seconds.
    animation_length: f32 = 0.15,
    /// Duration for short jumps (one or two cells, e.g. typing), seconds.
    short_animation_length: f32 = 0.04,
    /// How far the back of the cursor trails the front, 0.0 to 1.0. At
    /// 1.0 the front jumps immediately with a maximum trail; lower values
    /// animate more smoothly but add lag.
    trail_size: f32 = 1.0,
};

pub const Animator = struct {
    corners: [4]Corner,
    shape: Shape = .block,
    dims: [2]f32 = .{ 1, 1 },
    /// Top-left pixel offset of the destination cell in grid space.
    destination: [2]f32 = .{ 0, 0 },
    /// True between a destination change and the next advance().
    jumped: bool = false,
    /// Whether any corner is still in motion.
    animating: bool = false,
    /// Wide characters double the block cursor width.
    double_width: bool = false,

    pub fn init(shape: Shape, dims: [2]f32, double_width: bool, destination: [2]f32) Animator {
        var a = Animator{
            .corners = undefined,
            .shape = shape,
            .dims = dims,
            .double_width = double_width,
            .destination = destination,
        };
        a.setShape(shape, dims, double_width);
        // setShape re-baselines the corners onto the new geometry, so the first
        // frame never animates in from the origin and a wide block seeds its
        // corners across both cells.
        return a;
    }

    /// Snap every corner onto the current destination with the active shape,
    /// clear the springs and motion flags. Used for the initial seed, an
    /// immediate retarget, and a shape change so corners never linger in the
    /// previous geometry (overlay shape and corner trail would otherwise
    /// disagree for the rest of a jump).
    fn snapToDestination(self: *Animator) void {
        for (&self.corners) |*c| {
            const cd = self.cornerDestination(c);
            c.current = cd;
            c.previous_destination = cd;
            c.spring_x.reset();
            c.spring_y.reset();
            c.animation_length = 0;
        }
        self.jumped = false;
        self.animating = false;
    }

    pub fn setShape(self: *Animator, shape: Shape, dims: [2]f32, double_width: bool) void {
        self.shape = shape;
        self.dims = dims;
        self.double_width = double_width;
        const bar_percentage = default_bar_percentage;
        for (&self.corners, standard_corners) |*corner, rel| {
            const x = rel[0];
            const y = rel[1];
            corner.relative = switch (shape) {
                .block, .hollow => rel,
                .bar => .{
                    (x + 0.5) * bar_percentage - 0.5,
                    y,
                },
                .underline => .{
                    x,
                    -((-y + 0.5) * bar_percentage - 0.5),
                },
            };
        }
        // Re-baseline onto the new footprint; a shape change fired mid-jump
        // must not leave the four corners still gliding to old-shape corners
        // (the overlay already renders the new shape).
        self.snapToDestination();
    }

    /// Effective pixel width; block doubles on a wide character.
    fn width(self: *const Animator) f32 {
        return self.dims[0] * @as(f32, if (self.double_width and self.shape == .block) 2 else 1);
    }

    /// The grid-pixel center of the destination cell.
    fn center(self: *const Animator) [2]f32 {
        return .{
            self.destination[0] + self.width() * 0.5,
            self.destination[1] + self.dims[1] * 0.5,
        };
    }

    /// Grid-pixel destination of a corner from the cursor center, using the
    /// effective width so a wide block spans both cells on the first frame.
    fn cornerDestination(self: *const Animator, corner: *const Corner) [2]f32 {
        const c = self.center();
        return .{
            c[0] + corner.relative[0] * self.width(),
            c[1] + corner.relative[1] * self.dims[1],
        };
    }

    /// How closely a corner aligns with the direction of travel, from -1
    /// (directly behind) to +1 (directly ahead). Corners ahead move faster
    /// (leading edge); corners behind lag (trailing edge).
    fn directionAlignment(self: *const Animator, corner: *const Corner) f32 {
        const corner_destination = self.cornerDestination(corner);
        var corner_direction = corner.relative;
        normalize(&corner_direction);
        var travel: [2]f32 = .{
            corner_destination[0] - corner.previous_destination[0],
            corner_destination[1] - corner.previous_destination[1],
        };
        normalize(&travel);
        return dot(travel, corner_direction);
    }

    /// Pick an animation length from leading/trailing alignment. Short
    /// jumps (one or two cells) use the fast short duration.
    fn jumpAnimationLength(
        self: *const Animator,
        corner: *const Corner,
        settings: Settings,
        alignment: f32,
    ) f32 {
        const corner_destination = self.cornerDestination(corner);
        const jump_vec: [2]f32 = .{
            (corner_destination[0] - corner.previous_destination[0]) / self.width(),
            (corner_destination[1] - corner.previous_destination[1]) / self.dims[1],
        };
        const cells = @max(@abs(jump_vec[0]), @abs(jump_vec[1]));
        if (cells <= 2.001) {
            return @min(settings.animation_length, settings.short_animation_length);
        }
        const leading = settings.animation_length * (1.0 - std.math.clamp(settings.trail_size, 0, 1));
        const trailing = settings.animation_length;
        return lerp(trailing, leading, alignment);
    }

    /// Retarget toward `destination` (top-left of the new cell). Detects the
    /// jump and sets per-corner animation lengths from alignment.
    pub fn setDestination(
        self: *Animator,
        destination: [2]f32,
        dims: [2]f32,
        double_width: bool,
        settings: Settings,
        immediate: bool,
    ) void {
        const moved = destination[0] != self.destination[0] or
            destination[1] != self.destination[1] or dims[0] != self.dims[0] or
            dims[1] != self.dims[1] or double_width != self.double_width;
        self.destination = destination;
        self.dims = dims;
        self.double_width = double_width;

        // An immediate retarget (cursor hidden, unfocused, reduced-motion, or
        // the config flag disabled) snaps every corner onto its destination and
        // clears the springs so no stale quad or false jump survives. The plain
        // no-change path (syncCursorAnimator calls setDestination every frame)
        // must leave an in-flight trail untouched.
        if (immediate) {
            self.snapToDestination();
            return;
        }
        if (!moved) return;

        var alignments: [4]f32 = undefined;
        var min: f32 = std.math.inf(f32);
        var max: f32 = -std.math.inf(f32);
        for (&self.corners, 0..) |c, i| {
            alignments[i] = self.directionAlignment(&c);
            min = @min(min, alignments[i]);
            max = @max(max, alignments[i]);
        }
        const range = max - min;
        for (&self.corners, 0..) |*c, i| {
            var alignment: f32 = if (range == 0) 1.0 else (alignments[i] - min) / range;
            alignment = std.math.clamp(alignment, 0, 1);
            c.animation_length = self.jumpAnimationLength(c, settings, alignment);
        }

        // Seed springs from the gap to each corner's new destination.
        for (&self.corners) |*c| {
            const cd = self.cornerDestination(c);
            if (cd[0] != c.previous_destination[0] or cd[1] != c.previous_destination[1]) {
                c.spring_x.position = cd[0] - c.current[0];
                c.spring_y.position = cd[1] - c.current[1];
                c.previous_destination = cd;
            }
        }
        self.jumped = true;
    }

    /// Advance all corner springs by `dt`. Returns true while any corner is
    /// still moving.
    pub fn advance(self: *Animator, dt: f32) bool {
        var animating = false;
        for (&self.corners) |*c| {
            animating = c.update(dt) or animating;
        }
        self.animating = animating;
        self.jumped = false;
        return animating;
    }

    /// Current corner positions in grid space, indices 0..3 =
    /// top-left, top-right, bottom-right, bottom-left. Corners are
    /// snapped relative to the destination's fractional offset so the quad
    /// does not shimmer as it glides between whole pixels.
    pub fn cursorCorners(self: *const Animator) [4][2]f32 {
        const fract_x = @mod(self.destination[0], 1);
        const fract_y = @mod(self.destination[1], 1);
        var out: [4][2]f32 = undefined;
        for (&self.corners, 0..) |*c, i| {
            out[i] = .{
                @round(c.current[0] - fract_x) + fract_x,
                @round(c.current[1] - fract_y) + fract_y,
            };
        }
        return out;
    }

    /// True once every spring has settled on the destination cell.
    pub fn settled(self: *const Animator) bool {
        return !self.jumped and !self.animating;
    }
};

fn dot(a: [2]f32, b: [2]f32) f32 {
    return a[0] * b[0] + a[1] * b[1];
}

fn normalize(v: *[2]f32) void {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1]);
    if (len <= 0.0001) return;
    v[0] /= len;
    v[1] /= len;
}

test "bar shape keeps corners within the cell" {
    const dims = [2]f32{ 8, 16 };
    const a = Animator.init(.bar, dims, false, .{ 0, 0 });
    for (a.corners) |c| {
        try std.testing.expect(c.relative[0] >= -0.5 and c.relative[0] <= 0.5);
        try std.testing.expect(c.relative[1] >= -0.5 and c.relative[1] <= 0.5);
    }
}

test "a small jump settles within a few frames" {
    var a = Animator.init(.block, .{ 8, 16 }, false, .{ 0, 0 });
    const settings: Settings = .{};
    a.setDestination(.{ 8, 0 }, .{ 8, 16 }, false, settings, false);
    const dt: f32 = 1.0 / 60.0;
    var frames: u32 = 0;
    while (a.advance(dt) and frames < 240) : (frames += 1) {}
    // Corners converge on the destination cell (top-left x=8, size 8x16).
    // Top-left corner sits at (8, 0); bottom-right at (16, 16).
    const corners = a.cursorCorners();
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), corners[0][0], 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), corners[0][1], 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), corners[2][0], 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), corners[2][1], 1.0);
}

test "long jump stretches the trail then settles" {
    var a = Animator.init(.block, .{ 8, 16 }, false, .{ 0, 0 });
    const settings: Settings = .{};
    a.setDestination(.{ 80, 0 }, .{ 8, 16 }, false, settings, false);
    try std.testing.expect(!a.settled());
    const dt: f32 = 1.0 / 60.0;
    var frames: u32 = 0;
    while (a.advance(dt) and frames < 240) : (frames += 1) {}
    // The spring must converge within the 4-second cap.
    try std.testing.expect(frames < 240);
    try std.testing.expect(a.settled());
}

test "wide block initializes to the doubled cell width" {
    const a = Animator.init(.block, .{ 8, 16 }, true, .{ 32, 5 });
    // Effective width is dims[0]*2 = 16: corners span x from 32 to 48.
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), a.corners[0].current[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 48.0), a.corners[1].current[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 48.0), a.corners[2].current[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), a.corners[3].current[0], 0.001);
    // Vertically unchanged (single cell height).
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), a.corners[0].current[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), a.corners[2].current[1], 0.001);
}

test "no-destination-change frame leaves a moving trail untouched" {
    var a = Animator.init(.block, .{ 8, 16 }, false, .{ 0, 0 });
    a.setDestination(.{ 80, 0 }, .{ 8, 16 }, false, .{}, false);
    try std.testing.expect(!a.settled());
    const moving = a.corners[0].current[0];
    // syncCursorAnimator re-resolves the same cell every frame while the
    // trail is in flight; that call must not snap the trail to the target.
    a.setDestination(.{ 80, 0 }, .{ 8, 16 }, false, .{}, false);
    try std.testing.expect(!a.settled());
    try std.testing.expectApproxEqAbs(moving, a.corners[0].current[0], 0.001);
}

test "immediate snap leaves the animator settled at the new cell" {
    var a = Animator.init(.block, .{ 8, 16 }, false, .{ 0, 0 });
    a.setDestination(.{ 80, 0 }, .{ 8, 16 }, false, .{}, false);
    try std.testing.expect(!a.settled());
    a.setDestination(.{ 80, 0 }, .{ 8, 16 }, false, .{}, true);
    try std.testing.expect(a.settled());
    for (a.corners) |c| {
        try std.testing.expectApproxEqAbs(c.previous_destination[0], c.current[0], 0.001);
        try std.testing.expectApproxEqAbs(c.previous_destination[1], c.current[1], 0.001);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), a.corners[0].current[0], 0.001);
}

test "vertical one-row jump uses the short animation length" {
    var a = Animator.init(.block, .{ 8, 16 }, false, .{ 0, 0 });
    const settings: Settings = .{ .animation_length = 0.150, .short_animation_length = 0.040 };
    // A single-row vertical move is a short "one or two cells" jump; it must
    // not fall through to the long 150ms duration.
    a.setDestination(.{ 0, 16 }, .{ 8, 16 }, false, settings, false);
    for (a.corners) |c| {
        try std.testing.expect(c.animation_length <= 0.041);
    }
}

test "setShape mid-jump re-baselines corners onto the new footprint" {
    var a = Animator.init(.block, .{ 8, 16 }, false, .{ 0, 0 });
    a.setDestination(.{ 80, 0 }, .{ 8, 16 }, false, .{}, false);
    try std.testing.expect(!a.settled());
    // DECSCUSR switches block -> bar while the quad is still gliding. The
    // corners must land on the bar footprint rather than finish the jump as a
    // block that the overlay already renders as a bar.
    a.setShape(.bar, .{ 8, 16 }, false);
    try std.testing.expect(a.settled());
    // Every corner sits on its destination along the bar geometry.
    for (a.corners) |c| {
        try std.testing.expectApproxEqAbs(c.previous_destination[0], c.current[0], 0.001);
        try std.testing.expectApproxEqAbs(c.previous_destination[1], c.current[1], 0.001);
    }
    // Horizontally narrowed to the bar width (8/8 = 1px), not the 8px block
    // the trail was flying with; corners no longer span the full cell.
    const bar_width = @as(f32, @floatFromInt(8)) * default_bar_percentage;
    try std.testing.expectApproxEqAbs(bar_width, a.corners[1].current[0] - a.corners[0].current[0], 0.001);
    try std.testing.expectApproxEqAbs(bar_width, a.corners[2].current[0] - a.corners[3].current[0], 0.001);
}
