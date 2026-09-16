//! Automatic shell integration.
//!
//! Monstar mirrors kitty by making supported shells report their working
//! directory (OSC 7) and window title (OSC 2) as events instead of polling
//! `/proc`: the directory while sitting at a prompt and the running command
//! line while one executes. This module detects the configured shell and
//! injects the scripts under `share/monstar/shell-integration` using each
//! shell's own startup mechanism. When no OSC 2 title is available, the tab
//! bar falls back to the PTY foreground process-group leader.
//!
//! Bash starts in POSIX mode and sources the script through `ENV`; zsh loads
//! it through `ZDOTDIR`; fish, nushell, and elvish discover it through
//! `XDG_DATA_DIRS`. Unsupported shells are left untouched and use the same
//! foreground-process fallback.

const std = @import("std");

const log = std.log.scoped(.shell_integration);

pub const Shell = enum { bash, elvish, fish, nushell, zsh };

/// The session command, matching what the child receives.
pub const Command = struct {
    path: [*:0]const u8,
    argv: [:null]const ?[*:0]const u8,
};

pub const Result = struct {
    shell: Shell,
    command: Command,
};

/// Detect and configure the shell in `command`, mutating `env` with the
/// injection variables and returning the (possibly rewritten) command.
/// Returns null when the shell is unsupported or its scripts are missing.
pub fn setup(
    arena: std.mem.Allocator,
    io: std.Io,
    resources_dir: []const u8,
    command: Command,
    env: *std.process.Environ.Map,
) !?Result {
    const shell = detectShell(command) orelse return null;
    const integ_dir = try std.fs.path.join(arena, &.{ resources_dir, "shell-integration" });

    const new_command: Command = switch (shell) {
        .bash => (try setupBash(arena, io, command, integ_dir, env)) orelse return null,
        .zsh => (try setupZsh(arena, io, command, integ_dir, env)) orelse return null,
        .fish => (try setupFish(arena, io, command, integ_dir, env)) orelse return null,
        .elvish => (try setupElvish(arena, io, command, integ_dir, env)) orelse return null,
        .nushell => (try setupNushell(arena, io, command, integ_dir, env)) orelse return null,
    };
    log.debug("enabled {s} shell integration", .{@tagName(shell)});
    return .{ .shell = shell, .command = new_command };
}

fn detectShell(command: Command) ?Shell {
    return detectShellPath(std.mem.span(command.path));
}

/// Identify a supported shell from an executable path or bare command name.
pub fn detectShellPath(path: []const u8) ?Shell {
    const exe = std.fs.path.basename(path);
    if (std.mem.eql(u8, exe, "bash")) return .bash;
    if (std.mem.eql(u8, exe, "elvish")) return .elvish;
    if (std.mem.eql(u8, exe, "fish")) return .fish;
    if (std.mem.eql(u8, exe, "nu")) return .nushell;
    if (std.mem.eql(u8, exe, "zsh")) return .zsh;
    return null;
}

/// Locate `share/monstar` from the environment or next to the executable,
/// mirroring how themes are resolved.
pub fn resourcesDir(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
) ?[]const u8 {
    if (environ.getPosix("MONSTAR_RESOURCES_DIR")) |dir| return dir;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.process.executableDirPath(io, &buf) catch return null;
    return std.fs.path.join(arena, &.{ buf[0..len], "..", "share", "monstar" }) catch null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Prepend the integration directory to XDG_DATA_DIRS and remember it so the
/// shell script can remove it once loaded.
fn setupXdgDataDirs(
    arena: std.mem.Allocator,
    integ_dir: []const u8,
    env: *std.process.Environ.Map,
) !void {
    try env.put("MONSTAR_SHELL_INTEGRATION_XDG_DIR", integ_dir);
    const current = env.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    const new = try std.fmt.allocPrint(arena, "{s}:{s}", .{ integ_dir, current });
    try env.put("XDG_DATA_DIRS", new);
}

/// Bash cannot be injected through a startup file, so it is started in POSIX
/// mode and the `ENV` variable points at our script. The script then restores
/// the normal startup sequence.
fn setupBash(
    arena: std.mem.Allocator,
    io: std.Io,
    command: Command,
    integ_dir: []const u8,
    env: *std.process.Environ.Map,
) !?Command {
    const script = try std.fs.path.join(arena, &.{ integ_dir, "bash", "monstar.bash" });
    if (!fileExists(io, script)) return null;

    var args: std.ArrayList(?[*:0]const u8) = .empty;
    try args.append(arena, command.argv[0] orelse return null);
    try args.append(arena, "--posix");

    // Flags the script must replay when it rebuilds the startup sequence.
    var inject: std.ArrayList(u8) = .empty;
    try inject.appendSlice(arena, "1");
    var rcfile: ?[]const u8 = null;

    var i: usize = 1;
    while (command.argv[i]) |arg_z| : (i += 1) {
        const arg = std.mem.span(arg_z);
        if (std.mem.eql(u8, arg, "--posix")) return null;
        if (std.mem.eql(u8, arg, "--norc")) {
            try inject.appendSlice(arena, " --norc");
            continue;
        }
        if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.appendSlice(arena, " --noprofile");
            continue;
        }
        if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            i += 1;
            rcfile = if (command.argv[i]) |v| std.mem.span(v) else null;
            continue;
        }
        if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // `-c` (and friends) run non-interactively: no prompt to hook.
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) return null;
            try args.append(arena, arg_z);
            continue;
        }
        if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            try args.append(arena, arg_z);
            i += 1;
            while (command.argv[i]) |rest| : (i += 1) try args.append(arena, rest);
            break;
        }
        try args.append(arena, arg_z);
    }

    if (env.get("ENV")) |old| try env.put("MONSTAR_BASH_ENV", old);
    try env.put("ENV", script);
    try env.put("MONSTAR_BASH_INJECT", inject.items);
    if (rcfile) |value| try env.put("MONSTAR_BASH_RCFILE", value);

    // POSIX mode defaults HISTFILE to ~/.sh_history; keep bash's normal file.
    if (env.get("HISTFILE") == null) {
        if (env.get("HOME")) |home| {
            const histfile = try std.fs.path.join(arena, &.{ home, ".bash_history" });
            try env.put("HISTFILE", histfile);
            try env.put("MONSTAR_BASH_UNEXPORT_HISTFILE", "1");
        }
    }

    return .{
        .path = command.path,
        .argv = try args.toOwnedSliceSentinel(arena, null),
    };
}

/// Zsh loads `<ZDOTDIR>/.zshenv`, so point ZDOTDIR at our directory and let
/// the script restore the user's value and source their real `.zshenv`.
fn setupZsh(
    arena: std.mem.Allocator,
    io: std.Io,
    command: Command,
    integ_dir: []const u8,
    env: *std.process.Environ.Map,
) !?Command {
    const dir = try std.fs.path.join(arena, &.{ integ_dir, "zsh" });
    if (!dirExists(io, dir)) return null;
    const zshenv = try std.fs.path.join(arena, &.{ dir, ".zshenv" });
    if (!fileExists(io, zshenv)) return null;

    if (env.get("ZDOTDIR")) |old| try env.put("MONSTAR_ZDOTDIR", old);
    try env.put("ZDOTDIR", dir);
    return command;
}

fn setupFish(
    arena: std.mem.Allocator,
    io: std.Io,
    command: Command,
    integ_dir: []const u8,
    env: *std.process.Environ.Map,
) !?Command {
    const conf = try std.fs.path.join(arena, &.{ integ_dir, "fish", "vendor_conf.d", "monstar.fish" });
    if (!fileExists(io, conf)) return null;
    try setupXdgDataDirs(arena, integ_dir, env);
    return command;
}

fn setupElvish(
    arena: std.mem.Allocator,
    io: std.Io,
    command: Command,
    integ_dir: []const u8,
    env: *std.process.Environ.Map,
) !?Command {
    const module = try std.fs.path.join(arena, &.{ integ_dir, "elvish", "lib", "monstar-integration.elv" });
    if (!fileExists(io, module)) return null;
    try setupXdgDataDirs(arena, integ_dir, env);
    return command;
}

fn setupNushell(
    arena: std.mem.Allocator,
    io: std.Io,
    command: Command,
    integ_dir: []const u8,
    env: *std.process.Environ.Map,
) !?Command {
    const module = try std.fs.path.join(arena, &.{ integ_dir, "nushell", "vendor", "autoload", "monstar.nu" });
    if (!fileExists(io, module)) return null;
    try setupXdgDataDirs(arena, integ_dir, env);

    var args: std.ArrayList(?[*:0]const u8) = .empty;
    try args.append(arena, command.argv[0] orelse return null);
    try args.append(arena, "--execute");
    try args.append(arena, "try { use monstar * }");
    var i: usize = 1;
    while (command.argv[i]) |arg| : (i += 1) {
        const text = std.mem.span(arg);
        if (std.mem.eql(u8, text, "--command") or std.mem.eql(u8, text, "--lsp")) return null;
        if (text.len > 1 and text[0] == '-' and text[1] != '-') {
            if (std.mem.indexOfScalar(u8, text, 'c') != null) return null;
        }
        try args.append(arena, arg);
    }
    return .{
        .path = command.path,
        .argv = try args.toOwnedSliceSentinel(arena, null),
    };
}

test "detectShell matches supported basenames only" {
    const mk = struct {
        fn f(comptime path: [:0]const u8) Command {
            return .{ .path = path, .argv = undefined };
        }
    }.f;

    try std.testing.expectEqual(Shell.bash, detectShell(mk("/usr/bin/bash")).?);
    try std.testing.expectEqual(Shell.zsh, detectShell(mk("/bin/zsh")).?);
    try std.testing.expectEqual(Shell.fish, detectShell(mk("fish")).?);
    try std.testing.expectEqual(Shell.nushell, detectShell(mk("/usr/bin/nu")).?);
    try std.testing.expectEqual(Shell.elvish, detectShell(mk("/usr/bin/elvish")).?);
    try std.testing.expect(detectShell(mk("/bin/sh")) == null);
    try std.testing.expect(detectShell(mk("/bin/dash")) == null);
}

test "detectShellPath matches a supported command word" {
    try std.testing.expectEqual(Shell.bash, detectShellPath("bash").?);
    try std.testing.expectEqual(Shell.zsh, detectShellPath("/usr/bin/zsh").?);
    try std.testing.expect(detectShellPath("bash-custom") == null);
}

test "bash injection adds posix mode and records startup flags" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bash");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bash/monstar.bash", .data = "" });
    const integ_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    var env = std.process.Environ.Map.init(arena);
    var argv = [_:null]?[*:0]const u8{ "bash", "--norc", "-i" };
    const result = (try setupBash(arena, std.testing.io, .{
        .path = "bash",
        .argv = &argv,
    }, integ_dir, &env)).?;

    try std.testing.expectEqualStrings("bash", std.mem.span(result.argv[0].?));
    try std.testing.expectEqualStrings("--posix", std.mem.span(result.argv[1].?));
    try std.testing.expectEqualStrings("1 --norc", env.get("MONSTAR_BASH_INJECT").?);
    try std.testing.expect(env.get("ENV") != null);
}

test "bash injection bails out for non-interactive -c" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bash");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bash/monstar.bash", .data = "" });
    const integ_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    var env = std.process.Environ.Map.init(arena);
    var argv = [_:null]?[*:0]const u8{ "bash", "-c", "true" };
    try std.testing.expect(try setupBash(arena, std.testing.io, .{
        .path = "bash",
        .argv = &argv,
    }, integ_dir, &env) == null);
}

test "fish injection prepends XDG_DATA_DIRS" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "fish/vendor_conf.d");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fish/vendor_conf.d/monstar.fish", .data = "" });
    const integ_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    var env = std.process.Environ.Map.init(arena);
    try env.put("XDG_DATA_DIRS", "/opt/share");
    _ = (try setupFish(arena, std.testing.io, .{
        .path = "fish",
        .argv = undefined,
    }, integ_dir, &env)).?;

    const expected = try std.fmt.allocPrint(arena, "{s}:/opt/share", .{integ_dir});
    try std.testing.expectEqualStrings(expected, env.get("XDG_DATA_DIRS").?);
    try std.testing.expectEqualStrings(integ_dir, env.get("MONSTAR_SHELL_INTEGRATION_XDG_DIR").?);
}
