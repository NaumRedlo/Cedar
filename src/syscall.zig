// The syscall surface between EL0 and the kernel. ABI: svc #0 with the
// call number in x8, arguments in x0..x1, result in x0 (Linux-style).

const log = @import("log.zig");
const sched = @import("sched.zig");
const timer = @import("timer.zig");
const exceptions = @import("exceptions.zig");
const user = @import("user.zig");
const fs = @import("fs.zig");

const Frame = exceptions.Frame;

pub const WRITE = 0; // write(ptr, len) -> len | -1
pub const SLEEP = 1; // sleep(ticks)
pub const EXIT = 2; // exit(code) -> never returns
pub const TICKS = 3; // ticks() -> u64
pub const OPEN = 4; // open(path_ptr, path_len) -> fd | -1
pub const READ = 5; // read(fd, buf_ptr, buf_len) -> n (0 = EOF) | -1
pub const CLOSE = 6; // close(fd) -> 0 | -1

const FAIL: u64 = @bitCast(@as(i64, -1));

// A user pointer is only trusted if the whole range lies inside the
// process's own window (its TTBR0 is live, so access just works).
fn userSlice(ptr: u64, len: u64, max: u64) ?[]u8 {
    if (len == 0 or len > max) return null;
    if (ptr < user.CODE_VA or ptr + len > user.STACK_TOP) return null;
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}

pub fn dispatch(frame: *Frame) *Frame {
    switch (frame.x[8]) {
        WRITE => {
            if (userSlice(frame.x[0], frame.x[1], 4096)) |s| {
                log.kprint(s);
                frame.x[0] = s.len;
            } else {
                frame.x[0] = FAIL;
            }
            return frame;
        },
        SLEEP => return sched.sleepInHandler(frame, frame.x[0]),
        EXIT => return sched.exitInHandler(frame, frame.x[0]),
        TICKS => {
            frame.x[0] = timer.now();
            return frame;
        },
        OPEN => {
            frame.x[0] = sysOpen(frame.x[0], frame.x[1]);
            return frame;
        },
        READ => {
            frame.x[0] = sysRead(frame.x[0], frame.x[1], frame.x[2]);
            return frame;
        },
        CLOSE => {
            frame.x[0] = sysClose(frame.x[0]);
            return frame;
        },
        else => {
            frame.x[0] = FAIL;
            return frame;
        },
    }
}

fn sysOpen(path_ptr: u64, path_len: u64) u64 {
    if (!fs.ready) return FAIL;
    const path = userSlice(path_ptr, path_len, 256) orelse return FAIL;
    const node = fs.global.lookup(path) orelse return FAIL;
    if (node.kind != .file) return FAIL;

    const t = sched.currentThread();
    const slot = for (&t.fds, 0..) |maybe, i| {
        if (maybe == null) break i;
    } else return FAIL;

    t.fds[slot] = .{ .node = node };
    node.open_count += 1;
    return slot;
}

fn sysRead(fd: u64, buf_ptr: u64, buf_len: u64) u64 {
    const buf = userSlice(buf_ptr, buf_len, 64 * 1024) orelse return FAIL;
    const t = sched.currentThread();
    if (fd >= sched.MAX_FDS) return FAIL;
    // Capture by pointer: the offset must advance in the table itself.
    if (t.fds[@intCast(fd)]) |*handle| {
        const data = handle.node.data.items;
        if (handle.offset >= data.len) return 0; // EOF
        const n = @min(buf.len, data.len - handle.offset);
        @memcpy(buf[0..n], data[handle.offset..][0..n]);
        handle.offset += n;
        return n;
    }
    return FAIL;
}

fn sysClose(fd: u64) u64 {
    const t = sched.currentThread();
    if (fd >= sched.MAX_FDS) return FAIL;
    const handle = t.fds[@intCast(fd)] orelse return FAIL;
    handle.node.open_count -= 1;
    t.fds[@intCast(fd)] = null;
    return 0;
}
