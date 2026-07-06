pub const SidebarView = enum {
    explorer,
    search,
    git,
    run,
    extensions,
    ai,
};

pub const all = [_]SidebarView{ .explorer, .search, .git, .run, .extensions, .ai };
