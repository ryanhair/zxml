const std = @import("std");

// Sample data for realistic content
const LIBRARY_NAMES = [_][]const u8{ "City Library", "University Library", "Public Library", "Research Library", "Digital Archive" };
const LIBRARY_LOCATIONS = [_][]const u8{ "Downtown", "Campus", "Suburb", "Metro Center", "Tech District" };
const COLLECTION_THEMES = [_][]const u8{ "Technology", "Literature", "Science", "History", "Arts", "Entertainment", "Education" };
const COLLECTION_NAMES = [_][]const u8{ "Classics", "Modern Works", "Bestsellers", "Academic", "Popular", "Archived", "Premium" };

const BOOK_TITLES = [_][]const u8{
    "The Algorithm Design Manual",
    "Clean Code",
    "Design Patterns",
    "The Pragmatic Programmer",
    "Introduction to Algorithms",
    "Structure and Interpretation of Computer Programs",
    "The Art of Computer Programming",
    "Code Complete",
    "Refactoring",
    "Domain-Driven Design",
    "1984",
    "Brave New World",
    "To Kill a Mockingbird",
    "The Great Gatsby",
    "Pride and Prejudice",
    "The Catcher in the Rye",
    "Lord of the Flies",
    "Animal Farm",
    "Fahrenheit 451",
    "The Hobbit",
};

const BOOK_AUTHORS = [_][]const u8{
    "Knuth",     "Martin",   "Fowler",  "Thomas",   "Hunt",    "Cormen",    "Rivest",
    "Leiserson", "Stein",    "Gamma",   "Helm",     "Johnson", "Vlissides", "McConnell",
    "Evans",     "Vernon",   "Newman",  "Orwell",   "Huxley",  "Lee",       "Fitzgerald",
    "Austen",    "Salinger", "Golding", "Bradbury", "Tolkien",
};

const MOVIE_TITLES = [_][]const u8{
    "The Matrix",               "Inception",                "Interstellar",          "The Dark Knight",
    "Pulp Fiction",             "The Shawshank Redemption", "The Godfather",         "Fight Club",
    "Forrest Gump",             "Goodfellas",               "The Lord of the Rings", "Star Wars",
    "Back to the Future",       "The Terminator",           "Alien",                 "Blade Runner",
    "The Silence of the Lambs", "Se7en",                    "The Usual Suspects",    "Memento",
};

const MOVIE_DIRECTORS = [_][]const u8{
    "Nolan",    "Wachowskis", "Spielberg", "Scorsese",   "Tarantino", "Kubrick",
    "Coppola",  "Fincher",    "Cameron",   "Scott",      "Jackson",   "Lucas",
    "Zemeckis", "Burton",     "Anderson",  "Villeneuve", "Cuaron",    "Del Toro",
    "Wright",   "Ritchie",
};

const MUSIC_TITLES = [_][]const u8{
    "Bohemian Rhapsody",   "Stairway to Heaven",      "Hotel California",
    "Sweet Child O' Mine", "Smells Like Teen Spirit", "Imagine",
    "One",                 "Nothing Else Matters",    "November Rain",
    "Comfortably Numb",    "Wish You Were Here",      "Black",
    "Alive",               "Jeremy",                  "Even Flow",
    "Under the Bridge",    "Californication",         "Everlong",
    "Learn to Fly",        "Times Like These",
};

const MUSIC_ARTISTS = [_][]const u8{
    "Queen",        "Led Zeppelin", "Eagles",             "Guns N' Roses", "Nirvana",
    "The Beatles",  "Metallica",    "Pink Floyd",         "Pearl Jam",     "Red Hot Chili Peppers",
    "Foo Fighters", "AC/DC",        "The Rolling Stones", "Aerosmith",     "Bon Jovi",
    "U2",           "Radiohead",    "Coldplay",           "Linkin Park",   "Green Day",
};

const MUSIC_ALBUMS = [_][]const u8{
    "A Night at the Opera",     "Led Zeppelin IV",          "Hotel California",
    "Appetite for Destruction", "Nevermind",                "Abbey Road",
    "The Black Album",          "The Wall",                 "Ten",
    "Californication",          "The Colour and the Shape", "Back in Black",
    "Exile on Main St.",        "Pump",                     "Slippery When Wet",
    "The Joshua Tree",          "OK Computer",              "Parachutes",
    "Hybrid Theory",            "American Idiot",
};

const BOOK_FORMATS = [_][]const u8{ "PDF", "EPUB", "MOBI", "AZW3" };
const MOVIE_FORMATS = [_][]const u8{ "4K_HDR", "1080p", "720p", "BluRay", "Digital" };
const MUSIC_FORMATS = [_][]const u8{ "FLAC", "MP3_320", "AAC", "WAV", "OGG" };

const Config = struct {
    libraries: u32 = 2,
    collections: u32 = 3,
    items: u32 = 10,
    output: []const u8,
    seed: ?u64 = null,
    pretty: bool = true,
};

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var libraries: u32 = 2;
    var collections: u32 = 3;
    var items: u32 = 10;
    var output_arg: ?[]const u8 = null;
    var seed: ?u64 = null;
    var pretty: bool = true;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--libraries") or std.mem.eql(u8, arg, "-l")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            libraries = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--collections") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            collections = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--items") or std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            items = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            output_arg = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--seed") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--no-pretty")) {
            pretty = false;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        }
    }

    return Config{
        .libraries = libraries,
        .collections = collections,
        .items = items,
        .output = output_arg orelse try allocator.dupe(u8, "media_library.xml"),
        .seed = seed,
        .pretty = pretty,
    };
}

fn printHelp() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(
        \\Usage: generate_media_library [options]
        \\
        \\Options:
        \\  -l, --libraries NUM    Number of libraries to generate (default: 2)
        \\  -c, --collections NUM  Number of collections per library (default: 3)
        \\  -i, --items NUM        Number of items per collection (default: 10)
        \\  -o, --output FILE      Output XML file name (default: media_library.xml)
        \\  -s, --seed NUM         Random seed for reproducible output
        \\  --no-pretty            Output compact XML without pretty printing
        \\  -h, --help             Show this help message
        \\
    );
    try stdout.flush();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try parseArgs(allocator);
    defer allocator.free(config.output);

    var prng = std.Random.DefaultPrng.init(config.seed orelse @intCast(std.time.milliTimestamp()));
    const random = prng.random();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const total_items = config.libraries * config.collections * config.items;

    try stdout.print("Generating XML with:\n", .{});
    try stdout.print("  - {d} libraries\n", .{config.libraries});
    try stdout.print("  - {d} collections per library ({d} total)\n", .{ config.collections, config.libraries * config.collections });
    try stdout.print("  - {d} items per collection ({d} total items)\n", .{ config.items, total_items });

    const file = try std.fs.cwd().createFile(config.output, .{});
    defer file.close();

    var file_buffer: [8192]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const writer = &file_writer.interface;

    // Write XML declaration
    try writer.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");

    // Generate platform
    try generatePlatform(writer, random, config, 0);

    try writer.flush();

    const stat = try file.stat();
    try stdout.print("\nGenerated {s} ({d} bytes)\n", .{ config.output, stat.size });
    try stdout.print("\nEstimated content distribution (randomized):\n", .{});
    try stdout.print("  - Books: ~{d} items\n", .{total_items / 3});
    try stdout.print("  - Movies: ~{d} items\n", .{total_items / 3});
    try stdout.print("  - Music: ~{d} items\n", .{total_items / 3});
    try stdout.flush();
}

fn generatePlatform(writer: anytype, random: std.Random, config: Config, indent: u32) !void {
    try writeIndent(writer, indent, config.pretty);
    try writer.print("<platform platform_id=\"DIGI-{d}\" name=\"StreamVault\" region=\"{s}\" subscription_fee=\"{d:.2}\" active=\"true\">\n", .{
        random.intRangeAtMost(u32, 1000, 9999),
        randomChoice([]const u8, random, &[_][]const u8{ "North America", "Europe", "Asia Pacific", "Global" }),
        4.99 + random.float(f64) * 15.0,
    });

    var lib: u32 = 0;
    while (lib < config.libraries) : (lib += 1) {
        try generateLibrary(writer, random, config, indent + 1, lib + 1);
    }

    try writeIndent(writer, indent, config.pretty);
    try writer.writeAll("</platform>\n");
}

fn generateLibrary(writer: anytype, random: std.Random, config: Config, indent: u32, lib_id: u32) !void {
    try writeIndent(writer, indent, config.pretty);
    try writer.print("<library name=\"{s} {d}\" location=\"{s}\" established=\"{d}\" public=\"{s}\">\n", .{
        randomChoice([]const u8, random, &LIBRARY_NAMES),
        lib_id,
        randomChoice([]const u8, random, &LIBRARY_LOCATIONS),
        random.intRangeAtMost(u32, 1800, 2020),
        if (random.boolean()) "true" else "false",
    });

    var coll: u32 = 0;
    while (coll < config.collections) : (coll += 1) {
        try generateCollection(writer, random, config, indent + 1, coll + 1);
    }

    try writeIndent(writer, indent, config.pretty);
    try writer.writeAll("</library>\n");
}

fn generateCollection(writer: anytype, random: std.Random, config: Config, indent: u32, coll_id: u32) !void {
    try writeIndent(writer, indent, config.pretty);
    try writer.print("<collection name=\"{s} {d}\" theme=\"{s}\" curated=\"{s}\">\n", .{
        randomChoice([]const u8, random, &COLLECTION_NAMES),
        coll_id,
        randomChoice([]const u8, random, &COLLECTION_THEMES),
        if (random.boolean()) "true" else "false",
    });

    var item: u32 = 0;
    while (item < config.items) : (item += 1) {
        const item_type = random.intRangeAtMost(u32, 0, 2);
        switch (item_type) {
            0 => try generateBook(writer, random, config, indent + 1),
            1 => try generateMovie(writer, random, config, indent + 1),
            2 => try generateMusic(writer, random, config, indent + 1),
            else => unreachable,
        }
    }

    try writeIndent(writer, indent, config.pretty);
    try writer.writeAll("</collection>\n");
}

fn generateBook(writer: anytype, random: std.Random, config: Config, indent: u32) !void {
    try writeIndent(writer, indent, config.pretty);
    try writer.print("<book isbn=\"978-{d}\" title=\"{s}\" author=\"{s}\" pages=\"{d}\">\n", .{
        random.intRangeAtMost(u64, 1000000000, 9999999999),
        randomChoice([]const u8, random, &BOOK_TITLES),
        randomChoice([]const u8, random, &BOOK_AUTHORS),
        random.intRangeAtMost(u32, 100, 1500),
    });

    // Metadata
    try writeIndent(writer, indent + 1, config.pretty);
    try writer.print("<metadata file_size=\"{d}\" format=\"{s}\" encrypted=\"{s}\"/>\n", .{
        random.intRangeAtMost(u32, 1, 100),
        randomChoice([]const u8, random, &BOOK_FORMATS),
        if (random.boolean()) "true" else "false",
    });

    // Optional rating (70% chance)
    if (random.float(f32) > 0.3) {
        try writeIndent(writer, indent + 1, config.pretty);
        try writer.print("<rating score=\"{d:.1}\" max_score=\"5\" verified=\"{s}\"/>\n", .{
            3.0 + random.float(f64) * 2.0,
            if (random.boolean()) "true" else "false",
        });
    }

    try writeIndent(writer, indent, config.pretty);
    try writer.writeAll("</book>\n");
}

fn generateMovie(writer: anytype, random: std.Random, config: Config, indent: u32) !void {
    try writeIndent(writer, indent, config.pretty);
    try writer.print("<movie imdb_id=\"tt{d}\" title=\"{s}\" director=\"{s}\" year=\"{d}\">\n", .{
        random.intRangeAtMost(u32, 1000000, 9999999),
        randomChoice([]const u8, random, &MOVIE_TITLES),
        randomChoice([]const u8, random, &MOVIE_DIRECTORS),
        random.intRangeAtMost(u32, 1970, 2024),
    });

    // Metadata
    try writeIndent(writer, indent + 1, config.pretty);
    try writer.print("<metadata file_size=\"{d}\" duration=\"{d}\" format=\"{s}\" encrypted=\"{s}\"/>\n", .{
        random.intRangeAtMost(u32, 700, 50000),
        random.intRangeAtMost(u32, 80, 200),
        randomChoice([]const u8, random, &MOVIE_FORMATS),
        if (random.boolean()) "true" else "false",
    });

    // Optional rating (80% chance)
    if (random.float(f32) > 0.2) {
        try writeIndent(writer, indent + 1, config.pretty);
        try writer.print("<rating score=\"{d:.1}\" max_score=\"10\" verified=\"{s}\"/>\n", .{
            5.0 + random.float(f64) * 5.0,
            if (random.boolean()) "true" else "false",
        });
    }

    try writeIndent(writer, indent, config.pretty);
    try writer.writeAll("</movie>\n");
}

fn generateMusic(writer: anytype, random: std.Random, config: Config, indent: u32) !void {
    try writeIndent(writer, indent, config.pretty);
    try writer.print("<music track_id=\"SPT-{d}\" title=\"{s}\" artist=\"{s}\" album=\"{s}\" track_number=\"{d}\">\n", .{
        random.intRangeAtMost(u32, 100, 999),
        randomChoice([]const u8, random, &MUSIC_TITLES),
        randomChoice([]const u8, random, &MUSIC_ARTISTS),
        randomChoice([]const u8, random, &MUSIC_ALBUMS),
        random.intRangeAtMost(u32, 1, 20),
    });

    // Metadata
    try writeIndent(writer, indent + 1, config.pretty);
    try writer.print("<metadata file_size=\"{d}\" duration=\"{d}\" format=\"{s}\" encrypted=\"{s}\"/>\n", .{
        random.intRangeAtMost(u32, 3, 50),
        random.intRangeAtMost(u32, 2, 8),
        randomChoice([]const u8, random, &MUSIC_FORMATS),
        if (random.boolean()) "true" else "false",
    });

    // Optional rating (50% chance)
    if (random.float(f32) > 0.5) {
        try writeIndent(writer, indent + 1, config.pretty);
        try writer.print("<rating score=\"{d:.1}\" max_score=\"5\" verified=\"{s}\"/>\n", .{
            3.0 + random.float(f64) * 2.0,
            if (random.boolean()) "true" else "false",
        });
    }

    try writeIndent(writer, indent, config.pretty);
    try writer.writeAll("</music>\n");
}

fn randomChoice(comptime T: type, random: std.Random, choices: []const T) T {
    const idx = random.intRangeLessThan(usize, 0, choices.len);
    return choices[idx];
}

fn writeIndent(writer: anytype, indent: u32, pretty: bool) !void {
    if (!pretty) return;
    var i: u32 = 0;
    while (i < indent) : (i += 1) {
        try writer.writeAll("    ");
    }
}
