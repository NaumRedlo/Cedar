// Round-robin scheduler over kernel threads.
//
// The context-switch mechanism rides on the exception path: every
// interrupt/svc lands in vectors.S, which saves the full Frame on the
// interrupted thread's own stack and lets handleException return the
// frame to resume. Returning another thread's saved frame IS the
// context switch — vectors.S repoints sp and erets into it.

const std = @import("std");
const exceptions = @import("exceptions.zig");
const mem = @import("mem.zig");
const log = @import("log.zig");

const Frame = exceptions.Frame;

const MAX_THREADS = 8;
const STACK_PAGES = 4; // 16 KiB per thread

// SPSR for a fresh thread: EL1h, IRQs enabled, D/A/F masked.
const INITIAL_SPSR: u64 = 0x345;

pub const State = enum { unused, ready, running, finished };

pub const Thread = struct {
    state: State = .unused,
    context: *Frame = undefined,
    name: []const u8 = "",
    stack_base: u64 = 0,
};

var threads: [MAX_THREADS]Thread = @splat(.{});
var current: usize = 0;
var started = false;

// The boot flow becomes thread 0; its context gets captured by the
// first preemption automatically.
pub fn init() void {
    threads[0] = .{ .state = .running, .name = "main" };
    started = true;
}

pub const SpawnError = error{ NoSlot, NoMemory };

pub fn spawn(name: []const u8, entry: *const fn () callconv(.c) void) SpawnError!void {
    const slot = for (&threads, 0..) |*t, i| {
        if (t.state == .unused) break i;
    } else return error.NoSlot;

    const stack_base = mem.frames.allocContiguous(STACK_PAGES) orelse return error.NoMemory;
    const stack_top = stack_base + STACK_PAGES * mem.PAGE_SIZE;

    // Fabricate the frame eret will consume: entry point in ELR, thread
    // exit as the return address, sp ends up at stack_top after restore.
    const frame: *Frame = @ptrFromInt(stack_top - @sizeOf(Frame));
    frame.* = .{ .x = @splat(0), .elr = @intFromPtr(entry), .spsr = INITIAL_SPSR };
    frame.x[30] = @intFromPtr(&threadExit);

    threads[slot] = .{
        .state = .ready,
        .context = frame,
        .name = name,
        .stack_base = stack_base,
    };
}

fn threadExit() callconv(.c) noreturn {
    threads[current].state = .finished;
    log.kprintf("sched: thread '{s}' finished\n", .{threads[current].name});
    while (true) asm volatile ("wfi"); // descheduled on the next tick, never resumed
}

// Voluntarily give up the rest of the time slice.
pub fn yield() void {
    asm volatile ("svc #0");
}

// Called from exception context (timer tick or svc). Saves the
// interrupted thread's frame and picks the next ready one.
pub fn reschedule(frame: *Frame) *Frame {
    if (!started) return frame;

    threads[current].context = frame;
    if (threads[current].state == .running) threads[current].state = .ready;

    var i = (current + 1) % MAX_THREADS;
    var scanned: usize = 0;
    while (scanned < MAX_THREADS) : (scanned += 1) {
        if (threads[i].state == .ready) {
            current = i;
            threads[i].state = .running;
            return threads[i].context;
        }
        i = (i + 1) % MAX_THREADS;
    }
    @panic("scheduler: no runnable threads");
}
