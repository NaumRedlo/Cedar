// Cedar FS: an in-RAM hierarchical filesystem.
//
// Design notes ("classic tree, modernised"):
// - names are case-insensitive but case-preserving, macOS-style:
//   /Home/Welcome.txt and /home/welcome.txt are the same file, and it
//   is stored with the capitalisation it was created with;
// - every node carries created/modified timestamps (scheduler ticks
//   for now), the seed for richer metadata (tags) later;
// - pure logic over an allocator: no kernel imports, fully
//   unit-testable on the host. The kernel provides the clock.
//
// Persistence comes later (virtio-blk + on-disk format); the API is
// deliberately kept storage-agnostic.

const std = @import("std");

pub const Kind = enum { file, dir };

pub const Error = error{
    NotFound,
    Exists,
    NotDir,
    IsDir,
    NotFile,
    NotEmpty,
    Busy,
    BadPath,
} || std.mem.Allocator.Error;

fn zeroClock() u64 {
    return 0;
}

pub const Node = struct {
    name: []u8, // owned, case-preserving
    kind: Kind,
    created: u64,
    modified: u64,
    parent: ?*Node,
    children: std.ArrayList(*Node) = .empty, // dirs
    data: std.ArrayList(u8) = .empty, // files
    open_count: u32 = 0, // live file descriptors pointing here

    pub fn size(self: *const Node) usize {
        return switch (self.kind) {
            .file => self.data.items.len,
            .dir => self.children.items.len,
        };
    }
};

pub const Fs = struct {
    alloc: std.mem.Allocator,
    root: *Node,
    clock: *const fn () u64 = &zeroClock,

    pub fn init(alloc: std.mem.Allocator) Error!Fs {
        const root = try alloc.create(Node);
        root.* = .{
            .name = try alloc.dupe(u8, ""),
            .kind = .dir,
            .created = 0,
            .modified = 0,
            .parent = null,
        };
        return .{ .alloc = alloc, .root = root };
    }

    fn nameEql(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    fn childByName(dir: *Node, name: []const u8) ?*Node {
        for (dir.children.items) |c| {
            if (nameEql(c.name, name)) return c;
        }
        return null;
    }

    pub fn lookup(self: *const Fs, path: []const u8) ?*Node {
        var cur = self.root;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (cur.kind != .dir) return null;
            cur = childByName(cur, seg) orelse return null;
        }
        return cur;
    }

    // Split into (existing parent dir, final segment).
    fn resolveParent(self: *const Fs, path: []const u8) Error!struct { dir: *Node, name: []const u8 } {
        var trimmed = std.mem.trim(u8, path, "/ ");
        if (trimmed.len == 0) return Error.BadPath;
        const cut = std.mem.lastIndexOfScalar(u8, trimmed, '/');
        const dir_path = if (cut) |i| trimmed[0..i] else "";
        const base = if (cut) |i| trimmed[i + 1 ..] else trimmed;
        if (base.len == 0) return Error.BadPath;
        const dir = self.lookup(dir_path) orelse return Error.NotFound;
        if (dir.kind != .dir) return Error.NotDir;
        return .{ .dir = dir, .name = base };
    }

    fn newNode(self: *Fs, dir: *Node, name: []const u8, kind: Kind) Error!*Node {
        if (childByName(dir, name) != null) return Error.Exists;
        const node = try self.alloc.create(Node);
        errdefer self.alloc.destroy(node);
        const now = self.clock();
        node.* = .{
            .name = try self.alloc.dupe(u8, name),
            .kind = kind,
            .created = now,
            .modified = now,
            .parent = dir,
        };
        try dir.children.append(self.alloc, node);
        dir.modified = now;
        return node;
    }

    pub fn mkdir(self: *Fs, path: []const u8) Error!*Node {
        const loc = try self.resolveParent(path);
        return self.newNode(loc.dir, loc.name, .dir);
    }

    pub fn create(self: *Fs, path: []const u8) Error!*Node {
        const loc = try self.resolveParent(path);
        return self.newNode(loc.dir, loc.name, .file);
    }

    // Create-or-replace file contents.
    pub fn write(self: *Fs, path: []const u8, bytes: []const u8) Error!void {
        const node = self.lookup(path) orelse blk: {
            break :blk try self.create(path);
        };
        if (node.kind != .file) return Error.NotFile;
        node.data.clearRetainingCapacity();
        try node.data.appendSlice(self.alloc, bytes);
        node.modified = self.clock();
    }

    pub fn read(self: *const Fs, path: []const u8) Error![]const u8 {
        const node = self.lookup(path) orelse return Error.NotFound;
        if (node.kind != .file) return Error.IsDir;
        return node.data.items;
    }

    pub fn serialize(self: *const Fs, w: anytype) !void {
        try serializeNode(self.root, w);
    }

    pub fn deserialize(alloc: std.mem.Allocator, r: anytype) !Fs {
        const root = try deserializeNode(alloc, null, r);
        if (root.kind != .dir or root.name.len != 0) return DeserializeError.Corrupt;
        return .{ .alloc = alloc, .root = root };
    }

    pub fn remove(self: *Fs, path: []const u8) Error!void {
        const node = self.lookup(path) orelse return Error.NotFound;
        const parent = node.parent orelse return Error.BadPath; // root
        if (node.kind == .dir and node.children.items.len != 0) return Error.NotEmpty;
        if (node.open_count != 0) return Error.Busy;

        const idx = std.mem.indexOfScalar(*Node, parent.children.items, node) orelse unreachable;
        _ = parent.children.orderedRemove(idx);
        parent.modified = self.clock();

        node.children.deinit(self.alloc);
        node.data.deinit(self.alloc);
        self.alloc.free(node.name);
        self.alloc.destroy(node);
    }
};

// --- snapshot serialization (CedarFS1) ---
//
// A depth-first stream of node records, storage-agnostic: the writer/
// reader only need writeAll/readAll. All integers little-endian.
//   record: u8 kind, u16 name_len, name, u64 created, u64 modified,
//           dir → u32 child_count + child records
//           file → u64 data_len + bytes

fn putInt(w: anytype, comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try w.writeAll(&b);
}

fn getInt(r: anytype, comptime T: type) !T {
    var b: [@sizeOf(T)]u8 = undefined;
    try r.readAll(&b);
    return std.mem.readInt(T, &b, .little);
}

fn serializeNode(node: *const Node, w: anytype) !void {
    try putInt(w, u8, @intFromEnum(node.kind));
    try putInt(w, u16, @intCast(node.name.len));
    try w.writeAll(node.name);
    try putInt(w, u64, node.created);
    try putInt(w, u64, node.modified);
    switch (node.kind) {
        .dir => {
            try putInt(w, u32, @intCast(node.children.items.len));
            for (node.children.items) |c| try serializeNode(c, w);
        },
        .file => {
            try putInt(w, u64, node.data.items.len);
            try w.writeAll(node.data.items);
        },
    }
}

const DeserializeError = error{ Corrupt, EndOfStream } || std.mem.Allocator.Error;

fn deserializeNode(alloc: std.mem.Allocator, parent: ?*Node, r: anytype) !*Node {
    const kind_raw = try getInt(r, u8);
    if (kind_raw > 1) return DeserializeError.Corrupt;
    const kind: Kind = @enumFromInt(kind_raw);
    const name_len = try getInt(r, u16);
    if (name_len > 255) return DeserializeError.Corrupt;
    var name_buf: [255]u8 = undefined;
    try r.readAll(name_buf[0..name_len]);

    const node = try alloc.create(Node);
    errdefer alloc.destroy(node);
    node.* = .{
        .name = try alloc.dupe(u8, name_buf[0..name_len]),
        .kind = kind,
        .created = try getInt(r, u64),
        .modified = try getInt(r, u64),
        .parent = parent,
    };
    if (parent) |p| try p.children.append(alloc, node);

    switch (kind) {
        .dir => {
            const count = try getInt(r, u32);
            if (count > 4096) return DeserializeError.Corrupt;
            for (0..count) |_| _ = try deserializeNode(alloc, node, r);
        },
        .file => {
            const len = try getInt(r, u64);
            if (len > 16 << 20) return DeserializeError.Corrupt;
            try node.data.resize(alloc, @intCast(len));
            try r.readAll(node.data.items);
        },
    }
    return node;
}

// Kernel-global instance, initialised in kmain once the heap is up.
pub var global: Fs = undefined;
pub var ready = false;

const testing = std.testing;

fn testFs() !Fs {
    return Fs.init(testing.allocator);
}

fn freeTree(fs: *Fs, node: *Node) void {
    while (node.children.items.len > 0) {
        freeTree(fs, node.children.items[node.children.items.len - 1]);
    }
    node.children.deinit(fs.alloc);
    node.data.deinit(fs.alloc);
    fs.alloc.free(node.name);
    const parent = node.parent;
    if (parent) |p| {
        const idx = std.mem.indexOfScalar(*Node, p.children.items, node) orelse unreachable;
        _ = p.children.orderedRemove(idx);
    }
    fs.alloc.destroy(node);
}

fn deinitTestFs(fs: *Fs) void {
    freeTree(fs, fs.root);
}

test "mkdir, create, lookup" {
    var fs = try testFs();
    defer deinitTestFs(&fs);

    _ = try fs.mkdir("/Programs");
    _ = try fs.mkdir("/Home");
    _ = try fs.create("/Home/notes.txt");

    try testing.expect(fs.lookup("/Home/notes.txt") != null);
    try testing.expect(fs.lookup("/Home").?.kind == .dir);
    try testing.expect(fs.lookup("/nope") == null);
    try testing.expectEqual(@as(usize, 2), fs.root.children.items.len);
}

test "case-insensitive lookup preserves case" {
    var fs = try testFs();
    defer deinitTestFs(&fs);

    _ = try fs.mkdir("/Home");
    try fs.write("/Home/Welcome.txt", "hi");

    const n = fs.lookup("/home/welcome.TXT") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Welcome.txt", n.name);
    try testing.expectError(Error.Exists, fs.create("/HOME/WELCOME.TXT"));
}

test "write, read, overwrite" {
    var fs = try testFs();
    defer deinitTestFs(&fs);

    try fs.write("/a.txt", "first");
    try testing.expectEqualStrings("first", try fs.read("/a.txt"));
    try fs.write("/a.txt", "second");
    try testing.expectEqualStrings("second", try fs.read("/a.txt"));
}

test "remove semantics" {
    var fs = try testFs();
    defer deinitTestFs(&fs);

    _ = try fs.mkdir("/d");
    try fs.write("/d/f", "x");
    try testing.expectError(Error.NotEmpty, fs.remove("/d"));
    try fs.remove("/d/f");
    try fs.remove("/d");
    try testing.expect(fs.lookup("/d") == null);
    try testing.expectError(Error.NotFound, fs.remove("/d"));
}

test "errors: parents, kinds, bad paths" {
    var fs = try testFs();
    defer deinitTestFs(&fs);

    try testing.expectError(Error.NotFound, fs.create("/no/such/dir.txt"));
    try fs.write("/f", "data");
    try testing.expectError(Error.NotDir, fs.create("/f/child"));
    try testing.expectError(Error.IsDir, fs.read("/"));
    try testing.expectError(Error.BadPath, fs.mkdir("/"));
}

const ListWriter = struct {
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    pub fn writeAll(self: *const ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.alloc, bytes);
    }
};

const SliceReader = struct {
    data: []const u8,
    off: usize = 0,
    pub fn readAll(self: *SliceReader, buf: []u8) !void {
        if (self.off + buf.len > self.data.len) return error.EndOfStream;
        @memcpy(buf, self.data[self.off..][0..buf.len]);
        self.off += buf.len;
    }
};

test "snapshot round-trip preserves the tree" {
    var fs = try testFs();
    defer deinitTestFs(&fs);
    _ = try fs.mkdir("/Programs");
    _ = try fs.mkdir("/Home");
    _ = try fs.mkdir("/Home/Ideas");
    try fs.write("/Home/Welcome.txt", "persist me");
    try fs.write("/Programs/bin", &[_]u8{ 0, 1, 2, 255, 254 });

    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(testing.allocator);
    try fs.serialize(&ListWriter{ .list = &blob, .alloc = testing.allocator });

    var reader = SliceReader{ .data = blob.items };
    var restored = try Fs.deserialize(testing.allocator, &reader);
    defer deinitTestFs(&restored);

    try testing.expectEqualStrings("persist me", try restored.read("/home/welcome.TXT"));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 255, 254 }, try restored.read("/Programs/bin"));
    try testing.expect(restored.lookup("/Home/Ideas").?.kind == .dir);
    try testing.expectEqualStrings("Welcome.txt", restored.lookup("/home/welcome.txt").?.name);
    try testing.expectEqual(fs.lookup("/Home/Welcome.txt").?.modified, restored.lookup("/Home/Welcome.txt").?.modified);
}

test "deserialize rejects corrupt streams" {
    var junk = SliceReader{ .data = &[_]u8{ 9, 0, 0 } }; // kind 9 = invalid
    try testing.expectError(error.Corrupt, Fs.deserialize(testing.allocator, &junk));
}

test "open files cannot be removed" {
    var fs = try testFs();
    defer deinitTestFs(&fs);

    try fs.write("/f", "data");
    const node = fs.lookup("/f").?;
    node.open_count = 1;
    try testing.expectError(Error.Busy, fs.remove("/f"));
    node.open_count = 0;
    try fs.remove("/f");
}

test "timestamps advance with the clock" {
    var fs = try testFs();
    defer deinitTestFs(&fs);

    const Clock = struct {
        var t: u64 = 100;
        fn now() u64 {
            t += 1;
            return t;
        }
    };
    fs.clock = &Clock.now;

    try fs.write("/f", "v1");
    const created = fs.lookup("/f").?.created;
    try fs.write("/f", "v2");
    const modified = fs.lookup("/f").?.modified;
    try testing.expect(modified > created);
}
