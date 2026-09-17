//! Owns Wayland clipboard, primary-selection, drag-and-drop, and their
//! bounded, nonblocking transfers: one incoming pipe and a small outgoing
//! pool, all with deadlines. Application policy remains with App.

const Clipboard = @This();

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const clipboard_format = @import("clipboard_format.zig");

const log = std.log.scoped(.app);

// Keep one transfer within the PTY write backlog's bound. Without a cap, a
// clipboard owner that never closes its pipe can grow this process without
// limit while the event loop continues draining it.
const max_transfer_size = 1024 * 1024;
pub const max_outgoing_transfers = 8;
const max_outgoing_bytes = 16 * 1024 * 1024;
const transfer_timeout_ms: i64 = 10 * 1000;
const max_write_per_dispatch = 64 * 1024;
const max_dnd_source_bytes = 64 * 1024 * 1024;
const max_dnd_source_mimes = 256;

pub const Target = enum { clipboard, primary };

pub const Osc52Read = struct { tab_id: u64, kind: u8 };
pub const TerminalPaste = struct { tab_id: u64, target: Target };

pub const Purpose = union(enum) {
    terminal: TerminalPaste,
    osc52_read: Osc52Read,
    kitty_read: u64,
};

pub const RequestResult = enum { started, busy, unavailable };

pub const DndData = struct {
    mime: []const u8,
    data: []const u8,
    x: f64,
    y: f64,
    operations: DndOperations,
};

pub const Event = union(enum) {
    terminal: struct {
        tab_id: u64,
        target: Target,
        mime: []const u8,
        data: []const u8,
    },
    osc52_read: struct { tab_id: u64, kind: u8, data: []const u8 },
    kitty_read: struct { tab_id: u64, mime: []const u8, data: []const u8 },
    dnd: DndData,
};

pub const DndOperations = packed struct(u2) {
    copy: bool = false,
    move: bool = false,
};

pub const DndMotion = struct {
    x: f64,
    y: f64,
    mime: []const u8,
    operations: DndOperations,
};

pub const DndAction = enum { none, copy, move };

pub const DndSourceItem = struct {
    mime: []const u8,
    data: ?[]const u8,
};

pub const DndSourceEvent = union(enum) {
    target: struct { tab_id: u64, index: ?usize },
    action: struct { tab_id: u64, action: DndAction },
    dropped: u64,
    finished: struct { tab_id: u64, cancelled: bool },
    data_request: struct { tab_id: u64, index: usize },
};

pub const DndEvent = union(enum) {
    motion: DndMotion,
    leave,
    source: DndSourceEvent,
};

pub const DndFn = *const fn (ctx: *anyopaque, event: DndEvent) bool;

alloc: std.mem.Allocator,
data_manager: ?*wl.DataDeviceManager,
data_device: ?*wl.DataDevice,
primary_manager: ?*zwp.PrimarySelectionDeviceManagerV1,
primary_device: ?*zwp.PrimarySelectionDeviceV1,
clip_offer: ?*DataOffer,
clip_pending_offer: ?*DataOffer,
primary_offer: ?*PrimaryOffer,
primary_pending_offer: ?*PrimaryOffer,
dnd_offer: ?*DataOffer,
dnd_source: ?*DndSource,
clip_source: ?*Source,
primary_source: ?*Source,
transfer_fd: posix.fd_t,
transfer_buf: std.ArrayList(u8),
transfer_action: TransferAction,
transfer_deadline_ms: i64,
outgoing: [max_outgoing_transfers]?OutgoingTransfer,
outgoing_bytes: usize,
dnd_ctx: ?*anyopaque,
dnd_fn: ?DndFn,

const TransferAction = union(enum) {
    terminal: struct {
        tab_id: u64 = 0,
        target: Target,
        mime: [*:0]const u8,
    },
    osc52_read: Osc52Read,
    kitty_read: struct { tab_id: u64, mime: [*:0]const u8 },
    dnd: *DataOffer,
};

const OutgoingTransfer = struct {
    fd: posix.fd_t,
    data: []u8,
    offset: usize,
    deadline_ms: i64,
};

const TransferOffer = union(enum) {
    clipboard: *DataOffer,
    primary: *PrimaryOffer,

    fn receive(self: TransferOffer, mime: [*:0]const u8, fd: posix.fd_t) void {
        switch (self) {
            .clipboard => |offer| offer.offer.receive(mime, fd),
            .primary => |offer| offer.offer.receive(mime, fd),
        }
    }
};

const DataOffer = struct {
    clipboard: *Clipboard,
    offer: *wl.DataOffer,
    mimes: clipboard_format.MimeMask = 0,
    dnd_mimes: clipboard_format.MimeMask = 0,
    dnd_action: wl.DataDeviceManager.DndAction = .{},
    source_actions: wl.DataDeviceManager.DndAction = .{ .copy = true },
    enter_serial: u32 = 0,
    x: f64 = 0,
    y: f64 = 0,

    fn noteMime(self: *DataOffer, mime_type: [*:0]const u8) void {
        if (clipboard_format.mimeBit(&clipboard_format.paste_mime_preference, mime_type)) |bit| self.mimes |= bit;
        if (clipboard_format.mimeBit(&clipboard_format.dnd_mime_preference, mime_type)) |bit| self.dnd_mimes |= bit;
    }

    fn bestMime(self: *const DataOffer) ?[*:0]const u8 {
        return clipboard_format.preferredMime(&clipboard_format.paste_mime_preference, self.mimes);
    }

    fn bestDndMime(self: *const DataOffer) ?[*:0]const u8 {
        return clipboard_format.preferredMime(&clipboard_format.dnd_mime_preference, self.dnd_mimes);
    }

    fn destroy(self: *DataOffer) void {
        const clipboard = self.clipboard;
        if (clipboard.clip_offer == self) clipboard.clip_offer = null;
        if (clipboard.clip_pending_offer == self) clipboard.clip_pending_offer = null;
        if (clipboard.dnd_offer == self) clipboard.dnd_offer = null;
        self.offer.destroy();
        clipboard.alloc.destroy(self);
    }
};

const PrimaryOffer = struct {
    clipboard: *Clipboard,
    offer: *zwp.PrimarySelectionOfferV1,
    mimes: clipboard_format.MimeMask = 0,

    fn noteMime(self: *PrimaryOffer, mime_type: [*:0]const u8) void {
        if (clipboard_format.mimeBit(&clipboard_format.paste_mime_preference, mime_type)) |bit| self.mimes |= bit;
    }

    fn bestMime(self: *const PrimaryOffer) ?[*:0]const u8 {
        return clipboard_format.preferredMime(&clipboard_format.paste_mime_preference, self.mimes);
    }

    fn destroy(self: *PrimaryOffer) void {
        const clipboard = self.clipboard;
        if (clipboard.primary_offer == self) clipboard.primary_offer = null;
        if (clipboard.primary_pending_offer == self) clipboard.primary_pending_offer = null;
        self.offer.destroy();
        clipboard.alloc.destroy(self);
    }
};

/// Heap context for an outgoing selection source. It owns both the sentinel
/// text and its optional Latin-1 representation, plus the source proxy,
/// until cancellation, replacement, or teardown.
const Source = struct {
    clipboard: *Clipboard,
    text: [:0]const u8,
    latin1: ?[]const u8,
    source: union(enum) {
        clipboard: *wl.DataSource,
        primary: *zwp.PrimarySelectionSourceV1,
    },

    fn destroy(self: *Source) void {
        const clipboard = self.clipboard;
        switch (self.source) {
            .clipboard => |source| {
                if (clipboard.clip_source == self) clipboard.clip_source = null;
                source.destroy();
            },
            .primary => |source| {
                if (clipboard.primary_source == self) clipboard.primary_source = null;
                source.destroy();
            },
        }
        if (self.latin1) |text| clipboard.alloc.free(text);
        clipboard.alloc.free(self.text);
        clipboard.alloc.destroy(self);
    }

    fn supportsMime(self: *const Source, mime: [:0]const u8) bool {
        return !std.mem.eql(u8, mime, "STRING") or self.latin1 != null;
    }

    fn send(self: *Source, mime: [*:0]const u8, fd: i32) void {
        const text = if (std.mem.eql(u8, std.mem.span(mime), "STRING"))
            self.latin1 orelse {
                _ = std.os.linux.close(fd);
                return;
            }
        else
            self.text;
        self.clipboard.sendSelection(text, fd);
    }
};

const DndSource = struct {
    clipboard: *Clipboard,
    tab_id: u64,
    source: *wl.DataSource,
    mimes: []Mime,
    pending: [max_outgoing_transfers]?Pending = @splat(null),

    const Mime = struct {
        name: [:0]u8,
        data: ?[]u8,
    };

    const Pending = struct {
        fd: posix.fd_t,
        index: usize,
        deadline_ms: i64,
    };

    fn destroy(self: *DndSource) void {
        const clipboard = self.clipboard;
        if (clipboard.dnd_source == self) clipboard.dnd_source = null;
        for (self.pending) |pending| {
            if (pending) |item| _ = std.os.linux.close(item.fd);
        }
        for (self.mimes) |mime| {
            clipboard.alloc.free(mime.name);
            if (mime.data) |data| clipboard.alloc.free(data);
        }
        clipboard.alloc.free(self.mimes);
        self.source.destroy();
        clipboard.alloc.destroy(self);
    }

    fn mimeIndex(self: *const DndSource, mime: [*:0]const u8) ?usize {
        const name = std.mem.span(mime);
        for (self.mimes, 0..) |item, index| {
            if (std.mem.eql(u8, item.name, name)) return index;
        }
        return null;
    }

    fn send(self: *DndSource, mime: [*:0]const u8, fd: posix.fd_t) void {
        const index = self.mimeIndex(mime) orelse {
            _ = std.os.linux.close(fd);
            return;
        };
        if (self.mimes[index].data) |data| {
            self.clipboard.sendSelection(data, fd);
            return;
        }
        if (self.clipboard.activeOutgoingCount() + self.pendingCount() >= max_outgoing_transfers) {
            _ = std.os.linux.close(fd);
            return;
        }
        const slot = for (&self.pending, 0..) |pending, i| {
            if (pending == null) break i;
        } else {
            _ = std.os.linux.close(fd);
            return;
        };
        self.pending[slot] = .{
            .fd = fd,
            .index = index,
            .deadline_ms = monotonicMs() + transfer_timeout_ms,
        };
        if (!self.clipboard.reportDnd(.{ .source = .{ .data_request = .{
            .tab_id = self.tab_id,
            .index = index,
        } } })) {
            self.pending[slot] = null;
            _ = std.os.linux.close(fd);
        }
    }

    fn pendingCount(self: *const DndSource) usize {
        var count: usize = 0;
        for (self.pending) |pending| count += @intFromBool(pending != null);
        return count;
    }

    fn pendingDeadline(self: *const DndSource) ?i64 {
        var deadline: ?i64 = null;
        for (self.pending) |pending| if (pending) |item| {
            if (deadline == null or item.deadline_ms < deadline.?) deadline = item.deadline_ms;
        };
        return deadline;
    }

    fn expirePending(self: *DndSource, now: i64) void {
        for (&self.pending) |*pending| {
            const item = pending.* orelse continue;
            if (item.deadline_ms > now) continue;
            _ = std.os.linux.close(item.fd);
            pending.* = null;
        }
    }

    fn fulfill(self: *DndSource, index: usize, data: ?[]const u8) void {
        for (&self.pending) |*pending| {
            const item = pending.* orelse continue;
            if (item.index != index) continue;
            pending.* = null;
            if (data) |bytes| {
                self.clipboard.sendSelection(bytes, item.fd);
            } else {
                _ = std.os.linux.close(item.fd);
            }
        }
    }
};

pub fn init(
    alloc: std.mem.Allocator,
    data_manager: ?*wl.DataDeviceManager,
    primary_manager: ?*zwp.PrimarySelectionDeviceManagerV1,
) Clipboard {
    return .{
        .alloc = alloc,
        .data_manager = data_manager,
        .data_device = null,
        .primary_manager = primary_manager,
        .primary_device = null,
        .clip_offer = null,
        .clip_pending_offer = null,
        .primary_offer = null,
        .primary_pending_offer = null,
        .dnd_offer = null,
        .dnd_source = null,
        .clip_source = null,
        .primary_source = null,
        .transfer_fd = -1,
        .transfer_buf = .empty,
        .transfer_action = .{ .terminal = .{
            .target = .clipboard,
            .mime = clipboard_format.paste_mime_preference[0].ptr,
        } },
        .transfer_deadline_ms = 0,
        .outgoing = @splat(null),
        .outgoing_bytes = 0,
        .dnd_ctx = null,
        .dnd_fn = null,
    };
}

pub fn deinit(self: *Clipboard) void {
    self.abortTransfer();
    for (0..max_outgoing_transfers) |i| self.closeOutgoing(i);
    self.transfer_buf.deinit(self.alloc);
    if (self.clip_offer) |offer| offer.destroy();
    if (self.clip_pending_offer) |offer| offer.destroy();
    if (self.primary_offer) |offer| offer.destroy();
    if (self.primary_pending_offer) |offer| offer.destroy();
    if (self.dnd_offer) |offer| offer.destroy();
    if (self.dnd_source) |source| source.destroy();
    if (self.clip_source) |source| source.destroy();
    if (self.primary_source) |source| source.destroy();
}

fn activeOutgoingCount(self: *const Clipboard) usize {
    var count: usize = 0;
    for (self.outgoing) |transfer| count += @intFromBool(transfer != null);
    return count;
}

fn sendSelection(self: *Clipboard, text: []const u8, fd: posix.fd_t) void {
    const pending = if (self.dnd_source) |source| source.pendingCount() else 0;
    if (self.activeOutgoingCount() + pending >= max_outgoing_transfers) {
        _ = std.os.linux.close(fd);
        return;
    }
    const slot = for (&self.outgoing, 0..) |transfer, i| {
        if (transfer == null) break i;
    } else {
        _ = std.os.linux.close(fd);
        return;
    };
    if (text.len > max_outgoing_bytes -| self.outgoing_bytes) {
        _ = std.os.linux.close(fd);
        return;
    }
    const owned = self.alloc.dupe(u8, text) catch {
        _ = std.os.linux.close(fd);
        return;
    };
    setNonblocking(fd) catch {
        self.alloc.free(owned);
        _ = std.os.linux.close(fd);
        return;
    };
    self.outgoing[slot] = .{
        .fd = fd,
        .data = owned,
        .offset = 0,
        .deadline_ms = monotonicMs() + transfer_timeout_ms,
    };
    self.outgoing_bytes += owned.len;
}

pub fn pollOutgoing(self: *Clipboard, fds: *[max_outgoing_transfers]posix.pollfd) void {
    for (self.outgoing, 0..) |transfer, i| fds[i] = if (transfer) |item|
        .{ .fd = item.fd, .events = posix.POLL.OUT, .revents = 0 }
    else
        .{ .fd = -1, .events = posix.POLL.OUT, .revents = 0 };
}

pub fn dispatchOutgoing(self: *Clipboard, fds: *const [max_outgoing_transfers]posix.pollfd) void {
    for (fds, 0..) |poll_fd, i| {
        const transfer = &(self.outgoing[i] orelse continue);
        if (poll_fd.fd != transfer.fd or poll_fd.revents == 0) continue;
        if (poll_fd.revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            self.closeOutgoing(i);
            continue;
        }
        if (poll_fd.revents & posix.POLL.OUT == 0) continue;
        const remaining = transfer.data[transfer.offset..];
        const amount = @min(remaining.len, max_write_per_dispatch);
        const rc = writeWithoutSigpipe(transfer.fd, remaining[0..amount]);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                transfer.offset += rc;
                if (transfer.offset == transfer.data.len) self.closeOutgoing(i);
            },
            .INTR, .AGAIN => {},
            else => self.closeOutgoing(i),
        }
    }
}

pub fn pollTimeoutMs(self: *const Clipboard) i32 {
    var deadline: ?i64 = if (self.transfer_fd >= 0) self.transfer_deadline_ms else null;
    for (self.outgoing) |transfer| if (transfer) |item| {
        if (deadline == null or item.deadline_ms < deadline.?) deadline = item.deadline_ms;
    };
    if (self.dnd_source) |source| if (source.pendingDeadline()) |pending| {
        if (deadline == null or pending < deadline.?) deadline = pending;
    };
    const end = deadline orelse return -1;
    return @intCast(@min(@max(end - monotonicMs(), 0), std.math.maxInt(i32)));
}

/// Expires stale transfers. True means an incoming transfer was aborted.
pub fn expireTransfers(self: *Clipboard) bool {
    const now = monotonicMs();
    const incoming_expired = self.transfer_fd >= 0 and self.transfer_deadline_ms <= now;
    if (incoming_expired) self.abortTransfer();
    for (self.outgoing, 0..) |transfer, i| {
        if (transfer) |item| if (item.deadline_ms <= now) self.closeOutgoing(i);
    }
    if (self.dnd_source) |source| source.expirePending(now);
    return incoming_expired;
}

pub fn osc52Read(self: *const Clipboard) ?Osc52Read {
    if (self.transfer_fd < 0) return null;
    return switch (self.transfer_action) {
        .osc52_read => |read| read,
        else => null,
    };
}

pub fn kittyReadTabId(self: *const Clipboard) ?u64 {
    if (self.transfer_fd < 0) return null;
    return switch (self.transfer_action) {
        .kitty_read => |read| read.tab_id,
        else => null,
    };
}

fn closeOutgoing(self: *Clipboard, i: usize) void {
    if (self.outgoing[i]) |transfer| {
        _ = std.os.linux.close(transfer.fd);
        self.outgoing_bytes -= transfer.data.len;
        self.alloc.free(transfer.data);
        self.outgoing[i] = null;
    }
}

pub fn setDevices(
    self: *Clipboard,
    data_device: ?*wl.DataDevice,
    primary_device: ?*zwp.PrimarySelectionDeviceV1,
) void {
    self.data_device = data_device;
    self.primary_device = primary_device;
    if (data_device) |device| device.setListener(*Clipboard, dataDeviceListener, self);
    if (primary_device) |device| device.setListener(*Clipboard, primaryDeviceListener, self);
}

pub fn setDndCallback(self: *Clipboard, ctx: *anyopaque, callback: DndFn) void {
    self.dnd_ctx = ctx;
    self.dnd_fn = callback;
}

pub fn startDnd(
    self: *Clipboard,
    tab_id: u64,
    serial: u32,
    origin: *wl.Surface,
    icon: ?*wl.Surface,
    operations: DndOperations,
    items: []const DndSourceItem,
) bool {
    const manager = self.data_manager orelse {
        log.debug("OSC 72 Wayland drag unavailable: no data manager", .{});
        return false;
    };
    const device = self.data_device orelse {
        log.debug("OSC 72 Wayland drag unavailable: no data device", .{});
        return false;
    };
    if (self.dnd_source != null or items.len == 0 or items.len > max_dnd_source_mimes) {
        log.debug("OSC 72 Wayland drag rejected: active={} mimes={d}", .{ self.dnd_source != null, items.len });
        return false;
    }
    var mime_bytes: usize = 0;
    var data_bytes: usize = 0;
    for (items) |item| {
        mime_bytes +|= item.mime.len;
        if (item.data) |data| data_bytes +|= data.len;
    }
    if (mime_bytes > max_transfer_size or data_bytes > max_dnd_source_bytes) return false;

    const source = manager.createDataSource() catch return false;
    const mimes = self.alloc.alloc(DndSource.Mime, items.len) catch {
        source.destroy();
        return false;
    };
    var copied: usize = 0;
    for (items, mimes) |item, *copy| {
        const name = self.alloc.dupeZ(u8, item.mime) catch {
            for (mimes[0..copied]) |done| {
                self.alloc.free(done.name);
                if (done.data) |data| self.alloc.free(data);
            }
            self.alloc.free(mimes);
            source.destroy();
            return false;
        };
        const data = if (item.data) |bytes| self.alloc.dupe(u8, bytes) catch {
            self.alloc.free(name);
            for (mimes[0..copied]) |done| {
                self.alloc.free(done.name);
                if (done.data) |owned| self.alloc.free(owned);
            }
            self.alloc.free(mimes);
            source.destroy();
            return false;
        } else null;
        copy.* = .{ .name = name, .data = data };
        copied += 1;
    }
    const ctx = self.alloc.create(DndSource) catch {
        for (mimes) |mime| {
            self.alloc.free(mime.name);
            if (mime.data) |data| self.alloc.free(data);
        }
        self.alloc.free(mimes);
        source.destroy();
        return false;
    };
    ctx.* = .{ .clipboard = self, .tab_id = tab_id, .source = source, .mimes = mimes };
    for (mimes) |mime| source.offer(mime.name.ptr);
    if (source.getVersion() >= wl.DataSource.set_actions_since_version) {
        source.setActions(.{ .copy = operations.copy, .move = operations.move });
    }
    source.setListener(*DndSource, dndSourceListener, ctx);
    self.dnd_source = ctx;
    device.startDrag(source, origin, icon, serial);
    log.debug("OSC 72 Wayland start_drag sent tab={d} serial={d}", .{ tab_id, serial });
    return true;
}

pub fn fulfillDndData(self: *Clipboard, tab_id: u64, index: usize, data: ?[]const u8) void {
    const source = self.dnd_source orelse return;
    if (source.tab_id == tab_id) source.fulfill(index, data);
}

/// Cancel the active drag source when it belongs to `tab_id`. Returns
/// true when a source was cancelled.
pub fn cancelDnd(self: *Clipboard, tab_id: u64) bool {
    const source = self.dnd_source orelse return false;
    if (source.tab_id != tab_id) return false;
    _ = self.reportDnd(.{ .source = .{ .finished = .{ .tab_id = tab_id, .cancelled = true } } });
    source.destroy();
    return true;
}

/// Apply the running program's OSC 72 acceptance to the active Wayland drag.
pub fn setDndAcceptance(self: *Clipboard, operation: enum { none, copy, move }) void {
    const offer = self.dnd_offer orelse return;
    const allowed: wl.DataDeviceManager.DndAction = .{
        .copy = offer.source_actions.copy,
        .move = offer.source_actions.move,
    };
    // OSC 72 can request an unavailable action, including a stale response
    // after source actions change. Wayland requires preferred to be in allowed.
    const preferred: wl.DataDeviceManager.DndAction = switch (operation) {
        .none => .{},
        .copy => .{ .copy = allowed.copy },
        .move => .{ .move = allowed.move },
    };
    const mime = if (preferred.copy or preferred.move) offer.bestDndMime() else null;
    offer.offer.accept(offer.enter_serial, mime);
    offer.offer.setActions(allowed, preferred);
}

/// Takes ownership of `text` on every path.
pub fn claim(self: *Clipboard, target: Target, text: [:0]const u8, serial: u32) bool {
    return switch (target) {
        .clipboard => self.claimClipboard(text, serial),
        .primary => self.claimPrimary(text, serial),
    };
}

pub fn request(self: *Clipboard, target: Target, purpose: Purpose) RequestResult {
    if (self.transfer_fd >= 0) return .busy;

    switch (target) {
        .clipboard => {
            const offer = self.clip_offer orelse return .unavailable;
            const mime = offer.bestMime() orelse return .unavailable;
            const action: TransferAction = switch (purpose) {
                .terminal => |source| .{ .terminal = .{ .tab_id = source.tab_id, .target = source.target, .mime = mime } },
                .osc52_read => |read| .{ .osc52_read = read },
                .kitty_read => |tab_id| .{ .kitty_read = .{ .tab_id = tab_id, .mime = mime } },
            };
            self.beginTransfer(mime, .{ .clipboard = offer }, action) catch return .unavailable;
        },
        .primary => {
            const offer = self.primary_offer orelse return .unavailable;
            const mime = offer.bestMime() orelse return .unavailable;
            const action: TransferAction = switch (purpose) {
                .terminal => |source| .{ .terminal = .{ .tab_id = source.tab_id, .target = source.target, .mime = mime } },
                .osc52_read => |read| .{ .osc52_read = read },
                .kitty_read => |tab_id| .{ .kitty_read = .{ .tab_id = tab_id, .mime = mime } },
            };
            self.beginTransfer(mime, .{ .primary = offer }, action) catch return .unavailable;
        },
    }
    return .started;
}

pub fn transferFd(self: *const Clipboard) posix.fd_t {
    return self.transfer_fd;
}

/// Returns null only when the nonblocking transfer needs more input. A
/// returned event borrows the transfer buffer until `finishEvent` is called.
pub fn readTransfer(self: *Clipboard) !?Event {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = posix.read(self.transfer_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => {
                self.abortTransfer();
                return err;
            },
        };
        if (n == 0) break;
        if (n > max_transfer_size -| self.transfer_buf.items.len) {
            self.abortTransfer();
            return error.TransferTooLarge;
        }
        self.transfer_buf.appendSlice(self.alloc, buf[0..n]) catch |err| {
            self.abortTransfer();
            return err;
        };
    }

    _ = std.os.linux.close(self.transfer_fd);
    self.transfer_fd = -1;
    return switch (self.transfer_action) {
        .terminal => |transfer| .{ .terminal = .{
            .tab_id = transfer.tab_id,
            .target = transfer.target,
            .mime = std.mem.span(transfer.mime),
            .data = self.transfer_buf.items,
        } },
        .osc52_read => |read| .{ .osc52_read = .{ .tab_id = read.tab_id, .kind = read.kind, .data = self.transfer_buf.items } },
        .kitty_read => |read| .{ .kitty_read = .{
            .tab_id = read.tab_id,
            .mime = std.mem.span(read.mime),
            .data = self.transfer_buf.items,
        } },
        .dnd => |offer| .{ .dnd = .{
            .mime = std.mem.span(offer.bestDndMime() orelse unreachable),
            .data = self.transfer_buf.items,
            .x = offer.x,
            .y = offer.y,
            .operations = dndOperations(offer.source_actions),
        } },
    };
}

pub fn finishEvent(self: *Clipboard) void {
    switch (self.transfer_action) {
        .dnd => |offer| {
            if (offer.dnd_action.copy or offer.dnd_action.move) offer.offer.finish();
            offer.destroy();
        },
        else => {},
    }
    self.transfer_buf.clearRetainingCapacity();
    self.transfer_action = .{ .terminal = .{
        .target = .clipboard,
        .mime = clipboard_format.paste_mime_preference[0].ptr,
    } };
}

fn abortTransfer(self: *Clipboard) void {
    if (self.transfer_fd >= 0) _ = std.os.linux.close(self.transfer_fd);
    self.transfer_fd = -1;
    switch (self.transfer_action) {
        .dnd => |offer| offer.destroy(),
        else => {},
    }
    self.transfer_buf.clearRetainingCapacity();
    self.transfer_action = .{ .terminal = .{
        .target = .clipboard,
        .mime = clipboard_format.paste_mime_preference[0].ptr,
    } };
}

/// Clear a selection immediately. Wayland accepts the request without a
/// round trip, which lets terminal protocol writes be answered synchronously.
pub fn clear(self: *Clipboard, target: Target, serial: u32) bool {
    switch (target) {
        .clipboard => {
            const device = self.data_device orelse return false;
            device.setSelection(null, serial);
            if (self.clip_source) |source| source.destroy();
        },
        .primary => {
            const device = self.primary_device orelse return false;
            device.setSelection(null, serial);
            if (self.primary_source) |source| source.destroy();
        },
    }
    return true;
}

/// Return the text representations currently offered for a selection.
/// The returned slice borrows `buf` and the static MIME names.
pub fn availableMimes(
    self: *const Clipboard,
    target: Target,
    buf: *[clipboard_format.paste_mime_preference.len][]const u8,
) []const []const u8 {
    const mask: clipboard_format.MimeMask = switch (target) {
        .clipboard => if (self.clip_offer) |offer| offer.mimes else 0,
        .primary => if (self.primary_offer) |offer| offer.mimes else 0,
    };
    var len: usize = 0;
    for (clipboard_format.paste_mime_preference, 0..) |mime, i| {
        if (mask & (@as(clipboard_format.MimeMask, 1) << @intCast(i)) == 0) continue;
        buf[len] = mime;
        len += 1;
    }
    return buf[0..len];
}

fn claimClipboard(self: *Clipboard, text: [:0]const u8, serial: u32) bool {
    const manager = self.data_manager orelse {
        self.alloc.free(text);
        return false;
    };
    const device = self.data_device orelse {
        self.alloc.free(text);
        return false;
    };
    const source = manager.createDataSource() catch {
        self.alloc.free(text);
        return false;
    };
    const ctx = self.alloc.create(Source) catch {
        source.destroy();
        self.alloc.free(text);
        return false;
    };
    ctx.* = .{
        .clipboard = self,
        .text = text,
        .latin1 = clipboard_format.encodeLatin1(self.alloc, text) catch null,
        .source = .{ .clipboard = source },
    };
    inline for (clipboard_format.paste_mime_preference) |mime| {
        if (ctx.supportsMime(mime)) source.offer(mime.ptr);
    }
    source.setListener(*Source, dataSourceListener, ctx);
    device.setSelection(source, serial);
    if (self.clip_source) |old| old.destroy();
    self.clip_source = ctx;
    log.debug("claimed clipboard ({d} bytes)", .{text.len});
    return true;
}

fn claimPrimary(self: *Clipboard, text: [:0]const u8, serial: u32) bool {
    const manager = self.primary_manager orelse {
        self.alloc.free(text);
        return false;
    };
    const device = self.primary_device orelse {
        self.alloc.free(text);
        return false;
    };
    const source = manager.createSource() catch {
        self.alloc.free(text);
        return false;
    };
    const ctx = self.alloc.create(Source) catch {
        source.destroy();
        self.alloc.free(text);
        return false;
    };
    ctx.* = .{
        .clipboard = self,
        .text = text,
        .latin1 = clipboard_format.encodeLatin1(self.alloc, text) catch null,
        .source = .{ .primary = source },
    };
    inline for (clipboard_format.paste_mime_preference) |mime| {
        if (ctx.supportsMime(mime)) source.offer(mime.ptr);
    }
    source.setListener(*Source, primarySourceListener, ctx);
    device.setSelection(source, serial);
    if (self.primary_source) |old| old.destroy();
    self.primary_source = ctx;
    log.debug("claimed primary selection ({d} bytes)", .{text.len});
    return true;
}

fn beginTransfer(
    self: *Clipboard,
    mime: [*:0]const u8,
    offer: TransferOffer,
    action: TransferAction,
) !void {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    errdefer _ = std.os.linux.close(fds[0]);
    errdefer _ = std.os.linux.close(fds[1]);

    try setNonblocking(fds[0]);
    offer.receive(mime, fds[1]);
    _ = std.os.linux.close(fds[1]);
    self.transfer_fd = fds[0];
    self.transfer_deadline_ms = monotonicMs() + transfer_timeout_ms;
    self.transfer_buf.clearRetainingCapacity();
    self.transfer_action = action;
}

fn createDataOffer(self: *Clipboard, proxy: *wl.DataOffer) ?*DataOffer {
    if (self.clip_pending_offer) |old| old.destroy();
    const offer = self.alloc.create(DataOffer) catch {
        proxy.destroy();
        return null;
    };
    offer.* = .{ .clipboard = self, .offer = proxy };
    proxy.setListener(*DataOffer, dataOfferListener, offer);
    self.clip_pending_offer = offer;
    return offer;
}

fn takeDataOffer(self: *Clipboard, proxy: *wl.DataOffer) ?*DataOffer {
    const offer = self.clip_pending_offer orelse return null;
    if (offer.offer != proxy) return null;
    self.clip_pending_offer = null;
    return offer;
}

fn createPrimaryOffer(self: *Clipboard, proxy: *zwp.PrimarySelectionOfferV1) ?*PrimaryOffer {
    if (self.primary_pending_offer) |old| old.destroy();
    const offer = self.alloc.create(PrimaryOffer) catch {
        proxy.destroy();
        return null;
    };
    offer.* = .{ .clipboard = self, .offer = proxy };
    proxy.setListener(*PrimaryOffer, primaryOfferListener, offer);
    self.primary_pending_offer = offer;
    return offer;
}

fn takePrimaryOffer(self: *Clipboard, proxy: *zwp.PrimarySelectionOfferV1) ?*PrimaryOffer {
    const offer = self.primary_pending_offer orelse return null;
    if (offer.offer != proxy) return null;
    self.primary_pending_offer = null;
    return offer;
}

fn beginDrop(self: *Clipboard) void {
    const offer = self.dnd_offer orelse return;
    self.dnd_offer = null;
    if (self.transfer_fd >= 0) {
        offer.destroy();
        return;
    }
    const mime = offer.bestDndMime() orelse {
        offer.destroy();
        return;
    };
    self.beginTransfer(mime, .{ .clipboard = offer }, .{ .dnd = offer }) catch {
        offer.destroy();
    };
}

fn dataSourceListener(_: *wl.DataSource, event: wl.DataSource.Event, ctx: *Source) void {
    switch (event) {
        .send => |send| ctx.send(send.mime_type, send.fd),
        .cancelled => ctx.destroy(),
        else => {},
    }
}

fn dndSourceListener(_: *wl.DataSource, event: wl.DataSource.Event, ctx: *DndSource) void {
    const clipboard = ctx.clipboard;
    switch (event) {
        .target => |target| {
            const index = if (target.mime_type) |mime| ctx.mimeIndex(mime) else null;
            _ = clipboard.reportDnd(.{ .source = .{ .target = .{ .tab_id = ctx.tab_id, .index = index } } });
        },
        .send => |send| ctx.send(send.mime_type, send.fd),
        .cancelled => {
            _ = clipboard.reportDnd(.{ .source = .{ .finished = .{ .tab_id = ctx.tab_id, .cancelled = true } } });
            ctx.destroy();
        },
        .dnd_drop_performed => _ = clipboard.reportDnd(.{ .source = .{ .dropped = ctx.tab_id } }),
        .dnd_finished => {
            _ = clipboard.reportDnd(.{ .source = .{ .finished = .{ .tab_id = ctx.tab_id, .cancelled = false } } });
            ctx.destroy();
        },
        .action => |action| {
            const selected: DndAction = if (action.dnd_action.copy)
                .copy
            else if (action.dnd_action.move)
                .move
            else
                .none;
            _ = clipboard.reportDnd(.{ .source = .{ .action = .{ .tab_id = ctx.tab_id, .action = selected } } });
        },
    }
}

fn primarySourceListener(
    _: *zwp.PrimarySelectionSourceV1,
    event: zwp.PrimarySelectionSourceV1.Event,
    ctx: *Source,
) void {
    switch (event) {
        .send => |send| ctx.send(send.mime_type, send.fd),
        .cancelled => ctx.destroy(),
    }
}

fn dataOfferListener(_: *wl.DataOffer, event: wl.DataOffer.Event, offer: *DataOffer) void {
    switch (event) {
        .offer => |ev| offer.noteMime(ev.mime_type),
        .source_actions => |ev| {
            offer.source_actions = ev.source_actions;
            const clipboard = offer.clipboard;
            // Wayland sends the source's real actions after data-device enter,
            // so refresh both the application and compositor negotiation.
            if (clipboard.dnd_offer == offer) clipboard.updateDndNegotiation(offer);
        },
        .action => |ev| offer.dnd_action = ev.dnd_action,
    }
}

fn primaryOfferListener(
    _: *zwp.PrimarySelectionOfferV1,
    event: zwp.PrimarySelectionOfferV1.Event,
    offer: *PrimaryOffer,
) void {
    switch (event) {
        .offer => |ev| offer.noteMime(ev.mime_type),
    }
}

fn dataDeviceListener(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *Clipboard) void {
    switch (event) {
        .data_offer => |data_offer| _ = self.createDataOffer(data_offer.id),
        .selection => |selection| {
            const offer = if (selection.id) |id| offer: {
                break :offer self.takeDataOffer(id) orelse {
                    id.destroy();
                    break :offer null;
                };
            } else null;
            if (self.clip_offer) |old| old.destroy();
            self.clip_offer = offer;
        },
        .enter => |enter| {
            const id = enter.id orelse return;
            const offer = self.takeDataOffer(id) orelse {
                id.destroy();
                return;
            };
            if (offer.bestDndMime()) |mime| {
                offer.enter_serial = enter.serial;
                offer.x = enter.x.toDouble();
                offer.y = enter.y.toDouble();
                offer.offer.accept(enter.serial, mime);
                offer.offer.setActions(.{ .copy = true }, .{ .copy = true });
                if (self.dnd_offer) |old| old.destroy();
                self.dnd_offer = offer;
                self.updateDndNegotiation(offer);
            } else {
                offer.offer.accept(enter.serial, null);
                offer.destroy();
            }
        },
        .leave => if (self.dnd_offer) |offer| {
            _ = self.reportDnd(.leave);
            offer.destroy();
        },
        .drop => self.beginDrop(),
        .motion => |motion| if (self.dnd_offer) |offer| {
            offer.x = motion.x.toDouble();
            offer.y = motion.y.toDouble();
            _ = self.reportDndMotion(offer);
        },
    }
}

fn reportDndMotion(self: *Clipboard, offer: *const DataOffer) bool {
    const mime = offer.bestDndMime() orelse return false;
    return self.reportDnd(.{ .motion = .{
        .x = offer.x,
        .y = offer.y,
        .mime = std.mem.span(mime),
        .operations = dndOperations(offer.source_actions),
    } });
}

fn reportDnd(self: *Clipboard, event: DndEvent) bool {
    const callback = self.dnd_fn orelse return false;
    return callback(self.dnd_ctx orelse return false, event);
}

fn updateDndNegotiation(self: *Clipboard, offer: *DataOffer) void {
    if (!self.reportDndMotion(offer)) return;
    const actions = dndActions(offer.source_actions);
    offer.offer.setActions(actions.allowed, actions.preferred);
}

fn dndActions(source: wl.DataDeviceManager.DndAction) struct {
    allowed: wl.DataDeviceManager.DndAction,
    preferred: wl.DataDeviceManager.DndAction,
} {
    const allowed: wl.DataDeviceManager.DndAction = .{
        .copy = source.copy,
        .move = source.move,
    };
    const preferred: wl.DataDeviceManager.DndAction = if (allowed.copy)
        .{ .copy = true }
    else if (allowed.move)
        .{ .move = true }
    else
        .{};
    return .{ .allowed = allowed, .preferred = preferred };
}

fn dndOperations(actions: wl.DataDeviceManager.DndAction) DndOperations {
    return .{ .copy = actions.copy, .move = actions.move };
}

fn primaryDeviceListener(
    _: *zwp.PrimarySelectionDeviceV1,
    event: zwp.PrimarySelectionDeviceV1.Event,
    self: *Clipboard,
) void {
    switch (event) {
        .data_offer => |data_offer| _ = self.createPrimaryOffer(data_offer.offer),
        .selection => |selection| {
            const offer = if (selection.id) |id| offer: {
                break :offer self.takePrimaryOffer(id) orelse {
                    id.destroy();
                    break :offer null;
                };
            } else null;
            if (self.primary_offer) |old| old.destroy();
            self.primary_offer = offer;
        },
    }
}

fn setNonblocking(fd: posix.fd_t) !void {
    const linux = std.os.linux;
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.FcntlFailed;
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, flags | nonblock)) != .SUCCESS)
        return error.FcntlFailed;
}

fn monotonicMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn sigpipePending() bool {
    const linux = std.os.linux;
    var pending = posix.sigemptyset();
    const rc = linux.syscall2(.rt_sigpending, @intFromPtr(&pending), linux.NSIG / 8);
    return linux.errno(rc) == .SUCCESS and posix.sigismember(&pending, .PIPE);
}

fn writeWithoutSigpipe(fd: posix.fd_t, data: []const u8) usize {
    const linux = std.os.linux;
    var pipe_mask = posix.sigemptyset();
    posix.sigaddset(&pipe_mask, .PIPE);
    var old_mask: posix.sigset_t = undefined;
    posix.sigprocmask(linux.SIG.BLOCK, &pipe_mask, &old_mask);
    const was_pending = sigpipePending();
    const rc = linux.write(fd, data.ptr, data.len);
    // Consume only the signal generated by this failed write, preserving a
    // SIGPIPE that was already pending for the caller.
    if (linux.errno(rc) == .PIPE and !was_pending) {
        const zero: linux.timespec = .{ .sec = 0, .nsec = 0 };
        while (true) {
            const waited = linux.syscall4(
                .rt_sigtimedwait,
                @intFromPtr(&pipe_mask),
                0,
                @intFromPtr(&zero),
                linux.NSIG / 8,
            );
            if (linux.errno(waited) != .INTR) break;
        }
    }
    posix.sigprocmask(linux.SIG.SETMASK, &old_mask, null);
    return rc;
}

test "closed clipboard writer consumes its own SIGPIPE and restores the mask" {
    const linux = std.os.linux;
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    var before: posix.sigset_t = undefined;
    posix.sigprocmask(linux.SIG.BLOCK, null, &before);
    try std.testing.expectEqual(.PIPE, linux.errno(writeWithoutSigpipe(fds[1], "x")));
    try std.testing.expect(!sigpipePending());
    var after: posix.sigset_t = undefined;
    posix.sigprocmask(linux.SIG.BLOCK, null, &after);
    try std.testing.expectEqual(posix.sigismember(&before, .PIPE), posix.sigismember(&after, .PIPE));
}

test "transfer read failure discards partial data" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();

    try clipboard.transfer_buf.appendSlice(std.testing.allocator, "partial");
    const rc = linux.openat(
        linux.AT.FDCWD,
        "/tmp",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true },
        0,
    );
    try std.testing.expectEqual(.SUCCESS, linux.errno(rc));
    clipboard.transfer_fd = @intCast(rc);

    try std.testing.expectError(error.IsDir, clipboard.readTransfer());
    try std.testing.expectEqual(@as(posix.fd_t, -1), clipboard.transfer_fd);
    try std.testing.expectEqual(@as(usize, 0), clipboard.transfer_buf.items.len);
}

test "oversized transfer is aborted before growing past the paste backlog" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();

    try clipboard.transfer_buf.resize(std.testing.allocator, max_transfer_size);
    var pipe_fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true, .NONBLOCK = true })),
    );
    clipboard.transfer_fd = pipe_fds[0];
    _ = linux.write(pipe_fds[1], "x", 1);
    _ = linux.close(pipe_fds[1]);

    try std.testing.expectError(error.TransferTooLarge, clipboard.readTransfer());
    try std.testing.expectEqual(@as(posix.fd_t, -1), clipboard.transfer_fd);
    try std.testing.expectEqual(@as(usize, 0), clipboard.transfer_buf.items.len);
}

test "selection send does not block while the consumer is idle" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    var pipe_fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true, .NONBLOCK = true })),
    );
    defer _ = linux.close(pipe_fds[0]);

    const text = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(text);
    for (text, 0..) |*byte, i| byte.* = @truncate(i);

    clipboard.sendSelection(text, pipe_fds[1]);
    @memset(text, 0); // The transfer retains the selection's original bytes.

    var received: usize = 0;
    var buf: [16 * 1024]u8 = undefined;
    while (clipboard.outgoing_bytes != 0) {
        var polls: [max_outgoing_transfers]posix.pollfd = undefined;
        clipboard.pollOutgoing(&polls);
        _ = try posix.poll(&polls, 0);
        clipboard.dispatchOutgoing(&polls);
        while (posix.read(pipe_fds[0], &buf)) |n| {
            if (n == 0) break;
            for (buf[0..n], received..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i)), byte);
            received += n;
        } else |err| try std.testing.expectEqual(error.WouldBlock, err);
    }
    try std.testing.expectEqual(text.len, received);
}

test "selection writer survives a consumer closing early" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    var pipe_fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })),
    );
    _ = linux.close(pipe_fds[0]);
    clipboard.sendSelection("selection", pipe_fds[1]);
    var polls: [max_outgoing_transfers]posix.pollfd = undefined;
    clipboard.pollOutgoing(&polls);
    _ = try posix.poll(&polls, 0);
    clipboard.dispatchOutgoing(&polls);
    try std.testing.expectEqual(@as(usize, 0), clipboard.outgoing_bytes);
}

test "selection source callbacks honor the requested text encoding" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    const cases = [_]struct { text: [:0]const u8, latin1: ?[]const u8 }{
        .{ .text = "café £ÿ\n", .latin1 = "caf\xe9 \xa3\xff\n" },
        .{ .text = "price: 5€", .latin1 = null },
    };
    for (cases) |case| {
        var source: Source = .{
            .clipboard = &clipboard,
            .text = case.text,
            .latin1 = try clipboard_format.encodeLatin1(std.testing.allocator, case.text),
            .source = undefined,
        };
        defer if (source.latin1) |text| std.testing.allocator.free(text);
        try std.testing.expectEqual(case.latin1 != null, source.supportsMime("STRING"));
        for ([_]Target{ .clipboard, .primary }) |target| {
            for (clipboard_format.paste_mime_preference) |mime| {
                const is_latin1 = std.mem.eql(u8, mime, "STRING");
                if (!is_latin1) try std.testing.expect(source.supportsMime(mime));
                var fds: [2]posix.fd_t = undefined;
                try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })));
                defer _ = linux.close(fds[0]);
                switch (target) {
                    .clipboard => dataSourceListener(undefined, .{ .send = .{ .mime_type = mime, .fd = fds[1] } }, &source),
                    .primary => primarySourceListener(undefined, .{ .send = .{ .mime_type = mime, .fd = fds[1] } }, &source),
                }
                var polls: [max_outgoing_transfers]posix.pollfd = undefined;
                clipboard.pollOutgoing(&polls);
                _ = try posix.poll(&polls, 0);
                clipboard.dispatchOutgoing(&polls);
                var buf: [64]u8 = undefined;
                const n = try posix.read(fds[0], &buf);
                try std.testing.expectEqualStrings(if (is_latin1) case.latin1 orelse "" else case.text, buf[0..n]);
                try std.testing.expectEqual(@as(usize, 0), try posix.read(fds[0], &buf));
                try std.testing.expectEqual(@as(usize, 0), clipboard.outgoing_bytes);
            }
        }
    }
}

test "outgoing limits, timeout, and teardown close transfers" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);

    var readers: [max_outgoing_transfers + 1]posix.fd_t = undefined;
    for (0..max_outgoing_transfers + 1) |i| {
        var fds: [2]posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
        readers[i] = fds[0];
        clipboard.sendSelection("x", fds[1]);
    }
    // The ninth writer was rejected and its reader observes EOF.
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try posix.read(readers[max_outgoing_transfers], &byte));
    _ = linux.close(readers[max_outgoing_transfers]);

    clipboard.outgoing[0].?.deadline_ms = monotonicMs() - 1;
    try std.testing.expect(!clipboard.expireTransfers());
    try std.testing.expect(clipboard.outgoing[0] == null);
    for (readers[0..max_outgoing_transfers]) |fd| _ = linux.close(fd);
    clipboard.deinit();
}

test "incoming deadline preserves OSC 52 kind until expiry" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    defer _ = linux.close(fds[1]);
    clipboard.transfer_fd = fds[0];
    clipboard.transfer_action = .{ .osc52_read = .{ .tab_id = 1, .kind = 'c' } };
    clipboard.transfer_deadline_ms = monotonicMs() - 1;
    try std.testing.expectEqual(@as(?u8, 'c'), clipboard.osc52Read().?.kind);
    try std.testing.expectEqual(@as(i32, 0), clipboard.pollTimeoutMs());
    try std.testing.expect(clipboard.expireTransfers());
    try std.testing.expect(clipboard.osc52Read() == null);
}

test "drag negotiation prefers a supported source action" {
    const move_only = dndActions(.{ .move = true });
    try std.testing.expect(!move_only.allowed.copy);
    try std.testing.expect(move_only.allowed.move);
    try std.testing.expect(!move_only.preferred.copy);
    try std.testing.expect(move_only.preferred.move);

    const copy_and_move = dndActions(.{ .copy = true, .move = true });
    try std.testing.expect(copy_and_move.allowed.copy);
    try std.testing.expect(copy_and_move.allowed.move);
    try std.testing.expect(copy_and_move.preferred.copy);
    try std.testing.expect(!copy_and_move.preferred.move);
}

test "drag acceptance never sends an unsupported Wayland preferred action" {
    const linux = std.os.linux;
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &fds,
    )));
    defer _ = linux.close(fds[1]);
    const display = try wl.Display.connectToFd(fds[0]);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();
    // Create a real client proxy, but inspect requests ourselves instead of
    // running a compositor. No server replies are needed to marshal requests.
    const proxy = try registry.bind(1, wl.DataOffer, 3);
    defer proxy.destroy();
    try std.testing.expectEqual(.SUCCESS, display.flush());
    var buf: [512]u8 align(4) = undefined;
    _ = try posix.read(fds[1], &buf); // Discard registry construction requests.

    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    var offer: DataOffer = .{ .clipboard = &clipboard, .offer = proxy, .enter_serial = 17 };
    offer.noteMime("text/plain");
    clipboard.dnd_offer = &offer;
    defer clipboard.dnd_offer = null;

    // Source mask, application choice, expected preference. Include a stale
    // move choice after a source switches to copy-only, and the reverse.
    inline for (.{
        .{ @as(u32, 1), .move, @as(u32, 0) },
        .{ @as(u32, 2), .copy, @as(u32, 0) },
        .{ @as(u32, 3), .move, @as(u32, 2) },
        .{ @as(u32, 1), .copy, @as(u32, 1) },
        .{ @as(u32, 3), .none, @as(u32, 0) },
        .{ @as(u32, 0), .copy, @as(u32, 0) },
    }) |case| {
        offer.source_actions = @bitCast(case[0]);
        clipboard.setDndAcceptance(case[1]);
        try std.testing.expectEqual(.SUCCESS, display.flush());
        const n = try posix.read(fds[1], &buf);
        const words = std.mem.bytesAsSlice(u32, buf[0..n]);
        const accept_size = words[1] >> 16;
        try std.testing.expectEqual(proxy.getId(), words[0]);
        try std.testing.expectEqual(@as(u32, 0), words[1] & 0xffff); // accept
        try std.testing.expectEqual(@as(u32, 17), words[2]);
        if (case[2] == 0) {
            try std.testing.expectEqual(@as(u32, 0), words[3]); // Null MIME rejects the drop.
        } else {
            try std.testing.expectEqualStrings("text/plain\x00", buf[16..][0..words[3]]);
        }
        const actions = words[accept_size / 4 ..];
        try std.testing.expectEqual(@as(usize, 4), actions.len);
        try std.testing.expectEqual(proxy.getId(), actions[0]);
        try std.testing.expectEqual(@as(u32, (16 << 16) | 4), actions[1]); // set_actions
        try std.testing.expectEqual(case[0], actions[2]);
        try std.testing.expectEqual(case[2], actions[3]);
    }
}

test "drag source serves requested data asynchronously" {
    const Capture = struct {
        request: ?DndSourceEvent = null,

        fn callback(ctx: *anyopaque, event: DndEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .source => |source| self.request = source,
                else => {},
            }
            return true;
        }
    };
    const linux = std.os.linux;
    const alloc = std.testing.allocator;
    var clipboard: Clipboard = .init(alloc, null, null);
    defer clipboard.deinit();
    var capture: Capture = .{};
    clipboard.setDndCallback(&capture, Capture.callback);
    const name = try alloc.dupeZ(u8, "text/uri-list");
    defer alloc.free(name);
    const mimes = try alloc.alloc(DndSource.Mime, 1);
    defer alloc.free(mimes);
    mimes[0] = .{ .name = name, .data = null };
    var source: DndSource = .{
        .clipboard = &clipboard,
        .tab_id = 77,
        .source = undefined,
        .mimes = mimes,
    };
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &fds,
    )));
    defer _ = linux.close(fds[0]);

    source.send(name.ptr, fds[1]);
    const data_request = capture.request.?.data_request;
    try std.testing.expectEqual(@as(u64, 77), data_request.tab_id);
    try std.testing.expectEqual(@as(usize, 0), data_request.index);
    source.fulfill(0, "file:///tmp/a\r\n");
    var polls: [max_outgoing_transfers]posix.pollfd = undefined;
    clipboard.pollOutgoing(&polls);
    _ = try posix.poll(&polls, 0);
    clipboard.dispatchOutgoing(&polls);
    var buf: [64]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("file:///tmp/a\r\n", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), clipboard.outgoing_bytes);

    var stalled: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &stalled,
    )));
    defer _ = linux.close(stalled[0]);
    source.send(name.ptr, stalled[1]);
    for (&source.pending) |*pending| {
        if (pending.*) |*item| item.deadline_ms = monotonicMs() - 1;
    }
    clipboard.dnd_source = &source;
    try std.testing.expect(!clipboard.expireTransfers());
    clipboard.dnd_source = null;
    try std.testing.expectEqual(@as(usize, 0), try posix.read(stalled[0], &buf));
}

test "drag source marshals MIME actions and original serial" {
    const linux = std.os.linux;
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &fds,
    )));
    defer _ = linux.close(fds[1]);
    const display = try wl.Display.connectToFd(fds[0]);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();
    const manager = try registry.bind(1, wl.DataDeviceManager, 3);
    defer manager.destroy();
    const device = try registry.bind(2, wl.DataDevice, 3);
    defer device.destroy();
    const surface = try registry.bind(3, wl.Surface, 1);
    defer surface.destroy();
    try std.testing.expectEqual(.SUCCESS, display.flush());
    var buf: [1024]u8 align(4) = undefined;
    _ = try posix.read(fds[1], &buf);

    var clipboard: Clipboard = .init(std.testing.allocator, manager, null);
    defer clipboard.deinit();
    clipboard.setDevices(device, null);
    try std.testing.expect(clipboard.startDnd(42, 1234, surface, null, .{ .copy = true, .move = true }, &.{
        .{ .mime = "text/uri-list", .data = "file:///tmp/a\r\n" },
        .{ .mime = "text/plain", .data = null },
    }));
    const source = clipboard.dnd_source.?.source;
    try std.testing.expectEqual(.SUCCESS, display.flush());
    const n = try posix.read(fds[1], &buf);
    const words = std.mem.bytesAsSlice(u32, buf[0..n]);
    var offset: usize = 0;
    var offers: usize = 0;
    var saw_actions = false;
    var saw_start = false;
    while (offset < words.len) {
        const object_id = words[offset];
        const header = words[offset + 1];
        const opcode = header & 0xffff;
        const size = header >> 16;
        const message = words[offset .. offset + size / 4];
        if (object_id == source.getId() and opcode == 0) offers += 1;
        if (object_id == source.getId() and opcode == 2) {
            try std.testing.expectEqual(@as(u32, 3), message[2]);
            saw_actions = true;
        }
        if (object_id == device.getId() and opcode == 0) {
            try std.testing.expectEqual(source.getId(), message[2]);
            try std.testing.expectEqual(surface.getId(), message[3]);
            try std.testing.expectEqual(@as(u32, 0), message[4]);
            try std.testing.expectEqual(@as(u32, 1234), message[5]);
            saw_start = true;
        }
        offset += size / 4;
    }
    try std.testing.expectEqual(@as(usize, 2), offers);
    try std.testing.expect(saw_actions);
    try std.testing.expect(saw_start);
}
