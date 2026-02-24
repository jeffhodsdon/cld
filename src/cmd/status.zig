const std = @import("std");
const Config = @import("Config");
const Cmd = @import("Cmd");
const ProcessPool = @import("ProcessPool");

pub fn run() void {
    const w = std.fs.File.stdout().deprecatedWriter();
    const home = std.posix.getenv("HOME") orelse "";

    w.writeAll("\ncld status\n\n") catch {};

    // 1. imsg binary
    checkBinary(w, "imsg binary", "imsg", "brew install cld (or add imsg to PATH)");

    // 2. claude binary
    checkBinary(w, "claude binary", "claude", "npm install -g @anthropic-ai/claude-code");

    // 3. Claude auth
    checkClaudeAuth(w);

    // 4. Messages DB readable
    checkMessagesDb(w, home);

    // 5. Config file
    checkConfig(w, home);

    // 6. Memory directory
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

fn checkClaudeAuth(w: anytype) void {
    const label = "claude auth";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cmd = Cmd.init(allocator, "claude");
    defer cmd.deinit();
    cmd.arg("auth") catch return;
    cmd.arg("status") catch return;
    cmd.arg("--json") catch return;

    var result = ProcessPool.exec(allocator, &cmd) catch {
        printFail(w, label, "failed to run claude", "Check claude binary");
        return;
    };
    defer result.deinit();

    if (result.exit_code != 0) {
        printFail(w, label, "not authenticated", "Run: claude /login");
        return;
    }

    // Parse JSON properly instead of string matching
    const AuthStatus = struct {
        loggedIn: bool = false,
        email: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(AuthStatus, allocator, result.stdout, .{
        .ignore_unknown_fields = true,
    }) catch {
        printFail(w, label, "unexpected response from claude auth status", "");
        return;
    };
    defer parsed.deinit();

    if (parsed.value.loggedIn) {
        printPass(w, label, parsed.value.email orelse "logged in");
    } else {
        printFail(w, label, "not logged in", "Run: claude /login");
    }
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
        // Resolve our own binary path and check if it has an FDA grant in TCC.
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_path = std.fs.selfExePath(&resolved_buf) catch null;

        if (self_path) |sp| {
            if (checkTccFdaPath(sp)) {
                printPass(w, label, "~/Library/Messages/chat.db");
            } else {
                printWarn(w, label, "readable (via terminal), but cld binary lacks FDA", "Add cld in System Settings > Privacy & Security > Full Disk Access");
            }
        } else {
            // Can't resolve self path, just report readable
            printPass(w, label, "~/Library/Messages/chat.db");
        }
    } else |_| {
        printFail(w, label, "~/Library/Messages/chat.db (not readable)", "Grant Full Disk Access to cld in System Settings > Privacy & Security");
    }
}

/// Query the system TCC.db to check if a specific path has a Full Disk Access grant.
fn checkTccFdaPath(path: []const u8) bool {
    var query_buf: [1024]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buf, "SELECT auth_value FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client='{s}' AND auth_value=2 LIMIT 1", .{path}) catch return false;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cmd = Cmd.init(allocator, "sqlite3");
    defer cmd.deinit();
    cmd.arg("/Library/Application Support/com.apple.TCC/TCC.db") catch return false;
    cmd.arg(query) catch return false;

    var result = ProcessPool.exec(allocator, &cmd) catch return false;
    defer result.deinit();

    return result.exit_code == 0 and std.mem.indexOf(u8, result.stdout, "2") != null;
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
