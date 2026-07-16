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

    pub fn remove(self: *Fs, path: []const u8) Error!void {
        const node = self.lookup(path) orelse return Error.NotFound;
        const parent = node.parent orelse return Error.BadPath; // root
        if (node.kind == .dir and node.children.items.len != 0) return Error.NotEmpty;

        const idx = std.mem.indexOfScalar(*Node, parent.children.items, node) orelse unreachable;
        _ = parent.children.orderedRemove(idx);
        parent.modified = self.clock();

        node.children.deinit(self.alloc);
        node.data.deinit(self.alloc);
        self.alloc.free(node.name);
        self.alloc.destroy(node);
    }
};

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
