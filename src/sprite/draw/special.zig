//! Vendored and adapted from ghostty (src/font/sprite/draw/special.zig), MIT licensed.
//! Original copyright Mitchell Hashimoto and ghostty contributors.
//! This file contains glyph drawing functions for all of the
//! non-Unicode sprite glyphs, such as cursors and underlines.
//!
//! The naming convention in this file differs from the usual
//! because the draw functions for special sprites are found by
//! having names that exactly match the enum fields in Sprite.

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../metrics.zig");
const sprite = @import("../canvas.zig");

pub fn underline(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| metrics.underline_thickness,
    );

    canvas.rect(.{
        .x = 0,
        .y = @intCast(y),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
}

pub fn underline_double(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| 2 * metrics.underline_thickness,
    );

    // We place one underline above the underline position, and one below
    // by one thickness, creating a "negative" underline where the single
    // underline would be placed.
    canvas.rect(.{
        .x = 0,
        .y = @intCast(y -| metrics.underline_thickness),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
    canvas.rect(.{
        .x = 0,
        .y = @intCast(y +| metrics.underline_thickness),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
}

pub fn underline_dotted(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    var ctx = canvas.getContext();
    defer ctx.deinit();

    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    const float_pos: f64 = @floatFromInt(metrics.underline_position);
    const float_thick: f64 = @floatFromInt(metrics.underline_thickness);

    // The diameter will be sqrt2 * the usual underline thickness
    // since otherwise dotted underlines look somewhat anemic.
    const radius = std.math.sqrt1_2 * float_thick;

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const padding: f64 = @floatFromInt(canvas.padding_y);
    const y = @min(
        // The center of the underline stem.
        float_pos + 0.5 * float_thick,
        // The lowest we can go on the canvas and not get clipped.
        float_height + padding - @ceil(radius),
    );

    const dot_count: f64 = @max(
        @min(
            // We should try to have enough dots that the
            // space between them matches their diameter.
            @ceil(float_width / (4 * radius)),
            // And not enough that the space between
            // each dot is less than their radius.
            @floor(float_width / (3 * radius)),
            // And definitely not enough that the space
            // between them is less than a single pixel.
            @floor(float_width / (2 * radius + 1)),
        ),
        // And we must have at least one dot per cell.
        1.0,
    );

    // What we essentially do is divide the cell in to
    // dot_count areas with a dot centered in each one.
    var x: f64 = (float_width / dot_count) / 2;
    for (0..@as(usize, @intFromFloat(dot_count))) |_| {
        try ctx.arc(x, y, radius, 0.0, std.math.tau);
        try ctx.closePath();
        x += float_width / dot_count;
    }

    try ctx.fill();
}

pub fn underline_dashed(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| metrics.underline_thickness,
    );

    const dash_width = width / 3 + 1;
    const dash_count = (width / dash_width) + 1;
    var i: u32 = 0;
    while (i < dash_count) : (i += 2) {
        const x = i * dash_width;
        canvas.rect(.{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = @intCast(dash_width),
            .height = @intCast(metrics.underline_thickness),
        }, .on);
    }
}

// Wu antialiased undercurl, ported from kitty (decorations.c
// add_curl_underline, MIT/GPL3). Each x column paints two antialias
// boundary intensites plus a solid fill, so the wiggle reads as bold
// instead of a hairline. Amplitude is derived from the descender space
// rather than the cell width, matching kitty's taller, more visible wave.
pub fn underline_curly(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    const max_x: f64 = @floatFromInt(width -| 1);
    const max_y: u32 = height -| 1;
    const xfactor: f64 = 2.0 * std.math.pi / max_x;

    const d_quot: u32 = metrics.underline_thickness / 2;
    const d_rem: u32 = metrics.underline_thickness % 2;
    const pos_limit: u32 = if (height > d_quot + d_rem) height - (d_quot + d_rem) else 0;
    var position: u32 = @min(metrics.underline_position, pos_limit);

    const thick_cap: u32 = if (height > position + 1) height - (position + 1) else 0;
    var thickness: u32 = @max(1, @min(metrics.underline_thickness, thick_cap));

    const max_height: u32 = if (position > thickness / 2) height - (position - thickness / 2) else height;
    const half_height: u32 = @max(1, max_height / 4);

    // The curve's Wu-aliased bounding edges supply part of the visual
    // thickness, so the solid fill is one row thinner than the nominal.
    thickness = @max(1, thickness) - (if (thickness < 3) @as(u32, 1) else @as(u32, 2));

    position += half_height * 2;
    if (position + half_height > max_y) position = max_y -| half_height;

    const sfc_width: u32 = @intCast(canvas.sfc.getWidth());
    const fill: f64 = @floatFromInt(thickness);

    for (0..width) |x| {
        const y: f64 = @as(f64, @floatFromInt(half_height)) * std.math.cos(@as(f64, @floatFromInt(x)) * xfactor);
        const y_floor: f64 = @floor(y);
        const y1: i32 = @intFromFloat(@floor(y - fill));
        const y2: i32 = @intFromFloat(@ceil(y));
        const intensity: u8 = @intFromFloat(@floor(255.0 * @abs(y - y_floor)));
        const xc: i32 = @intCast(x);

        curlAlpha(canvas, xc, y1, 255 - intensity, sfc_width, max_y, position);
        curlAlpha(canvas, xc, y2, intensity, sfc_width, max_y, position);
        var t: u32 = 1;
        while (t <= thickness) : (t += 1) {
            curlAlpha(canvas, xc, y1 + @as(i32, @intCast(t)), 255, sfc_width, max_y, position);
        }
    }
}

/// Saturating write of `val` alpha at canvas column `x`, row `position+y`,
/// clamped into the cell. Accumulates so overlapping dots stay solid.
fn curlAlpha(
    canvas: *sprite.Canvas,
    x: i32,
    y: i32,
    val: u8,
    sfc_width: u32,
    max_y: u32,
    position: u32,
) void {
    const yy: i32 = std.math.clamp(y + @as(i32, @intCast(position)), 0, @as(i32, @intCast(max_y)));
    const bx: i32 = x + @as(i32, @intCast(canvas.padding_x));
    const by: i32 = yy + @as(i32, @intCast(canvas.padding_y));
    const idx: usize = @as(usize, @intCast(by)) * sfc_width + @as(usize, @intCast(bx));
    const buf = std.mem.sliceAsBytes(canvas.sfc.image_surface_alpha8.buf);
    if (idx < buf.len) buf[idx] +|= val;
}

pub fn strikethrough(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    canvas.rect(.{
        .x = 0,
        .y = @intCast(metrics.strikethrough_position),
        .width = @intCast(width),
        .height = @intCast(metrics.strikethrough_thickness),
    }, .on);
}

pub fn overline(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    // We can go beyond the top of the cell a bit, but we
    // want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell above the top
    // of the cell.
    const y = @max(
        metrics.overline_position,
        -@as(i32, @intCast(canvas.padding_y)),
    );

    canvas.rect(.{
        .x = 0,
        .y = y,
        .width = @intCast(width),
        .height = @intCast(metrics.overline_thickness),
    }, .on);
}

pub fn cursor_rect(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;

    canvas.rect(.{
        .x = 0,
        .y = 0,
        .width = @intCast(width),
        .height = @intCast(height),
    }, .on);
}

pub fn cursor_hollow_rect(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    // We fill the entire rect and then hollow out the inside, this isn't very
    // efficient but it doesn't need to be and it's the easiest way to write it.
    canvas.rect(.{
        .x = 0,
        .y = 0,
        .width = @intCast(width),
        .height = @intCast(height),
    }, .on);
    canvas.rect(.{
        .x = @intCast(metrics.cursor_thickness),
        .y = @intCast(metrics.cursor_thickness),
        .width = @intCast(width -| metrics.cursor_thickness * 2),
        .height = @intCast(height -| metrics.cursor_thickness * 2),
    }, .off);
}

pub fn cursor_bar(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;

    // We place the bar cursor half of its thickness over the left edge of the
    // cell, so that it sits centered between characters, not biased to a side.
    //
    // We round up (add 1 before dividing by 2) because, empirically, having a
    // 1px cursor shifted left a pixel looks better than having it not shifted.
    canvas.rect(.{
        .x = -@as(i32, @intCast((metrics.cursor_thickness + 1) / 2)),
        .y = 0,
        .width = @intCast(metrics.cursor_thickness),
        .height = @intCast(height),
    }, .on);
}

pub fn cursor_underline(
    cp: u32,
    canvas: *sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| metrics.underline_thickness,
    );

    canvas.rect(.{
        .x = 0,
        .y = @intCast(y),
        .width = @intCast(width),
        .height = @intCast(metrics.cursor_thickness),
    }, .on);
}
