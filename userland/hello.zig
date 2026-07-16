// The first Cedar user program. Runs at EL0: no direct hardware access,
// everything goes through syscalls.

fn sys(n: u64, a: u64, b: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [n] "{x8}" (n),
          [a] "{x0}" (a),
          [b] "{x1}" (b),
        : .{ .memory = true });
}

fn print(s: []const u8) void {
    _ = sys(0, @intFromPtr(s.ptr), s.len);
}

fn sleep(ticks: u64) void {
    _ = sys(1, ticks, 0);
}

fn exit(code: u64) noreturn {
    _ = sys(2, code, 0);
    while (true) {}
}

export fn _start() linksection(".text.entry") callconv(.c) noreturn {
    print("hello from EL0! Cedar runs user programs now\n");
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        sleep(5);
        print("EL0: awake again, all systems nominal\n");
    }
    print("EL0: goodbye\n");
    exit(0);
}
