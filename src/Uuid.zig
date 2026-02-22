const std = @import("std");

const Uuid = @This();

bytes: [16]u8,

/// Generate a random UUID v4.
pub fn v4() Uuid {
    var buf: [16]u8 = undefined;
    std.crypto.random.bytes(&buf);
    // Version 4
    buf[6] = (buf[6] & 0x0f) | 0x40;
    // Variant 1
    buf[8] = (buf[8] & 0x3f) | 0x80;
    return .{ .bytes = buf };
}

/// Format as 8-4-4-4-12 hex string into a stack buffer.
pub fn toStr(self: *const Uuid) [36]u8 {
    const hex = std.fmt.bytesToHex(self.bytes, .lower);
    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

/// Allocate the 8-4-4-4-12 string on the heap.
pub fn toStrAlloc(self: *const Uuid, allocator: std.mem.Allocator) ![]const u8 {
    const buf = self.toStr();
    return allocator.dupe(u8, &buf);
}

test "v4 version and variant bits" {
    const uuid = Uuid.v4();
    // Version: upper nibble of byte 6 must be 0x4
    try std.testing.expectEqual(0x40, uuid.bytes[6] & 0xf0);
    // Variant: upper 2 bits of byte 8 must be 10
    try std.testing.expectEqual(0x80, uuid.bytes[8] & 0xc0);
}

test "toStr format" {
    const uuid: Uuid = .{ .bytes = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0x4f, 0x80, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde } };
    const str = uuid.toStr();
    try std.testing.expectEqualStrings("01234567-89ab-cd4f-8012-3456789abcde", &str);
}

test "toStr length is 36" {
    const uuid = Uuid.v4();
    const str = uuid.toStr();
    try std.testing.expectEqual(36, str.len);
}

test "toStrAlloc matches toStr" {
    const uuid = Uuid.v4();
    const heap = try uuid.toStrAlloc(std.testing.allocator);
    defer std.testing.allocator.free(heap);
    const stack = uuid.toStr();
    try std.testing.expectEqualStrings(&stack, heap);
}
