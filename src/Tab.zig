//! One terminal session inside a Monstar window.
//!
//! A `Tab` owns exactly one `vt.Terminal`, its pty, and the two-stage
//! read pipeline that drains the pty into the terminal. The owning `App`
//! keeps a list of tabs and renders only the active one; a tab that is not
//! active still drains its pty and keeps its terminal up to date so it is
//! current when the user switches to it.

const Tab = @This();

const std = @import("std");
const posix = std.posix;
const vt = @import("ghostty-vt");
const App = @import("App.zig");
const Config = @import("Config.zig");
const Pty = @import("Pty.zig");
const ReadPipeline = @import("ReadPipeline.zig");
const ScrollbackSearch = @import("ScrollbackSearch.zig");
const KittyImageCache = @import("KittyImageCache.zig");
const KittyClipboard = @import("KittyClipboard.zig");

const log = std.log.scoped(.tab);

// Includes headroom for base64 framing of a maximum-sized clipboard read.
pub const max_pty_write_queue = 4 * 1024 * 1024;

/// The directory for kitty t=t temporary-file transmissions, resolved
/// like Ghostty: $TMPDIR, then $TMP, then /tmp. Returned slices point
/// into the process environment and stay valid for its lifetime.
fn tmpDirPath(environ: std.process.Environ) []const u8 {
    const dir = environ.getPosix("TMPDIR") orelse
        environ.getPosix("TMP") orelse
        return "/tmp";
    return std.mem.trimEnd(u8, dir, &.{std.fs.path.sep});
}

/// Owned session state for a single tab. The terminal is the source of
/// truth for content; `render_state` is derived from it in App.
alloc: std.mem.Allocator,
/// Stable identity used by App's asynchronous clipboard broker.
id: u64,
io: std.Io,
app: *App,
term: vt.Terminal,
stream: App.AppStream,
pty: Pty,
pipeline: ReadPipeline,
child_pid: posix.pid_t,
child_exited: bool,
/// PTY input that could not be written yet (master is nonblocking).
write_queue: std.ArrayList(u8),
write_queue_offset: usize = 0,
/// Native incremental scrollback search for this tab.
search: ?ScrollbackSearch,
/// Pinned copies of kitty image data shared between consecutive async jobs.
kitty_cache: KittyImageCache,
/// OSC 5522 transaction state belongs to this terminal session.
kitty_clipboard: KittyClipboard,
/// Cached DEC mode 2048 state, to detect the application enabling
/// in-band size reports.
in_band_reports: bool,
/// Per-session DEC 2026 timeout in monotonic nanoseconds; null outside a batch.
sync_output_deadline_ns: ?u64 = null,
/// True after OSC 22 explicitly set the pointer shape.
mouse_shape_explicit: bool,
/// Active screen at the last check, to detect alt screen switches.
active_screen: vt.ScreenSet.Key,

pub const InitOptions = struct {
    cols: u16,
    rows: u16,
    cell_width: u31,
    cell_height: u31,
    color_scheme: vt.device_status.ColorScheme = .dark,
    working_directory: ?[:0]const u8 = null,
    /// Hold the child just before exec until `releaseChild` is called
    /// (used to move it into a cgroup before it can spawn grandchildren).
    gate_child: bool = false,
};

/// Creates a tab: opens a pty, spawns the session child, initializes the
/// terminal, and starts the read pipeline. `path`/`argv`/`envp` must stay
/// valid for the lifetime of the call (the child copies them via execve).
/// Returns a tab whose child is still gated when `gate_child` is set; the
/// caller must call `releaseChild` once any child-scope migration is done
/// or abandoned (also covered by `deinit`).
pub fn init(
    alloc: std.mem.Allocator,
    io: std.Io,
    app: *App,
    id: u64,
    config: Config,
    environ: std.process.Environ,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    options: InitOptions,
) !*Tab {
    var term: vt.Terminal = try .init(io, alloc, .{
        .cols = options.cols,
        .rows = options.rows,
        .max_scrollback_bytes = config.scrollback_limit,
        .colors = config.terminalColors(options.color_scheme),
        .default_modes = .{ .grapheme_cluster = true },
        // libghostty-vt defaults to a conservative 10MB, which rejects a
        // single fullscreen image on large displays (a 4K RGBA frame is
        // ~32MB). Default matches the Ghostty app (320MB).
        .kitty_image_storage_limit = config.image_storage_limit,
        // Accept every kitty transmission medium, matching the Ghostty
        // app. t=s shared memory matters most for throughput.
        .kitty_image_loading_limits = .allWithTempDir(tmpDirPath(environ)),
    });
    errdefer term.deinit(alloc);
    try term.resize(alloc, .{
        .cols = options.cols,
        .rows = options.rows,
        .cell_size_px = .{
            .width = options.cell_width,
            .height = options.cell_height,
        },
    });

    var pty: Pty = try .open(.{
        .row = options.rows,
        .col = options.cols,
        .xpixel = @intCast(options.cols * options.cell_width),
        .ypixel = @intCast(options.rows * options.cell_height),
    });
    errdefer pty.deinit();

    const child_pid = try pty.spawn(path, argv, envp, .{
        .cwd = if (options.working_directory) |cwd| cwd.ptr else null,
        .gate_child = options.gate_child,
    });

    // Nonblocking master: a blocking write can deadlock the whole loop
    // when the child floods output while we respond to queries embedded in
    // that output.
    setNonblocking(pty.master);

    const self = try alloc.create(Tab);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .io = io,
        .app = app,
        .id = id,
        .term = term,
        .stream = undefined,
        .pty = pty,
        .pipeline = try .init(pty.master),
        .child_pid = child_pid,
        .child_exited = false,
        .write_queue = .empty,
        .search = null,
        .kitty_cache = .empty,
        .kitty_clipboard = .init(alloc),
        .in_band_reports = false,
        .mouse_shape_explicit = false,
        .active_screen = .primary,
    };
    errdefer self.pipeline.deinit();

    self.stream = .init(.{
        .allocator = alloc,
        .handler = .{
            .app = self.app,
            .tab = self,
            .terminal_handler = .init(&self.term),
        },
    });
    self.stream.handler.terminal_handler.terminfo_name = "monstar";
    return self;
}

/// The child has exited and been reaped.
pub fn childExited(self: *Tab) bool {
    return self.child_exited;
}

/// Apply window configuration while preserving this session's OSC overrides.
/// Scrollback capacity is startup-only; graphics limits update every screen.
pub fn applyConfig(self: *Tab, config: Config, color_scheme: vt.device_status.ColorScheme) void {
    const colors = config.terminalColors(color_scheme);
    self.term.colors.background.default = colors.background.default;
    self.term.colors.foreground.default = colors.foreground.default;
    self.term.colors.cursor.default = colors.cursor.default;
    self.term.colors.palette.changeDefault(colors.palette.original);
    var screens = self.term.screens.all.iterator();
    while (screens.next()) |entry| {
        if (entry.value.*.kitty_images.total_limit == config.image_storage_limit) continue;
        self.term.setKittyGraphicsSizeLimit(self.alloc, config.image_storage_limit);
        break;
    }
}

/// Observe a DEC 2026 boundary without extending an existing batch's deadline.
pub fn syncSynchronizedOutput(self: *Tab, now_ns: u64, timeout_ns: u64) bool {
    const enabled = self.term.modes.get(.synchronized_output);
    if (enabled == (self.sync_output_deadline_ns != null)) return false;
    self.sync_output_deadline_ns = if (enabled) now_ns +| timeout_ns else null;
    return true;
}

/// End only this session's expired synchronized-output batch.
pub fn expireSynchronizedOutput(self: *Tab, now_ns: u64) bool {
    const deadline = self.sync_output_deadline_ns orelse return false;
    if (now_ns < deadline) return false;
    self.term.modes.set(.synchronized_output, false);
    self.sync_output_deadline_ns = null;
    return true;
}

/// Reap the session child if it has exited; returns true once.
pub fn tryWait(self: *Tab) !bool {
    if (self.child_exited) return false;
    if (try Pty.tryWait(self.child_pid)) |status| {
        log.debug("child exited with status {d}", .{status});
        self.child_exited = true;
        return true;
    }
    return false;
}

pub fn deinit(self: *Tab) void {
    // Stop and join the gather thread before the master closes.
    self.pipeline.stop();
    if (self.child_exited) {
        self.pipeline.deinit();
    } else {
        self.pty.closeMaster();
        _ = std.os.linux.kill(self.child_pid, std.os.linux.SIG.HUP);
        self.pipeline.deinit();
    }
    self.pty.deinit();
    if (self.search) |*search| search.deinit(self.alloc, &self.term);
    self.kitty_cache.deinit(self.alloc);
    self.kitty_clipboard.deinit();
    self.write_queue.deinit(self.alloc);
    self.stream.deinit();
    self.term.deinit(self.alloc);
    self.alloc.destroy(self);
}

/// Release a gated child (see InitOptions.gate_child) once any child-scope
/// migration is complete or abandoned.
pub fn releaseChild(self: *Tab) void {
    self.pty.releaseChild();
}

/// Stop this tab's read pipeline and hang up its child, without deallocating
/// the terminal state. Used on shutdown and when closing a tab.
pub fn hangup(self: *Tab) void {
    self.pipeline.stop();
    if (self.child_exited) return;
    self.pty.closeMaster();
    _ = std.os.linux.kill(self.child_pid, std.os.linux.SIG.HUP);
}

/// Start this tab's read pipeline (called once from the App event loop).
pub fn start(self: *Tab) !void {
    try self.pipeline.start();
}

/// Drain one ready batch from this tab's pipeline into its terminal.
/// Returns the count of batches consumed; 0 when the pipeline is idle.
pub fn drain(self: *Tab) !usize {
    self.pipeline.clearReady();
    var consumed: usize = 0;
    for (0..ReadPipeline.buffer_count) |_| {
        const batch = self.pipeline.take() orelse break;
        self.stream.nextSlice(batch);
        self.pipeline.release();
        consumed += 1;
    }
    self.pipeline.rearm();
    if (self.pipeline.hasFailed()) return error.PtyReadFailed;
    return consumed;
}

/// Accept the entire write or drop it before emitting any bytes. Reserve the
/// possible backlog first so neither backpressure nor OOM truncates a reply.
pub fn writePty(self: *Tab, bytes: []const u8) void {
    std.debug.assert(self.write_queue_offset <= self.write_queue.items.len);
    const pending = self.write_queue.items.len - self.write_queue_offset;
    if (bytes.len > max_pty_write_queue -| pending) {
        log.warn("pty write queue full; dropping complete write ({d} bytes)", .{bytes.len});
        return;
    }
    // Only move the tail when at least as many bytes have been consumed.
    // Otherwise grow: compacting after every small drain would be quadratic.
    if (self.write_queue.capacity - self.write_queue.items.len < bytes.len and
        self.write_queue_offset >= pending)
    {
        std.mem.copyForwards(u8, self.write_queue.items[0..pending], self.write_queue.items[self.write_queue_offset..]);
        self.write_queue.items.len = pending;
        self.write_queue_offset = 0;
    }
    self.write_queue.ensureUnusedCapacity(self.alloc, bytes.len) catch |err| {
        log.warn("pty write queue reserve failed: {}", .{err});
        return;
    };
    // A backlog exists; keep ordering by appending behind it.
    if (pending > 0) {
        self.write_queue.appendSliceAssumeCapacity(bytes);
        return;
    }
    const written = self.tryPtyWrite(bytes);
    self.write_queue.appendSliceAssumeCapacity(bytes[written..]);
}

/// Drain the backlog after the master polled writable.
pub fn flushWriteQueue(self: *Tab) void {
    self.write_queue_offset += self.tryPtyWrite(self.write_queue.items[self.write_queue_offset..]);
    if (self.write_queue_offset == self.write_queue.items.len) {
        self.write_queue.clearRetainingCapacity();
        self.write_queue_offset = 0;
    }
}

/// Write as much as the kernel accepts; returns the number of bytes
/// consumed. Never blocks.
fn tryPtyWrite(self: *Tab, bytes: []const u8) usize {
    const linux = std.os.linux;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(self.pty.master, bytes.ptr + offset, bytes.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => offset += rc,
            .INTR => continue,
            .AGAIN => break,
            // EIO: child gone; the read side notices and shuts down.
            .IO => break,
            else => |err| {
                log.err("pty write failed: {}", .{err});
                break;
            },
        }
    }
    return offset;
}

fn setNonblocking(fd: posix.fd_t) void {
    const linux = std.os.linux;
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return;
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

/// Resize this tab's terminal and pty to the given grid.
pub fn resize(self: *Tab, alloc: std.mem.Allocator, cols: u16, rows: u16, cell_width: u31, cell_height: u31) !void {
    try self.term.resize(alloc, .{
        .cols = cols,
        .rows = rows,
        .cell_size_px = .{
            .width = cell_width,
            .height = cell_height,
        },
    });
    try self.pty.setWinsize(.{
        .row = rows,
        .col = cols,
        .xpixel = @intCast(cols * cell_width),
        .ypixel = @intCast(rows * cell_height),
    });
}
