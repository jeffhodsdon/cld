const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Library modules (no dependencies) ──────────────────────────────

    const message_mod = b.createModule(.{ .root_source_file = b.path("src/message.zig") });
    const cmd_mod = b.createModule(.{ .root_source_file = b.path("src/Cmd.zig") });
    const memory_mod = b.createModule(.{ .root_source_file = b.path("src/memory.zig") });
    const uuid_mod = b.createModule(.{ .root_source_file = b.path("src/Uuid.zig") });
    const config_mod = b.createModule(.{ .root_source_file = b.path("src/Config.zig") });
    const prompts_mod = b.createModule(.{ .root_source_file = b.path("src/prompts.zig") });
    prompts_mod.addAnonymousImport("system_prompt", .{ .root_source_file = b.path("prompts/system.md") });
    prompts_mod.addAnonymousImport("summarize_prompt", .{ .root_source_file = b.path("prompts/summarize.md") });

    // ── Library modules (with dependencies) ────────────────────────────

    const process_mod = b.createModule(.{ .root_source_file = b.path("src/Process.zig") });
    process_mod.addImport("Cmd", cmd_mod);

    const pool_mod = b.createModule(.{ .root_source_file = b.path("src/ProcessPool.zig") });
    pool_mod.addImport("Cmd", cmd_mod);
    pool_mod.addImport("Process", process_mod);

    const adapter_mod = b.createModule(.{ .root_source_file = b.path("src/adapter.zig") });
    adapter_mod.addImport("message", message_mod);

    const imessage_mod = b.createModule(.{ .root_source_file = b.path("src/adapter/imessage.zig") });
    imessage_mod.addImport("adapter", adapter_mod);
    imessage_mod.addImport("message", message_mod);
    imessage_mod.addImport("Cmd", cmd_mod);
    imessage_mod.addImport("ProcessPool", pool_mod);

    const provider_mod = b.createModule(.{ .root_source_file = b.path("src/provider.zig") });
    provider_mod.addImport("message", message_mod);

    const claude_mod = b.createModule(.{ .root_source_file = b.path("src/provider/claude.zig") });
    claude_mod.addImport("provider", provider_mod);
    claude_mod.addImport("message", message_mod);
    claude_mod.addImport("Cmd", cmd_mod);
    claude_mod.addImport("ProcessPool", pool_mod);
    claude_mod.addImport("Uuid", uuid_mod);

    // ── Executable ─────────────────────────────────────────────────────

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("Config", config_mod);
    exe_mod.addImport("imessage", imessage_mod);
    exe_mod.addImport("claude", claude_mod);
    exe_mod.addImport("memory", memory_mod);
    exe_mod.addImport("prompts", prompts_mod);
    exe_mod.addImport("ProcessPool", pool_mod);
    exe_mod.addImport("Cmd", cmd_mod);
    exe_mod.addImport("message", message_mod);

    const exe = b.addExecutable(.{
        .name = "cld",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run cld");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ──────────────────────────────────────────────────────────

    const test_step = b.step("test", "Run unit tests");

    // No-dependency tests
    addTestTarget(b, test_step, "cmd", b.path("src/Cmd.zig"), target, optimize, &.{});
    addTestTarget(b, test_step, "config", b.path("src/Config.zig"), target, optimize, &.{});
    addTestTarget(b, test_step, "uuid", b.path("src/Uuid.zig"), target, optimize, &.{});
    addTestTarget(b, test_step, "memory", b.path("src/memory.zig"), target, optimize, &.{});

    // Process -> Cmd
    addTestTarget(b, test_step, "process", b.path("src/Process.zig"), target, optimize, &.{
        .{ .name = "Cmd", .module = cmd_mod },
    });

    // ProcessPool -> Cmd, Process
    addTestTarget(b, test_step, "process_pool", b.path("src/ProcessPool.zig"), target, optimize, &.{
        .{ .name = "Cmd", .module = cmd_mod },
        .{ .name = "Process", .module = process_mod },
    });

    // imessage -> adapter, message, Cmd, ProcessPool
    addTestTarget(b, test_step, "imessage", b.path("src/adapter/imessage.zig"), target, optimize, &.{
        .{ .name = "adapter", .module = adapter_mod },
        .{ .name = "message", .module = message_mod },
        .{ .name = "Cmd", .module = cmd_mod },
        .{ .name = "ProcessPool", .module = pool_mod },
    });

    // claude -> provider, message, Cmd, ProcessPool, Uuid
    addTestTarget(b, test_step, "claude", b.path("src/provider/claude.zig"), target, optimize, &.{
        .{ .name = "provider", .module = provider_mod },
        .{ .name = "message", .module = message_mod },
        .{ .name = "Cmd", .module = cmd_mod },
        .{ .name = "ProcessPool", .module = pool_mod },
        .{ .name = "Uuid", .module = uuid_mod },
    });
}

const Import = struct {
    name: []const u8,
    module: *std.Build.Module,
};

fn addTestTarget(
    b: *std.Build,
    test_step: *std.Build.Step,
    comptime name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const Import,
) void {
    const mod = b.createModule(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (imports) |imp| {
        mod.addImport(imp.name, imp.module);
    }

    const unit_test = b.addTest(.{ .root_module = mod });
    const run = b.addRunArtifact(unit_test);
    test_step.dependOn(&run.step);
    b.step("test-" ++ name, "Run " ++ name ++ " tests").dependOn(&run.step);
}
