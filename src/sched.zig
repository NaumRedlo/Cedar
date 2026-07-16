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
const timer = @import("timer.zig");
const arch = @import("arch.zig").impl;

const Frame = exceptions.Frame;

const MAX_THREADS = 8;
const STACK_PAGES = 4; // 16 KiB per thread

// SPSR for a fresh thread: EL1h, IRQs enabled, D/A/F masked.
const INITIAL_SPSR: u64 = 0x345;

pub const State = enum { unused, ready, running, sleeping, blocked, finished };

pub const Thread = struct {
    state: State = .unused,
    context: *Frame = undefined,
    name: []const u8 = "",
    stack_base: u64 = 0,
    wake_at: u64 = 0, // tick deadline while .sleeping
    wait_token: usize = 0, // what we're blocked on while .blocked
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

// Deschedule the current thread until `ticks_n` timer ticks pass.
// The idle thread (0) must never sleep — it is the scheduler's
// guarantee that something is always runnable.
pub fn sleep(ticks_n: u64) void {
    const daif = arch.irqSave();
    std.debug.assert(current != 0);
    threads[current].state = .sleeping;
    threads[current].wake_at = timer.now() + ticks_n;
    arch.irqRestore(daif);
    yield();
}

// Mark the current thread blocked on a token. Caller must hold IRQs
// masked and call yield() after unmasking; a concurrent wake between
// the two just makes the yield a no-op round trip.
pub fn blockCurrentOn(token: usize) void {
    std.debug.assert(current != 0);
    threads[current].state = .blocked;
    threads[current].wait_token = token;
}

// Wake one thread blocked on the token. Returns true if someone woke.
pub fn wakeOne(token: usize) bool {
    for (&threads) |*t| {
        if (t.state == .blocked and t.wait_token == token) {
            t.state = .ready;
            t.wait_token = 0;
            return true;
        }
    }
    return false;
}

fn wakeExpired() void {
    const now = timer.now();
    for (&threads) |*t| {
        if (t.state == .sleeping and t.wake_at <= now) {
            t.state = .ready;
        }
    }
}

// Called from exception context (timer tick or svc). Saves the
// interrupted thread's frame and picks the next ready one.
pub fn reschedule(frame: *Frame) *Frame {
    if (!started) return frame;

    wakeExpired();

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
