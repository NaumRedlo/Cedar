// The syscall surface between EL0 and the kernel. ABI: svc #0 with the
// call number in x8, arguments in x0..x1, result in x0 (Linux-style).

const log = @import("log.zig");
const sched = @import("sched.zig");
const timer = @import("timer.zig");
const exceptions = @import("exceptions.zig");
const user = @import("user.zig");

const Frame = exceptions.Frame;

pub const WRITE = 0; // write(ptr, len) -> len | -1
pub const SLEEP = 1; // sleep(ticks)
pub const EXIT = 2; // exit(code) -> never returns
pub const TICKS = 3; // ticks() -> u64

const FAIL: u64 = @bitCast(@as(i64, -1));

pub fn dispatch(frame: *Frame) *Frame {
    switch (frame.x[8]) {
        WRITE => {
            const ptr = frame.x[0];
            const len = frame.x[1];
            // The pointer must lie inside the process's own window.
            if (len <= 4096 and ptr >= user.CODE_VA and ptr + len <= user.STACK_TOP) {
                log.kprint(@as([*]const u8, @ptrFromInt(ptr))[0..len]);
                frame.x[0] = len;
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
        else => {
            frame.x[0] = FAIL;
            return frame;
        },
    }
}
