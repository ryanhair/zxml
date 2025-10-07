const std = @import("std");
const PullParser = @import("pull_parser").PullParser;

const Book = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    isbn: []const u8,
    available: bool,
    authors: std.ArrayList([]const u8),
    year: u32,
    pages: u32,
    price: f64,
    currency: []const u8,

    pub fn init(allocator: std.mem.Allocator) Book {
        return Book{
            .allocator = allocator,
            .id = "",
            .title = "",
            .isbn = "",
            .available = false,
            .authors = std.ArrayList([]const u8){},
            .year = 0,
            .pages = 0,
            .price = 0.0,
            .currency = "",
        };
    }

    pub fn deinit(self: *Book) void {
        if (self.id.len > 0) self.allocator.free(self.id);
        if (self.title.len > 0) self.allocator.free(self.title);
        if (self.isbn.len > 0) self.allocator.free(self.isbn);
        if (self.currency.len > 0) self.allocator.free(self.currency);
        for (self.authors.items) |author| {
            self.allocator.free(author);
        }
        self.authors.deinit(self.allocator);
    }

    pub fn print(self: *const Book) void {
        std.debug.print("Book: {s} (ID: {s})\n", .{ self.title, self.id });
        std.debug.print("  ISBN: {s}\n", .{self.isbn});
        std.debug.print("  Available: {}\n", .{self.available});
        std.debug.print("  Authors: ", .{});
        for (self.authors.items, 0..) |author, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{author});
        }
        std.debug.print("\n", .{});
        std.debug.print("  Published: {d} ({d} pages)\n", .{ self.year, self.pages });
        std.debug.print("  Price: {d:.2} {s}\n", .{ self.price, self.currency });
        std.debug.print("\n", .{});
    }
};

const ParseState = enum {
    Root,
    InLibrary,
    InBooks,
    InBook,
    InTitle,
    InAuthors,
    InAuthor,
    InAuthorName,
    InPublisher,
    InYear,
    InPages,
    InPrice,
    InDescription,
    Other,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read XML file
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const filename = if (args.len > 1) args[1] else "examples/books.xml";

    const xml_content = std.fs.cwd().readFileAlloc(allocator, filename, 1024 * 1024) catch |err| {
        std.debug.print("Error reading file '{s}': {}\n", .{ filename, err });
        return;
    };
    defer allocator.free(xml_content);

    std.debug.print("=== Pull Parser Example: Extracting Book Information ===\n\n", .{});

    // Initialize reader and parser
    var reader = std.Io.Reader.fixed(xml_content);
    var parser = PullParser.initWithReader(allocator, &reader);
    defer parser.deinit();

    var books = std.ArrayList(Book){};
    defer {
        for (books.items) |*book| {
            book.deinit();
        }
        books.deinit(allocator);
    }

    var state = ParseState.Root;
    var current_book: ?Book = null;

    // Parse the XML
    while (try parser.next()) |event| {
        switch (event) {
            .start_element => |elem| {
                if (std.mem.eql(u8, elem.name, "library")) {
                    state = .InLibrary;
                } else if (std.mem.eql(u8, elem.name, "books")) {
                    state = .InBooks;
                } else if (std.mem.eql(u8, elem.name, "book")) {
                    state = .InBook;
                    current_book = Book.init(allocator);

                    // Extract attributes - must copy since they'll be invalidated when element closes
                    for (elem.attributes) |attr| {
                        if (std.mem.eql(u8, attr.name, "id")) {
                            current_book.?.id = try allocator.dupe(u8, attr.value);
                        } else if (std.mem.eql(u8, attr.name, "isbn")) {
                            current_book.?.isbn = try allocator.dupe(u8, attr.value);
                        } else if (std.mem.eql(u8, attr.name, "available")) {
                            current_book.?.available = std.mem.eql(u8, attr.value, "true");
                        }
                    }
                } else if (state == .InBook) {
                    if (std.mem.eql(u8, elem.name, "title")) {
                        state = .InTitle;
                    } else if (std.mem.eql(u8, elem.name, "authors")) {
                        state = .InAuthors;
                    } else if (std.mem.eql(u8, elem.name, "year")) {
                        state = .InYear;
                    } else if (std.mem.eql(u8, elem.name, "pages")) {
                        state = .InPages;
                    } else if (std.mem.eql(u8, elem.name, "price")) {
                        state = .InPrice;
                        // Extract currency attribute - must copy
                        for (elem.attributes) |attr| {
                            if (std.mem.eql(u8, attr.name, "currency")) {
                                current_book.?.currency = try allocator.dupe(u8, attr.value);
                            }
                        }
                    }
                } else if (state == .InAuthors) {
                    if (std.mem.eql(u8, elem.name, "author")) {
                        state = .InAuthor;
                    }
                } else if (state == .InAuthor) {
                    if (std.mem.eql(u8, elem.name, "name")) {
                        state = .InAuthorName;
                    }
                }
            },

            .end_element => |elem| {
                if (std.mem.eql(u8, elem.name, "book")) {
                    // Finished parsing a book, add it to our collection
                    if (current_book) |book| {
                        try books.append(allocator, book);
                        current_book = null;
                    }
                    state = .InBooks;
                } else if (std.mem.eql(u8, elem.name, "books")) {
                    state = .InLibrary;
                } else if (std.mem.eql(u8, elem.name, "library")) {
                    state = .Root;
                } else if (std.mem.eql(u8, elem.name, "authors")) {
                    state = .InBook;
                } else if (std.mem.eql(u8, elem.name, "author")) {
                    state = .InAuthors;
                } else if (std.mem.eql(u8, elem.name, "name") and state == .InAuthorName) {
                    state = .InAuthor;
                } else {
                    // Return to book context for other elements
                    if (state == .InTitle or state == .InYear or state == .InPages or state == .InPrice) {
                        state = .InBook;
                    }
                }
            },

            .text => |content| {
                if (current_book) |*book| {
                    switch (state) {
                        .InTitle => book.title = try allocator.dupe(u8, content),
                        .InYear => book.year = std.fmt.parseInt(u32, content, 10) catch 0,
                        .InPages => book.pages = std.fmt.parseInt(u32, content, 10) catch 0,
                        .InPrice => book.price = std.fmt.parseFloat(f64, content) catch 0.0,
                        .InAuthorName => {
                            const author_copy = try allocator.dupe(u8, content);
                            try book.authors.append(allocator, author_copy);
                        },
                        else => {},
                    }
                }
            },

            .end_document => break,
            else => {}, // Handle other events if needed
        }
    }

    // Display results
    std.debug.print("Found {} books:\n\n", .{books.items.len});
    for (books.items) |*book| {
        book.print();
    }

    // Summary statistics
    var total_pages: u32 = 0;
    var available_count: u32 = 0;
    var total_price: f64 = 0.0;

    for (books.items) |book| {
        total_pages += book.pages;
        if (book.available) available_count += 1;
        total_price += book.price;
    }

    std.debug.print("=== Library Statistics ===\n", .{});
    std.debug.print("Total books: {}\n", .{books.items.len});
    std.debug.print("Available books: {}\n", .{available_count});
    std.debug.print("Total pages: {}\n", .{total_pages});
    std.debug.print("Average price: ${d:.2}\n", .{total_price / @as(f64, @floatFromInt(books.items.len))});
}