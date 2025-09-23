const std = @import("std");

/// Stack-based string storage for XML parser
/// Stores strings in a single allocated buffer with mark/reset functionality
pub const StringStorage = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    buffer_pos: usize = 0, // Current top of stack

    const DEFAULT_CAPACITY = 64 * 1024; // 64 KB - sufficient for typical element ancestry depth

    pub fn init(allocator: std.mem.Allocator) StringStorage {
        var buffer = std.ArrayList(u8){};
        // Pre-allocate reasonable default capacity to minimize reallocations
        buffer.ensureTotalCapacity(allocator, DEFAULT_CAPACITY) catch {};
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .buffer_pos = 0,
        };
    }

    pub fn deinit(self: *StringStorage) void {
        self.buffer.deinit(self.allocator);
    }

    /// Mark the current position in the buffer (for stack push)
    pub fn mark(self: *StringStorage) usize {
        return self.buffer_pos;
    }

    /// Reset the buffer to a previous mark (for stack pop)
    pub fn resetToMark(self: *StringStorage, mark_pos: usize) void {
        self.buffer_pos = mark_pos;
        // Don't shrink the ArrayList - just track position
        // The buffer.items slice remains valid, we just reuse the space
    }

    /// Store a string and return a reference to it
    /// Automatically resolves XML entities if present
    /// Returned slices remain valid until the next resetToMark() call
    pub fn store(self: *StringStorage, str: []const u8) ![]const u8 {
        // Check if string contains entities
        if (std.mem.indexOfScalar(u8, str, '&')) |_| {
            return self.storeWithEntities(str);
        }

        // Ensure we have total capacity (not just unused)
        const needed_capacity = self.buffer_pos + str.len;
        if (self.buffer.capacity < needed_capacity) {
            try self.buffer.ensureTotalCapacity(self.allocator, needed_capacity);
        }

        const start = self.buffer_pos;
        // Copy directly to buffer at current position
        @memcpy(self.buffer.items.ptr[self.buffer_pos..][0..str.len], str);
        self.buffer_pos += str.len;

        // Keep items.len in sync with buffer_pos for proper capacity checks
        if (self.buffer.items.len < self.buffer_pos) {
            self.buffer.items.len = self.buffer_pos;
        }

        return self.buffer.items[start..self.buffer_pos];
    }

    /// Store a string with entity resolution
    fn storeWithEntities(self: *StringStorage, str: []const u8) ![]const u8 {
        // Estimate capacity needed (worst case: str.len * 4 for unicode, but typically str.len)
        const needed_capacity = self.buffer_pos + str.len;
        if (self.buffer.capacity < needed_capacity) {
            try self.buffer.ensureTotalCapacity(self.allocator, needed_capacity);
        }

        const start = self.buffer_pos;

        var i: usize = 0;
        while (i < str.len) {
            if (str[i] == '&') {
                // Find the entity end
                const entity_start = i + 1;
                const entity_end = std.mem.indexOfScalarPos(u8, str, entity_start, ';') orelse {
                    // No semicolon found, treat as literal
                    try self.appendByte(str[i]);
                    i += 1;
                    continue;
                };

                const entity_name = str[entity_start..entity_end];

                // Resolve built-in entities
                if (std.mem.eql(u8, entity_name, "lt")) {
                    try self.appendByte('<');
                } else if (std.mem.eql(u8, entity_name, "gt")) {
                    try self.appendByte('>');
                } else if (std.mem.eql(u8, entity_name, "amp")) {
                    try self.appendByte('&');
                } else if (std.mem.eql(u8, entity_name, "quot")) {
                    try self.appendByte('"');
                } else if (std.mem.eql(u8, entity_name, "apos")) {
                    try self.appendByte('\'');
                } else if (entity_name.len > 1 and entity_name[0] == '#') {
                    // Numeric character reference
                    const codepoint = if (entity_name[1] == 'x' or entity_name[1] == 'X')
                        std.fmt.parseInt(u21, entity_name[2..], 16) catch {
                            // Invalid, keep as literal
                            try self.appendSlice(str[i .. entity_end + 1]);
                            i = entity_end + 1;
                            continue;
                        }
                    else
                        std.fmt.parseInt(u21, entity_name[1..], 10) catch {
                            // Invalid, keep as literal
                            try self.appendSlice(str[i .. entity_end + 1]);
                            i = entity_end + 1;
                            continue;
                        };

                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                        // Invalid codepoint, keep as literal
                        try self.appendSlice(str[i .. entity_end + 1]);
                        i = entity_end + 1;
                        continue;
                    };
                    try self.appendSlice(buf[0..len]);
                } else {
                    // Unknown entity, keep as literal
                    try self.appendSlice(str[i .. entity_end + 1]);
                }

                i = entity_end + 1;
            } else {
                try self.appendByte(str[i]);
                i += 1;
            }
        }

        return self.buffer.items[start..self.buffer_pos];
    }

    /// Append a single byte at current position
    fn appendByte(self: *StringStorage, byte: u8) !void {
        const needed = self.buffer_pos + 1;
        if (self.buffer.capacity < needed) {
            try self.buffer.ensureTotalCapacity(self.allocator, needed);
        }
        self.buffer.items.ptr[self.buffer_pos] = byte;
        self.buffer_pos += 1;
        if (self.buffer.items.len < self.buffer_pos) {
            self.buffer.items.len = self.buffer_pos;
        }
    }

    /// Append a slice at current position
    fn appendSlice(self: *StringStorage, slice: []const u8) !void {
        const needed = self.buffer_pos + slice.len;
        if (self.buffer.capacity < needed) {
            try self.buffer.ensureTotalCapacity(self.allocator, needed);
        }
        @memcpy(self.buffer.items.ptr[self.buffer_pos..][0..slice.len], slice);
        self.buffer_pos += slice.len;
        if (self.buffer.items.len < self.buffer_pos) {
            self.buffer.items.len = self.buffer_pos;
        }
    }

    /// Get a string by reference (for compatibility)
    pub fn getString(self: *StringStorage, str: []const u8) []const u8 {
        _ = self;
        return str;
    }
};
