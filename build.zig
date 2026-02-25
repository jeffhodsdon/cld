const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Library modules (no dependencies) ──────────────────────────────

    const message_mod = b.createModule(.{ .root_source_file = b.path("src/message.zig") });
    const cmd_mod = b.createModule(.{ .root_source_file = b.path("src/proc/Cmd.zig") });
    const memory_mod = b.createModule(.{ .root_source_file = b.path("src/Memory.zig") });
    const uuid_mod = b.createModule(.{ .root_source_file = b.path("src/Uuid.zig") });
    const config_mod = b.createModule(.{ .root_source_file = b.path("src/Config.zig") });
    const prompts_mod = b.createModule(.{ .root_source_file = b.path("src/prompts.zig") });
    prompts_mod.addAnonymousImport("system_prompt", .{ .root_source_file = b.path("prompts/system.md") });
    prompts_mod.addAnonymousImport("compact_prompt", .{ .root_source_file = b.path("prompts/compact.md") });
    prompts_mod.addAnonymousImport("memory_prompt", .{ .root_source_file = b.path("prompts/memory.md") });

    // ── Library modules (with dependencies) ────────────────────────────

    const process_mod = b.createModule(.{ .root_source_file = b.path("src/proc/Process.zig") });
    process_mod.addImport("Cmd", cmd_mod);

    const pool_mod = b.createModule(.{ .root_source_file = b.path("src/proc/ProcessPool.zig") });
    pool_mod.addImport("Cmd", cmd_mod);
    pool_mod.addImport("Process", process_mod);

    const adapter_mod = b.createModule(.{ .root_source_file = b.path("src/adapter.zig") });
    adapter_mod.addImport("message", message_mod);

    const imessage_mod = b.createModule(.{ .root_source_file = b.path("src/adapter/IMessage.zig") });
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
    claude_mod.addImport("Memory", memory_mod);
    claude_mod.addImport("prompts", prompts_mod);

    const scheduler_mod = b.createModule(.{
        .root_source_file = b.path("src/Scheduler.zig"),
        .link_libc = true,
    });

    // ── Command module (CLI subcommands) ────────────────────────────────

    const command_mod = b.createModule(.{ .root_source_file = b.path("src/cmd.zig") });
    command_mod.addImport("Config", config_mod);
    command_mod.addImport("Cmd", cmd_mod);
    command_mod.addImport("ProcessPool", pool_mod);
    command_mod.addImport("Memory", memory_mod);
    command_mod.addImport("prompts", prompts_mod);
    command_mod.addImport("claude", claude_mod);

    // ── Executable ─────────────────────────────────────────────────────

    // Inject git commit hash at compile time
    const git_hash = b.option([]const u8, "git-hash", "Git commit hash") orelse "dev";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "git_hash", git_hash);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addOptions("build_options", build_options);
    exe_mod.addImport("Config", config_mod);
    exe_mod.addImport("IMessage", imessage_mod);
    exe_mod.addImport("claude", claude_mod);
    exe_mod.addImport("Memory", memory_mod);
    exe_mod.addImport("prompts", prompts_mod);
    exe_mod.addImport("ProcessPool", pool_mod);
    exe_mod.addImport("Cmd", cmd_mod);
    exe_mod.addImport("message", message_mod);
    exe_mod.addImport("cmd", command_mod);
    exe_mod.addImport("Scheduler", scheduler_mod);

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
    addTestTarget(b, test_step, "cmd", b.path("src/proc/Cmd.zig"), target, optimize, &.{});
    addTestTarget(b, test_step, "config", b.path("src/Config.zig"), target, optimize, &.{});
    addTestTarget(b, test_step, "uuid", b.path("src/Uuid.zig"), target, optimize, &.{});
    addTestTarget(b, test_step, "memory", b.path("src/Memory.zig"), target, optimize, &.{});

    // prompts -> embedded files
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/prompts.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addAnonymousImport("system_prompt", .{ .root_source_file = b.path("prompts/system.md") });
        mod.addAnonymousImport("compact_prompt", .{ .root_source_file = b.path("prompts/compact.md") });
        mod.addAnonymousImport("memory_prompt", .{ .root_source_file = b.path("prompts/memory.md") });
        const unit_test = b.addTest(.{ .root_module = mod });
        const run = b.addRunArtifact(unit_test);
        test_step.dependOn(&run.step);
        b.step("test-prompts", "Run prompts tests").dependOn(&run.step);
    }

    // Process -> Cmd
    addTestTarget(b, test_step, "process", b.path("src/proc/Process.zig"), target, optimize, &.{
        .{ .name = "Cmd", .module = cmd_mod },
    });

    // ProcessPool -> Cmd, Process
    addTestTarget(b, test_step, "process_pool", b.path("src/proc/ProcessPool.zig"), target, optimize, &.{
        .{ .name = "Cmd", .module = cmd_mod },
        .{ .name = "Process", .module = process_mod },
    });

    // imessage -> adapter, message, Cmd, ProcessPool
    addTestTarget(b, test_step, "imessage", b.path("src/adapter/IMessage.zig"), target, optimize, &.{
        .{ .name = "adapter", .module = adapter_mod },
        .{ .name = "message", .module = message_mod },
        .{ .name = "Cmd", .module = cmd_mod },
        .{ .name = "ProcessPool", .module = pool_mod },
    });

    // scheduler (built-in cron, needs libc for localtime_r)
    addTestTarget(b, test_step, "scheduler", b.path("src/Scheduler.zig"), target, optimize, &.{});

    // claude -> provider, message, Cmd, ProcessPool, Uuid, memory, prompts
    addTestTarget(b, test_step, "claude", b.path("src/provider/claude.zig"), target, optimize, &.{
        .{ .name = "provider", .module = provider_mod },
        .{ .name = "message", .module = message_mod },
        .{ .name = "Cmd", .module = cmd_mod },
        .{ .name = "ProcessPool", .module = pool_mod },
        .{ .name = "Uuid", .module = uuid_mod },
        .{ .name = "Memory", .module = memory_mod },
        .{ .name = "prompts", .module = prompts_mod },
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
