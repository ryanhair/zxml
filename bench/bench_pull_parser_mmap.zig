const std = @import("std");
const PullParser = @import("pull_parser").PullParser;

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

    // Get file size for stats
    const file = try std.fs.cwd().openFile(filename, .{});
    const file_size = (try file.stat()).size;
    file.close();

    // Benchmark: parse and count using mmap
    const start = std.time.nanoTimestamp();

    // Initialize parser with memory-mapped file (parser handles mmap internally)
    var parser = try PullParser.initWithMmap(allocator, filename);
    defer parser.deinit();

    var library_count: u32 = 0;
    var collection_count: u32 = 0;
    var book_count: u32 = 0;
    var movie_count: u32 = 0;
    var music_count: u32 = 0;

    var in_library = false;
    var in_collection = false;

    while (try parser.next()) |event| {
        switch (event) {
            .start_element => |elem| {
                if (std.mem.eql(u8, elem.name, "library")) {
                    library_count += 1;
                    in_library = true;
                } else if (std.mem.eql(u8, elem.name, "collection") and in_library) {
                    collection_count += 1;
                    in_collection = true;
                } else if (in_collection) {
                    if (std.mem.eql(u8, elem.name, "book")) {
                        book_count += 1;
                    } else if (std.mem.eql(u8, elem.name, "movie")) {
                        movie_count += 1;
                    } else if (std.mem.eql(u8, elem.name, "music")) {
                        music_count += 1;
                    }
                }
            },
            .end_element => |elem| {
                if (std.mem.eql(u8, elem.name, "library")) {
                    in_library = false;
                } else if (std.mem.eql(u8, elem.name, "collection")) {
                    in_collection = false;
                }
            },
            else => {},
        }
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns = end - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const throughput_mbs = (@as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("File: {s}\n", .{filename});
    std.debug.print("Size: {d} bytes ({d:.2} MB)\n", .{ file_size, @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0) });
    std.debug.print("Libraries: {d}\n", .{library_count});
    std.debug.print("Collections: {d}\n", .{collection_count});
    std.debug.print("Items: {d} (books: {d}, movies: {d}, music: {d})\n", .{ book_count + movie_count + music_count, book_count, movie_count, music_count });
    std.debug.print("Time: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("Throughput: {d:.2} MB/s\n", .{throughput_mbs});
    std.debug.print("\nNote: Uses memory-mapped file (mmap) - OS handles paging\n", .{});
}
