# zxml - High-Performance XML Parser for Zig

[![Zig](https://img.shields.io/badge/Zig-0.15.1-orange)](https://ziglang.org/)

A blazingly fast, zero-copy XML parser for Zig featuring compile-time typed parsing and streaming performance.

## Features

- **High Performance**: 390 MB/s (PullParser) and 372 MB/s (TypedParser) in ReleaseFast mode
- **Compile-Time Typed Parsing**: Generate strongly-typed parsers from your structs at compile time
- **Zero-Copy**: String slices point directly into the parser buffer (no allocations)
- **Streaming**: Bounded memory usage regardless of document size
- **Lazy Iteration**: Efficient nested iteration with `Iterator` and `MultiIterator` types
- **Type Safety**: Automatic conversion from XML strings to native Zig types

## Quick Start

```zig
const std = @import("std");
const zxml = @import("zxml");

// Define your schema
const Book = struct {
    isbn: []const u8,
    title: []const u8,
    author: []const u8,
    pages: u32,
};

const Library = struct {
    name: []const u8,
    location: []const u8,
    books: zxml.Iterator("book", Book),  // Lazy iteration
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const xml =
        \\<?xml version="1.0"?>
        \\<library name="City Library" location="New York">
        \\    <book isbn="978-0451524935" title="1984" author="George Orwell" pages="328"/>
        \\    <book isbn="978-0441172719" title="Dune" author="Frank Herbert" pages="688"/>
        \\</library>
    ;

    var reader = std.Io.Reader.fixed(xml);

    // Parse with compile-time generated parser
    const LibraryParser = zxml.TypedParser(Library);
    var parser = try LibraryParser.init(allocator, &reader);
    defer parser.deinit();

    const library = &parser.result;
    std.debug.print("Library: {s} in {s}\n", .{ library.name, library.location });

    // Iterate through books lazily
    while (try library.books.next()) |book| {
        std.debug.print("  - {s} by {s} ({d} pages)\n",
            .{ book.title, book.author, book.pages });
    }
}
```

## Performance

Tested on a 1.22 GB XML file with 5,000,000 items (100 libraries, 10,000 collections):

| Parser          | Speed (ReleaseFast) | Time      | vs PullParser |
| --------------- | ------------------- | --------- | ------------- |
| **PullParser**  | 379.76 MB/s         | 3211.6 ms | baseline      |
| **TypedParser** | 368.80 MB/s         | 3307.1 ms | **97.1%**     |

Both benchmarks perform equivalent work: tracking libraries, collections, and counting books, movies, and music items.

**Debug builds**: PullParser 37.83 MB/s, TypedParser 30.94 MB/s (82% of PullParser)

**Memory Usage**: Bounded by element depth, not document size. Zero heap allocations for string content.

## TypedParser

The TypedParser generates optimized parsing code at compile time from your struct definitions.

### Type System

**Primitives** (parsed from attributes or element text):

- `[]const u8` - Zero-copy string slices
- `u32`, `i32`, etc. - Parsed with `std.fmt.parseInt`
- `f32`, `f64` - Parsed with `std.fmt.parseFloat`
- `bool` - Parses "true"/"false"
- `?T` - Optional fields (null if attribute/element missing)

**Structs** (map to XML elements):

- Fields map to attributes (primitives) or child elements (structs)
- Field names match XML names (configurable via `xml_names`)
- Can be eager (fully parsed) or lazy (has iterator)

**Iterators** (lazy collections):

- `Iterator(tag_name, T)` - Iterate over repeated elements with the same tag
- `MultiIterator(Union)` - Iterate over mixed element types via tagged union
- Maximum one iterator per struct

### Example: Nested Lazy Iteration

```zig
const Rating = struct {
    score: f32,
    max_score: u32,
    verified: bool,
};

const Metadata = struct {
    file_size: u32,
    duration: ?u32,
    format: []const u8,
    encrypted: bool,
};

const Book = struct {
    isbn: []const u8,
    title: []const u8,
    author: []const u8,
    pages: u32,
    metadata: Metadata,
    rating: ?Rating,
};

const Collection = struct {
    name: []const u8,
    theme: []const u8,
    curated: bool,
    books: zxml.Iterator("book", Book),
};

const Library = struct {
    name: []const u8,
    location: []const u8,
    established: u32,
    public: bool,
    collections: zxml.Iterator("collection", Collection),
};

// Usage
const LibraryParser = zxml.TypedParser(Library);
var parser = try LibraryParser.init(allocator, &reader);
defer parser.deinit();

var library = &parser.result;
while (try library.collections.next()) |*collection| {
    std.debug.print("Collection: {s}\n", .{collection.name});
    while (try collection.books.next()) |book| {
        std.debug.print("  - {s} by {s}\n", .{book.title, book.author});
    }
}
```

### Example: Mixed Child Types

Use tagged unions for XML elements with different tags:

```zig
const Book = struct {
    isbn: []const u8,
    title: []const u8,
    author: []const u8,
};

const Movie = struct {
    imdb_id: []const u8,
    title: []const u8,
    director: []const u8,
    year: u32,
};

const Music = struct {
    track_id: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
};

const MediaItem = union(enum) {
    book: Book,
    movie: Movie,
    music: Music,
};

const Collection = struct {
    name: []const u8,
    items: zxml.MultiIterator(MediaItem),  // Matches <book>, <movie>, <music>
};

// Usage
while (try collection.items.next()) |item| {
    switch (item) {
        .book => |book| std.debug.print("Book: {s}\n", .{book.title}),
        .movie => |movie| std.debug.print("Movie: {s} ({d})\n", .{movie.title, movie.year}),
        .music => |music| std.debug.print("Music: {s} by {s}\n", .{music.title, music.artist}),
    }
}
```

## Advanced Features

### Default Values

Fields can have default values that are used when XML attributes/elements are missing:

```zig
const Config = struct {
    host: []const u8,
    port: u32 = 8080,              // Defaults to 8080 if missing
    timeout: u32 = 30,             // Defaults to 30
    debug: bool = false,           // Defaults to false
    name: []const u8 = "default",  // Comptime string literal
};

// XML: <config host="localhost"/>
// Result: host="localhost", port=8080, timeout=30, debug=false, name="default"
```

Works with:

- Primitives (`u32 = 30`, `bool = false`)
- Comptime string literals (`[]const u8 = "default"`)
- Optional types with defaults (`?u32 = 8080`)

### Custom Type Parsers

Define custom parsing logic for your types with `parseXml()`:

```zig
const Timestamp = struct {
    year: u32,
    month: u32,
    day: u32,

    pub fn parseXml(text: []const u8) !@This() {
        // Parse "YYYY-MM-DD" format
        if (text.len != 10 or text[4] != '-' or text[7] != '-') {
            return error.InvalidFormat;
        }
        const year = try std.fmt.parseInt(u32, text[0..4], 10);
        const month = try std.fmt.parseInt(u32, text[5..7], 10);
        const day = try std.fmt.parseInt(u32, text[8..10], 10);
        return .{ .year = year, .month = month, .day = day };
    }
};

const Event = struct {
    name: []const u8,
    date: Timestamp,  // Parsed with custom parseXml()
    deadline: ?Timestamp,  // Works with optional types too
};

// XML: <event name="Conference" date="2024-03-15"/>
// Result: date.year=2024, date.month=3, date.day=15
```

Custom parsers:

- Must have signature: `pub fn parseXml(text: []const u8) !@This()`
- Work with optional fields (`?Timestamp`)
- Can return any error type
- Are treated as primitives (can be attributes or text content)

### Name Mapping

Map Zig field names to different XML names using `xml_names`:

```zig
const Book = struct {
    isbn: []const u8,
    max_score: u32,

    // Map snake_case to kebab-case
    pub const xml_names = .{
        .isbn = "ISBN-13",
        .max_score = "max-score",
    };
};

// XML: <book ISBN-13="978-0451524935" max-score="100"/>
// Zig: book.isbn = "978-0451524935", book.max_score = 100
```

For union variants in MultiIterator:

```zig
const MediaItem = union(enum) {
    book: Book,
    movie: Movie,

    pub const xml_names = .{
        .book = "book-item",
        .movie = "movie-item",
    };
};

// XML: <book-item .../> matches .book variant
// XML: <movie-item .../> matches .movie variant
```

Features:

- Partial mapping supported (unmapped fields use Zig names)
- Works for struct fields and union variants
- Case-sensitive matching
- Compile-time validated (typos caught at compile time)

### Parsing Strategies

**Eager Parsing** (no Iterator fields):

- Parses entire subtree immediately
- All data available after parsing
- Used for leaf structures (Book, Rating, Metadata)

**Lazy Parsing** (has Iterator/MultiIterator):

- Parses only attributes immediately
- Creates iterator for child elements
- Parsing resumes on each `next()` call
- Used for container structures (Collection, Library)

### Compile-Time Validation

The TypedParser validates your schema at compile time:

```zig
// ✓ Valid: eager struct (no iterator)
const Book = struct {
    title: []const u8,
    author: []const u8,
    rating: Rating,  // Nested eager struct is fine
};

// ✓ Valid: lazy struct with iterator
const Library = struct {
    name: []const u8,
    books: zxml.Iterator("book", Book),  // Book is eager, that's ok
};

// ✗ Invalid: eager struct cannot have lazy descendants
const Collection = struct {
    name: []const u8,
    library: Library,  // ERROR: Library is lazy (has iterator)
};
```

## PullParser

For low-level control, use the event-based PullParser directly:

```zig
var parser = zxml.PullParser.init(allocator, &reader.interface);
defer parser.deinit();

while (try parser.next()) |event| {
    switch (event) {
        .start_element => |elem| {
            std.debug.print("<{s}>\n", .{elem.name});
            for (elem.attributes) |attr| {
                std.debug.print("  {s}=\"{s}\"\n", .{attr.name, attr.value});
            }
        },
        .end_element => |elem| {
            std.debug.print("</{s}>\n", .{elem.name});
        },
        .text => |text| {
            std.debug.print("TEXT: {s}\n", .{text});
        },
        .cdata => |cdata| {
            std.debug.print("CDATA: {s}\n", .{cdata});
        },
        .comment => |comment| {
            std.debug.print("<!-- {s} -->\n", .{comment});
        },
        .xml_declaration => |decl| {
            std.debug.print("XML {s}\n", .{decl.version});
        },
        .doctype => |doctype| {
            std.debug.print("<!DOCTYPE {s}>\n", .{doctype.name});
        },
        else => {},
    }
}
```

### Event Types

```zig
pub const Event = union(enum) {
    start_document,
    end_document,
    start_element: struct { name: []const u8, attributes: []const Attribute },
    end_element: struct { name: []const u8 },
    text: []const u8,
    comment: []const u8,
    cdata: []const u8,
    processing_instruction: struct { target: []const u8, data: []const u8 },
    xml_declaration: struct { version: []const u8, encoding: ?[]const u8, standalone: ?bool },
    doctype: struct { name: []const u8, system_id: ?[]const u8, public_id: ?[]const u8 },
};
```

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zxml = .{
        .url = "https://github.com/yourusername/zxml/archive/main.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const zxml = b.dependency("zxml", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zxml", zxml.module("zxml"));
```

### Manual

Copy the repository and add to your `build.zig`:

```zig
const zxml_mod = b.addModule("zxml", .{
    .root_source_file = b.path("path/to/zxml/src/root.zig"),
});

exe.root_module.addImport("zxml", zxml_mod);
```

## Building

```bash
# Build everything
zig build

# Run tests (30+ tests)
zig build test

# Run examples
zig build run-pull-example
zig build run-typed-example

# Run benchmarks (ReleaseFast recommended)
zig build bench-pull -- <xml-file>
zig build bench-typed -- <xml-file>

# Generate test data
zig build generate-xml -- --libraries 10 --collections 5 --items 20 --output test.xml

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

## Architecture

### StringStorage

Stack-based string storage with mark/reset for bounded memory:

```zig
var storage = StringStorage.init(allocator);
defer storage.deinit();

storage.mark();  // Save position
const str = try storage.append("hello");  // Returns slice into buffer
// Use str...
storage.resetToMark();  // str is now invalid, memory freed
```

The PullParser uses this pattern to maintain bounded memory:

- Each element depth gets a mark
- Element close triggers resetToMark
- Memory usage = O(max element depth), not O(document size)

### Zero-Copy Semantics

All strings are slices into the parser's internal buffer:

```zig
while (try iterator.next()) |item| {
    // item.title, item.author are valid HERE
    const title = try allocator.dupe(u8, item.title);  // Copy if needed later
    defer allocator.free(title);
}
// After next(), previous strings are invalid
```

## Zig 0.15 Specifics

This library uses Zig 0.15's new `std.Io.Reader` interface:

```zig
// File reader
const file = try std.fs.cwd().openFile("file.xml", .{});
var buffer: [8192]u8 = undefined;
var file_reader = file.reader(&buffer);
const reader = &file_reader.interface;  // *std.Io.Reader

// Fixed buffer reader
const xml = "<?xml ...";
var reader = std.Io.Reader.fixed(xml);
```

## Limitations

- **UTF-8 Only**: Currently only supports UTF-8 encoded XML
- **Well-Formed Input**: Designed for known-good XML (minimal validation)
- **Zero-Copy Lifetime**: Strings valid only until next iteration

## Future Enhancements

- Validation rules (min/max, regex, custom validators)
- Better error messages with line/column numbers

## Documentation

- **[CLAUDE.md](CLAUDE.md)**: Comprehensive project documentation for Claude Code
- **[examples/](examples/)**: Working examples
- **[bench/](bench/)**: Benchmark tools

## Contributing

Contributions welcome! Please:

1. Run tests: `zig build test`
2. Follow existing code style
3. Add tests for new features
4. Update documentation

## License

MIT License

## Acknowledgments

- Inspired by Java's StAX for pull-style parsing
- Zig's comptime for type-safe code generation
- Zero-copy principles from high-performance parsers
