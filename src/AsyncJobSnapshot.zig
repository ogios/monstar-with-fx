//! Owned overlay and Kitty inputs borrowed by an in-flight async raster job.

const AsyncJobSnapshot = @This();

const std = @import("std");
const Renderer = @import("Renderer.zig");
const KittyImageCache = @import("KittyImageCache.zig");

preedit: ?[]u8 = null,
link_hint: ?[]u8 = null,
search: ?[]u8 = null,
search_no_match: bool = false,
link_range: ?Renderer.LinkRange = null,
search_range: ?Renderer.LinkRange = null,
search_matches: std.ArrayList(bool) = .empty,
scrollbar: ?Renderer.ScrollbarThumb = null,
hyperlink_hints: bool = false,
tab_bar: []Renderer.TabBarItem = &.{},
tab_bar_height: u31 = 0,
/// Animated cursor quad, or null when no animation overlay is active.
cursor_overlay: ?Renderer.CursorOverlay = null,
kitty: []Renderer.KittyRenderItem = &.{},
/// The cache that owns the pinned kitty items above. The active tab can change
/// while a job is in flight, so release must return pins to this owner, never
/// the currently-active tab's cache.
kitty_cache: ?*KittyImageCache = null,

pub fn deinit(self: *AsyncJobSnapshot, alloc: std.mem.Allocator) void {
    if (self.preedit) |value| alloc.free(value);
    if (self.link_hint) |value| alloc.free(value);
    if (self.search) |value| alloc.free(value);
    for (self.tab_bar) |item| alloc.free(item.title);
    alloc.free(self.tab_bar);
    self.search_matches.deinit(alloc);
    self.releaseKitty(alloc);
}

pub fn replaceOverlays(
    self: *AsyncJobSnapshot,
    alloc: std.mem.Allocator,
    preedit: ?[]const u8,
    link_hint: ?[]const u8,
    search: ?[]u8,
    search_no_match: bool,
    link_range: ?Renderer.LinkRange,
    search_range: ?Renderer.LinkRange,
    search_matches: std.ArrayList(bool),
    scrollbar: ?Renderer.ScrollbarThumb,
    hyperlink_hints: bool,
) !void {
    var new_preedit: ?[]u8 = null;
    errdefer if (new_preedit) |value| alloc.free(value);
    var new_link_hint: ?[]u8 = null;
    errdefer if (new_link_hint) |value| alloc.free(value);
    errdefer if (search) |value| alloc.free(value);
    const matches = search_matches;
    if (preedit) |value| new_preedit = try alloc.dupe(u8, value);
    if (link_hint) |value| new_link_hint = try alloc.dupe(u8, value);

    if (self.preedit) |value| alloc.free(value);
    if (self.link_hint) |value| alloc.free(value);
    if (self.search) |value| alloc.free(value);
    self.search_matches.deinit(alloc);
    self.preedit = new_preedit;
    self.link_hint = new_link_hint;
    self.search = search;
    self.search_no_match = search_no_match;
    self.link_range = link_range;
    self.search_range = search_range;
    self.search_matches = matches;
    self.scrollbar = scrollbar;
    self.hyperlink_hints = hyperlink_hints;
}

/// Replaces the owned tab-bar snapshot. On failure the existing snapshot is
/// preserved.
pub fn replaceTabBar(self: *AsyncJobSnapshot, alloc: std.mem.Allocator, items: []const Renderer.TabBarItem, height: u31) !void {
    const new_items = try alloc.dupe(Renderer.TabBarItem, items);
    errdefer alloc.free(new_items);
    var duped: usize = 0;
    errdefer for (new_items[0..duped]) |item| alloc.free(item.title);
    for (new_items, 0..) |*item, i| {
        _ = i;
        item.title = try alloc.dupe(u8, item.title);
        duped += 1;
    }
    for (self.tab_bar) |item| alloc.free(item.title);
    alloc.free(self.tab_bar);
    self.tab_bar = new_items;
    self.tab_bar_height = height;
}

/// Drop the pinned kitty pins against the cache that owns them and free the
/// owned render items. `kitty_cache` is null when there is nothing to release.
pub fn releaseKitty(self: *AsyncJobSnapshot, alloc: std.mem.Allocator) void {
    if (self.kitty_cache) |cache| {
        for (self.kitty) |item| cache.release(item.image.id, item.image.generation);
        cache.sweep(alloc);
    }
    alloc.free(self.kitty);
    self.kitty = &.{};
    self.kitty_cache = null;
}

pub fn setCursorOverlay(self: *AsyncJobSnapshot, overlay: ?Renderer.CursorOverlay) void {
    self.cursor_overlay = overlay;
}

pub fn replaceKitty(self: *AsyncJobSnapshot, alloc: std.mem.Allocator, cache: *KittyImageCache, items: []Renderer.KittyRenderItem) !void {
    errdefer alloc.free(items);
    var acquired: usize = 0;
    errdefer for (items[0..acquired]) |item| cache.release(item.image.id, item.image.generation);
    for (items) |*item| {
        item.image.data = .{ .complete = try cache.acquire(alloc, item.image) };
        acquired += 1;
    }
    // Release the previous pins against the cache that owns them; the active
    // tab may differ after a switch, so never use the current tab's cache.
    self.releaseKitty(alloc);
    self.kitty = items;
    self.kitty_cache = if (items.len > 0) cache else null;
    if (items.len > 0) cache.sweep(alloc);
}
