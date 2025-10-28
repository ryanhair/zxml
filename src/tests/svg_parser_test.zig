const std = @import("std");
const zxml = @import("zxml");

const xml_content = @embedFile("./tiger.svg");

test "svg parse test with mmap" {
    try withMmap(std.testing.allocator);
}

test "svg parse test with stream" {
    try withStream(std.testing.allocator);
}

test "svg parse test with memory" {
    try withMemory(std.testing.allocator);
}

fn withMmap(allocator: std.mem.Allocator) !void {
    var parser = try SvgParser.initWithMmap(allocator, "src/tests/tiger.svg");

    defer parser.deinit();
    var doc = try parser.parse();
    defer doc.deinit();

    try std.testing.expectEqual(240, doc.paths.items.len);
}

fn withStream(allocator: std.mem.Allocator) !void {
    var reader = std.Io.Reader.fixed(xml_content);
    var parser = try SvgParser.initStream(allocator, &reader);

    defer parser.deinit();
    var doc = try parser.parse();
    defer doc.deinit();

    try std.testing.expectEqual(240, doc.paths.items.len);
}

fn withMemory(allocator: std.mem.Allocator) !void {
    var parser = try SvgParser.initInMemory(allocator, xml_content);

    defer parser.deinit();
    var doc = try parser.parse();
    defer doc.deinit();

    try std.testing.expectEqual(240, doc.paths.items.len);
}

pub const SvgPath = struct {
    dummy: u8 = 0, // we just need this to have a non-zero size

    fn parse(allocator: std.mem.Allocator, xml: SvgXml.PathXml) !SvgPath {
        // ignored for this test...
        _ = allocator;
        _ = xml;
        return SvgPath{};
    }
};

const SvgXml = struct {
    paths: zxml.Iterator("path", SvgXml.PathXml),

    const PathXml = struct {
        d: []const u8,
    };
};

pub const SvgDocument = struct {
    allocator: std.mem.Allocator,

    paths: std.ArrayList(SvgPath) = std.ArrayList(SvgPath).empty,

    pub fn deinit(self: *SvgDocument) void {
        self.paths.deinit(self.allocator);
    }
};

pub const SvgParser = struct {
    const Parser = zxml.TypedParser(SvgXml);

    parser: Parser,

    pub fn initWithMmap(allocator: std.mem.Allocator, filepath: []const u8) !SvgParser {
        var parser = Parser.initWithMmap(allocator, filepath) catch |err| {
            std.log.err("could not parse SVG: {}", .{err});
            return error.InvalidSvg;
        };
        errdefer parser.deinit();
        return SvgParser{ .parser = parser };
    }

    pub fn initInMemory(allocator: std.mem.Allocator, xml: []const u8) !SvgParser {
        var parser = Parser.initInMemory(allocator, xml) catch |err| {
            std.log.err("could not parse SVG: {}", .{err});
            return error.InvalidSvg;
        };
        errdefer parser.deinit();
        return SvgParser{ .parser = parser };
    }

    pub fn initStream(allocator: std.mem.Allocator, reader: *std.io.Reader) !SvgParser {
        var parser = Parser.init(allocator, reader) catch |err| {
            std.log.err("could not parse SVG: {}", .{err});
            return error.InvalidSvg;
        };
        errdefer parser.deinit();
        return SvgParser{ .parser = parser };
    }

    pub fn parse(self: *SvgParser) !SvgDocument {
        const allocator = self.parser.allocator;
        var doc = SvgDocument{
            .allocator = allocator,
            .paths = try std.ArrayList(SvgPath).initCapacity(allocator, 240),
        };

        // We (used to) have a crash in Release builds here
        while (try self.parser.result.paths.next()) |item| {
            const path = try SvgPath.parse(allocator, item);
            try doc.paths.append(allocator, path);
        }

        return doc;
    }

    pub fn deinit(self: *SvgParser) void {
        self.parser.deinit();
    }
};
