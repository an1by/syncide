const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub const VERSION = "0.4.0";
pub const REPO = "an1by/syncide";

pub const UpdateOptions = struct {
    force: bool = false,
    check_only: bool = false,
    target_version: ?[]const u8 = null,
};

const ReleaseApiPayload = struct {
    tag_name: []const u8,
};

const SemverTuple = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub fn trimVersionPrefix(ver: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, ver, " \t\r\n");
    if (trimmed.len > 0 and (trimmed[0] == 'v' or trimmed[0] == 'V')) {
        return trimmed[1..];
    }
    return trimmed;
}

fn parseSemver(ver: []const u8) ?SemverTuple {
    const clean = trimVersionPrefix(ver);
    const core = if (std.mem.indexOfAny(u8, clean, "-+")) |idx| clean[0..idx] else clean;

    var it = std.mem.splitScalar(u8, core, '.');
    const maj_s = it.next() orelse return null;
    const min_s = it.next() orelse "0";
    const pat_s = it.next() orelse "0";

    const major = std.fmt.parseInt(u32, maj_s, 10) catch return null;
    const minor = std.fmt.parseInt(u32, min_s, 10) catch return null;
    const patch = std.fmt.parseInt(u32, pat_s, 10) catch return null;

    return .{
        .major = major,
        .minor = minor,
        .patch = patch,
    };
}

pub fn compareSemver(a: []const u8, b: []const u8) std.math.Order {
    const pa = parseSemver(a) orelse {
        return std.mem.order(u8, trimVersionPrefix(a), trimVersionPrefix(b));
    };
    const pb = parseSemver(b) orelse {
        return std.mem.order(u8, trimVersionPrefix(a), trimVersionPrefix(b));
    };

    if (pa.major != pb.major) {
        return std.math.order(pa.major, pb.major);
    }
    if (pa.minor != pb.minor) {
        return std.math.order(pa.minor, pb.minor);
    }
    return std.math.order(pa.patch, pb.patch);
}

pub fn platformAssetName() ![]const u8 {
    const os_slug = switch (builtin.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => return error.UnsupportedPlatform,
    };
    const arch_slug = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedArchitecture,
    };

    if (builtin.os.tag == .windows) {
        return "syncide-" ++ os_slug ++ "-" ++ arch_slug ++ ".exe";
    }
    return "syncide-" ++ os_slug ++ "-" ++ arch_slug ++ ".tar.gz";
}

fn isValidHex64(s: []const u8) bool {
    if (s.len != 64) {
        return false;
    }
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F');
        if (!ok) {
            return false;
        }
    }
    return true;
}

pub fn parseExpectedSha256(sums_content: []const u8, asset_name: []const u8) ?[]const u8 {
    var line_it = std.mem.splitScalar(u8, sums_content, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len < 66) {
            continue;
        }
        const sp_idx = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const hash_tok = line[0..sp_idx];
        if (!isValidHex64(hash_tok)) {
            continue;
        }

        var file_tok = std.mem.trimStart(u8, line[sp_idx..], " \t*");
        if (std.mem.startsWith(u8, file_tok, "./")) {
            file_tok = file_tok[2..];
        }
        const base = Dir.path.basename(file_tok);
        if (std.ascii.eqlIgnoreCase(file_tok, asset_name) or std.ascii.eqlIgnoreCase(base, asset_name)) {
            return hash_tok;
        }
    }
    return null;
}

pub fn computeFileSha256Hex(io: Io, file_path: []const u8) ![64]u8 {
    var f = try Dir.openFileAbsolute(io, file_path, .{});
    defer f.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk_buf: [16384]u8 = undefined;
    var reader = f.reader(io, &.{});
    while (true) {
        const n = reader.interface.readSliceShort(&chunk_buf) catch {
            return reader.err orelse error.ReadFailed;
        };
        if (n == 0) {
            break;
        }
        hasher.update(chunk_buf[0..n]);
        if (n < chunk_buf.len) {
            break;
        }
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Renames a file (including a currently executing `.exe` on Windows via Win32 `MoveFileExW`,
/// avoiding `NtOpenFile` `FILE_SHARE_READ` `FileBusy` errors in stdlib `Dir.renameAbsolute`).
pub fn moveExecutableOrFile(io: Io, src_path: []const u8, dst_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const win = struct {
            const MOVEFILE_REPLACE_EXISTING: u32 = 0x00000001;
            extern "kernel32" fn MoveFileExW(
                lpExistingFileName: [*:0]const u16,
                lpNewFileName: ?[*:0]const u16,
                dwFlags: u32,
            ) callconv(.winapi) i32;
        };

        var src_w: [4096:0]u16 = undefined;
        const src_len = try std.unicode.utf8ToUtf16Le(&src_w, src_path);
        src_w[src_len] = 0;

        var dst_w: [4096:0]u16 = undefined;
        const dst_len = try std.unicode.utf8ToUtf16Le(&dst_w, dst_path);
        dst_w[dst_len] = 0;

        if (win.MoveFileExW(&src_w, &dst_w, win.MOVEFILE_REPLACE_EXISTING) != 0) {
            return;
        }
        return error.UpdatePermissionDenied;
    }

    Dir.renameAbsolute(src_path, dst_path, io) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.UpdatePermissionDenied,
        else => return err,
    };
}

/// Best-effort cleanup of `<exe>.old` or `<exe>.uninstall` left behind on Windows.
pub fn cleanupOldExecutable(arena: Allocator, io: Io) void {
    if (builtin.os.tag != .windows) {
        return;
    }
    const exe_path = std.process.executablePathAlloc(io, arena) catch return;
    if (std.fmt.allocPrint(arena, "{s}.old", .{exe_path})) |old_path| {
        Dir.deleteFileAbsolute(io, old_path) catch {};
    } else |_| {}
    if (std.fmt.allocPrint(arena, "{s}.uninstall", .{exe_path})) |uninst_path| {
        Dir.deleteFileAbsolute(io, uninst_path) catch {};
    } else |_| {}
}

fn escapePsSingleQuotedAlloc(arena: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |c| {
        if (c == '\r' or c == '\n' or c == 0) {
            return error.InvalidDownloadParameter;
        }
        if (c == '\'') {
            try out.appendSlice(arena, "''");
        } else {
            try out.append(arena, c);
        }
    }
    return out.toOwnedSlice(arena);
}

fn spawnWaitSuccess(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    argv: []const []const u8,
) bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return false;

    const term = child.wait(io) catch return false;
    return term.success();
}

fn downloadUrlToFile(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    url: []const u8,
    dest_path: []const u8,
) !void {
    if (!std.mem.startsWith(u8, url, "https://")) {
        return error.InsecureDownloadUrl;
    }
    Dir.deleteFileAbsolute(io, dest_path) catch {};

    if (builtin.os.tag == .windows) {
        const sys_root = environ_map.get("SystemRoot") orelse "C:\\Windows";
        const curl_exe = try Dir.path.join(arena, &.{ sys_root, "System32", "curl.exe" });

        if (Dir.accessAbsolute(io, curl_exe, .{})) |_| {
            if (spawnWaitSuccess(io, environ_map, &.{
                curl_exe,
                "-fsSL",
                "--retry",
                "2",
                "-H",
                "User-Agent: syncide-updater",
                "-o",
                dest_path,
                url,
            })) {
                if (Dir.accessAbsolute(io, dest_path, .{})) |_| {
                    return;
                } else |_| {}
            }
        } else |_| {}

        const ps_exe = try Dir.path.join(arena, &.{
            sys_root,
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe",
        });
        const safe_url = try escapePsSingleQuotedAlloc(arena, url);
        const safe_dest = try escapePsSingleQuotedAlloc(arena, dest_path);
        const ps_cmd = try std.fmt.allocPrint(
            arena,
            "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Headers @{{'User-Agent'='syncide-updater'}} -Uri '{s}' -OutFile '{s}' -UseBasicParsing",
            .{ safe_url, safe_dest },
        );

        if (spawnWaitSuccess(io, environ_map, &.{
            ps_exe,
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            ps_cmd,
        })) {
            if (Dir.accessAbsolute(io, dest_path, .{})) |_| {
                return;
            } else |_| {}
        }

        return error.DownloadFailed;
    }

    if (spawnWaitSuccess(io, environ_map, &.{
        "curl",
        "-fsSL",
        "--retry",
        "2",
        "-H",
        "User-Agent: syncide-updater",
        "-o",
        dest_path,
        url,
    })) {
        if (Dir.accessAbsolute(io, dest_path, .{})) |_| {
            return;
        } else |_| {}
    }

    if (spawnWaitSuccess(io, environ_map, &.{
        "wget",
        "-q",
        "--header=User-Agent: syncide-updater",
        "-O",
        dest_path,
        url,
    })) {
        if (Dir.accessAbsolute(io, dest_path, .{})) |_| {
            return;
        } else |_| {}
    }

    return error.DownloadFailed;
}

fn parseTagFromHeaders(arena: Allocator, headers_raw: []const u8) !?[]const u8 {
    var last_tag: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, headers_raw, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len > 9 and std.ascii.eqlIgnoreCase(line[0..9], "location:")) {
            const loc = std.mem.trim(u8, line[9..], " \t");
            if (std.mem.indexOf(u8, loc, "/releases/tag/")) |idx| {
                const rest = loc[idx + "/releases/tag/".len ..];
                const end_idx = std.mem.indexOfAny(u8, rest, "?#/ \t\r") orelse rest.len;
                if (end_idx > 0) {
                    last_tag = try arena.dupe(u8, rest[0..end_idx]);
                }
            }
        }
    }
    return last_tag;
}

fn fetchLatestTagAlloc(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    work_dir: []const u8,
) !?[]const u8 {
    const api_url = "https://api.github.com/repos/" ++ REPO ++ "/releases/latest";
    const json_path = try Dir.path.join(arena, &.{ work_dir, "latest.json" });

    if (downloadUrlToFile(arena, io, environ_map, api_url, json_path)) |_| {
        if (Dir.cwd().readFileAlloc(io, json_path, arena, .limited(2 * 1024 * 1024))) |raw| {
            if (std.json.parseFromSlice(ReleaseApiPayload, arena, raw, .{
                .ignore_unknown_fields = true,
            })) |parsed| {
                if (parsed.value.tag_name.len > 0) {
                    return try arena.dupe(u8, parsed.value.tag_name);
                }
            } else |_| {}
        } else |_| {}
    } else |_| {}

    // Fallback if GitHub REST API is rate-limited: inspect HTTP 302 Location header
    const latest_url = "https://github.com/" ++ REPO ++ "/releases/latest";
    const hdr_path = try Dir.path.join(arena, &.{ work_dir, "headers.txt" });
    const sink_path = try Dir.path.join(arena, &.{ work_dir, "sink.tmp" });

    if (builtin.os.tag == .windows) {
        const sys_root = environ_map.get("SystemRoot") orelse "C:\\Windows";
        const curl_exe = try Dir.path.join(arena, &.{ sys_root, "System32", "curl.exe" });
        _ = spawnWaitSuccess(io, environ_map, &.{
            curl_exe,
            "-fsSLI",
            "-D",
            hdr_path,
            "-o",
            sink_path,
            latest_url,
        });
    } else {
        _ = spawnWaitSuccess(io, environ_map, &.{
            "curl",
            "-fsSLI",
            "-D",
            hdr_path,
            "-o",
            sink_path,
            latest_url,
        });
    }

    if (Dir.cwd().readFileAlloc(io, hdr_path, arena, .limited(256 * 1024))) |hdr_raw| {
        return try parseTagFromHeaders(arena, hdr_raw);
    } else |_| {}

    return null;
}

fn verifyWindowsPeBinary(io: Io, bin_path: []const u8) !void {
    var f = try Dir.openFileAbsolute(io, bin_path, .{});
    defer f.close(io);

    const st = try f.stat(io);
    if (st.size < 16 * 1024) {
        return error.CorruptDownloadedBinary;
    }

    var mz: [2]u8 = undefined;
    var r = f.reader(io, &.{});
    const n = r.interface.readSliceShort(&mz) catch return error.CorruptDownloadedBinary;
    if (n < 2 or mz[0] != 'M' or mz[1] != 'Z') {
        return error.InvalidExecutableHeader;
    }
}

pub fn runSelfUpdate(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    out: *Io.Writer,
    opts: UpdateOptions,
) !void {
    const asset_name = try platformAssetName();
    const exe_path = try std.process.executablePathAlloc(io, arena);
    const exe_dir = Dir.path.dirname(exe_path) orelse return error.InvalidExecutablePath;

    const ns = Io.Clock.awake.now(io).nanoseconds;
    const stage_name = try std.fmt.allocPrint(arena, ".syncide-update-{d}", .{ns});
    const stage_dir = try Dir.path.join(arena, &.{ exe_dir, stage_name });

    Dir.cwd().createDirPath(io, stage_dir) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.UpdatePermissionDenied,
        else => return err,
    };
    defer Dir.cwd().deleteTree(io, stage_dir) catch {};

    var resolved_tag: ?[]const u8 = null;
    if (opts.target_version) |req_ver| {
        const clean = trimVersionPrefix(req_ver);
        if (clean.len == 0) {
            return error.InvalidVersionTag;
        }
        resolved_tag = try std.fmt.allocPrint(arena, "v{s}", .{clean});
    } else {
        try out.print("Checking latest syncide release (current: v{s})...\n", .{VERSION});
        try out.flush();
        resolved_tag = try fetchLatestTagAlloc(arena, io, environ_map, stage_dir);
    }

    if (opts.check_only) {
        const tag = resolved_tag orelse return error.ReleaseCheckFailed;
        if (compareSemver(tag, VERSION) == .gt) {
            try out.print("Update available: v{s} -> {s} (run 'syncide update' to install).\n", .{
                VERSION,
                tag,
            });
        } else {
            try out.print("syncide is up to date (v{s}).\n", .{VERSION});
        }
        return;
    }

    if (opts.target_version == null and !opts.force) {
        if (resolved_tag) |tag| {
            if (compareSemver(tag, VERSION) != .gt) {
                try out.print("syncide is already up to date (v{s}).\n", .{VERSION});
                return;
            }
        }
    }

    const base_download_url = if (resolved_tag) |tag|
        try std.fmt.allocPrint(arena, "https://github.com/{s}/releases/download/{s}", .{ REPO, tag })
    else
        try std.fmt.allocPrint(arena, "https://github.com/{s}/releases/latest/download", .{REPO});

    const display_ver = resolved_tag orelse "latest";
    try out.print("Downloading {s} ({s})...\n", .{ asset_name, display_ver });
    try out.flush();

    const sums_url = try std.fmt.allocPrint(arena, "{s}/SHA256SUMS.txt", .{base_download_url});
    const asset_url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base_download_url, asset_name });

    const sums_path = try Dir.path.join(arena, &.{ stage_dir, "SHA256SUMS.txt" });
    const asset_path = try Dir.path.join(arena, &.{ stage_dir, asset_name });

    try downloadUrlToFile(arena, io, environ_map, sums_url, sums_path);
    try downloadUrlToFile(arena, io, environ_map, asset_url, asset_path);

    const sums_raw = try Dir.cwd().readFileAlloc(io, sums_path, arena, .limited(256 * 1024));
    const expected_hex = parseExpectedSha256(sums_raw, asset_name) orelse return error.MissingAssetChecksum;
    const actual_hex = try computeFileSha256Hex(io, asset_path);

    if (!std.ascii.eqlIgnoreCase(expected_hex, &actual_hex)) {
        return error.ChecksumMismatch;
    }

    if (builtin.os.tag == .windows) {
        try verifyWindowsPeBinary(io, asset_path);

        const old_exe = try std.fmt.allocPrint(arena, "{s}.old", .{exe_path});
        Dir.deleteFileAbsolute(io, old_exe) catch {};

        try moveExecutableOrFile(io, exe_path, old_exe);

        moveExecutableOrFile(io, asset_path, exe_path) catch |err| {
            moveExecutableOrFile(io, old_exe, exe_path) catch {};
            return err;
        };

        // Best-effort immediate removal; if locked by Windows image loader, cleaned up on next startup
        Dir.deleteFileAbsolute(io, old_exe) catch {};
    } else {
        if (!spawnWaitSuccess(io, environ_map, &.{ "tar", "-xzf", asset_path, "-C", stage_dir })) {
            return error.ArchiveExtractFailed;
        }

        const extracted_bin = try Dir.path.join(arena, &.{ stage_dir, "syncide" });
        try Dir.accessAbsolute(io, extracted_bin, .{});
        _ = spawnWaitSuccess(io, environ_map, &.{ "chmod", "755", extracted_bin });

        Dir.renameAbsolute(extracted_bin, exe_path, io) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return error.UpdatePermissionDenied,
            else => return err,
        };
    }

    try out.print("Updated syncide: v{s} -> {s} ({s})\n", .{ VERSION, display_ver, exe_path });
}

test "semver comparison and SHA256SUMS parsing" {
    try std.testing.expectEqual(std.math.Order.gt, compareSemver("v0.3.0", "0.2.0"));
    try std.testing.expectEqual(std.math.Order.eq, compareSemver("0.3.0", "v0.3.0"));
    try std.testing.expectEqual(std.math.Order.lt, compareSemver("0.2.9", "0.3.0"));

    const sample_sums =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  syncide-linux-x86_64.tar.gz\r\n" ++
        "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 *./syncide-windows-x86_64.exe\n";

    const win_hash = parseExpectedSha256(sample_sums, "syncide-windows-x86_64.exe");
    try std.testing.expect(win_hash != null);
    try std.testing.expectEqualStrings(
        "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
        win_hash.?,
    );

    const linux_hash = parseExpectedSha256(sample_sums, "syncide-linux-x86_64.tar.gz");
    try std.testing.expect(linux_hash != null);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        linux_hash.?,
    );
}
