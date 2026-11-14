const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Io = std.Io;

const win_junction = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const DWORD = u32;
    const BOOL = i32;
    const WCHAR = u16;

    const GENERIC_WRITE: DWORD = 0x40000000;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_FLAG_OPEN_REPARSE_POINT: DWORD = 0x00200000;
    const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
    const FSCTL_SET_REPARSE_POINT: DWORD = 0x000900A4;
    const IO_REPARSE_TAG_MOUNT_POINT: DWORD = 0xA0000003;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const WCHAR,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn DeviceIoControl(
        hDevice: HANDLE,
        dwIoControlCode: DWORD,
        lpInBuffer: ?*const anyopaque,
        nInBufferSize: DWORD,
        lpOutBuffer: ?*anyopaque,
        nOutBufferSize: DWORD,
        lpBytesReturned: ?*DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

    pub fn create(io: Io, link_path: []const u8, target_path: []const u8) !void {
        try Dir.createDirAbsolute(io, link_path, .default_dir);
        errdefer Dir.deleteDirAbsolute(io, link_path) catch {};

        var link_w: [4096:0]u16 = undefined;
        const link_w_len = try std.unicode.utf8ToUtf16Le(&link_w, link_path);
        link_w[link_w_len] = 0;

        const clean_target = paths.stripWinPrefix(target_path);
        var print_w: [4096]u16 = undefined;
        const print_w_len = try std.unicode.utf8ToUtf16Le(&print_w, clean_target);
        for (print_w[0..print_w_len]) |*ch| {
            if (ch.* == '/') {
                ch.* = '\\';
            }
        }

        const prefix = [_]u16{ '\\', '?', '?', '\\' };
        const sub_w_len = prefix.len + print_w_len;
        const sub_bytes: u16 = @intCast(sub_w_len * 2);
        const print_bytes: u16 = @intCast(print_w_len * 2);
        const reparse_data_len: u16 = 8 + sub_bytes + 2 + print_bytes + 2;
        const total_len: DWORD = 8 + @as(DWORD, reparse_data_len);

        var reparse_buf: [16384]u8 align(4) = @splat(0);
        if (total_len > reparse_buf.len) {
            return error.NameTooLong;
        }

        std.mem.writeInt(u32, reparse_buf[0..4], IO_REPARSE_TAG_MOUNT_POINT, .little);
        std.mem.writeInt(u16, reparse_buf[4..6], reparse_data_len, .little);
        std.mem.writeInt(u16, reparse_buf[6..8], 0, .little);
        // MountPointReparseBuffer header
        std.mem.writeInt(u16, reparse_buf[8..10], 0, .little); // SubstituteNameOffset
        std.mem.writeInt(u16, reparse_buf[10..12], sub_bytes, .little); // SubstituteNameLength
        std.mem.writeInt(u16, reparse_buf[12..14], sub_bytes + 2, .little); // PrintNameOffset
        std.mem.writeInt(u16, reparse_buf[14..16], print_bytes, .little); // PrintNameLength

        var byte_pos: usize = 16;
        const prefix_bytes = std.mem.sliceAsBytes(prefix[0..]);
        @memcpy(reparse_buf[byte_pos .. byte_pos + prefix_bytes.len], prefix_bytes);
        byte_pos += prefix_bytes.len;

        const target_w_bytes = std.mem.sliceAsBytes(print_w[0..print_w_len]);
        @memcpy(reparse_buf[byte_pos .. byte_pos + target_w_bytes.len], target_w_bytes);
        byte_pos += target_w_bytes.len + 2; // +2 for null wchar

        @memcpy(reparse_buf[byte_pos .. byte_pos + target_w_bytes.len], target_w_bytes);

        const handle = CreateFileW(
            &link_w,
            GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) {
            return error.JunctionOpenFailed;
        }
        defer _ = CloseHandle(handle);

        var returned: DWORD = 0;
        const ok = DeviceIoControl(
            handle,
            FSCTL_SET_REPARSE_POINT,
            &reparse_buf,
            total_len,
            null,
            0,
            &returned,
            null,
        );
        if (ok == 0) {
            return error.JunctionSetFailed;
        }
    }
} else struct {};

pub fn copyFileAbsolute(io: Io, src_path: []const u8, dst_path: []const u8) !void {
    if (Dir.path.dirname(dst_path)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }

    var src = try Dir.openFileAbsolute(io, src_path, .{});
    defer src.close(io);

    var dst = try Dir.createFileAbsolute(io, dst_path, .{ .truncate = true });
    defer dst.close(io);

    var buf: [32768]u8 = undefined;
    var reader = src.reader(io, &.{});
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch return reader.err.?;
        if (n == 0) {
            break;
        }
        try dst.writeStreamingAll(io, buf[0..n]);
    }
}

pub fn copyTreeAbsolute(arena: Allocator, io: Io, src_dir_path: []const u8, dst_dir_path: []const u8) !void {
    try Dir.cwd().createDirPath(io, dst_dir_path);

    var src_dir = try Dir.openDirAbsolute(io, src_dir_path, .{ .iterate = true });
    defer src_dir.close(io);

    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        const src_child = try Dir.path.join(arena, &.{ src_dir_path, entry.name });
        const dst_child = try Dir.path.join(arena, &.{ dst_dir_path, entry.name });

        if (entry.kind == .directory) {
            try copyTreeAbsolute(arena, io, src_child, dst_child);
        } else if (entry.kind == .file) {
            try copyFileAbsolute(io, src_child, dst_child);
        }
    }
}

pub fn inspectLink(arena: Allocator, io: Io, link_path: []const u8, expected_target: []const u8) types.LinkState {
    const lst = Dir.cwd().statFile(io, link_path, .{ .follow_symlinks = false }) catch {
        return .missing;
    };

    if (lst.kind == .sym_link) {
        var link_buf: [Dir.max_path_bytes]u8 = undefined;
        const n = Dir.readLinkAbsolute(io, link_path, &link_buf) catch {
            return .broken;
        };
        const raw_target = paths.stripWinPrefix(link_buf[0..n]);
        const resolved = if (Dir.path.isAbsolute(raw_target))
            raw_target
        else blk: {
            const parent = Dir.path.dirname(link_path) orelse ".";
            break :blk Dir.path.resolve(arena, &.{ parent, raw_target }) catch return .broken;
        };

        Dir.accessAbsolute(io, resolved, .{}) catch {
            return .broken;
        };

        if (paths.pathsEqual(resolved, expected_target)) {
            return .linked;
        }
        return .linked_other;
    }

    if (lst.kind == .file) {
        if (Dir.cwd().statFile(io, expected_target, .{ .follow_symlinks = true })) |tst| {
            if (lst.inode != 0 and lst.inode == tst.inode and lst.nlink > 1) {
                return .hardlinked;
            }
        } else |_| {}
    }

    return .unlinked_real;
}

pub fn inspectIdeLinks(
    arena: Allocator,
    io: Io,
    ide: types.IdeInstallation,
    store: types.StorePaths,
) types.IdeLinkReport {
    return .{
        .settings_state = inspectLink(arena, io, ide.settings_path, store.settings_path),
        .keybindings_state = inspectLink(arena, io, ide.keybindings_path, store.keybindings_path),
        .extensions_state = inspectLink(arena, io, ide.extensions_dir, store.extensions_dir),
    };
}

fn removeLinkOnly(io: Io, link_path: []const u8) void {
    Dir.deleteFileAbsolute(io, link_path) catch {
        Dir.deleteDirAbsolute(io, link_path) catch {};
    };
}

pub fn linkConfigFile(
    arena: Allocator,
    io: Io,
    ide_file_path: []const u8,
    store_file_path: []const u8,
) !types.LinkState {
    const curr = inspectLink(arena, io, ide_file_path, store_file_path);
    if (curr == .linked or curr == .hardlinked) {
        return curr;
    }

    if (Dir.path.dirname(ide_file_path)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }

    if (curr != .missing) {
        removeLinkOnly(io, ide_file_path);
    }

    if (Dir.symLinkAbsolute(io, store_file_path, ide_file_path, .{ .is_directory = false })) |_| {
        return .linked;
    } else |err| {
        if (builtin.os.tag == .windows and (err == error.AccessDenied or err == error.PermissionDenied)) {
            try Dir.cwd().hardLink(store_file_path, .cwd(), ide_file_path, io, .{});
            return .hardlinked;
        }
        return err;
    }
}

fn createDirectoryLink(io: Io, store_ext_dir: []const u8, ide_ext_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        if (win_junction.create(io, ide_ext_path, store_ext_dir)) |_| {
            return;
        } else |_| {
            try Dir.symLinkAbsolute(io, store_ext_dir, ide_ext_path, .{ .is_directory = true });
            return;
        }
    }
    try Dir.symLinkAbsolute(io, store_ext_dir, ide_ext_path, .{ .is_directory = true });
}

/// Atomically replaces an IDE's extensions folder with a Windows Junction / POSIX directory symlink.
/// If any language server binary inside `ide_ext_path` is locked by a running IDE, `renameAbsolute`
/// fails immediately without deleting a single file.
pub fn linkExtensionsDir(
    arena: Allocator,
    io: Io,
    ide_ext_path: []const u8,
    store_ext_dir: []const u8,
) !void {
    const curr = inspectLink(arena, io, ide_ext_path, store_ext_dir);
    if (curr == .linked) {
        return;
    }

    if (Dir.path.dirname(ide_ext_path)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }
    try Dir.cwd().createDirPath(io, store_ext_dir);

    const st_opt: ?File.Stat = Dir.cwd().statFile(io, ide_ext_path, .{ .follow_symlinks = false }) catch null;
    if (st_opt == null) {
        try createDirectoryLink(io, store_ext_dir, ide_ext_path);
        return;
    }

    if (st_opt.?.kind == .sym_link) {
        removeLinkOnly(io, ide_ext_path);
        try createDirectoryLink(io, store_ext_dir, ide_ext_path);
        return;
    }

    // Real directory: atomic rename-swap before deleting
    const now_ns = Io.Clock.awake.now(io).nanoseconds;
    const staging_old = try std.fmt.allocPrint(arena, "{s}.__syncide_old_{d}", .{ ide_ext_path, now_ns });

    Dir.renameAbsolute(ide_ext_path, staging_old, io) catch |err| {
        if (err == error.AccessDenied or err == error.PermissionDenied or err == error.FileBusy) {
            return error.ExtensionsFolderLockedByRunningIde;
        }
        return err;
    };

    createDirectoryLink(io, store_ext_dir, ide_ext_path) catch |link_err| {
        Dir.renameAbsolute(staging_old, ide_ext_path, io) catch {};
        return link_err;
    };

    Dir.cwd().deleteTree(io, staging_old) catch {};
}

pub fn unlinkIde(arena: Allocator, io: Io, ide: types.IdeInstallation, store: types.StorePaths) !void {
    const pairs = [_][2][]const u8{
        .{ ide.settings_path, store.settings_path },
        .{ ide.keybindings_path, store.keybindings_path },
    };

    for (pairs) |pair| {
        const st = inspectLink(arena, io, pair[0], pair[1]);
        if (st == .linked or st == .hardlinked or st == .broken) {
            removeLinkOnly(io, pair[0]);
            if (Dir.accessAbsolute(io, pair[1], .{})) |_| {
                try copyFileAbsolute(io, pair[1], pair[0]);
            } else |_| {}
        }
    }

    const ext_st = inspectLink(arena, io, ide.extensions_dir, store.extensions_dir);
    if (ext_st == .linked or ext_st == .broken) {
        removeLinkOnly(io, ide.extensions_dir);
        if (Dir.accessAbsolute(io, store.extensions_dir, .{})) |_| {
            try copyTreeAbsolute(arena, io, store.extensions_dir, ide.extensions_dir);
        } else |_| {}
    }
}
