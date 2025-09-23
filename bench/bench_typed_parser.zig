const std = @import("std");
const zxml = @import("zxml");

const TypedParser = zxml.TypedParser;
const Iterator = zxml.Iterator;
const MultiIterator = zxml.MultiIterator;

// Schema definition (same as example)
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

const Movie = struct {
    imdb_id: []const u8,
    title: []const u8,
    director: []const u8,
    year: u32,
    metadata: Metadata,
    rating: ?Rating,
};

const Music = struct {
    track_id: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    track_number: u32,
    metadata: Metadata,
    rating: ?Rating,
};

const MediaItem = union(enum) {
    book: Book,
    movie: Movie,
    music: Music,
};

const Collection = struct {
    name: []const u8,
    theme: []const u8,
    curated: bool,
    items: MultiIterator(MediaItem),
};

const Library = struct {
    name: []const u8,
    location: []const u8,
    established: u32,
    public: bool,
    collections: Iterator("collection", Collection),
};

const DigitalPlatform = struct {
    platform_id: []const u8,
    name: []const u8,
    region: []const u8,
    subscription_fee: f32,
    active: bool,
    libraries: Iterator("library", Library),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get filename from command line
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <xml-file>\n", .{args[0]});
        std.process.exit(1);
    }

    const filename = args[1];

    // Read the XML file
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var buffer: [256 * 1024]u8 = undefined;
    var file_reader = file.reader(&buffer);
    const reader = &file_reader.interface;

    // Benchmark: parse and iterate through entire document
    const start = std.time.nanoTimestamp();

    const DigitalPlatformParser = TypedParser(DigitalPlatform);
    var parser = try DigitalPlatformParser.init(allocator, reader);
    defer parser.deinit();

    var platform = &parser.result;

    var library_count: u32 = 0;
    var collection_count: u32 = 0;
    var book_count: u32 = 0;
    var movie_count: u32 = 0;
    var music_count: u32 = 0;

    while (try platform.libraries.next()) |*library| {
        library_count += 1;
        while (try library.collections.next()) |*collection| {
            collection_count += 1;
            while (try collection.items.next()) |item| {
                switch (item) {
                    .book => book_count += 1,
                    .movie => movie_count += 1,
                    .music => music_count += 1,
                }
            }
        }
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns = end - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const file_info = try file.stat();
    const throughput_mbs = (@as(f64, @floatFromInt(file_info.size)) / (1024.0 * 1024.0)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    // Print results
    std.debug.print("File: {s}\n", .{filename});
    std.debug.print("Size: {d} bytes ({d:.2} MB)\n", .{ file_info.size, @as(f64, @floatFromInt(file_info.size)) / (1024.0 * 1024.0) });
    std.debug.print("Libraries: {d}\n", .{library_count});
    std.debug.print("Collections: {d}\n", .{collection_count});
    std.debug.print("Items: {d} (books: {d}, movies: {d}, music: {d})\n", .{ book_count + movie_count + music_count, book_count, movie_count, music_count });
    std.debug.print("Time: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("Throughput: {d:.2} MB/s\n", .{throughput_mbs});
}
