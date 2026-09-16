//! The live terminal application: owns the terminal state, PTY, renderer,
//! and window, and runs the event loop that ties them together.
//!
//! The loop polls the Wayland display and the read pipeline's ready
//! eventfd (a gather thread drains the PTY master concurrently). PTY
//! output feeds the terminal and schedules a redraw; redraws are throttled
//! by the window's frame callbacks.

const App = @This();

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const c = @import("c");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const vt = @import("ghostty-vt");
const Clipboard = @import("Clipboard.zig");
const KittyClipboard = @import("KittyClipboard.zig");
const Config = @import("Config.zig");
const CursorAnimator = @import("CursorAnimator.zig");
const keybind = @import("keybind.zig");
const Font = @import("Font.zig");
const Keyboard = @import("Keyboard.zig");
const Link = @import("Link.zig");
const Pty = @import("Pty.zig");
const ReadPipeline = @import("ReadPipeline.zig");
const Renderer = @import("Renderer.zig");
const AsyncRaster = @import("AsyncRaster.zig");
const AsyncJobSnapshot = @import("AsyncJobSnapshot.zig");
const FrameDamageTracker = @import("FrameDamageTracker.zig");
const KittyImageCache = @import("KittyImageCache.zig");
const ScrollbackSearch = @import("ScrollbackSearch.zig");
const ScrollDetector = @import("ScrollDetector.zig");
const Tab = @import("Tab.zig");
const TerminalLayout = @import("TerminalLayout.zig");
const cgroup = @import("cgroup.zig");
const DbusConnection = @import("dbus/Connection.zig");

/// Type of the session-bus connection handle. Collapses to `void` when
/// D-Bus support is compiled out (`-Ddbus=false`), so the `dbus` field
/// below always has a valid, zero-cost type regardless of the option.
const DbusHandle = if (build_options.enable_dbus) ?DbusConnection else void;
const no_dbus: DbusHandle = if (build_options.enable_dbus) null else {};
const clipboard_format = @import("clipboard_format.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.app);

const HoveredLink = struct {
    uri: []u8,
    range: ?Renderer.LinkRange,
};

const LinkAction = enum { open, copy };

const LinkPress = struct {
    uri: []u8,
    cell: vt.Coordinate,
    button: u32,
    action: LinkAction,
};

const PendingDbus = struct {
    serial: u32,
    deadline_ns: i96,
    kind: Kind,

    const Kind = union(enum) {
        notification,
        color_scheme,
        reduced_motion,
        open_uri: struct { uri: []u8, token: ?[:0]u8 },

        fn deinit(kind: Kind, alloc: std.mem.Allocator) void {
            if (kind == .open_uri) {
                alloc.free(kind.open_uri.uri);
                if (kind.open_uri.token) |token| alloc.free(token);
            }
        }
    };
};

alloc: std.mem.Allocator,
io: std.Io,
config_arena: std.heap.ArenaAllocator,
config: Config,
config_path: ?[:0]const u8,
config_overrides: []const []const u8,
environ: std.process.Environ,
tabs: std.ArrayList(*Tab),
active: *Tab,
/// The single terminal snapshot both render paths draw from. Updated
/// only on the main thread while no render target is checked out, so
/// the async worker can read it without locks while a job is in flight.
render_state: vt.RenderState,
/// Main-thread scratch for recognizing viewport movement before
/// RenderState.update consumes Ghostty's row dirtiness.
scroll_detector: ScrollDetector,
async_raster: ?AsyncRaster,
async_raster_loader: ?AsyncRaster.Loader,
async_generation: u64,
/// The next async snapshot must be rebuilt completely because renderer-only
/// state changed or a prior snapshot was rendered but not committed.
async_force_full: bool,
/// A finished async frame whose buffer is checked out, waiting for the
/// outstanding frame callback before it can be committed. While held,
/// `window.rendering_pending` stays true so no new render can start.
held_frame: ?*Window.Buffer,
/// Owned overlay and Kitty inputs for the in-flight async job.
async_job: AsyncJobSnapshot,
/// The window geometry changed, so a repaint at the new size must
/// happen even while synchronized output has content frames frozen.
geometry_redraw: bool,
frame_damage: FrameDamageTracker,
font: Font,
/// The physical pixel size the font is currently loaded at.
font_size_px: f64,
/// Runtime-only size override from keyboard shortcuts, preserving the
/// configured point or logical-pixel unit.
runtime_font_size: ?Config.FontSize,
/// Current physical grid rectangle and effective padding.
layout: TerminalLayout,
/// Vertical extent of the tab-bar strip at the top of the surface, in
/// pixels. The terminal grid is laid out below it.
tab_bar_height: u31,
/// Selection highlight colors, from config or OSC 17/19. Snapshotted
/// into the raster worker's renderer on (re)configure.
selection_bg: vt.color.RGB,
selection_fg: ?vt.color.RGB,
selection_bg_override: ?vt.color.RGB,
selection_fg_override: ?vt.color.RGB,
/// Background used briefly after the current selection is copied.
copy_highlight: vt.color.RGB,
copy_highlight_fg: vt.color.RGB,
copy_highlight_active: bool,
/// Configured cursor fill when OSC 12 has not set a VT cursor color.
cursor_color: Config.TerminalColor,
/// Configured text color beneath a focused block cursor.
cursor_text: ?Config.TerminalColor,
/// Neovide-style animated cursor. Owns the gliding corners; a non-settled
/// animator repaints the cursor overlay in lockstep with the compositor.
cursor_anim: CursorAnimator.Animator = undefined,
/// False until the first recognized cursor destination has been seeded.
cursor_anim_ready: bool = false,
/// True while the cursor quad is in motion; detects the settle handoff
/// back to the native cell cursor so that cell repaints in cursor colors.
cursor_anim_moving: bool = false,
/// Monotonic time (ns) of the previous cursor-animation advance, for dt.
cursor_anim_last_ns: u64 = 0,
window: *Window,
keyboard: Keyboard,
/// Terminal contents changed since the last committed frame.
needs_redraw: bool,
/// Keyboard focus state; unfocused windows draw a hollow cursor.
focused: bool,
ime_focused: bool,
ime_preedit: ?[]u8,
ime_pending_preedit: ?[]u8,
ime_pending_commit: ?[]u8,
/// Keep the window open after the last child exits.
hold: bool,
/// Session command reused to spawn each new tab.
child_path: [*:0]const u8,
child_argv: [*:null]const ?[*:0]const u8,
child_envp: [*:null]const ?[*:0]const u8,
working_directory: ?[:0]const u8,
/// Closed tabs awaiting child reaping or whose kitty image cache is still
/// borrowed by an in-flight async snapshot. A manually closed tab must retain
/// its child PID until wait4 reaps it; otherwise the exited child remains a
/// zombie until Monstar itself exits.
pending_tab_cleanup: std.ArrayList(*Tab) = .empty,
/// Session bus connection, used for notifications and future desktop settings.
/// `void` when built with `-Ddbus=false`.
dbus: DbusHandle,
dbus_fd: posix.fd_t,
pending_dbus: std.ArrayList(PendingDbus) = .empty,
/// URI held while the compositor creates a token for activating its handler.
pending_open_uri: ?[]u8,
/// A null value means the notification is awaiting its activation token.
notifications: std.AutoHashMapUnmanaged(u32, ?[]u8),
color_scheme: vt.device_status.ColorScheme,
/// Standardized XDG desktop preference; scrollbar dismissal snaps instead
/// of fading when motion should be reduced.
reduced_motion: bool,
/// signalfd for process-local signals, polled in the event loop.
signal_fd: posix.fd_t,
/// Key repeat: timerfd armed while a repeating key is held.
repeat_fd: posix.fd_t,
repeat_keycode: ?u32,
/// From wl_keyboard.repeat_info: characters per second and delay in ms.
repeat_rate: i32,
repeat_delay: i32,
/// Kinetic touchpad scrolling after a finger-axis sequence stops.
fling_fd: posix.fd_t,
fling_active: bool,
fling_velocity: f64,
scroll_velocity: f64,
last_scroll_time_ms: ?u32,
/// Safety timer for DEC mode 2026 synchronized output.
sync_output_fd: posix.fd_t,
/// Timer for ghostty-vt selection autoscroll while dragging past an edge.
selection_autoscroll_fd: posix.fd_t,
/// One-shot timer restoring the normal selection color after a copy.
copy_highlight_fd: posix.fd_t,
/// One-shot timer that clears stale OSC 9;4 taskbar progress.
taskbar_progress_fd: posix.fd_t,
/// Drives bounded libghostty search work without blocking the event loop.
search_fd: posix.fd_t,
/// One-shot visibility delay followed by periodic scrollbar fade ticks.
scrollbar_fd: posix.fd_t,
/// One-shot wake for the next libghostty Kitty animation frame.
kitty_animation_fd: posix.fd_t,
/// Idle scheduler for incremental cold scrollback compression.
compression_fd: posix.fd_t,
compression_activity: u64,
scrollbar_alpha: u8,
scrollbar_fading: bool,
scrollbar_fade_elapsed_ms: u16,
scrollbar_reveal_hovered: bool,
scrollbar_hovered: bool,
scrollbar_drag: ?ScrollbarDrag,
/// Pointer position in logical surface coordinates.
pointer_x: f64,
pointer_y: f64,
pointer_inside: bool,
/// Demand-driven link detection cache. The URI is owned by App.
hovered_link: ?HoveredLink,
link_checked_cell: ?vt.Coordinate,
link_active: bool,
/// A link click acts only if release occurs over the original cell.
link_press: ?LinkPress,
/// Wheel state accumulated between pointer frame events.
scroll_pixels: f64,
scroll_frame_pixels: f64,
scroll_clicks: i32,
scroll_value120: i32,
scroll_line_remainder: f64,
scroll_target: ScrollTarget,
scroll_source: wl.Pointer.AxisSource,
scroll_time_ms: u32,
scroll_had_pixels: bool,
scroll_had_discrete: bool,
scroll_had_value120: bool,
scroll_stopped: bool,
/// True while the left button is down for terminal-side selection.
selecting: bool,
/// A left-button press consumed by the tab strip. Its matching release must
/// not leak into terminal selection or application mouse reporting.
tab_bar_press: bool,
/// A middle-button press consumed by the tab strip. Kept separately from the
/// left-button gesture so its release cannot paste after closing a tab.
tab_bar_middle_press: bool,
/// True when the active drag should produce a rectangular selection.
selection_rectangle: bool,
selection_gesture: vt.SelectionGesture,
/// Button press currently owned by application mouse reporting.
mouse_button: ?vt.input.MouseButton,
/// Serial of the most recent input event, required to claim selections.
last_serial: u32,
clipboard: Clipboard,
next_tab_id: u64,
const selection_word_boundaries = [_]u21{
    0,   ' ', '\t', '\'', '"',
    '│',
    '`', '|', ':',  ';',  ',',
    '(', ')', '[',  ']',  '{',
    '}', '<', '>',  '$',
};

/// Terminal lines per wheel click.
const initial_cols = 80;
const initial_rows = 24;
const app_name = "monstar";
const sync_output_reset_ms = 1000;
const taskbar_progress_timeout_seconds = 15;
const selection_repeat_ms = 500;
const selection_autoscroll_ms = 15;
const search_tick_ms = 1;
const search_ticks_per_wake = 8;
const max_search_query_bytes = 64 * 1024;
const scrollbar_hold_ms = 700;
// Fluent durationFast with curveAccelerateMin for a small exiting overlay.
const scrollbar_fade_duration_ms = 150;
const scrollbar_fade_interval_ms = 15;
const compression_idle_ms = 250;
const compression_step_ms = 1;
const scrollbar_default_alpha = 150;
const scrollbar_hover_alpha = 220;
const scrollbar_width = 6;
const scrollbar_inset = 3;
const scrollbar_min_thumb = 24;
const scrollbar_hit_width = 14;
const scrollbar_reveal_width = 24;
const disarmed_timer: std.os.linux.itimerspec = .{
    .it_value = .{ .sec = 0, .nsec = 0 },
    .it_interval = .{ .sec = 0, .nsec = 0 },
};
/// Preserve Monstar's Wayland precision-scroll normalization before applying
/// the user-facing Ghostty-compatible multiplier.
const wayland_precision_scroll_scale = 3.0;
/// Kinetic scroll tuning, matching Keywork's touchpad fling behavior.
const fling_decay_per_ms = 0.998;
const fling_interval_ms = 8;
const fling_start_velocity = 150.0;
const fling_min_velocity = 30.0;
const fling_max_velocity = 8000.0;
const velocity_smoothing = 0.75;

const ScrollTarget = enum { viewport, keys, application };

const ScrollbarDrag = struct {
    grab_offset: f64,
    screen: vt.ScreenSet.Key,
};

const ScrollbarGeometry = struct {
    thumb: Renderer.ScrollbarThumb,
    track_y: u31,
    travel: u31,
    max_offset: usize,
};

pub const InitialSize = union(enum) {
    default,
    chars: struct { cols: u16, rows: u16 },
    pixels: struct { width: u31, height: u31 },
};

pub const InitOptions = struct {
    config_path: ?[:0]const u8 = null,
    config_overrides: []const []const u8 = &.{},
    working_directory: ?[:0]const u8 = null,
    title: [:0]const u8 = "monstar",
    initial_size: InitialSize = .default,
    hold: bool = false,
};

const StartupSize = struct {
    cols: u16,
    rows: u16,
    window: Window.InitialSize,
};

fn initialTerminalSize(size: InitialSize, font: *const Font, config: Config) StartupSize {
    const padding = physicalPadding(config, 120);
    return switch (size) {
        .default => .{
            .cols = initial_cols,
            .rows = initial_rows,
            .window = .{},
        },
        .chars => |chars| .{
            .cols = chars.cols,
            .rows = chars.rows,
            .window = .{
                .width = dimensionForCells(chars.cols, font.cell_width, padding.left, padding.right),
                .height = dimensionForCells(chars.rows, font.cell_height, padding.top, padding.bottom),
            },
        },
        .pixels => |pixels| pixels: {
            const layout = TerminalLayout.init(pixels.width, pixels.height, font.cell_width, font.cell_height, padding);
            break :pixels .{
                .cols = layout.columns,
                .rows = layout.rows,
                .window = .{
                    .width = pixels.width,
                    .height = pixels.height,
                },
            };
        },
    };
}

fn dimensionForCells(cells: u16, cell_size: u31, before: u31, after: u31) u31 {
    return @intCast(@min(
        std.math.maxInt(u31),
        @as(u64, cells) * cell_size + before + after,
    ));
}

pub const TerminalHandler = vt.TerminalStream.Handler;
pub const AppStream = vt.Stream(AppStreamHandler);

pub const AppStreamHandler = struct {
    /// The tab that owns this stream, so background tabs parse into their
    /// own terminal while view-global effects still reach the App.
    tab: *Tab,
    app: *App,
    terminal_handler: TerminalHandler,

    pub fn deinit(self: *AppStreamHandler) void {
        self.terminal_handler.deinit();
    }

    pub fn vt(
        self: *AppStreamHandler,
        comptime action: AppStream.Action.Tag,
        value: AppStream.Action.Value(action),
    ) void {
        // Clipboard reads are asynchronous on Wayland. Keep libghostty's
        // parsing, but route both clipboard protocols around its synchronous
        // TerminalStream effect contract and through Monstar's poll loop.
        switch (action) {
            .clipboard_contents, .kitty_clipboard => {},
            else => self.terminal_handler.vt(action, value),
        }
        const app = self.app;
        switch (action) {
            .color_operation => app.handleOscColorOperation(self.tab, &value.requests, value.terminator),
            .kitty_color_report => app.answerKittySelectionColorQueries(self.tab, value),
            .clipboard_contents => app.setOsc52Clipboard(self.tab, value.kind, value.data),
            .kitty_clipboard => {
                self.tab.kitty_clipboard.handle(value) catch |err| {
                    if (err == error.QueueFull) {
                        const response = self.tab.kitty_clipboard.rejection();
                        app.writeKittyClipboardStatus(self.tab, response.op, response.id, response.terminator, .EBUSY);
                    } else {
                        log.warn("failed to handle OSC 5522 command: {}", .{err});
                    }
                };
                app.pumpKittyClipboard(self.tab);
            },
            .show_desktop_notification => app.showDesktopNotification(value.title, value.body),
            .mouse_shape => {
                self.tab.mouse_shape_explicit = true;
                app.syncCursorShape();
            },
            .set_mode => {
                if (value.mode == .report_color_scheme) app.sendColorSchemeReport(self.tab);
                if (value.mode == .in_band_size_reports) {
                    self.tab.in_band_reports = true;
                    app.sendSizeReport(self.tab);
                }
                app.syncCursorShape();
            },
            .restore_mode => {
                if (value.mode == .report_color_scheme and self.tab.term.modes.get(.report_color_scheme)) {
                    app.sendColorSchemeReport(self.tab);
                }
                if (value.mode == .in_band_size_reports) {
                    const enabled = self.tab.term.modes.get(.in_band_size_reports);
                    self.tab.in_band_reports = enabled;
                    if (enabled) app.sendSizeReport(self.tab);
                }
                app.syncCursorShape();
            },
            .reset_mode => {
                if (value.mode == .in_band_size_reports) self.tab.in_band_reports = false;
                app.syncCursorShape();
            },
            .full_reset => {
                self.tab.kitty_clipboard.reset();
                self.tab.mouse_shape_explicit = false;
                self.tab.in_band_reports = false;
                app.syncCursorShape();
            },
            else => {},
        }
    }
};

/// The currently active tab.
pub fn tab(self: *const App) *Tab {
    return self.active;
}

pub fn tabAt(self: *const App, index: usize) *Tab {
    return self.tabs.items[index];
}

/// `argv`/`envp` must stay valid for the lifetime of the call (the child
/// copies them via execve). `config` strings must remain valid until the
/// first successful reload or App teardown.
pub fn init(
    io: std.Io,
    alloc: std.mem.Allocator,
    config: Config,
    environ: std.process.Environ,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    options: InitOptions,
) !*App {
    const font_size_px = Config.fontSizePixels(config.font_size, 120);
    var font: Font = try .init(
        alloc,
        config.font_family,
        font_size_px,
        config.adjust_cell_height,
    );
    errdefer font.deinit(alloc);

    vt.sys.decode_png = decodePng;

    const startup_size = initialTerminalSize(options.initial_size, &font, config);
    const tab_bar_height = font.cell_height;
    const startup_padding = paddingWithTabBar(config, 120, tab_bar_height);
    const startup_layout = TerminalLayout.init(
        dimensionForCells(startup_size.cols, font.cell_width, startup_padding.left, startup_padding.right),
        dimensionForCells(startup_size.rows, font.cell_height, startup_padding.top, startup_padding.bottom),
        font.cell_width,
        font.cell_height,
        startup_padding,
    );

    // Child-exit detection is driven by SIGCHLD, not pty EOF; config
    // reloads are driven by SIGUSR1. Block both and receive them through
    // signalfd in the poll loop. This must happen before the fork so an
    // early child exit cannot be missed.
    var sigmask = posix.sigemptyset();
    posix.sigaddset(&sigmask, .CHLD);
    posix.sigaddset(&sigmask, .USR1);
    posix.sigprocmask(std.os.linux.SIG.BLOCK, &sigmask, null);
    const signal_fd = posix.signalfd(
        -1,
        &sigmask,
        std.os.linux.SFD.CLOEXEC | std.os.linux.SFD.NONBLOCK,
    ) catch return error.SignalFdFailed;
    errdefer _ = std.os.linux.close(signal_fd);

    // Connect to dbus before the fork so the child can be moved into
    // its own systemd scope before it execs. Filter and fd wiring happen
    // in initDbus once the App has a stable address. With -Ddbus=false,
    // dbus_connection is always the sole `void` value and every dependent
    // feature below (notifications, portals, cgroup isolation) is inert.
    var dbus_connection: DbusHandle = if (build_options.enable_dbus) connection: {
        break :connection DbusConnection.connectSession(io, alloc, environ) catch |err| {
            log.warn("session dbus unavailable; desktop integration disabled: {}", .{err});
            break :connection null;
        };
    } else no_dbus;
    errdefer if (build_options.enable_dbus) {
        if (dbus_connection) |*connection| connection.deinit();
    };

    // When enabled, move each session child into its own transient
    // systemd scope before it can exec. The gate holds the child so
    // grandchildren cannot escape the scope; on failure, releasing the
    // gate lets it proceed un-isolated. Only the request is sent here:
    // systemd's reply and the pid migration land while we set up the
    // window, and the gate is released once both are confirmed below.
    // Always false with -Ddbus=false, since scope creation is a
    // systemd1 D-Bus call.
    const use_cgroup_scope = if (build_options.enable_dbus)
        config.linux_cgroup == .always and dbus_connection != null and cgroup.systemdBooted()
    else
        false;

    const window = try Window.create(alloc, config.app_id, options.title, startup_size.window);
    errdefer window.destroy();
    window.setBufferAlpha(config.background_opacity < 255);
    window.setBackgroundBlur(config.background_blur and config.background_opacity < 255);

    // Timerfds must be nonblocking: disarming a timerfd clears its
    // pending expirations, so a reader acting on stale poll revents
    // (event dispatched earlier in the same loop iteration disarmed
    // the timer) would otherwise block the whole loop forever.
    const repeat_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(repeat_fd);

    const fling_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(fling_fd);

    const sync_output_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(sync_output_fd);

    const selection_autoscroll_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(selection_autoscroll_fd);

    const copy_highlight_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(copy_highlight_fd);

    const taskbar_progress_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(taskbar_progress_fd);

    const search_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(search_fd);

    const scrollbar_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(scrollbar_fd);

    const kitty_animation_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(kitty_animation_fd);

    const compression_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(compression_fd);

    // Allocate the App to a stable address before the first tab, so that
    // tab can hold a back-reference to the owning App.
    const self = try alloc.create(App);
    errdefer alloc.destroy(self);

    const first_tab = try Tab.init(alloc, io, self, 1, config, environ, path, argv, envp, .{
        .cols = startup_size.cols,
        .rows = startup_size.rows,
        .cell_width = font.cell_width,
        .cell_height = font.cell_height,
        .working_directory = options.working_directory,
        .gate_child = use_cgroup_scope,
    });
    errdefer first_tab.deinit();

    var pending_scope: ?cgroup.Pending = null;
    if (build_options.enable_dbus) {
        if (use_cgroup_scope) {
            pending_scope = cgroup.startMoveIntoScope(&dbus_connection.?, @intCast(first_tab.child_pid)) catch blk: {
                log.warn("cgroup isolation unavailable; child stays in our cgroup", .{});
                break :blk null;
            };
        }
    }
    // On error paths the errdefer'd first_tab.deinit releases the gate.
    errdefer if (pending_scope) |pending| pending.cancel();
    if (pending_scope == null) first_tab.releaseChild();

    var tabs: std.ArrayList(*Tab) = .empty;
    try tabs.append(alloc, first_tab);

    self.* = .{
        .alloc = alloc,
        .io = io,
        .config_arena = .init(alloc),
        .config = config,
        .config_path = options.config_path,
        .config_overrides = options.config_overrides,
        .environ = environ,
        .tabs = tabs,
        .active = first_tab,
        .render_state = .empty,
        .scroll_detector = .{},
        .async_raster = null,
        .async_raster_loader = null,
        .async_generation = 1,
        .async_force_full = true,
        .held_frame = null,
        .async_job = .{},
        .geometry_redraw = false,
        .frame_damage = .init(alloc),
        .font = font,
        .font_size_px = font_size_px,
        .runtime_font_size = null,
        .layout = startup_layout,
        .tab_bar_height = tab_bar_height,
        .selection_bg = config.effectiveSelectionBackground(.dark),
        .selection_fg = config.effectiveSelectionForeground(.dark),
        .selection_bg_override = null,
        .selection_fg_override = null,
        .copy_highlight = config.effectiveCopyHighlight(.dark),
        .copy_highlight_fg = config.effectiveCopyHighlightForeground(.dark),
        .copy_highlight_active = false,
        .cursor_color = config.effectiveCursorColor(.dark),
        .cursor_text = config.effectiveCursorText(.dark),
        .cursor_anim = undefined,
        .cursor_anim_ready = false,
        .cursor_anim_moving = false,
        .cursor_anim_last_ns = 0,
        .window = window,
        .keyboard = try .init(),
        .needs_redraw = true,
        .focused = true,
        .ime_focused = false,
        .ime_preedit = null,
        .ime_pending_preedit = null,
        .ime_pending_commit = null,
        .hold = options.hold,
        .child_path = path,
        .child_argv = argv,
        .child_envp = envp,
        .working_directory = options.working_directory,
        .dbus = dbus_connection,
        .dbus_fd = -1,
        .pending_open_uri = null,
        .notifications = .empty,
        .color_scheme = .dark,
        .reduced_motion = false,
        .signal_fd = signal_fd,
        .repeat_fd = repeat_fd,
        .repeat_keycode = null,
        .repeat_rate = 25,
        .repeat_delay = 600,
        .fling_fd = fling_fd,
        .fling_active = false,
        .fling_velocity = 0,
        .scroll_velocity = 0,
        .last_scroll_time_ms = null,
        .sync_output_fd = sync_output_fd,
        .selection_autoscroll_fd = selection_autoscroll_fd,
        .copy_highlight_fd = copy_highlight_fd,
        .taskbar_progress_fd = taskbar_progress_fd,
        .search_fd = search_fd,
        .scrollbar_fd = scrollbar_fd,
        .kitty_animation_fd = kitty_animation_fd,
        .compression_fd = compression_fd,
        .compression_activity = first_tab.term.compressionActivity(),
        .scrollbar_alpha = 0,
        .scrollbar_fading = false,
        .scrollbar_fade_elapsed_ms = 0,
        .scrollbar_reveal_hovered = false,
        .scrollbar_hovered = false,
        .scrollbar_drag = null,
        .pointer_x = 0,
        .pointer_y = 0,
        .pointer_inside = false,
        .hovered_link = null,
        .link_checked_cell = null,
        .link_active = false,
        .link_press = null,
        .scroll_pixels = 0,
        .scroll_frame_pixels = 0,
        .scroll_clicks = 0,
        .scroll_value120 = 0,
        .scroll_line_remainder = 0,
        .scroll_target = .viewport,
        .scroll_source = .wheel,
        .scroll_time_ms = 0,
        .scroll_had_pixels = false,
        .scroll_had_discrete = false,
        .scroll_had_value120 = false,
        .scroll_stopped = false,
        .selecting = false,
        .tab_bar_press = false,
        .tab_bar_middle_press = false,
        .selection_rectangle = false,
        .selection_gesture = .init,
        .mouse_button = null,
        .last_serial = 0,
        .clipboard = .init(alloc, window.data_manager, window.primary_manager),
        .next_tab_id = 2,
    };

    // Scope confirmation ran concurrently with the window setup above,
    // so this rarely waits; the child stays gated until its migration
    // is confirmed (or abandoned).
    if (pending_scope) |pending| {
        pending_scope = null;
        pending.finish() catch {
            log.warn("cgroup isolation unavailable; child stays in our cgroup", .{});
        };
        first_tab.releaseChild();
    }

    // Handle sequences that need responses or side effects.
    self.installEffects(first_tab);
    self.clipboard.setDndCallback(self, dndEvent);

    self.initDbus();
    window.setCallbacks(
        self,
        resize,
        keyboardEvent,
        pointerEvent,
        textInputEvent,
        scaleChanged,
        redrawReady,
        activationTokenReady,
        clipboardDevicesChanged,
    );
    return self;
}

fn decodePng(alloc: std.mem.Allocator, data: []const u8) vt.sys.DecodeError!vt.sys.Image {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const decoded = c.stbi_load_from_memory(
        data.ptr,
        @intCast(data.len),
        &width,
        &height,
        &channels,
        4,
    ) orelse return error.InvalidData;
    defer c.stbi_image_free(decoded);

    if (width <= 0 or height <= 0) return error.InvalidData;
    const pixel_count = std.math.mul(usize, @intCast(width), @intCast(height)) catch return error.InvalidData;
    const len = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;
    const out = try alloc.alloc(u8, len);
    errdefer alloc.free(out);

    @memcpy(out, decoded[0..len]);
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .data = out,
    };
}

/// Window scale delegate: reload the font at the physical pixel size so
/// glyphs are rasterized crisply instead of upscaled by the compositor.
/// The window calls the resize delegate right after, re-fitting the grid
/// to the new cell metrics.
fn scaleChanged(ctx: *anyopaque, scale120: u32) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const size_px = Config.fontSizePixels(self.effectiveFontSize(), scale120);
    if (size_px == 0 or size_px == self.font_size_px) return;

    const new_font: Font = try .init(
        self.alloc,
        self.config.font_family,
        size_px,
        self.config.adjust_cell_height,
    );
    self.font.deinit(self.alloc);
    self.font = new_font;
    self.font_size_px = size_px;
    self.requestFullAsyncRedraw();
}

const Handler = TerminalHandler;
const Effects = Handler.Effects;

/// Effects callbacks only receive the terminal handler; walk back up through
/// monstar's wrapper handler to the tab that owns the terminal.
fn appFromHandler(handler: *Handler) *Tab {
    const app_handler: *AppStreamHandler = @fieldParentPtr("terminal_handler", handler);
    return app_handler.tab;
}

/// Install the sequence effects (PTY replies, size reports, bell, title,
/// drag-and-drop) on a tab's handler. Every tab, not just the first, needs them
/// so background tabs answer queries against their own pty.
fn installEffects(self: *App, tb: *Tab) void {
    _ = self;
    var effects: Effects = .readonly;
    effects.write_pty = effectWritePty;
    effects.device_attributes = effectDeviceAttributes;
    effects.enquiry = effectEnquiry;
    effects.size = effectSize;
    effects.color_scheme = effectColorScheme;
    effects.xtversion = effectXtversion;
    effects.title_changed = effectTitleChanged;
    effects.bell = effectBell;
    effects.progress_report = effectProgressReport;
    effects.clipboard_read = effectClipboardRead;
    effects.drag_and_drop = effectDragAndDrop;
    tb.stream.handler.terminal_handler.effects = effects;
}

/// Return type of an Effects callback, e.g. device_attributes.
fn EffectResult(comptime field_name: []const u8) type {
    const FnPtr = @typeInfo(@FieldType(Effects, field_name)).optional.child;
    return @typeInfo(@typeInfo(FnPtr).pointer.child).@"fn".return_type.?;
}

fn effectWritePty(handler: *Handler, data: []const u8) void {
    appFromHandler(handler).writePty(data);
}

fn effectDeviceAttributes(_: *Handler) EffectResult("device_attributes") {
    return deviceAttributes();
}

fn deviceAttributes() EffectResult("device_attributes") {
    return .{
        .primary = .{
            .features = &.{ .ansi_color, .clipboard },
        },
    };
}

fn effectEnquiry(_: *Handler) []const u8 {
    return "";
}

fn effectProgressReport(handler: *Handler, report: vt.osc.Command.ProgressReport) void {
    appFromHandler(handler).app.reportTaskbarProgress(report);
}

fn effectSize(handler: *Handler) ?vt.size_report.Size {
    return appFromHandler(handler).app.currentSize(appFromHandler(handler));
}

fn currentSize(self: *App, tb: *Tab) vt.size_report.Size {
    return .{
        .rows = tb.term.rows,
        .columns = tb.term.cols,
        .cell_width = self.font.cell_width,
        .cell_height = self.font.cell_height,
    };
}

fn effectColorScheme(handler: *Handler) ?vt.device_status.ColorScheme {
    return appFromHandler(handler).app.color_scheme;
}

fn sendColorSchemeReport(self: *App, tb: *Tab) void {
    tb.writePty(switch (self.color_scheme) {
        .dark => "\x1B[?997;1n",
        .light => "\x1B[?997;2n",
    });
}

fn effectXtversion(_: *Handler) []const u8 {
    return "monstar " ++ build_options.version;
}

fn effectTitleChanged(handler: *Handler) void {
    const tb = appFromHandler(handler);
    // The tab bar shows every tab, so any title change needs a repaint.
    tb.app.needs_redraw = true;
    // Only reflect the title of the visible (active) tab in the window.
    if (tb != tb.app.tab()) return;
    if (tb.term.getTitle()) |title| tb.app.window.toplevel.setTitle(title.ptr);
}

fn effectBell(handler: *Handler) void {
    appFromHandler(handler).app.window.ringBell();
}

fn effectClipboardRead(_: *Handler, read: vt.clipboard.Read) void {
    // Presence advertises mode 5522 support in DECRQM. OSC 5522 actions are
    // intercepted by AppStreamHandler and never use this synchronous path.
    read.reply(.unsupported);
}

fn effectDragAndDrop(handler: *Handler, event: vt.kitty.dnd.Event) void {
    if (event != .acceptance) return;
    const tb = appFromHandler(handler);
    const state = tb.term.kitty_dnd orelse return;
    const accepted = state.clientAccepted() orelse return;
    tb.app.clipboard.setDndAcceptance(switch (accepted) {
        .none => .none,
        .copy => .copy,
        .move => .move,
    });
}

fn clipboardTarget(location: vt.clipboard.Location) ?Clipboard.Target {
    return switch (location) {
        .standard => .clipboard,
        .selection, .primary => .primary,
        else => null,
    };
}

fn showDesktopNotification(self: *App, title: []const u8, body: []const u8) void {
    if (self.focused) return;

    const effective_title = if (title.len > 0)
        title
    else
        self.tab().term.getTitle() orelse app_name;

    self.sendDesktopNotification(effective_title, body) catch |err| {
        log.warn("failed to send desktop notification: {}", .{err});
    };
}

fn reportTaskbarProgress(self: *App, report: vt.osc.Command.ProgressReport) void {
    self.sendTaskbarProgress(report) catch |err| {
        if (err != error.DBusUnavailable) {
            log.warn("failed to send taskbar progress: {}", .{err});
        }
        return;
    };

    if (report.state == .remove) {
        self.stopTaskbarProgressTimer();
    } else {
        self.armTaskbarProgressTimer();
    }
}

/// Finish setting up the session bus connection made in init (filter,
/// matches, poll fd); the connection itself is created before the child
/// fork so that cgroup scope creation can use it.
fn initDbus(self: *App) void {
    if (!build_options.enable_dbus) return;
    const connection = if (self.dbus != null) &self.dbus.? else return;

    connection.addMatch("type='signal',interface='org.freedesktop.Notifications'") catch {
        connection.deinit();
        self.dbus = null;
        return;
    };
    connection.addMatch("type='signal',interface='org.freedesktop.portal.Settings'") catch {
        connection.deinit();
        self.dbus = null;
        return;
    };

    self.dbus_fd = connection.getFd();
    self.readPortalAppearance();
}

fn deinitDbus(self: *App) void {
    self.sendTaskbarProgress(.{ .state = .remove }) catch {};
    for (self.pending_dbus.items) |pending| pending.kind.deinit(self.alloc);
    self.pending_dbus.deinit(self.alloc);
    var it = self.notifications.valueIterator();
    while (it.next()) |token| {
        if (token.*) |value| self.alloc.free(value);
    }
    self.notifications.deinit(self.alloc);

    if (!build_options.enable_dbus) return;
    if (self.dbus) |*connection| {
        connection.deinit();
        self.dbus = null;
        self.dbus_fd = -1;
    }
}

fn dispatchDbus(self: *App) void {
    if (!build_options.enable_dbus) return;
    const connection = if (self.dbus != null) &self.dbus.? else return;
    connection.flushWrites() catch |err| {
        self.disconnectDbus(err);
        return;
    };
    while (connection.nextMessage() catch |err| {
        self.disconnectDbus(err);
        return;
    }) |message_value| {
        var message = message_value;
        defer message.deinit();
        self.handleDbusMessage(&message);
    }
}

fn disconnectDbus(self: *App, err: anyerror) void {
    if (!build_options.enable_dbus) return;
    log.warn("session dbus disconnected: {}", .{err});
    if (self.dbus) |*connection| connection.deinit();
    self.dbus = null;
    self.dbus_fd = -1;
    for (self.pending_dbus.items) |pending| pending.kind.deinit(self.alloc);
    self.pending_dbus.clearRetainingCapacity();
}

/// Takes ownership of kind only after the complete request is accepted.
fn sendDbusMethod(
    self: *App,
    kind: PendingDbus.Kind,
    method: DbusConnection.Method,
    signature: []const u8,
    body: []const u8,
    fds: []const posix.fd_t,
) !void {
    if (!build_options.enable_dbus) return error.DBusUnavailable;
    const connection = if (self.dbus != null) &self.dbus.? else return error.DBusUnavailable;
    if (self.pending_dbus.items.len >= 64) return error.OutgoingQueueFull;
    try self.pending_dbus.ensureUnusedCapacity(self.alloc, 1);
    const serial = try connection.sendMethod(method, signature, body, fds);
    self.pending_dbus.appendAssumeCapacity(.{
        .serial = serial,
        .deadline_ns = std.Io.Clock.awake.now(self.io).nanoseconds + std.time.ns_per_s,
        .kind = kind,
    });
}

fn dbusPollTimeoutMs(self: *const App) i32 {
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    var timeout: i32 = -1;
    for (self.pending_dbus.items) |pending| {
        const remaining = @max(0, pending.deadline_ns - now);
        const ms: i32 = @intCast(@min(std.math.maxInt(i32), @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        timeout = if (timeout < 0) ms else @min(timeout, ms);
    }
    return timeout;
}

fn expireDbusRequests(self: *App) void {
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    var i: usize = 0;
    while (i < self.pending_dbus.items.len) {
        if (self.pending_dbus.items[i].deadline_ns > now) {
            i += 1;
            continue;
        }
        // A timed-out portal may still open the URI. Never launch a second
        // handler unless an explicit unavailable-service reply was received.
        const pending = self.pending_dbus.orderedRemove(i);
        pending.kind.deinit(self.alloc);
    }
}

/// A bare tab wired to a pipe as its pty master, for exercising write-queue
/// and clipboard write paths without a live child. The caller owns the tab
/// and must deinit its write_queue.
fn pipeBackedTab(alloc: std.mem.Allocator, master: posix.fd_t) *Tab {
    const tb = alloc.create(Tab) catch unreachable;
    tb.* = .{
        .alloc = alloc,
        .io = std.testing.io,
        .app = undefined,
        .id = 1,
        .term = undefined,
        .stream = undefined,
        .pty = .{ .master = master, .slave = -1, .gate = -1 },
        .pipeline = undefined,
        .child_pid = -1,
        .child_exited = false,
        .write_queue = .empty,
        .write_queue_offset = 0,
        .search = null,
        .kitty_cache = .empty,
        .kitty_clipboard = .init(alloc),
        .in_band_reports = false,
        .mouse_shape_explicit = false,
        .active_screen = .primary,
    };
    return tb;
}

test "desktop calls return before replies and correlate delayed notifications" {
    if (!build_options.enable_dbus) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const linux = std.os.linux;
    var sockets: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &sockets,
    )));
    defer _ = linux.close(sockets[1]);
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.alloc = alloc;
    app.io = std.testing.io;
    app.config = .{};
    app.pending_dbus = .empty;
    app.notifications = .empty;
    app.dbus = .{ .allocator = alloc, .io = std.testing.io, .fd = sockets[0] };
    defer app.deinitDbus();

    try app.sendDesktopNotification("test", "delayed reply");
    try std.testing.expectEqual(@as(usize, 1), app.pending_dbus.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.notifications.count());
    const serial = app.pending_dbus.items[0].serial;
    const wire = @import("dbus/wire.zig");
    var body: DbusConnection.Encoder = .init(alloc);
    defer body.deinit();
    try body.uint32(42);
    const data = try wire.encodeMessage(alloc, .{
        .message_type = .method_return,
        .reply_serial = serial,
        .signature = "u",
    }, 1, body.bytes(), 0);
    var reply = try wire.parseMessage(alloc, data, try alloc.alloc(posix.fd_t, 0));
    defer reply.deinit();
    app.handleDbusMessage(&reply);
    try std.testing.expectEqual(@as(usize, 0), app.pending_dbus.items.len);
    try std.testing.expect(app.notifications.contains(42));

    // No portal reply: expire owned fallback data, never open a second handler.
    try app.openUriPortal("https://example.com", "activation-token");
    try std.testing.expectEqual(@as(usize, 1), app.pending_dbus.items.len);
    app.pending_dbus.items[0].deadline_ns = 0;
    try std.testing.expectEqual(@as(i32, 0), app.dbusPollTimeoutMs());
    app.expireDbusRequests();
    try std.testing.expectEqual(@as(usize, 0), app.pending_dbus.items.len);
    try std.testing.expectEqual(@as(i32, -1), app.dbusPollTimeoutMs());
}

fn hasQueuedDbusMessages(self: *const App) bool {
    if (!build_options.enable_dbus) return false;
    return if (self.dbus) |*connection| connection.hasQueuedMessages() else false;
}

fn readPortalAppearance(self: *App) void {
    self.readPortalAppearanceUint32("color-scheme", .color_scheme);
    self.readPortalAppearanceUint32("reduced-motion", .reduced_motion);
}

fn readPortalAppearanceUint32(self: *App, key: []const u8, kind: PendingDbus.Kind) void {
    var body: DbusConnection.Encoder = .init(self.alloc);
    defer body.deinit();
    body.string("org.freedesktop.appearance") catch return;
    body.string(key) catch return;

    self.sendDbusMethod(kind, .{
        .destination = "org.freedesktop.portal.Desktop",
        .path = "/org/freedesktop/portal/desktop",
        .interface = "org.freedesktop.portal.Settings",
        .member = "ReadOne",
    }, "ss", body.bytes(), &.{}) catch {};
}

fn portalColorScheme(value: u32) vt.device_status.ColorScheme {
    return switch (value) {
        2 => .light,
        else => .dark,
    };
}

fn portalReducedMotion(value: u32) bool {
    return value == 1;
}

fn sendDesktopNotification(self: *App, title: []const u8, body: []const u8) !void {
    if (!build_options.enable_dbus) return error.DBusUnavailable;

    var encoded: DbusConnection.Encoder = .init(self.alloc);
    defer encoded.deinit();
    try encoded.string(app_name);
    try encoded.uint32(0); // replaces_id
    try encoded.string(""); // app_icon
    try encoded.string(title);
    try encoded.string(body);

    const actions = try encoded.beginArray(4);
    try encoded.string("default");
    try encoded.string("Open");
    try encoded.endArray(actions);

    const hints = try encoded.beginArray(8);
    try dbusAppendStringVariant(&encoded, "desktop-entry", self.config.app_id);
    try encoded.endArray(hints);
    try encoded.int32(-1); // server default expiration

    try self.sendDbusMethod(.notification, .{
        .destination = "org.freedesktop.Notifications",
        .path = "/org/freedesktop/Notifications",
        .interface = "org.freedesktop.Notifications",
        .member = "Notify",
    }, "susssasa{sv}i", encoded.bytes(), &.{});
}

fn sendTaskbarProgress(self: *App, report: vt.osc.Command.ProgressReport) !void {
    if (!build_options.enable_dbus) return error.DBusUnavailable;
    const connection = if (self.dbus != null) &self.dbus.? else return error.DBusUnavailable;

    var encoded: DbusConnection.Encoder = .init(self.alloc);
    defer encoded.deinit();
    const desktop_uri = try std.fmt.allocPrint(self.alloc, "application://{s}.desktop", .{self.config.app_id});
    defer self.alloc.free(desktop_uri);
    try encoded.string(desktop_uri);

    const properties = try encoded.beginArray(8);

    const value = taskbarProgressValue(report);
    const visible = report.state != .remove;
    try dbusAppendBoolVariant(&encoded, "progress-visible", visible);
    try dbusAppendDoubleVariant(&encoded, "progress", value);
    try encoded.endArray(properties);

    try connection.sendSignal(.{
        .path = "/com/canonical/Unity/LauncherEntry",
        .interface = "com.canonical.Unity.LauncherEntry",
        .member = "Update",
    }, "sa{sv}", encoded.bytes());
}

fn taskbarProgressValue(report: vt.osc.Command.ProgressReport) f64 {
    return switch (report.state) {
        .remove, .indeterminate => 0.0,
        .set, .@"error", .pause => if (report.progress) |progress|
            @as(f64, @floatFromInt(progress)) / 100.0
        else
            0.0,
    };
}

fn openUriPortal(self: *App, uri: []const u8, activation_token: ?[:0]const u8) !void {
    if (!build_options.enable_dbus) return error.PortalUnavailable;
    if (self.dbus == null) return error.PortalUnavailable;
    const owned_uri = try self.alloc.dupe(u8, uri);
    errdefer self.alloc.free(owned_uri);
    const owned_token = if (activation_token) |token| try self.alloc.dupeZ(u8, token) else null;
    errdefer if (owned_token) |token| self.alloc.free(token);
    const kind: PendingDbus.Kind = .{ .open_uri = .{ .uri = owned_uri, .token = owned_token } };

    // The portal's OpenURI method rejects file:// URIs by design; local
    // paths go through the fd-passing OpenFile/OpenDirectory methods.
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    if (try clipboard_format.osc7Path(arena_state.allocator(), uri)) |path| {
        return self.openFilePortal(path, activation_token, kind);
    }

    var encoded: DbusConnection.Encoder = .init(self.alloc);
    defer encoded.deinit();
    try encoded.string(""); // parent window
    try encoded.string(uri);
    const options = try encoded.beginArray(8);
    if (activation_token) |token| try dbusAppendStringVariant(&encoded, "activation_token", token);
    try encoded.endArray(options);

    try self.sendPortalCall(kind, "OpenURI", "ssa{sv}", encoded.bytes(), &.{});
}

/// Open a local file or directory through the portal by passing an fd:
/// files open with the default handler, directories in the file manager.
fn openFilePortal(
    self: *App,
    path: [:0]const u8,
    activation_token: ?[:0]const u8,
    kind: PendingDbus.Kind,
) !void {
    const linux = std.os.linux;

    // Directory-ness decides the portal method; O_DIRECTORY fails with
    // ENOTDIR on regular files. NONBLOCK guards against FIFOs blocking
    // the event loop (a no-op for regular files).
    var is_dir = true;
    var rc = linux.openat(linux.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
        .NONBLOCK = true,
    }, 0);
    if (linux.errno(rc) == .NOTDIR) {
        is_dir = false;
        rc = linux.openat(linux.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .NONBLOCK = true,
        }, 0);
    }
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: posix.fd_t = @intCast(rc);
    // The connection duplicates the descriptor before returning.
    defer _ = linux.close(fd);

    var encoded: DbusConnection.Encoder = .init(self.alloc);
    defer encoded.deinit();
    try encoded.string(""); // parent window
    try encoded.unixFd(0);
    const options = try encoded.beginArray(8);
    if (activation_token) |token| try dbusAppendStringVariant(&encoded, "activation_token", token);
    try encoded.endArray(options);

    try self.sendPortalCall(
        kind,
        if (is_dir) "OpenDirectory" else "OpenFile",
        "sha{sv}",
        encoded.bytes(),
        &.{fd},
    );
}

/// Takes ownership of kind on success; the eventual reply decides fallback.
fn sendPortalCall(
    self: *App,
    kind: PendingDbus.Kind,
    member: []const u8,
    signature: []const u8,
    body: []const u8,
    fds: []const posix.fd_t,
) !void {
    try self.sendDbusMethod(kind, .{
        .destination = "org.freedesktop.portal.Desktop",
        .path = "/org/freedesktop/portal/desktop",
        .interface = "org.freedesktop.portal.OpenURI",
        .member = member,
    }, signature, body, fds);
}

fn isPortalUnavailableErrorName(name: []const u8) bool {
    const unavailable = [_][]const u8{
        "org.freedesktop.DBus.Error.ServiceUnknown",
        "org.freedesktop.DBus.Error.NameHasNoOwner",
        "org.freedesktop.DBus.Error.UnknownMethod",
        "org.freedesktop.DBus.Error.UnknownInterface",
        "org.freedesktop.DBus.Error.UnknownObject",
    };
    for (unavailable) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

test "only definitive portal errors enable fallback" {
    try std.testing.expect(isPortalUnavailableErrorName(
        "org.freedesktop.DBus.Error.ServiceUnknown",
    ));
    try std.testing.expect(isPortalUnavailableErrorName(
        "org.freedesktop.DBus.Error.UnknownMethod",
    ));
    try std.testing.expect(!isPortalUnavailableErrorName(
        "org.freedesktop.DBus.Error.NoReply",
    ));
    try std.testing.expect(!isPortalUnavailableErrorName(
        "org.freedesktop.DBus.Error.TimedOut",
    ));
}

fn dbusAppendStringVariant(
    encoder: *DbusConnection.Encoder,
    key: []const u8,
    value: []const u8,
) !void {
    try encoder.dictEntryAlignment();
    try encoder.string(key);
    try encoder.variantSignature("s");
    try encoder.string(value);
}

fn dbusAppendBoolVariant(
    encoder: *DbusConnection.Encoder,
    key: []const u8,
    value: bool,
) !void {
    try encoder.dictEntryAlignment();
    try encoder.string(key);
    try encoder.variantSignature("b");
    try encoder.boolean(value);
}

fn dbusAppendDoubleVariant(
    encoder: *DbusConnection.Encoder,
    key: []const u8,
    value: f64,
) !void {
    try encoder.dictEntryAlignment();
    try encoder.string(key);
    try encoder.variantSignature("d");
    try encoder.double(value);
}

fn handleDbusMessage(self: *App, message: *const DbusConnection.Message) void {
    if (message.messageType() == .method_return or message.messageType() == .error_reply) {
        const serial = message.header.reply_serial orelse return;
        for (self.pending_dbus.items, 0..) |pending, i| {
            if (pending.serial != serial) continue;
            _ = self.pending_dbus.orderedRemove(i);
            defer pending.kind.deinit(self.alloc);
            self.handleDbusReply(pending.kind, message);
            return;
        }
        return;
    }
    if (message.messageType() != .signal) return;
    const interface = message.header.interface orelse return;
    const member = message.header.member orelse return;
    if (std.mem.eql(u8, interface, "org.freedesktop.Notifications")) {
        if (std.mem.eql(u8, member, "ActivationToken")) {
            self.handleNotificationActivationToken(message);
        } else if (std.mem.eql(u8, member, "ActionInvoked")) {
            self.handleNotificationActionInvoked(message);
        }
    } else if (std.mem.eql(u8, interface, "org.freedesktop.portal.Settings") and
        std.mem.eql(u8, member, "SettingChanged"))
    {
        self.handlePortalSettingChanged(message);
    }
}

fn handleDbusReply(self: *App, kind: PendingDbus.Kind, message: *const DbusConnection.Message) void {
    if (kind == .open_uri) {
        if (message.messageType() == .error_reply) {
            if (message.header.error_name) |name| if (isPortalUnavailableErrorName(name)) {
                self.openUriXdg(kind.open_uri.uri, kind.open_uri.token) catch |err| {
                    log.warn("failed to open hyperlink with xdg-open: {}", .{err});
                };
            };
        }
        return;
    }
    if (message.messageType() != .method_return) return;
    var decoder = message.bodyDecoder();
    switch (kind) {
        .notification => {
            if (!std.mem.eql(u8, message.bodySignature(), "u")) return;
            const id = decoder.uint32() catch return;
            decoder.end() catch return;
            const old = self.notifications.fetchPut(self.alloc, id, null) catch return;
            if (old) |entry| if (entry.value) |token| self.alloc.free(token);
        },
        .color_scheme, .reduced_motion => {
            if (!std.mem.eql(u8, message.bodySignature(), "v")) return;
            const signature = decoder.variantSignature() catch return;
            if (!std.mem.eql(u8, signature, "u")) return;
            const value = decoder.uint32() catch return;
            decoder.end() catch return;
            if (kind == .color_scheme)
                self.setColorScheme(portalColorScheme(value), true)
            else
                self.setReducedMotion(portalReducedMotion(value));
        },
        .open_uri => unreachable,
    }
}

fn handlePortalSettingChanged(self: *App, message: *const DbusConnection.Message) void {
    if (!std.mem.eql(u8, message.bodySignature(), "ssv")) return;
    var decoder = message.bodyDecoder();
    const namespace = decoder.string() catch return;
    if (!std.mem.eql(u8, namespace, "org.freedesktop.appearance")) return;

    const key = decoder.string() catch return;
    const color_scheme_changed = std.mem.eql(u8, key, "color-scheme");
    const reduced_motion_changed = std.mem.eql(u8, key, "reduced-motion");
    if (!color_scheme_changed and !reduced_motion_changed) return;

    const variant_signature = decoder.variantSignature() catch return;
    if (!std.mem.eql(u8, variant_signature, "u")) return;
    const value = decoder.uint32() catch return;
    decoder.end() catch return;
    if (color_scheme_changed) {
        const color_scheme = portalColorScheme(value);
        if (self.color_scheme != color_scheme) self.setColorScheme(color_scheme, true);
    } else {
        self.setReducedMotion(portalReducedMotion(value));
    }
}

fn setColorScheme(self: *App, color_scheme: vt.device_status.ColorScheme, report: bool) void {
    self.color_scheme = color_scheme;
    self.applyColorDefaults();
    if (report) for (self.tabs.items) |tb| {
        if (tb.term.modes.get(.report_color_scheme)) self.sendColorSchemeReport(tb);
    };
}

fn setReducedMotion(self: *App, reduced_motion: bool) void {
    if (self.reduced_motion == reduced_motion) return;
    self.reduced_motion = reduced_motion;
    if (reduced_motion and self.scrollbar_fading) {
        self.hideScrollbar();
        self.syncHoveredLink(true);
    }
}

fn handleNotificationActivationToken(self: *App, message: *const DbusConnection.Message) void {
    if (!std.mem.eql(u8, message.bodySignature(), "us")) return;
    var decoder = message.bodyDecoder();
    const notification_id = decoder.uint32() catch return;
    const token_slot = self.notifications.getPtr(notification_id) orelse return;
    const token = decoder.string() catch return;
    decoder.end() catch return;

    const owned = self.alloc.dupe(u8, token) catch return;
    if (token_slot.*) |old| self.alloc.free(old);
    token_slot.* = owned;
}

fn handleNotificationActionInvoked(self: *App, message: *const DbusConnection.Message) void {
    if (!std.mem.eql(u8, message.bodySignature(), "us")) return;
    var decoder = message.bodyDecoder();
    const notification_id = decoder.uint32() catch return;
    const notification = self.notifications.fetchRemove(notification_id) orelse return;
    defer if (notification.value) |token| self.alloc.free(token);
    const action = decoder.string() catch return;
    decoder.end() catch return;
    if (!std.mem.eql(u8, action, "default")) return;

    if (notification.value) |token| {
        if (token.len > 0) {
            const token_z = self.alloc.dupeZ(u8, token) catch return;
            defer self.alloc.free(token_z);
            self.window.activate(token_z);
            return;
        }
    }

    const requested = self.window.requestAttention() catch |err| {
        log.warn("failed to request attention after notification activation: {}", .{err});
        return;
    };
    if (!requested) log.warn("cannot request attention: xdg-activation is unavailable", .{});
}

fn setNonblocking(fd: posix.fd_t) void {
    const linux = std.os.linux;
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return;
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

pub fn deinit(self: *App) void {
    self.hangupChild();
    if (self.async_raster_loader) |*loader| loader.deinit();
    if (self.async_raster) |*async_raster| async_raster.deinit();
    self.frame_damage.deinit();
    self.async_job.deinit(self.alloc);
    if (self.hovered_link) |link| self.alloc.free(link.uri);
    if (self.link_press) |press| self.alloc.free(press.uri);
    self.clearImeText();
    self.clipboard.deinit();
    if (self.pending_open_uri) |uri| self.alloc.free(uri);
    self.deinitDbus();
    _ = std.os.linux.close(self.compression_fd);
    _ = std.os.linux.close(self.kitty_animation_fd);
    _ = std.os.linux.close(self.scrollbar_fd);
    _ = std.os.linux.close(self.search_fd);
    _ = std.os.linux.close(self.taskbar_progress_fd);
    _ = std.os.linux.close(self.copy_highlight_fd);
    _ = std.os.linux.close(self.selection_autoscroll_fd);
    _ = std.os.linux.close(self.sync_output_fd);
    _ = std.os.linux.close(self.fling_fd);
    _ = std.os.linux.close(self.repeat_fd);
    _ = std.os.linux.close(self.signal_fd);
    self.keyboard.deinit();
    self.window.destroy();
    self.scroll_detector.deinit(self.alloc);
    self.render_state.deinit(self.alloc);
    for (self.pending_tab_cleanup.items) |closing| closing.deinit();
    self.pending_tab_cleanup.deinit(self.alloc);
    for (self.tabs.items) |tb| tb.deinit();
    self.tabs.deinit(self.alloc);
    self.font.deinit(self.alloc);
    self.config_arena.deinit();
    self.alloc.destroy(self);
}

/// Run until the window is closed or, without hold mode, every child exits.
pub fn run(self: *App) !void {
    errdefer self.hangupChild();

    // The raster worker is the only renderer; start building it before
    // the first configure so it is usually ready by the first frame.
    self.startAsyncRasterLoad();

    for (self.tabs.items) |tb| try tb.start();

    const display = self.window.display;
    const base = [_]posix.pollfd{
        .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        // Per-tab pipeline fds and pty-write fds are appended below.
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.OUT, .revents = 0 },
        .{ .fd = self.repeat_fd, .events = posix.POLL.IN, .revents = 0 },
        // In-flight paste pipe; negative (ignored) while idle.
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.signal_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.sync_output_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.selection_autoscroll_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.copy_highlight_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.taskbar_progress_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.dbus_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.fling_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.search_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.scrollbar_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.kitty_animation_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.compression_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const k_wl = 0;
    const k_repeat = 3;
    const k_paste = 4;
    const k_signal = 5;
    const k_sync_output = 6;
    const k_selection_autoscroll = 7;
    const k_copy_highlight = 8;
    const k_taskbar = 9;
    const k_dbus = 10;
    const k_async = 11;
    const k_fling = 12;
    const k_search = 13;
    const k_scrollbar = 14;
    const k_kitty_anim = 15;
    const k_compression = 16;

    var fds: std.ArrayList(posix.pollfd) = .empty;
    defer fds.deinit(self.alloc);
    try fds.appendSlice(self.alloc, &base);
    const outgoing_start = fds.items.len;
    try fds.appendNTimes(self.alloc, .{ .fd = -1, .events = posix.POLL.OUT, .revents = 0 }, Clipboard.max_outgoing_transfers);
    const tab_start = outgoing_start + Clipboard.max_outgoing_transfers;

    while (self.window.running and (self.anyChildAlive() or self.hold)) {
        // Tabs can appear or disappear while the loop waits: Ctrl+Shift+N runs
        // from a key event dispatched below. Grow or trim the per-tab poll tail
        // so the current tab set is wired before the next poll. poll ignores
        // entries past `items.len`, so trimming drops stale closed pty fds.
        const needed = tab_start + self.tabs.items.len * 2;
        if (fds.items.len < needed) {
            try fds.appendNTimes(self.alloc, .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 }, needed - fds.items.len);
        }
        fds.items.len = needed;

        // Tab slots live at a fixed `tab_start` offset, so their indexes are
        // stable; only the base references must be re-fetched after the backing
        // array possibly grew above.
        const wl_fd = &fds.items[k_wl];
        const repeat_fd = &fds.items[k_repeat];
        const paste_fd = &fds.items[k_paste];
        const signal_fd = &fds.items[k_signal];
        const sync_output_fd = &fds.items[k_sync_output];
        const selection_autoscroll_fd = &fds.items[k_selection_autoscroll];
        const copy_highlight_fd = &fds.items[k_copy_highlight];
        const taskbar_progress_fd = &fds.items[k_taskbar];
        const dbus_fd = &fds.items[k_dbus];
        const async_fd = &fds.items[k_async];
        const fling_fd = &fds.items[k_fling];
        const search_fd = &fds.items[k_search];
        const scrollbar_fd = &fds.items[k_scrollbar];
        const kitty_animation_fd = &fds.items[k_kitty_anim];
        const compression_fd = &fds.items[k_compression];
        const outgoing_clipboard_fds = fds.items[outgoing_start..][0..Clipboard.max_outgoing_transfers];

        self.expireDbusRequests();
        self.expireClipboardTransfers();
        self.syncScrollbackCompression();
        wl_fd.events = posix.POLL.IN;
        dbus_fd.fd = self.dbus_fd;
        async_fd.fd = if (self.async_raster_loader) |*loader|
            loader.complete_fd
        else if (self.async_raster) |*async_raster|
            async_raster.complete_fd
        else
            -1;

        // Wire each tab's pipeline (input) and, while it has a write
        // backlog, its pty master (output) into the poll set.
        const wired_tabs = self.tabs.items.len;
        for (self.tabs.items, 0..) |tb, i| {
            const pipe = &fds.items[tab_start + 2 * i];
            const write = &fds.items[tab_start + 2 * i + 1];
            pipe.fd = tb.pipeline.ready_fd;
            pipe.events = posix.POLL.IN;
            pipe.revents = 0;
            write.fd = if (tb.write_queue.items.len > 0) tb.pty.master else -1;
            write.events = posix.POLL.OUT;
            write.revents = 0;
        }

        // Standard libwayland read dance: drain the local queue, flush
        // requests, then sleep until one of the fds is ready.
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
            self.window.flushPending();
            self.syncTerminalVisibility();
        }
        if (self.hasQueuedDbusMessages()) {
            display.cancelRead();
            self.dispatchDbus();
            continue;
        }
        // Pending Wayland callbacks can request a redraw while prepareRead
        // drains the local queue. Do that work before entering an infinite
        // poll, or it may remain stranded until an unrelated fd wakes us.
        if (self.hasReadyRedraw()) {
            display.cancelRead();
            try self.redrawIfNeeded();
            continue;
        }
        switch (display.flush()) {
            .SUCCESS => {},
            // Socket full: wait for writability in the main poll set so
            // PTY output still drains while the compositor catches up.
            .AGAIN => wl_fd.events |= posix.POLL.OUT,
            else => {
                display.cancelRead();
                return error.FlushFailed;
            },
        }

        paste_fd.fd = self.clipboard.transferFd();
        self.clipboard.pollOutgoing(outgoing_clipboard_fds);
        dbus_fd.events = posix.POLL.IN;
        if (build_options.enable_dbus) {
            if (self.dbus) |*connection| {
                if (connection.hasPendingWrites()) dbus_fd.events |= posix.POLL.OUT;
            }
        }
        const clipboard_timeout = self.clipboard.pollTimeoutMs();
        const dbus_timeout = self.dbusPollTimeoutMs();
        const timeout = if (clipboard_timeout < 0) dbus_timeout else if (dbus_timeout < 0) clipboard_timeout else @min(clipboard_timeout, dbus_timeout);
        const ready = posix.poll(fds.items, timeout) catch {
            display.cancelRead();
            return error.PollFailed;
        };
        _ = ready;

        if (wl_fd.revents & posix.POLL.IN != 0) {
            if (display.readEvents() != .SUCCESS) return error.ReadEventsFailed;
        } else {
            display.cancelRead();
        }
        if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        self.window.flushPending();
        self.syncTerminalVisibility();

        if (signal_fd.revents & posix.POLL.IN != 0) {
            // Removing a tab shifts the poll slots below. Start over with a
            // freshly wired set rather than apply this iteration's events to
            // a different tab.
            if (try self.drainSignals()) continue;
        }

        // Per-tab pty output and input. Only tabs wired at the top of this
        // iteration have poll data; a tab opened mid-iteration by a dispatched
        // key event is not in the set, and a closed one was trimmed above.
        for (self.tabs.items, 0..) |tb, i| {
            if (i >= wired_tabs) break;
            const pipe = &fds.items[tab_start + 2 * i];
            const write = &fds.items[tab_start + 2 * i + 1];
            if (write.revents & posix.POLL.OUT != 0) tb.flushWriteQueue();
            if (pipe.revents & posix.POLL.IN != 0) {
                try self.drainTab(tb);
            }
        }

        if (repeat_fd.revents & posix.POLL.IN != 0) {
            self.fireRepeat();
        }

        if (sync_output_fd.revents & posix.POLL.IN != 0) {
            self.fireSyncOutputReset();
        }

        if (selection_autoscroll_fd.revents & posix.POLL.IN != 0) {
            self.fireSelectionAutoscroll();
        }

        if (copy_highlight_fd.revents & posix.POLL.IN != 0) {
            self.fireCopyHighlightTimeout();
        }

        if (fling_fd.revents & posix.POLL.IN != 0) {
            self.fireFling();
        }

        if (search_fd.revents & posix.POLL.IN != 0) {
            self.fireSearch();
        }

        if (scrollbar_fd.revents & posix.POLL.IN != 0) {
            self.fireScrollbarFade();
        }

        if (kitty_animation_fd.revents & posix.POLL.IN != 0) {
            self.fireKittyAnimation();
        }

        if (compression_fd.revents & posix.POLL.IN != 0) {
            self.fireScrollbackCompression();
        }

        if (taskbar_progress_fd.revents & posix.POLL.IN != 0) {
            self.fireTaskbarProgressTimeout();
        }

        if (dbus_fd.revents & (posix.POLL.IN | posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR) != 0 or
            self.hasQueuedDbusMessages())
        {
            self.dispatchDbus();
        }

        if (async_fd.revents & posix.POLL.IN != 0) {
            if (self.async_raster_loader != null)
                self.finishAsyncRasterLoad()
            else
                self.finishAsyncRender();
        }

        // Free closed tabs once their children have been reaped and the raster
        // worker is no longer borrowing their kitty image cache.
        self.drainPendingCleanup();

        self.clipboard.dispatchOutgoing(outgoing_clipboard_fds);
        if (self.clipboard.transferFd() >= 0 and paste_fd.fd == self.clipboard.transferFd() and
            paste_fd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0)
        {
            self.readClipboardTransfer();
        }

        // Drive the cursor trail in lockstep with the compositor: each frame
        // callback clears frame_pending, and re-arming the redraw here samples
        // exactly one trail step per displayed frame at the monitor's refresh
        // rate rather than on the old fixed timer.
        if (self.cursor_anim_moving and !self.window.frame_pending and !self.window.suspended) {
            self.needs_redraw = true;
        }
        try self.redrawIfNeeded();
    }

    if (self.window.fatal_error != null) {
        self.hangupChild();
        return error.WindowFatal;
    }

    // Window closed while children are alive: hang them up like a real
    // terminal whose master side went away. Do not synchronously wait
    // here: shells can wait on foreground jobs that still hold the
    // slave side open, which would wedge the terminal process.
    if (self.anyChildAlive()) {
        self.hangupChild();
    }
}

fn anyChildAlive(self: *const App) bool {
    for (self.tabs.items) |tb| {
        if (!tb.child_exited) return true;
    }
    return false;
}

fn hangupChild(self: *App) void {
    for (self.tabs.items) |tb| tb.hangup();
}

/// Signal events arrived. SIGCHLD is the only place the terminal decides
/// the session is over; SIGUSR1 reloads process-local configuration.
/// Drains process signals and returns whether reaping removed a tab.
fn drainSignals(self: *App) !bool {
    var info: std.os.linux.signalfd_siginfo = undefined;
    var saw_sigchld = false;
    var saw_sigusr1 = false;
    while (true) {
        const n = posix.read(self.signal_fd, std.mem.asBytes(&info)) catch break;
        if (n == 0) break;
        switch (info.signo) {
            @intFromEnum(std.os.linux.SIG.CHLD) => saw_sigchld = true,
            @intFromEnum(std.os.linux.SIG.USR1) => saw_sigusr1 = true,
            else => {},
        }
    }
    if (saw_sigusr1) self.reloadConfig();
    var removed_tab = false;
    if (saw_sigchld) {
        // Reap each exited session, then remove its tab. `orderedRemove`
        // shifts the following tab into this index, so do not advance it.
        var i: usize = 0;
        while (i < self.tabs.items.len) {
            const tb = self.tabs.items[i];
            if (try tb.tryWait()) {
                try self.finishChildOutput(tb);
                if (self.removeExitedTab(i)) {
                    removed_tab = true;
                    continue;
                }
            }
            i += 1;
        }
        // Manually closed tabs no longer participate in rendering or input,
        // but their Tab remains queued until wait4 consumes the child status.
        // Reap them on the same SIGCHLD edge as visible sessions.
        try self.reapPendingTabChildren();
    }
    return removed_tab;
}

/// Reap children belonging to tabs removed explicitly by the user. Their
/// pipelines are already stopped and their PTY masters closed, so no terminal
/// output remains to drain.
fn reapPendingTabChildren(self: *App) !void {
    for (self.pending_tab_cleanup.items) |closing| {
        _ = try closing.tryWait();
    }
}

test "children of manually closed tabs remain tracked until reaped" {
    const alloc = std.testing.allocator;
    const linux = std.os.linux;
    const fork_rc = linux.fork();
    try std.testing.expectEqual(.SUCCESS, linux.errno(fork_rc));
    if (fork_rc == 0) linux.exit(0);

    const tb = pipeBackedTab(alloc, -1);
    defer alloc.destroy(tb);
    tb.child_pid = @intCast(fork_rc);

    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.pending_tab_cleanup = .empty;
    defer app.pending_tab_cleanup.deinit(alloc);
    try app.pending_tab_cleanup.append(alloc, tb);

    // wait4(WNOHANG) may race the newly forked child. Keep exercising the same
    // nonblocking event-loop path until the scheduler publishes its exit.
    for (0..100_000) |_| {
        try app.reapPendingTabChildren();
        if (tb.child_exited) break;
    }
    if (!tb.child_exited) {
        _ = linux.kill(tb.child_pid, linux.SIG.KILL);
        _ = Pty.wait(tb.child_pid) catch {};
    }
    try std.testing.expect(tb.child_exited);
    app.pending_tab_cleanup.clearRetainingCapacity();
}

/// Once wait4 confirms the session child is gone, join the gatherer, consume
/// everything it published, then drain bytes it had not yet read from the
/// nonblocking master before ending the session.
/// Once wait4 confirms this tab's session child is gone, join its gatherer,
/// consume everything it published, then drain bytes it had not yet read
/// from the nonblocking master before ending the session.
fn finishChildOutput(self: *App, tb: *Tab) !void {
    tb.pipeline.stop();
    try self.drainTab(tb);
    const consumed = try drainPtyTail(tb.pty.master, &tb.stream);
    if (consumed) {
        self.needs_redraw = true;
        if (tb == self.active) self.syncPtyOutput(tb, true);
    }
}

/// Handles a reaped session after its final PTY bytes have been consumed.
/// Returns whether the tab was removed. Hold mode retains the terminal;
/// otherwise the last session closes the window, or a neighbor becomes active.
fn removeExitedTab(self: *App, idx: usize) bool {
    std.debug.assert(idx < self.tabs.items.len);
    std.debug.assert(self.tabs.items[idx].child_exited);
    if (self.hold) {
        const tb = self.tabs.items[idx];
        // The child cannot finish a synchronized batch after exiting. Show
        // its final output even if it left DEC 2026 enabled.
        tb.term.modes.set(.synchronized_output, false);
        tb.sync_output_deadline_ns = null;
        self.armSyncOutputTimer(self.nowNs());
        self.requestFullAsyncRedraw();
        return false;
    }
    if (self.tabs.items.len == 1) {
        const closing = self.tabs.orderedRemove(idx);
        self.disposeClosedTab(closing);
        self.window.running = false;
        return true;
    }

    if (self.tabs.items[idx] == self.active) {
        if (idx + 1 < self.tabs.items.len) {
            self.activateIndex(idx + 1);
        } else {
            self.activateIndex(idx - 1);
        }
    }
    const closing = self.tabs.orderedRemove(idx);
    self.disposeClosedTab(closing);
    log.debug("session exited; closed tab ({d} remaining)", .{self.tabs.items.len});
    self.requestFullAsyncRedraw();
    return true;
}

test "hold retains exited tabs and exposes their final synchronized output" {
    const alloc = std.testing.allocator;
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    const window = try alloc.create(Window);
    defer alloc.destroy(window);
    window.running = true;
    app.window = window;
    app.io = std.testing.io;
    app.hold = true;
    app.async_generation = 0;
    app.held_frame = null;
    app.tabs = .empty;
    defer app.tabs.deinit(alloc);
    app.sync_output_fd = try createTimerFd();
    defer _ = std.os.linux.close(app.sync_output_fd);
    const a = pipeBackedTab(alloc, -1);
    defer alloc.destroy(a);
    const b = pipeBackedTab(alloc, -1);
    defer alloc.destroy(b);
    const tabs = [_]*Tab{ a, b };
    for (tabs) |tb| {
        tb.term = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 1 });
        try tb.term.printString("final");
        tb.child_exited = true;
        tb.term.modes.set(.synchronized_output, true);
    }
    defer for (tabs) |tb| tb.term.deinit(alloc);
    try app.tabs.appendSlice(alloc, &tabs);
    app.active = b;
    try std.testing.expect(!app.removeExitedTab(0));
    try std.testing.expect(!app.removeExitedTab(1));
    try std.testing.expectEqual(@as(usize, 2), app.tabs.items.len);
    try std.testing.expect(app.active == b);
    try std.testing.expect(window.running);
    for (tabs) |tb| {
        try std.testing.expect(!tb.term.modes.get(.synchronized_output));
        const contents = try tb.term.plainString(alloc);
        defer alloc.free(contents);
        try std.testing.expectEqualStrings("final", std.mem.trimEnd(u8, contents, "\n "));
    }
    app.tabs.items.len = 1;
    app.active = a;
    try std.testing.expect(!app.removeExitedTab(0));
    try std.testing.expectEqual(@as(usize, 1), app.tabs.items.len);
    try std.testing.expect(window.running);
    try std.testing.expect(app.needs_redraw);
}

fn reloadConfig(self: *App) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    var committed = false;
    defer if (!committed) arena_state.deinit();

    const arena = arena_state.allocator();
    var new_config = if (self.config_path) |path|
        Config.loadPath(arena, path)
    else
        Config.load(arena, self.environ);
    for (self.config_overrides) |override| {
        new_config.applyOverride(arena, override) catch |err| {
            log.warn("config override failed: {s}: {}", .{ override, err });
            return;
        };
    }
    new_config.resolveThemes(self.io, arena, self.environ) catch |err| {
        log.warn("theme reload failed: {}", .{err});
        return;
    };
    self.applyConfig(new_config) catch |err| {
        log.warn("config reload failed: {}", .{err});
        return;
    };

    self.config_arena.deinit();
    self.config_arena = arena_state;
    self.config = new_config;
    committed = true;
    log.info("config reloaded", .{});
}

fn activeIndex(self: *const App) usize {
    for (self.tabs.items, 0..) |t, i| if (t == self.active) return i;
    unreachable;
}

/// Ctrl+Shift+N: open a new session. In tab mode (default) a new tab starts
/// in the current tab's working directory; in window mode an independent
/// window is spawned through the user service manager.
fn openNewSession(self: *App) void {
    if (self.config.new_window_mode == .window) {
        self.spawnNewWindow();
    } else {
        self.newTab();
    }
}

/// The active tab's directory, mirroring kitty: its OSC 7 report when present
/// and valid, else the shell process's real cwd from /proc so sessions without
/// shell integration still inherit the right directory. Returns null when the
/// directory no longer exists, so the caller inherits this process's cwd.
fn activeTabPwd(self: *App, arena: std.mem.Allocator) std.mem.Allocator.Error!?[:0]const u8 {
    if (self.tab().term.getPwd()) |url| {
        if (try clipboard_format.osc7Path(arena, url)) |path| {
            if (self.isDirectory(path)) return path;
        }
    }

    var proc_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proc_path = std.fmt.bufPrint(&proc_buf, "/proc/{d}/cwd", .{self.tab().child_pid}) catch return null;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(self.io, proc_path, &link_buf) catch return null;
    const link = link_buf[0..len];
    // readlink appends " (deleted)" once the directory is unlinked.
    if (std.mem.endsWith(u8, link, " (deleted)")) return null;
    if (!self.isDirectory(link)) return null;
    return try arena.dupeZ(u8, link);
}

fn isDirectory(self: *App, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// Ctrl+Shift+T (and Ctrl+Shift+N in tab mode): start a new session tab in
/// the current tab's working directory and switch to it.
fn newTab(self: *App) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pwd: ?[:0]const u8 = self.activeTabPwd(arena) catch null;
    const envp = sessionEnvp(arena, self.child_envp, pwd) catch |err| {
        log.err("new tab env setup failed: {}", .{err});
        return;
    };

    const tb = Tab.init(
        self.alloc,
        self.io,
        self,
        self.next_tab_id,
        self.config,
        self.environ,
        self.child_path,
        self.child_argv,
        envp,
        .{
            .cols = self.tab().term.cols,
            .rows = self.tab().term.rows,
            .cell_width = self.font.cell_width,
            .cell_height = self.font.cell_height,
            .working_directory = pwd orelse self.working_directory,
            .color_scheme = self.color_scheme,
        },
    ) catch |err| {
        log.err("new tab spawn failed: {}", .{err});
        return;
    };
    self.next_tab_id += 1;
    // A new tab needs the response/side-effect handlers, not just the default
    // readonly ones, so its device queries, size reports and PTY replies reach
    // its own pty.
    self.installEffects(tb);
    tb.start() catch |err| {
        log.err("new tab pipeline start failed: {}", .{err});
        tb.deinit();
        return;
    };

    self.tabs.append(self.alloc, tb) catch |err| {
        log.err("new tab list grow failed: {}", .{err});
        tb.deinit();
        return;
    };
    if (tb.term.getTitle()) |title| self.window.toplevel.setTitle(title.ptr);
    log.debug("opened new tab ({d})", .{self.tabs.items.len});
    self.activateTab(tb);
}

fn activateTab(self: *App, tb: *Tab) void {
    if (tb == self.active) return;
    self.cancelDrag();
    self.cancelLinkPress();
    self.clearSelection();
    self.stopFling();
    self.hideScrollbar();
    self.clearImeText();
    self.active = tb;
    // Every tab shares the window geometry; make sure the newly-active
    // terminal matches the current grid and force a full repaint.
    self.render_state.rows = 0;
    self.render_state.dirty = .full;
    self.async_force_full = true;
    self.hovered_link = null;
    self.link_checked_cell = null;
    self.link_active = false;
    self.needs_redraw = true;
    self.syncActiveScreen(tb);
    self.syncSynchronizedOutput(tb);
    self.syncInBandSizeReports(tb);
    self.requestFullAsyncRedraw();
    if (tb.term.getTitle()) |title| self.window.toplevel.setTitle(title.ptr);
}

fn activateIndex(self: *App, index: usize) void {
    self.activateTab(self.tabs.items[index]);
}

/// Returns a live tab by its stable asynchronous-operation identity.
fn findTab(self: *App, id: u64) ?*Tab {
    for (self.tabs.items) |tb| if (tb.id == id) return tb;
    return null;
}

fn nextTab(self: *App) void {
    self.activateIndex((self.activeIndex() + 1) % self.tabs.items.len);
}

fn prevTab(self: *App) void {
    const len = self.tabs.items.len;
    self.activateIndex((self.activeIndex() + len - 1) % len);
}

/// Ctrl+Shift+, / Ctrl+Shift+.: move the active tab one slot left or right in
/// the strip. The tab stays active; a no-op at either end.
fn moveTab(self: *App, direction: isize) void {
    const len: isize = @intCast(self.tabs.items.len);
    if (len < 2) return;
    const idx: isize = @intCast(self.activeIndex());
    const target = idx + direction;
    if (target < 0 or target >= len) return;
    std.mem.swap(*Tab, &self.tabs.items[@intCast(idx)], &self.tabs.items[@intCast(target)]);
    self.requestFullAsyncRedraw();
}

/// Ctrl+Shift+W/Q: close the active tab, activating a neighbor. Closing the
/// last tab closes the window. A live child is hung up immediately, while its
/// tab state is retained until SIGCHLD lets the event loop reap it.
fn closeTab(self: *App) void {
    self.closeTabAt(self.activeIndex());
}

fn closeTabAt(self: *App, idx: usize) void {
    std.debug.assert(idx < self.tabs.items.len);
    if (self.tabs.items.len <= 1) {
        self.tabs.items[idx].hangup();
        self.window.running = false;
        return;
    }
    // Once removed from `tabs`, a live child's PID is reachable only through
    // the cleanup queue. Reserve before changing visible state so OOM cannot
    // turn the child into an untracked zombie.
    self.pending_tab_cleanup.ensureUnusedCapacity(self.alloc, 1) catch |err| {
        log.warn("cannot close tab: failed to reserve child cleanup ({})", .{err});
        return;
    };
    if (self.tabs.items[idx] == self.active) {
        if (idx + 1 < self.tabs.items.len) {
            self.activateIndex(idx + 1);
        } else {
            self.activateIndex(idx - 1);
        }
    }
    const closing = self.tabs.orderedRemove(idx);
    // Stop the child immediately. Only cache/terminal destruction may wait
    // for a raster snapshot; clipboard completions use the stable tab ID and
    // will be discarded once this tab is absent from `tabs`.
    closing.hangup();
    if (closing.child_exited) {
        self.disposeClosedTab(closing);
    } else {
        self.pending_tab_cleanup.appendAssumeCapacity(closing);
    }
    log.debug("closed tab ({d} remaining)", .{self.tabs.items.len});
    self.requestFullAsyncRedraw();
}

/// Releases a removed tab now, unless the async raster worker still borrows
/// its kitty cache through the current snapshot.
fn disposeClosedTab(self: *App, closing: *Tab) void {
    std.debug.assert(closing.child_exited);
    // Defer deinit while the raster worker is busy or the snapshot still pins
    // this tab's kitty cache. A deferred tab stays alive so the cache pointer
    // in the snapshot remains valid until it is released.
    const snapshot_pins = self.async_job.kitty_cache == &closing.kitty_cache;
    const busy = self.async_raster != null and self.async_raster.?.busy();
    if (!busy and !snapshot_pins) {
        closing.deinit();
    } else {
        self.pending_tab_cleanup.append(self.alloc, closing) catch |err| {
            // Out of memory. When the snapshot still pins this tab's cache,
            // freeing the tab would leave a dangling cache pointer, so leak it
            // rather than risk a use-after-free.
            if (snapshot_pins) {
                log.warn("out of memory deferring closed tab cleanup ({}); leaking a tab", .{err});
            } else {
                closing.deinit();
            }
        };
    }
}

/// Deinit queued closed tabs once their children are reaped, the raster worker
/// is idle, and the snapshot no longer pins their kitty cache.
fn drainPendingCleanup(self: *App) void {
    const busy = if (self.async_raster) |*async_raster| async_raster.busy() else false;
    var i: usize = 0;
    while (i < self.pending_tab_cleanup.items.len) {
        const closing = self.pending_tab_cleanup.items[i];
        if (!closing.child_exited or busy or self.async_job.kitty_cache == &closing.kitty_cache) {
            i += 1;
            continue;
        }
        _ = self.pending_tab_cleanup.swapRemove(i);
        closing.deinit();
    }
}

/// Ctrl+Shift+N (window mode): spawn an independent monstar window in the
/// shell's current directory through the user service manager so the new
/// window is not adopted by this monstar's launcher.
fn spawnNewWindow(self: *App) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pwd: ?[:0]const u8 = pwd: {
        const url = self.tab().term.getPwd() orelse break :pwd null;
        break :pwd clipboard_format.osc7Path(arena, url) catch null;
    };

    const envp = self.spawnEnvp(arena, pwd, null) catch |err| {
        log.err("spawn env setup failed: {}", .{err});
        return;
    };
    const exe_path = resolveCommandPathZ(arena, self.environ, "monstar", null) catch "monstar";

    self.spawnSystemdRun(arena, envp, exe_path, pwd) catch |err| {
        log.err("new window launch failed: {}", .{err});
    };
}

fn spawnSystemdRun(
    self: *App,
    arena: std.mem.Allocator,
    envp: [*:null]const ?[*:0]const u8,
    exe_path: [:0]const u8,
    pwd: ?[:0]const u8,
) !void {
    const systemd_run = try resolveCommandPath(arena, self.environ, "systemd-run", null);

    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "systemd-run", "--user", "--collect" });
    if (pwd) |p| {
        const cwd_arg = try std.fmt.allocPrintSentinel(arena, "--working-directory={s}", .{p}, 0);
        try argv.append(arena, cwd_arg.ptr);
    }
    try argv.append(arena, exe_path.ptr);
    const argv_slice = try argv.toOwnedSliceSentinel(arena, null);
    if (!spawnLauncher(systemd_run, argv_slice.ptr, envp, "systemd-run")) {
        return error.SystemdRunFailed;
    }
}

fn spawnLauncher(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    label: []const u8,
) bool {
    const linux = std.os.linux;

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        log.err("{s} fork failed: {}", .{ label, linux.errno(fork_rc) });
        return false;
    }
    const pid: posix.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        const empty_mask = posix.sigemptyset();
        posix.sigprocmask(linux.SIG.SETMASK, &empty_mask, null);
        _ = linux.execve(path, argv, envp);
        linux.exit(127);
    }

    var status: u32 = undefined;
    _ = linux.wait4(pid, &status, 0, null);
    return waitStatusExitedZero(status);
}

fn spawnDetached(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    pwd: ?[:0]const u8,
    label: []const u8,
) bool {
    const linux = std.os.linux;

    // Double fork: the intermediate child exits immediately so init adopts
    // the launched process and it never lingers as our zombie.
    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        log.err("{s} fork failed: {}", .{ label, linux.errno(fork_rc) });
        return false;
    }
    const pid: posix.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        // Intermediate child. Only async-signal-safe calls from here on.
        // We block SIGCHLD/SIGUSR1 for our signalfd; the launched process must
        // start with a clean mask and its own session.
        const empty_mask = posix.sigemptyset();
        posix.sigprocmask(linux.SIG.SETMASK, &empty_mask, null);
        _ = linux.setsid();
        const detached_rc = linux.fork();
        if (linux.errno(detached_rc) != .SUCCESS) linux.exit(127);
        if (detached_rc != 0) linux.exit(0);

        if (pwd) |p| _ = linux.chdir(p.ptr);
        _ = linux.execve(path, argv, envp);
        linux.exit(127); // exec failed
    }

    // Reap the intermediate child; it exits right after the second fork.
    var status: u32 = undefined;
    _ = linux.wait4(pid, &status, 0, null);
    return waitStatusExitedZero(status);
}

fn waitStatusExitedZero(status: u32) bool {
    return (status & 0x7f) == 0 and (status >> 8) == 0;
}

pub fn resolveCommandPath(
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    command: [:0]const u8,
    cwd: ?[:0]const u8,
) ![*:0]const u8 {
    return (try resolveCommandPathZ(arena, environ, command, cwd)).ptr;
}

/// Search PATH relative to the child's working directory (null inherits ours).
/// Returned relative paths must be executed from that directory, not ours.
/// Explicit paths bypass lookup; a failed search returns CommandNotFound.
pub fn resolveCommandPathZ(
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    command: [:0]const u8,
    cwd: ?[:0]const u8,
) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, command, '/') != null) return command;

    const path_env = environ.getPosix("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var dirs = std.mem.splitScalar(u8, path_env, ':');
    while (dirs.next()) |dir| {
        const base = if (dir.len == 0) "." else dir;
        const candidate = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ base, command }, 0);
        const probe = if (cwd != null and !std.fs.path.isAbsolute(candidate))
            try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ cwd.?, candidate }, 0)
        else
            candidate;
        var stat = std.mem.zeroes(std.os.linux.Statx);
        const stat_rc = std.os.linux.statx(
            std.os.linux.AT.FDCWD,
            probe,
            std.os.linux.AT.NO_AUTOMOUNT,
            .{ .TYPE = true },
            &stat,
        );
        if (std.os.linux.errno(stat_rc) == .SUCCESS and stat.mask.TYPE and
            std.os.linux.S.ISREG(stat.mode) and
            std.os.linux.errno(std.os.linux.access(probe, std.os.linux.X_OK)) == .SUCCESS)
        {
            return candidate;
        }
    }
    return error.CommandNotFound;
}

/// Ctrl+Shift+Z/X: move the scrollback viewport between OSC 133 prompt marks.
fn jumpPrompt(self: *App, delta: isize) void {
    const screen = self.tab().term.screens.active;
    if (!screen.semantic_prompt.seen) return;
    screen.pages.scroll(.{ .delta_prompt = delta });
    self.revealScrollbar();
    self.clearSelection();
    self.needs_redraw = true;
    self.syncHoveredLink(true);
}

/// Ctrl+Shift+G: pipe the most recent OSC 133-delimited command output to
/// the configured shell command. The command runs as `/bin/sh -c <value>`.
fn pipeCommandOutput(self: *App) void {
    const command = self.config.pipe_command_output orelse return;
    const output = self.lastCommandOutput() orelse return;
    defer self.alloc.free(output);

    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pwd: ?[:0]const u8 = pwd: {
        const url = self.tab().term.getPwd() orelse break :pwd null;
        break :pwd clipboard_format.osc7Path(arena, url) catch null;
    };
    const envp = self.spawnEnvp(arena, pwd, null) catch |err| {
        log.err("pipe command env setup failed: {}", .{err});
        return;
    };

    spawnPipeCommand(command, output, envp, pwd);
}

fn lastCommandOutput(self: *App) ?[:0]const u8 {
    return semanticCommandOutputText(self.alloc, self.tab().term.screens.active);
}

fn semanticCommandOutputText(alloc: std.mem.Allocator, screen: *vt.Screen) ?[:0]const u8 {
    if (!screen.semantic_prompt.seen) return null;

    var it = screen.pages.promptIterator(.left_up, .{ .screen = .{} }, null);
    while (it.next()) |prompt_pin| {
        const hl = screen.pages.highlightSemanticContent(prompt_pin, .output) orelse continue;
        const sel = vt.Selection.init(hl.start, hl.end, false);
        return screen.selectionString(alloc, .{ .sel = sel, .trim = false }) catch null;
    }
    return null;
}

fn spawnPipeCommand(
    command: [:0]const u8,
    output: []const u8,
    envp: [*:null]const ?[*:0]const u8,
    pwd: ?[:0]const u8,
) void {
    const linux = std.os.linux;

    var fds: [2]posix.fd_t = undefined;
    const pipe_rc = linux.pipe2(&fds, .{ .CLOEXEC = true });
    if (linux.errno(pipe_rc) != .SUCCESS) {
        log.err("pipe command pipe failed: {}", .{linux.errno(pipe_rc)});
        return;
    }
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        log.err("pipe command fork failed: {}", .{linux.errno(fork_rc)});
        return;
    }
    const pid: posix.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        const empty_mask = posix.sigemptyset();
        posix.sigprocmask(linux.SIG.SETMASK, &empty_mask, null);
        _ = linux.setsid();

        const runner_rc = linux.fork();
        if (linux.errno(runner_rc) == .SUCCESS and runner_rc == 0) {
            runPipeCommandChild(command, envp, pwd, fds[0], fds[1]);
        }

        const writer_rc = linux.fork();
        if (linux.errno(writer_rc) == .SUCCESS and writer_rc == 0) {
            writePipeCommandChild(output, fds[0], fds[1]);
        }

        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        linux.exit(0);
    }

    var status: u32 = undefined;
    _ = linux.wait4(pid, &status, 0, null);
}

fn runPipeCommandChild(
    command: [:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    pwd: ?[:0]const u8,
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
) noreturn {
    const linux = std.os.linux;
    if (pwd) |p| _ = linux.chdir(p.ptr);
    _ = linux.dup2(read_fd, 0);
    _ = linux.close(read_fd);
    _ = linux.close(write_fd);

    const devnull = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(devnull) == .SUCCESS) {
        const fd: posix.fd_t = @intCast(devnull);
        _ = linux.dup2(fd, 1);
        _ = linux.dup2(fd, 2);
        if (fd > 2) _ = linux.close(fd);
    }

    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command.ptr };
    _ = linux.execve("/bin/sh", &argv, envp);
    linux.exit(127);
}

fn writePipeCommandChild(output: []const u8, read_fd: posix.fd_t, write_fd: posix.fd_t) noreturn {
    const linux = std.os.linux;
    _ = linux.close(read_fd);
    writeAllFd(write_fd, output);
    _ = linux.close(write_fd);
    linux.exit(0);
}

fn writeAllFd(fd: posix.fd_t, data: []const u8) void {
    const linux = std.os.linux;
    var offset: usize = 0;
    while (offset < data.len) {
        const rc = linux.write(fd, data.ptr + offset, data.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return;
                offset += rc;
            },
            .INTR => {},
            else => return,
        }
    }
}

/// Environment for a spawned process, with optional PWD and activation-token
/// overrides.
fn spawnEnvp(
    self: *App,
    arena: std.mem.Allocator,
    pwd: ?[:0]const u8,
    activation_token: ?[:0]const u8,
) ![*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var has_terminfo = false;
    for (self.environ.block.slice) |entry| {
        const e = entry orelse continue;
        const value = std.mem.span(e);
        // Reflect monstar's terminal definition, not whatever environ we were
        // launched with. Without TERM/COLORTERM/TERMINFO a freshly-spawned
        // shell is not a proper interactive monstar session.
        if (std.mem.startsWith(u8, value, "TERM=")) continue;
        if (std.mem.startsWith(u8, value, "COLORTERM=")) continue;
        if (std.mem.startsWith(u8, value, "TERMINFO=")) has_terminfo = true;
        if (pwd != null and std.mem.startsWith(u8, value, "PWD=")) continue;
        // Activation tokens are single-use and must not leak from the process
        // that launched us into unrelated children.
        if (std.mem.startsWith(u8, value, "XDG_ACTIVATION_TOKEN=")) continue;
        try list.append(arena, e);
    }
    try list.append(arena, "TERM=monstar");
    try list.append(arena, "COLORTERM=truecolor");
    if (pwd) |p| {
        const entry = try std.mem.joinZ(arena, "", &.{ "PWD=", p });
        try list.append(arena, entry.ptr);
    }
    if (activation_token) |token| {
        const entry = try std.mem.joinZ(arena, "", &.{ "XDG_ACTIVATION_TOKEN=", token });
        try list.append(arena, entry.ptr);
    }
    if (!has_terminfo) {
        var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.process.executableDirPath(self.io, &exe_dir_buf)) |len| {
            const terminfo_dir = try std.fs.path.joinZ(arena, &.{ exe_dir_buf[0..len], "..", "share", "terminfo" });
            const entry = try std.fs.path.joinZ(arena, &.{ terminfo_dir, "m", "monstar" });
            if (std.os.linux.errno(std.os.linux.access(entry, std.os.linux.R_OK)) == .SUCCESS) {
                try list.append(arena, try std.mem.joinZ(arena, "", &.{ "TERMINFO=", terminfo_dir }));
            }
        } else |_| {}
    }
    const slice = try list.toOwnedSliceSentinel(arena, null);
    return slice.ptr;
}

/// Clone the prepared session environment for another tab, replacing PWD when
/// the active tab provides one. Shell integration variables live only in this
/// environment (not `App.environ`) and must accompany the reused session
/// command; in particular, bash's injected `--posix` requires its `ENV` script.
fn sessionEnvp(
    arena: std.mem.Allocator,
    base: [*:null]const ?[*:0]const u8,
    pwd: ?[:0]const u8,
) ![*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (base[i]) |entry| : (i += 1) {
        if (pwd != null and std.mem.startsWith(u8, std.mem.span(entry), "PWD=")) continue;
        try list.append(arena, entry);
    }
    if (pwd) |value| {
        const entry = try std.mem.joinZ(arena, "", &.{ "PWD=", value });
        try list.append(arena, entry.ptr);
    }
    const slice = try list.toOwnedSliceSentinel(arena, null);
    return slice.ptr;
}

test "new tab session environment preserves bash injection and replaces PWD" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = [_:null]?[*:0]const u8{
        "ENV=/share/monstar/shell-integration/bash/monstar.bash",
        "MONSTAR_BASH_INJECT=1",
        "PWD=/old",
        "TERM=monstar",
    };
    const envp = try sessionEnvp(arena, &base, "/new");

    try std.testing.expectEqualStrings("ENV=/share/monstar/shell-integration/bash/monstar.bash", std.mem.span(envp[0].?));
    try std.testing.expectEqualStrings("MONSTAR_BASH_INJECT=1", std.mem.span(envp[1].?));
    try std.testing.expectEqualStrings("TERM=monstar", std.mem.span(envp[2].?));
    try std.testing.expectEqualStrings("PWD=/new", std.mem.span(envp[3].?));
    try std.testing.expect(envp[4] == null);
}

fn applyConfig(self: *App, new_config: Config) !void {
    const desired_font_size = Config.fontSizePixels(self.runtime_font_size orelse new_config.font_size, self.window.scale120);
    const new_font: Font = try .init(
        self.alloc,
        new_config.font_family,
        desired_font_size,
        new_config.adjust_cell_height,
    );

    self.applyColorDefaultsForConfig(new_config);
    self.window.setBufferAlpha(new_config.background_opacity < 255);
    self.window.setBackgroundBlur(new_config.background_blur and new_config.background_opacity < 255);
    self.window.toplevel.setAppId(new_config.app_id);

    // Always rebuild the Font on config reload so a reload also picks up
    // fontconfig/file changes for the same family name. The resize path is
    // responsible for deciding whether the new cell metrics changed enough
    // to notify the pty and DEC 2048 in-band size-report listeners.
    self.font.deinit(self.alloc);
    self.font = new_font;
    self.font_size_px = desired_font_size;
    resizeForConfig(
        self,
        Window.physicalDimension(self.window.width, self.window.scale120),
        Window.physicalDimension(self.window.height, self.window.scale120),
        new_config,
    ) catch |err| {
        log.warn("config reload resize failed: {}", .{err});
    };

    if (!new_config.inertial_scrolling) self.stopFling();
    self.requestFullAsyncRedraw();
}

fn applyColorDefaults(self: *App) void {
    self.applyColorDefaultsForConfig(self.config);
    self.requestFullAsyncRedraw();
}

fn applyColorDefaultsForConfig(self: *App, config: Config) void {
    for (self.tabs.items) |tb| tb.applyConfig(config, self.color_scheme);

    self.selection_bg = colorWithRuntimeOverride(
        config.effectiveSelectionBackground(self.color_scheme),
        self.selection_bg_override,
    );
    self.selection_fg = colorWithRuntimeOverride(
        config.effectiveSelectionForeground(self.color_scheme),
        self.selection_fg_override,
    );
    self.copy_highlight = config.effectiveCopyHighlight(self.color_scheme);
    self.copy_highlight_fg = config.effectiveCopyHighlightForeground(self.color_scheme);
    self.cursor_color = config.effectiveCursorColor(self.color_scheme);
    self.cursor_text = config.effectiveCursorText(self.color_scheme);
}

test "theme and configuration updates reach background tabs and preserve OSC overrides" {
    const alloc = std.testing.allocator;
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.config = .{};
    app.color_scheme = .dark;
    app.selection_bg_override = null;
    app.selection_fg_override = null;
    app.async_generation = 0;
    app.held_frame = null;
    app.tabs = .empty;
    defer app.tabs.deinit(alloc);
    const a = pipeBackedTab(alloc, -1);
    defer alloc.destroy(a);
    const b = pipeBackedTab(alloc, -1);
    defer alloc.destroy(b);
    const tabs = [_]*Tab{ a, b };
    for (tabs) |tb| {
        tb.term = try .init(std.testing.io, alloc, .{ .cols = 2, .rows = 1 });
        tb.term.modes.set(.report_color_scheme, true);
        try tb.write_queue.append(alloc, 0);
    }
    defer for (tabs) |tb| {
        tb.term.deinit(alloc);
        tb.write_queue.deinit(alloc);
    };
    try app.tabs.appendSlice(alloc, &tabs);
    app.active = a;
    const runtime: vt.color.RGB = .{ .r = 1, .g = 2, .b = 3 };
    b.term.colors.background.set(runtime);
    app.setColorScheme(.light, true);
    const light = app.config.terminalColors(.light);
    for (tabs) |tb| {
        try std.testing.expectEqual(light.background.default, tb.term.colors.background.default);
        try std.testing.expectEqual(light.foreground.default, tb.term.colors.foreground.default);
        try std.testing.expectEqualSlices(vt.color.RGB, &light.palette.original, &tb.term.colors.palette.original);
        try std.testing.expectEqualStrings("\x00\x1b[?997;2n", tb.write_queue.items);
    }
    const new_config: Config = .{ .background = .{ .r = 20, .g = 30, .b = 40 }, .image_storage_limit = 1234 };
    app.applyColorDefaultsForConfig(new_config);
    for (tabs) |tb| {
        try std.testing.expectEqual(new_config.background, tb.term.colors.background.default);
        try std.testing.expectEqual(@as(usize, 1234), tb.term.screens.active.kitty_images.total_limit);
    }
    try std.testing.expectEqual(runtime, b.term.colors.background.get().?);
}

test "resize reports DEC 2048 size to the tab that enabled it" {
    const alloc = std.testing.allocator;
    const linux = std.os.linux;
    var out_a: [2]posix.fd_t = undefined;
    var out_b: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&out_a, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(out_a[0]);
    defer _ = linux.close(out_a[1]);
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&out_b, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(out_b[0]);
    defer _ = linux.close(out_b[1]);

    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.alloc = alloc;
    app.font = undefined;
    app.font.cell_width = 10;
    app.font.cell_height = 20;

    const a = pipeBackedTab(alloc, out_a[1]);
    defer alloc.destroy(a);
    defer a.write_queue.deinit(alloc);
    a.id = 1;
    a.term = try .init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer a.term.deinit(alloc);
    const b = pipeBackedTab(alloc, out_b[1]);
    defer alloc.destroy(b);
    defer b.write_queue.deinit(alloc);
    b.id = 2;
    b.term = try .init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer b.term.deinit(alloc);

    // Only tab A enables DEC 2048 in-band size reports; a resize must push a
    // report to A's pty alone, reaching its own master/slave pair.
    a.term.modes.set(.in_band_size_reports, true);
    app.notifyTabResize(a);
    app.notifyTabResize(b);

    var buf: [64]u8 = undefined;
    var expected: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&expected);
    try vt.size_report.encode(&writer, .mode_2048, .{
        .rows = 24,
        .columns = 80,
        .cell_width = 10,
        .cell_height = 20,
    });
    const n = try posix.read(out_a[0], &buf);
    try std.testing.expectEqualStrings(writer.buffered(), buf[0..n]);
    try std.testing.expectError(error.WouldBlock, posix.read(out_b[0], &buf));

    // Disabling the mode stops future reports to A.
    a.term.modes.set(.in_band_size_reports, false);
    app.notifyTabResize(a);
    try std.testing.expectError(error.WouldBlock, posix.read(out_a[0], &buf));
}

fn selectionBackgroundForRender(self: *const App) vt.color.RGB {
    return if (self.copy_highlight_active) self.copy_highlight else self.selection_bg;
}

fn selectionForegroundForRender(self: *const App) ?vt.color.RGB {
    return if (self.copy_highlight_active) self.copy_highlight_fg else self.selection_fg;
}

fn colorWithRuntimeOverride(default: vt.color.RGB, runtime: ?vt.color.RGB) vt.color.RGB {
    return runtime orelse default;
}

test "runtime color override survives default changes until reset" {
    const first_default: vt.color.RGB = .{ .r = 1, .g = 2, .b = 3 };
    const next_default: vt.color.RGB = .{ .r = 4, .g = 5, .b = 6 };
    const runtime: vt.color.RGB = .{ .r = 7, .g = 8, .b = 9 };

    try std.testing.expectEqual(runtime, colorWithRuntimeOverride(first_default, runtime));
    try std.testing.expectEqual(runtime, colorWithRuntimeOverride(next_default, runtime));
    try std.testing.expectEqual(next_default, colorWithRuntimeOverride(next_default, null));
}

fn effectiveFontSize(self: *const App) Config.FontSize {
    return self.runtime_font_size orelse self.config.font_size;
}

fn setRuntimeFontSize(self: *App, configured_size: ?Config.FontSize) void {
    const next_size = configured_size orelse self.config.font_size;
    const size_px = Config.fontSizePixels(next_size, self.window.scale120);
    const new_font: Font = Font.init(
        self.alloc,
        self.config.font_family,
        size_px,
        self.config.adjust_cell_height,
    ) catch |err| {
        log.warn("font size change failed: {}", .{err});
        return;
    };

    self.runtime_font_size = configured_size;
    self.font.deinit(self.alloc);
    self.font = new_font;
    self.font_size_px = size_px;
    resize(
        self,
        Window.physicalDimension(self.window.width, self.window.scale120),
        Window.physicalDimension(self.window.height, self.window.scale120),
    ) catch |err| {
        log.warn("font size change resize failed: {}", .{err});
    };
    self.requestFullAsyncRedraw();
}

fn adjustRuntimeFontSize(self: *App, delta: i32) void {
    const current = self.effectiveFontSize();
    const amount = @as(f32, @floatFromInt(delta));
    const next: Config.FontSize = switch (current) {
        .points => |value| .{ .points = std.math.clamp(value + amount, 1, 512) },
        .pixels => |value| .{ .pixels = std.math.clamp(value + amount, 1, 512) },
    };
    if (std.meta.eql(next, current)) return;
    self.setRuntimeFontSize(next);
}

fn resetRuntimeFontSize(self: *App) void {
    if (self.runtime_font_size == null) return;
    self.setRuntimeFontSize(null);
}

/// Feed pipeline batches of PTY output into the terminal. Bounded to
/// one ring's worth so a flooding child cannot starve the Wayland side
/// of the loop; rearm() keeps the eventfd hot while batches remain.
///
/// The master can never return EIO/EOF because Pty.spawn retains a
/// slave fd in this process; only SIGCHLD ends the session.
fn drainTab(self: *App, tb: *Tab) !void {
    tb.pipeline.clearReady();
    var consumed = false;
    for (0..ReadPipeline.buffer_count) |_| {
        const batch = tb.pipeline.take() orelse break;
        tb.stream.nextSlice(batch);
        tb.pipeline.release();
        consumed = true;
        self.needs_redraw = true;
    }
    tb.pipeline.rearm();
    if (tb.pipeline.hasFailed()) return error.PtyReadFailed;
    self.syncPtyOutput(tb, consumed);
}

fn syncPtyOutput(self: *App, tb: *Tab, consumed: bool) void {
    self.syncInBandSizeReports(tb);
    self.syncSynchronizedOutput(tb);
    self.syncScrollTarget();
    self.syncActiveScreen(tb);
    if (consumed) self.refreshSearch(tb);
    // Pointer-driven overlays only apply to the visible tab.
    if (tb == self.active) {
        self.syncScrollbarHover();
        if (consumed) self.syncHoveredLink(true);
    }
}

fn drainPtyTail(fd: posix.fd_t, stream: anytype) !bool {
    var consumed = false;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (n == 0) break;
        stream.nextSlice(buf[0..n]);
        consumed = true;
    }
    return consumed;
}

fn handleOscColorOperation(
    self: *App,
    tb: *Tab,
    requests: *const vt.osc.color.List,
    terminator: vt.osc.Terminator,
) void {
    var it = requests.constIterator(0);
    while (it.next()) |req| {
        switch (req.*) {
            .set => |set| self.setOscColor(set),
            .query => |target| self.answerOscSelectionColorQuery(tb, target, terminator),
            .reset => |target| self.resetOscColor(target),
            else => {},
        }
    }
}

fn setOscColor(self: *App, set: vt.osc.color.ColoredTarget) void {
    switch (set.target) {
        .dynamic => |dynamic| switch (dynamic) {
            .highlight_background => {
                self.selection_bg_override = set.color;
                self.selection_bg = set.color;
            },
            .highlight_foreground => {
                self.selection_fg_override = set.color;
                self.selection_fg = set.color;
            },
            else => return,
        },
        else => return,
    }
    self.requestFullAsyncRedraw();
}

fn resetOscColor(self: *App, target: vt.osc.color.Target) void {
    switch (target) {
        .dynamic => |dynamic| switch (dynamic) {
            .highlight_background => {
                self.selection_bg_override = null;
                self.selection_bg = self.config.effectiveSelectionBackground(self.color_scheme);
            },
            .highlight_foreground => {
                self.selection_fg_override = null;
                self.selection_fg = self.config.effectiveSelectionForeground(self.color_scheme);
            },
            else => return,
        },
        else => return,
    }
    self.requestFullAsyncRedraw();
}

fn answerKittySelectionColorQueries(self: *App, tb: *Tab, request: vt.kitty.color.OSC) void {
    var writer: std.Io.Writer.Allocating = .init(self.alloc);
    defer writer.deinit();

    const wrote_response = self.formatKittySelectionColorResponse(&writer.writer, request) catch return;
    if (!wrote_response) return;

    const response = writer.toOwnedSlice() catch return;
    defer self.alloc.free(response);
    tb.writePty(response);
}

fn formatKittySelectionColorResponse(
    self: *const App,
    writer: *std.Io.Writer,
    request: vt.kitty.color.OSC,
) !bool {
    var wrote_response = false;
    for (request.list.items) |item| {
        switch (item) {
            .query => |key| {
                const value = self.kittySelectionColorValue(key) orelse continue;
                if (!wrote_response) {
                    try writer.writeAll("\x1b]21");
                    wrote_response = true;
                }
                try writeKittyColorReport(writer, key, value);
            },
            else => {},
        }
    }
    if (wrote_response) try writer.writeAll(request.terminator.string());
    return wrote_response;
}

const KittyColorValue = union(enum) {
    color: vt.color.RGB,
    unset,
};

fn kittySelectionColorValue(self: *const App, key: vt.kitty.color.Kind) ?KittyColorValue {
    return switch (key) {
        .palette => null,
        .special => |special| switch (special) {
            .selection_background => .{ .color = self.selection_bg },
            .selection_foreground => if (self.selection_fg) |color|
                .{ .color = color }
            else
                .unset,
            .foreground,
            .background,
            .cursor,
            .cursor_text,
            .visual_bell,
            .second_transparent_background,
            => null,
        },
    };
}

fn writeKittyColorReport(
    writer: *std.Io.Writer,
    key: vt.kitty.color.Kind,
    value: KittyColorValue,
) !void {
    try writer.print(";{f}=", .{key});
    switch (value) {
        .color => |color| try writeKittyColorValue(writer, color),
        .unset => {},
    }
}

fn writeKittyColorValue(writer: *std.Io.Writer, color: vt.color.RGB) !void {
    try writer.print("rgb:{x:0>2}/{x:0>2}/{x:0>2}", .{ color.r, color.g, color.b });
}

fn setOsc52Clipboard(self: *App, tb: *Tab, kind: u8, data: []const u8) void {
    if (data.len == 1 and data[0] == '?') {
        self.beginOsc52Read(tb, kind);
        return;
    }

    const text = decodeOsc52ClipboardData(self.alloc, data) catch |err| {
        switch (err) {
            error.OutOfMemory => log.warn("out of memory decoding OSC 52 clipboard data", .{}),
            else => log.info("application sent invalid base64 data for OSC 52", .{}),
        }
        return;
    };

    switch (osc52Target(kind)) {
        .clipboard => _ = self.clipboard.claim(.clipboard, text, self.last_serial),
        .primary => _ = self.clipboard.claim(.primary, text, self.last_serial),
    }
}

fn beginOsc52Read(self: *App, tb: *Tab, kind: u8) void {
    const target: Clipboard.Target = switch (osc52Target(kind)) {
        .clipboard => .clipboard,
        .primary => .primary,
    };
    switch (self.clipboard.request(target, .{ .osc52_read = .{ .tab_id = tb.id, .kind = kind } })) {
        .started => {},
        .busy, .unavailable => self.writeOsc52ClipboardReport(tb, kind, ""),
    }
}

fn writeOsc52ClipboardReport(self: *App, tb: *Tab, kind: u8, data: []const u8) void {
    var writer: std.Io.Writer.Allocating = .init(self.alloc);
    defer writer.deinit();
    formatOsc52ClipboardReport(&writer.writer, kind, data) catch return;
    const response = writer.toOwnedSlice() catch return;
    defer self.alloc.free(response);
    tb.writePty(response);
}

fn formatOsc52ClipboardReport(writer: *std.Io.Writer, kind: u8, data: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    var encoded_buf: [4096]u8 = undefined;
    if (enc.calcSize(data.len) <= encoded_buf.len) {
        const payload = enc.encode(&encoded_buf, data);
        try writer.print("\x1b]52;{c};{s}\x07", .{ kind, payload });
        return;
    }

    try writer.print("\x1b]52;{c};", .{kind});
    try enc.encodeWriter(writer, data);
    try writer.writeByte(0x07);
}

const Osc52Target = enum { clipboard, primary };

fn osc52Target(kind: u8) Osc52Target {
    return switch (kind) {
        's', 'p' => .primary,
        else => .clipboard,
    };
}

fn decodeOsc52ClipboardData(alloc: std.mem.Allocator, data: []const u8) ![:0]const u8 {
    const dec = std.base64.standard.Decoder;
    const size = try dec.calcSizeForSlice(data);
    const buf = try alloc.allocSentinel(u8, size, 0);
    errdefer alloc.free(buf);
    try dec.decode(buf, data);
    return buf;
}

fn answerOscSelectionColorQuery(
    self: *App,
    tb: *Tab,
    target: vt.osc.color.Target,
    terminator: vt.osc.Terminator,
) void {
    switch (target) {
        .palette => {},
        .dynamic => |dynamic| switch (dynamic) {
            .highlight_background => self.writeOscDynamicReport(tb, 17, self.selection_bg, terminator),
            .highlight_foreground => self.writeOscDynamicReport(
                tb,
                19,
                self.selection_fg orelse self.effectiveForeground(),
                terminator,
            ),
            .foreground,
            .background,
            .cursor,
            .pointer_foreground,
            .pointer_background,
            .tektronix_foreground,
            .tektronix_background,
            .tektronix_cursor,
            => {},
        },
        .special => {},
    }
}

fn writeOscDynamicReport(
    self: *App,
    tb: *Tab,
    dynamic: u16,
    color: vt.color.RGB,
    terminator: vt.osc.Terminator,
) void {
    self.writeOscColorReport(tb, .{ .dynamic = dynamic }, color, terminator);
}

const OscColorReport = union(enum) {
    palette: u8,
    dynamic: u16,
};

fn writeOscColorReport(
    _: *App,
    tb: *Tab,
    report: OscColorReport,
    color: vt.color.RGB,
    terminator: vt.osc.Terminator,
) void {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    formatOscColorReport(&writer, report, color, terminator) catch return;
    tb.writePty(writer.buffered());
}

fn formatOscColorReport(
    writer: *std.Io.Writer,
    report: OscColorReport,
    color: vt.color.RGB,
    terminator: vt.osc.Terminator,
) !void {
    switch (report) {
        .palette => |idx| try writer.print(
            "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
            .{
                idx,
                @as(u16, color.r) * 257,
                @as(u16, color.g) * 257,
                @as(u16, color.b) * 257,
            },
        ),
        .dynamic => |dynamic| try writer.print(
            "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
            .{
                dynamic,
                @as(u16, color.r) * 257,
                @as(u16, color.g) * 257,
                @as(u16, color.b) * 257,
            },
        ),
    }
    try writer.writeAll(terminator.string());
}

fn effectiveForeground(self: *const App) vt.color.RGB {
    return self.tab().term.colors.foreground.get() orelse self.tab().term.colors.palette.current[7];
}

fn syncCursorShape(self: *App) void {
    self.window.setCursorShape(self.currentCursorShape());
}

fn currentCursorShape(self: *App) Window.CursorShape {
    if (self.pointerInTabBar()) return .pointer;
    if (self.scrollbar_hovered or self.scrollbar_drag != null or self.scrollbarThumbHit() != null) return .default;
    if (self.hoveredLinkUri() != null) return .pointer;
    if (self.tab().mouse_shape_explicit) return cursorShapeFromMouseShape(self.tab().term.mouse_shape);
    return if (self.tab().term.flags.mouse_event != .none) .default else .text;
}

fn linkModifiersActive(mods: vt.input.KeyMods, mouse_reporting: bool) bool {
    if (!mods.ctrl or mods.alt or mods.super) return false;
    return mods.shift or !mouse_reporting;
}

fn linksActive(self: *App) bool {
    return linkModifiersActive(
        self.keyboard.currentMods(),
        self.tab().term.flags.mouse_event != .none,
    );
}

fn cursorShapeFromMouseShape(shape: vt.MouseShape) Window.CursorShape {
    return switch (shape) {
        .default => .default,
        .context_menu => .context_menu,
        .help => .help,
        .pointer => .pointer,
        .progress => .progress,
        .wait => .wait,
        .cell => .cell,
        .crosshair => .crosshair,
        .text => .text,
        .vertical_text => .vertical_text,
        .alias => .alias,
        .copy => .copy,
        .move => .move,
        .no_drop => .no_drop,
        .not_allowed => .not_allowed,
        .grab => .grab,
        .grabbing => .grabbing,
        .all_scroll => .all_scroll,
        .col_resize => .col_resize,
        .row_resize => .row_resize,
        .n_resize => .n_resize,
        .e_resize => .e_resize,
        .s_resize => .s_resize,
        .w_resize => .w_resize,
        .ne_resize => .ne_resize,
        .nw_resize => .nw_resize,
        .se_resize => .se_resize,
        .sw_resize => .sw_resize,
        .ew_resize => .ew_resize,
        .ns_resize => .ns_resize,
        .nesw_resize => .nesw_resize,
        .nwse_resize => .nwse_resize,
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
    };
}

test "link modifiers are exact and shift bypasses mouse reporting" {
    try std.testing.expect(linkModifiersActive(.{ .ctrl = true }, false));
    try std.testing.expect(linkModifiersActive(.{ .ctrl = true, .shift = true }, false));
    try std.testing.expect(linkModifiersActive(.{ .ctrl = true, .caps_lock = true }, false));
    try std.testing.expect(!linkModifiersActive(.{ .ctrl = true, .alt = true }, false));
    try std.testing.expect(!linkModifiersActive(.{ .ctrl = true, .super = true }, false));
    try std.testing.expect(!linkModifiersActive(.{ .shift = true }, false));
    try std.testing.expect(!linkModifiersActive(.{ .ctrl = true }, true));
    try std.testing.expect(linkModifiersActive(.{ .ctrl = true, .shift = true }, true));
}

test "OSC color reports use 16-bit rgb format" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatOscColorReport(
        &writer,
        .{ .dynamic = 10 },
        .{ .r = 0x12, .g = 0x34, .b = 0x56 },
        .st,
    );
    try std.testing.expectEqualStrings("\x1b]10;rgb:1212/3434/5656\x1b\\", writer.buffered());

    writer = .fixed(&buf);
    try formatOscColorReport(
        &writer,
        .{ .palette = 7 },
        .{ .r = 0xab, .g = 0xcd, .b = 0xef },
        .bel,
    );
    try std.testing.expectEqualStrings("\x1b]4;7;rgb:abab/cdcd/efef\x07", writer.buffered());
}

test "kitty color reports use OSC 21 key value format" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writer.writeAll("\x1b]21");
    try writeKittyColorReport(
        &writer,
        .{ .special = .foreground },
        .{ .color = .{ .r = 0x12, .g = 0x34, .b = 0x56 } },
    );
    try writeKittyColorReport(&writer, .{ .special = .cursor }, .unset);
    try writeKittyColorReport(
        &writer,
        .{ .palette = 7 },
        .{ .color = .{ .r = 0xab, .g = 0xcd, .b = 0xef } },
    );
    try writer.writeAll(vt.osc.Terminator.st.string());

    try std.testing.expectEqualStrings(
        "\x1b]21;foreground=rgb:12/34/56;cursor=;7=rgb:ab/cd/ef\x1b\\",
        writer.buffered(),
    );
}

test "OSC 52 set decodes clipboard payload" {
    const text = try decodeOsc52ClipboardData(std.testing.allocator, "aGVsbG8=");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);

    try std.testing.expectEqual(.clipboard, osc52Target('c'));
    try std.testing.expectEqual(.primary, osc52Target('s'));
    try std.testing.expectEqual(.primary, osc52Target('p'));
    try std.testing.expectEqual(.clipboard, osc52Target('7'));
}

test "OSC 52 set rejects invalid base64 padding" {
    // Early padding can leave part or all of the destination unwritten.
    for ([_][]const u8{ "=AAA", "AA=A", "A===", "aGVsbG9=" }) |payload| {
        try std.testing.expectError(error.InvalidPadding, decodeOsc52ClipboardData(std.testing.allocator, payload));
    }
    try std.testing.expectError(error.InvalidCharacter, decodeOsc52ClipboardData(std.testing.allocator, "!!!!"));
}

test "OSC 52 read reports base64 clipboard payload" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatOsc52ClipboardReport(&writer, 'c', "hello");
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x07", writer.buffered());
}

test "busy OSC 52 read replies empty without disturbing the active transfer" {
    const alloc = std.testing.allocator;
    const linux = std.os.linux;
    var incoming: [2]posix.fd_t = undefined;
    var output_a: [2]posix.fd_t = undefined;
    var output_b: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&incoming, .{ .CLOEXEC = true, .NONBLOCK = true })));
    try std.testing.expectEqual(@as(usize, 5), linux.write(incoming[1], "hello", 5));
    _ = linux.close(incoming[1]);
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&output_a, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(output_a[0]);
    defer _ = linux.close(output_a[1]);
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&output_b, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(output_b[0]);
    defer _ = linux.close(output_b[1]);
    const tab_a = pipeBackedTab(alloc, output_a[1]);
    defer alloc.destroy(tab_a);
    defer tab_a.kitty_clipboard.deinit();
    defer tab_a.write_queue.deinit(alloc);
    const tab_b = pipeBackedTab(alloc, output_b[1]);
    defer alloc.destroy(tab_b);
    defer tab_b.kitty_clipboard.deinit();
    defer tab_b.write_queue.deinit(alloc);
    tab_b.id = 2;
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.alloc = alloc;
    app.active = tab_a;
    app.tabs = .empty;
    defer app.tabs.deinit(alloc);
    try app.tabs.append(alloc, tab_a);
    try app.tabs.append(alloc, tab_b);
    app.clipboard = .init(alloc, null, null);
    defer app.clipboard.deinit();
    app.clipboard.transfer_fd = incoming[0];
    app.clipboard.transfer_action = .{ .osc52_read = .{ .tab_id = tab_a.id, .kind = 'c' } };

    app.beginOsc52Read(tab_b, 'p');
    var buf: [64]u8 = undefined;
    const busy_len = try posix.read(output_b[0], &buf);
    try std.testing.expectEqualStrings("\x1b]52;p;\x07", buf[0..busy_len]);
    try std.testing.expectEqual(incoming[0], app.clipboard.transferFd());
    try std.testing.expectEqual(@as(?u8, 'c'), app.clipboard.osc52Read().?.kind);

    const event = (try app.clipboard.readTransfer()).?;
    try std.testing.expectEqual(@as(u8, 'c'), event.osc52_read.kind);
    try std.testing.expectEqualStrings("hello", event.osc52_read.data);
    app.writeOsc52ClipboardReport(tab_a, event.osc52_read.kind, event.osc52_read.data);
    app.clipboard.finishEvent();
    const completed_len = try posix.read(output_a[0], &buf);
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x07", buf[0..completed_len]);
    try std.testing.expectError(error.WouldBlock, posix.read(output_b[0], &buf));
}

test "PNG decode rejects oversized dimensions before rasterization" {
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAJxEAAAABCAYAAACXHN81AAAAPUlEQVR42u3BMQEAAADCoPVP7W0HoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgDOcRQABLx9QIgAAAABJRU5ErkJggg==";
    const decoder = std.base64.standard.Decoder;
    const png = try std.testing.allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer std.testing.allocator.free(png);
    try decoder.decode(png, encoded);

    try std.testing.expectError(error.InvalidData, decodePng(std.testing.allocator, png));
}

test "kitty PNG direct transmit installs decoded RGBA image" {
    const alloc = std.testing.allocator;
    const old_decode_png = vt.sys.decode_png;
    vt.sys.decode_png = decodePng;
    defer vt.sys.decode_png = old_decode_png;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var command: std.Io.Writer.Allocating = .init(alloc);
    defer command.deinit();
    try command.writer.print("\x1b_Ga=T,f=100,i=7;{s}\x1b\\", .{
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=",
    });

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(command.writer.buffered());

    const img = term.screens.active.kitty_images.imageById(7) orelse return error.MissingImage;
    try std.testing.expectEqual(.rgba, img.format);
    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);
    try std.testing.expectEqual(@as(usize, img.width) * img.height * 4, img.data.len());
    try std.testing.expectEqual(@as(usize, 1), term.screens.active.kitty_images.placements.count());
}

test "DA1 advertises OSC 52 clipboard support" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try deviceAttributes().encode(.primary, &writer);
    try std.testing.expectEqualStrings("\x1b[?62;22;52c", writer.buffered());
}

test "portal appearance values map to application preferences" {
    try std.testing.expectEqual(vt.device_status.ColorScheme.dark, portalColorScheme(0));
    try std.testing.expectEqual(vt.device_status.ColorScheme.dark, portalColorScheme(1));
    try std.testing.expectEqual(vt.device_status.ColorScheme.light, portalColorScheme(2));
    try std.testing.expectEqual(vt.device_status.ColorScheme.dark, portalColorScheme(99));

    try std.testing.expect(!portalReducedMotion(0));
    try std.testing.expect(portalReducedMotion(1));
    try std.testing.expect(!portalReducedMotion(99));
}

/// DEC mode 2048 (in-band size reports): the terminal must send a size
/// report when the application enables the mode, and again on every
/// resize while it stays enabled. Neovim relies on these instead of
/// SIGWINCH once DECRQM confirms support.
///
/// Mode actions send the immediate report, including when an application
/// re-enables an already-enabled mode. This end-of-chunk sync is a
/// fallback for any state changes that do not pass through AppStreamHandler.
fn syncInBandSizeReports(self: *App, tb: *Tab) void {
    const enabled = tb.term.modes.get(.in_band_size_reports);
    if (enabled and !tb.in_band_reports) self.sendSizeReport(tb);
    tb.in_band_reports = enabled;
}

fn sendSizeReport(self: *App, tb: *Tab) void {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    vt.size_report.encode(&writer, .mode_2048, self.currentSize(tb)) catch return;
    tb.writePty(writer.buffered());
}

/// Propagate a resized grid to a child that enabled DEC 2048 in-band size
/// reports. Such apps halt SIGWINCH handling and draw from the inline report
/// alone, so a resize that reflows Monstar's grid without pushing a fresh
/// report leaves the child at the old size until it restarts.
fn notifyTabResize(self: *App, tb: *Tab) void {
    if (tb.term.modes.get(.in_band_size_reports)) self.sendSizeReport(tb);
}

/// DEC mode 2026 (synchronized output): while enabled, the terminal
/// state may change but frames should not expose the intermediate state.
/// A one-shot timer prevents a misbehaving child from freezing output.
fn syncSynchronizedOutput(self: *App, tb: *Tab) void {
    const now_ns = self.nowNs();
    if (!tb.syncSynchronizedOutput(now_ns, sync_output_reset_ms * std.time.ns_per_ms)) return;
    self.armSyncOutputTimer(now_ns);
    if (tb.sync_output_deadline_ns == null) self.needs_redraw = true;
}

fn armSyncOutputTimer(self: *App, now_ns: u64) void {
    var next: ?u64 = null;
    for (self.tabs.items) |tb| {
        const deadline = tb.sync_output_deadline_ns orelse continue;
        next = @min(next orelse deadline, deadline);
    }
    _ = setTimer(self.sync_output_fd, if (next) |deadline| .{
        // Zero disarms timerfd, so already-due batches need a positive delay.
        .it_value = timespecFromNs(@max(1, deadline -| now_ns)),
        .it_interval = .{ .sec = 0, .nsec = 0 },
    } else disarmed_timer, "synchronized output");
}

fn fireSyncOutputReset(self: *App) void {
    _ = readTimer(self.sync_output_fd) orelse return;
    const now_ns = self.nowNs();
    var any_frozen = false;
    for (self.tabs.items) |tb| {
        if (!tb.expireSynchronizedOutput(now_ns)) continue;
        log.debug("synchronized output timed out; forcing redraw", .{});
        any_frozen = true;
    }
    self.armSyncOutputTimer(now_ns);
    if (any_frozen) {
        self.needs_redraw = true;
        self.requestFullAsyncRedraw();
    }
}

fn armTaskbarProgressTimer(self: *App) void {
    _ = setTimer(self.taskbar_progress_fd, .{
        .it_value = .{ .sec = taskbar_progress_timeout_seconds, .nsec = 0 },
        .it_interval = .{ .sec = 0, .nsec = 0 },
    }, "taskbar progress");
}

test "synchronized output deadlines survive another tab ending its batch" {
    const alloc = std.testing.allocator;
    const a = pipeBackedTab(alloc, -1);
    defer alloc.destroy(a);
    a.term = try .init(std.testing.io, alloc, .{ .cols = 2, .rows = 1 });
    defer a.term.deinit(alloc);
    const b = pipeBackedTab(alloc, -1);
    defer alloc.destroy(b);
    b.term = try .init(std.testing.io, alloc, .{ .cols = 2, .rows = 1 });
    defer b.term.deinit(alloc);
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.io = std.testing.io;
    app.tabs = .empty;
    defer app.tabs.deinit(alloc);
    try app.tabs.appendSlice(alloc, &.{ a, b });
    app.sync_output_fd = try createTimerFd();
    defer _ = std.os.linux.close(app.sync_output_fd);

    a.term.modes.set(.synchronized_output, true);
    app.syncSynchronizedOutput(a);
    const a_deadline = a.sync_output_deadline_ns.?;
    b.term.modes.set(.synchronized_output, true);
    app.syncSynchronizedOutput(b);
    b.term.modes.set(.synchronized_output, false);
    app.syncSynchronizedOutput(b);
    try std.testing.expectEqual(a_deadline, a.sync_output_deadline_ns.?);
    var remaining: std.os.linux.itimerspec = undefined;
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.timerfd_gettime(app.sync_output_fd, &remaining)));
    try std.testing.expect(remaining.it_value.sec != 0 or remaining.it_value.nsec != 0);

    b.term.modes.set(.synchronized_output, true);
    _ = b.syncSynchronizedOutput(a_deadline, std.time.ns_per_s);
    try std.testing.expect(!a.expireSynchronizedOutput(a_deadline - 1));
    try std.testing.expect(a.expireSynchronizedOutput(a_deadline));
    try std.testing.expect(!a.term.modes.get(.synchronized_output));
    try std.testing.expect(!b.expireSynchronizedOutput(a_deadline));
    try std.testing.expect(b.term.modes.get(.synchronized_output));
}

fn stopTaskbarProgressTimer(self: *App) void {
    _ = setTimer(self.taskbar_progress_fd, disarmed_timer, "taskbar progress");
}

fn fireTaskbarProgressTimeout(self: *App) void {
    _ = readTimer(self.taskbar_progress_fd) orelse return;
    self.sendTaskbarProgress(.{ .state = .remove }) catch |err| {
        if (err != error.DBusUnavailable) {
            log.warn("failed to clear stale taskbar progress: {}", .{err});
        }
    };
}

/// Window pointer delegate: track position and accumulate wheel scroll,
/// applying it at frame boundaries.
fn pointerEvent(ctx: *anyopaque, event: wl.Pointer.Event) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.syncScrollTarget();
    switch (event) {
        .enter => |enter| {
            self.pointer_x = enter.surface_x.toDouble();
            self.pointer_y = enter.surface_y.toDouble();
            self.pointer_inside = true;
            self.syncScrollbarHoverFromPointer();
            self.syncHoveredLink(false);
            self.syncCursorShape();
        },
        .motion => |motion| {
            self.pointer_x = motion.surface_x.toDouble();
            self.pointer_y = motion.surface_y.toDouble();
            if (self.scrollbar_drag != null) {
                self.dragScrollbar();
                return;
            }
            self.syncScrollbarHoverFromPointer();
            self.syncHoveredLink(false);
            if (self.selecting) {
                self.extendSelection();
            } else if (self.mouse_button != null or self.reportingMouse()) {
                self.sendMouseEvent(.{
                    .action = .motion,
                    .button = self.mouse_button,
                    .mods = self.keyboard.currentMods(),
                    .pos = self.pointerPosPhysical(),
                });
            }
        },
        .axis => |axis| {
            self.stopFling();
            if (axis.axis == .vertical_scroll and !self.scroll_had_discrete and !self.scroll_had_value120) {
                const pixels = axis.value.toDouble();
                self.scroll_pixels += pixels;
                self.scroll_frame_pixels += pixels;
                self.scroll_time_ms = axis.time;
                self.scroll_had_pixels = true;
            }
            if (!self.window.pointerHasFrames()) self.finishScrollFrame();
        },
        .axis_discrete => |discrete| {
            self.stopFling();
            if (discrete.axis == .vertical_scroll) {
                self.scroll_clicks += discrete.discrete;
                self.scroll_had_discrete = true;
            }
        },
        .axis_value120 => |axis| {
            self.stopFling();
            if (axis.axis == .vertical_scroll) {
                self.scroll_value120 += axis.value120;
                self.scroll_had_value120 = true;
            }
        },
        .frame => self.finishScrollFrame(),
        .button => |button| {
            self.last_serial = button.serial;
            if (button.state == .pressed) self.stopFling();
            if (button.button == 272) { // BTN_LEFT
                if (button.state == .pressed) self.tab_bar_press = false;
                switch (button.state) {
                    .pressed => if (self.pointerInTabBar()) {
                        self.tab_bar_press = true;
                        self.activateTabAtPointer();
                        return;
                    },
                    .released => if (self.tab_bar_press) {
                        self.tab_bar_press = false;
                        return;
                    },
                    else => {},
                }
                if (button.state == .pressed and self.beginScrollbarDrag()) return;
                if (button.state == .released and self.finishScrollbarDrag()) return;
            }
            if (button.button == 274) { // BTN_MIDDLE
                if (button.state == .pressed) self.tab_bar_middle_press = false;
                switch (button.state) {
                    .pressed => if (self.pointerInTabBar()) {
                        self.tab_bar_middle_press = true;
                        self.closeTabAtPointer();
                        return;
                    },
                    .released => if (self.tab_bar_middle_press) {
                        self.tab_bar_middle_press = false;
                        return;
                    },
                    else => {},
                }
            }
            // Mouse reporting wins when the application asked for it,
            // except that shift bypasses it for terminal-side selection.
            const reporting = self.tab().term.flags.mouse_event != .none and
                !self.keyboard.currentMods().shift;
            const mouse_button = mouseButtonFromEvdev(button.button);

            if (button.button == 272) { // BTN_LEFT
                if (button.state == .pressed) {
                    if (self.armLinkPress(button.button, .open)) {
                        self.syncScrollbarHover();
                        return;
                    }
                    self.cancelLinkPress();
                }
                if (button.state == .released and self.finishLinkPress(button.button)) {
                    self.syncScrollbarHover();
                    return;
                }
                switch (button.state) {
                    .pressed => if (reporting) {
                        self.forwardMouseButton(button, mouse_button.?);
                    } else {
                        self.startSelection(button.time);
                        self.syncScrollbarHover();
                    },
                    // Routing may have changed since the press (shift
                    // released mid-drag, app toggled mouse mode): an
                    // armed drag always finishes; only presses the app
                    // saw get their release.
                    .released => if (self.selecting) {
                        self.finishSelection();
                        self.syncScrollbarHover();
                    } else if (self.mouse_button == mouse_button) {
                        self.forwardMouseButton(button, mouse_button.?);
                    } else if (reporting) {
                        self.forwardMouseButton(button, mouse_button.?);
                    },
                    else => {},
                }
                return;
            }

            if (button.button == 273) { // BTN_RIGHT
                if (button.state == .pressed) {
                    if (self.armLinkPress(button.button, .copy)) return;
                    self.cancelLinkPress();
                }
                if (button.state == .released and self.finishLinkPress(button.button)) return;
            }

            if (reporting and mouse_button != null) {
                self.forwardMouseButton(button, mouse_button.?);
                return;
            }
            if (button.button == 274 and button.state == .pressed) {
                // BTN_MIDDLE: paste the primary selection.
                self.beginPaste(.primary);
            }
        },
        .axis_source => |source| self.scroll_source = source.axis_source,
        .axis_stop => |stop| {
            if (stop.axis == .vertical_scroll) self.scroll_stopped = true;
        },
        // Terminal scrolling follows the compositor-provided logical axis;
        // the physical direction hint does not change that behavior.
        .axis_relative_direction => {},
        .leave => {
            self.pointer_inside = false;
            self.syncScrollbarHover();
            self.syncHoveredLink(false);
        },
    }
}

fn pointerSurfacePhysical(self: *const App) struct { x: f64, y: f64 } {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    return .{
        .x = @max(0, self.pointer_x * scale),
        .y = @max(0, self.pointer_y * scale),
    };
}

const TabBarRect = struct {
    top: u31,
    height: u31,
};

fn tabBarRect(layout: TerminalLayout, configured_height: u31, position: Config.TabBarPosition) ?TabBarRect {
    const reserved = switch (position) {
        .top => layout.grid_y,
        .bottom => layout.surface_height -| layout.grid_y -| layout.grid_height,
    };
    const height = @min(configured_height, reserved);
    if (height == 0) return null;
    return .{
        .top = switch (position) {
            .top => 0,
            .bottom => layout.surface_height - height,
        },
        .height = height,
    };
}

test "tab bar hit rectangle follows its configured edge and fitted padding" {
    const layout: TerminalLayout = .{
        .surface_width = 100,
        .surface_height = 80,
        .grid_x = 0,
        .grid_y = 20,
        .grid_width = 100,
        .grid_height = 40,
        .columns = 10,
        .rows = 2,
        .padding = .{ .top = 20, .bottom = 20 },
    };

    try std.testing.expectEqual(TabBarRect{ .top = 0, .height = 15 }, tabBarRect(layout, 15, .top).?);
    try std.testing.expectEqual(TabBarRect{ .top = 65, .height = 15 }, tabBarRect(layout, 15, .bottom).?);
    try std.testing.expectEqual(TabBarRect{ .top = 60, .height = 20 }, tabBarRect(layout, 30, .bottom).?);
    try std.testing.expectEqual(@as(?TabBarRect, null), tabBarRect(layout, 0, .top));
}

fn pointerInTabBar(self: *const App) bool {
    if (!self.pointer_inside) return false;
    const rect = tabBarRect(self.layout, self.tab_bar_height, self.config.tab_bar_position) orelse return false;
    const pos = self.pointerSurfacePhysical();
    return pos.x < self.layout.surface_width and pos.y >= rect.top and pos.y < rect.top + rect.height;
}

fn activateTabAtPointer(self: *App) void {
    if (self.tabIndexAtPointer()) |index| self.activateIndex(index);
    self.syncCursorShape();
}

fn closeTabAtPointer(self: *App) void {
    if (self.tabIndexAtPointer()) |index| self.closeTabAt(index);
    self.syncCursorShape();
}

fn tabIndexAtPointer(self: *App) ?usize {
    const pos = self.pointerSurfacePhysical();
    const x: u31 = @intFromFloat(pos.x);
    const items = self.tabBarSnapshot() catch |err| {
        log.warn("cannot hit test tab bar: {}", .{err});
        return null;
    };
    defer self.freeTabBarSnapshot(items);
    const index = Renderer.tabBarItemAt(
        self.alloc,
        items,
        self.layout.surface_width,
        self.font.cell_width,
        x,
    ) catch |err| {
        log.warn("cannot hit test tab bar: {}", .{err});
        return null;
    };
    return index;
}

fn scrollbarPointerEligible(self: *App) bool {
    if (!self.pointer_inside or self.tab().term.screens.active_key != .primary or
        self.scrollbar_drag != null or self.selecting or self.mouse_button != null or
        self.link_press != null)
    {
        return false;
    }
    const scrollbar = self.tab().term.screens.active.pages.scrollbar();
    return scrollbar.total > scrollbar.len;
}

fn scrollbarRevealHovered(self: *App) bool {
    if (!self.scrollbarPointerEligible()) return false;
    const pos = self.pointerSurfacePhysical();
    const reveal_width = Window.physicalDimension(scrollbar_reveal_width, self.window.scale120);
    const reveal_left = self.layout.surface_width -| reveal_width;
    return pos.x >= reveal_left and pos.x < self.layout.surface_width and
        pos.y >= self.layout.grid_y and pos.y < self.layout.grid_y + self.layout.grid_height;
}

fn syncScrollbarHover(self: *App) void {
    const reveal_hovered = self.scrollbarRevealHovered();
    const hovered = reveal_hovered and self.scrollbarThumbUnderPointer() != null;
    if (reveal_hovered == self.scrollbar_reveal_hovered and hovered == self.scrollbar_hovered) return;
    self.scrollbar_reveal_hovered = reveal_hovered;
    self.scrollbar_hovered = hovered;
    if (reveal_hovered) {
        self.revealScrollbar();
    } else {
        const scrollbar = self.tab().term.screens.active.pages.scrollbar();
        if (self.tab().term.screens.active_key != .primary or scrollbar.total <= scrollbar.len) {
            self.hideScrollbar();
        } else if (self.scrollbar_alpha > 0) {
            const changed = self.scrollbar_alpha != scrollbar_default_alpha;
            self.scrollbar_alpha = scrollbar_default_alpha;
            self.armScrollbarHold();
            if (changed) self.requestFullAsyncRedraw();
        }
    }
    self.syncCursorShape();
}

fn syncScrollbarHoverFromPointer(self: *App) void {
    self.syncScrollbarHover();
    if (self.scrollbar_reveal_hovered) self.revealScrollbar();
}

fn scrollbarThumbUnderPointer(self: *App) ?ScrollbarGeometry {
    if (!self.scrollbarPointerEligible()) return null;
    const scrollbar = self.tab().term.screens.active.pages.scrollbar();
    const geometry = scrollbarGeometry(scrollbar, self.layout, self.window.scale120, scrollbar_default_alpha) orelse return null;
    const pos = self.pointerSurfacePhysical();
    const hit_width = @max(geometry.thumb.width, Window.physicalDimension(scrollbar_hit_width, self.window.scale120));
    const hit_left = self.layout.surface_width -| hit_width;
    const thumb_bottom = geometry.thumb.y + geometry.thumb.height;
    if (pos.x < hit_left or pos.x >= self.layout.surface_width or
        pos.y < geometry.thumb.y or pos.y >= thumb_bottom) return null;
    return geometry;
}

fn scrollbarThumbHit(self: *App) ?ScrollbarGeometry {
    if (self.scrollbar_alpha == 0) return null;
    const scrollbar = self.tab().term.screens.active.pages.scrollbar();
    if (!scrollbarShouldRender(scrollbar, self.scrollbar_alpha)) return null;
    return self.scrollbarThumbUnderPointer();
}

fn beginScrollbarDrag(self: *App) bool {
    const geometry = self.scrollbarThumbHit() orelse return false;
    const pos = self.pointerSurfacePhysical();
    self.cancelDrag();
    self.cancelLinkPress();
    self.scrollbar_reveal_hovered = false;
    self.scrollbar_hovered = false;
    self.scrollbar_drag = .{
        .grab_offset = std.math.clamp(
            pos.y - @as(f64, @floatFromInt(geometry.thumb.y)),
            0,
            @as(f64, @floatFromInt(geometry.thumb.height)),
        ),
        .screen = self.tab().term.screens.active_key,
    };
    self.revealScrollbar();
    self.syncHoveredLink(true);
    self.syncCursorShape();
    return true;
}

fn dragScrollbar(self: *App) void {
    const drag = self.scrollbar_drag orelse return;
    if (drag.screen != self.tab().term.screens.active_key) return;
    const geometry = self.currentScrollbarGeometry(scrollbar_hover_alpha) orelse return;
    const pos = self.pointerSurfacePhysical();
    const row = scrollbarRowForThumbY(geometry, pos.y - drag.grab_offset);
    self.tab().term.screens.active.pages.scroll(.{ .row = row });
    self.revealScrollbar();
    self.needs_redraw = true;
    self.syncHoveredLink(true);
}

fn finishScrollbarDrag(self: *App) bool {
    if (self.scrollbar_drag == null) return false;
    self.scrollbar_drag = null;
    self.syncScrollbarHover();
    self.revealScrollbar();
    self.syncHoveredLink(true);
    self.syncCursorShape();
    return true;
}

/// The viewport cell under the pointer, clamped to the grid.
fn cellAtPointer(self: *App) struct { x: u16, y: u16 } {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    const px: f64 = @max(0, self.pointer_x * scale - @as(f64, @floatFromInt(self.layout.grid_x)));
    const py: f64 = @max(0, self.pointer_y * scale - @as(f64, @floatFromInt(self.layout.grid_y)));
    const x: u16 = @intFromFloat(@min(
        px / @as(f64, @floatFromInt(self.font.cell_width)),
        @as(f64, @floatFromInt(self.tab().term.cols -| 1)),
    ));
    const y: u16 = @intFromFloat(@min(
        py / @as(f64, @floatFromInt(self.font.cell_height)),
        @as(f64, @floatFromInt(self.tab().term.rows -| 1)),
    ));
    return .{ .x = x, .y = y };
}

fn pinAtPointer(self: *App) ?vt.Pin {
    const cell = self.cellAtPointer();
    return self.tab().term.screens.active.pages.pin(.{
        .viewport = .{ .x = cell.x, .y = cell.y },
    });
}

/// Unlike selection coordinates, link coordinates must be inside the grid;
/// padding must not clamp to a clickable edge cell.
fn linkCellAtPointer(self: *App) ?vt.Coordinate {
    if (!self.pointer_inside) return null;
    if (self.scrollbar_hovered or self.scrollbar_drag != null or self.scrollbarThumbHit() != null) return null;
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    const px = self.pointer_x * scale;
    const py = self.pointer_y * scale;
    const grid_x: f64 = @floatFromInt(self.layout.grid_x);
    const grid_y: f64 = @floatFromInt(self.layout.grid_y);
    const grid_right: f64 = @floatFromInt(self.layout.grid_x + self.layout.grid_width);
    const grid_bottom: f64 = @floatFromInt(self.layout.grid_y + self.layout.grid_height);
    if (px < grid_x or px >= grid_right or py < grid_y or py >= grid_bottom) return null;
    return .{
        .x = @intFromFloat((px - grid_x) / @as(f64, @floatFromInt(self.font.cell_width))),
        .y = @intFromFloat((py - grid_y) / @as(f64, @floatFromInt(self.font.cell_height))),
    };
}

fn linkPinAtPointer(self: *App) ?vt.Pin {
    const cell = self.linkCellAtPointer() orelse return null;
    return self.tab().term.screens.active.pages.pin(.{ .viewport = cell });
}

fn oscHyperlinkAtPin(pin: vt.Pin) ?[]const u8 {
    const page = pin.node.page();
    const rac = pin.rowAndCell();
    if (!rac.cell.hyperlink) return null;
    const link_id = page.lookupHyperlink(rac.cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, link_id);
    return entry.uri.slice(page.memory);
}

fn detectHoveredLink(self: *App) !?HoveredLink {
    const pin = self.linkPinAtPointer() orelse return null;
    if (oscHyperlinkAtPin(pin)) |uri| {
        return .{ .uri = try self.alloc.dupe(u8, uri), .range = null };
    }

    const screen = self.tab().term.screens.active;
    const line = screen.selectLine(.{
        .pin = pin,
        .whitespace = null,
        .semantic_prompt_boundary = true,
    }) orelse return null;
    var strmap = try screen.selectionStringMap(self.alloc, .{
        .sel = line,
        .trim = false,
    });
    defer strmap.deinit(self.alloc);
    const text = strmap.string;

    var offset: usize = 0;
    while (Link.find(text, offset)) |match| {
        if (match.end > strmap.map.count()) break;
        const selection: vt.Selection = .init(
            strmap.map.get(match.start).?,
            strmap.map.get(match.end - 1).?,
            false,
        );
        if (selection.contains(screen, pin)) {
            return .{
                .uri = try self.alloc.dupe(u8, text[match.start..match.end]),
                .range = self.linkRange(selection),
            };
        }
        offset = match.end;
    }
    return null;
}

fn linkRange(self: *App, selection: vt.Selection) ?Renderer.LinkRange {
    const screen = self.tab().term.screens.active;
    return highlightRange(
        screen,
        selection.topLeft(screen),
        selection.bottomRight(screen),
        self.tab().term.rows,
        self.tab().term.cols,
    );
}

fn highlightRange(
    screen: *vt.Screen,
    start: vt.Pin,
    end: vt.Pin,
    rows: u16,
    cols: u16,
) ?Renderer.LinkRange {
    const tl = screen.pages.pointFromPin(.screen, start) orelse return null;
    const br = screen.pages.pointFromPin(.screen, end) orelse return null;
    const viewport = screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport)) orelse return null;
    const last_y = viewport.screen.y + rows - 1;
    if (br.screen.y < viewport.screen.y or tl.screen.y > last_y) return null;

    return .{
        .start = .{
            .x = if (tl.screen.y < viewport.screen.y) 0 else tl.screen.x,
            .y = @max(tl.screen.y, viewport.screen.y) - viewport.screen.y,
        },
        .end = .{
            .x = if (br.screen.y > last_y) cols - 1 else br.screen.x,
            .y = @min(br.screen.y, last_y) - viewport.screen.y,
        },
    };
}

fn hoveredLinksEqual(a: ?HoveredLink, b: ?HoveredLink) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?.uri, b.?.uri) and std.meta.eql(a.?.range, b.?.range);
}

/// Recompute the link only while the exact activation modifiers are held.
/// Repeated pointer motion inside one cell is deliberately a no-op.
fn syncHoveredLink(self: *App, force: bool) void {
    const active = self.linksActive();
    const activation_changed = active != self.link_active;
    self.link_active = active;
    const cell = if (active) self.linkCellAtPointer() else null;
    if (!force and !activation_changed and std.meta.eql(cell, self.link_checked_cell)) return;
    self.link_checked_cell = cell;

    const next: ?HoveredLink = if (cell != null)
        self.detectHoveredLink() catch |err| next: {
            log.warn("automatic link detection failed: {}", .{err});
            break :next null;
        }
    else
        null;
    const changed = !hoveredLinksEqual(self.hovered_link, next);
    if (changed) {
        if (self.hovered_link) |old| self.alloc.free(old.uri);
        self.hovered_link = next;
    } else if (next) |unchanged| {
        self.alloc.free(unchanged.uri);
    }
    if (changed or activation_changed) self.requestFullAsyncRedraw();
    self.syncCursorShape();
}

fn hoveredLinkUri(self: *App) ?[]const u8 {
    if (!self.linksActive()) return null;
    const link = self.hovered_link orelse return null;
    return link.uri;
}

fn armLinkPress(self: *App, button: u32, action: LinkAction) bool {
    const uri = self.hoveredLinkUri() orelse return false;
    const cell = self.linkCellAtPointer() orelse return false;
    const owned = self.alloc.dupe(u8, uri) catch |err| {
        log.warn("failed to save pressed link: {}", .{err});
        return false;
    };
    if (self.link_press) |old| self.alloc.free(old.uri);
    self.link_press = .{ .uri = owned, .cell = cell, .button = button, .action = action };
    return true;
}

fn cancelLinkPress(self: *App) void {
    if (self.link_press) |press| self.alloc.free(press.uri);
    self.link_press = null;
}

fn finishLinkPress(self: *App, button: u32) bool {
    const press = self.link_press orelse return false;
    if (press.button != button) return false;
    self.link_press = null;
    defer self.alloc.free(press.uri);

    const cell = self.linkCellAtPointer();
    const uri = self.hoveredLinkUri();
    if (cell != null and uri != null and
        std.meta.eql(cell.?, press.cell) and std.mem.eql(u8, uri.?, press.uri))
    {
        switch (press.action) {
            .open => self.openUri(press.uri),
            .copy => self.copyLink(press.uri),
        }
    }
    return true;
}

fn copyLink(self: *App, uri: []const u8) void {
    const text = clipboard_format.formatLinkCopy(self.alloc, uri) catch |err| {
        log.warn("failed to format hyperlink for clipboard: {}", .{err});
        return;
    };
    _ = self.clipboard.claim(.clipboard, text, self.last_serial);
}

fn openUri(self: *App, uri: []const u8) void {
    const owned = self.alloc.dupe(u8, uri) catch |err| {
        log.warn("failed to save hyperlink URI: {}", .{err});
        return;
    };

    if (self.pending_open_uri) |pending| self.alloc.free(pending);
    self.pending_open_uri = owned;

    const requested = self.window.requestActivationToken(self.last_serial) catch |err| requested: {
        log.warn("failed to request hyperlink activation token: {}", .{err});
        break :requested false;
    };
    if (requested) return;

    self.openPendingUri(null);
}

fn activationTokenReady(ctx: *anyopaque, token: [:0]const u8) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.openPendingUri(token);
}

fn openPendingUri(self: *App, activation_token: ?[:0]const u8) void {
    const uri = self.pending_open_uri orelse return;
    self.pending_open_uri = null;
    defer self.alloc.free(uri);

    self.openUriPortal(uri, activation_token) catch |err| {
        if (err == error.PortalUnavailable) {
            self.openUriXdg(uri, activation_token) catch |fallback_err| {
                log.warn("failed to open hyperlink with xdg-open: {}", .{fallback_err});
            };
            return;
        }
        log.warn("failed to open hyperlink through portal: {}", .{err});
    };
}

fn openUriXdg(self: *App, uri: []const u8, activation_token: ?[:0]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const xdg_open = try resolveCommandPathZ(arena, self.environ, "xdg-open", null);

    const uri_z = try arena.dupeZ(u8, uri);
    const envp = try self.spawnEnvp(arena, null, activation_token);
    const argv = [_:null]?[*:0]const u8{ "xdg-open", uri_z.ptr };
    if (!spawnDetached(xdg_open.ptr, &argv, envp, null, "xdg-open")) {
        return error.SpawnFailed;
    }
}

fn pointerPhysical(self: *App) struct { x: f64, y: f64 } {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    return .{
        .x = @max(0, self.pointer_x * scale),
        // SelectionGesture supports horizontal padding explicitly; make Y
        // grid-local so its top/bottom autoscroll thresholds do the same.
        .y = @max(0, self.pointer_y * scale - @as(f64, @floatFromInt(self.layout.grid_y))),
    };
}

fn selectionGeometry(self: *App) vt.SelectionGesture.Drag.Geometry {
    return .{
        .columns = self.tab().term.cols,
        .cell_width = self.font.cell_width,
        .padding_left = self.layout.grid_x,
        .screen_height = self.layout.grid_height,
    };
}

fn physicalPadding(config: Config, scale120: u32) TerminalLayout.Padding {
    return .{
        .left = Window.physicalDimension(config.window_padding_x.first, scale120),
        .right = Window.physicalDimension(config.window_padding_x.second, scale120),
        .top = Window.physicalDimension(config.window_padding_y.first, scale120),
        .bottom = Window.physicalDimension(config.window_padding_y.second, scale120),
    };
}

/// Window padding with the tab-bar strip reserved on the configured edge.
fn paddingWithTabBar(config: Config, scale120: u32, tab_bar_height: u31) TerminalLayout.Padding {
    var padding = physicalPadding(config, scale120);
    switch (config.tab_bar_position) {
        .top => padding.top +|= tab_bar_height,
        .bottom => padding.bottom +|= tab_bar_height,
    }
    return padding;
}

fn selectionTimestamp(ms: u32) std.Io.Timestamp {
    return std.Io.Timestamp.fromNanoseconds(
        @as(i96, @intCast(ms)) * @as(i96, @intCast(std.time.ns_per_ms)),
    );
}

fn mouseButtonFromEvdev(button: u32) ?vt.input.MouseButton {
    return switch (button) {
        272 => .left, // BTN_LEFT
        273 => .right, // BTN_RIGHT
        274 => .middle, // BTN_MIDDLE
        else => null,
    };
}

fn reportingMouse(self: *App) bool {
    return self.tab().term.flags.mouse_event != .none and !self.keyboard.currentMods().shift;
}

fn forwardMouseButton(self: *App, button: anytype, mouse_button: vt.input.MouseButton) void {
    // Buttons owned by the application dismiss any terminal-side
    // selection; the application handles the event its own way.
    self.clearSelection();
    if (button.state == .pressed) self.mouse_button = mouse_button;
    self.sendMouseEvent(.{
        .action = if (button.state == .pressed) .press else .release,
        .button = mouse_button,
        .mods = self.keyboard.currentMods(),
        .pos = self.pointerPosPhysical(),
    });
    if (button.state == .released and self.mouse_button == mouse_button) self.mouse_button = null;
    self.syncScrollbarHover();
}

fn startSelection(self: *App, time_ms: u32) void {
    const pin = self.pinAtPointer() orelse return;
    const pos = self.pointerPhysical();
    self.selection_rectangle = self.keyboard.currentMods().ctrl;
    const selection = self.selection_gesture.press(&self.tab().term, .{
        .time = selectionTimestamp(time_ms),
        .pin = pin,
        .xpos = pos.x,
        .ypos = pos.y,
        .max_distance = @floatFromInt(self.font.cell_width),
        .repeat_interval = selection_repeat_ms * std.time.ns_per_ms,
        .word_boundary_codepoints = &selection_word_boundaries,
    }) catch return;
    self.selecting = true;
    self.applySelection(selection, true);
}

fn extendSelection(self: *App) void {
    const pin = self.pinAtPointer() orelse return;
    const pos = self.pointerPhysical();
    const selection = self.selection_gesture.drag(&self.tab().term, .{
        .pin = pin,
        .xpos = pos.x,
        .ypos = pos.y,
        .rectangle = self.selection_rectangle,
        .word_boundary_codepoints = &selection_word_boundaries,
        .geometry = self.selectionGeometry(),
    });
    self.applySelection(selection, false);
    self.syncSelectionAutoscrollTimer();
}

/// Stop any in-progress drag, untracking the anchor pin on the screen
/// that owns it (which may no longer be the active one).
fn cancelDrag(self: *App) void {
    self.selecting = false;
    self.selection_rectangle = false;
    self.selection_gesture.reset(&self.tab().term);
    self.stopSelectionAutoscrollTimer();
}

fn finishSelection(self: *App) void {
    if (!self.selecting) return;
    self.selecting = false;
    self.selection_gesture.release(&self.tab().term, .{ .pin = self.pinAtPointer() });
    self.selection_rectangle = false;
    self.stopSelectionAutoscrollTimer();
    // Finished selections claim the primary selection, X style.
    self.copyToPrimary();
}

fn applySelection(self: *App, selection: ?vt.Selection, clear_if_null: bool) void {
    const screen = self.tab().term.screens.active;
    if (selection) |sel| {
        screen.select(sel) catch return;
        self.needs_redraw = true;
    } else if (clear_if_null and screen.selection != null) {
        screen.clearSelection();
        self.needs_redraw = true;
    }
}

fn syncSelectionAutoscrollTimer(self: *App) void {
    if (!self.selecting or self.selection_gesture.left_drag_autoscroll == .none) {
        self.stopSelectionAutoscrollTimer();
        return;
    }
    const interval = timespecFromNs(selection_autoscroll_ms * std.time.ns_per_ms);
    _ = setTimer(self.selection_autoscroll_fd, .{
        .it_value = interval,
        .it_interval = interval,
    }, "selection autoscroll");
}

fn stopSelectionAutoscrollTimer(self: *App) void {
    _ = setTimer(self.selection_autoscroll_fd, disarmed_timer, "selection autoscroll");
}

fn fireSelectionAutoscroll(self: *App) void {
    _ = readTimer(self.selection_autoscroll_fd) orelse return;
    if (!self.selecting) return;

    const cell = self.cellAtPointer();
    const pos = self.pointerPhysical();
    const selection = self.selection_gesture.autoscrollTick(&self.tab().term, .{
        .viewport = .{ .x = cell.x, .y = cell.y },
        .xpos = pos.x,
        .ypos = pos.y,
        .rectangle = self.selection_rectangle,
        .word_boundary_codepoints = &selection_word_boundaries,
        .geometry = self.selectionGeometry(),
    });
    self.applySelection(selection, false);
    self.needs_redraw = true;
    self.syncHoveredLink(true);
    self.syncSelectionAutoscrollTimer();
}

/// Drop the current selection and stop any in-progress drag.
fn clearSelection(self: *App) void {
    self.cancelDrag();
    const screen = self.tab().term.screens.active;
    if (screen.selection != null) {
        screen.clearSelection();
        self.needs_redraw = true;
    }
}

/// React to alt screen enter/exit: an in-flight drag must not span
/// screens (its anchor pin belongs to the old screen's pages). The
/// terminal itself clears the incoming screen's selection.
fn syncActiveScreen(self: *App, tb: *Tab) void {
    const key = tb.term.screens.active_key;
    if (key == tb.active_screen) return;
    tb.active_screen = key;
    if (tb != self.active) return;
    self.scrollbar_reveal_hovered = false;
    self.scrollbar_hovered = false;
    self.hideScrollbar();
    self.cancelDrag();
    self.syncScrollbarHover();
}

fn clipboardDevicesChanged(
    ctx: *anyopaque,
    data_device: ?*wl.DataDevice,
    primary_device: ?*zwp.PrimarySelectionDeviceV1,
) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.clipboard.setDevices(data_device, primary_device);
}

/// The current selection's text, allocated, or null if nothing selected.
fn selectionText(self: *App) ?[:0]const u8 {
    const screen = self.tab().term.screens.active;
    const sel = screen.selection orelse return null;
    return screen.selectionString(self.alloc, .{ .sel = sel, .trim = true }) catch null;
}

/// Claim the primary selection with the currently selected text.
fn copyToPrimary(self: *App) void {
    const text = self.selectionText() orelse return;
    _ = self.clipboard.claim(.primary, text, self.last_serial);
}

/// Claim the clipboard with the currently selected text.
fn copyToClipboard(self: *App) void {
    const text = self.selectionText() orelse return;
    if (self.clipboard.claim(.clipboard, text, self.last_serial)) self.flashCopyHighlight();
}

fn flashCopyHighlight(self: *App) void {
    if (self.config.copy_highlight_duration == 0) return;
    if (!setTimer(self.copy_highlight_fd, .{
        .it_value = timespecFromNs(@as(u64, self.config.copy_highlight_duration) * std.time.ns_per_ms),
        .it_interval = .{ .sec = 0, .nsec = 0 },
    }, "copy highlight")) return;
    if (self.copy_highlight_active) return;

    self.copy_highlight_active = true;
    self.requestFullAsyncRedraw();
}

fn fireCopyHighlightTimeout(self: *App) void {
    _ = readTimer(self.copy_highlight_fd) orelse return;
    if (!self.copy_highlight_active) return;

    self.copy_highlight_active = false;
    self.requestFullAsyncRedraw();
}

/// Ask the offer's owner to stream its contents into a pipe; the read
/// end joins the poll loop and the paste completes on EOF.
fn beginPaste(self: *App, target: Clipboard.Target) void {
    _ = self.clipboard.request(target, .{ .terminal = .{ .tab_id = self.tab().id, .target = target } });
}

fn expireClipboardTransfers(self: *App) void {
    const osc52_read = self.clipboard.osc52Read();
    const kitty_read_tab_id = self.clipboard.kittyReadTabId();
    if (!self.clipboard.expireTransfers()) return;
    if (osc52_read) |read| if (self.findTab(read.tab_id)) |tb| self.writeOsc52ClipboardReport(tb, read.kind, "");
    self.failStartedKittyRead(kitty_read_tab_id, .EIO);
    self.pumpKittyClipboards();
}

test "expired Kitty read fails and unblocks the next queued request" {
    const alloc = std.testing.allocator;
    const linux = std.os.linux;
    var incoming: [2]posix.fd_t = undefined;
    var output: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&incoming, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(incoming[1]);
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&output, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(output[0]);
    defer _ = linux.close(output[1]);
    const tb = pipeBackedTab(alloc, output[1]);
    defer alloc.destroy(tb);
    defer tb.kitty_clipboard.deinit();
    defer tb.write_queue.deinit(alloc);
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.alloc = alloc;
    app.active = tb;
    app.tabs = .empty;
    defer app.tabs.deinit(alloc);
    try app.tabs.append(alloc, tb);
    app.clipboard = .init(alloc, null, null);
    defer app.clipboard.deinit();
    app.clipboard.transfer_fd = incoming[0];
    app.clipboard.transfer_deadline_ms = 0;
    app.clipboard.transfer_action = .{ .kitty_read = .{ .tab_id = tb.id, .mime = "text/plain" } };
    try tb.kitty_clipboard.handle(.{ .metadata = "type=read:id=first", .payload = "dGV4dC9wbGFpbg==", .terminator = .st });
    tb.kitty_clipboard.front().?.read.started = true;
    try tb.kitty_clipboard.handle(.{ .metadata = "type=read:id=second", .payload = "Lg==", .terminator = .st });

    app.expireClipboardTransfers();
    try std.testing.expectEqual(@as(posix.fd_t, -1), app.clipboard.transferFd());
    try std.testing.expect(tb.kitty_clipboard.front() == null);
    try std.testing.expectEqual(@as(usize, 0), tb.kitty_clipboard.retained_bytes);
    var buf: [1024]u8 = undefined;
    const n = try posix.read(output[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "status=EIO") != null);
    const first = std.mem.indexOf(u8, buf[0..n], "id=first").?;
    const second = std.mem.indexOf(u8, buf[0..n], "id=second").?;
    try std.testing.expect(first < second);
}

test "clipboard paste stays with its requesting tab or is discarded after close" {
    const alloc = std.testing.allocator;
    const linux = std.os.linux;
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.alloc = alloc;
    app.io = std.testing.io;
    app.tabs = .empty;
    defer app.tabs.deinit(alloc);
    app.clipboard = .init(alloc, null, null);
    defer app.clipboard.deinit();
    const a = pipeBackedTab(alloc, -1);
    const b = pipeBackedTab(alloc, -1);
    defer alloc.destroy(a);
    defer alloc.destroy(b);
    const tabs = [_]*Tab{ a, b };
    for (tabs, 0..) |tb, i| {
        tb.id = i + 1;
        tb.app = app;
        tb.term = try .init(std.testing.io, alloc, .{ .cols = 2, .rows = 1 });
        tb.stream = .init(.{ .allocator = alloc, .handler = .{
            .app = app,
            .tab = tb,
            .terminal_handler = .init(&tb.term),
        } });
        app.installEffects(tb);
    }
    defer for (tabs) |tb| {
        tb.stream.deinit();
        tb.term.deinit(alloc);
        tb.write_queue.deinit(alloc);
        tb.kitty_clipboard.deinit();
    };
    a.term.modes.set(.bracketed_paste, true);
    app.active = b;
    for ([_]Clipboard.Target{ .clipboard, .primary }) |target| {
        for ([_]bool{ false, true }) |closed| {
            app.tabs.clearRetainingCapacity();
            if (!closed) try app.tabs.append(alloc, a);
            try app.tabs.append(alloc, b);
            for (tabs) |tb| {
                tb.write_queue.clearRetainingCapacity();
                // Keep writes queued, so the test does not need a live PTY.
                try tb.write_queue.append(alloc, 0);
            }
            var incoming: [2]posix.fd_t = undefined;
            try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&incoming, .{ .CLOEXEC = true, .NONBLOCK = true })));
            app.clipboard.transfer_fd = incoming[0];
            app.clipboard.transfer_action = .{ .terminal = .{ .tab_id = a.id, .target = target, .mime = "text/plain" } };
            try std.testing.expectEqual(@as(usize, 7), linux.write(incoming[1], "payload", 7));
            _ = linux.close(incoming[1]);
            app.readClipboardTransfer();
            try std.testing.expectEqualStrings(if (closed) "\x00" else "\x00\x1b[200~payload\x1b[201~", a.write_queue.items);
            try std.testing.expectEqualStrings("\x00", b.write_queue.items);
        }
    }
}

fn readClipboardTransfer(self: *App) void {
    const osc52_read = self.clipboard.osc52Read();
    const kitty_read_tab_id = self.clipboard.kittyReadTabId();
    const event = self.clipboard.readTransfer() catch |err| {
        log.warn("clipboard transfer failed: {}", .{err});
        if (osc52_read) |read| if (self.findTab(read.tab_id)) |tb| self.writeOsc52ClipboardReport(tb, read.kind, "");
        self.failStartedKittyRead(kitty_read_tab_id, .EIO);
        self.pumpKittyClipboards();
        return;
    } orelse return;
    defer self.pumpKittyClipboards();
    defer self.clipboard.finishEvent();
    switch (event) {
        .terminal => |paste| if (self.findTab(paste.tab_id)) |tb| self.writeTerminalPaste(
            tb,
            .{ .clipboard = clipboardLocation(paste.target) },
            paste.mime,
            paste.data,
        ),
        .osc52_read => |read| if (self.findTab(read.tab_id)) |tb| self.writeOsc52ClipboardReport(tb, read.kind, read.data),
        .kitty_read => |read| {
            const tb = self.findTab(read.tab_id) orelse return;
            const request = switch (tb.kitty_clipboard.front().?.*) {
                .read => |*request| request,
                else => unreachable,
            };
            std.debug.assert(request.started);
            var available_buf: [clipboard_format.paste_mime_preference.len][]const u8 = undefined;
            self.finishKittyClipboardRead(
                tb,
                request,
                self.clipboard.availableMimes(clipboardTargetFromKitty(request.target), &available_buf),
                .{ .mime = read.mime, .data = read.data },
            );
        },
        .dnd => |drop| {
            if (self.tab().term.kitty_dnd) |state| {
                self.writeKittyDndDrop(state, drop);
                return;
            }
            const text = self.formatDropPaste(drop.mime, drop.data) catch return;
            defer self.alloc.free(text);
            self.writeTerminalPaste(self.tab(), .text, "text/plain", text);
        },
    }
}

/// Start and retire committed OSC 5522 operations strictly from the FIFO
/// head. Asynchronous reads stop the pump until their Wayland pipe reaches
/// EOF; writes and metadata-only replies complete immediately in order.
fn pumpKittyClipboard(self: *App, tb: *Tab) void {
    while (tb.kitty_clipboard.front()) |request| {
        switch (request.*) {
            .status => |*status| {
                self.writeKittyClipboardStatus(tb, status.op, status.id, status.terminator, status.status);
                tb.kitty_clipboard.pop();
            },
            .write => |*write| {
                tb.kitty_clipboard.prepareWrite(write);
                const target = clipboardTarget(write.committed.loc) orelse {
                    self.writeKittyClipboardStatus(tb, .write, write.committed.id, write.terminator, .ENOSYS);
                    tb.kitty_clipboard.pop();
                    continue;
                };
                const status: vt.kitty.clipboard.Status = if (write.committed.contents.len == 0)
                    if (self.clipboard.clear(target, self.last_serial)) .DONE else .ENOSYS
                else status: {
                    const text = for (write.committed.contents) |content| {
                        if (vt.clipboard.isTextMime(content.mime)) break content.data;
                    } else break :status .ENOSYS;
                    const owned = self.alloc.dupeZ(u8, text) catch break :status .EIO;
                    break :status if (self.clipboard.claim(target, owned, self.last_serial)) .DONE else .ENOSYS;
                };
                self.writeKittyClipboardStatus(tb, .write, write.committed.id, write.terminator, status);
                tb.kitty_clipboard.pop();
            },
            .read => |*read| {
                if (read.started) return;
                tb.kitty_clipboard.prepareRead(read) catch {
                    self.writeKittyClipboardStatus(tb, .read, read.id, read.terminator, .EIO);
                    tb.kitty_clipboard.pop();
                    continue;
                };
                if (read.paste) |paste| {
                    const available = [_][]const u8{paste.mime};
                    self.finishKittyClipboardRead(tb, read, &available, paste);
                    continue;
                }
                if (!read.needsTransfer()) {
                    var available_buf: [clipboard_format.paste_mime_preference.len][]const u8 = undefined;
                    self.finishKittyClipboardRead(
                        tb,
                        read,
                        self.clipboard.availableMimes(clipboardTargetFromKitty(read.target), &available_buf),
                        null,
                    );
                    continue;
                }

                switch (self.clipboard.request(clipboardTargetFromKitty(read.target), .{ .kitty_read = tb.id })) {
                    .started => {
                        read.started = true;
                        return;
                    },
                    .busy => return,
                    .unavailable => {
                        self.finishKittyClipboardRead(tb, read, &.{}, null);
                        continue;
                    },
                }
            },
        }
    }
}

fn finishKittyClipboardRead(
    self: *App,
    owner: *Tab,
    read: *const KittyClipboard.Read,
    available: []const []const u8,
    content: ?vt.clipboard.Content,
) void {
    var writer: std.Io.Writer.Allocating = .init(self.alloc);
    defer writer.deinit();
    read.encodeSuccess(&writer.writer, available, content) catch {
        self.writeKittyClipboardStatus(owner, .read, read.id, read.terminator, .EIO);
        owner.kitty_clipboard.pop();
        return;
    };
    owner.writePty(writer.writer.buffered());
    owner.kitty_clipboard.pop();
}

fn failStartedKittyRead(self: *App, tab_id: ?u64, status: vt.kitty.clipboard.Status) void {
    // The active transfer records its originating tab ID in Clipboard.
    // A closed requester is intentionally not resurrected or redirected.
    const owner = self.findTab(tab_id orelse return) orelse return;
    const request = owner.kitty_clipboard.front() orelse return;
    const read = switch (request.*) {
        .read => |*read| read,
        else => return,
    };
    if (!read.started) return;
    self.writeKittyClipboardStatus(owner, .read, read.id, read.terminator, status);
    owner.kitty_clipboard.pop();
}

fn pumpKittyClipboards(self: *App) void {
    for (self.tabs.items) |tb| self.pumpKittyClipboard(tb);
}

fn writeKittyClipboardStatus(
    self: *App,
    tb: *Tab,
    op: vt.kitty.clipboard.Operation,
    id: []const u8,
    terminator: vt.osc.Terminator,
    status: vt.kitty.clipboard.Status,
) void {
    var writer: std.Io.Writer.Allocating = .init(self.alloc);
    defer writer.deinit();
    (vt.kitty.clipboard.Response{
        .op = op,
        .status = status,
        .id = id,
        .terminator = terminator,
    }).encode(&writer.writer) catch return;
    tb.writePty(writer.writer.buffered());
}

fn writeTerminalPaste(
    self: *App,
    tb: *Tab,
    source: vt.PasteSource,
    mime: []const u8,
    data: []const u8,
) void {
    if (data.len == 0) return;

    switch (source) {
        .clipboard => |location| if (tb.term.modes.get(.kitty_paste_events)) {
            const target = clipboardTarget(location) orelse return;
            var writer: std.Io.Writer.Allocating = .init(self.alloc);
            defer writer.deinit();
            tb.kitty_clipboard.paste(
                self.io,
                kittyClipboardTarget(target),
                mime,
                data,
                &writer.writer,
            ) catch |err| {
                log.warn("Kitty clipboard paste event failed: {}", .{err});
                return;
            };
            tb.writePty(writer.writer.buffered());
            return;
        },
        .text => {},
    }

    // STRING is Latin-1, unlike the other accepted text representations.
    // Decode only ordinary paste; Kitty transfers retain their MIME and bytes.
    const decoded = if (std.mem.eql(u8, mime, "STRING"))
        clipboard_format.decodeLatin1(self.alloc, data) catch return
    else
        null;
    defer if (decoded) |text| self.alloc.free(text);
    const contents = [_]vt.clipboard.Content{.{
        .mime = if (decoded != null) "text/plain;charset=utf-8" else mime,
        .data = decoded orelse data,
    }};
    _ = tb.stream.handler.terminal_handler.paste(.{
        .source = source,
        .contents = .{ .memory = &contents },
        // Preserve Monstar's existing paste policy. libghostty still applies
        // bracket framing and xterm control-byte sanitization.
        .allow_unsafe = true,
    }) catch |err| {
        log.warn("terminal paste failed: {}", .{err});
    };
}

test "ordinary STRING pastes and text drops decode Latin-1" {
    const alloc = std.testing.allocator;
    const linux = std.os.linux;
    var output: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&output, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(output[0]);
    defer _ = linux.close(output[1]);

    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.alloc = alloc;
    app.io = std.testing.io;
    app.clipboard = .init(alloc, null, null);
    defer app.clipboard.deinit();
    const tb = pipeBackedTab(alloc, output[1]);
    defer alloc.destroy(tb);
    defer tb.kitty_clipboard.deinit();
    tb.app = app;
    tb.term = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer tb.term.deinit(alloc);
    tb.stream = .init(.{
        .allocator = alloc,
        .handler = .{ .app = app, .tab = tb, .terminal_handler = .init(&tb.term) },
    });
    defer tb.stream.deinit();
    tb.stream.handler.terminal_handler.effects = .readonly;
    tb.stream.handler.terminal_handler.effects.write_pty = effectWritePty;
    tb.write_queue = .empty;
    tb.write_queue_offset = 0;
    defer tb.write_queue.deinit(alloc);
    app.tabs = .empty;
    defer app.tabs.deinit(alloc);
    try app.tabs.append(alloc, tb);
    app.active = tb;

    // C3 A9 is valid UTF-8 too, but STRING still means two Latin-1 characters.
    const latin1 = "caf\xe9 \xa3\xff \xc3\xa9\n";
    const utf8 = "café £ÿ Ã©\n";
    const cases = [_]struct { mime: []const u8, data: []const u8 }{
        .{ .mime = "STRING", .data = latin1 },
        .{ .mime = "UTF8_STRING", .data = utf8 },
    };
    for (cases) |case| {
        tb.term.modes.set(.bracketed_paste, false);
        app.writeTerminalPaste(tb, .{ .clipboard = .standard }, case.mime, case.data);
        var buf: [128]u8 = undefined;
        const n = try posix.read(output[0], &buf);
        try std.testing.expectEqualStrings("café £ÿ Ã©\r", buf[0..n]);

        tb.term.modes.set(.bracketed_paste, true);
        app.writeTerminalPaste(tb, .{ .clipboard = .selection }, case.mime, case.data);
        const bracketed_n = try posix.read(output[0], &buf);
        try std.testing.expectEqualStrings("\x1b[200~café £ÿ Ã©\n\x1b[201~", buf[0..bracketed_n]);

        const drop = try app.formatDropPaste(case.mime, case.data);
        defer alloc.free(drop);
        try std.testing.expectEqualStrings(utf8, drop);
    }
}

fn kittyClipboardTarget(target: Clipboard.Target) KittyClipboard.Target {
    return switch (target) {
        .clipboard => .clipboard,
        .primary => .primary,
    };
}

fn clipboardTargetFromKitty(target: KittyClipboard.Target) Clipboard.Target {
    return switch (target) {
        .clipboard => .clipboard,
        .primary => .primary,
    };
}

fn clipboardLocation(target: Clipboard.Target) vt.clipboard.Location {
    return switch (target) {
        .clipboard => .standard,
        .primary => .primary,
    };
}

fn dndEvent(ctx: *anyopaque, event: Clipboard.DndEvent) bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    const state = self.tab().term.kitty_dnd orelse return false;

    var writer: std.Io.Writer.Allocating = .init(self.alloc);
    defer writer.deinit();
    switch (event) {
        .motion => |motion| {
            const mimes = [_][]const u8{motion.mime};
            state.dragMove(
                self.alloc,
                &writer.writer,
                self.kittyDndMove(motion.x, motion.y, motion.operations),
                &mimes,
            ) catch return true;
        },
        .leave => state.dragLeave(self.alloc, &writer.writer) catch return true,
    }
    self.tab().writePty(writer.writer.buffered());
    return true;
}

fn writeKittyDndDrop(
    self: *App,
    state: *vt.kitty.dnd.State,
    drop: Clipboard.DndData,
) void {
    var writer: std.Io.Writer.Allocating = .init(self.alloc);
    defer writer.deinit();
    const items = [_]vt.kitty.dnd.Item{.{ .mime = drop.mime, .data = drop.data }};
    state.dragDrop(
        self.alloc,
        &writer.writer,
        self.kittyDndMove(drop.x, drop.y, drop.operations),
        &items,
    ) catch |err| {
        log.warn("Kitty drag-and-drop failed: {}", .{err});
        return;
    };
    self.tab().writePty(writer.writer.buffered());
}

fn kittyDndMove(
    self: *const App,
    logical_x: f64,
    logical_y: f64,
    operations: Clipboard.DndOperations,
) vt.kitty.dnd.MoveEvent {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    const pixel_x = @max(0, logical_x * scale - @as(f64, @floatFromInt(self.layout.grid_x)));
    const pixel_y = @max(0, logical_y * scale - @as(f64, @floatFromInt(self.layout.grid_y)));
    const cell_x: u32 = @intFromFloat(@min(
        pixel_x / @as(f64, @floatFromInt(self.font.cell_width)),
        @as(f64, @floatFromInt(self.tab().term.cols -| 1)),
    ));
    const cell_y: u32 = @intFromFloat(@min(
        pixel_y / @as(f64, @floatFromInt(self.font.cell_height)),
        @as(f64, @floatFromInt(self.tab().term.rows -| 1)),
    ));
    return .{
        .cell_x = cell_x,
        .cell_y = cell_y,
        .pixel_x = @intFromFloat(@min(pixel_x, std.math.maxInt(i32))),
        .pixel_y = @intFromFloat(@min(pixel_y, std.math.maxInt(i32))),
        .operations = .{ .copy = operations.copy, .move = operations.move },
    };
}

fn formatDropPaste(self: *App, mime: []const u8, data: []const u8) ![]u8 {
    if (std.mem.eql(u8, mime, "STRING")) return clipboard_format.decodeLatin1(self.alloc, data);
    if (!std.mem.eql(u8, mime, clipboard_format.uri_list_mime)) return self.alloc.dupe(u8, data);
    return try clipboard_format.formatUriListDrop(self.alloc, data);
}

fn scrollTarget(self: *const App) ScrollTarget {
    if (self.tab().term.flags.mouse_event != .none) return .application;
    return if (self.tab().term.screens.active_key == .alternate) .keys else .viewport;
}

fn syncScrollTarget(self: *App) void {
    const target = self.scrollTarget();
    if (target == self.scroll_target) return;
    self.scroll_target = target;

    // Remainders and kinetic motion belong to the previous recipient. In
    // particular, raw precision pixels must not acquire the new scale.
    self.stopFling();
    self.resetScrollVelocity();
    self.scroll_pixels = 0;
    self.scroll_frame_pixels = 0;
    self.scroll_clicks = 0;
    self.scroll_value120 = 0;
    self.scroll_line_remainder = 0;
    self.scroll_source = .wheel;
    self.scroll_had_pixels = false;
    self.scroll_had_discrete = false;
    self.scroll_had_value120 = false;
    self.scroll_stopped = false;
}

/// Convert accumulated wheel movement into scrolled lines: wheel clicks
/// count fixed lines, smooth (touchpad) scroll counts cell heights.
fn finishScrollFrame(self: *App) void {
    self.syncScrollTarget();
    if (self.scroll_had_pixels) {
        if (self.scroll_source == .finger) {
            self.trackScrollVelocity(self.scroll_frame_pixels, self.scroll_time_ms);
        } else {
            self.resetScrollVelocity();
        }
    } else if (self.scroll_had_discrete or self.scroll_had_value120) {
        self.resetScrollVelocity();
    }

    // Mouse-tracking applications interpret wheel events themselves. Keep
    // configured scaling for the viewport and alternate-screen key fallback.
    const discrete_multiplier = if (self.scroll_target == .application)
        1
    else
        self.config.mouse_scroll_multiplier.discrete;

    var lines: i32 = 0;
    if (self.scroll_had_value120) {
        const wheel_ticks = @as(f64, @floatFromInt(self.scroll_value120)) / 120.0;
        const total = wheel_ticks * discrete_multiplier + self.scroll_line_remainder;
        const whole = @trunc(total);
        lines = @intFromFloat(whole);
        self.scroll_line_remainder = total - whole;
    } else if (self.scroll_had_discrete) {
        const total = @as(f64, @floatFromInt(self.scroll_clicks)) * discrete_multiplier +
            self.scroll_line_remainder;
        const whole = @trunc(total);
        lines = @intFromFloat(whole);
        self.scroll_line_remainder = total - whole;
    } else if (self.scroll_pixels != 0) {
        // Logical pixels per row: physical cell height descaled.
        const cell: f64 = @as(f64, @floatFromInt(self.font.cell_height)) * 120.0 /
            @as(f64, @floatFromInt(self.window.scale120));
        const multiplier = self.precisionScrollScale();
        const pixels = self.scroll_pixels * multiplier;
        const whole = @divTrunc(pixels, cell);
        lines = @intFromFloat(whole);
        self.scroll_pixels -= whole * cell / multiplier;
    }
    if (self.scroll_had_value120 or self.scroll_had_discrete) self.scroll_pixels = 0;
    self.scroll_frame_pixels = 0;
    self.scroll_clicks = 0;
    self.scroll_value120 = 0;
    self.scroll_source = .wheel;
    self.scroll_had_pixels = false;
    self.scroll_had_discrete = false;
    self.scroll_had_value120 = false;
    if (lines != 0) self.scrollLines(lines);
    if (self.scroll_stopped) {
        self.scroll_stopped = false;
        self.startFling();
        self.resetScrollVelocity();
    }
}

fn precisionScrollScale(self: *const App) f64 {
    if (self.scrollTarget() == .application) return 1;
    return wayland_precision_scroll_scale * self.config.mouse_scroll_multiplier.precision;
}

/// Fold one finger-scroll frame into an exponential moving average in
/// effective content pixels per second.
fn trackScrollVelocity(self: *App, pixels: f64, time_ms: u32) void {
    defer self.last_scroll_time_ms = time_ms;
    const last = self.last_scroll_time_ms orelse return;
    const dt_ms: f64 = @floatFromInt(time_ms -% last);
    if (dt_ms <= 0 or dt_ms > 200) return;
    const velocity = pixels * self.precisionScrollScale() / dt_ms * 1000.0;
    self.scroll_velocity = (1 - velocity_smoothing) * self.scroll_velocity + velocity_smoothing * velocity;
}

fn resetScrollVelocity(self: *App) void {
    self.scroll_velocity = 0;
    self.last_scroll_time_ms = null;
}

fn startFling(self: *App) void {
    if (!self.config.inertial_scrolling) return;
    const velocity = std.math.clamp(self.scroll_velocity, -fling_max_velocity, fling_max_velocity);
    if (@abs(velocity) < fling_start_velocity) return;

    const interval = timespecFromNs(fling_interval_ms * std.time.ns_per_ms);
    const spec: std.os.linux.itimerspec = .{ .it_value = interval, .it_interval = interval };
    if (!setTimer(self.fling_fd, spec, "fling")) return;
    self.fling_velocity = velocity;
    self.fling_active = true;
}

fn stopFling(self: *App) void {
    if (!self.fling_active) return;
    self.fling_active = false;
    _ = setTimer(self.fling_fd, disarmed_timer, "fling");
}

fn fireFling(self: *App) void {
    self.syncScrollTarget();
    const expirations = readTimer(self.fling_fd) orelse return;
    if (!self.fling_active) return;

    const dt_ms: f64 = @floatFromInt(fling_interval_ms * expirations);
    self.scroll_pixels += self.fling_velocity * dt_ms / 1000.0 / self.precisionScrollScale();
    self.finishScrollFrame();

    self.fling_velocity *= std.math.pow(f64, fling_decay_per_ms, dt_ms);
    if (@abs(self.fling_velocity) < fling_min_velocity) self.stopFling();
}

test "wheel frames route reports, viewport movement, and keys without sharing remainders" {
    const alloc = std.testing.allocator;
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.alloc = alloc;
    app.config = .{};
    const tb = pipeBackedTab(alloc, -1);
    defer alloc.destroy(tb);
    defer tb.kitty_clipboard.deinit();
    app.tabs = .empty;
    defer app.tabs.deinit(alloc);
    try app.tabs.append(alloc, tb);
    app.active = tb;
    tb.app = app;
    tb.term = try .init(std.testing.io, alloc, .{ .cols = 16, .rows = 3, .max_scrollback_bytes = 100_000 });
    defer tb.term.deinit(alloc);
    tb.stream = .init(.{ .allocator = alloc, .handler = .{ .app = app, .tab = tb, .terminal_handler = .init(&tb.term) } });
    defer tb.stream.deinit();
    var stream = tb.term.vtStream();
    defer stream.deinit();
    tb.write_queue = .empty;
    defer tb.write_queue.deinit(alloc);
    // A backlog keeps actual encoded PTY input in the queue without a child.
    try tb.write_queue.append(alloc, 0);
    tb.write_queue_offset = 0;
    app.keyboard.state = null;
    app.window = try alloc.create(Window);
    defer alloc.destroy(app.window);
    app.window.pointer_enter_serial = null;
    app.window.scale120 = 120;
    app.window.cursor_shape = .text;
    app.window.pointer = null;
    app.font.cell_width = 10;
    app.font.cell_height = 20;
    app.layout = .init(160, 60, 10, 20, .{});
    app.pointer_x = 5;
    app.pointer_y = 5;
    app.pointer_inside = false;
    app.mouse_button = null;
    tb.mouse_shape_explicit = false;
    app.selection_gesture = .init;
    app.selection_autoscroll_fd = try createTimerFd();
    defer _ = std.os.linux.close(app.selection_autoscroll_fd);
    app.scrollbar_fd = try createTimerFd();
    defer _ = std.os.linux.close(app.scrollbar_fd);
    app.fling_fd = try createTimerFd();
    defer _ = std.os.linux.close(app.fling_fd);
    app.scrollbar_drag = null;
    app.scrollbar_hovered = false;
    app.scrollbar_reveal_hovered = false;
    app.scrollbar_alpha = 0;
    app.async_generation = 0;
    app.held_frame = null;
    app.hovered_link = null;
    app.link_active = false;
    app.link_checked_cell = null;
    app.fling_active = false;
    // Force the same initialization used when a new recipient takes over.
    app.scroll_target = .application;
    app.syncScrollTarget();

    for ([_][]const u8{ "\x1b[?9h", "\x1b[?1000h", "\x1b[?1002h", "\x1b[?1003h" }, 0..) |mode, mode_index| {
        stream.nextSlice(mode);
        stream.nextSlice("\x1b[?1006h");
        for ([_]bool{ false, true }) |alternate| {
            stream.nextSlice(if (alternate) "\x1b[?1049h" else "\x1b[?1049l");
            for ([_]f64{ 0.01, 0.25, 3, 10_000 }) |multiplier| {
                app.config.mouse_scroll_multiplier = .{ .discrete = multiplier, .precision = multiplier };
                for ([_]i32{ -1, 1 }) |sign| {
                    for (0..3) |form| {
                        tb.write_queue.shrinkRetainingCapacity(1);
                        switch (form) {
                            0 => pointerEvent(app, .{ .axis_discrete = .{ .axis = .vertical_scroll, .discrete = sign } }),
                            1 => pointerEvent(app, .{ .axis_value120 = .{ .axis = .vertical_scroll, .value120 = sign * 120 } }),
                            else => pointerEvent(app, .{ .axis = .{ .axis = .vertical_scroll, .time = 100, .value = .fromDouble(@as(f64, @floatFromInt(sign)) * 20) } }),
                        }
                        pointerEvent(app, .frame);
                        // X10 suppresses wheel buttons; the other modes emit one report.
                        const expected = if (mode_index == 0) "" else if (sign < 0) "\x1b[<64;1;1M" else "\x1b[<65;1;1M";
                        try std.testing.expectEqualStrings(expected, tb.write_queue.items[1..]);
                    }
                }
            }
        }
    }

    // Partial detents and precision pixels truncate toward zero, including reversals.
    for ([_]i32{ -1, 1 }) |sign| {
        tb.write_queue.shrinkRetainingCapacity(1);
        for ([_]i32{ 60, -30, 90 }, 0..) |amount, index| {
            pointerEvent(app, .{ .axis_value120 = .{ .axis = .vertical_scroll, .value120 = sign * amount } });
            pointerEvent(app, .frame);
            if (index < 2) try std.testing.expectEqual(@as(usize, 1), tb.write_queue.items.len);
        }
        try std.testing.expectEqualStrings(if (sign < 0) "\x1b[<64;1;1M" else "\x1b[<65;1;1M", tb.write_queue.items[1..]);
        tb.write_queue.shrinkRetainingCapacity(1);
        for ([_]f64{ 7, -2, 15 }, 0..) |amount, index| {
            pointerEvent(app, .{ .axis = .{ .axis = .vertical_scroll, .time = 100, .value = .fromDouble(@as(f64, @floatFromInt(sign)) * amount) } });
            pointerEvent(app, .frame);
            if (index < 2) try std.testing.expectEqual(@as(usize, 1), tb.write_queue.items.len);
        }
        try std.testing.expectEqualStrings(if (sign < 0) "\x1b[<64;1;1M" else "\x1b[<65;1;1M", tb.write_queue.items[1..]);
    }

    // value120 takes precedence over the legacy forms in the same frame.
    tb.write_queue.shrinkRetainingCapacity(1);
    pointerEvent(app, .{ .axis = .{ .axis = .vertical_scroll, .time = 100, .value = .fromDouble(80) } });
    pointerEvent(app, .{ .axis_discrete = .{ .axis = .vertical_scroll, .discrete = 2 } });
    pointerEvent(app, .{ .axis_value120 = .{ .axis = .vertical_scroll, .value120 = -120 } });
    pointerEvent(app, .frame);
    try std.testing.expectEqualStrings("\x1b[<64;1;1M", tb.write_queue.items[1..]);
    try std.testing.expectEqual(@as(f64, 0), app.scroll_pixels);

    // Local scrolling moves history instead of writing PTY input.
    stream.nextSlice("\x1b[?1049l\x1b[?1003l");
    for (0..30) |_| stream.nextSlice("line\r\n");
    app.config.mouse_scroll_multiplier = .{ .discrete = 3, .precision = 2 };
    const offset = tb.term.screens.active.pages.scrollbar().offset;
    tb.write_queue.shrinkRetainingCapacity(1);
    pointerEvent(app, .{ .axis_discrete = .{ .axis = .vertical_scroll, .discrete = -1 } });
    pointerEvent(app, .frame);
    try std.testing.expectEqual(offset - 3, tb.term.screens.active.pages.scrollbar().offset);
    pointerEvent(app, .{ .axis_value120 = .{ .axis = .vertical_scroll, .value120 = -120 } });
    pointerEvent(app, .frame);
    try std.testing.expectEqual(offset - 6, tb.term.screens.active.pages.scrollbar().offset);
    pointerEvent(app, .{ .axis = .{ .axis = .vertical_scroll, .time = 100, .value = .fromDouble(-10) } });
    pointerEvent(app, .frame);
    try std.testing.expectEqual(offset - 9, tb.term.screens.active.pages.scrollbar().offset);
    try std.testing.expectEqual(@as(usize, 1), tb.write_queue.items.len);

    stream.nextSlice("\x1b[?1049h");
    pointerEvent(app, .{ .axis_discrete = .{ .axis = .vertical_scroll, .discrete = -1 } });
    pointerEvent(app, .frame);
    try std.testing.expectEqualStrings("\x1b[A\x1b[A\x1b[A", tb.write_queue.items[1..]);

    // A local half-line must not cancel the first opposite application detent.
    stream.nextSlice("\x1b[?1049l");
    app.config.mouse_scroll_multiplier.discrete = 0.5;
    pointerEvent(app, .{ .axis_discrete = .{ .axis = .vertical_scroll, .discrete = -1 } });
    pointerEvent(app, .frame);
    try std.testing.expectEqual(@as(f64, -0.5), app.scroll_line_remainder);
    stream.nextSlice("\x1b[?1000h");
    tb.write_queue.shrinkRetainingCapacity(1);
    pointerEvent(app, .{ .axis_discrete = .{ .axis = .vertical_scroll, .discrete = 1 } });
    pointerEvent(app, .frame);
    try std.testing.expectEqualStrings("\x1b[<65;1;1M", tb.write_queue.items[1..]);

    // The reverse handoff must not lend an application's partial detent to local scrolling.
    pointerEvent(app, .{ .axis_value120 = .{ .axis = .vertical_scroll, .value120 = 60 } });
    pointerEvent(app, .frame);
    stream.nextSlice("\x1b[?1000l");
    const before = tb.term.screens.active.pages.scrollbar().offset;
    pointerEvent(app, .{ .axis_discrete = .{ .axis = .vertical_scroll, .discrete = 1 } });
    pointerEvent(app, .frame);
    try std.testing.expectEqual(before, tb.term.screens.active.pages.scrollbar().offset);
    try std.testing.expectEqual(@as(f64, 0.5), app.scroll_line_remainder);

    // A frame without new scroll must not reinterpret pending local pixels as reports or keys.
    for ([_][]const u8{ "\x1b[?1000h", "\x1b[?1049h" }) |takeover| {
        stream.nextSlice("\x1b[?1000l\x1b[?1049l");
        app.config.mouse_scroll_multiplier.precision = 0.01;
        tb.write_queue.shrinkRetainingCapacity(1);
        pointerEvent(app, .{ .axis = .{ .axis = .vertical_scroll, .time = 100, .value = .fromDouble(100) } });
        pointerEvent(app, .frame);
        try std.testing.expectEqual(@as(f64, 100), app.scroll_pixels);
        stream.nextSlice(takeover);
        pointerEvent(app, .frame);
        try std.testing.expectEqualStrings("", tb.write_queue.items[1..]);
        try std.testing.expectEqual(@as(f64, 0), app.scroll_pixels);
    }

    // Exercise the real timer consumer: one 8 ms tick at 3000 px/s is 24 pixels.
    stream.nextSlice("\x1b[?1049l\x1b[?1000h");
    app.syncScrollTarget();
    for ([_]f64{ 0.01, 1, 10_000 }) |multiplier| {
        app.config.mouse_scroll_multiplier.precision = multiplier;
        app.scroll_pixels = 0;
        app.resetScrollVelocity();
        app.trackScrollVelocity(40, 100);
        app.trackScrollVelocity(40, 110);
        app.startFling();
        try std.testing.expect(app.fling_active);
        try std.testing.expectEqual(@as(f64, 3000), app.fling_velocity);
        // A one-shot timer guarantees one expiration regardless of scheduler delay.
        try std.testing.expect(setTimer(app.fling_fd, .{ .it_value = timespecFromNs(1), .it_interval = .{ .sec = 0, .nsec = 0 } }, "test fling"));
        var fds = [_]posix.pollfd{.{ .fd = app.fling_fd, .events = posix.POLL.IN, .revents = 0 }};
        try std.testing.expectEqual(@as(usize, 1), try posix.poll(&fds, 1000));
        tb.write_queue.shrinkRetainingCapacity(1);
        app.fireFling();
        try std.testing.expectEqualStrings("\x1b[<65;1;1M", tb.write_queue.items[1..]);
        try std.testing.expectEqual(@as(f64, 4), app.scroll_pixels);
        app.stopFling();
    }

    // Mode changes cancel a running fling before it can deliver to another recipient.
    app.scroll_velocity = 3000;
    app.startFling();
    stream.nextSlice("\x1b[?1000l");
    tb.write_queue.shrinkRetainingCapacity(1);
    app.fireFling();
    try std.testing.expect(!app.fling_active);
    try std.testing.expectEqual(@as(f64, 0), app.scroll_pixels);
    try std.testing.expectEqual(@as(f64, 0), app.scroll_velocity);
    try std.testing.expectEqualStrings("", tb.write_queue.items[1..]);
}

test "application fling threshold ignores precision configuration" {
    const alloc = std.testing.allocator;
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.alloc = alloc;
    app.config = .{};
    const tb = pipeBackedTab(alloc, -1);
    defer alloc.destroy(tb);
    defer tb.kitty_clipboard.deinit();
    defer tb.write_queue.deinit(alloc);
    app.tabs = .empty;
    defer app.tabs.deinit(alloc);
    try app.tabs.append(alloc, tb);
    app.active = tb;
    tb.app = app;
    tb.term = try .init(std.testing.io, alloc, .{ .cols = 2, .rows = 1 });
    defer tb.term.deinit(alloc);
    tb.term.flags.mouse_event = .normal;
    app.fling_fd = try createTimerFd();
    defer _ = std.os.linux.close(app.fling_fd);
    for ([_]f64{ 0.01, 1, 10_000 }) |multiplier| {
        app.config.mouse_scroll_multiplier.precision = multiplier;
        for ([_]f64{ -4, -1, 1, 4 }) |pixels| {
            app.fling_active = false;
            app.resetScrollVelocity();
            app.trackScrollVelocity(pixels, 100);
            app.trackScrollVelocity(pixels, 110);
            app.startFling();
            try std.testing.expectEqual(pixels * 75, app.scroll_velocity);
            try std.testing.expectEqual(@abs(pixels) == 4, app.fling_active);
            app.stopFling();
        }
    }
}

fn scrollbarAtBottom(scrollbar: vt.PageList.Scrollbar) bool {
    return scrollbar.total <= scrollbar.len or
        scrollbar.offset >= scrollbar.total - scrollbar.len;
}

fn scrollbarShouldRender(
    scrollbar: vt.PageList.Scrollbar,
    alpha: u8,
) bool {
    return alpha > 0 and scrollbar.total > scrollbar.len;
}

fn scrollbarGeometry(
    scrollbar: vt.PageList.Scrollbar,
    layout: TerminalLayout,
    scale120: u32,
    alpha: u8,
) ?ScrollbarGeometry {
    if (scrollbar.total <= scrollbar.len or layout.surface_width == 0 or layout.grid_height == 0) return null;

    const inset = @min(Window.physicalDimension(scrollbar_inset, scale120), layout.grid_height / 2);
    const track_y = layout.grid_y + inset;
    const track_height = layout.grid_height - inset * 2;
    if (track_height == 0) return null;

    const desired_width = @max(1, Window.physicalDimension(scrollbar_width, scale120));
    const right = layout.surface_width -| inset;
    if (right == 0) return null;
    const width = @min(desired_width, right);
    const min_height = @min(track_height, @max(1, Window.physicalDimension(scrollbar_min_thumb, scale120)));
    const proportional: u31 = @intCast(
        (@as(u128, track_height) * scrollbar.len) / scrollbar.total,
    );
    const thumb_height = @min(track_height, @max(min_height, @max(1, proportional)));
    const travel = track_height - thumb_height;
    const max_offset = scrollbar.total - scrollbar.len;
    const offset = @min(scrollbar.offset, max_offset);
    const thumb_offset: u31 = if (travel == 0)
        0
    else
        @intCast((@as(u128, travel) * offset + max_offset / 2) / max_offset);

    return .{
        .thumb = .{
            .x = right - width,
            .y = track_y + thumb_offset,
            .width = width,
            .height = thumb_height,
            .alpha = alpha,
        },
        .track_y = track_y,
        .travel = travel,
        .max_offset = max_offset,
    };
}

fn scrollbarRowForThumbY(geometry: ScrollbarGeometry, thumb_y: f64) usize {
    if (geometry.travel == 0) return 0;
    const relative = std.math.clamp(
        thumb_y - @as(f64, @floatFromInt(geometry.track_y)),
        0,
        @as(f64, @floatFromInt(geometry.travel)),
    );
    return @intFromFloat(@round(
        relative / @as(f64, @floatFromInt(geometry.travel)) *
            @as(f64, @floatFromInt(geometry.max_offset)),
    ));
}

fn currentScrollbarGeometry(self: *App, alpha: u8) ?ScrollbarGeometry {
    return scrollbarGeometry(
        self.tab().term.screens.active.pages.scrollbar(),
        self.layout,
        self.window.scale120,
        alpha,
    );
}

fn currentScrollbarThumb(self: *App) ?Renderer.ScrollbarThumb {
    const scrollbar = self.tab().term.screens.active.pages.scrollbar();
    if (!scrollbarShouldRender(scrollbar, self.scrollbar_alpha)) return null;
    const geometry = scrollbarGeometry(scrollbar, self.layout, self.window.scale120, self.scrollbar_alpha) orelse return null;
    return geometry.thumb;
}

fn cubicBezierCoordinate(t: f64, control_1: f64, control_2: f64) f64 {
    const inverse = 1.0 - t;
    return 3.0 * inverse * inverse * t * control_1 +
        3.0 * inverse * t * t * control_2 + t * t * t;
}

/// Evaluate Fluent's curveAccelerateMin cubic-bezier(0.8, 0, 0.78, 1)
/// at timeline position `x`.
fn scrollbarFadeProgress(x: f64) f64 {
    std.debug.assert(x >= 0.0 and x <= 1.0);
    if (x == 0.0 or x == 1.0) return x;

    // CSS timing curves map x to y through the Bezier parameter. A short
    // bisection is deterministic and more than precise enough for u8 alpha.
    var low: f64 = 0.0;
    var high: f64 = 1.0;
    for (0..16) |_| {
        const t = (low + high) / 2.0;
        if (cubicBezierCoordinate(t, 0.8, 0.78) < x)
            low = t
        else
            high = t;
    }
    return cubicBezierCoordinate((low + high) / 2.0, 0.0, 1.0);
}

fn scrollbarFadeAlpha(elapsed_ms: u16) u8 {
    if (elapsed_ms >= scrollbar_fade_duration_ms) return 0;
    const progress = @as(f64, @floatFromInt(elapsed_ms)) / scrollbar_fade_duration_ms;
    const initial_alpha: f64 = @floatFromInt(scrollbar_default_alpha);
    return @intFromFloat(@round(initial_alpha * (1.0 - scrollbarFadeProgress(progress))));
}

test "scrollbar fade follows Fluent accelerated exit curve" {
    try std.testing.expectEqual(@as(u8, scrollbar_default_alpha), scrollbarFadeAlpha(0));
    try std.testing.expectEqual(@as(u8, 0), scrollbarFadeAlpha(scrollbar_fade_duration_ms));
    try std.testing.expect(scrollbarFadeAlpha(scrollbar_fade_duration_ms / 2) > scrollbar_default_alpha / 2);

    var previous: u8 = scrollbar_default_alpha;
    var elapsed: u16 = scrollbar_fade_interval_ms;
    while (elapsed <= scrollbar_fade_duration_ms) : (elapsed += scrollbar_fade_interval_ms) {
        const alpha = scrollbarFadeAlpha(elapsed);
        try std.testing.expect(alpha <= previous);
        previous = alpha;
    }
}

fn armScrollbarHold(self: *App) void {
    self.scrollbar_fading = false;
    self.scrollbar_fade_elapsed_ms = 0;
    _ = setTimer(self.scrollbar_fd, .{
        .it_value = timespecFromNs(scrollbar_hold_ms * std.time.ns_per_ms),
        .it_interval = .{ .sec = 0, .nsec = 0 },
    }, "scrollbar");
}

fn hideScrollbar(self: *App) void {
    _ = setTimer(self.scrollbar_fd, disarmed_timer, "scrollbar");
    self.scrollbar_fading = false;
    self.scrollbar_fade_elapsed_ms = 0;
    if (self.scrollbar_alpha == 0) return;
    self.scrollbar_alpha = 0;
    self.requestFullAsyncRedraw();
}

fn revealScrollbar(self: *App) void {
    const scrollbar = self.tab().term.screens.active.pages.scrollbar();
    const at_bottom = scrollbarAtBottom(scrollbar);
    self.scrollbar_fading = false;
    self.scrollbar_fade_elapsed_ms = 0;

    const alpha: u8 = if (self.scrollbar_drag != null or self.scrollbar_hovered)
        scrollbar_hover_alpha
    else
        scrollbar_default_alpha;
    const changed = self.scrollbar_alpha != alpha;
    self.scrollbar_alpha = alpha;
    if (self.scrollbar_drag == null and !self.scrollbar_hovered and
        (!self.scrollbar_reveal_hovered or at_bottom))
        self.armScrollbarHold()
    else
        _ = setTimer(self.scrollbar_fd, disarmed_timer, "scrollbar");
    if (changed) self.requestFullAsyncRedraw();
}

fn fireScrollbarFade(self: *App) void {
    const expirations = readTimer(self.scrollbar_fd) orelse return;
    const at_bottom = scrollbarAtBottom(self.tab().term.screens.active.pages.scrollbar());
    if (self.scrollbar_drag != null or self.scrollbar_hovered or self.scrollbar_alpha == 0 or
        (self.scrollbar_reveal_hovered and !at_bottom)) return;

    if (self.reduced_motion) {
        self.hideScrollbar();
        self.syncHoveredLink(true);
        return;
    }

    if (!self.scrollbar_fading) {
        self.scrollbar_fading = true;
        self.scrollbar_fade_elapsed_ms = 0;
        const interval = timespecFromNs(scrollbar_fade_interval_ms * std.time.ns_per_ms);
        _ = setTimer(self.scrollbar_fd, .{ .it_value = interval, .it_interval = interval }, "scrollbar");
        return;
    }

    const max_ticks = scrollbar_fade_duration_ms / scrollbar_fade_interval_ms;
    const ticks: u16 = @intCast(@min(expirations, max_ticks));
    self.scrollbar_fade_elapsed_ms = @min(
        scrollbar_fade_duration_ms,
        self.scrollbar_fade_elapsed_ms + ticks * scrollbar_fade_interval_ms,
    );
    const alpha = scrollbarFadeAlpha(self.scrollbar_fade_elapsed_ms);
    if (alpha == 0) {
        self.hideScrollbar();
        self.syncHoveredLink(true);
    } else if (alpha != self.scrollbar_alpha) {
        self.scrollbar_alpha = alpha;
        self.requestFullAsyncRedraw();
    }
}

/// Route wheel scrolling (positive = towards newer content): mouse
/// reports when the application asked for them, arrow keys on the
/// alternate screen, otherwise the scrollback viewport.
fn scrollLines(self: *App, lines_down: i32) void {
    const lines_abs: u32 = @abs(lines_down);
    const target = self.scrollTarget();
    if (target == .application) {
        // A selection can exist here via the shift override; scrolling
        // hands control back to the application, so drop it.
        self.clearSelection();
        const button: vt.input.MouseButton = if (lines_down < 0) .four else .five;
        for (0..lines_abs) |_| {
            self.sendMouseEvent(.{
                .action = .press,
                .button = button,
                .mods = self.keyboard.currentMods(),
                .pos = self.pointerPosPhysical(),
            });
        }
        return;
    }

    if (target == .keys) {
        // Full-screen apps without mouse support (pagers, editors)
        // expect cursor keys instead of viewport scrolling; the app
        // will move content, so any selection over it goes stale.
        self.clearSelection();
        const key: vt.input.Key = if (lines_down < 0) .arrow_up else .arrow_down;
        for (0..lines_abs) |_| _ = self.encodeAndWriteKey(.{ .key = key, .action = .press });
        return;
    }

    self.tab().term.screens.active.pages.scroll(.{ .delta_row = lines_down });
    // Scrolling changes which terminal pin is under a stationary pointer.
    // Pointer motion normally advances an active drag, so do the same here
    // after the viewport has moved.
    if (self.selecting) self.extendSelection();
    self.revealScrollbar();
    self.needs_redraw = true;
    self.syncHoveredLink(true);
}

fn sendMouseEvent(self: *App, event: vt.input.MouseEncodeEvent) void {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var opts = vt.input.MouseEncodeOptions.fromTerminal(&self.tab().term, .{
        .screen = .{
            .width = self.layout.surface_width,
            .height = self.layout.surface_height,
        },
        .cell = .{ .width = self.font.cell_width, .height = self.font.cell_height },
        .padding = .{
            .top = self.layout.padding.top,
            .right = self.layout.padding.right,
            .bottom = self.layout.padding.bottom,
            .left = self.layout.padding.left,
        },
    });
    opts.any_button_pressed = event.action == .press or self.mouse_button != null;
    vt.input.encodeMouse(&writer, event, opts) catch return;
    self.tab().writePty(writer.buffered());
}

/// Pointer position in physical (buffer) pixels, as mouse encoding expects.
fn pointerPosPhysical(self: *App) vt.input.MouseEncodeEvent.Pos {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    return .{
        .x = @floatCast(self.pointer_x * scale),
        .y = @floatCast(self.pointer_y * scale),
    };
}

/// Window keyboard delegate: track xkb state and encode key presses
/// into PTY input.
fn keyboardEvent(ctx: *anyopaque, event: wl.Keyboard.Event) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    switch (event) {
        .keymap => |keymap| {
            if (keymap.format != .xkb_v1) {
                log.err("unsupported keymap format {}", .{keymap.format});
                _ = std.os.linux.close(keymap.fd);
                return;
            }
            // A new keymap redefines what the armed repeat keycode means, so stop it.
            self.cancelRepeat();
            // setKeymap takes ownership of the fd.
            self.keyboard.setKeymap(keymap.fd, keymap.size) catch |err| {
                log.err("keymap load failed: {}", .{err});
            };
        },
        .modifiers => |mods| {
            const links_were_active = self.linksActive();
            self.keyboard.updateMods(
                mods.mods_depressed,
                mods.mods_latched,
                mods.mods_locked,
                mods.group,
            );
            if (links_were_active != self.linksActive()) {
                self.syncHoveredLink(true);
            }
        },
        .key => |key| {
            self.last_serial = key.serial;
            const action: vt.input.KeyAction = switch (key.state) {
                .pressed => .press,
                .released => .release,
                .repeated => .repeat,
                else => return,
            };
            self.onKey(key.key, action);
            switch (action) {
                .press => if (self.keyboard.keyRepeats(key.key)) self.armRepeat(key.key),
                .release => if (self.repeat_keycode == key.key) self.cancelRepeat(),
                else => {},
            }
        },
        .repeat_info => |info| {
            self.repeat_rate = info.rate;
            self.repeat_delay = info.delay;
            if (self.repeat_keycode) |keycode| {
                if (repeatTimerSpec(info.rate, info.delay)) |_|
                    self.armRepeat(keycode)
                else
                    self.cancelRepeat();
            }
        },
        // Keys held across a focus change must not keep repeating.
        .leave => {
            self.cancelRepeat();
            self.keyboard.resetTransientState();
            self.setFocus(false);
        },
        .enter => |enter| {
            self.last_serial = enter.serial;
            self.setFocus(true);
        },
    }
}

fn setFocus(self: *App, focused: bool) void {
    if (self.focused == focused) return;
    self.focused = focused;
    self.requestFullAsyncRedraw();
    // Applications with focus reporting (mode 1004) get CSI I / CSI O.
    if (self.tab().term.modes.get(.focus_event)) {
        var buf: [vt.input.max_focus_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        vt.input.encodeFocus(&writer, if (focused) .gained else .lost) catch return;
        self.tab().writePty(writer.buffered());
    }
}

/// Wayland's suspended toplevel state is positive knowledge that the view is
/// hidden. Every other state remains conservatively potentially visible.
fn syncTerminalVisibility(self: *App) void {
    const visible = !self.window.suspended;
    if (self.tab().term.flags.visible == visible) return;
    self.tab().term.flags.visible = visible;
    if (!self.tab().term.modes.get(.report_visibility)) return;

    var buf: [vt.device_status.max_visibility_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    vt.device_status.encodeVisibilityReport(
        &writer,
        if (visible) .potentially_visible else .not_visible,
    ) catch return;
    self.tab().writePty(writer.buffered());
}

fn textInputEvent(ctx: *anyopaque, event: zwp.TextInputV3.Event) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    switch (event) {
        .enter => {
            self.ime_focused = true;
            self.window.enableTextInput(self.textInputCursorRect(self.currentCursorState()));
        },
        .leave => {
            self.ime_focused = false;
            self.window.disableTextInput();
            self.setImePreedit(null);
            self.resetPendingIme();
        },
        .preedit_string => |preedit| {
            self.replaceImeText(&self.ime_pending_preedit, if (preedit.text) |text| std.mem.sliceTo(text, 0) else null);
        },
        .commit_string => |commit| {
            self.replaceImeText(&self.ime_pending_commit, if (commit.text) |text| std.mem.sliceTo(text, 0) else null);
        },
        .delete_surrounding_text => {},
        .done => {
            self.applyPendingIme();
        },
    }
}

fn applyPendingIme(self: *App) void {
    if (self.tab().search != null) {
        if (self.ime_pending_commit) |commit| self.appendSearchText(commit);
        self.setImePreedit(self.ime_pending_preedit);
        self.resetPendingIme();
        return;
    }
    if (self.ime_pending_commit) |commit| {
        if (commit.len > 0) {
            self.tab().writePty(commit);
            self.clearSelection();
            if (self.tab().term.screens.active.pages.viewport != .active) {
                self.tab().term.screens.active.pages.scroll(.active);
                self.revealScrollbar();
                self.syncHoveredLink(true);
            }
        }
    }
    self.setImePreedit(self.ime_pending_preedit);
    self.resetPendingIme();
    self.syncTextInputCursorRect(&self.render_state);
}

fn setImePreedit(self: *App, text: ?[]const u8) void {
    self.replaceImeText(&self.ime_preedit, text);
    self.requestFullAsyncRedraw();
}

fn replaceImeText(self: *App, slot: *?[]u8, text: ?[]const u8) void {
    if (slot.*) |old| self.alloc.free(old);
    slot.* = null;
    const value = text orelse return;
    if (value.len == 0) return;
    slot.* = self.alloc.dupe(u8, value) catch |err| {
        log.warn("failed to copy IME text: {}", .{err});
        return;
    };
}

fn resetPendingIme(self: *App) void {
    self.replaceImeText(&self.ime_pending_preedit, null);
    self.replaceImeText(&self.ime_pending_commit, null);
}

fn clearImeText(self: *App) void {
    self.replaceImeText(&self.ime_preedit, null);
    self.resetPendingIme();
}

/// Start (or move) key repeat to the given key: first fire after the
/// configured delay, then at the configured rate.
fn armRepeat(self: *App, evdev_keycode: u32) void {
    const spec = repeatTimerSpec(self.repeat_rate, self.repeat_delay) orelse return;
    self.repeat_keycode = evdev_keycode;
    _ = setTimer(self.repeat_fd, spec, "key repeat");
}

fn cancelRepeat(self: *App) void {
    self.repeat_keycode = null;
    _ = setTimer(self.repeat_fd, disarmed_timer, "key repeat");
}

fn repeatTimerSpec(rate: i32, delay_ms: i32) ?std.os.linux.itimerspec {
    if (rate <= 0 or delay_ms < 0) return null;
    const interval_ns = @max(
        1,
        @divTrunc(std.time.ns_per_s, @as(u64, @intCast(rate))),
    );
    // A zero timerfd value disarms the timer, so represent Wayland's legal
    // zero-millisecond delay with the shortest possible initial interval.
    const delay_ns = @max(1, @as(u64, @intCast(delay_ms)) * std.time.ns_per_ms);
    return .{
        .it_value = timespecFromNs(delay_ns),
        .it_interval = timespecFromNs(interval_ns),
    };
}

test "key repeat timer accepts zero delay and disables zero rate" {
    const immediate = repeatTimerSpec(25, 0).?;
    try std.testing.expectEqual(@as(isize, 0), immediate.it_value.sec);
    try std.testing.expectEqual(@as(isize, 1), immediate.it_value.nsec);
    try std.testing.expectEqual(@as(isize, 40 * std.time.ns_per_ms), immediate.it_interval.nsec);

    try std.testing.expectEqual(null, repeatTimerSpec(0, 500));
    try std.testing.expectEqual(null, repeatTimerSpec(25, -1));
}

fn createTimerFd() !posix.fd_t {
    const rc = std.os.linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (std.os.linux.errno(rc) != .SUCCESS) return error.TimerFdFailed;
    return @intCast(rc);
}

fn setTimer(fd: posix.fd_t, spec: std.os.linux.itimerspec, label: []const u8) bool {
    const rc = std.os.linux.timerfd_settime(fd, .{}, &spec, null);
    const err = std.os.linux.errno(rc);
    if (err == .SUCCESS) return true;
    log.err("{s} timerfd_settime failed: {}", .{ label, err });
    return false;
}

fn readTimer(fd: posix.fd_t) ?u64 {
    var expirations: u64 = 0;
    const n = posix.read(fd, std.mem.asBytes(&expirations)) catch return null;
    return if (n == @sizeOf(u64) and expirations > 0) expirations else null;
}

fn timespecFromNs(ns: u64) std.os.linux.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

/// The repeat timer expired: re-send the held key.
fn fireRepeat(self: *App) void {
    const expirations = readTimer(self.repeat_fd) orelse return;
    const keycode = self.repeat_keycode orelse return;
    // Cap the burst so a stalled loop can't flood the PTY.
    for (0..@min(expirations, 8)) |_| self.onKey(keycode, .repeat);
}

fn fireKittyAnimation(self: *App) void {
    _ = readTimer(self.kitty_animation_fd) orelse return;
    self.needs_redraw = true;
}

fn syncScrollbackCompression(self: *App) void {
    const activity = self.tab().term.compressionActivity();
    if (activity == self.compression_activity) return;
    self.compression_activity = activity;
    self.armScrollbackCompression(compression_idle_ms);
}

fn fireScrollbackCompression(self: *App) void {
    _ = readTimer(self.compression_fd) orelse return;

    const activity = self.tab().term.compressionActivity();
    if (activity != self.compression_activity) {
        self.compression_activity = activity;
        self.armScrollbackCompression(compression_idle_ms);
        return;
    }

    if (self.tab().term.compress(.incremental) == .pending) {
        self.armScrollbackCompression(compression_step_ms);
    }
}

fn armScrollbackCompression(self: *App, delay_ms: u64) void {
    _ = setTimer(self.compression_fd, .{
        .it_value = timespecFromNs(delay_ms * std.time.ns_per_ms),
        .it_interval = .{ .sec = 0, .nsec = 0 },
    }, "scrollback compression");
}

fn startSearch(self: *App) void {
    if (self.tab().search != null) return;
    self.tab().search = ScrollbackSearch.init(&self.tab().term) catch |err| {
        log.warn("failed to start scrollback search: {}", .{err});
        return;
    };
    self.stopFling();
    self.clearSelection();
    self.requestFullAsyncRedraw();
}

fn finishSearch(self: *App, accept: bool) void {
    var accepted: ?vt.Selection = null;
    if (self.tab().search) |*search| {
        if (accept and search.engineValid(&self.tab().term) and
            search.engine_key == self.tab().term.screens.active_key)
        {
            if (search.engine.?.selectedMatch()) |match| {
                accepted = .init(match.startPin(), match.endPin(), false);
            }
        } else if (!accept) {
            search.restoreViewport(&self.tab().term);
        }
        search.deinit(self.alloc, &self.tab().term);
        self.tab().search = null;
    }
    self.stopSearchTimer();
    self.clearImeText();
    self.revealScrollbar();
    if (accepted) |selection| {
        self.tab().term.screens.active.select(selection) catch |err| {
            log.warn("failed to select accepted search match: {}", .{err});
            self.requestFullAsyncRedraw();
            return;
        };
        self.copyToPrimary();
    }
    self.syncHoveredLink(true);
    self.requestFullAsyncRedraw();
}

fn rebuildSearch(self: *App) void {
    const search = if (self.tab().search) |*value| value else return;
    search.deinitEngine(&self.tab().term);
    self.stopSearchTimer();
    if (search.query.items.len == 0) {
        search.restoreViewport(&self.tab().term);
        self.revealScrollbar();
        self.syncHoveredLink(true);
        self.requestFullAsyncRedraw();
        return;
    }

    const key = self.tab().term.screens.active_key;
    search.engine = vt.search.Screen.init(
        self.alloc,
        self.tab().term.screens.active,
        search.query.items,
    ) catch |err| {
        log.warn("failed to initialize scrollback search: {}", .{err});
        self.requestFullAsyncRedraw();
        return;
    };
    search.engine_key = key;
    search.engine_generation = self.tab().term.screens.generation(key);
    search.complete = false;
    self.ensureSearchSelection();
    self.startSearchTimer();
    self.requestFullAsyncRedraw();
}

/// Reconcile search with live terminal output. Screen generations make it
/// safe to release an engine after an alternate screen was destroyed.
fn refreshSearch(self: *App, tb: *Tab) void {
    // Incremental search is a view-level UI feature that only scans the
    // visible tab; a background tab's match set is refreshed on activation.
    if (tb != self.active) return;
    const search = if (self.tab().search) |*value| value else return;
    if (search.query.items.len == 0) return;
    if (!search.engineValid(&self.tab().term) or
        search.engine_key != self.tab().term.screens.active_key)
    {
        self.rebuildSearch();
        return;
    }

    search.engine.?.reloadActive() catch |err| {
        log.warn("failed to refresh scrollback search: {}", .{err});
        return;
    };
    search.complete = false;
    self.ensureSearchSelection();
    self.startSearchTimer();
    self.requestFullAsyncRedraw();
}

fn startSearchTimer(self: *App) void {
    const interval = timespecFromNs(search_tick_ms * std.time.ns_per_ms);
    _ = setTimer(self.search_fd, .{
        .it_value = interval,
        .it_interval = interval,
    }, "scrollback search");
}

fn stopSearchTimer(self: *App) void {
    _ = setTimer(self.search_fd, disarmed_timer, "scrollback search");
}

fn fireSearch(self: *App) void {
    _ = readTimer(self.search_fd) orelse return;
    var search = if (self.tab().search) |*value| value else {
        self.stopSearchTimer();
        return;
    };
    if (search.query.items.len == 0) {
        self.stopSearchTimer();
        return;
    }
    if (!search.engineValid(&self.tab().term)) {
        self.rebuildSearch();
        return;
    }

    const before_matches = search.engine.?.matchesLen();
    const before_selected: ?usize = if (search.engine.?.selected) |selected| selected.idx else null;
    const before_complete = search.complete;
    for (0..search_ticks_per_wake) |_| {
        search.engine.?.tick() catch |err| switch (err) {
            error.FeedRequired => {
                search.engine.?.feed() catch |feed_err| {
                    log.warn("failed to feed scrollback search: {}", .{feed_err});
                    search.complete = true;
                    self.stopSearchTimer();
                    break;
                };
                continue;
            },
            error.SearchComplete => {
                search.complete = true;
                self.stopSearchTimer();
                break;
            },
            error.OutOfMemory => {
                log.warn("failed to advance scrollback search: {}", .{err});
                search.complete = true;
                self.stopSearchTimer();
                break;
            },
        };
    }
    self.ensureSearchSelection();

    search = &self.tab().search.?;
    const after_selected: ?usize = if (search.engine.?.selected) |selected| selected.idx else null;
    if (before_matches != search.engine.?.matchesLen() or
        before_selected != after_selected or before_complete != search.complete)
    {
        self.requestFullAsyncRedraw();
    }
}

fn ensureSearchSelection(self: *App) void {
    const search = if (self.tab().search) |*value| value else return;
    if (!search.engineValid(&self.tab().term) or
        search.engine_key != self.tab().term.screens.active_key) return;
    const engine = &search.engine.?;
    if (engine.selected == null and engine.matchesLen() > 0) {
        _ = engine.select(.next) catch |err| {
            log.warn("failed to select scrollback search result: {}", .{err});
            return;
        };
        self.scrollToSearchSelection();
    }
}

fn selectSearch(self: *App, direction: vt.search.Screen.Select) void {
    const search = if (self.tab().search) |*value| value else return;
    if (!search.engineValid(&self.tab().term) or
        search.engine_key != self.tab().term.screens.active_key) return;
    _ = search.engine.?.select(direction) catch |err| {
        log.warn("failed to move scrollback search selection: {}", .{err});
        return;
    };
    self.scrollToSearchSelection();
    self.requestFullAsyncRedraw();
}

fn scrollToSearchSelection(self: *App) void {
    const search = if (self.tab().search) |*value| value else return;
    if (!search.engineValid(&self.tab().term) or
        search.engine_key != self.tab().term.screens.active_key) return;
    const match = search.engine.?.selectedMatch() orelse return;
    const screen = search.engine.?.screen;
    if (!searchMatchVisible(screen, match)) {
        screen.pages.scroll(.{ .pin = match.startPin() });
        self.revealScrollbar();
        self.syncHoveredLink(true);
    }
    self.needs_redraw = true;
}

fn searchMatchVisible(screen: *vt.Screen, match: vt.highlight.Flattened) bool {
    var viewport = screen.pages.pageIterator(.right_down, .{ .viewport = .{} }, null);
    const chunks = match.chunks.slice();
    while (viewport.next()) |visible| {
        for (0..chunks.len) |i| {
            const chunk = chunks.get(i);
            if (visible.overlaps(.{
                .node = chunk.node,
                .start = chunk.start,
                .end = chunk.end,
            })) return true;
        }
    }
    return false;
}

fn appendSearchText(self: *App, text: []const u8) void {
    if (text.len == 0) return;
    const search = if (self.tab().search) |*value| value else return;
    if (search.query.items.len + text.len > max_search_query_bytes) return;
    search.query.appendSlice(self.alloc, text) catch |err| {
        log.warn("failed to edit scrollback search: {}", .{err});
        return;
    };
    self.rebuildSearch();
}

fn backspaceSearch(self: *App) void {
    const search = if (self.tab().search) |*value| value else return;
    if (!truncateLastUtf8(&search.query)) return;
    self.rebuildSearch();
}

fn truncateLastUtf8(text: *std.ArrayList(u8)) bool {
    if (text.items.len == 0) return false;
    var start = text.items.len - 1;
    while (start > 0 and text.items[start] & 0xc0 == 0x80) start -= 1;
    text.shrinkRetainingCapacity(start);
    return true;
}

fn handleSearchKey(self: *App, event: vt.input.KeyEvent) void {
    if (event.action == .release) return;
    if (event.mods.ctrl) {
        switch (event.unshifted_codepoint) {
            'n' => self.selectSearch(.prev),
            'p' => self.selectSearch(.next),
            'c', 'g' => self.finishSearch(false),
            'u' => {
                const search = if (self.tab().search) |*value| value else return;
                if (search.query.items.len == 0) return;
                search.query.clearRetainingCapacity();
                self.rebuildSearch();
            },
            else => {},
        }
        return;
    }

    switch (event.key) {
        .escape => self.finishSearch(false),
        .enter, .numpad_enter => self.finishSearch(true),
        .backspace, .numpad_backspace => self.backspaceSearch(),
        else => if (!event.mods.alt and !event.mods.super) self.appendSearchText(event.utf8),
    }
}

const ScrollbackKeyAction = union(enum) {
    lines: isize,
    page_up,
    page_down,
    top,
    bottom,
    passthrough,
};

fn scrollbackKeyAction(
    config: *const Config,
    active_screen: vt.ScreenSet.Key,
    event: vt.input.KeyEvent,
) ?ScrollbackKeyAction {
    if (keybind.getEvent(config.keybinds.items, event)) |action| {
        // Explicit bindings override fixed shortcuts even when unbound or
        // passed through to an alternate-screen application.
        return switch (action) {
            .unbind => .passthrough,
            .scroll_page_lines => |lines| if (active_screen == .primary) .{ .lines = lines } else .passthrough,
        };
    }
    // Leave scrollback shortcuts to full-screen applications.
    if (active_screen != .primary) return null;
    if (!event.mods.shift or event.mods.ctrl or event.mods.alt or event.mods.super) return null;

    return switch (event.key) {
        .page_up => .page_up,
        .page_down => .page_down,
        .home => .top,
        .end => .bottom,
        else => null,
    };
}

fn handleScrollbackKey(self: *App, event: vt.input.KeyEvent, scroll: ScrollbackKeyAction) void {
    std.debug.assert(scroll != .passthrough);
    // Consume the matching release too, but move only on press/repeat.
    if (event.action == .release) return;

    self.stopFling();
    const rows: isize = @intCast(self.tab().term.rows);
    switch (scroll) {
        .lines => |lines| self.tab().term.screens.active.pages.scroll(.{ .delta_row = lines }),
        .page_up => self.tab().term.screens.active.pages.scroll(.{ .delta_row = -rows }),
        .page_down => self.tab().term.screens.active.pages.scroll(.{ .delta_row = rows }),
        .top => self.tab().term.screens.active.pages.scroll(.top),
        .bottom => self.tab().term.screens.active.pages.scroll(.active),
        .passthrough => unreachable,
    }
    self.revealScrollbar();
    self.needs_redraw = true;
    self.syncHoveredLink(true);
}

fn onKey(self: *App, evdev_keycode: u32, action: vt.input.KeyAction) void {
    var utf8_buf: [16]u8 = undefined;
    const event = self.keyboard.translate(&utf8_buf, evdev_keycode, action) orelse return;

    if (self.tab().search != null) return self.handleSearchKey(event);

    if (scrollbackKeyAction(&self.config, self.tab().term.screens.active_key, event)) |scroll| {
        if (scroll != .passthrough) return self.handleScrollbackKey(event, scroll);
    } else {
        // Shift is only allowed on `=` (for `Ctrl++`); ctrl+_ and ctrl+) belong to the application.
        if (action == .press and event.mods.ctrl) {
            switch (event.unshifted_codepoint) {
                '=' => return self.adjustRuntimeFontSize(1),
                '-' => if (!event.mods.shift) return self.adjustRuntimeFontSize(-1),
                '0' => if (!event.mods.shift) return self.resetRuntimeFontSize(),
                else => {},
            }
        }

        // Copy/paste bindings take priority over the application.
        if (action == .press and event.mods.ctrl and event.mods.shift) {
            switch (event.unshifted_codepoint) {
                'c' => return self.copyToClipboard(),
                'f' => return self.startSearch(),
                'g' => return self.pipeCommandOutput(),
                'h' => return self.prevTab(),
                'l' => return self.nextTab(),
                'n' => return self.openNewSession(),
                't' => return self.newTab(),
                'q' => return self.closeTab(),
                'w' => return self.closeTab(),
                'v' => return self.beginPaste(.clipboard),
                'x' => return self.jumpPrompt(1),
                'z' => return self.jumpPrompt(-1),
                ',' => return self.moveTab(-1),
                '.' => return self.moveTab(1),
                else => {},
            }
            // Ctrl+Shift+PageUp/PageDown cycle tabs.
            switch (event.key) {
                .page_up => return self.prevTab(),
                .page_down => return self.nextTab(),
                .f5 => return self.reloadConfig(),
                else => {},
            }
        }
    }

    const wrote = self.encodeAndWriteKey(event);

    // A non-modifier key that produced input dismisses the selection
    // and snaps a scrolled-back viewport to the bottom (ghostty's
    // selection-clear-on-typing behavior).
    if (wrote and action != .release and !event.key.modifier()) {
        self.stopFling();
        self.clearSelection();
        if (self.tab().term.screens.active.pages.viewport != .active) {
            self.tab().term.screens.active.pages.scroll(.active);
            self.revealScrollbar();
            self.needs_redraw = true;
            self.syncHoveredLink(true);
        }
    }
}

fn encodeAndWriteKey(self: *App, event: vt.input.KeyEvent) bool {
    var out_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);
    vt.input.encodeKey(&writer, event, .fromTerminal(&self.tab().term)) catch |err| {
        log.err("key encode failed: {}", .{err});
        return false;
    };
    const bytes = writer.buffered();
    if (bytes.len == 0) return false;
    self.tab().writePty(bytes);
    return true;
}

// Includes headroom for base64 framing of a maximum-sized clipboard read.
const max_pty_write_queue = Tab.max_pty_write_queue;

test "maximum clipboard response survives write backpressure in order" {
    const alloc = std.testing.allocator;
    const linux = std.os.linux;
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    const tb = pipeBackedTab(alloc, fds[1]);
    defer alloc.destroy(tb);
    defer tb.write_queue.deinit(alloc);
    const app = try alloc.create(App);
    defer alloc.destroy(app);
    app.alloc = alloc;
    app.active = tb;
    app.tabs = .empty;

    const clipboard = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(clipboard);
    @memset(clipboard, 'x');
    var expected: std.Io.Writer.Allocating = .init(alloc);
    defer expected.deinit();
    try formatOsc52ClipboardReport(&expected.writer, 'c', clipboard);
    try expected.writer.writeAll("following input");

    app.writeOsc52ClipboardReport(tb, 'c', clipboard);
    try std.testing.expect(tb.write_queue.items.len > 1024 * 1024);
    tb.writePty("following input");
    var received: usize = 0;
    var buf: [16 * 1024]u8 = undefined;
    while (received < expected.written().len) {
        const n = try posix.read(fds[0], &buf);
        try std.testing.expect(n > 0);
        try std.testing.expectEqualSlices(u8, expected.written()[received..][0..n], buf[0..n]);
        received += n;
        const queued_len = tb.write_queue.items.len;
        const queued_offset = tb.write_queue_offset;
        tb.flushWriteQueue();
        if (tb.write_queue.items.len > 0) {
            try std.testing.expectEqual(queued_len, tb.write_queue.items.len);
            try std.testing.expect(tb.write_queue_offset > queued_offset);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), tb.write_queue.items.len);
    try std.testing.expectEqual(@as(usize, 0), tb.write_queue_offset);
}

test "PTY limit and allocation failure reject before writing a prefix" {
    const alloc = std.testing.allocator;
    const linux = std.os.linux;
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    const tb = pipeBackedTab(alloc, fds[1]);
    defer alloc.destroy(tb);
    defer tb.write_queue.deinit(alloc);
    const oversized = try alloc.alloc(u8, max_pty_write_queue + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    tb.writePty(oversized);
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(fds[0], &byte));
    try std.testing.expectEqual(@as(usize, 0), tb.write_queue.items.len);

    var failing: std.testing.FailingAllocator = .init(alloc, .{ .fail_index = 0 });
    tb.alloc = failing.allocator();
    tb.writePty("reply");
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectError(error.WouldBlock, posix.read(fds[0], &byte));
    try std.testing.expectEqual(@as(usize, 0), tb.write_queue.items.len);
}

test "PTY enqueue counts unread bytes and amortizes compaction" {
    const alloc = std.testing.allocator;
    const tb = pipeBackedTab(alloc, -1);
    defer alloc.destroy(tb);
    tb.write_queue = try .initCapacity(alloc, max_pty_write_queue);
    defer tb.write_queue.deinit(alloc);
    tb.write_queue.items.len = max_pty_write_queue;
    for (tb.write_queue.items, 0..) |*byte, i| byte.* = @truncate(i);

    // A small consumed prefix doesn't trigger a large tail copy, and does
    // not count against the logical cap. Reserve failure keeps it intact.
    tb.write_queue_offset = 1;
    var failing: std.testing.FailingAllocator = .init(alloc, .{ .fail_index = 0, .resize_fail_index = 0 });
    tb.alloc = failing.allocator();
    tb.writePty("x");
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), tb.write_queue_offset);
    try std.testing.expectEqual(@as(usize, max_pty_write_queue), tb.write_queue.items.len);
    tb.alloc = alloc;
    tb.writePty("x");
    try std.testing.expectEqual(@as(usize, 1), tb.write_queue_offset);
    try std.testing.expectEqual(@as(usize, max_pty_write_queue + 1), tb.write_queue.items.len);
    tb.writePty("rejected");
    try std.testing.expectEqual(@as(usize, max_pty_write_queue + 1), tb.write_queue.items.len);
    try std.testing.expectEqual(@as(u8, 'x'), tb.write_queue.items[max_pty_write_queue]);

    // With enough consumed bytes, reclaim the prefix instead of growing.
    tb.write_queue.items.len = tb.write_queue.capacity;
    @memset(tb.write_queue.items, 0);
    tb.write_queue_offset = tb.write_queue.items.len - 4;
    @memcpy(tb.write_queue.items[tb.write_queue_offset..], "tail");
    const capacity = tb.write_queue.capacity;
    tb.writePty("next");
    try std.testing.expectEqual(capacity, tb.write_queue.capacity);
    try std.testing.expectEqual(@as(usize, 0), tb.write_queue_offset);
    try std.testing.expectEqualStrings("tailnext", tb.write_queue.items);
}

fn searchRangeForRender(self: *App) ?Renderer.LinkRange {
    const search = if (self.tab().search) |*value| value else return null;
    if (!search.engineValid(&self.tab().term) or
        search.engine_key != self.tab().term.screens.active_key)
    {
        return null;
    }
    const match = search.engine.?.selectedMatch() orelse return null;
    return highlightRange(
        search.engine.?.screen,
        match.startPin(),
        match.endPin(),
        self.tab().term.rows,
        self.tab().term.cols,
    );
}

fn searchMatchesForRender(self: *App) !std.ArrayList(bool) {
    const search = if (self.tab().search) |*value| value else return .empty;
    if (search.query.items.len == 0 or !search.engineValid(&self.tab().term) or
        search.engine_key != self.tab().term.screens.active_key)
    {
        return .empty;
    }
    return searchMatchMask(
        self.alloc,
        search.engine.?.screen,
        search.query.items,
        self.tab().term.rows,
        self.tab().term.cols,
    );
}

fn searchMatchMask(
    alloc: std.mem.Allocator,
    screen: *vt.Screen,
    query: []const u8,
    rows: u16,
    cols: u16,
) !std.ArrayList(bool) {
    std.debug.assert(rows > 0 and cols > 0);
    var result: std.ArrayList(bool) = .empty;
    errdefer result.deinit(alloc);

    var viewport: vt.search.Viewport = try .init(alloc, query);
    defer viewport.deinit();
    _ = try viewport.update(&screen.pages);
    while (viewport.next()) |match| {
        const range = highlightRange(
            screen,
            match.startPin(),
            match.endPin(),
            rows,
            cols,
        ) orelse continue;
        if (result.items.len == 0) {
            try result.resize(alloc, @as(usize, rows) * cols);
            @memset(result.items, false);
        }
        markSearchRange(result.items, cols, range);
    }
    return result;
}

fn markSearchRange(mask: []bool, cols: u16, range: Renderer.LinkRange) void {
    const stride: usize = cols;
    std.debug.assert(mask.len % stride == 0);
    std.debug.assert(range.end.y < mask.len / stride);
    for (range.start.y..range.end.y + 1) |y| {
        const start_x: usize = if (y == range.start.y) range.start.x else 0;
        const end_x: usize = if (y == range.end.y) range.end.x + 1 else stride;
        @memset(mask[@as(usize, y) * stride + start_x .. @as(usize, y) * stride + end_x], true);
    }
}

fn searchNoMatch(self: *App) bool {
    const search = if (self.tab().search) |*value| value else return false;
    if (search.query.items.len == 0 or self.ime_preedit != null or
        !search.complete or !search.engineValid(&self.tab().term))
    {
        return false;
    }
    return search.engine.?.matchesLen() == 0;
}

fn searchOverlayText(self: *App) !?[]u8 {
    const search = if (self.tab().search) |*value| value else return null;
    const preedit: []const u8 = self.ime_preedit orelse "";
    if (!search.engineValid(&self.tab().term)) {
        return try std.fmt.allocPrint(self.alloc, "Search: {s}{s}", .{
            search.query.items,
            preedit,
        });
    }

    const engine = &search.engine.?;
    const total = engine.matchesLen();
    const current: usize = if (engine.selected) |selected| selected.idx + 1 else 0;
    if (search.complete) {
        return try std.fmt.allocPrint(self.alloc, "Search ({d}/{d}): {s}{s}", .{
            current,
            total,
            search.query.items,
            preedit,
        });
    }
    return try std.fmt.allocPrint(self.alloc, "Search ({d}/{d}+): {s}{s}", .{
        current,
        total,
        search.query.items,
        preedit,
    });
}

/// Build an owned snapshot of the currently-visible tabs for the tab bar.
/// All returned titles are owned by the caller (freed by freeTabBarSnapshot);
/// the caller must hand the slice to replaceTabBar, which dups it again for
/// the in-flight job.
fn tabBarSnapshot(self: *App) ![]Renderer.TabBarItem {
    var items: std.ArrayList(Renderer.TabBarItem) = .empty;
    errdefer {
        for (items.items) |item| self.alloc.free(item.title);
        items.deinit(self.alloc);
    }
    for (self.tabs.items, 0..) |tb, i| {
        const title = if (tb.term.getTitle()) |text|
            if (text.len > 0) try self.alloc.dupe(u8, text) else try self.tabProcessTitle(tb, i)
        else
            try self.tabProcessTitle(tb, i);
        try items.append(self.alloc, .{ .title = title, .active = tb == self.active });
    }
    return items.toOwnedSlice(self.alloc);
}

/// Use the foreground process-group leader when no application title is set.
/// A full-screen child such as nvim can clear OSC 2 before returning to its
/// parent; the PTY foreground group still identifies yazi (or the shell at a
/// prompt), so the tab does not degrade to an opaque numeric label.
fn tabProcessTitle(self: *App, tb: *Tab, index: usize) ![]u8 {
    var foreground_pid: posix.pid_t = undefined;
    const rc = std.os.linux.tcgetpgrp(tb.pty.master, &foreground_pid);
    if (std.os.linux.errno(rc) != .SUCCESS) foreground_pid = tb.child_pid;
    if (try self.processName(foreground_pid)) |name| return name;
    if (foreground_pid != tb.child_pid) {
        if (try self.processName(tb.child_pid)) |name| return name;
    }
    return std.fmt.allocPrint(self.alloc, "{d}", .{index + 1});
}

/// Read and own Linux's short, stable process name.
fn processName(self: *App, pid: posix.pid_t) std.mem.Allocator.Error!?[]u8 {
    if (pid <= 0) return null;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
    const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return null;
    defer file.close(self.io);

    var name_buf: [256]u8 = undefined;
    const len = posix.read(file.handle, &name_buf) catch return null;
    const name = std.mem.trim(u8, name_buf[0..len], " \t\r\n");
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return null;
    return try self.alloc.dupe(u8, name);
}

fn freeTabBarSnapshot(self: *App, items: []Renderer.TabBarItem) void {
    for (items) |item| self.alloc.free(item.title);
    self.alloc.free(items);
}

fn tabBarEqual(a: []const Renderer.TabBarItem, b: []const Renderer.TabBarItem) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.active != y.active or !std.mem.eql(u8, x.title, y.title)) return false;
    }
    return true;
}

const AsyncRenderStart = enum { submitted, no_work, deferred };

fn startAsyncRender(self: *App) !AsyncRenderStart {
    var async_raster = &(self.async_raster orelse return .deferred);
    if (async_raster.busy()) return .deferred;
    const selection_bg = self.selectionBackgroundForRender();
    const selection_fg = self.selectionForegroundForRender();
    if (!async_raster.configuredFor(
        self.font.discovery(),
        selection_bg,
        selection_fg,
        self.cursor_color,
        self.cursor_text,
        self.config.background_opacity,
        self.config.background_opacity_cells,
    )) {
        async_raster.reconfigure(
            self.font.discovery(),
            selection_bg,
            selection_fg,
            self.cursor_color,
            self.cursor_text,
            self.config.background_opacity,
            self.config.background_opacity_cells,
        ) catch |err| {
            self.rasterFatal(err);
            return .deferred;
        };
    }
    // DEC 2026: the terminal is mid-update, so the previous snapshot
    // (and its overlay/kitty copies) is re-rendered as-is — reachable
    // only for geometry redraws. Any pending snapshot rebuild stays
    // deferred until the freeze ends.
    const frozen = self.tab().term.modes.get(.synchronized_output);
    var hyperlink_hints = self.linksActive();
    // Frozen jobs re-render the previous snapshot at a new geometry, so
    // they never take the unchanged-overlay shortcut.
    var overlay_dirty = true;
    var tab_bar_dirty = true;
    var scroll: ?ScrollDetector.Scroll = null;
    var old_cursor: vt.RenderState.Cursor = self.render_state.cursor;
    if (!frozen) {
        self.tickKittyAnimations();
        const has_kitty_graphics = self.tab().term.screens.active.kitty_images.placements.count() > 0;
        const new_scrollbar = self.currentScrollbarThumb();
        // Detection must precede update(). Both the previous and next frame
        // must be free of overlays because their pixels do not move with
        // terminal rows.
        if (!self.async_force_full and
            !hyperlink_hints and !self.async_job.hyperlink_hints and
            self.ime_preedit == null and self.async_job.preedit == null and
            self.async_job.link_hint == null and
            self.tab().search == null and self.async_job.search == null and
            new_scrollbar == null and self.async_job.scrollbar == null and
            !has_kitty_graphics and self.async_job.kitty.len == 0)
        {
            scroll = try self.scroll_detector.detect(self.alloc, &self.render_state, &self.tab().term);
        }
        if (self.async_force_full) {
            self.render_state.rows = 0;
            self.render_state.dirty = .full;
        }
        old_cursor = self.render_state.cursor;
        try self.render_state.update(self.alloc, &self.tab().term);
        self.dirtyCursorRows(old_cursor);
        const cursor_was_animating = self.cursor_anim_moving;
        self.syncCursorAnimator();
        // Advance the trail once per produced frame so it stays locked to the
        // compositor's refresh rather than sampling on a fixed nanosecond
        // timer. Guard on readiness and on an active or pending jump: with no
        // movement the animator is disabled/unsupported and advance() would
        // read an uninitialized quad.
        if (self.cursor_anim_ready and (self.cursor_anim_moving or self.cursor_anim.jumped)) {
            self.advanceCursorAnimation(cursor_was_animating);
        }
        // If terminal state (rather than the fade timer) removed the last
        // overlay, redraw its old pixels instead of repairing from a buffer
        // that still contains the thumb.
        if (self.async_job.scrollbar != null and new_scrollbar == null) {
            self.render_state.dirty = .full;
        }
        if (self.render_state.dirty == .partial and self.allRenderRowsDirty()) {
            self.render_state.dirty = .full;
        }
        // Snapshot overlay inputs; the worker cannot safely read App state.
        // The previous job's copies are dead: only one job exists at a time.
        const hovered = if (hyperlink_hints) self.hovered_link else null;
        const new_link: ?[]const u8 = if (hovered) |link| link.uri else null;
        const new_range: ?Renderer.LinkRange = if (hovered) |link| link.range else null;
        const new_preedit: ?[]const u8 = if (self.tab().search == null) self.ime_preedit else null;
        var new_search_matches = try self.searchMatchesForRender();
        errdefer new_search_matches.deinit(self.alloc);
        const new_search = try self.searchOverlayText();
        const new_search_no_match = self.searchNoMatch();
        const new_search_range = self.searchRangeForRender();
        overlay_dirty = hyperlink_hints != self.async_job.hyperlink_hints or
            !optionalStrEql(self.async_job.preedit, new_preedit) or
            !optionalStrEql(self.async_job.link_hint, new_link) or
            !optionalStrEql(self.async_job.search, new_search) or
            self.async_job.search_no_match != new_search_no_match or
            !std.meta.eql(self.async_job.link_range, new_range) or
            !std.meta.eql(self.async_job.search_range, new_search_range) or
            !std.mem.eql(bool, self.async_job.search_matches.items, new_search_matches.items) or
            !std.meta.eql(self.async_job.scrollbar, new_scrollbar);
        try self.async_job.replaceOverlays(self.alloc, new_preedit, new_link, new_search, new_search_no_match, new_range, new_search_range, new_search_matches, new_scrollbar, hyperlink_hints);
        new_search_matches = .empty;

        // Tab bar snapshot: titles, active highlight, and strip height.
        const new_bar = try self.tabBarSnapshot();
        defer self.freeTabBarSnapshot(new_bar);
        tab_bar_dirty = self.async_job.tab_bar_height != self.tab_bar_height or
            !tabBarEqual(self.async_job.tab_bar, new_bar);
        if (tab_bar_dirty) try self.async_job.replaceTabBar(self.alloc, new_bar, self.tab_bar_height);
        var kitty_changed = false;
        if (has_kitty_graphics) {
            // Text-only scrolling also dirties the kitty storage. It can
            // change pixels only when placements exist (or were removed).
            kitty_changed = self.tab().term.screens.active.kitty_images.dirty;
            const items = try Renderer.collectKittyPlacements(&self.font, self.alloc, &self.tab().term);
            if (!Renderer.kittyItemsEqual(self.async_job.kitty, items)) kitty_changed = true;
            try self.async_job.replaceKitty(self.alloc, &self.tab().kitty_cache, items);
        } else {
            if (self.async_job.kitty.len > 0) kitty_changed = true;
            self.async_job.releaseKitty(self.alloc);
        }
        // Kitty placements are not tracked per row, so any change to
        // the graphics — or any content change underneath them — is a
        // full render.
        if (kitty_changed or (has_kitty_graphics and self.render_state.dirty != .false)) {
            self.render_state.dirty = .full;
        }
        overlay_dirty = overlay_dirty or kitty_changed;
        const new_cursor_overlay = self.cursorOverlay();
        if (!std.meta.eql(self.async_job.cursor_overlay, new_cursor_overlay))
            overlay_dirty = true;
        self.async_job.setCursorOverlay(new_cursor_overlay);
        if (overlay_dirty or self.render_state.dirty != .full) scroll = null;
        // Nothing to draw: content is clean and every overlay input
        // matches the previous job. Parse batches that only stream
        // kitty payload bytes land here; submitting would burn a job
        // round-trip (and often a buffer repair copy) on a frame
        // identical to the last one. A moving cursor trail is exempt:
        // it must keep a frame callback outstanding so it never freezes
        // mid-settle (its integer-rounded corner is momentarily stable).
        if (self.render_state.dirty == .false and !overlay_dirty and !tab_bar_dirty and !self.geometry_redraw and !self.cursor_anim_moving) return .no_work;
    } else {
        // Keep link affordances consistent with the stale snapshot.
        hyperlink_hints = self.async_job.hyperlink_hints;
        // Full-surface scrollbar coordinates belong to the old geometry.
        // Remove the thumb while synchronized output holds the old terminal
        // snapshot; the current geometry is picked up when the freeze ends.
        if (self.async_job.scrollbar != null) self.render_state.dirty = .full;
        if (self.async_job.cursor_overlay != null) {
            self.async_job.cursor_overlay = null;
            self.render_state.dirty = .full;
        }
    }
    std.debug.assert(self.held_frame == null);
    const target = self.window.acquireRenderTarget() catch |err| {
        // Overlay snapshots above now describe the pending frame rather than
        // the last submitted one. Ensure the retry cannot mistake them for
        // unchanged inputs and skip the frame.
        self.async_force_full = true;
        // NotReady is transient window state. Every other failure means the
        // only renderer cannot obtain a buffer, so retrying in the pre-poll
        // redraw path would spin indefinitely.
        if (err != error.NotReady) self.rasterFatal(err);
        return .deferred;
    };
    errdefer self.window.cancelRender(target.buffer);
    if (scroll != null and target.age != 1 and target.source_pixels == null) scroll = null;
    if (scroll) |value| self.scroll_detector.prepare(&self.render_state, value, old_cursor);
    const repair: AsyncRaster.Repair = if (scroll == null)
        try self.frame_damage.planRepair(
            target.age,
            self.render_state.dirty == .full,
            .{
                .width = target.width,
                .height = target.height,
                .grid_x = self.layout.grid_x,
                .grid_y = self.layout.grid_y,
                .grid_width = self.layout.grid_width,
                .grid_height = self.layout.grid_height,
                .cell_width = self.font.cell_width,
                .cell_height = self.font.cell_height,
            },
        )
    else
        .none;
    self.async_generation +%= 1;
    async_raster.submit(.{
        .pixels = target.pixels,
        .source_pixels = target.source_pixels,
        .width = target.width,
        .height = target.height,
        .grid_x = self.layout.grid_x,
        .grid_y = self.layout.grid_y,
        .grid_width = self.layout.grid_width,
        .grid_height = self.layout.grid_height,
        .age = target.age,
        .generation = self.async_generation,
        .focused = self.focused,
        .hyperlink_hints = hyperlink_hints,
        .link_range = self.async_job.link_range,
        .search_range = self.async_job.search_range,
        .search_matches = self.async_job.search_matches.items,
        .search_background = self.copy_highlight,
        .search_foreground = self.copy_highlight_fg,
        .preedit = self.async_job.preedit,
        .link_hint = self.async_job.link_hint,
        .search = self.async_job.search,
        .search_no_match = self.async_job.search_no_match,
        .scrollbar = if (frozen) null else self.async_job.scrollbar,
        .tab_bar = self.async_job.tab_bar,
        .tab_bar_height = self.tab_bar_height,
        .tab_bar_position = self.config.tab_bar_position,
        .tab_bar_background = self.config.effectiveTabBarBackground(self.color_scheme),
        .active_tab_background = self.config.effectiveActiveTabBackground(self.color_scheme),
        .active_tab_foreground = self.config.effectiveActiveTabForeground(self.color_scheme),
        .inactive_tab_background = self.config.effectiveInactiveTabBackground(self.color_scheme),
        .inactive_tab_foreground = self.config.effectiveInactiveTabForeground(self.color_scheme),
        .tab_bar_dirty = tab_bar_dirty,
        .kitty_items = self.async_job.kitty,
        .cursor_overlay = self.async_job.cursor_overlay,
        .overlay_dirty = overlay_dirty,
        .scroll_shift = if (scroll) |value| value.shift else null,
        .repair = repair,
    }) catch |err| {
        self.window.cancelRender(target.buffer);
        if (self.async_job.kitty_cache) |cache| cache.sweep(self.alloc);
        self.rasterFatal(err);
        return .deferred;
    };
    if (!frozen) self.tab().term.screens.active.kitty_images.dirty = false;
    if (!frozen) self.async_force_full = false;
    return .submitted;
}

fn tickKittyAnimations(self: *App) void {
    const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    const now_ms: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
    const delay_ms = self.tab().term.screens.active.kitty_images.animationTick(self.io, now_ms);
    const spec: std.os.linux.itimerspec = if (delay_ms) |delay| .{
        .it_value = timespecFromNs(@max(delay, 1) *| std.time.ns_per_ms),
        .it_interval = .{ .sec = 0, .nsec = 0 },
    } else disarmed_timer;
    _ = setTimer(self.kitty_animation_fd, spec, "kitty animation");
}

fn optionalStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// A finished frame is waiting and the compositor is ready for it.
fn canCommitHeldFrame(self: *const App) bool {
    if (self.held_frame == null) return false;
    return !self.window.frame_pending and !self.window.suspended;
}

/// Dirty content can start a new frame right now. A frame may start
/// while a frame callback is outstanding (raster overlaps the frame
/// wait); it is refused only while the raster worker is still coming up
/// or a render target is already checked out.
fn hasContentRedraw(self: *App) bool {
    if (!self.needs_redraw) return false;
    // DEC 2026 freezes content frames, but geometry changes still
    // repaint (the frozen snapshot at the new size).
    if (self.tab().term.modes.get(.synchronized_output) and !self.geometry_redraw) return false;
    if (self.window.width == 0 or self.window.suspended) return false;
    if (self.window.rendering_pending) return false;
    if (self.async_raster == null) return false;
    return true;
}

/// Must report true exactly when redrawIfNeeded will make progress:
/// the pre-poll fast path in run() otherwise spins without ever reading
/// the display socket.
fn hasReadyRedraw(self: *App) bool {
    return self.canCommitHeldFrame() or self.hasContentRedraw();
}

fn redrawIfNeeded(self: *App) !void {
    if (self.canCommitHeldFrame()) self.commitHeldFrame();
    if (!self.hasContentRedraw()) return;
    switch (try self.startAsyncRender()) {
        .submitted, .no_work => {
            self.needs_redraw = false;
            self.geometry_redraw = false;
        },
        .deferred => {},
    }
}

/// Commit a finished frame that was held for the frame callback, unless
/// the window geometry changed while it waited.
fn commitHeldFrame(self: *App) void {
    const buffer = self.held_frame orelse return;
    self.held_frame = null;
    if (buffer.width != Window.physicalDimension(self.window.width, self.window.scale120) or
        buffer.height != Window.physicalDimension(self.window.height, self.window.scale120))
    {
        self.window.cancelRender(buffer);
        self.frame_damage.invalidate();
        self.async_force_full = true;
        self.needs_redraw = true;
        return;
    }
    self.commitFinishedFrame(buffer);
}

/// Commit an async-rendered buffer using the current frame's damage
/// entry. Commit failures are fatal: the surface is unusable.
fn commitFinishedFrame(self: *App, buffer: *Window.Buffer) void {
    const surface_damage = self.frame_damage.currentSurfaceDamage(buffer.height) catch |err| {
        log.err("async surface damage failed: {}", .{err});
        self.window.cancelRender(buffer);
        self.window.fatal_error = err;
        self.window.running = false;
        return;
    };
    self.window.commitRender(buffer, surface_damage) catch |err| {
        log.err("async commit failed: {}", .{err});
        self.window.cancelRender(buffer);
        self.window.fatal_error = err;
        self.window.running = false;
    };
}

/// The raster worker is the only renderer; a load failure is fatal.
fn startAsyncRasterLoad(self: *App) void {
    std.debug.assert(self.async_raster == null and self.async_raster_loader == null);

    self.async_raster_loader = AsyncRaster.Loader.init(
        self.font.discovery(),
        self.selectionBackgroundForRender(),
        self.selectionForegroundForRender(),
        self.cursor_color,
        self.cursor_text,
        self.config.background_opacity,
        self.config.background_opacity_cells,
        &self.render_state,
    ) catch |err| {
        self.rasterFatal(err);
        return;
    };
    if (self.async_raster_loader) |*loader| {
        loader.start() catch |err| {
            loader.deinit();
            self.async_raster_loader = null;
            self.rasterFatal(err);
        };
    }
}

fn finishAsyncRasterLoad(self: *App) void {
    var loader = &(self.async_raster_loader orelse return);
    const result = loader.takeResult() orelse return;
    loader.deinit();
    self.async_raster_loader = null;

    switch (result) {
        .failed => |err| self.rasterFatal(err),
        .ready => |ready| {
            var raster = ready;
            if (!raster.configuredFor(
                self.font.discovery(),
                self.selectionBackgroundForRender(),
                self.selectionForegroundForRender(),
                self.cursor_color,
                self.cursor_text,
                self.config.background_opacity,
                self.config.background_opacity_cells,
            )) {
                // Config changed while loading; rebuild with the new one.
                raster.deinit();
                self.startAsyncRasterLoad();
                return;
            }

            self.async_raster = raster;
            if (self.async_raster) |*async_raster| {
                async_raster.start() catch |err| {
                    async_raster.deinit();
                    self.async_raster = null;
                    self.rasterFatal(err);
                    return;
                };
            }
            // Content may have gone dirty while the worker was loading.
            self.needs_redraw = true;
        },
    }
}

/// The app cannot render without the raster worker; stop with the error.
fn rasterFatal(self: *App, err: anyerror) void {
    log.err("raster worker unavailable: {}", .{err});
    self.window.fatal_error = err;
    self.window.running = false;
}

fn finishAsyncRender(self: *App) void {
    var async_raster = &(self.async_raster orelse return);
    const result = async_raster.takeResult() orelse return;
    const buffer = self.findRenderingBuffer(result.job.pixels) orelse {
        self.needs_redraw = true;
        return;
    };
    if (result.err) |err| {
        self.window.cancelRender(buffer);
        self.async_job.releaseKitty(self.alloc);
        // A deterministic raster error would retry forever; with no other
        // renderer to fall back to, stop.
        self.rasterFatal(err);
        return;
    }
    if (result.job.generation != self.async_generation or
        self.window.suspended or
        result.job.width != Window.physicalDimension(self.window.width, self.window.scale120) or
        result.job.height != Window.physicalDimension(self.window.height, self.window.scale120))
    {
        self.window.cancelRender(buffer);
        self.async_force_full = true;
        self.needs_redraw = true;
        return;
    }
    if (result.damage == .none) {
        // The target may have been repaired, but it matches the current
        // surface. Do not advance frame history unless a commit does.
        self.window.cancelRender(buffer);
        self.clearRenderDirty();
        self.syncTextInputCursorRect(&self.render_state);
        return;
    }
    self.frame_damage.begin(.{
        .width = result.job.width,
        .height = result.job.height,
        .grid_x = result.job.grid_x,
        .grid_y = result.job.grid_y,
        .grid_width = result.job.grid_width,
        .grid_height = result.job.grid_height,
        .cell_width = self.font.cell_width,
        .cell_height = self.font.cell_height,
    });
    self.frame_damage.record(async_raster, result.damage) catch |err| {
        log.err("async damage bookkeeping failed: {}", .{err});
        self.window.cancelRender(buffer);
        self.window.fatal_error = err;
        self.window.running = false;
        return;
    };
    self.clearRenderDirty();
    self.syncTextInputCursorRect(&self.render_state);
    if (self.window.frame_pending) {
        // The compositor is not ready for another commit. Hold the
        // finished buffer; redrawIfNeeded commits it when the frame
        // callback fires, then starts the next render immediately so
        // raster work overlaps the following frame wait.
        std.debug.assert(self.held_frame == null);
        self.held_frame = buffer;
        return;
    }
    self.commitFinishedFrame(buffer);
}

fn redrawReady(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.needs_redraw = true;
}

fn findRenderingBuffer(self: *App, pixels: []u32) ?*Window.Buffer {
    for (self.window.buffers.items) |buffer| {
        if (buffer.rendering and buffer.pixels().ptr == pixels.ptr) return buffer;
    }
    return null;
}

fn allRenderRowsDirty(self: *const App) bool {
    return allStateRowsDirty(&self.render_state);
}

fn allStateRowsDirty(state: *const vt.RenderState) bool {
    const rows: usize = state.rows;
    if (rows == 0) return false;
    for (state.row_data.items(.dirty)[0..rows]) |dirty| {
        if (!dirty) return false;
    }
    return true;
}

fn syncTextInputCursorRect(self: *App, state: *const vt.RenderState) void {
    if (!self.ime_focused) return;
    self.window.setTextInputCursorRect(self.textInputCursorRect(state));
}

fn textInputCursorRect(self: *App, state: *const vt.RenderState) Window.TextInputRect {
    const cursor = state.cursor.viewport;
    const x_cells: u32 = if (cursor) |cpos| @intCast(cpos.x -| @intFromBool(cpos.wide_tail)) else 0;
    const y_cells: u32 = if (cursor) |cpos| @intCast(cpos.y) else 0;
    return physicalRectToLogical(self.window.scale120, .{
        .x = @intCast(self.layout.grid_x + x_cells * self.font.cell_width),
        .y = @intCast(self.layout.grid_y + y_cells * self.font.cell_height),
        .width = @intCast(self.font.cell_width),
        .height = @intCast(self.font.cell_height),
    });
}

fn currentCursorState(self: *const App) *const vt.RenderState {
    return &self.render_state;
}

fn physicalRectToLogical(scale120: u32, rect: Window.TextInputRect) Window.TextInputRect {
    return .{
        .x = scaledPhysicalToLogical(scale120, rect.x),
        .y = scaledPhysicalToLogical(scale120, rect.y),
        .width = @max(1, scaledPhysicalToLogical(scale120, rect.width)),
        .height = @max(1, scaledPhysicalToLogical(scale120, rect.height)),
    };
}

fn scaledPhysicalToLogical(scale120: u32, value: i32) i32 {
    return @intCast(@divTrunc(@as(i64, value) * 120 + @divTrunc(@as(i64, scale120), 2), @as(i64, scale120)));
}

fn dirtyCursorRows(self: *App, old_cursor: vt.RenderState.Cursor) void {
    dirtyCursorRowsForState(&self.render_state, old_cursor);
}

fn dirtyCursorRowsForState(state: *vt.RenderState, old_cursor: vt.RenderState.Cursor) void {
    const new_cursor = state.cursor;
    if (old_cursor.visible == new_cursor.visible and
        old_cursor.visual_style == new_cursor.visual_style and
        std.meta.eql(old_cursor.viewport, new_cursor.viewport))
    {
        return;
    }

    dirtyCursorRowInState(state, old_cursor.viewport);
    dirtyCursorRowInState(state, new_cursor.viewport);
}

fn dirtyCursorRowInState(state: *vt.RenderState, viewport: ?vt.RenderState.Cursor.Viewport) void {
    const row = viewport orelse return;
    if (row.y >= state.row_data.len) return;

    state.row_data.items(.dirty)[row.y] = true;
    if (state.dirty == .false) state.dirty = .partial;
}

/// Mark the current cursor viewport row dirty so the native cell cursor
/// repaints in its colors (used on settle handoff from the overlay).
fn dirtyCursorCell(self: *App) void {
    dirtyCursorRowInState(&self.render_state, self.render_state.cursor.viewport);
}

/// Whether the animated cursor should be active right now. Disabled by
/// the config flag, reduced-motion, lost focus, or a hidden cursor.
fn cursorAnimationEnabled(self: *const App) bool {
    if (!self.config.cursor_animation) return false;
    if (self.reduced_motion) return false;
    if (!self.focused) return false;
    if (!self.render_state.cursor.visible) return false;
    return true;
}

fn cursorAnimatorSettings(self: *const App) CursorAnimator.Settings {
    return .{
        .animation_length = @as(f32, @floatFromInt(self.config.cursor_animation_length)) / 1000.0,
        .short_animation_length = @as(f32, @floatFromInt(self.config.cursor_animation_short)) / 1000.0,
        .trail_size = @as(f32, @floatFromInt(self.config.cursor_animation_trail)) / 100.0,
    };
}

fn cursorAnimatorShape(self: *const App) CursorAnimator.Shape {
    return switch (self.render_state.cursor.visual_style) {
        .bar => .bar,
        .underline => .underline,
        .block_hollow => .hollow,
        .block => .block,
    };
}

/// The grid-pixel destination (top-left) of the cursor cell.
fn cursorAnimatorDestination(self: *const App) ?[2]f32 {
    const viewport = self.render_state.cursor.viewport orelse return null;
    const x: u31 = @intCast(viewport.x -| @intFromBool(viewport.wide_tail));
    const y: u31 = viewport.y;
    return .{
        @as(f32, @floatFromInt(x * self.font.cell_width)),
        @as(f32, @floatFromInt(y * self.font.cell_height)),
    };
}

/// Whether the cursor sits on a wide character, doubling the block width.
fn cursorAnimatorDoubleWidth(self: *const App) bool {
    const viewport = self.render_state.cursor.viewport orelse return false;
    if (viewport.wide_tail) return true;
    const cell = self.render_state.cursor.cell;
    return cell.wide == .wide;
}

/// Reconcile the animator to the terminal's current cursor cell after each
/// render-state update. Retargets when the cursor moved; initializes the
/// animator on the first call; flags movement (the trail then advances per
/// produced frame in lockstep with the compositor).
fn syncCursorAnimator(self: *App) void {
    if (!self.cursorAnimationEnabled()) {
        if (self.cursor_anim_moving) {
            self.cursor_anim_moving = false;
            self.dirtyCursorCell();
        }
        if (self.cursor_anim_ready) {
            // Snap the animator to its destination so a stale quad does not
            // linger when the cursor is hidden/unfocused.
            const destination = self.cursorAnimatorDestination() orelse .{ 0, 0 };
            self.cursor_anim.setDestination(
                destination,
                .{ @floatFromInt(self.font.cell_width), @floatFromInt(self.font.cell_height) },
                self.cursorAnimatorDoubleWidth(),
                self.cursorAnimatorSettings(),
                true,
            );
        }
        return;
    }

    const destination = self.cursorAnimatorDestination() orelse return;
    const dims = [2]f32{
        @as(f32, @floatFromInt(self.font.cell_width)),
        @as(f32, @floatFromInt(self.font.cell_height)),
    };
    const double_width = self.cursorAnimatorDoubleWidth();
    const shape = self.cursorAnimatorShape();

    if (!self.cursor_anim_ready) {
        self.cursor_anim = CursorAnimator.Animator.init(shape, dims, double_width, destination);
        self.cursor_anim_ready = true;
        return;
    }

    if (self.cursor_anim.shape != shape) {
        self.cursor_anim.setShape(shape, dims, double_width);
    }
    self.cursor_anim.setDestination(destination, dims, double_width, self.cursorAnimatorSettings(), false);
    if (!self.cursor_anim.settled()) {
        self.cursor_anim_moving = true;
    }
}

/// Current animated cursor quad, or null when the animator is at rest
/// (so the renderer's native cell cursor takes over).
fn cursorOverlay(self: *const App) ?Renderer.CursorOverlay {
    if (!self.cursorAnimationEnabled()) return null;
    if (!self.cursor_anim_ready) return null;
    // The overlay fills a filled quad; a hollow block must stay the native
    // outlined sprite, so it does not animate.
    if (self.cursor_anim.shape == .hollow) return null;
    if (self.cursor_anim.settled()) return null;
    const corners = self.cursor_anim.cursorCorners();
    return .{
        .corners = .{
            .{ @intFromFloat(corners[0][0]), @intFromFloat(corners[0][1]) },
            .{ @intFromFloat(corners[1][0]), @intFromFloat(corners[1][1]) },
            .{ @intFromFloat(corners[2][0]), @intFromFloat(corners[2][1]) },
            .{ @intFromFloat(corners[3][0]), @intFromFloat(corners[3][1]) },
        },
        .shape = self.cursor_anim.shape,
    };
}

/// Advance the cursor trail once per produced frame. From rest the first
/// step takes no elapsed time (so a fresh jump glides from the next frame),
/// while an already-moving trail folds in the whole frame period — keeping
/// the trail's sampling rate equal to the compositor's refresh rate.
fn advanceCursorAnimation(self: *App, was_animating: bool) void {
    const now_ns = self.nowNs();
    if (!was_animating) self.cursor_anim_last_ns = now_ns;
    const dt_sec = @as(f32, @floatFromInt(now_ns -| self.cursor_anim_last_ns)) / @as(f32, std.time.ns_per_s);
    self.cursor_anim_last_ns = now_ns;
    const clamped = std.math.clamp(dt_sec, 0.0, 0.05);
    if (self.cursor_anim.advance(clamped)) {
        self.cursor_anim_moving = true;
    } else {
        // Settled: hand off to the native cell cursor, repainting its cell
        // in cursor colors (the overlay no longer covers it).
        if (self.cursor_anim_moving) {
            self.cursor_anim_moving = false;
            self.dirtyCursorCell();
        }
    }
}

fn nowNs(self: *const App) u64 {
    const ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    return @intCast(@max(ns, 0));
}

fn clearRenderDirty(self: *App) void {
    clearStateDirty(&self.render_state);
}

fn clearStateDirty(state: *vt.RenderState) void {
    const rows = state.row_data.slice();
    for (rows.items(.dirty)) |*dirty| dirty.* = false;
    state.dirty = .false;
}

/// Renderer-only state changed. Invalidate any in-flight snapshot without
/// touching RenderState while the worker may be reading it; startAsyncRender
/// performs the full rebuild after the worker becomes idle.
fn requestFullAsyncRedraw(self: *App) void {
    self.invalidateAsyncFrame();
    self.needs_redraw = true;
}

fn invalidateAsyncFrame(self: *App) void {
    self.async_generation +%= 1;
    self.async_force_full = true;
    // A held frame was rastered from the now-stale state; drop it rather
    // than commit outdated pixels on the next frame callback.
    if (self.held_frame) |buffer| {
        self.held_frame = null;
        self.window.cancelRender(buffer);
        self.frame_damage.invalidate();
        self.needs_redraw = true;
    }
}

/// Window resize delegate: fit the grid to the new size, resize the
/// terminal (reflow) and tell the child.
fn resize(ctx: *anyopaque, width: u31, height: u31) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.resizeForConfig(width, height, self.config);
}

fn resizeForConfig(self: *App, width: u31, height: u31, config: Config) anyerror!void {
    self.tab_bar_height = self.font.cell_height;
    const padding = paddingWithTabBar(config, self.window.scale120, self.tab_bar_height);
    const layout = TerminalLayout.init(
        width,
        height,
        self.font.cell_width,
        self.font.cell_height,
        padding,
    );
    const layout_changed = !std.meta.eql(layout, self.layout);
    self.layout = layout;
    const cols = layout.columns;
    const rows = layout.rows;
    const terminal_width_px = std.math.mul(u32, cols, self.font.cell_width) catch std.math.maxInt(u32);
    const terminal_height_px = std.math.mul(u32, rows, self.font.cell_height) catch std.math.maxInt(u32);
    const pixels_changed = terminal_width_px != self.tab().term.width_px or terminal_height_px != self.tab().term.height_px;
    const cells_changed = cols != self.tab().term.cols or rows != self.tab().term.rows;
    if (!cells_changed and !pixels_changed and !layout_changed) return;

    if (cells_changed or pixels_changed) {
        if (cells_changed) log.debug("resize to {d}x{d} cells", .{ cols, rows });
        // Every tab shares the window geometry; keep each terminal (and, via
        // SIGWINCH, its child) sized to the same grid.
        for (self.tabs.items) |tb| {
            try tb.resize(self.alloc, cols, rows, self.font.cell_width, self.font.cell_height);
            self.notifyTabResize(tb);
        }
        if (cells_changed) self.refreshSearch(self.tab());
    }
    self.geometry_redraw = true;
    self.needs_redraw = true;
    self.syncScrollbarHover();
    self.syncHoveredLink(true);
}

test "scrollbar geometry maps viewport rows across the track" {
    const layout = TerminalLayout.init(100, 100, 10, 10, .{});
    const top = scrollbarGeometry(.{ .total = 100, .offset = 0, .len = 20 }, layout, 120, scrollbar_default_alpha).?;
    const middle = scrollbarGeometry(.{ .total = 100, .offset = 40, .len = 20 }, layout, 120, scrollbar_default_alpha).?;
    const bottom = scrollbarGeometry(.{ .total = 100, .offset = 80, .len = 20 }, layout, 120, scrollbar_default_alpha).?;

    try std.testing.expectEqual(@as(u31, 91), top.thumb.x);
    try std.testing.expectEqual(@as(u31, 6), top.thumb.width);
    try std.testing.expectEqual(@as(u31, 24), top.thumb.height);
    try std.testing.expectEqual(@as(u31, 3), top.thumb.y);
    try std.testing.expectEqual(@as(u31, 38), middle.thumb.y);
    try std.testing.expectEqual(@as(u31, 73), bottom.thumb.y);
    try std.testing.expectEqual(@as(usize, 0), scrollbarRowForThumbY(top, 3));
    try std.testing.expectEqual(@as(usize, 40), scrollbarRowForThumbY(top, 38));
    try std.testing.expectEqual(@as(usize, 80), scrollbarRowForThumbY(top, 73));
    try std.testing.expect(scrollbarAtBottom(.{ .total = 100, .offset = 80, .len = 20 }));
    try std.testing.expect(!scrollbarAtBottom(.{ .total = 100, .offset = 79, .len = 20 }));
    try std.testing.expect(scrollbarShouldRender(.{ .total = 100, .offset = 80, .len = 20 }, scrollbar_default_alpha));
    try std.testing.expect(scrollbarShouldRender(.{ .total = 100, .offset = 80, .len = 20 }, scrollbar_hover_alpha));
    try std.testing.expect(!scrollbarShouldRender(.{ .total = 20, .offset = 0, .len = 20 }, scrollbar_hover_alpha));
    try std.testing.expect(!scrollbarShouldRender(.{ .total = 100, .offset = 40, .len = 20 }, 0));
    try std.testing.expect(scrollbarGeometry(.{ .total = 20, .offset = 0, .len = 20 }, layout, 120, scrollbar_default_alpha) == null);
}

test "semantic command output extracts most recent completed output" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer term.deinit(alloc);

    try term.semanticPrompt(.init(.fresh_line_new_prompt));
    try term.printString("$ ");
    try term.semanticPrompt(.init(.end_prompt_start_input));
    try term.printString("printf");
    try term.semanticPrompt(.init(.end_input_start_output));
    term.carriageReturn();
    try term.linefeed();
    try term.printString("one");
    term.carriageReturn();
    try term.linefeed();
    try term.printString("two");
    try term.semanticPrompt(.init(.end_command));
    term.carriageReturn();
    try term.linefeed();
    try term.semanticPrompt(.init(.fresh_line_new_prompt));
    try term.printString("$ ");

    const output = semanticCommandOutputText(alloc, term.screens.active).?;
    defer alloc.free(output);
    try std.testing.expectEqualStrings("one\ntwo", output);
}

test "search backspace removes one UTF-8 codepoint" {
    const alloc = std.testing.allocator;
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(alloc);
    try query.appendSlice(alloc, "abé🙂");

    try std.testing.expect(truncateLastUtf8(&query));
    try std.testing.expectEqualStrings("abé", query.items);
    try std.testing.expect(truncateLastUtf8(&query));
    try std.testing.expectEqualStrings("ab", query.items);
    try std.testing.expect(truncateLastUtf8(&query));
    try std.testing.expectEqualStrings("a", query.items);
    try std.testing.expect(truncateLastUtf8(&query));
    try std.testing.expect(!truncateLastUtf8(&query));
}

test "scrollback keys require supported modifiers on the primary screen" {
    var config: Config = .{};
    defer config.keybinds.deinit(std.testing.allocator);
    const shifted: vt.input.KeyMods = .{ .shift = true };
    const ctrl_shifted: vt.input.KeyMods = .{ .shift = true, .ctrl = true };
    try std.testing.expectEqual(
        ScrollbackKeyAction{ .lines = -1 },
        scrollbackKeyAction(&config, .primary, .{ .key = .arrow_up, .mods = shifted }).?,
    );
    try std.testing.expectEqual(
        ScrollbackKeyAction{ .lines = 1 },
        scrollbackKeyAction(&config, .primary, .{ .key = .arrow_down, .mods = shifted }).?,
    );
    try std.testing.expectEqual(
        ScrollbackKeyAction.page_up,
        scrollbackKeyAction(&config, .primary, .{ .key = .page_up, .mods = shifted }).?,
    );
    try std.testing.expectEqual(
        ScrollbackKeyAction.page_down,
        scrollbackKeyAction(&config, .primary, .{ .key = .page_down, .mods = shifted }).?,
    );
    try std.testing.expectEqual(
        ScrollbackKeyAction.top,
        scrollbackKeyAction(&config, .primary, .{ .key = .home, .mods = shifted }).?,
    );
    try std.testing.expectEqual(
        ScrollbackKeyAction.bottom,
        scrollbackKeyAction(&config, .primary, .{ .key = .end, .mods = shifted }).?,
    );

    try std.testing.expectEqual(
        ScrollbackKeyAction.passthrough,
        scrollbackKeyAction(&config, .alternate, .{ .key = .arrow_up, .mods = shifted }).?,
    );
    try std.testing.expectEqual(
        null,
        scrollbackKeyAction(&config, .primary, .{ .key = .arrow_up, .mods = ctrl_shifted }),
    );
    try std.testing.expectEqual(
        null,
        scrollbackKeyAction(&config, .primary, .{ .key = .page_up }),
    );
    try std.testing.expectEqual(
        null,
        scrollbackKeyAction(&config, .primary, .{
            .key = .page_up,
            .mods = ctrl_shifted,
        }),
    );

    try config.set(std.testing.allocator, "keybind", "ctrl+shift+up=scroll_page_lines:-5");
    try config.set(std.testing.allocator, "keybind", "shift+up=unbind");
    try std.testing.expectEqual(
        ScrollbackKeyAction{ .lines = -5 },
        scrollbackKeyAction(&config, .primary, .{ .key = .arrow_up, .mods = ctrl_shifted }).?,
    );
    try std.testing.expectEqual(
        ScrollbackKeyAction.passthrough,
        scrollbackKeyAction(&config, .primary, .{ .key = .arrow_up, .mods = shifted }).?,
    );
}

test "custom scrolling overrides fixed chords and passes through on the alternate screen" {
    var config: Config = .{};
    defer config.keybinds.deinit(std.testing.allocator);
    const cases = [_]struct { binding: []const u8, event: vt.input.KeyEvent }{
        .{ .binding = "ctrl+shift+c=scroll_page_lines:-3", .event = .{ .key = .key_c, .unshifted_codepoint = 'c', .mods = .{ .ctrl = true, .shift = true } } },
        .{ .binding = "ctrl+==scroll_page_lines:-3", .event = .{ .key = .equal, .unshifted_codepoint = '=', .mods = .{ .ctrl = true } } },
        .{ .binding = "shift+PageUp=scroll_page_lines:-3", .event = .{ .key = .page_up, .mods = .{ .shift = true } } },
    };
    for (cases) |case| {
        try config.set(std.testing.allocator, "keybind", case.binding);
        for ([_]vt.input.KeyAction{ .press, .repeat, .release }) |action| {
            var event = case.event;
            event.action = action;
            try std.testing.expectEqual(ScrollbackKeyAction{ .lines = -3 }, scrollbackKeyAction(&config, .primary, event).?);
            try std.testing.expectEqual(ScrollbackKeyAction.passthrough, scrollbackKeyAction(&config, .alternate, event).?);
        }
    }
    try config.set(std.testing.allocator, "keybind", "ctrl+shift+c=unbind");
    try std.testing.expectEqual(ScrollbackKeyAction.passthrough, scrollbackKeyAction(&config, .primary, cases[0].event).?);
}

test "scrollback search scrolls a history match into the viewport" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{
        .cols = 16,
        .rows = 3,
        .max_scrollback_bytes = 100,
    });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("needle\r\n");
    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        stream.nextSlice(std.fmt.bufPrint(&buf, "line{d}\r\n", .{i}) catch unreachable);
    }

    const screen = term.screens.active;
    var search: vt.search.Screen = try .init(alloc, screen, "needle");
    defer search.deinit();
    try search.searchAll();
    try std.testing.expect(try search.select(.next));
    const match = search.selectedMatch().?;
    try std.testing.expect(!searchMatchVisible(screen, match));

    screen.pages.scroll(.{ .pin = match.startPin() });
    try std.testing.expect(searchMatchVisible(screen, match));
    const range = highlightRange(
        screen,
        match.startPin(),
        match.endPin(),
        term.rows,
        term.cols,
    ).?;
    try std.testing.expectEqual(@as(u32, 0), range.start.y);
    try std.testing.expectEqual(@as(u16, 0), range.start.x);
    try std.testing.expectEqual(@as(u16, 5), range.end.x);
}

test "search match mask includes every visible result" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("hit hit");

    var mask = try searchMatchMask(
        alloc,
        term.screens.active,
        "hit",
        term.rows,
        term.cols,
    );
    defer mask.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 20), mask.items.len);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false, true, true, true, false, false, false }, mask.items[0..10]);
    const no_matches = [_]bool{false} ** 10;
    try std.testing.expectEqualSlices(bool, &no_matches, mask.items[10..20]);
}

test "stopping the read pipeline preserves final PTY output" {
    const Collector = struct {
        bytes: [256]u8 = undefined,
        len: usize = 0,

        fn nextSlice(self: *@This(), value: []const u8) void {
            @memcpy(self.bytes[self.len..][0..value.len], value);
            self.len += value.len;
        }
    };

    const linux = std.os.linux;
    var pipe_fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true, .NONBLOCK = true })),
    );
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    var pipeline: ReadPipeline = try .init(pipe_fds[0]);
    defer pipeline.deinit();
    try pipeline.start();

    const expected = "output written immediately before child exit";
    const written = linux.write(pipe_fds[1], expected.ptr, expected.len);
    try std.testing.expectEqual(.SUCCESS, linux.errno(written));
    try std.testing.expectEqual(expected.len, written);

    // Model the SIGCHLD path: stop may win before the gather thread reads,
    // after it publishes, or between those points. Both stores are drained in
    // order so none of the child's final bytes are lost.
    pipeline.stop();
    var collector: Collector = .{};
    while (pipeline.take()) |batch| {
        collector.nextSlice(batch);
        pipeline.release();
    }
    _ = try drainPtyTail(pipe_fds[0], &collector);

    try std.testing.expectEqualStrings(expected, collector.bytes[0..collector.len]);
}
