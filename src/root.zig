const std = @import("std");

pub const types = @import("types.zig");
pub const paths = @import("paths.zig");
pub const discovery = @import("discovery.zig");
pub const archive = @import("archive.zig");
pub const linker = @import("linker.zig");
pub const extensions = @import("extensions.zig");
pub const state = @import("state.zig");
pub const syncer = @import("syncer.zig");

fn writeDummyExt(
    arena: std.mem.Allocator,
    io: std.Io,
    ext_root: []const u8,
    publisher: []const u8,
    name: []const u8,
    version: []const u8,
) !void {
    const folder_name = try std.fmt.allocPrint(arena, "{s}.{s}-{s}", .{ publisher, name, version });
    const folder = try std.Io.Dir.path.join(arena, &.{ ext_root, folder_name });
    try std.Io.Dir.cwd().createDirPath(io, folder);

    const pkg_path = try std.Io.Dir.path.join(arena, &.{ folder, "package.json" });
    const payload = try std.fmt.allocPrint(
        arena,
        "{{\"name\":\"{s}\",\"publisher\":\"{s}\",\"version\":\"{s}\",\"engines\":{{\"vscode\":\"^1.85.0\"}}}}",
        .{ name, publisher, version },
    );
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pkg_path, .data = payload });
}

test "end-to-end discovery, zip backups, junction/symlink live sync, broken link repair, and unlink" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();

    const cwd_abs = try std.process.currentPathAlloc(io, arena);
    const rand_ns = std.Io.Clock.awake.now(io).nanoseconds;
    const sandbox_name = try std.fmt.allocPrint(arena, ".zig-cache/syncide-sandbox-{d}", .{rand_ns});
    const sandbox = try std.Io.Dir.path.resolve(arena, &.{ cwd_abs, sandbox_name });
    defer std.Io.Dir.cwd().deleteTree(io, sandbox) catch {};

    const fake_home = try std.Io.Dir.path.join(arena, &.{ sandbox, "home" });
    const fake_appdata = try std.Io.Dir.path.join(arena, &.{ sandbox, "appdata" });
    try std.Io.Dir.cwd().createDirPath(io, fake_home);
    try std.Io.Dir.cwd().createDirPath(io, fake_appdata);

    // Seed VS Code
    const code_user = try std.Io.Dir.path.join(arena, &.{ fake_appdata, "Code", "User" });
    try std.Io.Dir.cwd().createDirPath(io, code_user);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.Io.Dir.path.join(arena, &.{ code_user, "settings.json" }),
        .data = "{\"theme\":\"code-old\"}",
    });
    try writeDummyExt(
        arena,
        io,
        try std.Io.Dir.path.join(arena, &.{ fake_home, ".vscode", "extensions" }),
        "esbenp",
        "prettier-vscode",
        "10.1.0",
    );

    // Seed Cursor (primary)
    const cursor_user = try std.Io.Dir.path.join(arena, &.{ fake_appdata, "Cursor", "User" });
    try std.Io.Dir.cwd().createDirPath(io, cursor_user);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.Io.Dir.path.join(arena, &.{ cursor_user, "settings.json" }),
        .data = "{\"theme\":\"cursor-primary\"}",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.Io.Dir.path.join(arena, &.{ cursor_user, "keybindings.json" }),
        .data = "[{\"key\":\"ctrl+k\"}]",
    });
    try writeDummyExt(
        arena,
        io,
        try std.Io.Dir.path.join(arena, &.{ fake_home, ".cursor", "extensions" }),
        "biomejs",
        "biome",
        "2.0.0",
    );

    // Seed backup dir & non-VSCode dir (must be ignored)
    const bak_user = try std.Io.Dir.path.join(arena, &.{ fake_appdata, "Cursor_backup_2026", "User" });
    try std.Io.Dir.cwd().createDirPath(io, bak_user);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.Io.Dir.path.join(arena, &.{ bak_user, "settings.json" }),
        .data = "{}",
    });
    const lm_dir = try std.Io.Dir.path.join(arena, &.{ fake_home, ".lmstudio", "extensions", "foo" });
    try std.Io.Dir.cwd().createDirPath(io, lm_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.Io.Dir.path.join(arena, &.{ lm_dir, "package.json" }),
        .data = "{\"name\":\"not-vscode\"}",
    });

    const p = try paths.resolvePlatformPaths(arena, &env_map, .{
        .home_dir = fake_home,
        .app_config_root = fake_appdata,
    });
    const ides = try discovery.discoverIdes(arena, io, p);
    try std.testing.expectEqual(@as(usize, 2), ides.len);

    var cursor_ide: ?types.IdeInstallation = null;
    var code_ide: ?types.IdeInstallation = null;
    for (ides) |ide| {
        if (std.mem.eql(u8, ide.id, "cursor")) {
            cursor_ide = ide;
        } else if (std.mem.eql(u8, ide.id, "code")) {
            code_ide = ide;
        }
    }
    try std.testing.expect(cursor_ide != null and code_ide != null);

    const custom_store = try std.Io.Dir.path.join(arena, &.{ sandbox, "custom-store" });
    const summary = try syncer.initializeSync(arena, gpa, io, &env_map, .{
        .platform_paths = p,
        .selected_ides = ides,
        .primary_ide = cursor_ide.?,
        .store_dir = custom_store,
        .merge_extensions = true,
    });

    try std.testing.expectEqual(@as(usize, 0), summary.warnings.len);
    try std.testing.expectEqual(@as(usize, 2), summary.extensions_total);
    try std.testing.expectEqual(@as(usize, 4), summary.backups_created.len);

    // Live edit in VS Code propagates immediately to Cursor
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = code_ide.?.settings_path,
        .data = "{\"theme\":\"live-synced\"}",
    });
    const cursor_settings = try std.Io.Dir.cwd().readFileAlloc(io, cursor_ide.?.settings_path, arena, .limited(4096));
    try std.testing.expectEqualStrings("{\"theme\":\"live-synced\"}", cursor_settings);

    // Adding an extension in Cursor appears immediately in VS Code
    try writeDummyExt(arena, io, cursor_ide.?.extensions_dir, "svelte", "svelte-vscode", "109.0.0");
    const svelte_pkg = try std.Io.Dir.path.join(arena, &.{
        code_ide.?.extensions_dir,
        "svelte.svelte-vscode-109.0.0",
        "package.json",
    });
    try std.Io.Dir.accessAbsolute(io, svelte_pkg, .{});

    const sync_res = try syncer.runManualSync(arena, gpa, io, &env_map, p, null, false);
    try std.testing.expectEqual(@as(usize, 3), sync_res.extensions_total);

    // Test pure-Zig DEFLATE zip builder directly
    const pure_zip = try std.Io.Dir.path.join(arena, &.{ sandbox, "pure-test.zip" });
    try archive.createZipPure(gpa, io, pure_zip, custom_store, &.{"User"});
    try std.Io.Dir.accessAbsolute(io, pure_zip, .{});

    // Test standalone unlink
    const store_paths = try paths.getStorePaths(arena, custom_store);
    try linker.unlinkIde(arena, io, code_ide.?, store_paths);
    const code_ext_stat = try std.Io.Dir.cwd().statFile(io, code_ide.?.extensions_dir, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.directory, code_ext_stat.kind);
}
