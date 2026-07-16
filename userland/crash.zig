// Deliberately misbehaving user program: proves that a process fault
// kills the process, not the system. It tries to read kernel memory,
// which its EL0 mappings forbid.

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

export fn _start() linksection(".text.entry") callconv(.c) noreturn {
    print("crash: greetings from EL0, about to read kernel memory...\n");
    const p: *volatile u64 = @ptrFromInt(0xffffff80_4008_0000);
    _ = p.*;
    print("crash: THIS LINE MUST NEVER PRINT\n");
    while (true) {}
}
