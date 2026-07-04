pub const SidebarView = enum {
    explorer,
    search,
    git,
    run,
    extensions,
};

pub const all = [_]SidebarView{ .explorer, .search, .git, .run, .extensions };
