pub const InboundMessage = struct {
    id: []const u8,
    channel_id: []const u8, // "imessage:+1234567890"
    sender: []const u8,
    text: []const u8,
    timestamp: i64,
    reply_to: ?[]const u8 = null,
    attachments: []const []const u8 = &.{},
};

pub const OutboundMessage = struct {
    channel_id: []const u8,
    text: []const u8,
    reply_to: ?[]const u8 = null,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
    timestamp: i64 = 0,
    attachments: []const []const u8 = &.{},

    pub const Role = enum {
        user,
        assistant,
        system,
    };
};

pub const Request = struct {
    conversation_id: []const u8,
    messages: []const Message,
    system_prompt: []const u8,
};

pub const Response = struct {
    text: []const u8,
    done: bool,
};

pub const Handle = u64;

pub const SendError = error{
    AdapterFailed,
    InvalidRecipient,
    Timeout,
};
