const msg = @import("message");

pub const Request = msg.Request;
pub const Response = msg.Response;
pub const Handle = msg.Handle;

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (*anyopaque, Request) Handle,
        poll: *const fn (*anyopaque, Handle) ?Response,
        cancel: *const fn (*anyopaque, Handle) void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn start(self: Provider, req: Request) Handle {
        return self.vtable.start(self.ptr, req);
    }

    pub fn poll(self: Provider, handle: Handle) ?Response {
        return self.vtable.poll(self.ptr, handle);
    }

    pub fn cancel(self: Provider, handle: Handle) void {
        return self.vtable.cancel(self.ptr, handle);
    }

    pub fn deinit(self: Provider) void {
        return self.vtable.deinit(self.ptr);
    }
};
