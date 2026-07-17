// A real cat: takes file paths as arguments, prints their contents.
// argc/argv arrive in x0/x1 straight from the kernel-built stack block.

fn sys(n: u64, a: u64, b: u64, c: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [n] "{x8}" (n),
          [a] "{x0}" (a),
          [b] "{x1}" (b),
          [c] "{x2}" (c),
        : .{ .memory = true });
}

fn print(s: []const u8) void {
    _ = sys(0, @intFromPtr(s.ptr), s.len, 0);
}

fn open(path: []const u8) i64 {
    return @bitCast(sys(4, @intFromPtr(path.ptr), path.len, 0));
}

fn read(fd: u64, buf: []u8) i64 {
    return @bitCast(sys(5, fd, @intFromPtr(buf.ptr), buf.len));
}

fn close(fd: u64) void {
    _ = sys(6, fd, 0, 0);
}

fn exit(code: u64) noreturn {
    _ = sys(2, code, 0, 0);
    while (true) {}
}

fn span(p: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return p[0..n];
}

fn cat(path: []const u8) bool {
    const fd = open(path);
    if (fd < 0) {
        print("cat: cannot open ");
        print(path);
        print("\n");
        return false;
    }
    var buf: [64]u8 = undefined;
    while (true) {
        const n = read(@intCast(fd), &buf);
        if (n <= 0) break;
        print(buf[0..@intCast(n)]);
    }
    close(@intCast(fd));
    return true;
}

export fn _start(argc: usize, argv: [*]const [*:0]const u8) linksection(".text.entry") callconv(.c) noreturn {
    if (argc < 2) {
        print("usage: cat <path> [more paths...]\n");
        exit(1);
    }
    var failed: u64 = 0;
    for (1..argc) |i| {
        if (!cat(span(argv[i]))) failed += 1;
    }
    exit(failed);
}
