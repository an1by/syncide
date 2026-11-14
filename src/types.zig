const std = @import("std");

pub const LinkState = enum {
    linked,
    hardlinked,
    linked_other,
    unlinked_real,
    broken,
    missing,

    pub fn badge(self: LinkState) []const u8 {
        return switch (self) {
            .linked => "LINKED",
            .hardlinked => "HARDLINK",
            .linked_other => "OTHER_LINK",
            .unlinked_real => "LOCAL",
            .broken => "BROKEN",
            .missing => "MISSING",
        };
    }
};

pub const IdeSpec = struct {
    id: []const u8,
    name: []const u8,
    config_dir_name: []const u8,
    dot_dir_name: []const u8,
    cli_names: []const []const u8,
};

pub const IdeInstallation = struct {
    id: []const u8,
    name: []const u8,
    app_dir: []const u8,
    user_dir: []const u8,
    settings_path: []const u8,
    keybindings_path: []const u8,
    dot_dir: []const u8,
    extensions_dir: []const u8,
    cli_names: []const []const u8,
    has_settings: bool,
    settings_size: u64,
    has_keybindings: bool,
    keybindings_size: u64,
    extensions_count: usize,
};

pub const IdeLinkReport = struct {
    settings_state: LinkState,
    keybindings_state: LinkState,
    extensions_state: LinkState,
};

pub const SyncState = struct {
    version: u32 = 1,
    storeDir: []const u8,
    primaryIdeId: []const u8,
    managedIdeIds: []const []const u8,
    mergeExtensions: bool = false,
};

pub const PlatformPaths = struct {
    home_dir: []const u8,
    app_config_root: []const u8,
    default_store_dir: []const u8,
    bootstrap_state_path: []const u8,
};

pub const StorePaths = struct {
    store_dir: []const u8,
    user_dir: []const u8,
    settings_path: []const u8,
    keybindings_path: []const u8,
    extensions_dir: []const u8,
    state_path: []const u8,
};
