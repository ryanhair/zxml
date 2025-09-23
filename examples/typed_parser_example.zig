const std = @import("std");
const zxml = @import("zxml");

const TypedParser = zxml.TypedParser;
const Iterator = zxml.Iterator;
const MultiIterator = zxml.MultiIterator;

// ============================================================================
// Feature Showcase: Custom Type Parser
// ============================================================================

/// Custom type with parseXml for parsing ISO-style timestamps
const Timestamp = struct {
    year: u32,
    month: u32,
    day: u32,

    pub fn parseXml(text: []const u8) !@This() {
        // Parse "YYYY-MM-DD" format
        if (text.len != 10 or text[4] != '-' or text[7] != '-') {
            return error.InvalidTimestampFormat;
        }

        const year = try std.fmt.parseInt(u32, text[0..4], 10);
        const month = try std.fmt.parseInt(u32, text[5..7], 10);
        const day = try std.fmt.parseInt(u32, text[8..10], 10);

        return .{ .year = year, .month = month, .day = day };
    }

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    }
};

// ============================================================================
// Feature Showcase: Default Values & Name Mapping
// ============================================================================

const Rating = struct {
    score: f32,
    max_score: u32 = 5, // Default value: max_score defaults to 5 if not present
    verified: bool = false, // Default value: defaults to false

    // Name mapping: XML uses kebab-case
    pub const xml_names = .{
        .max_score = "max-score",
    };
};

const Metadata = struct {
    file_size: u32,
    duration: ?u32,
    format: []const u8,
    encrypted: bool = false, // Default value: defaults to false

    // Name mapping: XML uses kebab-case
    pub const xml_names = .{
        .file_size = "file-size",
    };
};

const Book = struct {
    isbn: []const u8,
    title: []const u8,
    author: []const u8,
    pages: u32,
    published: ?Timestamp, // Custom type parser in action
    metadata: Metadata,
    rating: ?Rating,
};

const Movie = struct {
    imdb_id: []const u8,
    title: []const u8,
    director: []const u8,
    year: u32,
    released: ?Timestamp, // Custom type parser
    metadata: Metadata,
    rating: ?Rating,

    // Name mapping for imdb_id
    pub const xml_names = .{
        .imdb_id = "imdb-id",
    };
};

const Music = struct {
    track_id: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    track_number: u32,
    released: ?Timestamp, // Custom type parser
    metadata: Metadata,
    rating: ?Rating,

    // Name mapping
    pub const xml_names = .{
        .track_id = "track-id",
        .track_number = "track-number",
    };
};

const MediaItem = union(enum) {
    book: Book,
    movie: Movie,
    music: Music,
};

const Collection = struct {
    name: []const u8,
    theme: []const u8,
    curated: bool = false, // Default value
    items: MultiIterator(MediaItem),
};

const Library = struct {
    name: []const u8,
    location: []const u8,
    established: u32,
    public: bool = true, // Default value: defaults to public
    collections: Iterator("collection", Collection),
};

const DigitalPlatform = struct {
    platform_id: []const u8,
    name: []const u8,
    region: []const u8,
    subscription_fee: f32,
    active: bool = true, // Default value
    libraries: Iterator("library", Library),

    // Name mapping: XML uses kebab-case for multi-word attributes
    pub const xml_names = .{
        .platform_id = "platform-id",
        .subscription_fee = "subscription-fee",
    };
};

const xml_content =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<platform platform-id="DIGI-7791" name="StreamVault" region="Asia Pacific" subscription-fee="5.01">
    \\    <library name="Digital Archive" location="Downtown" established="2012" public="false">
    \\        <collection name="Modern Works" theme="Entertainment" curated="true">
    \\            <music track-id="SPT-973" title="Under the Bridge" artist="Radiohead" album="OK Computer" track-number="10" released="2023-06-15">
    \\                <metadata file-size="17" duration="4" format="FLAC"/>
    \\                <rating score="4.0" max-score="5" verified="true"/>
    \\            </music>
    \\            <movie imdb-id="tt1375666" title="Inception" director="Christopher Nolan" year="2010" released="2010-07-16">
    \\                <metadata file-size="32025" duration="148" format="1080p" encrypted="true"/>
    \\                <rating score="8.8"/>
    \\            </movie>
    \\        </collection>
    \\        <collection name="Bestsellers" theme="Technology">
    \\            <book isbn="978-0321125217" title="Domain-Driven Design" author="Eric Evans" pages="560" published="2003-08-30">
    \\                <metadata file-size="66" format="EPUB"/>
    \\                <rating score="4.5"/>
    \\            </book>
    \\            <music track-id="SPT-783" title="Bohemian Rhapsody" artist="Queen" album="A Night at the Opera" track-number="11" released="1975-10-31">
    \\                <metadata file-size="15" duration="6" format="FLAC" encrypted="false"/>
    \\                <rating score="5.0" verified="true"/>
    \\            </music>
    \\        </collection>
    \\    </library>
    \\    <library name="City Library" location="Midtown" established="1915">
    \\        <collection name="Classics" theme="Literature" curated="true">
    \\            <book isbn="978-0451524935" title="1984" author="George Orwell" pages="328" published="1949-06-08">
    \\                <metadata file-size="2" format="MOBI"/>
    \\                <rating score="4.7" verified="true"/>
    \\            </book>
    \\            <music track-id="SPT-706" title="Stairway to Heaven" artist="Led Zeppelin" album="Led Zeppelin IV" track-number="4" released="1971-11-08">
    \\                <metadata file-size="28" duration="8" format="MP3"/>
    \\            </music>
    \\        </collection>
    \\    </library>
    \\</platform>
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reader = std.Io.Reader.fixed(xml_content);

    // Create the typed parser
    const DigitalPlatformParser = TypedParser(DigitalPlatform);
    var parser = try DigitalPlatformParser.init(allocator, &reader);
    defer parser.deinit();

    var platform = &parser.result;

    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  zxml TypedParser Example - New Features Showcase         ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n\n", .{});

    std.debug.print("Features demonstrated:\n", .{});
    std.debug.print("  ✓ Custom Type Parsers (Timestamp with parseXml)\n", .{});
    std.debug.print("  ✓ Default Values (active, public, curated, etc.)\n", .{});
    std.debug.print("  ✓ Name Mapping (platform-id → platform_id, etc.)\n\n", .{});

    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    std.debug.print("Platform: {s}\n", .{platform.name});
    std.debug.print("  ID: {s} (mapped from 'platform-id')\n", .{platform.platform_id});
    std.debug.print("  Region: {s}\n", .{platform.region});
    std.debug.print("  Fee: ${d:.2} (mapped from 'subscription-fee')\n", .{platform.subscription_fee});
    std.debug.print("  Active: {} (default value used)\n\n", .{platform.active});

    var library_count: u32 = 0;
    while (try platform.libraries.next()) |*library| {
        library_count += 1;
        std.debug.print("─────────────────────────────────────────────────────────\n", .{});
        std.debug.print("📚 Library #{d}: {s}\n", .{ library_count, library.name });
        std.debug.print("   Location: {s}\n", .{library.location});
        std.debug.print("   Established: {d}\n", .{library.established});
        std.debug.print("   Public: {}\n\n", .{library.public});

        var collection_count: u32 = 0;
        while (try library.collections.next()) |*collection| {
            collection_count += 1;
            std.debug.print("  📁 Collection #{d}: {s}\n", .{ collection_count, collection.name });
            std.debug.print("     Theme: {s}, Curated: {}\n\n", .{ collection.theme, collection.curated });

            var book_count: u32 = 0;
            var movie_count: u32 = 0;
            var music_count: u32 = 0;

            while (try collection.items.next()) |item| {
                switch (item) {
                    .book => |book| {
                        book_count += 1;
                        std.debug.print("     📖 {s} by {s}\n", .{ book.title, book.author });
                        std.debug.print("        ISBN: {s}, Pages: {d}\n", .{ book.isbn, book.pages });
                        if (book.published) |pub_date| {
                            std.debug.print("        Published: {any} (custom parser)\n", .{pub_date});
                        }
                        std.debug.print("        Format: {s}, Size: {d}MB, Encrypted: {}\n", .{
                            book.metadata.format,
                            book.metadata.file_size,
                            book.metadata.encrypted,
                        });
                        if (book.rating) |rating| {
                            std.debug.print("        Rating: {d:.1}/{d} (verified: {})\n", .{
                                rating.score,
                                rating.max_score,
                                rating.verified,
                            });
                        }
                        std.debug.print("\n", .{});
                    },
                    .movie => |movie| {
                        movie_count += 1;
                        std.debug.print("     🎬 {s} ({d}) by {s}\n", .{ movie.title, movie.year, movie.director });
                        std.debug.print("        IMDB: {s} (mapped from 'imdb-id')\n", .{movie.imdb_id});
                        if (movie.released) |rel_date| {
                            std.debug.print("        Released: {any} (custom parser)\n", .{rel_date});
                        }
                        std.debug.print("        Format: {s}, Size: {d}MB", .{
                            movie.metadata.format,
                            movie.metadata.file_size,
                        });
                        if (movie.metadata.duration) |duration| {
                            std.debug.print(", Duration: {d}min", .{duration});
                        }
                        std.debug.print(", Encrypted: {}\n", .{movie.metadata.encrypted});
                        if (movie.rating) |rating| {
                            std.debug.print("        Rating: {d:.1}/{d} (max defaults to 5)\n", .{
                                rating.score,
                                rating.max_score,
                            });
                        }
                        std.debug.print("\n", .{});
                    },
                    .music => |music| {
                        music_count += 1;
                        std.debug.print("     🎵 {s} by {s}\n", .{ music.title, music.artist });
                        std.debug.print("        Track ID: {s} (mapped from 'track-id')\n", .{music.track_id});
                        std.debug.print("        Album: {s}, Track #: {d}\n", .{ music.album, music.track_number });
                        if (music.released) |rel_date| {
                            std.debug.print("        Released: {any} (custom parser)\n", .{rel_date});
                        }
                        std.debug.print("        Format: {s}, Size: {d}MB", .{
                            music.metadata.format,
                            music.metadata.file_size,
                        });
                        if (music.metadata.duration) |duration| {
                            std.debug.print(", Duration: {d}min", .{duration});
                        }
                        std.debug.print("\n", .{});
                        if (music.rating) |rating| {
                            std.debug.print("        Rating: {d:.1} (verified: {})\n", .{
                                rating.score,
                                rating.verified,
                            });
                        }
                        std.debug.print("\n", .{});
                    },
                }
            }

            std.debug.print("     ✓ {d} books, {d} movies, {d} tracks\n\n", .{ book_count, movie_count, music_count });
        }

        std.debug.print("  ✓ {d} collections in this library\n\n", .{collection_count});
    }

    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("✅ Successfully parsed {d} libraries!\n", .{library_count});
    std.debug.print("\nKey takeaways:\n", .{});
    std.debug.print("  • Custom parseXml() enables domain-specific parsing\n", .{});
    std.debug.print("  • Default values reduce XML verbosity\n", .{});
    std.debug.print("  • xml_names handles any naming convention\n", .{});
}
