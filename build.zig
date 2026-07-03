const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util = b.addModule("forge-util", .{
        .root_source_file = b.path("packages/util/src/root.zig"),
        .target = target,
    });
    const core = b.addModule("forge-core", .{
        .root_source_file = b.path("packages/core/src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "forge-util", .module = util }},
    });
    const kernel = b.addModule("forge-kernel", .{
        .root_source_file = b.path("packages/kernel/src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "forge-core", .module = core }},
    });
    const workspace = b.addModule("forge-workspace", .{
        .root_source_file = b.path("packages/workspace/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "forge-core", .module = core },
            .{ .name = "forge-util", .module = util },
        },
    });
    const editor = b.addModule("forge-editor", .{
        .root_source_file = b.path("packages/editor/src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "forge-core", .module = core }},
    });
    const renderer = b.addModule("forge-renderer", .{
        .root_source_file = b.path("packages/renderer/src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "forge-core", .module = core }},
    });
    renderer.addIncludePath(b.path("packages/renderer/src/platform/mac"));
    renderer.addCSourceFile(.{
        .file = b.path("packages/renderer/src/platform/mac/mac_window.m"),
        .flags = &.{"-fobjc-arc"},
    });
    renderer.linkFramework("AppKit", .{});
    renderer.linkFramework("Metal", .{});
    renderer.linkFramework("MetalKit", .{});
    renderer.linkFramework("CoreGraphics", .{});
    renderer.linkFramework("CoreText", .{});
    renderer.linkFramework("CoreFoundation", .{});
    renderer.linkSystemLibrary("objc", .{});
    renderer.linkSystemLibrary("c", .{});
    const lsp = b.addModule("forge-lsp", .{
        .root_source_file = b.path("packages/lsp/src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "forge-core", .module = core }},
    });
    const ai = b.addModule("forge-ai", .{
        .root_source_file = b.path("packages/ai/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "forge-core", .module = core },
            .{ .name = "forge-kernel", .module = kernel },
        },
    });
    const plugin = b.addModule("forge-plugin", .{
        .root_source_file = b.path("packages/plugin/src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "forge-core", .module = core }},
    });

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
            },
        }),
    });
    b.installArtifact(cli);

    const ide = b.addExecutable(.{
        .name = "forge-ide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/forge-ide/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "forge-core", .module = core },
                .{ .name = "forge-kernel", .module = kernel },
                .{ .name = "forge-workspace", .module = workspace },
                .{ .name = "forge-renderer", .module = renderer },
            },
        }),
    });
    b.installArtifact(ide);

    const run_cmd = b.addRunArtifact(cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_ide_cmd = b.addRunArtifact(ide);
    run_ide_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_ide_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Forge CLI");
    run_step.dependOn(&run_cmd.step);

    const run_ide_step = b.step("run-ide", "Run the Forge IDE");
    run_ide_step.dependOn(&run_ide_cmd.step);

    // --- Renderer Spike ---
    const spike = b.addExecutable(.{
        .name = "renderer-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/renderer-spike/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add include paths for C headers
    spike.root_module.addIncludePath(b.path("tools/renderer-spike/src"));

    // Compile Objective-C Window Implementation
    spike.root_module.addCSourceFile(.{
        .file = b.path("tools/renderer-spike/src/mac_window.m"),
        .flags = &.{"-fobjc-arc"},
    });

    // Link macOS frameworks
    spike.root_module.linkFramework("AppKit", .{});
    spike.root_module.linkFramework("Metal", .{});
    spike.root_module.linkFramework("MetalKit", .{});
    spike.root_module.linkFramework("CoreGraphics", .{});
    spike.root_module.linkFramework("CoreText", .{});
    spike.root_module.linkFramework("CoreFoundation", .{});
    spike.root_module.linkSystemLibrary("objc", .{});
    spike.root_module.linkSystemLibrary("c", .{});

    b.installArtifact(spike);

    const run_spike_cmd = b.addRunArtifact(spike);
    run_spike_cmd.step.dependOn(b.getInstallStep());

    const run_spike_step = b.step("run-spike", "Run the Renderer Spike");
    run_spike_step.dependOn(&run_spike_cmd.step);

    const test_step = b.step("test", "Run all unit tests");
    const modules = [_]*std.Build.Module{
        util, core, kernel, workspace, editor, renderer, lsp, ai, plugin,
    };
    for (modules) |module| {
        const module_tests = b.addTest(.{ .root_module = module });
        const run_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_tests.step);
    }

    const cli_tests = b.addTest(.{ .root_module = cli.root_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);
}
