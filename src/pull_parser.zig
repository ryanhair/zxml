const std = @import("std");
const StreamingBackend = @import("./streaming_backend.zig").StreamingBackend;
const InMemoryBackend = @import("./in_memory_backend.zig").InMemoryBackend;

// Re-export common types from StreamingBackend (both backends share these)
pub const Event = @import("./streaming_backend.zig").Event;
pub const Attribute = @import("./streaming_backend.zig").Attribute;

/// Pull parser for event-based XML parsing
/// Supports streaming (Reader-based), in-memory, and memory-mapped parsing
pub const PullParser = struct {
    backend: union(enum) {
        streaming: StreamingBackend,
        in_memory: InMemoryBackend,
    },
    // If set, we own this mmap'd memory and must munmap on deinit
    mmap_data: ?[]const u8 = null,

    /// Initialize parser with a Reader for streaming parsing
    /// Suitable for large files or network streams
    /// String data is valid until the corresponding element closes
    /// Performance: ~400 MB/s
    pub fn initWithReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) PullParser {
        return .{
            .backend = .{ .streaming = StreamingBackend.init(allocator, reader) },
            .mmap_data = null,
        };
    }

    /// Initialize parser with XML data in memory
    /// Suitable for small documents (few MB) that fit in memory
    /// Offers highest performance (2x faster than streaming)
    /// String data references the input XML directly (zero-copy)
    /// Performance: ~800-850 MB/s
    pub fn initInMemory(allocator: std.mem.Allocator, xml: []const u8) PullParser {
        return .{
            .backend = .{ .in_memory = InMemoryBackend.init(allocator, xml) },
            .mmap_data = null,
        };
    }

    /// Initialize parser with memory-mapped file
    /// Best for large files (100+ MB) - no upfront memory allocation
    /// OS handles paging automatically, no file size limits
    /// Offers near-in-memory performance (1.5-2x faster than streaming)
    /// Performance: ~550-800 MB/s depending on file size
    pub fn initWithMmap(allocator: std.mem.Allocator, file_path: []const u8) !PullParser {
        // Open the file
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = (try file.stat()).size;

        // Memory map the entire file (OS handles paging)
        const mmap_data = try std.posix.mmap(
            null,
            file_size,
            std.posix.PROT.READ,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        return .{
            .backend = .{ .in_memory = InMemoryBackend.init(allocator, mmap_data) },
            .mmap_data = mmap_data,
        };
    }

    /// Deinitialize the parser
    pub fn deinit(self: *PullParser) void {
        switch (self.backend) {
            .streaming => |*b| b.deinit(),
            .in_memory => |*b| b.deinit(),
        }
        // If we own mmap'd memory, unmap it
        if (self.mmap_data) |mmap| {
            std.posix.munmap(@alignCast(mmap));
        }
    }

    /// Get next parsing event
    pub fn next(self: *PullParser) !?Event {
        switch (self.backend) {
            .streaming => |*b| return try b.next(),
            .in_memory => |*b| return try b.next(),
        }
    }

    /// Get current parser depth
    pub fn getDepth(self: *const PullParser) u8 {
        return switch (self.backend) {
            .streaming => |*b| b.getDepth(),
            .in_memory => |*b| b.getDepth(),
        };
    }

    /// Get current parser position
    pub fn getPosition(self: *const PullParser) usize {
        return switch (self.backend) {
            .streaming => |*b| b.getPosition(),
            .in_memory => |*b| b.getPosition(),
        };
    }

    /// Get parser state
    pub fn getState(self: *const PullParser) ParserState {
        return switch (self.backend) {
            .streaming => |*b| b.getState(),
            .in_memory => |*b| b.getState(),
        };
    }
};

// Re-export ParserState from StreamingBackend
const ParserState = @import("./streaming_backend.zig").ParserState;
