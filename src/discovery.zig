const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub const KNOWN_IDES = [_]types.IdeSpec{
    .{ .id = "code", .name = "VS Code", .config_dir_name = "Code", .dot_dir_name = ".vscode", .cli_names = &.{"code"} },
    .{ .id = "code-insiders", .name = "VS Code Insiders", .config_dir_name = "Code - Insiders", .dot_dir_name = ".vscode-insiders", .cli_names = &.{"code-insiders"} },
    .{ .id = "code-oss", .name = "Code - OSS", .config_dir_name = "Code - OSS", .dot_dir_name = ".vscode-oss", .cli_names = &.{"code-oss"} },
    .{ .id = "vscodium", .name = "VSCodium", .config_dir_name = "VSCodium", .dot_dir_name = ".vscode-oss", .cli_names = &.{"codium"} },
    .{ .id = "vscodium-insiders", .name = "VSCodium Insiders", .config_dir_name = "VSCodium - Insiders", .dot_dir_name = ".vscodium-insiders", .cli_names = &.{"codium-insiders"} },
    .{ .id = "cursor", .name = "Cursor", .config_dir_name = "Cursor", .dot_dir_name = ".cursor", .cli_names = &.{"cursor"} },
    .{ .id = "windsurf", .name = "Windsurf", .config_dir_name = "Windsurf", .dot_dir_name = ".windsurf", .cli_names = &.{"windsurf"} },
    .{ .id = "windsurf-next", .name = "Windsurf Next", .config_dir_name = "Windsurf - Next", .dot_dir_name = ".windsurf-next", .cli_names = &.{"windsurf-next"} },
    .{ .id = "antigravity", .name = "Antigravity", .config_dir_name = "Antigravity", .dot_dir_name = ".antigravity", .cli_names = &.{ "agy", "antigravity" } },
    .{ .id = "antigravity-ide", .name = "Antigravity IDE", .config_dir_name = "Antigravity IDE", .dot_dir_name = ".antigravity-ide", .cli_names = &.{ "antigravity-ide", "agy" } },
    .{ .id = "trae", .name = "Trae", .config_dir_name = "Trae", .dot_dir_name = ".trae", .cli_names = &.{"trae"} },
    .{ .id = "trae-cn", .name = "Trae CN", .config_dir_name = "Trae CN", .dot_dir_name = ".trae-cn", .cli_names = &.{"trae-cn"} },
    .{ .id = "positron", .name = "Positron", .config_dir_name = "Positron", .dot_dir_name = ".positron", .cli_names = &.{"positron"} },
    .{ .id = "void", .name = "Void", .config_dir_name = "Void", .dot_dir_name = ".void-editor", .cli_names = &.{"void"} },
    .{ .id = "pearai", .name = "PearAI", .config_dir_name = "PearAI", .dot_dir_name = ".pearai", .cli_names = &.{"pearai"} },
    .{ .id = "kiro", .name = "Kiro", .config_dir_name = "Kiro", .dot_dir_name = ".kiro", .cli_names = &.{"kiro"} },
    .{ .id = "qoder", .name = "Qoder", .config_dir_name = "Qoder", .dot_dir_name = ".qoder", .cli_names = &.{"qoder"} },
    .{ .id = "aide", .name = "Aide", .config_dir_name = "Aide", .dot_dir_name = ".aide", .cli_names = &.{"aide"} },
};

const USER_MARKERS = [_][]const u8{
    "settings.json",
    "keybindings.json",
    "globalStorage",
    "workspaceStorage",
    "snippets",
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) {
        return false;
    }
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (suffix.len > s.len) {
        return false;
    }
    return std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

pub fn isIgnoredAppConfigDir(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "syncide") or
        std.ascii.eqlIgnoreCase(name, "temp") or
        std.ascii.eqlIgnoreCase(name, "tmp") or
        std.ascii.eqlIgnoreCase(name, "bak"))
    {
        return true;
    }
    if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[0..3], "bak") and
        (std.ascii.isUpper(name[3]) or name[3] == '_' or name[3] == '-'))
    {
        return true;
    }
    if (containsIgnoreCase(name, "_backup") or
        containsIgnoreCase(name, "-backup") or
        containsIgnoreCase(name, ".bak") or
        endsWithIgnoreCase(name, "_old") or
        endsWithIgnoreCase(name, "-old"))
    {
        return true;
    }
    return false;
}

fn pathExists(io: Io, abs_path: []const u8) bool {
    Dir.accessAbsolute(io, abs_path, .{}) catch return false;
    return true;
}

fn safeFileInfo(io: Io, abs_path: []const u8) struct { exists: bool, size: u64 } {
    const st = Dir.cwd().statFile(io, abs_path, .{ .follow_symlinks = true }) catch {
        return .{ .exists = false, .size = 0 };
    };
    if (st.kind == .file) {
        return .{ .exists = true, .size = st.size };
    }
    return .{ .exists = false, .size = 0 };
}

pub fn countExtensionsInDir(arena: Allocator, io: Io, extensions_dir: []const u8) usize {
    var dir = Dir.openDirAbsolute(io, extensions_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') {
            continue;
        }
        if (entry.kind == .directory or entry.kind == .sym_link) {
            const pkg_path = Dir.path.join(arena, &.{ extensions_dir, entry.name, "package.json" }) catch continue;
            if (pathExists(io, pkg_path)) {
                count += 1;
            }
        }
    }
    return count;
}

fn looksLikeVsCodeUserDir(arena: Allocator, io: Io, user_dir: []const u8) bool {
    var d = Dir.openDirAbsolute(io, user_dir, .{}) catch return false;
    d.close(io);

    for (USER_MARKERS) |marker| {
        const p = Dir.path.join(arena, &.{ user_dir, marker }) catch continue;
        if (pathExists(io, p)) {
            return true;
        }
    }
    return false;
}

const PackageEngines = struct {
    engines: ?struct {
        vscode: ?[]const u8 = null,
    } = null,
};

fn looksLikeVsCodeExtensionsDir(arena: Allocator, io: Io, extensions_dir: []const u8) bool {
    var dir = Dir.openDirAbsolute(io, extensions_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io);

    const manifest_path = Dir.path.join(arena, &.{ extensions_dir, "extensions.json" }) catch return false;
    if (pathExists(io, manifest_path)) {
        return true;
    }

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '.') {
            continue;
        }
        const pkg_path = Dir.path.join(arena, &.{ extensions_dir, entry.name, "package.json" }) catch continue;
        const raw = Dir.cwd().readFileAlloc(io, pkg_path, arena, .limited(256 * 1024)) catch continue;
        const parsed = std.json.parseFromSlice(PackageEngines, arena, raw, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();
        if (parsed.value.engines) |eng| {
            if (eng.vscode != null) {
                return true;
            }
        }
    }
    return false;
}

fn slugifyAlloc(arena: Allocator, input: []const u8, sep: ?u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_sep = true;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(arena, std.ascii.toLower(c));
            prev_sep = false;
        } else if (sep) |s| {
            if (!prev_sep) {
                try out.append(arena, s);
                prev_sep = true;
            }
        }
    }
    while (out.items.len > 0 and sep != null and out.items[out.items.len - 1] == sep.?) {
        _ = out.pop();
    }
    return out.toOwnedSlice(arena);
}

fn resolveHeuristicDotDir(arena: Allocator, io: Io, home_dir: []const u8, dir_name: []const u8) ![]const u8 {
    const hyphen = try slugifyAlloc(arena, dir_name, '-');
    const compact = try slugifyAlloc(arena, dir_name, null);

    const cand1 = try std.fmt.allocPrint(arena, ".{s}", .{hyphen});
    const cand2 = try std.fmt.allocPrint(arena, ".{s}", .{compact});
    const cand3 = try std.fmt.allocPrint(arena, ".{s}-editor", .{hyphen});
    const candidates = [_][]const u8{ cand1, cand2, cand3 };

    for (candidates) |cand| {
        const ext_dir = try Dir.path.join(arena, &.{ home_dir, cand, "extensions" });
        if (looksLikeVsCodeExtensionsDir(arena, io, ext_dir)) {
            return cand;
        }
    }
    for (candidates) |cand| {
        const d_path = try Dir.path.join(arena, &.{ home_dir, cand });
        if (pathExists(io, d_path)) {
            return cand;
        }
    }
    return cand1;
}

fn buildInstallation(arena: Allocator, io: Io, p: types.PlatformPaths, spec: types.IdeSpec) !?types.IdeInstallation {
    const app_dir = try Dir.path.join(arena, &.{ p.app_config_root, spec.config_dir_name });
    const user_dir = try Dir.path.join(arena, &.{ app_dir, "User" });
    const dot_dir = try Dir.path.join(arena, &.{ p.home_dir, spec.dot_dir_name });
    const extensions_dir = try Dir.path.join(arena, &.{ dot_dir, "extensions" });

    const has_user = looksLikeVsCodeUserDir(arena, io, user_dir);
    const has_ext = looksLikeVsCodeExtensionsDir(arena, io, extensions_dir);
    if (!has_user and !has_ext) {
        return null;
    }

    const settings_path = try Dir.path.join(arena, &.{ user_dir, "settings.json" });
    const keybindings_path = try Dir.path.join(arena, &.{ user_dir, "keybindings.json" });
    const set_info = safeFileInfo(io, settings_path);
    const key_info = safeFileInfo(io, keybindings_path);

    return .{
        .id = spec.id,
        .name = spec.name,
        .app_dir = app_dir,
        .user_dir = user_dir,
        .settings_path = settings_path,
        .keybindings_path = keybindings_path,
        .dot_dir = dot_dir,
        .extensions_dir = extensions_dir,
        .cli_names = spec.cli_names,
        .has_settings = set_info.exists,
        .settings_size = set_info.size,
        .has_keybindings = key_info.exists,
        .keybindings_size = key_info.size,
        .extensions_count = countExtensionsInDir(arena, io, extensions_dir),
    };
}

pub fn discoverIdes(arena: Allocator, io: Io, p: types.PlatformPaths) ![]types.IdeInstallation {
    var list: std.ArrayList(types.IdeInstallation) = .empty;

    for (KNOWN_IDES) |spec| {
        if (try buildInstallation(arena, io, p, spec)) |inst| {
            try list.append(arena, inst);
        }
    }

    // Heuristic discovery for unknown VS Code forks inside AppData / ~/.config
    if (Dir.openDirAbsolute(io, p.app_config_root, .{ .iterate = true })) |app_dir_val| {
        var app_dir = app_dir_val;
        defer app_dir.close(io);

        var it = app_dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) {
                continue;
            }
            const dir_name = entry.name;
            if (isIgnoredAppConfigDir(dir_name)) {
                continue;
            }

            var already_known = false;
            for (KNOWN_IDES) |known| {
                if (std.ascii.eqlIgnoreCase(known.config_dir_name, dir_name)) {
                    already_known = true;
                    break;
                }
            }
            if (already_known) {
                continue;
            }

            const user_dir = try Dir.path.join(arena, &.{ p.app_config_root, dir_name, "User" });
            if (!looksLikeVsCodeUserDir(arena, io, user_dir)) {
                continue;
            }

            const owned_name = try arena.dupe(u8, dir_name);
            const slug = try slugifyAlloc(arena, owned_name, '-');
            const id = if (slug.len > 0) slug else owned_name;
            const dot_dir_name = try resolveHeuristicDotDir(arena, io, p.home_dir, owned_name);
            const clis = try arena.alloc([]const u8, 1);
            clis[0] = id;

            const custom_spec: types.IdeSpec = .{
                .id = id,
                .name = owned_name,
                .config_dir_name = owned_name,
                .dot_dir_name = dot_dir_name,
                .cli_names = clis,
            };

            if (try buildInstallation(arena, io, p, custom_spec)) |inst| {
                try list.append(arena, inst);
            }
        }
    } else |_| {}

    return list.toOwnedSlice(arena);
}
