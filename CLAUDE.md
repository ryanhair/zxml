# zxml - Streaming XML Parser for Zig

## Project Overview

zxml is a high-performance, streaming XML parser for Zig 0.15.1 featuring:
- **PullParser**: Low-level event-based XML parser with bounded memory usage
- **TypedParser**: High-level compile-time generated parser for strongly-typed XML schemas
- **Zero-copy**: String data references the parser's internal buffer (no allocations for strings)
- **Streaming**: Memory usage bounded by element depth, not document size
- **Performance**: 390 MB/s (PullParser) and 372 MB/s (TypedParser) in ReleaseFast mode

## Project Structure

```
zxml/
├── src/
│   ├── root.zig              # Public API exports
│   ├── pull_parser.zig       # Low-level event-based parser
│   ├── typed_parser.zig      # Compile-time typed parser generator
│   ├── string_storage.zig    # Stack-based string storage with mark/reset
│   └── main.zig              # CLI benchmark tool
├── examples/
│   ├── pull_parser_example.zig
│   └── typed_parser_example.zig
├── bench/
│   ├── bench_pull_parser.zig
│   ├── bench_typed_parser.zig
│   └── generate_media_library.zig  # Test data generator
├── build.zig
├── TYPED_PARSER_PLAN.md      # Detailed TypedParser design document
└── CLAUDE.md                 # This file
```

## Core Components

### 1. PullParser (src/pull_parser.zig)

Low-level event-based XML parser inspired by Java's StAX.

**Key Features:**
- Event-driven API with `next()` iterator
- Zero-copy string slices into internal buffer
- Bounded memory via stack-based StringStorage
- Handles: elements, attributes, text, CDATA, comments, processing instructions, DOCTYPE

**Event Types:**
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

**Usage Pattern:**
```zig
var parser = PullParser.init(allocator, &reader.interface);
defer parser.deinit();

while (try parser.next()) |event| {
    switch (event) {
        .start_element => |elem| {
            // elem.name, elem.attributes valid until element closes
        },
        .text => |text| { /* ... */ },
        .end_element => { /* ... */ },
        else => {},
    }
}
```

**Memory Model:**
- Owns a `StringStorage` instance
- StringStorage uses mark/resetToMark for bounded memory
- Each element depth gets a mark, reset on element close
- All strings are slices into StringStorage buffer

**Performance:** 390 MB/s (ReleaseFast on 12.29 MB test file)

### 2. TypedParser (src/typed_parser.zig)

Compile-time generated strongly-typed XML parser built on PullParser.

**Key Features:**
- Automatic type conversion (string → int, float, bool)
- Compile-time schema validation
- Lazy iteration with `Iterator` and `MultiIterator`
- Zero-copy string handling (inherits from PullParser)
- Eager vs lazy parsing determined at compile-time

**Type System:**

1. **Primitive Types** (parsed from attributes or element text):
   - Integers: `u32`, `i32`, etc. → `std.fmt.parseInt`
   - Floats: `f32`, `f64` → `std.fmt.parseFloat`
   - Bools: `bool` → "true"/"false"
   - Strings: `[]const u8` → zero-copy slice
   - Optionals: `?T` → null if missing

2. **Struct Types** (map to XML elements):
   - Fields map to attributes (primitives) or child elements (structs)
   - Field names must exactly match XML names (snake_case preserved)
   - Can be eager (no iterators) or lazy (has iterator)

3. **Iterator Types** (lazy loading):
   - `Iterator(tag_name, T)`: iterate over repeated elements with same tag
   - `MultiIterator(Union)`: iterate over mixed element types via tagged union
   - Constraint: maximum 1 iterator per struct

**Example Schema:**
```zig
const Book = struct {
    isbn: []const u8,      // Attribute
    title: []const u8,     // Attribute
    pages: u32,            // Attribute (auto-parsed)
    metadata: Metadata,    // Child element (eager)
    rating: ?Rating,       // Optional child element
};

const Collection = struct {
    name: []const u8,
    items: Iterator("item", Book),  // Lazy iteration
};
```

**Parsing Strategies:**

1. **Eager Parsing** (no Iterator fields):
   - Parses entire subtree immediately
   - All data available after parsing
   - Used for leaf structures (Book, Rating, Metadata)

2. **Lazy Parsing** (has Iterator/MultiIterator):
   - Parses only attributes immediately
   - Creates iterator for child elements
   - Parsing resumes on each `next()` call
   - Used for container structures (Collection, Library)

**Validation Rules:**
- Eager structs cannot have lazy descendants (compile-time error)
- Each struct can have at most 1 Iterator or MultiIterator field
- Union types for MultiIterator must be tagged: `union(enum)`

**Usage Pattern:**
```zig
const MyParser = TypedParser(MyRootStruct);
var parser = try MyParser.init(allocator, reader);
defer parser.deinit();

const root = &parser.result;

while (try root.children.next()) |*child| {
    // Access child.field_name
    // Data valid until next iteration
}
```

**Performance:** 372 MB/s (ReleaseFast, 95% of PullParser speed)

### 3. StringStorage (src/string_storage.zig)

Stack-based string storage with mark/reset for bounded memory usage.

**Key Concepts:**
- Preallocated buffer (grows if needed)
- `mark()`: Save current position
- `resetToMark()`: Free everything after last mark
- `append()`: Add string, return slice into buffer

**Memory Lifecycle:**
```
Element depth 0: mark()
  <root>
  Element depth 1: mark()
    <child>text</child>     append("text")
  Element depth 1 end: resetToMark()  // Frees "text"
</root>
Element depth 0 end: resetToMark()
```

**Usage:**
```zig
var storage = StringStorage.init(allocator);
defer storage.deinit();

storage.mark();  // Save position
const str = try storage.append("hello");  // Returns slice
// Use str...
storage.resetToMark();  // str is now invalid
```

## Zig 0.15.1 Specific Details

### Reader API
```zig
// File reader pattern
const file = try std.fs.cwd().openFile("file.xml", .{});
var buffer: [8192]u8 = undefined;
var file_reader = file.reader(&buffer);
const reader = &file_reader.interface;  // *std.Io.Reader
```

### Stdout Pattern
```zig
var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;
```

### Event Union Access
```zig
// Event fields accessed via struct:
.start_element => |elem| {
    elem.name        // Not event.start_element.name
    elem.attributes
}
.end_element => |elem| {
    const name = elem.name;  // Unpack first
}
```

## Build System (build.zig)

### Modules
- **zxml**: Main library (src/root.zig)
- **pull_parser**: PullParser-only module (src/pull_parser.zig)

### Executables
- **zxml**: Main CLI tool (src/main.zig)
- **pull_parser_example**: PullParser usage example
- **typed_parser_example**: TypedParser usage example
- **bench_pull_parser**: PullParser benchmark
- **bench_typed_parser**: TypedParser benchmark
- **generate_media_library**: Test data generator

### Build Commands
```bash
# Build everything
zig build

# Run tests (23 tests total)
zig build test

# Run examples
zig build run-pull-example
zig build run-typed-example

# Benchmarks
zig build bench-pull -- <file.xml>
zig build bench-typed -- <file.xml>

# Generate test data
zig build generate-xml -- --libraries 10 --collections 5 --items 20 --output test.xml

# ReleaseFast build
zig build -Doptimize=ReleaseFast
```

### Test Organization
- `src/root.zig`: Module-level tests
- `src/pull_parser.zig`: PullParser tests (8 tests)
- `src/typed_parser.zig`: TypedParser tests (15 tests)

All tests run via `zig build test` (configured in build.zig).

## Performance Characteristics

### Benchmarks (12.29 MB test file, 50,000 items)

**Debug Build:**
- PullParser: 37.23 MB/s
- TypedParser: 31.69 MB/s (85% of PullParser)

**ReleaseFast Build:**
- PullParser: 390.09 MB/s
- TypedParser: 372.42 MB/s (95% of PullParser)

### Memory Usage
- Bounded by element depth, not document size
- StringStorage preallocates 64KB (grows if needed)
- No heap allocations for string content (zero-copy)
- Parser struct size: ~200 bytes

### Scaling
- Linear time complexity: O(document size)
- Constant memory: O(max element depth)
- Tested up to 50,000 items with no performance degradation

## Common Patterns

### PullParser: Extract Specific Elements
```zig
var parser = PullParser.init(allocator, &reader.interface);
defer parser.deinit();

while (try parser.next()) |event| {
    if (event == .start_element) {
        const elem = event.start_element;
        if (std.mem.eql(u8, elem.name, "book")) {
            // Found a book element
            for (elem.attributes) |attr| {
                if (std.mem.eql(u8, attr.name, "title")) {
                    // attr.value valid until </book>
                    const title = try allocator.dupe(u8, attr.value);
                    defer allocator.free(title);
                }
            }
        }
    }
}
```

### TypedParser: Nested Lazy Iteration
```zig
const Platform = struct {
    name: []const u8,
    libraries: Iterator("library", Library),
};

const Library = struct {
    name: []const u8,
    books: Iterator("book", Book),
};

const Book = struct {
    title: []const u8,
    author: []const u8,
};

// Usage
const PlatformParser = TypedParser(Platform);
var parser = try PlatformParser.init(allocator, reader);
defer parser.deinit();

var platform = &parser.result;
while (try platform.libraries.next()) |*lib| {
    while (try lib.books.next()) |book| {
        std.debug.print("{s} by {s}\n", .{book.title, book.author});
    }
}
```

### TypedParser: Mixed Child Types
```zig
const MediaItem = union(enum) {
    book: Book,
    movie: Movie,
    music: Music,
};

const Collection = struct {
    name: []const u8,
    items: MultiIterator(MediaItem),  // Iterates over <book>, <movie>, <music>
};

// Usage
while (try collection.items.next()) |item| {
    switch (item) {
        .book => |book| std.debug.print("Book: {s}\n", .{book.title}),
        .movie => |movie| std.debug.print("Movie: {s}\n", .{movie.title}),
        .music => |music| std.debug.print("Music: {s}\n", .{music.title}),
    }
}
```

## Key Architectural Decisions

### 1. Stack-Based String Storage
**Decision:** Use mark/reset instead of reference counting or garbage collection.

**Rationale:**
- XML structure is inherently hierarchical (stack-like)
- Bounded memory regardless of document size
- No allocator overhead for string content
- Simple lifetime model: data valid until element closes

**Tradeoff:** Strings must be copied if needed beyond element scope.

### 2. Iterator Type Detection
**Decision:** Use `pub const __is_zxml_iterator = true;` marker in generated types.

**Rationale:**
- Zig 0.15.1 comptime reflection is limited
- Field-based detection had issues with comptime evaluation order
- Declaration-based detection is reliable and explicit

**Alternatives Tried:**
- Field presence checking (failed due to comptime evaluation)
- Type name pattern matching (fragile)

### 3. TypedParser Eager/Lazy Separation
**Decision:** Compile-time selection of parsing strategy based on Iterator presence.

**Rationale:**
- Optimal performance: no runtime branches
- Type safety: prevents accidental eager loading of large datasets
- Clear API: presence of Iterator field signals lazy loading

**Validation:** Eager structs cannot have lazy descendants (prevents memory issues).

### 4. Zero-Copy Strings
**Decision:** All strings are slices into parser's buffer.

**Rationale:**
- Maximum performance (no allocations)
- Clear lifetime semantics (valid until next iteration)
- Matches use case: most XML processing is streaming

**User Responsibility:** Call `allocator.dupe()` if string needed longer.

### 5. Exact Field Name Matching
**Decision:** Struct field names must exactly match XML names (for now).

**Rationale:**
- Simple, predictable behavior
- No magic transformations (snake_case ↔ kebab-case)
- Future: can add `@xmlName("custom-name")` attribute

## Future Enhancements

See TYPED_PARSER_PLAN.md "Future Enhancements" section for detailed plans:

1. **Configurable Name Mapping**
   - Field attributes: `@xmlName("custom-name")`
   - Case conversion: snake_case ↔ kebab-case ↔ camelCase

2. **Better Error Messages**
   - Include field path, line/column numbers
   - Detailed error context

3. **Default Values**
   - `@xmlDefault(value)` for missing fields

4. **Validation Rules**
   - Min/max constraints
   - Regex patterns
   - Custom validators

5. **Performance Optimizations**
   - Comptime hash maps for field lookup
   - SIMD for string parsing

## Testing Strategy

### Unit Tests (23 total)
- **PullParser** (8 tests): Element parsing, attributes, entities, XML declarations, DOCTYPE
- **TypedParser** (15 tests): Type detection, primitive parsing, struct parsing, iterators

### Integration Tests
- Examples serve as integration tests
- Verified with actual XML files

### Performance Tests
- Benchmarks with generated test data (50,000 items)
- Comparison between PullParser and TypedParser
- Debug vs ReleaseFast builds

### Test Data Generation
`generate_media_library.zig` creates realistic test data:
- Configurable: libraries, collections, items per collection
- Realistic: books, movies, music with metadata
- Randomized: ensures variety in test cases

## Troubleshooting

### Common Issues

**1. "MissingRequiredField" error**
- Cause: XML missing a non-optional field
- Fix: Make field optional (`?T`) or ensure XML has the field

**2. Iterator detection not working**
- Cause: Using old cached build
- Fix: `rm -rf .zig-cache zig-out && zig build`

**3. "Expected type '*Iterator', found '*const Iterator'"**
- Cause: Trying to modify iterator from const context
- Fix: Use pointer capture in while loop: `while (try iter.next()) |*item|`

**4. Strings disappear after iteration**
- Cause: Zero-copy strings invalidated on next()
- Fix: Copy strings before calling next(): `try allocator.dupe(u8, str)`

**5. Performance slower than expected**
- Cause: Debug build
- Fix: Build with `-Doptimize=ReleaseFast`

### Debugging Tips

**Enable verbose PullParser events:**
```zig
while (try parser.next()) |event| {
    std.debug.print("Event: {}\n", .{event});
}
```

**Check TypedParser schema validation:**
- Errors appear at compile-time
- Read error messages carefully (they explain the issue)

**Verify XML structure:**
- Use `zig build run-pull-example` to see raw events
- Compare with your TypedParser schema

## Project History

### Phase 1: PullParser (Initial Implementation)
- Created event-based XML parser
- Implemented StringStorage with mark/reset
- Converted to Zig 0.15.1's new `std.Io.Reader` interface
- Achieved 390 MB/s performance

### Phase 2: Build System & Tooling
- Set up modular build.zig
- Created examples and benchmarks
- Converted Python test generator to Zig
- Added comprehensive test suite

### Phase 3: TypedParser (Current)
- Designed compile-time typed parser
- Implemented comptime reflection and validation
- Built Iterator and MultiIterator types
- Created eager/lazy parsing strategies
- Achieved 372 MB/s (95% of PullParser speed)

## Contributing Guidelines

### Code Style
- Follow Zig standard library conventions
- Use `zig fmt` for formatting
- Document public APIs with `///` comments
- Use clear, descriptive names

### Testing
- Add tests for new features
- Run `zig build test` before committing
- Update benchmarks if performance-critical

### Documentation
- Update this file for architectural changes
- Update TYPED_PARSER_PLAN.md for TypedParser changes
- Add examples for new features

## License

(Add your license here)

## Contact

(Add contact information here)
