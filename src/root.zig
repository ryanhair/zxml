//! zxml - A streaming XML parser for Zig
//!
//! This library provides a pull-style (event-based) XML parser with true streaming support.
//! Memory usage is bounded to the current element ancestry depth, not the document size.
//!
//! Example usage:
//! ```zig
//! const std = @import("std");
//! const zxml = @import("zxml");
//!
//! const file = try std.fs.cwd().openFile("data.xml", .{ .mode = .read_only });
//! var buffer: [256 * 1024]u8 = undefined;
//! var file_reader = file.reader(&buffer);
//!
//! var parser = zxml.PullParser.init(allocator, &file_reader.interface);
//! defer parser.deinit();
//!
//! while (try parser.next()) |event| {
//!     switch (event) {
//!         .start_element => |elem| {
//!             // Element name and attributes are valid until the element closes
//!             // If you need them longer, use allocator.dupe() to copy
//!         },
//!         .text => |content| { },
//!         .end_element => |elem| { },
//!         else => {},
//!     }
//! }
//! ```

const std = @import("std");

// Re-export the main parser API
const pull_parser = @import("pull_parser.zig");
pub const PullParser = pull_parser.PullParser;
pub const Event = pull_parser.Event;
pub const Attribute = pull_parser.Attribute;

// Re-export the typed parser API
const typed_parser = @import("typed_parser.zig");
pub const TypedParser = typed_parser.TypedParser;
pub const Iterator = typed_parser.Iterator;
pub const MultiIterator = typed_parser.MultiIterator;
