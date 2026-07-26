pub const SidebarView = enum {
    explorer,
    search,
    git,
    run,
    extensions,
    ai,
    outline,
    specs,
    runs,
};

pub const all = [_]SidebarView{ .explorer, .search, .git, .run, .extensions, .ai, .outline, .specs, .runs };
