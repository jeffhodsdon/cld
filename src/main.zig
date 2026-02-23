const std = @import("std");
const posix = std.posix;
const Config = @import("Config");
const IMessage = @import("imessage");
const Claude = @import("claude");
const Memory = @import("memory");
const prompts = @import("prompts");
const ProcessPool = @import("ProcessPool");
const Handle = @import("message").Handle;

const version = "0.1.0";

var running: bool = true;

pub fn main() !void {
    // Check for --version flag
    var args = std.process.args();
    _ = args.skip(); // skip argv[0]
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            const stdout = std.fs.File.stdout().deprecatedWriter();
            stdout.print("cld {s}\n", .{version}) catch {};
            return;
        }
    }

    // Handle SIGINT/SIGTERM for clean shutdown
    const sa = posix.Sigaction{
        .handler = .{ .handler = struct {
            fn handler(_: c_int) callconv(.c) void {
                running = false;
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

    // Load config
    var config = Config.load(allocator);
    defer config.deinit();

    // Shared process pool
    var pool = ProcessPool.init(allocator);
    defer pool.deinit();

    // Init components
    var memory = Memory.init(allocator, config.memory_path);
    defer memory.deinit();

    const mem_ctx = memory.getContext() catch "";
    defer if (mem_ctx.len > 0) allocator.free(mem_ctx);

    const system_prompt = if (mem_ctx.len > 0)
        std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ prompts.system, mem_ctx }) catch prompts.system
    else
        prompts.system;
    defer if (system_prompt.ptr != prompts.system.ptr) allocator.free(system_prompt);

    var imsg = try IMessage.init(allocator, &pool);
    defer imsg.deinit();

    var claude = Claude.init(allocator, &pool);
    defer claude.deinit();

    // Event-driven main loop
    while (running) {
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
                            memory.logMessage("recv", inbound.sender, inbound.text);
                            _ = claude.provider().start(.{
                                .conversation_id = inbound.channel_id,
                                .messages = &.{.{
                                    .role = .user,
                                    .content = inbound.text,
                                }},
                                .system_prompt = system_prompt,
                            });
                        }
                    },
                    .exited => {
                        if (!running) break;
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
                    .stdout_ready, .stderr_ready => {},
                }
            }
        }
    }
}
