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

const version = "0.1.0";

var running: bool = true;

pub fn main() !void {
    // Check for subcommands
    var args = std.process.args();
    _ = args.skip(); // skip argv[0]
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            const stdout = std.fs.File.stdout().deprecatedWriter();
            stdout.print("cld {s}\n", .{version}) catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "status")) {
            runStatus();
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

    // Resolve memory path: config override or ~/.local/share/cld/memory
    const resolved_memory_path = config.memory_path orelse resolvePath: {
        const home = std.posix.getenv("HOME") orelse break :resolvePath null;
        break :resolvePath std.fs.path.join(allocator, &.{ home, ".local", "share", "cld", "memory" }) catch null;
    };
    defer if (config.memory_path == null) {
        if (resolved_memory_path) |p| allocator.free(p);
    };
    const memory_path = resolved_memory_path orelse "memory";

    // Init components
    var memory = Memory.init(allocator, memory_path);
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

fn runStatus() void {
    const w = std.fs.File.stdout().deprecatedWriter();
    const home = std.posix.getenv("HOME") orelse "";

    w.writeAll("\ncld status\n\n") catch {};

    // 1. imsg binary
    checkBinary(w, "imsg binary", "imsg", "brew install cld (or add imsg to PATH)");

    // 2. claude binary
    checkBinary(w, "claude binary", "claude", "npm install -g @anthropic-ai/claude-code");

    // 3. Messages DB readable
    checkMessagesDb(w, home);

    // 4. Config file
    checkConfig(w, home);

    // 5. Memory directory
    checkMemoryDir(w, home);

    w.writeAll("\n") catch {};
}

fn checkBinary(w: anytype, label: []const u8, name: []const u8, fix: []const u8) void {
    const path_env = std.posix.getenv("PATH") orelse "";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        // Build path: dir/name — use stack buffer to avoid allocator
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = dir.len;
        if (dir_len + 1 + name.len > buf.len) continue;
        @memcpy(buf[0..dir_len], dir);
        buf[dir_len] = '/';
        @memcpy(buf[dir_len + 1 ..][0..name.len], name);
        const full_path = buf[0 .. dir_len + 1 + name.len];

        // Check file exists and is accessible
        const stat = std.fs.cwd().statFile(full_path) catch continue;
        _ = stat;
        printPass(w, label, full_path);
        return;
    }
    printFail(w, label, "not found on PATH", fix);
}

fn checkMessagesDb(w: anytype, home: []const u8) void {
    const label = "messages db";
    if (home.len == 0) {
        printFail(w, label, "HOME not set", "export HOME");
        return;
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const suffix = "/Library/Messages/chat.db";
    if (home.len + suffix.len > buf.len) {
        printFail(w, label, "path too long", "");
        return;
    }
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len..][0..suffix.len], suffix);
    const path = buf[0 .. home.len + suffix.len];

    if (std.fs.cwd().openFile(path, .{})) |file| {
        file.close();
        // File is readable — but this may be inherited from the terminal's FDA.
        // Query TCC.db to check if the actual binaries have their own FDA grants,
        // which is what matters when running as a brew service (launchd).
        const cld_has_fda = checkTccFda("cld");
        const imsg_has_fda = checkTccFda("imsg");

        if (cld_has_fda and imsg_has_fda) {
            printPass(w, label, "~/Library/Messages/chat.db");
        } else if (!cld_has_fda and !imsg_has_fda) {
            printWarn(w, label, "readable (via terminal), but cld and imsg lack Full Disk Access", "Add cld and imsg in System Settings > Privacy & Security > Full Disk Access");
        } else if (!imsg_has_fda) {
            printWarn(w, label, "readable (via terminal), but imsg lacks Full Disk Access", "Add imsg in System Settings > Privacy & Security > Full Disk Access");
        } else {
            printWarn(w, label, "readable (via terminal), but cld lacks Full Disk Access", "Add cld in System Settings > Privacy & Security > Full Disk Access");
        }
    } else |_| {
        printFail(w, label, "~/Library/Messages/chat.db (not readable)", "Grant Full Disk Access to cld and imsg in System Settings > Privacy & Security");
    }
}

/// Query the system TCC.db to check if a binary (resolved from PATH) has its own
/// Full Disk Access grant. Returns false if the query fails or the binary is not found.
fn checkTccFda(binary_name: []const u8) bool {
    // Resolve the binary's real path (following symlinks)
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = resolveBinaryPath(binary_name, &resolved_buf) orelse return false;

    // Query TCC.db: auth_value=2 means "allowed"
    var query_buf: [1024]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buf, "SELECT auth_value FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client='{s}' AND auth_value=2 LIMIT 1", .{real_path}) catch return false;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cmd = Cmd.init(allocator, "sqlite3");
    defer cmd.deinit();
    cmd.arg("/Library/Application Support/com.apple.TCC/TCC.db") catch return false;
    cmd.arg(query) catch return false;

    var result = ProcessPool.exec(allocator, &cmd) catch return false;
    defer result.deinit();

    // If we got output with "2", the binary has FDA
    return result.exit_code == 0 and std.mem.indexOf(u8, result.stdout, "2") != null;
}

/// Find a binary on PATH and resolve symlinks to get the real absolute path.
fn resolveBinaryPath(name: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var candidate_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (dir.len + 1 + name.len > candidate_buf.len) continue;
        @memcpy(candidate_buf[0..dir.len], dir);
        candidate_buf[dir.len] = '/';
        @memcpy(candidate_buf[dir.len + 1 ..][0..name.len], name);
        const candidate = candidate_buf[0 .. dir.len + 1 + name.len];

        const resolved = std.fs.cwd().realpath(candidate, out) catch continue;
        return resolved;
    }
    return null;
}

fn checkConfig(w: anytype, home: []const u8) void {
    const label = "config";
    if (home.len == 0) {
        printFail(w, label, "HOME not set", "export HOME");
        return;
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const suffix = "/.config/cld/config.json";
    if (home.len + suffix.len > buf.len) {
        printFail(w, label, "path too long", "");
        return;
    }
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len..][0..suffix.len], suffix);
    const path = buf[0 .. home.len + suffix.len];

    if (std.fs.cwd().openFile(path, .{})) |file| {
        file.close();
        printPass(w, label, "~/.config/cld/config.json");
    } else |_| {
        printFail(w, label, "~/.config/cld/config.json (not found)", "mkdir -p ~/.config/cld && echo '{}' > ~/.config/cld/config.json");
    }
}

fn checkMemoryDir(w: anytype, home: []const u8) void {
    const label = "memory dir";

    // Load config to get memory_path
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = Config.load(allocator);
    defer config.deinit();

    // Resolve default: ~/.local/share/cld/memory
    if (config.memory_path) |mem_path| {
        checkDirAccess(w, label, mem_path, mem_path);
    } else {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const suffix = "/.local/share/cld/memory";
        if (home.len == 0 or home.len + suffix.len > buf.len) {
            printFail(w, label, "~/.local/share/cld/memory", "mkdir -p ~/.local/share/cld/memory");
            return;
        }
        @memcpy(buf[0..home.len], home);
        @memcpy(buf[home.len..][0..suffix.len], suffix);
        const path = buf[0 .. home.len + suffix.len];
        checkDirAccess(w, label, "~/.local/share/cld/memory", path);
    }
}

fn checkDirAccess(w: anytype, label: []const u8, display: []const u8, path: []const u8) void {
    if (std.fs.cwd().openDir(path, .{})) |dir| {
        var d = dir;
        d.close();
        printPass(w, label, display);
    } else |_| {
        var fix_buf: [512]u8 = undefined;
        const fix = std.fmt.bufPrint(&fix_buf, "mkdir -p {s}", .{display}) catch "mkdir -p <memory_path>";
        printFail(w, label, display, fix);
    }
}

fn printPass(w: anytype, label: []const u8, detail: []const u8) void {
    w.print("  {s:<16}\xe2\x9c\x93 {s}\n", .{ label, detail }) catch {};
}

fn printWarn(w: anytype, label: []const u8, detail: []const u8, fix: []const u8) void {
    w.print("  {s:<16}\xe2\x9a\xa0 {s}\n", .{ label, detail }) catch {};
    if (fix.len > 0) {
        w.print("  {s:<16}  \xe2\x86\x92 {s}\n", .{ "", fix }) catch {};
    }
}

fn printFail(w: anytype, label: []const u8, detail: []const u8, fix: []const u8) void {
    w.print("  {s:<16}\xe2\x9c\x97 {s}\n", .{ label, detail }) catch {};
    if (fix.len > 0) {
        w.print("  {s:<16}  \xe2\x86\x92 {s}\n", .{ "", fix }) catch {};
    }
}
