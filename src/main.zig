const std = @import("std");
const syncide = @import("syncide");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const types = syncide.types;
const paths = syncide.paths;
const discovery = syncide.discovery;
const archive = syncide.archive;
const linker = syncide.linker;
const extensions = syncide.extensions;
const state_mod = syncide.state;
const syncer = syncide.syncer;
const updater = syncide.updater;

fn printHelp(w: *Io.Writer) !void {
    try w.writeAll(
        \\syncide — Lightweight cross-IDE settings, keybindings & extensions linker (Zig)
        \\
        \\Usage:
        \\  syncide init [options]                   Interactive setup: choose primary IDE, .zip backup & link
        \\  syncide status                           Show discovered IDEs and link status (alias: scan)
        \\  syncide sync [--include-new]             Verify/repair links, merge unlinked edits & reconcile extensions.json
        \\  syncide extension list                   List shared extensions (alias: ext ls, --list-extensions)
        \\  syncide extension install <id...>        Install extension(s) to shared store (alias: ext -i, --install-extension)
        \\  syncide extension uninstall <id...>      Remove extension(s) from shared store (alias: ext -u, --uninstall-extension)
        \\  syncide backups create [ide-id...|all]   Create compressed .zip backups and print archive paths
        \\  syncide backups clean [-f] [ide-id...]   Delete syncide .zip backups with confirmation or --force
        \\  syncide backups list [ide-id...|all]     List existing .zip backups and sizes (default for 'backups')
        \\  syncide unlink <ide-id...|all>           Detach IDE(s) back into standalone copies
        \\  syncide update [-f] [--check]            Self-update syncide binary from GitHub Releases
        \\  syncide --version                        Print installed syncide version
        \\
        \\Init Options:
        \\  --primary <id>       Primary IDE id (e.g. code, cursor, trae, antigravity)
        \\  --ides <ids|all>     Comma-separated IDE ids to link, or 'all'
        \\  --store <dir>        Custom central store directory (default: AppData/syncide or ~/.config/syncide)
        \\  --merge              Merge unique extensions from non-primary IDEs into store
        \\  -y, --yes            Non-interactive confirmation
        \\
        \\Backups Options:
        \\  -f, --force          Skip confirmation prompt in 'syncide backups clean'
        \\  --store <dir>        Explicit central store directory
        \\
        \\Update Options:
        \\  --check              Check whether a newer release is available without installing
        \\  --version <tag>      Install a specific release version (e.g. v0.3.0)
        \\  -f, --force          Reinstall even if already on the latest version
        \\
        \\Extension Options:
        \\  -l, --list-extensions          List installed extensions in shared store
        \\  -i, --install-extension <id>   Install extension ID or .vsix into shared store
        \\  -u, --uninstall-extension <id> Uninstall extension ID from shared store
        \\  -f, --force                    Pass --force when installing extensions
        \\
    );
}

fn readStdinLineAlloc(arena: Allocator, io: Io) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    const stdin_file = Io.File.stdin();
    var reader = stdin_file.reader(io, &.{});
    while (true) {
        const b = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return reader.err orelse error.InputFailed,
        };
        if (b == '\n') {
            break;
        }
        if (b != '\r') {
            try line.append(arena, b);
        }
    }
    return std.mem.trim(u8, line.items, " \t");
}

fn askPrompt(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    question: []const u8,
    default_val: ?[]const u8,
) ![]const u8 {
    if (default_val) |def| {
        try out.print("{s} [{s}]: ", .{ question, def });
    } else {
        try out.print("{s}: ", .{question});
    }
    try out.flush();

    const ans = try readStdinLineAlloc(arena, io);
    if (ans.len == 0 and default_val != null) {
        return default_val.?;
    }
    return ans;
}

fn askConfirm(arena: Allocator, io: Io, out: *Io.Writer, question: []const u8, default_yes: bool) !bool {
    const hint = if (default_yes) "Y/n" else "y/N";
    try out.print("{s} [{s}]: ", .{ question, hint });
    try out.flush();

    const ans = try readStdinLineAlloc(arena, io);
    if (ans.len == 0) {
        return default_yes;
    }
    return std.ascii.eqlIgnoreCase(ans, "y") or
        std.ascii.eqlIgnoreCase(ans, "yes") or
        std.mem.eql(u8, ans, "д") or
        std.mem.eql(u8, ans, "да") or
        std.mem.eql(u8, ans, "Д") or
        std.mem.eql(u8, ans, "Да");
}

fn askOneIndex(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    question: []const u8,
    max_count: usize,
    default_one_based: usize,
) !usize {
    var def_buf: [16]u8 = undefined;
    const def_str = try std.fmt.bufPrint(&def_buf, "{d}", .{default_one_based});

    while (true) {
        const raw = try askPrompt(arena, io, out, question, def_str);
        if (std.fmt.parseInt(usize, raw, 10)) |num| {
            if (num >= 1 and num <= max_count) {
                return num - 1;
            }
        } else |_| {}
        try out.print("Enter a number between 1 and {d}.\n", .{max_count});
    }
}

pub fn parseSelectionIndicesAlloc(arena: Allocator, raw_input: []const u8, max_count: usize) ![]usize {
    const trimmed = std.mem.trim(u8, raw_input, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "all") or std.mem.eql(u8, trimmed, "*")) {
        const all = try arena.alloc(usize, max_count);
        for (0..max_count) |i| {
            all[i] = i;
        }
        return all;
    }

    const selected = try arena.alloc(bool, max_count);
    defer arena.free(selected);

    var has_positive = false;
    var check_it = std.mem.tokenizeAny(u8, trimmed, ", ");
    while (check_it.next()) |tok| {
        if (tok[0] != '-' and tok[0] != '!') {
            has_positive = true;
            break;
        }
    }

    // Pure exclusion mode (e.g. "-3,-4") starts with all selected
    @memset(selected, !has_positive);

    var it = std.mem.tokenizeAny(u8, trimmed, ", ");
    var saw_any = false;
    while (it.next()) |tok| {
        saw_any = true;
        const is_exclude = tok[0] == '-' or tok[0] == '!';
        const body = if (is_exclude) tok[1..] else tok;
        if (body.len == 0) {
            return error.InvalidSelection;
        }

        if (std.mem.indexOfScalar(u8, body, '-')) |dash_pos| {
            const start_num = try std.fmt.parseInt(usize, body[0..dash_pos], 10);
            const end_num = try std.fmt.parseInt(usize, body[dash_pos + 1 ..], 10);
            if (start_num < 1 or end_num < start_num or end_num > max_count) {
                return error.InvalidSelection;
            }
            for (start_num..end_num + 1) |n| {
                selected[n - 1] = !is_exclude;
            }
        } else {
            const num = try std.fmt.parseInt(usize, body, 10);
            if (num < 1 or num > max_count) {
                return error.InvalidSelection;
            }
            selected[num - 1] = !is_exclude;
        }
    }

    if (!saw_any) {
        return error.InvalidSelection;
    }

    var out_indices: std.ArrayList(usize) = .empty;
    for (selected, 0..) |flag, idx| {
        if (flag) {
            try out_indices.append(arena, idx);
        }
    }
    if (out_indices.items.len == 0) {
        return error.EmptySelection;
    }
    return out_indices.toOwnedSlice(arena);
}

fn askManyIndices(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    question: []const u8,
    max_count: usize,
) ![]usize {
    while (true) {
        const raw = try askPrompt(arena, io, out, question, "all");
        if (parseSelectionIndicesAlloc(arena, raw, max_count)) |indices| {
            return indices;
        } else |_| {
            try out.print(
                "Enter 'all', numbers/ranges (e.g. '1,2,5' or '1-3'), or exclusions (e.g. '-4') within 1..{d}.\n",
                .{max_count},
            );
        }
    }
}

fn printStatusTable(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    p: types.PlatformPaths,
    ides: []const types.IdeInstallation,
) !void {
    if (ides.len == 0) {
        try out.print("No VS Code-based IDEs found in {s} or {s}.\n", .{ p.app_config_root, p.home_dir });
        return;
    }

    const st_opt = try state_mod.loadState(arena, io, p, null);
    var store_opt: ?types.StorePaths = null;

    if (st_opt) |st| {
        const sp = try paths.getStorePaths(arena, st.storeDir);
        store_opt = sp;
        const shared_cnt = discovery.countExtensionsInDir(arena, io, sp.extensions_dir);
        try out.print("Store:   {s}\nPrimary: {s} | Shared extensions: {d}\n\n", .{
            st.storeDir,
            st.primaryIdeId,
            shared_cnt,
        });
    } else {
        try out.print("Status:  Not initialized (default store: {s})\n\n", .{p.default_store_dir});
    }

    for (ides, 0..) |ide, idx| {
        var set_buf: [32]u8 = undefined;
        var key_buf: [32]u8 = undefined;
        const set_str = if (ide.has_settings) paths.formatBytesBuf(ide.settings_size, &set_buf) else "none";
        const key_str = if (ide.has_keybindings) paths.formatBytesBuf(ide.keybindings_size, &key_buf) else "none";
        const label = try std.fmt.allocPrint(arena, "{s} ({s})", .{ ide.name, ide.id });

        if (st_opt != null and store_opt != null) {
            var is_managed = false;
            for (st_opt.?.managedIdeIds) |mid| {
                if (std.mem.eql(u8, mid, ide.id)) {
                    is_managed = true;
                    break;
                }
            }
            const mark: u8 = if (is_managed) '*' else ' ';
            const rep = linker.inspectIdeLinks(arena, io, ide, store_opt.?);
            try out.print(
                "[{d}] {c} {s:<32} settings: {s:<8} | keys: {s:<8} | ext: {d:<3} [S:{s} K:{s} E:{s}]\n",
                .{
                    idx + 1,
                    mark,
                    label,
                    set_str,
                    key_str,
                    ide.extensions_count,
                    rep.settings_state.badge(),
                    rep.keybindings_state.badge(),
                    rep.extensions_state.badge(),
                },
            );
        } else {
            try out.print(
                "[{d}]   {s:<32} settings: {s:<8} | keys: {s:<8} | ext: {d}\n",
                .{ idx + 1, label, set_str, key_str, ide.extensions_count },
            );
        }
    }
}

fn printSyncSummary(out: *Io.Writer, sum: syncer.SyncSummary) !void {
    try out.print("\nStore directory:   {s}\n", .{sum.store_dir});
    try out.print("Shared extensions: {d}\n", .{sum.extensions_total});
    if (sum.backups_created.len > 0) {
        try out.print("Backups (.zip):    {d}\n", .{sum.backups_created.len});
        for (sum.backups_created) |z| {
            try out.print("  + {s}\n", .{z});
        }
    }
    if (sum.linked_ides.len > 0) {
        try out.writeAll("Linked IDEs:       ");
        for (sum.linked_ides, 0..) |name, i| {
            if (i > 0) {
                try out.writeAll(", ");
            }
            try out.writeAll(name);
        }
        try out.writeByte('\n');
    }
    if (sum.warnings.len > 0) {
        try out.writeAll("\nWarnings:\n");
        for (sum.warnings) |warn| {
            try out.print("  ! {s}\n", .{warn});
        }
    }
}

fn handleInit(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    out: *Io.Writer,
    p: types.PlatformPaths,
    args: []const []const u8,
) !void {
    var primary_arg: ?[]const u8 = null;
    var ides_arg: ?[]const u8 = null;
    var store_arg: ?[]const u8 = null;
    var merge_flag = false;
    var yes_flag = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--primary")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            primary_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--ides")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            ides_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--store")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            store_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--merge")) {
            merge_flag = true;
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            yes_flag = true;
        } else {
            return error.UnknownOption;
        }
    }

    const discovered = try discovery.discoverIdes(arena, io, p);
    if (discovered.len == 0) {
        try out.print("No VS Code-based IDEs detected in {s}.\n", .{p.app_config_root});
        return;
    }

    const existing_state = try state_mod.loadState(arena, io, p, store_arg);
    try out.writeAll("Discovered VS Code-based IDEs (all selected by default):\n\n");
    for (discovered, 0..) |ide, idx| {
        var set_buf: [32]u8 = undefined;
        var key_buf: [32]u8 = undefined;
        const set_str = if (ide.has_settings) paths.formatBytesBuf(ide.settings_size, &set_buf) else "none";
        const key_str = if (ide.has_keybindings) paths.formatBytesBuf(ide.keybindings_size, &key_buf) else "none";
        const label = try std.fmt.allocPrint(arena, "{s} ({s})", .{ ide.name, ide.id });
        try out.print(
            "[{d}] [x] {s:<32} settings: {s:<8} | keys: {s:<8} | ext: {d}\n",
            .{ idx + 1, label, set_str, key_str, ide.extensions_count },
        );
    }
    try out.writeByte('\n');

    var primary_ide: types.IdeInstallation = undefined;
    var selected_list: std.ArrayList(types.IdeInstallation) = .empty;
    var store_dir: []const u8 = undefined;
    var merge_extensions = merge_flag;

    if (yes_flag and primary_arg != null) {
        var found_primary: ?types.IdeInstallation = null;
        for (discovered) |ide| {
            if (std.ascii.eqlIgnoreCase(ide.id, primary_arg.?)) {
                found_primary = ide;
                break;
            }
        }
        primary_ide = found_primary orelse return error.UnknownPrimaryIde;
        try selected_list.append(arena, primary_ide);

        if (ides_arg == null or std.ascii.eqlIgnoreCase(ides_arg.?, "all")) {
            for (discovered) |ide| {
                if (!std.mem.eql(u8, ide.id, primary_ide.id)) {
                    try selected_list.append(arena, ide);
                }
            }
        } else {
            var tok_it = std.mem.tokenizeScalar(u8, ides_arg.?, ',');
            while (tok_it.next()) |raw_id| {
                const clean_id = std.mem.trim(u8, raw_id, " \t");
                for (discovered) |ide| {
                    if (std.ascii.eqlIgnoreCase(ide.id, clean_id) and !std.mem.eql(u8, ide.id, primary_ide.id)) {
                        try selected_list.append(arena, ide);
                    }
                }
            }
        }

        const raw_store = store_arg orelse (if (existing_state) |es| es.storeDir else p.default_store_dir);
        store_dir = try paths.resolveUserInputPath(arena, io, raw_store);
    } else {
        const chosen_indices = try askManyIndices(
            arena,
            io,
            out,
            "Select IDEs to synchronize ('all', '1,2,5', '1-3', or '-4' to exclude)",
            discovered.len,
        );
        for (chosen_indices) |cidx| {
            try selected_list.append(arena, discovered[cidx]);
        }

        if (selected_list.items.len < discovered.len) {
            try out.writeAll("\nSelected IDEs for synchronization:\n");
            for (selected_list.items, 0..) |ide, idx| {
                try out.print("  [{d}] {s} ({s})\n", .{ idx + 1, ide.name, ide.id });
            }
            try out.writeByte('\n');
        }

        var default_primary_one_based: usize = 1;
        if (existing_state) |es| {
            for (selected_list.items, 0..) |ide, idx| {
                if (std.mem.eql(u8, ide.id, es.primaryIdeId)) {
                    default_primary_one_based = idx + 1;
                    break;
                }
            }
        }

        const primary_idx = if (selected_list.items.len == 1)
            0
        else
            try askOneIndex(
                arena,
                io,
                out,
                "Select primary (base) IDE configuration (number)",
                selected_list.items.len,
                default_primary_one_based,
            );
        primary_ide = selected_list.items[primary_idx];

        if (selected_list.items.len > 1) {
            merge_extensions = try askConfirm(
                arena,
                io,
                out,
                "Merge unique extensions from other selected IDEs into primary set?",
                merge_flag,
            );
        }

        const default_store = store_arg orelse (if (existing_state) |es| es.storeDir else p.default_store_dir);
        const store_input = try askPrompt(arena, io, out, "Central store directory", default_store);
        store_dir = try paths.resolveUserInputPath(arena, io, store_input);

        try out.print("\nPlan:\n  Primary IDE:      {s} ({s})\n  Target IDEs:      ", .{
            primary_ide.name,
            primary_ide.id,
        });
        for (selected_list.items, 0..) |ide, idx| {
            if (idx > 0) {
                try out.writeAll(", ");
            }
            try out.writeAll(ide.name);
        }
        try out.print(
            "\n  Merge extensions: {s}\n  Store directory:  {s}\n  Backups:          compressed .zip inside each IDE folder\n\n",
            .{ if (merge_extensions) "yes" else "no", store_dir },
        );

        if (!(try askConfirm(arena, io, out, "Proceed with backup & linking?", true))) {
            try out.writeAll("Aborted.\n");
            return;
        }
    }

    try out.writeAll("\nCreating .zip backups and linking configurations...\n");
    try out.flush();

    const summary = try syncer.initializeSync(arena, gpa, io, environ_map, .{
        .platform_paths = p,
        .selected_ides = selected_list.items,
        .primary_ide = primary_ide,
        .store_dir = store_dir,
        .merge_extensions = merge_extensions,
    });
    try printSyncSummary(out, summary);
}

fn handleSync(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    out: *Io.Writer,
    p: types.PlatformPaths,
    args: []const []const u8,
) !void {
    var store_arg: ?[]const u8 = null;
    var include_new = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--store")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            store_arg = try paths.resolveUserInputPath(arena, io, args[i]);
        } else if (std.mem.eql(u8, arg, "--include-new")) {
            include_new = true;
        } else {
            return error.UnknownOption;
        }
    }

    const summary = try syncer.runManualSync(arena, gpa, io, environ_map, p, store_arg, include_new);
    try printSyncSummary(out, summary);
}

fn handleExtension(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    out: *Io.Writer,
    p: types.PlatformPaths,
    args: []const []const u8,
) !void {
    var store_arg: ?[]const u8 = null;
    var list_flag = false;
    var force_flag = false;
    var to_install: std.ArrayList([]const u8) = .empty;
    var to_uninstall: std.ArrayList([]const u8) = .empty;
    var positionals: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--store")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            store_arg = try paths.resolveUserInputPath(arena, io, args[i]);
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list-extensions")) {
            list_flag = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force_flag = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--install-extension")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            try to_install.append(arena, args[i]);
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--uninstall-extension")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            try to_uninstall.append(arena, args[i]);
        } else {
            try positionals.append(arena, arg);
        }
    }

    const st = (try state_mod.loadState(arena, io, p, store_arg)) orelse return error.NotInitialized;
    const store = try paths.getStorePaths(arena, st.storeDir);
    const discovered = try discovery.discoverIdes(arena, io, p);

    if (positionals.items.len > 0) {
        const sub = positionals.items[0];
        const rest = positionals.items[1..];
        if (std.ascii.eqlIgnoreCase(sub, "list") or std.ascii.eqlIgnoreCase(sub, "ls")) {
            list_flag = true;
        } else if (std.ascii.eqlIgnoreCase(sub, "install") or std.ascii.eqlIgnoreCase(sub, "add")) {
            try to_install.appendSlice(arena, rest);
        } else if (std.ascii.eqlIgnoreCase(sub, "uninstall") or
            std.ascii.eqlIgnoreCase(sub, "remove") or
            std.ascii.eqlIgnoreCase(sub, "rm"))
        {
            try to_uninstall.appendSlice(arena, rest);
        } else {
            return error.UnknownExtensionAction;
        }
    }

    if (list_flag or (positionals.items.len == 0 and to_install.items.len == 0 and to_uninstall.items.len == 0)) {
        const list = try extensions.reconcileExtensionsManifest(arena, io, store.extensions_dir);
        try out.print("Shared extensions in {s} ({d}):\n", .{ store.extensions_dir, list.len });
        for (list) |item| {
            try out.print("  {s}@{s}\n", .{ item.id, item.version });
        }
        return;
    }

    if (to_install.items.len > 0) {
        try out.flush();
        try extensions.installExtensionsToStore(
            arena,
            io,
            environ_map,
            store.extensions_dir,
            to_install.items,
            discovered,
            force_flag,
        );
        try out.print("Installed {d} extension(s) into shared store.\n", .{to_install.items.len});
        return;
    }

    if (to_uninstall.items.len > 0) {
        try out.flush();
        const res = try extensions.uninstallExtensionsFromStore(
            arena,
            io,
            environ_map,
            store.extensions_dir,
            to_uninstall.items,
            discovered,
        );
        if (res.removed.len > 0) {
            try out.writeAll("Removed: ");
            for (res.removed, 0..) |id, idx| {
                if (idx > 0) try out.writeAll(", ");
                try out.writeAll(id);
            }
            try out.writeByte('\n');
        }
        if (res.not_found.len > 0) {
            try out.writeAll("Not found: ");
            for (res.not_found, 0..) |id, idx| {
                if (idx > 0) try out.writeAll(", ");
                try out.writeAll(id);
            }
            try out.writeByte('\n');
        }
    }
}

fn handleUnlink(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    p: types.PlatformPaths,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        return error.MissingUnlinkTarget;
    }

    const st = (try state_mod.loadState(arena, io, p, null)) orelse return error.NotInitialized;
    const store = try paths.getStorePaths(arena, st.storeDir);
    const discovered = try discovery.discoverIdes(arena, io, p);

    var unlink_all = false;
    for (args) |a| {
        if (std.ascii.eqlIgnoreCase(a, "all")) {
            unlink_all = true;
            break;
        }
    }

    var detached: std.StringHashMapUnmanaged(void) = .empty;
    for (discovered) |ide| {
        var match = false;
        if (unlink_all) {
            for (st.managedIdeIds) |mid| {
                if (std.mem.eql(u8, mid, ide.id)) {
                    match = true;
                    break;
                }
            }
        } else {
            for (args) |a| {
                if (std.ascii.eqlIgnoreCase(a, ide.id)) {
                    match = true;
                    break;
                }
            }
        }
        if (match) {
            try linker.unlinkIde(arena, io, ide, store);
            try detached.put(arena, ide.id, {});
            try out.print("Unlinked {s} ({s}) -> standalone copies restored.\n", .{ ide.name, ide.id });
        }
    }

    if (detached.count() == 0) {
        return error.NoMatchingIdeFound;
    }

    var remaining: std.ArrayList([]const u8) = .empty;
    for (st.managedIdeIds) |mid| {
        if (!detached.contains(mid)) {
            try remaining.append(arena, mid);
        }
    }

    try state_mod.saveState(arena, io, p, .{
        .version = 1,
        .storeDir = st.storeDir,
        .primaryIdeId = st.primaryIdeId,
        .managedIdeIds = try remaining.toOwnedSlice(arena),
        .mergeExtensions = st.mergeExtensions,
    });
}

const BackupsSubcommand = enum {
    list,
    create,
    clean,
};

fn appendCreatedZipInfo(
    arena: Allocator,
    io: Io,
    label: []const u8,
    zip_path_opt: ?[]const u8,
    out_list: *std.ArrayList(archive.BackupArchiveInfo),
) !void {
    const zp = zip_path_opt orelse return;
    const st = Io.Dir.cwd().statFile(io, zp, .{ .follow_symlinks = false }) catch return;
    try out_list.append(arena, .{
        .ide_name = label,
        .path = zp,
        .size = st.size,
    });
}

fn handleBackups(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    out: *Io.Writer,
    p: types.PlatformPaths,
    args: []const []const u8,
) !void {
    var force_flag = false;
    var store_arg: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force_flag = true;
        } else if (std.mem.eql(u8, arg, "--store")) {
            i += 1;
            if (i >= args.len) {
                return error.MissingOptionValue;
            }
            store_arg = try paths.resolveUserInputPath(arena, io, args[i]);
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.UnknownOption;
        } else {
            try positionals.append(arena, arg);
        }
    }

    var action: BackupsSubcommand = .list;
    var filter_slice: []const []const u8 = &.{};

    if (positionals.items.len > 0) {
        const sub = positionals.items[0];
        filter_slice = positionals.items[1..];
        if (std.ascii.eqlIgnoreCase(sub, "create") or
            std.ascii.eqlIgnoreCase(sub, "new") or
            std.ascii.eqlIgnoreCase(sub, "make") or
            std.ascii.eqlIgnoreCase(sub, "add"))
        {
            action = .create;
        } else if (std.ascii.eqlIgnoreCase(sub, "clean") or
            std.ascii.eqlIgnoreCase(sub, "rm") or
            std.ascii.eqlIgnoreCase(sub, "remove") or
            std.ascii.eqlIgnoreCase(sub, "delete") or
            std.ascii.eqlIgnoreCase(sub, "prune") or
            std.ascii.eqlIgnoreCase(sub, "clear"))
        {
            action = .clean;
        } else if (std.ascii.eqlIgnoreCase(sub, "list") or std.ascii.eqlIgnoreCase(sub, "ls")) {
            action = .list;
        } else {
            return error.UnknownBackupsAction;
        }
    }

    const st_opt = try state_mod.loadState(arena, io, p, store_arg);
    const effective_store_dir: ?[]const u8 = store_arg orelse if (st_opt) |s| s.storeDir else null;
    const discovered = try discovery.discoverIdes(arena, io, p);

    var all_mode = (filter_slice.len == 0);
    for (filter_slice) |flt| {
        if (std.ascii.eqlIgnoreCase(flt, "all")) {
            all_mode = true;
            break;
        }
    }

    var include_store = false;
    var targets: std.ArrayList(types.IdeInstallation) = .empty;

    if (all_mode) {
        include_store = (effective_store_dir != null);
        try targets.appendSlice(arena, discovered);
    } else {
        for (filter_slice) |flt| {
            if (std.ascii.eqlIgnoreCase(flt, "store")) {
                include_store = true;
            }
        }
        for (discovered) |ide| {
            for (filter_slice) |flt| {
                if (std.ascii.eqlIgnoreCase(ide.id, flt)) {
                    try targets.append(arena, ide);
                    break;
                }
            }
        }
        if (!include_store and targets.items.len == 0) {
            return error.NoMatchingIdeFound;
        }
    }

    switch (action) {
        .list => {
            const scan_store = if (include_store) effective_store_dir else null;
            const backups = try archive.findBackups(arena, io, targets.items, scan_store);
            if (backups.len == 0) {
                try out.writeAll("No syncide backup archives (.zip) found.\n");
                return;
            }

            var total_bytes: u64 = 0;
            for (backups) |b| {
                total_bytes += b.size;
            }
            var total_buf: [32]u8 = undefined;
            const total_str = paths.formatBytesBuf(total_bytes, &total_buf);
            try out.print("Found {d} backup archive(s) ({s} total):\n", .{ backups.len, total_str });
            for (backups) |b| {
                var sz_buf: [32]u8 = undefined;
                const sz_str = paths.formatBytesBuf(b.size, &sz_buf);
                try out.print("  * [{s:>8}] {s}\n", .{ sz_str, b.path });
            }
        },
        .clean => {
            const scan_store = if (include_store) effective_store_dir else null;
            const backups = try archive.findBackups(arena, io, targets.items, scan_store);
            if (backups.len == 0) {
                try out.writeAll("No syncide backup archives (.zip) found.\n");
                return;
            }

            var total_bytes: u64 = 0;
            for (backups) |b| {
                total_bytes += b.size;
            }

            var total_buf: [32]u8 = undefined;
            const total_str = paths.formatBytesBuf(total_bytes, &total_buf);
            try out.print("Found {d} backup archive(s) ({s} total):\n", .{ backups.len, total_str });

            for (backups) |b| {
                var sz_buf: [32]u8 = undefined;
                const sz_str = paths.formatBytesBuf(b.size, &sz_buf);
                try out.print("  - [{s:>8}] {s}\n", .{ sz_str, b.path });
            }
            try out.writeByte('\n');

            if (!force_flag) {
                const prompt_msg = try std.fmt.allocPrint(
                    arena,
                    "Permanently delete {d} backup archive(s) ({s})? This cannot be undone",
                    .{ backups.len, total_str },
                );
                if (!(try askConfirm(arena, io, out, prompt_msg, false))) {
                    try out.writeAll("Aborted. Backups kept intact.\n");
                    return;
                }
            }

            const res = archive.deleteBackupArchives(io, backups);
            var freed_buf: [32]u8 = undefined;
            const freed_str = paths.formatBytesBuf(res.freed_bytes, &freed_buf);
            try out.print("Deleted {d} backup archive(s), freed {s}.\n", .{ res.deleted_count, freed_str });
            if (res.failed_count > 0) {
                try out.print("Warning: Failed to delete {d} archive(s).\n", .{res.failed_count});
            }
        },
        .create => {
            try out.writeAll("Creating compressed .zip backups...\n");
            try out.flush();

            const ts = try archive.makeTimestampSlugAlloc(arena, io);
            const sp_opt: ?types.StorePaths = if (effective_store_dir) |sd|
                try paths.getStorePaths(arena, sd)
            else
                null;

            var created: std.ArrayList(archive.BackupArchiveInfo) = .empty;

            if (all_mode) {
                if (sp_opt) |sp| {
                    const st_user = try archive.backupStoreUserConfig(arena, gpa, io, environ_map, sp, ts);
                    try appendCreatedZipInfo(arena, io, "shared store", st_user, &created);

                    const st_ext = try archive.backupStoreExtensions(arena, gpa, io, environ_map, sp, ts);
                    try appendCreatedZipInfo(arena, io, "shared store", st_ext, &created);

                    for (targets.items) |ide| {
                        const rep = linker.inspectIdeLinks(arena, io, ide, sp);
                        const skip_shared = rep.settings_state == .linked or
                            rep.settings_state == .hardlinked or
                            rep.keybindings_state == .linked or
                            rep.keybindings_state == .hardlinked;

                        const u_zip = try archive.backupIdeUserConfigCustom(
                            arena,
                            gpa,
                            io,
                            environ_map,
                            ide,
                            ts,
                            false,
                            skip_shared,
                        );
                        try appendCreatedZipInfo(arena, io, ide.name, u_zip, &created);

                        const e_zip = try archive.backupIdeExtensionsCustom(
                            arena,
                            gpa,
                            io,
                            environ_map,
                            ide,
                            sp,
                            ts,
                            false,
                        );
                        try appendCreatedZipInfo(arena, io, ide.name, e_zip, &created);
                    }
                } else {
                    for (targets.items) |ide| {
                        const u_zip = try archive.backupIdeUserConfig(arena, gpa, io, environ_map, ide, ts);
                        try appendCreatedZipInfo(arena, io, ide.name, u_zip, &created);

                        const e_zip = try archive.backupIdeExtensions(arena, gpa, io, environ_map, ide, ts);
                        try appendCreatedZipInfo(arena, io, ide.name, e_zip, &created);
                    }
                }
            } else {
                if (include_store) {
                    const sp = sp_opt orelse return error.NotInitialized;
                    const st_user = try archive.backupStoreUserConfig(arena, gpa, io, environ_map, sp, ts);
                    try appendCreatedZipInfo(arena, io, "shared store", st_user, &created);

                    const st_ext = try archive.backupStoreExtensions(arena, gpa, io, environ_map, sp, ts);
                    try appendCreatedZipInfo(arena, io, "shared store", st_ext, &created);
                }

                for (targets.items) |ide| {
                    const u_zip = try archive.backupIdeUserConfigCustom(
                        arena,
                        gpa,
                        io,
                        environ_map,
                        ide,
                        ts,
                        true,
                        false,
                    );
                    try appendCreatedZipInfo(arena, io, ide.name, u_zip, &created);

                    const e_zip = try archive.backupIdeExtensionsCustom(
                        arena,
                        gpa,
                        io,
                        environ_map,
                        ide,
                        sp_opt,
                        ts,
                        true,
                    );
                    try appendCreatedZipInfo(arena, io, ide.name, e_zip, &created);
                }
            }

            if (created.items.len == 0) {
                try out.writeAll("No configurations or extensions found to back up.\n");
                return;
            }

            var total_bytes: u64 = 0;
            for (created.items) |item| {
                total_bytes += item.size;
            }
            var total_buf: [32]u8 = undefined;
            const total_str = paths.formatBytesBuf(total_bytes, &total_buf);
            try out.print("Created {d} backup archive(s) ({s} total):\n", .{
                created.items.len,
                total_str,
            });
            for (created.items) |item| {
                var sz_buf: [32]u8 = undefined;
                const sz_str = paths.formatBytesBuf(item.size, &sz_buf);
                try out.print("  + [{s:>8}] {s}\n", .{ sz_str, item.path });
            }
        },
    }
}

fn handleUpdate(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    var opts: updater.UpdateOptions = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            opts.check_only = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            i += 1;
            if (i >= args.len) {
                return error.MissingOptionValue;
            }
            opts.target_version = args[i];
        } else {
            return error.UnknownOption;
        }
    }

    try updater.runSelfUpdate(arena, io, environ_map, out, opts);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    updater.cleanupOldExecutable(arena, io);

    const raw_args = try init.minimal.args.toSlice(arena);
    const cli_args = if (raw_args.len > 1) raw_args[1..] else &[_][]const u8{};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    for (cli_args) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "help")) {
            try printHelp(out);
            try out.flush();
            return;
        }
    }

    if (cli_args.len == 1 and
        (std.mem.eql(u8, cli_args[0], "-v") or
            std.mem.eql(u8, cli_args[0], "--version") or
            std.ascii.eqlIgnoreCase(cli_args[0], "version")))
    {
        try out.print("syncide {s}\n", .{updater.VERSION});
        try out.flush();
        return;
    }

    const p = try paths.resolvePlatformPaths(arena, init.environ_map, .{});
    const cmd = if (cli_args.len > 0) cli_args[0] else "status";
    const rest = if (cli_args.len > 1) cli_args[1..] else &[_][]const u8{};

    const runResult: anyerror!void = blk: {
        if (std.ascii.eqlIgnoreCase(cmd, "init") or std.ascii.eqlIgnoreCase(cmd, "setup")) {
            break :blk handleInit(arena, gpa, io, init.environ_map, out, p, rest);
        } else if (std.ascii.eqlIgnoreCase(cmd, "status") or std.ascii.eqlIgnoreCase(cmd, "scan")) {
            const ides = try discovery.discoverIdes(arena, io, p);
            break :blk printStatusTable(arena, io, out, p, ides);
        } else if (std.ascii.eqlIgnoreCase(cmd, "sync")) {
            break :blk handleSync(arena, gpa, io, init.environ_map, out, p, rest);
        } else if (std.ascii.eqlIgnoreCase(cmd, "extension") or
            std.ascii.eqlIgnoreCase(cmd, "extensions") or
            std.ascii.eqlIgnoreCase(cmd, "ext"))
        {
            break :blk handleExtension(arena, io, init.environ_map, out, p, rest);
        } else if (std.ascii.eqlIgnoreCase(cmd, "backups") or std.ascii.eqlIgnoreCase(cmd, "backup")) {
            break :blk handleBackups(arena, gpa, io, init.environ_map, out, p, rest);
        } else if (std.ascii.eqlIgnoreCase(cmd, "update") or
            std.ascii.eqlIgnoreCase(cmd, "self-update") or
            std.ascii.eqlIgnoreCase(cmd, "upgrade"))
        {
            break :blk handleUpdate(arena, io, init.environ_map, out, rest);
        } else if (std.ascii.eqlIgnoreCase(cmd, "unlink")) {
            break :blk handleUnlink(arena, io, out, p, rest);
        } else {
            try out.flush();
            std.debug.print("Error: Unknown command '{s}'. Run 'syncide --help' for usage.\n", .{cmd});
            std.process.exit(1);
        }
    };

    runResult catch |err| {
        try out.flush();
        if (err == error.NotInitialized) {
            std.debug.print("Error: syncide is not initialized yet. Run 'syncide init' first.\n", .{});
        } else if (err == error.UnknownBackupsAction) {
            std.debug.print(
                "Error: Unknown backups subcommand. Expected 'syncide backups create', 'syncide backups clean', or 'syncide backups list'.\n",
                .{},
            );
        } else if (err == error.UpdatePermissionDenied) {
            std.debug.print(
                "Error: Permission denied updating syncide executable. Re-run from an elevated terminal (or sudo).\n",
                .{},
            );
        } else if (err == error.ChecksumMismatch) {
            std.debug.print("Error: SHA-256 checksum verification failed! Aborting update.\n", .{});
        } else {
            std.debug.print("Error: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };

    try out.flush();
}

test "parseSelectionIndicesAlloc supports all, ranges, lists, and exclusions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const def_all = try parseSelectionIndicesAlloc(arena, "", 5);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, def_all);

    const explicit_all = try parseSelectionIndicesAlloc(arena, "all", 4);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, explicit_all);

    const ranges = try parseSelectionIndicesAlloc(arena, "1-3, 5", 5);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4 }, ranges);

    const excluded = try parseSelectionIndicesAlloc(arena, "-3, -4", 5);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4 }, excluded);
}

