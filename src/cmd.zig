const std = @import("std");

pub const status = @import("cmd/status.zig");
pub const provider = @import("cmd/provider.zig");

pub const Command = enum {
    status,
    provider,
};

pub fn parse(arg: []const u8) ?Command {
    return std.meta.stringToEnum(Command, arg);
}
