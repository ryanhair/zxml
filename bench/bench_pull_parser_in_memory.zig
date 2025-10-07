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

    // Read entire XML file into memory
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const xml = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024); // 1 GB max
    defer allocator.free(xml);

    // Initialize parser (in-memory mode)
    var parser = PullParser.initInMemory(allocator, xml);
    defer parser.deinit();

    // Benchmark: parse and count like bench_pull_parser does
    const start = std.time.nanoTimestamp();

    var library_count: u32 = 0;
    var collection_count: u32 = 0;
    var book_count: u32 = 0;
    var movie_count: u32 = 0;
    var music_count: u32 = 0;

    // Track depth to know when we're inside specific elements
    var in_library = false;
    var in_collection = false;

    while (try parser.next()) |event| {
        switch (event) {
            .start_element => |elem| {
                // Count elements like TypedParser does
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
                // Track when we exit elements
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
    const file_size = xml.len;
    const throughput_mbs = (@as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    // Print results (matching bench_pull_parser output format)
    std.debug.print("File: {s}\n", .{filename});
    std.debug.print("Size: {d} bytes ({d:.2} MB)\n", .{ file_size, @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0) });
    std.debug.print("Libraries: {d}\n", .{library_count});
    std.debug.print("Collections: {d}\n", .{collection_count});
    std.debug.print("Items: {d} (books: {d}, movies: {d}, music: {d})\n", .{ book_count + movie_count + music_count, book_count, movie_count, music_count });
    std.debug.print("Time: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("Throughput: {d:.2} MB/s\n", .{throughput_mbs});
}
