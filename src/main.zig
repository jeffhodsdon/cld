const std = @import("std");
const posix = std.posix;
const Config = @import("Config");
const IMessage = @import("imessage");
const Claude = @import("claude");
const Memory = @import("memory");
const prompts = @import("prompts");
const ProcessPool = @import("ProcessPool");
const Cmd = @import("Cmd");
const Handle = @import("message").Handle;
const Scheduler = @import("scheduler");
const build_options = @import("build_options");
const cmd = @import("cmd");

const version = "0.1.0";
const git_hash = build_options.git_hash;

pub const std_options: std.Options = .{
    .logFn = customLog,
};

fn customLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const prefix = comptime switch (level) {
        .err => "ERROR",
        .warn => "WARN ",
        .info => "INFO ",
        .debug => "DEBUG",
    };

    // Get wall clock time
    const epoch = std.time.timestamp();
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch) };
    const day_secs = es.getDaySeconds();
    const h = day_secs.getHoursIntoDay();
    const m = day_secs.getMinutesIntoHour();
    const s = day_secs.getSecondsIntoMinute();

    const stderr = std.fs.File.stderr().deprecatedWriter();
    nosuspend stderr.print("{d:0>2}:{d:0>2}:{d:0>2} {s} [{s}-{s}] " ++ format ++ "\n", .{h, m, s, prefix, version, git_hash} ++ args) catch {};
}

var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var signal_pipe: [2]posix.fd_t = .{ -1, -1 };

pub fn main() !void {
    // Check for subcommands
    var args = std.process.args();
    _ = args.skip(); // skip argv[0]
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            const stdout = std.fs.File.stdout().deprecatedWriter();
            stdout.print("cld {s}-{s}\n", .{ version, build_options.git_hash }) catch {};
            return;
        }
        if (cmd.parse(arg)) |command| {
            switch (command) {
                .status => cmd.status.run(),
                .provider => cmd.provider.run(&args),
            }
            return;
        }
    }

    // Self-pipe for waking poll() on signal
    signal_pipe = try posix.pipe();
    // Set write end to non-blocking so signal handler never blocks
    // O_NONBLOCK on macOS = 0x0004
    _ = try posix.fcntl(signal_pipe[1], std.c.F.SETFL, 0x0004);
    defer {
        posix.close(signal_pipe[0]);
        posix.close(signal_pipe[1]);
    }

    // Handle SIGINT/SIGTERM for clean shutdown
    const sa = posix.Sigaction{
        .handler = .{ .handler = struct {
            fn handler(_: c_int) callconv(.c) void {
                running.store(false, .release);
                // Wake up poll() via self-pipe
                _ = posix.write(signal_pipe[1], "x") catch {};
            }
        }.handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("starting", .{});

    // Load config
    var config = Config.load(allocator);
    defer config.deinit();

    // Shared process pool
    var pool = ProcessPool.init(allocator);
    defer pool.deinit();
    pool.setSignalFd(signal_pipe[0]);

    // Resolve memory path: ~/.local/share/cld/memory
    const home = std.posix.getenv("HOME") orelse {
        std.log.err("HOME not set", .{});
        return;
    };
    const memory_path = try std.fs.path.join(allocator, &.{ home, ".local", "share", "cld", "memory" });
    defer allocator.free(memory_path);

    // Ensure memory directory exists
    std.fs.cwd().makePath(memory_path) catch |err| {
        std.log.err("could not create memory dir '{s}': {}", .{ memory_path, err });
        return;
    };

    // Init components
    var memory = Memory.init(allocator, memory_path);
    defer memory.deinit();

    var imsg = try IMessage.init(allocator, &pool);
    defer imsg.deinit();

    var claude = Claude.init(allocator, &pool);
    defer claude.deinit();

    // Scheduler: state file next to memory dir
    const scheduler_state_path = std.fs.path.join(allocator, &.{ home, ".local", "share", "cld", "scheduler.json" }) catch null;
    defer if (scheduler_state_path) |p| allocator.free(p);

    var scheduler = Scheduler.init(allocator, scheduler_state_path);
    defer scheduler.deinit();

    // Register built-in tasks (config can override cron expression)
    const default_compact = Scheduler.parseCron("1 0 * * *") catch unreachable;
    const compact_schedule: Scheduler.Schedule = if (config.tasks) |t|
        if (t.compact) |expr| Scheduler.parseCron(expr) catch default_compact else default_compact
    else
        default_compact;
    scheduler.add("compact", compact_schedule, false) catch {};
    scheduler.loadState() catch {};
    std.log.info("scheduler: {d} task(s) registered", .{scheduler.tasks.items.len});

    // Event-driven main loop
    while (running.load(.acquire)) {
        // Check scheduler for due tasks
        const now = std.time.timestamp();
        const due = scheduler.tick(now);
        for (due) |task_name| {
            if (std.mem.eql(u8, task_name, "compact")) {
                std.log.info("scheduler: running compaction", .{});
                claude.compact(&memory, &Memory.yesterdayStr());
                memory.reloadTinys();
                scheduler.save() catch {};
            }
        }

        const events = try pool.poll(100);

        for (events) |event| {
            if (imsg.watch_id != null and event.id == imsg.watch_id.?) {
                // iMessage watcher event
                switch (event.tag) {
                    .stdout_ready => {
                        if (imsg.adapter().poll()) |inbound| {
                            if (!config.isSenderAllowed(inbound.sender)) {
                                std.log.info("ignored [{s}] {s}", .{ inbound.sender, inbound.text });
                                continue;
                            }
                            std.log.info("recv [{s}] {s}", .{ inbound.sender, inbound.text });
                            if (inbound.attachments.len > 0) {
                                std.log.info("recv {d} attachment(s):", .{inbound.attachments.len});
                                for (inbound.attachments) |path| {
                                    // Check if file exists
                                    const exists = if (std.fs.cwd().statFile(path)) |_| true else |_| false;
                                    std.log.info("  -> {s} (exists={})", .{ path, exists });
                                }
                            }
                            memory.logMessage("recv", inbound.sender, inbound.text);

                            // Build system prompt fresh each message (picks up file changes via stat check)
                            const mem_ctx = memory.getContext() catch "";
                            defer if (mem_ctx.len > 0) allocator.free(mem_ctx);
                            const sys_prompt = prompts.buildSystemPrompt(allocator, mem_ctx) catch prompts.system;
                            defer if (sys_prompt.ptr != prompts.system.ptr) allocator.free(sys_prompt);

                            _ = claude.provider().start(.{
                                .conversation_id = inbound.channel_id,
                                .messages = &.{.{
                                    .role = .user,
                                    .content = inbound.text,
                                    .attachments = inbound.attachments,
                                }},
                                .system_prompt = sys_prompt,
                            });
                        }
                    },
                    .exited => {
                        if (!running.load(.acquire)) break;
                        // Drain stderr for debug info
                        if (pool.get(event.id)) |proc| {
                            const stderr = proc.drainStderr() catch "";
                            if (stderr.len > 0) {
                                std.log.err("imsg stderr: {s}", .{stderr});
                            }
                            if (proc.checkExit()) |status| {
                                std.log.err("imsg exited with code {d}", .{status});
                            }
                        }
                        std.log.err("imsg watch process exited", .{});
                        return;
                    },
                    .stderr_ready => {},
                }
            } else if (claude.ownsProcess(event.id)) {
                // Claude session event
                switch (event.tag) {
                    .exited => {
                        // Find which handle this process belongs to
                        var handle_found: ?Handle = null;
                        var conv_id: []const u8 = "";
                        {
                            var it = claude.sessions.iterator();
                            while (it.next()) |entry| {
                                if (entry.value_ptr.process_id == event.id) {
                                    handle_found = entry.key_ptr.*;
                                    conv_id = entry.value_ptr.conversation_id;
                                    break;
                                }
                            }
                        }
                        if (handle_found) |handle| {
                            if (claude.provider().poll(handle)) |response| {
                                defer if (response.text.len > 0) allocator.free(response.text);
                                if (response.done and response.text.len > 0) {
                                    std.log.info("send [{s}] {s}", .{ conv_id, response.text });
                                    memory.logMessage("send", conv_id, response.text);
                                    imsg.adapter().send(.{
                                        .channel_id = conv_id,
                                        .text = response.text,
                                    }) catch |err| {
                                        std.log.err("send failed: {}", .{err});
                                    };
                                } else {
                                    std.log.warn("claude session produced no output", .{});
                                }
                            }
                            // Always clean up the session
                            claude.provider().cancel(handle);
                        }
                    },
                    .stdout_ready, .stderr_ready => {
                        // Drain pipe to prevent buffer filling up and blocking the child
                        if (pool.get(event.id)) |proc| {
                            proc.drainPipe();
                        }
                    },
                }
            }
        }
    }
}
