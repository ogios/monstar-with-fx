//! Asynchronous CPU raster worker.
//!
//! A single controlling thread owns each `Loader` and `AsyncRaster` and calls
//! its public methods; their internal threads only perform loading or raster
//! work. Once started, either object must remain at a stable address until its
//! thread is joined by `takeResult` or `deinit`. The supplied `RenderState` is
//! borrowed for the lifetime of the resulting `AsyncRaster` and must not be
//! accessed by the controlling thread while a raster job is busy.

const AsyncRaster = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const vt = @import("ghostty-vt");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const Renderer = @import("Renderer.zig");

pub const RepairRect = Renderer.PixelRect;

pub const Repair = union(enum) {
    none,
    full,
    rects: []const RepairRect,
};

/// A borrowed render snapshot. On successful submission, every slice and any
/// memory reachable through its elements must remain valid until the matching
/// result is taken, or until `AsyncRaster.deinit` returns. The worker has
/// exclusive access to mutate `pixels` during that interval; all other slices
/// are read-only. A returned `Result.job` preserves these borrows and does not
/// transfer ownership of their backing storage.
pub const Job = struct {
    pixels: []u32,
    source_pixels: ?[]const u32,
    width: u31,
    height: u31,
    grid_x: u31,
    grid_y: u31,
    grid_width: u31,
    grid_height: u31,
    age: usize,
    generation: u64,
    focused: bool,
    /// Underline hovered hyperlinks in the base render.
    hyperlink_hints: bool,
    /// Hovered automatically detected link in viewport cell coordinates.
    link_range: ?Renderer.LinkRange,
    /// Selected scrollback-search match in viewport cell coordinates.
    search_range: ?Renderer.LinkRange,
    /// Every visible scrollback-search match as a row-major cell mask.
    search_matches: []const bool,
    /// Colors shared by the full-strength selected match and dimmed matches.
    search_background: vt.color.RGB,
    search_foreground: vt.color.RGB,
    /// IME preedit overlay text.
    preedit: ?[]const u8,
    /// Hovered-hyperlink URI overlay.
    link_hint: ?[]const u8,
    /// Top-right scrollback-search overlay.
    search: ?[]const u8,
    /// Use the terminal's red palette entry for the search overlay.
    search_no_match: bool,
    /// Transient right-edge scrollback indicator in full-surface pixels.
    scrollbar: ?Renderer.ScrollbarThumb,
    /// Tab-bar strip labels; non-null when a tab bar is shown. The strip
    /// occupies `tab_bar_height` pixels along the configured edge.
    tab_bar: ?[]const Renderer.TabBarItem,
    /// Vertical extent of the tab-bar strip in pixels.
    tab_bar_height: u31,
    /// Which edge of the surface the strip occupies.
    tab_bar_position: Config.TabBarPosition = .bottom,
    /// Tab-bar colors. Kept separate from the selection colors so a
    /// selection change or post-copy flash never restyles the tabs.
    tab_bar_background: vt.color.RGB = .{ .r = 0, .g = 0, .b = 0 },
    active_tab_background: vt.color.RGB = .{ .r = 0x55, .g = 0x55, .b = 0x55 },
    active_tab_foreground: vt.color.RGB = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    inactive_tab_background: vt.color.RGB = .{ .r = 0x3a, .g = 0x3a, .b = 0x3a },
    inactive_tab_foreground: vt.color.RGB = .{ .r = 0xb4, .g = 0xb4, .b = 0xb4 },
    /// Labels or active-tab styling changed independently of grid overlays.
    tab_bar_dirty: bool = false,
    /// Visible kitty placements, resolved on the main thread with image
    /// data repointed at cache-pinned copies; empty when no graphics are
    /// visible.
    kitty_items: []const Renderer.KittyRenderItem,
    /// Animated cursor quad. Unlike the padding-drawing overlays it stays
    /// inside the grid rows, so a cursor-only frame still runs the
    /// partial-repair path, repainting only the crossed rows.
    cursor_overlay: ?Renderer.CursorOverlay = null,
    /// Any overlay input (kitty snapshot, preedit, link hint, hint
    /// flag) differs from the previously submitted job. Unchanged
    /// overlays over clean content need no repaint.
    overlay_dirty: bool,
    /// Whole terminal rows by which previous-frame pixels move. Positive
    /// shifts content up; negative shifts it down.
    scroll_shift: ?isize,
    /// Work needed to bring a stale target up to the previous committed
    /// frame.
    repair: Repair,

    fn hasOverlay(self: *const Job) bool {
        return self.preedit != null or self.link_hint != null or
            self.search != null or self.search_matches.len > 0 or
            self.scrollbar != null or
            self.kitty_items.len > 0;
    }
};

pub const Damage = enum {
    full,
    /// One or more buffer rectangles changed.
    partial,
    none,
};

pub const Result = struct {
    job: Job,
    err: ?anyerror,
    damage: Damage,
};

pub const LoadResult = union(enum) {
    ready: AsyncRaster,
    failed: anyerror,
};

/// Builds the worker's independent FreeType and renderer state after the
/// first frame without repeating the main Font's immutable discovery. The
/// controlling thread owns the loader and must eventually call `deinit`, even
/// after taking its result.
pub const Loader = struct {
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    cursor_color: ?Config.TerminalColor,
    cursor_text: ?Config.TerminalColor,
    background_alpha: u8,
    background_alpha_cells: bool,
    state: *vt.RenderState,
    thread: ?std.Thread = null,
    mutex: std.atomic.Mutex = .unlocked,
    result: ?LoadResult = null,
    complete_fd: posix.fd_t,

    /// Retains `discovery` and borrows `state`. The borrow is transferred to a
    /// successful `.ready` raster; otherwise it ends when the loader is
    /// deinitialized.
    pub fn init(
        discovery: *Font.Discovery,
        selection_background: vt.color.RGB,
        selection_foreground: ?vt.color.RGB,
        cursor_color: ?Config.TerminalColor,
        cursor_text: ?Config.TerminalColor,
        background_alpha: u8,
        background_alpha_cells: bool,
        state: *vt.RenderState,
    ) !Loader {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.EventFdFailed;
        discovery.ref();
        return .{
            .discovery = discovery,
            .selection_background = selection_background,
            .selection_foreground = selection_foreground,
            .cursor_color = cursor_color,
            .cursor_text = cursor_text,
            .background_alpha = background_alpha,
            .background_alpha_cells = background_alpha_cells,
            .state = state,
            .complete_fd = @intCast(rc),
        };
    }

    /// Starts the load thread. Requires no thread to have been started for
    /// this loader; `self` must not move until that thread is joined.
    pub fn start(self: *Loader) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, loadMain, .{self});
    }

    /// Returns null while loading is incomplete. A non-null return joins the
    /// load thread; `.ready` transfers an `AsyncRaster` that the caller must
    /// deinitialize, while `.failed` produces no raster.
    pub fn takeResult(self: *Loader) ?LoadResult {
        drainEventFd(self.complete_fd);
        self.lock();
        const result = self.result orelse {
            self.mutex.unlock();
            return null;
        };
        self.result = null;
        self.mutex.unlock();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        return result;
    }

    /// Joins an outstanding load, destroys any result not taken by the caller,
    /// releases the retained discovery, and invalidates the loader. This may
    /// block until loading completes.
    pub fn deinit(self: *Loader) void {
        if (self.thread) |thread| thread.join();
        if (self.result) |*result| switch (result.*) {
            .ready => |*raster| raster.deinit(),
            .failed => {},
        };
        _ = linux.close(self.complete_fd);
        self.discovery.unref();
        self.* = undefined;
    }

    fn loadMain(self: *Loader) void {
        const result: LoadResult = if (AsyncRaster.init(
            self.discovery,
            self.selection_background,
            self.selection_foreground,
            self.cursor_color,
            self.cursor_text,
            self.background_alpha,
            self.background_alpha_cells,
            self.state,
        )) |raster|
            .{ .ready = raster }
        else |err|
            .{ .failed = err };

        self.lock();
        self.result = result;
        self.mutex.unlock();
        writeEventfd(self.complete_fd) catch |err| {
            std.debug.panic("failed to notify async raster load completion: {}", .{err});
        };
    }

    fn lock(self: *Loader) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }
};

alloc: std.mem.Allocator,
font: *Font,
renderer: Renderer,
/// Origin for converting the last job's grid damage to surface coordinates.
rendered_grid_origin: [2]u31 = .{ 0, 0 },
tab_bar_damage: ?Renderer.PixelRect = null,
thread: ?std.Thread,
mutex: std.atomic.Mutex = .unlocked,
job_fd: posix.fd_t,
complete_fd: posix.fd_t,
stop: bool = false,
has_job: bool = false,
working: bool = false,
job: Job = undefined,
result: ?Result = null,
state: *vt.RenderState,

/// Creates an idle raster worker but does not start its thread. The returned
/// value owns its renderer, font, and event descriptors and borrows `state`
/// until `deinit`.
pub fn init(
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    cursor_color: ?Config.TerminalColor,
    cursor_text: ?Config.TerminalColor,
    background_alpha: u8,
    background_alpha_cells: bool,
    state: *vt.RenderState,
) !AsyncRaster {
    const alloc = std.heap.smp_allocator;
    const font = try alloc.create(Font);
    errdefer alloc.destroy(font);
    font.* = try .initWithDiscovery(alloc, discovery);
    errdefer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, font, .{
        .selection_background = selection_background,
        .selection_foreground = selection_foreground,
        .cursor_color = cursor_color,
        .cursor_text = cursor_text,
        .background_alpha = background_alpha,
        .background_alpha_cells = background_alpha_cells,
    });
    errdefer renderer.deinit();
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(rc) != .SUCCESS) return error.EventFdFailed;
    errdefer _ = linux.close(@as(posix.fd_t, @intCast(rc)));
    const job_rc = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (linux.errno(job_rc) != .SUCCESS) return error.EventFdFailed;
    errdefer _ = linux.close(@as(posix.fd_t, @intCast(job_rc)));
    const self: AsyncRaster = .{
        .alloc = alloc,
        .font = font,
        .renderer = renderer,
        .thread = null,
        .job_fd = @intCast(job_rc),
        .complete_fd = @intCast(rc),
        .state = state,
    };
    return self;
}

/// Starts the raster thread. Requires no thread to have been started for this
/// instance; `self` must not move until that thread is joined.
pub fn start(self: *AsyncRaster) !void {
    std.debug.assert(self.thread == null);
    self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
}

/// Stops and joins the raster thread, releases owned resources, and invalidates
/// the instance. This may block for an in-progress job; that job's borrowed
/// storage must remain valid until this function returns.
pub fn deinit(self: *AsyncRaster) void {
    if (self.thread) |thread| {
        self.lock();
        self.stop = true;
        self.mutex.unlock();
        self.notifyJob() catch |err| std.debug.panic("failed to wake async raster worker during shutdown: {}", .{err});
        thread.join();
    }
    _ = linux.close(self.job_fd);
    _ = linux.close(self.complete_fd);
    self.renderer.deinit();
    self.font.deinit(self.alloc);
    self.alloc.destroy(self.font);
    self.* = undefined;
}

/// Replaces the worker's font and renderer configuration while idle. Returns
/// `error.Busy` if a job is queued, running, or awaiting collection. Other
/// errors leave the existing configuration intact.
pub fn reconfigure(
    self: *AsyncRaster,
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    cursor_color: ?Config.TerminalColor,
    cursor_text: ?Config.TerminalColor,
    background_alpha: u8,
    background_alpha_cells: bool,
) !void {
    self.lock();
    defer self.mutex.unlock();
    if (self.has_job or self.working or self.result != null) return error.Busy;
    const font = try self.alloc.create(Font);
    errdefer self.alloc.destroy(font);
    font.* = try .initWithDiscovery(self.alloc, discovery);
    errdefer font.deinit(self.alloc);
    var renderer: Renderer = try .init(self.alloc, font, .{
        .selection_background = selection_background,
        .selection_foreground = selection_foreground,
        .cursor_color = cursor_color,
        .cursor_text = cursor_text,
        .background_alpha = background_alpha,
        .background_alpha_cells = background_alpha_cells,
    });
    errdefer renderer.deinit();
    self.renderer.deinit();
    self.font.deinit(self.alloc);
    self.alloc.destroy(self.font);
    self.font = font;
    self.renderer = renderer;
}

/// Reports whether a job is queued, running, or has an uncollected result.
pub fn busy(self: *AsyncRaster) bool {
    self.lock();
    defer self.mutex.unlock();
    return self.has_job or self.working or self.result != null;
}

/// Compares the current renderer settings, including discovery identity. This
/// query is synchronized with the worker and does not require an idle raster.
pub fn configuredFor(
    self: *AsyncRaster,
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    cursor_color: ?Config.TerminalColor,
    cursor_text: ?Config.TerminalColor,
    background_alpha: u8,
    background_alpha_cells: bool,
) bool {
    self.lock();
    defer self.mutex.unlock();
    return self.font.discovery() == discovery and
        self.renderer.selection_bg.eql(selection_background) and
        optionalRgbEql(self.renderer.selection_fg, selection_foreground) and
        optionalTerminalColorEql(self.renderer.cursor_color, cursor_color) and
        optionalTerminalColorEql(self.renderer.cursor_text, cursor_text) and
        self.renderer.background_alpha == background_alpha and
        self.renderer.background_alpha_cells == background_alpha_cells;
}

/// Queues one job and wakes the worker. Returns `error.Busy` unless the raster
/// is idle. On success the worker borrows the job's storage as documented by
/// `Job`; on notification failure no job is retained.
pub fn submit(self: *AsyncRaster, job: Job) !void {
    self.lock();
    defer self.mutex.unlock();
    if (self.has_job or self.working or self.result != null) return error.Busy;
    self.job = job;
    self.has_job = true;
    self.notifyJob() catch |err| {
        self.has_job = false;
        return err;
    };
}

/// Returns null until a job completes. Taking a result makes the raster idle
/// and ends the worker's borrow of the job storage; the returned `Job` still
/// contains caller-owned slices and performs no cleanup.
pub fn takeResult(self: *AsyncRaster) ?Result {
    self.drainEventfd();
    self.lock();
    defer self.mutex.unlock();
    const result = self.result orelse return null;
    self.result = null;
    return result;
}

/// Copies the most recently rendered surface rectangles into caller-owned `dest`,
/// clearing its previous contents while retaining capacity. Requires an idle
/// raster, normally immediately after `takeResult`; `alloc` is used only if
/// `dest` must grow.
pub fn copySurfaceDamageRects(self: *AsyncRaster, alloc: std.mem.Allocator, dest: *std.ArrayList(Renderer.PixelRect)) !void {
    self.lock();
    defer self.mutex.unlock();
    std.debug.assert(!self.has_job and !self.working and self.result == null);
    dest.clearRetainingCapacity();
    // Keep tab-strip damage before grid rows.
    if (self.tab_bar_damage) |rect| try dest.append(alloc, rect);
    for (self.renderer.rendered_rects.items) |rect| {
        var surface_rect = rect;
        surface_rect.x += self.rendered_grid_origin[0];
        surface_rect.y += self.rendered_grid_origin[1];
        try dest.append(alloc, surface_rect);
    }
}

fn lock(self: *AsyncRaster) void {
    while (!self.mutex.tryLock()) std.Thread.yield() catch {};
}

fn optionalRgbEql(a: ?vt.color.RGB, b: ?vt.color.RGB) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn optionalTerminalColorEql(a: ?Config.TerminalColor, b: ?Config.TerminalColor) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn drainEventfd(self: *AsyncRaster) void {
    drainEventFd(self.complete_fd);
}

fn drainEventFd(fd: posix.fd_t) void {
    var value: u64 = 0;
    while (posix.read(fd, std.mem.asBytes(&value))) |_| {} else |_| {}
}

fn notifyJob(self: *AsyncRaster) !void {
    try writeEventfd(self.job_fd);
}

fn writeEventfd(fd: posix.fd_t) !void {
    const one: u64 = 1;
    while (true) {
        const rc = linux.write(fd, @ptrCast(&one), @sizeOf(u64));
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc != @sizeOf(u64)) return error.ShortEventFdWrite;
                return;
            },
            .INTR => continue,
            else => return error.EventFdWriteFailed,
        }
    }
}

fn waitJob(self: *AsyncRaster) void {
    var value: u64 = 0;
    while (posix.read(self.job_fd, std.mem.asBytes(&value))) |_| return else |_| {}
}

fn workerMain(self: *AsyncRaster) void {
    while (true) {
        self.waitJob();
        self.lock();
        if (self.stop) {
            self.mutex.unlock();
            return;
        }
        const job = self.job;
        self.has_job = false;
        self.working = true;
        self.mutex.unlock();

        self.renderer.focused = job.focused;
        self.renderer.hyperlink_hints = job.hyperlink_hints;
        self.renderer.link_range = job.link_range;
        self.renderer.search_range = job.search_range;
        self.renderer.search_matches = job.search_matches;
        self.renderer.search_bg = job.search_background;
        self.renderer.search_fg = job.search_foreground;
        var damage: Damage = .full;
        const maybe_err: ?anyerror = if (self.renderJob(job, &damage)) |_| null else |e| e;

        self.lock();
        self.working = false;
        self.result = .{ .job = job, .err = maybe_err, .damage = damage };
        self.mutex.unlock();
        writeEventfd(self.complete_fd) catch |err| std.debug.panic("failed to notify async raster completion: {}", .{err});
    }
}

fn renderJob(self: *AsyncRaster, job: Job, damage: *Damage) !void {
    self.rendered_grid_origin = .{ job.grid_x, job.grid_y };
    self.tab_bar_damage = null;
    self.renderer.rendered_rects.clearRetainingCapacity();
    self.renderer.cursor_overlay = job.cursor_overlay;
    self.renderer.buffer_stride = job.width;
    try self.renderGrid(job, damage);
    if (damage.* != .full and !job.tab_bar_dirty) return;

    // Reserve only the padding on the strip's edge; the layout keeps the grid
    // clear of it, but a tiny surface can shrink the strip to fit.
    const reserved = switch (job.tab_bar_position) {
        .top => job.grid_y,
        .bottom => job.height -| job.grid_y -| job.grid_height,
    };
    const bar_height = @min(job.tab_bar_height, reserved);
    if (bar_height == 0) return;
    const bar_top: u31 = switch (job.tab_bar_position) {
        .top => 0,
        .bottom => job.height - bar_height,
    };
    const bar_pixels = job.pixels[@as(usize, bar_top) * job.width ..];
    @memset(bar_pixels[0 .. @as(usize, bar_height) * job.width], self.renderer.backgroundPixel(job.tab_bar_background));
    if (job.tab_bar) |items| {
        // Clip glyph overhang to the strip so its damage never reaches the grid.
        try self.renderer.renderTabBar(
            bar_pixels,
            job.width,
            bar_height,
            bar_height,
            items,
            job.active_tab_background,
            job.active_tab_foreground,
            job.inactive_tab_background,
            job.inactive_tab_foreground,
            job.tab_bar_background,
        );
    }
    if (damage.* != .full) {
        self.tab_bar_damage = .{ .x = 0, .y = bar_top, .width = job.width, .height = bar_height };
        damage.* = .partial;
    }
}

fn renderGrid(self: *AsyncRaster, job: Job, damage: *Damage) !void {
    const grid_pixels = gridPixels(job);
    // Include the old quad when animation ends, so the native cursor's first
    // frame also erases the trail outside its destination row.
    if ((job.cursor_overlay != null or self.renderer.last_cursor_quad != null) and
        !job.hasOverlay() and self.state.dirty != .full)
    {
        return self.renderJobCursor(job, grid_pixels, damage);
    }
    // These overlays draw outside the grid rows tracked by cell damage.
    if (job.hasOverlay()) {
        // Unless nothing changed at all: clean content plus the same
        // overlays as the previous job reproduce the previous frame,
        // so repair to it instead of re-rendering. Without this a
        // visible kitty image turns every submitted job into a full
        // render.
        if (!job.overlay_dirty and self.state.dirty == .false and repairToPreviousFrame(job)) {
            damage.* = .none;
            return;
        }
        clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
        if (job.kitty_items.len > 0) {
            try self.renderer.renderWithKittyItems(self.state, job.kitty_items, grid_pixels, job.grid_width, job.grid_height);
        } else {
            try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
        }
        if (job.preedit) |text| {
            try self.renderer.renderPreedit(self.state, grid_pixels, job.grid_width, job.grid_height, text);
        }
        if (job.link_hint) |uri| {
            try self.renderer.renderLinkHint(self.state, grid_pixels, job.grid_width, job.grid_height, uri);
        }
        if (job.search) |text| {
            try self.renderer.renderSearch(
                self.state,
                grid_pixels,
                job.grid_width,
                job.grid_height,
                text,
                job.search_no_match,
            );
        }
        if (job.scrollbar) |thumb| {
            self.renderer.renderScrollbarThumb(
                self.state,
                job.pixels,
                job.width,
                job.height,
                thumb,
            );
        }
        damage.* = .full;
        return;
    }
    if (job.scroll_shift) |shift| {
        clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
        // Ink crossing row boundaries cannot be reused independently: a
        // discarded row may have painted into a retained row's pixels.
        if (!self.font.neighbor_row_overhang and
            self.renderer.row_overhang.count() == 0 and
            scrollFromPreviousFrame(job, shift, self.font.cell_height))
        {
            try self.renderer.shiftCellState(self.state.rows, self.state.cols, shift);
            try self.renderer.renderDirty(self.state, grid_pixels, job.grid_width, job.grid_height);
            // Rasterization touched only dirty rows, but every retained row
            // moved to a different surface location.
            damage.* = .full;
            return;
        }
        // Dirty rows may already have been narrowed by the detector.
        try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
        damage.* = .full;
        return;
    }
    switch (self.state.dirty) {
        .full => {
            clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
            try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
            damage.* = .full;
        },
        .partial => {
            if (!repairToPreviousFrame(job)) {
                clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
                try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
                damage.* = .full;
                return;
            }
            try self.renderer.renderDirty(self.state, grid_pixels, job.grid_width, job.grid_height);
            damage.* = if (self.renderer.rendered_rects.items.len == 0) .none else .partial;
        },
        .false => {
            if (!repairToPreviousFrame(job)) {
                clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
                try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
                damage.* = .full;
                return;
            }
            damage.* = .none;
        },
    }
}

/// Partial-repair path for a cursor-only animated overlay. Forces a repaint
/// of the rows the cursor quad (old and new) crossed so its vacated trail is
/// cleared, then composites the new quad. The rest of the grid is untouched,
/// so damage is limited to those rows instead of the whole surface.
fn renderJobCursor(self: *AsyncRaster, job: Job, grid_pixels: []u32, damage: *Damage) !void {
    if (self.state.rows == 0 or self.state.cols == 0) {
        damage.* = .none;
        return;
    }
    const force = self.cursorForceRows();
    self.renderer.cursor_force_row_min = force[0];
    self.renderer.cursor_force_row_max = force[1];
    defer {
        self.renderer.cursor_force_row_min = std.math.maxInt(usize);
        self.renderer.cursor_force_row_max = 0;
    }
    if (!repairToPreviousFrame(job)) {
        clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
        try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
        damage.* = .full;
        return;
    }
    try self.renderer.renderDirty(self.state, grid_pixels, job.grid_width, job.grid_height);
    if (self.renderer.rendered_rects.items.len == 0) {
        damage.* = .none;
        return;
    }
    // multi_row_overhang: renderDirty wholesale re-renders, which already
    // composites the overlay; drawing it again would double-draw the glyph.
    if (!self.font.multi_row_overhang) {
        try self.renderer.renderCursorOverlay(self.state, grid_pixels, job.grid_width, job.grid_height);
    }
    damage.* = .partial;
}

/// Inclusive grid-local row band (expanded one row for glyph overhang) that
/// the current and previous cursor quads crossed, so renderDirty can clear
/// both the leading edge and the trail. `min > max` forces nothing.
fn cursorForceRows(self: *AsyncRaster) [2]usize {
    if (self.state.rows == 0) return .{ std.math.maxInt(usize), 0 };
    const cell_h: usize = self.font.cell_height;
    const rows: usize = self.state.rows;
    var min_row: usize = std.math.maxInt(usize);
    var max_row: usize = 0;
    var found = false;
    const candidates = [_]?Renderer.CursorOverlay{ self.renderer.cursor_overlay, self.renderer.last_cursor_quad };
    for (candidates) |overlay| {
        const quad = overlay orelse continue;
        for (quad.corners) |corner| {
            const row: usize = if (corner[1] <= 0)
                0
            else
                @min(rows - 1, @as(usize, @intCast(@divTrunc(corner[1], @as(i32, @intCast(cell_h))))));
            if (!found) {
                min_row = row;
                max_row = row;
                found = true;
            } else {
                min_row = @min(min_row, row);
                max_row = @max(max_row, row);
            }
        }
    }
    if (!found) return .{ std.math.maxInt(usize), 0 };
    min_row -|= 1;
    max_row = @min(rows - 1, max_row + 1);
    return .{ min_row, max_row };
}

fn gridPixels(job: Job) []u32 {
    std.debug.assert(job.grid_x + job.grid_width <= job.width);
    std.debug.assert(job.grid_y + job.grid_height <= job.height);
    const offset = @as(usize, job.grid_y) * job.width + job.grid_x;
    return job.pixels[offset..];
}

fn clearPadding(job: Job, color: u32) void {
    @memset(job.pixels[0 .. @as(usize, job.grid_y) * job.width], color);
    const grid_bottom = @as(usize, job.grid_y + job.grid_height) * job.width;
    @memset(job.pixels[grid_bottom..], color);
    for (job.grid_y..job.grid_y + job.grid_height) |y| {
        const row = @as(usize, y) * job.width;
        @memset(job.pixels[row .. row + job.grid_x], color);
        const right = row + job.grid_x + job.grid_width;
        @memset(job.pixels[right .. row + job.width], color);
    }
}

fn repairToPreviousFrame(job: Job) bool {
    return switch (job.repair) {
        .none => true,
        .full => repair: {
            const source = job.source_pixels orelse break :repair false;
            if (source.len != job.pixels.len) break :repair false;
            if (source.ptr != job.pixels.ptr) Renderer.copyPixels(job.pixels, source);
            break :repair true;
        },
        .rects => |rects| repair: {
            const source = job.source_pixels orelse break :repair false;
            if (source.len != job.pixels.len) break :repair false;
            if (source.ptr == job.pixels.ptr) break :repair true;
            for (rects) |rect| {
                if (rect.x > job.width or rect.width > job.width - rect.x or
                    rect.y > job.height or rect.height > job.height - rect.y)
                {
                    break :repair false;
                }
                for (rect.y..rect.y + rect.height) |y| {
                    const offset = @as(usize, y) * job.width + rect.x;
                    Renderer.copyPixels(
                        job.pixels[offset..][0..rect.width],
                        source[offset..][0..rect.width],
                    );
                }
            }
            break :repair true;
        },
    };
}

/// Move retained framebuffer rows directly from the previous frame into
/// their new positions. This avoids a full stale-buffer repair followed by
/// a second in-place shift when source and destination differ.
fn scrollFromPreviousFrame(job: Job, shift_rows: isize, cell_height: u31) bool {
    const rows: usize = @abs(shift_rows);
    if (rows == 0) return false;
    const shift_pixels = rows * cell_height;
    if (shift_pixels >= job.grid_height) return false;

    const source = if (job.age == 1)
        @as([]const u32, job.pixels)
    else
        job.source_pixels orelse return false;
    if (source.len != job.pixels.len) return false;

    const stride: usize = job.width;
    const grid_start = @as(usize, job.grid_y) * stride;
    const grid_end = @as(usize, job.grid_y + job.grid_height) * stride;
    const offset = shift_pixels * stride;
    const retained = grid_end - grid_start - offset;
    if (shift_rows > 0) {
        const dst = job.pixels[grid_start .. grid_start + retained];
        const src = source[grid_start + offset .. grid_end];
        if (source.ptr == job.pixels.ptr)
            @memmove(dst, src)
        else
            Renderer.copyPixels(dst, src);
    } else {
        const dst = job.pixels[grid_start + offset .. grid_end];
        const src = source[grid_start .. grid_start + retained];
        if (source.ptr == job.pixels.ptr)
            @memmove(dst, src)
        else
            Renderer.copyPixels(dst, src);
    }
    return true;
}

test "unchanged dirty rows report no damage" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 4, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?25labcd");

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var font: Font = try .init(alloc, "monospace", 16, null);
    defer font.deinit(alloc);
    var raster = try AsyncRaster.init(
        font.discovery(),
        .{ .r = 1, .g = 2, .b = 3 },
        null,
        null,
        null,
        255,
        false,
        &state,
    );
    defer raster.deinit();

    const width: u31 = raster.font.cell_width * 4;
    const height: u31 = raster.font.cell_height;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    const job: Job = .{
        .pixels = pixels,
        .source_pixels = null,
        .width = width,
        .height = height,
        .grid_x = 0,
        .grid_y = 0,
        .grid_width = width,
        .grid_height = height,
        .age = 1,
        .generation = 1,
        .focused = true,
        .hyperlink_hints = false,
        .link_range = null,
        .search_range = null,
        .search_matches = &.{},
        .search_background = .{ .r = 1, .g = 2, .b = 3 },
        .search_foreground = .{ .r = 4, .g = 5, .b = 6 },
        .preedit = null,
        .link_hint = null,
        .search = null,
        .search_no_match = false,
        .scrollbar = null,
        .tab_bar = null,
        .tab_bar_height = 0,
        .kitty_items = &.{},
        .overlay_dirty = false,
        .scroll_shift = null,
        .repair = .none,
    };

    var damage: Damage = .none;
    try raster.renderJob(job, &damage);
    try std.testing.expectEqual(Damage.full, damage);

    for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
    state.row_data.items(.dirty)[0] = true;
    state.dirty = .partial;
    damage = .full;
    try raster.renderJob(job, &damage);

    try std.testing.expectEqual(Damage.none, damage);
    try std.testing.expectEqual(@as(usize, 0), raster.renderer.rendered_rects.items.len);
}

test "tab bar and cursor damage match full rendering across stale buffers" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 12, .rows = 4 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?25lfirst\r\nsecond\r\nthird\r\nfourth");
    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    var font: Font = try .init(alloc, "monospace", 16, null);
    defer font.deinit(alloc);
    const selection: vt.color.RGB = .{ .r = 1, .g = 2, .b = 3 };
    var raster = try AsyncRaster.init(font.discovery(), selection, null, null, null, 255, false, &state);
    defer raster.deinit();
    var reference = try AsyncRaster.init(font.discovery(), selection, null, null, null, 255, false, &state);
    defer reference.deinit();
    const cw = font.cell_width;
    const ch = font.cell_height;
    const width = cw * 12 + 8;
    const height = ch * 5 + 7;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    const stale = try alloc.alloc(u32, pixels.len);
    defer alloc.free(stale);
    var job: Job = .{
        .pixels = pixels,
        .source_pixels = null,
        .width = width,
        .height = height,
        .grid_x = 3,
        .grid_y = ch + 3,
        .grid_width = cw * 12,
        .grid_height = ch * 4,
        .age = 1,
        .generation = 1,
        .focused = true,
        .hyperlink_hints = false,
        .link_range = null,
        .search_range = null,
        .search_matches = &.{},
        .search_background = selection,
        .search_foreground = selection,
        .preedit = null,
        .link_hint = null,
        .search = null,
        .search_no_match = false,
        .scrollbar = null,
        .tab_bar = &.{.{ .title = "long title", .active = true }},
        .tab_bar_height = ch,
        .tab_bar_position = .top,
        .kitty_items = &.{},
        .overlay_dirty = false,
        .scroll_shift = null,
        .repair = .none,
    };
    var damage: Damage = .none;
    try raster.renderJob(job, &damage);
    try std.testing.expectEqual(Damage.full, damage);
    @memcpy(stale, pixels);

    // A cell edit with no animated cursor preserves the tab strip and only
    // damages grid pixels, including the grid's nonzero surface offset.
    clearTestDirty(&state);
    stream.nextSlice("\x1b[2;3HX");
    try state.update(alloc, &term);
    try raster.renderJob(job, &damage);
    try std.testing.expectEqual(Damage.partial, damage);
    try std.testing.expectEqualSlices(u32, stale[0 .. @as(usize, ch) * width], pixels[0 .. @as(usize, ch) * width]);
    var rects: std.ArrayList(Renderer.PixelRect) = .empty;
    defer rects.deinit(alloc);
    try raster.copySurfaceDamageRects(alloc, &rects);
    try std.testing.expect(rects.items.len > 0);
    for (rects.items) |rect| {
        try std.testing.expect(rect.x >= job.grid_x);
        try std.testing.expect(rect.y >= job.grid_y);
    }
    try expectFullFrame(&reference, job);

    // Shortening a title clears the old suffix without rasterizing any row.
    @memcpy(stale, pixels);
    clearTestDirty(&state);
    job.tab_bar = &.{.{ .title = "A", .active = false }};
    job.tab_bar_dirty = true;
    try raster.renderJob(job, &damage);
    try std.testing.expectEqual(Damage.partial, damage);
    try std.testing.expectEqual(@as(usize, 0), raster.renderer.rendered_rects.items.len);
    try raster.copySurfaceDamageRects(alloc, &rects);
    try std.testing.expectEqualSlices(Renderer.PixelRect, &.{.{ .x = 0, .y = 0, .width = width, .height = ch }}, rects.items);
    try expectFullFrame(&reference, job);

    // The damage ring must keep strip coordinates in surface space when a
    // rotating shm buffer missed this title update.
    const FrameDamageTracker = @import("FrameDamageTracker.zig");
    var tracker: FrameDamageTracker = .init(alloc);
    defer tracker.deinit();
    const geometry: FrameDamageTracker.Geometry = .{
        .width = width,
        .height = height,
        .grid_x = job.grid_x,
        .grid_y = job.grid_y,
        .grid_width = job.grid_width,
        .grid_height = job.grid_height,
        .cell_width = cw,
        .cell_height = ch,
    };
    tracker.begin(geometry);
    try tracker.record(&raster, damage);
    const repair = try tracker.planRepair(2, false, geometry);
    try std.testing.expectEqualSlices(RepairRect, rects.items, repair.rects);
    var repair_job = job;
    repair_job.pixels = stale;
    repair_job.source_pixels = pixels;
    repair_job.tab_bar_dirty = false;
    repair_job.repair = repair;
    try raster.renderJob(repair_job, &damage);
    try std.testing.expectEqual(Damage.none, damage);
    try std.testing.expectEqualSlices(u32, pixels, stale);

    // A simultaneous title update and moving cursor must repaint both areas.
    clearTestDirty(&state);
    stream.nextSlice("\x1b[?25h\x1b[4;7H");
    try state.update(alloc, &term);
    job.tab_bar = &.{.{ .title = "B", .active = true }};
    job.cursor_overlay = .{ .shape = .block, .corners = .{
        .{ @intCast(cw), @intCast(ch) },
        .{ @intCast(cw * 2), @intCast(ch) },
        .{ @intCast(cw * 2), @intCast(ch * 2) },
        .{ @intCast(cw), @intCast(ch * 2) },
    } };
    try raster.renderJob(job, &damage);
    try std.testing.expectEqual(Damage.partial, damage);
    try std.testing.expect(raster.tab_bar_damage != null);
    try expectFullFrame(&reference, job);

    // When the overlay disappears, erase its old row as well as restoring
    // the native cursor at its destination, which is on a different row.
    clearTestDirty(&state);
    state.row_data.items(.dirty)[3] = true;
    state.dirty = .partial;
    job.cursor_overlay = null;
    job.tab_bar_dirty = false;
    try raster.renderJob(job, &damage);
    try std.testing.expectEqual(Damage.partial, damage);
    try std.testing.expect(raster.renderer.last_cursor_quad == null);
    try expectFullFrame(&reference, job);
}

test "tab bar renders along the bottom edge" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 12, .rows = 4 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    var font: Font = try .init(alloc, "monospace", 16, null);
    defer font.deinit(alloc);
    const selection: vt.color.RGB = .{ .r = 1, .g = 2, .b = 3 };
    var raster = try AsyncRaster.init(font.discovery(), selection, null, null, null, 255, false, &state);
    defer raster.deinit();
    var reference = try AsyncRaster.init(font.discovery(), selection, null, null, null, 255, false, &state);
    defer reference.deinit();
    const cw = font.cell_width;
    const ch = font.cell_height;
    const width = cw * 12 + 8;
    const height = ch * 5 + 7;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    var job: Job = .{
        .pixels = pixels,
        .source_pixels = null,
        .width = width,
        .height = height,
        .grid_x = 3,
        .grid_y = 3,
        .grid_width = cw * 12,
        .grid_height = ch * 4,
        .age = 1,
        .generation = 1,
        .focused = true,
        .hyperlink_hints = false,
        .link_range = null,
        .search_range = null,
        .search_matches = &.{},
        .search_background = selection,
        .search_foreground = selection,
        .preedit = null,
        .link_hint = null,
        .search = null,
        .search_no_match = false,
        .scrollbar = null,
        .tab_bar = &.{.{ .title = "long title", .active = true }},
        .tab_bar_height = ch,
        .tab_bar_position = .bottom,
        .kitty_items = &.{},
        .overlay_dirty = false,
        .scroll_shift = null,
        .repair = .none,
    };
    var damage: Damage = .none;
    try raster.renderJob(job, &damage);
    try std.testing.expectEqual(Damage.full, damage);
    try expectFullFrame(&reference, job);

    // A title update repaints only the bottom strip, in surface coordinates.
    clearTestDirty(&state);
    job.tab_bar = &.{.{ .title = "A", .active = false }};
    job.tab_bar_dirty = true;
    try raster.renderJob(job, &damage);
    try std.testing.expectEqual(Damage.partial, damage);
    var rects: std.ArrayList(Renderer.PixelRect) = .empty;
    defer rects.deinit(alloc);
    try raster.copySurfaceDamageRects(alloc, &rects);
    const bar_top: u31 = height - ch;
    try std.testing.expectEqualSlices(Renderer.PixelRect, &.{.{ .x = 0, .y = bar_top, .width = width, .height = ch }}, rects.items);
    try expectFullFrame(&reference, job);
}

fn clearTestDirty(state: *vt.RenderState) void {
    for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
    state.dirty = .false;
}

fn expectFullFrame(reference: *AsyncRaster, job: Job) !void {
    const pixels = try std.testing.allocator.alloc(u32, job.pixels.len);
    defer std.testing.allocator.free(pixels);
    var full_job = job;
    full_job.pixels = pixels;
    full_job.source_pixels = null;
    full_job.repair = .none;
    const previous_dirty = reference.state.dirty;
    defer reference.state.dirty = previous_dirty;
    reference.state.dirty = .full;
    var damage: Damage = .none;
    try reference.renderJob(full_job, &damage);
    try std.testing.expectEqual(Damage.full, damage);
    try std.testing.expectEqualSlices(u32, pixels, job.pixels);
}

test "primary and alternate screen scroll pixels match full repaint" {
    const ScrollDetector = @import("ScrollDetector.zig");
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |stale| {
        for ([_]?Config.MetricModifier{ null, .{ .percent = -25 } }) |cell_height| {
            for ([_][]const u8{ "", "\x1b[?1049h" }) |screen| {
                for ([_]isize{ 1, -1 }) |shift| {
                    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 12, .rows = 4 });
                    defer term.deinit(alloc);
                    var stream = term.vtStream();
                    defer stream.deinit();
                    stream.nextSlice(screen);
                    stream.nextSlice("Ågj\r\n\x1b[31msecond\r\n\x1b[32mc\u{301}\r\npq");
                    var state: vt.RenderState = .empty;
                    defer state.deinit(alloc);
                    try state.update(alloc, &term);
                    var font: Font = try .init(alloc, "DejaVu Sans Mono", 16, cell_height);
                    defer font.deinit(alloc);
                    var raster = try AsyncRaster.init(font.discovery(), .{ .r = 1, .g = 2, .b = 3 }, null, null, null, 255, false, &state);
                    defer raster.deinit();
                    const width = font.cell_width * 12;
                    const height = font.cell_height * 4;
                    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
                    defer alloc.free(pixels);
                    const previous = try alloc.alloc(u32, pixels.len);
                    defer alloc.free(previous);
                    const expected = try alloc.alloc(u32, pixels.len);
                    defer alloc.free(expected);
                    var job: Job = .{
                        .pixels = pixels,
                        .source_pixels = null,
                        .width = width,
                        .height = height,
                        .grid_x = 0,
                        .grid_y = 0,
                        .grid_width = width,
                        .grid_height = height,
                        .age = 1,
                        .generation = 1,
                        .focused = true,
                        .hyperlink_hints = false,
                        .link_range = null,
                        .search_range = null,
                        .search_matches = &.{},
                        .search_background = .{ .r = 1, .g = 2, .b = 3 },
                        .search_foreground = .{ .r = 4, .g = 5, .b = 6 },
                        .preedit = null,
                        .link_hint = null,
                        .search = null,
                        .search_no_match = false,
                        .scrollbar = null,
                        .tab_bar = null,
                        .tab_bar_height = 0,
                        .kitty_items = &.{},
                        .overlay_dirty = false,
                        .scroll_shift = null,
                        .repair = .none,
                    };
                    var damage: Damage = .none;
                    try raster.renderJob(job, &damage);
                    @memcpy(previous, pixels);
                    for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
                    state.dirty = .false;
                    const old_cursor = state.cursor;
                    stream.nextSlice(if (shift > 0) "\r\nnew" else "\x1b[T\x1b[1;1Hnew");
                    var detector: ScrollDetector = .{};
                    defer detector.deinit(alloc);
                    const scroll = (try detector.detect(alloc, &state, &term)).?;
                    try state.update(alloc, &term);
                    detector.prepare(&state, scroll, old_cursor);
                    job.scroll_shift = scroll.shift;
                    if (stale) {
                        @memset(pixels, 0x1234);
                        job.age = 2;
                        job.source_pixels = previous;
                    }
                    try raster.renderJob(job, &damage);
                    try std.testing.expectEqual(cell_height == null, raster.renderer.cellDamageStats().dirty_rows > 0);
                    var reference: Renderer = try .init(alloc, &font, .{});
                    defer reference.deinit();
                    try reference.render(&state, expected, width, height);
                    try std.testing.expectEqualSlices(u32, expected, pixels);
                }
            }
        }
    }
}

test "repair previous frame" {
    var target = [_]u32{ 1, 2, 3, 4 };
    const source = [_]u32{ 5, 6, 7, 8 };
    const base: Job = .{
        .pixels = &target,
        .source_pixels = &source,
        .width = 2,
        .height = 2,
        .grid_x = 0,
        .grid_y = 0,
        .grid_width = 2,
        .grid_height = 2,
        .age = 0,
        .generation = 1,
        .focused = true,
        .hyperlink_hints = false,
        .link_range = null,
        .search_range = null,
        .search_matches = &.{},
        .search_background = .{ .r = 1, .g = 2, .b = 3 },
        .search_foreground = .{ .r = 4, .g = 5, .b = 6 },
        .preedit = null,
        .link_hint = null,
        .search = null,
        .search_no_match = false,
        .scrollbar = null,
        .tab_bar = null,
        .tab_bar_height = 0,
        .kitty_items = &.{},
        .overlay_dirty = false,
        .scroll_shift = null,
        .repair = .full,
    };

    try std.testing.expect(repairToPreviousFrame(base));
    try std.testing.expectEqualSlices(u32, &source, &target);

    target = .{ 1, 2, 3, 4 };
    var current = base;
    current.source_pixels = null;
    current.age = 1;
    current.repair = .none;
    try std.testing.expect(repairToPreviousFrame(current));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &target);

    const rects = [_]RepairRect{.{ .x = 1, .y = 1, .width = 1, .height = 1 }};
    current = base;
    current.repair = .{ .rects = &rects };
    try std.testing.expect(repairToPreviousFrame(current));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 8 }, &target);

    target = .{ 1, 2, 3, 4 };
    current.repair = .{ .rects = &.{} };
    try std.testing.expect(repairToPreviousFrame(current));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &target);

    const invalid_rects = [_]RepairRect{
        .{ .x = 0, .y = 0, .width = 2, .height = 1 },
        .{ .x = 0, .y = 2, .width = 2, .height = 1 },
    };
    current.repair = .{ .rects = &invalid_rects };
    try std.testing.expect(!repairToPreviousFrame(current));

    current.source_pixels = null;
    current.age = 0;
    current.repair = .full;
    try std.testing.expect(!repairToPreviousFrame(current));
}

test "scroll previous frame in place and from distinct source" {
    var pixels = [_]u32{
        0,  1,  2,
        3,  4,  5,
        6,  7,  8,
        9,  10, 11,
        12, 13, 14,
    };
    var job: Job = .{
        .pixels = &pixels,
        .source_pixels = null,
        .width = 3,
        .height = 5,
        .grid_x = 0,
        .grid_y = 1,
        .grid_width = 3,
        .grid_height = 3,
        .age = 1,
        .generation = 1,
        .focused = true,
        .hyperlink_hints = false,
        .link_range = null,
        .search_range = null,
        .search_matches = &.{},
        .search_background = .{ .r = 1, .g = 2, .b = 3 },
        .search_foreground = .{ .r = 4, .g = 5, .b = 6 },
        .preedit = null,
        .link_hint = null,
        .search = null,
        .search_no_match = false,
        .scrollbar = null,
        .tab_bar = null,
        .tab_bar_height = 0,
        .kitty_items = &.{},
        .overlay_dirty = false,
        .scroll_shift = 1,
        .repair = .none,
    };

    try std.testing.expect(scrollFromPreviousFrame(job, 1, 1));
    try std.testing.expectEqualSlices(u32, &.{ 6, 7, 8, 9, 10, 11 }, pixels[3..9]);
    // The newly exposed row is deliberately untouched for renderDirty.
    try std.testing.expectEqualSlices(u32, &.{ 9, 10, 11 }, pixels[9..12]);

    const source = [_]u32{
        20, 21, 22,
        23, 24, 25,
        26, 27, 28,
        29, 30, 31,
        32, 33, 34,
    };
    @memset(&pixels, 99);
    job.age = 0;
    job.source_pixels = &source;
    try std.testing.expect(scrollFromPreviousFrame(job, -1, 1));
    try std.testing.expectEqualSlices(u32, &.{ 23, 24, 25, 26, 27, 28 }, pixels[6..12]);
    try std.testing.expectEqualSlices(u32, &.{ 99, 99, 99 }, pixels[3..6]);

    job.source_pixels = null;
    try std.testing.expect(!scrollFromPreviousFrame(job, 1, 1));
    try std.testing.expect(!scrollFromPreviousFrame(job, 3, 1));
}
