const msg = @import("message");

pub const InboundMessage = msg.InboundMessage;
pub const OutboundMessage = msg.OutboundMessage;
pub const SendError = msg.SendError;

/// Wrapping an external interface to conform to an internal one,
pub const Adapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        poll: *const fn (*anyopaque) ?InboundMessage,
        send: *const fn (*anyopaque, OutboundMessage) SendError!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn poll(self: Adapter) ?InboundMessage {
        return self.vtable.poll(self.ptr);
    }

    pub fn send(self: Adapter, message: OutboundMessage) SendError!void {
        return self.vtable.send(self.ptr, message);
    }

    pub fn deinit(self: Adapter) void {
        return self.vtable.deinit(self.ptr);
    }
};
