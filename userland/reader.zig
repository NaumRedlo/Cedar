// Reads Cedar FS files from EL0 through open/read/close syscalls,
// deliberately with a tiny buffer so the fd offset has to advance
// across multiple reads.

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

fn dump(path: []const u8) void {
    print("reader: --- ");
    print(path);
    print(" ---\n");
    const fd = open(path);
    if (fd < 0) {
        print("reader: open failed\n");
        return;
    }
    var buf: [24]u8 = undefined;
    while (true) {
        const n = read(@intCast(fd), &buf);
        if (n <= 0) break;
        print(buf[0..@intCast(n)]);
    }
    close(@intCast(fd));
}

export fn _start() linksection(".text.entry") callconv(.c) noreturn {
    dump("/System/version.txt");
    dump("/home/WELCOME.txt"); // case-insensitive path, on purpose
    print("reader: checking the error path...\n");
    if (open("/no/such/file") < 0) {
        print("reader: open('/no/such/file') correctly failed\n");
    }
    exit(0);
}
