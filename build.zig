const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const with_plugin = b.option(bool, "with-plugin", "Build the WASM plugin runtime (requires LLVM backend)") orelse (optimize != .Debug);
    const zware_dep = b.dependency("zware", .{
        .target = target,
        .optimize = optimize,
    });
    const zware: ?*std.Build.Module = if (with_plugin) zware_dep.module("zware") else null;

    const util = b.addModule("forge-util", .{
        .root_source_file = b.path("packages/util/src/root.zig"),
        .target = target,
    });
    util.addIncludePath(b.path("packages/util/src"));
    util.addCSourceFile(.{
        .file = b.path("packages/util/src/process_spawn.c"),
        .flags = &.{},
    });
    util.linkSystemLibrary("c", .{});
    const core = b.addModule("forge-core", .{
        .root_source_file = b.path("packages/core/src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "forge-util", .module = util }},
    });
    core.linkSystemLibrary("c", .{});
    const kernel = b.addModule("forge-kernel", .{
        .root_source_file = b.path("packages/kernel/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "forge-core", .module = core },
            .{ .name = "forge-util", .module = util },
        },
    });
    const workspace = b.addModule("forge-workspace", .{
        .root_source_file = b.path("packages/workspace/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "forge-core", .module = core },
            .{ .name = "forge-kernel", .module = kernel },
            .{ .name = "forge-util", .module = util },
        },
    });
    workspace.addIncludePath(b.path("third_party/tree-sitter/lib/include"));
    workspace.addIncludePath(b.path("third_party/tree-sitter-python/src"));
    workspace.addIncludePath(b.path("third_party/tree-sitter-typescript/typescript/src"));
    workspace.addIncludePath(b.path("third_party/tree-sitter-typescript/tsx/src"));
    workspace.addCSourceFile(.{
        .file = b.path("third_party/tree-sitter/lib/src/lib.c"),
        .flags = &.{"-std=c11"},
    });
    workspace.addCSourceFile(.{
        .file = b.path("third_party/tree-sitter-python/src/parser.c"),
        .flags = &.{"-std=c11"},
    });
    workspace.addCSourceFile(.{
        .file = b.path("third_party/tree-sitter-python/src/scanner.c"),
        .flags = &.{"-std=c11"},
    });
    workspace.addCSourceFile(.{
        .file = b.path("third_party/tree-sitter-typescript/typescript/src/parser.c"),
        .flags = &.{"-std=c11"},
    });
    workspace.addCSourceFile(.{
        .file = b.path("third_party/tree-sitter-typescript/typescript/src/scanner.c"),
        .flags = &.{"-std=c11"},
    });
    workspace.addCSourceFile(.{
        .file = b.path("third_party/tree-sitter-typescript/tsx/src/parser.c"),
        .flags = &.{"-std=c11"},
    });
    workspace.addCSourceFile(.{
        .file = b.path("third_party/tree-sitter-typescript/tsx/src/scanner.c"),
        .flags = &.{"-std=c11"},
    });
    workspace.linkSystemLibrary("c", .{});
    const editor = b.addModule("forge-editor", .{
        .root_source_file = b.path("packages/editor/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "forge-core", .module = core },
            .{ .name = "forge-workspace", .module = workspace },
        },
    });
    const renderer = b.addModule("forge-renderer", .{
        .root_source_file = b.path("packages/renderer/src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "forge-core", .module = core }},
    });
    renderer.addIncludePath(b.path("packages/renderer/src/platform"));
    renderer.addIncludePath(b.path("packages/renderer/src/platform/shared"));
    renderer.addIncludePath(b.path("packages/renderer/src/platform/mac"));
    renderer.linkSystemLibrary("c", .{});

    switch (target.result.os.tag) {
        .macos => {
            renderer.addCSourceFile(.{
                .file = b.path("packages/renderer/src/platform/mac/mac_window.m"),
                .flags = &.{ "-fobjc-arc", "-ObjC" },
            });
            renderer.addCSourceFile(.{
                .file = b.path("packages/renderer/src/platform/mac/mac_backend_shim.c"),
                .flags = &.{},
            });
            renderer.linkFramework("AppKit", .{});
            renderer.linkFramework("Metal", .{});
            renderer.linkFramework("MetalKit", .{});
            renderer.linkFramework("CoreGraphics", .{});
            renderer.linkFramework("CoreText", .{});
            renderer.linkFramework("CoreFoundation", .{});
            renderer.linkFramework("QuartzCore", .{});
            renderer.linkSystemLibrary("objc", .{});
        },
        .linux => {
            renderer.addCSourceFile(.{
                .file = b.path("packages/renderer/src/platform/linux/x11_window.c"),
                .flags = &.{},
            });
            renderer.linkSystemLibrary("X11", .{});
            renderer.linkSystemLibrary("Xext", .{});
            renderer.linkSystemLibrary("freetype", .{});
            renderer.linkSystemLibrary("fontconfig", .{});
        },
        .windows => {
            renderer.addCSourceFile(.{
                .file = b.path("packages/renderer/src/platform/windows/win32_window.c"),
                .flags = &.{},
            });
            renderer.addIncludePath(b.path("packages/renderer/src/platform/windows"));
            renderer.linkSystemLibrary("gdi32", .{});
            renderer.linkSystemLibrary("user32", .{});
            renderer.linkSystemLibrary("shell32", .{});
        },
        else => {},
    }
    const lsp = b.addModule("forge-lsp", .{
        .root_source_file = b.path("packages/lsp/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "forge-core", .module = core },
            .{ .name = "forge-util", .module = util },
        },
    });
    const ai = b.addModule("forge-ai", .{
        .root_source_file = b.path("packages/ai/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "forge-core", .module = core },
            .{ .name = "forge-kernel", .module = kernel },
            .{ .name = "forge-workspace", .module = workspace },
            .{ .name = "forge-util", .module = util },
        },
    });
    const plugin: *std.Build.Module = if (with_plugin) blk: {
        const p = b.addModule("forge-plugin", .{
            .root_source_file = b.path("packages/plugin/src/root.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "forge-core", .module = core },
                .{ .name = "forge-util", .module = util },
                .{ .name = "forge-workspace", .module = workspace },
                .{ .name = "zware", .module = zware.? },
            },
        });
        break :blk p;
    } else blk: {
        const p = b.addModule("forge-plugin", .{
            .root_source_file = b.path("packages/plugin/src/stub.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "forge-workspace", .module = workspace },
            },
        });
        break :blk p;
    };

    const cli = b.addExecutable(.{
        .name = "forge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/forge-cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "forge-core", .module = core },
                .{ .name = "forge-kernel", .module = kernel },
                .{ .name = "forge-workspace", .module = workspace },
                .{ .name = "forge-ai", .module = ai },
                .{ .name = "forge-plugin", .module = plugin },
                .{ .name = "forge-editor", .module = editor },
                .{ .name = "forge-util", .module = util },
            },
        }),
    });
    b.installArtifact(cli);

    const run_cmd = b.addRunArtifact(cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Forge CLI");
    run_step.dependOn(&run_cmd.step);

    // Forge IDE builds on macOS, Linux, and Windows.
    // When with_plugin=false, a stub plugin module is used so the IDE can
    // compile without zware (which requires the LLVM backend).
    var ide: ?*std.Build.Step.Compile = null;
    var run_ide_cmd: ?*std.Build.Step.Run = null;
    if (target.result.os.tag == .macos or target.result.os.tag == .linux or target.result.os.tag == .windows) {
        const ide_exe = b.addExecutable(.{
            .name = "forge-ide",
            .root_module = b.createModule(.{
                .root_source_file = b.path("apps/forge-ide/src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "forge-core", .module = core },
                    .{ .name = "forge-kernel", .module = kernel },
                    .{ .name = "forge-workspace", .module = workspace },
                    .{ .name = "forge-editor", .module = editor },
                    .{ .name = "forge-renderer", .module = renderer },
                    .{ .name = "forge-plugin", .module = plugin },
                    .{ .name = "forge-lsp", .module = lsp },
                    .{ .name = "forge-ai", .module = ai },
                    .{ .name = "forge-util", .module = util },
                },
            }),
        });
        b.installArtifact(ide_exe);
        ide_exe.root_module.linkSystemLibrary("c", .{});
        ide_exe.root_module.addIncludePath(b.path("apps/forge-ide/src/platform"));
        if (target.result.os.tag == .macos or target.result.os.tag == .linux or target.result.os.tag == .windows) {
            ide_exe.root_module.addCSourceFile(.{
                .file = b.path("apps/forge-ide/src/platform/pty_spawn.c"),
                .flags = &.{},
            });
            if (target.result.os.tag == .linux) {
                ide_exe.root_module.linkSystemLibrary("util", .{});
            }
            if (target.result.os.tag == .windows) {
                ide_exe.root_module.linkSystemLibrary("gdi32", .{});
                ide_exe.root_module.linkSystemLibrary("user32", .{});
                ide_exe.root_module.linkSystemLibrary("shell32", .{});
            }
        }
        const run_ide = b.addRunArtifact(ide_exe);
        run_ide.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_ide.addArgs(args);
        ide = ide_exe;
        run_ide_cmd = run_ide;
    }

    const run_ide_step = b.step("run-ide", "Run the Forge IDE");
    if (run_ide_cmd) |cmd| run_ide_step.dependOn(&cmd.step);

    // --- Renderer Spike (macOS-only experimental tool) ---
    if (target.result.os.tag == .macos) {
        const spike = b.addExecutable(.{
            .name = "renderer-spike",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/renderer-spike/src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        spike.root_module.addIncludePath(b.path("tools/renderer-spike/src"));
        spike.root_module.addCSourceFile(.{
            .file = b.path("tools/renderer-spike/src/mac_window.m"),
            .flags = &.{"-fobjc-arc"},
        });
        spike.root_module.linkFramework("AppKit", .{});
        spike.root_module.linkFramework("Metal", .{});
        spike.root_module.linkFramework("MetalKit", .{});
        spike.root_module.linkFramework("CoreGraphics", .{});
        spike.root_module.linkFramework("CoreText", .{});
        spike.root_module.linkFramework("CoreFoundation", .{});
        spike.root_module.linkFramework("QuartzCore", .{});
        spike.root_module.linkSystemLibrary("objc", .{});
        spike.root_module.linkSystemLibrary("c", .{});
        b.installArtifact(spike);
        const run_spike_cmd = b.addRunArtifact(spike);
        run_spike_cmd.step.dependOn(b.getInstallStep());
        const run_spike_step = b.step("run-spike", "Run the Renderer Spike");
        run_spike_step.dependOn(&run_spike_cmd.step);
    }

    const test_step = b.step("test", "Run all unit tests");
    var modules: std.ArrayList(*std.Build.Module) = .empty;
    var module_names: std.ArrayList([]const u8) = .empty;
    modules.append(b.allocator, util) catch unreachable;
    module_names.append(b.allocator, "util") catch unreachable;
    modules.append(b.allocator, core) catch unreachable;
    module_names.append(b.allocator, "core") catch unreachable;
    modules.append(b.allocator, kernel) catch unreachable;
    module_names.append(b.allocator, "kernel") catch unreachable;
    modules.append(b.allocator, workspace) catch unreachable;
    module_names.append(b.allocator, "workspace") catch unreachable;
    modules.append(b.allocator, editor) catch unreachable;
    module_names.append(b.allocator, "editor") catch unreachable;
    modules.append(b.allocator, renderer) catch unreachable;
    module_names.append(b.allocator, "renderer") catch unreachable;
    modules.append(b.allocator, lsp) catch unreachable;
    module_names.append(b.allocator, "lsp") catch unreachable;
    modules.append(b.allocator, ai) catch unreachable;
    module_names.append(b.allocator, "ai") catch unreachable;
    if (with_plugin) {
        modules.append(b.allocator, plugin) catch unreachable;
        module_names.append(b.allocator, "plugin") catch unreachable;
    }
    for (modules.items, module_names.items) |module, module_name| {
        const module_tests = b.addTest(.{ .root_module = module });
        if (module == util or module == kernel or module == lsp or module == ai) {
            module_tests.root_module.linkSystemLibrary("c", .{});
        }
        const run_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_tests.step);
        const named_test_step = b.step(b.fmt("test-{s}", .{module_name}), b.fmt("Run {s} package tests", .{module_name}));
        named_test_step.dependOn(&run_tests.step);
    }

    const cli_tests = b.addTest(.{ .root_module = cli.root_module });
    cli_tests.root_module.linkSystemLibrary("c", .{});
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);
    const test_cli_step = b.step("test-cli", "Run Forge CLI tests");
    test_cli_step.dependOn(&run_cli_tests.step);

    if (ide) |ide_exe| {
        const ide_tests = b.addTest(.{ .root_module = ide_exe.root_module });
        ide_tests.root_module.linkSystemLibrary("c", .{});
        const run_ide_tests = b.addRunArtifact(ide_tests);
        test_step.dependOn(&run_ide_tests.step);
        const test_ide_step = b.step("test-ide", "Run Forge IDE tests");
        test_ide_step.dependOn(&run_ide_tests.step);
    }

    // --- Contract tests (black-box CLI) ---
    // contract_test.zig spawns the real forge binary, so it needs the binary built first.
    const contract_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/forge-cli/src/contract_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    contract_tests.root_module.linkSystemLibrary("c", .{});
    const run_contract_tests = b.addRunArtifact(contract_tests);
    run_contract_tests.step.dependOn(b.getInstallStep()); // binary must be built first
    const test_contracts_step = b.step("test-contracts", "Run Forge CLI black-box contract tests");
    test_contracts_step.dependOn(&run_contract_tests.step);
}
