const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub const PathOverrides = struct {
    home_dir: ?[]const u8 = null,
    app_config_root: ?[]const u8 = null,
};

pub fn resolvePlatformPaths(
    arena: Allocator,
    environ_map: *const std.process.Environ.Map,
    overrides: PathOverrides,
) !types.PlatformPaths {
    const is_win = builtin.os.tag == .windows;
    const is_mac = builtin.os.tag == .macos;

    const home_raw = overrides.home_dir orelse
        environ_map.get("SYNCIDE_HOME") orelse
        (if (is_win) environ_map.get("USERPROFILE") else environ_map.get("HOME")) orelse
        return error.HomeDirectoryNotFound;

    const home_dir = try trimTrailingSepAlloc(arena, home_raw);

    const app_raw: []const u8 = if (overrides.app_config_root) |custom|
        try arena.dupe(u8, custom)
    else if (environ_map.get("SYNCIDE_APPDATA")) |env_override|
        try arena.dupe(u8, env_override)
    else if (is_win) blk: {
        if (environ_map.get("APPDATA")) |appdata| {
            break :blk try arena.dupe(u8, appdata);
        }
        break :blk try Dir.path.join(arena, &.{ home_dir, "AppData", "Roaming" });
    } else if (is_mac)
        try Dir.path.join(arena, &.{ home_dir, "Library", "Application Support" })
    else blk: {
        if (environ_map.get("XDG_CONFIG_HOME")) |xdg| {
            if (std.mem.trim(u8, xdg, " \t\r\n").len > 0) {
                break :blk try arena.dupe(u8, xdg);
            }
        }
        break :blk try Dir.path.join(arena, &.{ home_dir, ".config" });
    };

    const app_config_root = try trimTrailingSepAlloc(arena, app_raw);
    const default_store_dir = try Dir.path.join(arena, &.{ app_config_root, "syncide" });
    const bootstrap_state_path = try Dir.path.join(arena, &.{ default_store_dir, "state.json" });

    return .{
        .home_dir = home_dir,
        .app_config_root = app_config_root,
        .default_store_dir = default_store_dir,
        .bootstrap_state_path = bootstrap_state_path,
    };
}

pub fn getStorePaths(arena: Allocator, store_dir_raw: []const u8) !types.StorePaths {
    const store_dir = try trimTrailingSepAlloc(arena, store_dir_raw);
    const user_dir = try Dir.path.join(arena, &.{ store_dir, "User" });
    return .{
        .store_dir = store_dir,
        .user_dir = user_dir,
        .settings_path = try Dir.path.join(arena, &.{ user_dir, "settings.json" }),
        .keybindings_path = try Dir.path.join(arena, &.{ user_dir, "keybindings.json" }),
        .extensions_dir = try Dir.path.join(arena, &.{ store_dir, "extensions" }),
        .state_path = try Dir.path.join(arena, &.{ store_dir, "state.json" }),
    };
}

pub fn resolveUserInputPath(arena: Allocator, io: Io, raw_path: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n\"'");
    if (Dir.path.isAbsolute(trimmed)) {
        return Dir.path.resolve(arena, &.{trimmed});
    }
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    return Dir.path.resolve(arena, &.{ cwd_path, trimmed });
}

pub fn trimTrailingSepAlloc(arena: Allocator, p: []const u8) ![]const u8 {
    var end = p.len;
    while (end > 1 and (p[end - 1] == '/' or p[end - 1] == '\\')) {
        if (end == 3 and p[1] == ':') {
            break;
        }
        end -= 1;
    }
    return arena.dupe(u8, p[0..end]);
}

pub fn stripWinPrefix(p: []const u8) []const u8 {
    if (std.mem.startsWith(u8, p, "\\??\\") or std.mem.startsWith(u8, p, "\\\\?\\")) {
        return p[4..];
    }
    return p;
}

/// Compares two resolved paths accounting for separator style and OS case-insensitivity.
pub fn pathsEqual(a_raw: []const u8, b_raw: []const u8) bool {
    const is_case_insensitive = builtin.os.tag == .windows or builtin.os.tag == .macos;
    const a = std.mem.trimEnd(u8, stripWinPrefix(a_raw), "/\\");
    const b = std.mem.trimEnd(u8, stripWinPrefix(b_raw), "/\\");
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |ca, cb| {
        const na: u8 = if (ca == '\\') '/' else if (is_case_insensitive) std.ascii.toLower(ca) else ca;
        const nb: u8 = if (cb == '\\') '/' else if (is_case_insensitive) std.ascii.toLower(cb) else cb;
        if (na != nb) {
            return false;
        }
    }
    return true;
}

/// Converts a filesystem path into VS Code's URI.file().path format (e.g. "/c:/Users/foo/bar").
pub fn toVsCodeUriPath(arena: Allocator, fs_path: []const u8) ![]const u8 {
    const clean = stripWinPrefix(fs_path);
    var out: std.ArrayList(u8) = .empty;
    if (clean.len >= 2 and std.ascii.isAlphabetic(clean[0]) and clean[1] == ':') {
        try out.append(arena, '/');
        try out.append(arena, std.ascii.toLower(clean[0]));
        try out.append(arena, ':');
        for (clean[2..]) |c| {
            try out.append(arena, if (c == '\\') '/' else c);
        }
        return out.toOwnedSlice(arena);
    }

    if (clean.len == 0 or (clean[0] != '/' and clean[0] != '\\')) {
        try out.append(arena, '/');
    }
    for (clean) |c| {
        try out.append(arena, if (c == '\\') '/' else c);
    }
    return out.toOwnedSlice(arena);
}

pub fn formatBytesBuf(bytes: u64, buf: []u8) []const u8 {
    if (bytes == 0) {
        return "0 B";
    }
    const units = [_][]const u8{ "B", "KB", "MB", "GB" };
    var val: f64 = @floatFromInt(bytes);
    var idx: usize = 0;
    while (val >= 1024.0 and idx + 1 < units.len) : (idx += 1) {
        val /= 1024.0;
    }
    if (idx == 0) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "? B";
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ val, units[idx] }) catch "? B";
}
