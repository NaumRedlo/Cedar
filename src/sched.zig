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
const mmu = @import("mmu.zig");
const user = @import("user.zig");
const fs = @import("fs.zig");

const Frame = exceptions.Frame;

const MAX_THREADS = 8;
const STACK_PAGES = 4; // 16 KiB per thread

// SPSR for a fresh thread: EL1h, IRQs enabled, D/A/F masked.
const INITIAL_SPSR: u64 = 0x345;

pub const State = enum { unused, ready, running, sleeping, blocked, finished };

pub const MAX_FDS = 8;

pub const Fd = struct {
    node: *fs.Node,
    offset: usize = 0,
};

pub const Thread = struct {
    state: State = .unused,
    context: *Frame = undefined,
    name: []const u8 = "",
    stack_base: u64 = 0,
    wake_at: u64 = 0, // tick deadline while .sleeping
    wait_token: usize = 0, // what we're blocked on while .blocked
    ttbr0: ?u64 = null, // user page table root; null = pure kernel thread
    fds: [MAX_FDS]?Fd = @splat(null), // open files (user processes)
};

pub fn currentThread() *Thread {
    return &threads[current];
}

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

// SPSR for a fresh EL0 process: EL0t, IRQs enabled, D/A/F masked.
const USER_SPSR: u64 = 0x340;

// Free a finished thread's resources and return its slot to the pool.
// Must never run while executing on the thread's own kernel stack or
// with its TTBR0 live — callers guarantee the thread is not `current`.
fn reapThread(t: *Thread) void {
    if (t.stack_base != 0) {
        for (0..STACK_PAGES) |p| mem.frames.free(t.stack_base + p * mem.PAGE_SIZE);
    }
    if (t.ttbr0) |root| user.destroy(root);
    for (t.fds) |maybe| {
        if (maybe) |h| h.node.open_count -= 1;
    }
    t.* = .{}; // back to .unused
}

// Sweep finished threads other than the current one. Deferred by
// design: a thread that just exited is still `current` during its own
// reschedule and only gets reaped on a later one, by which point we are
// running on a different stack with a different TTBR0.
fn reapFinished() void {
    for (&threads, 0..) |*t, i| {
        if (i != current and t.state == .finished) reapThread(t);
    }
}

fn allocSlot(name: []const u8) SpawnError!struct { slot: usize, kstack_top: u64 } {
    reapFinished();
    const slot = for (&threads, 0..) |*t, i| {
        if (t.state == .unused) break i;
    } else return error.NoSlot;

    const stack_base = mem.frames.allocContiguous(STACK_PAGES) orelse return error.NoMemory;
    const stack_top = mmu.p2v(stack_base + STACK_PAGES * mem.PAGE_SIZE);
    threads[slot] = .{ .state = .ready, .name = name, .stack_base = stack_base };
    return .{ .slot = slot, .kstack_top = stack_top };
}

pub fn spawn(name: []const u8, entry: *const fn () callconv(.c) void) SpawnError!void {
    const s = try allocSlot(name);

    // Fabricate the frame eret will consume: entry point in ELR, thread
    // exit as the return address, sp ends up at stack_top after restore.
    const frame: *Frame = @ptrFromInt(s.kstack_top - @sizeOf(Frame));
    frame.* = .{ .x = @splat(0), .elr = @intFromPtr(entry), .spsr = INITIAL_SPSR };
    frame.x[30] = @intFromPtr(&threadExit);
    threads[s.slot].context = frame;
}

// A process: erets to EL0 at entry_va on its own TTBR0 table; exceptions
// from EL0 land on the thread's kernel stack (SP_EL1 = kstack top).
// x0/x1 arrive at _start as argc/argv.
pub fn spawnUser(name: []const u8, img: user.Image) SpawnError!void {
    const s = try allocSlot(name);

    const frame: *Frame = @ptrFromInt(s.kstack_top - @sizeOf(Frame));
    frame.* = .{ .x = @splat(0), .elr = img.entry, .spsr = USER_SPSR, .sp_el0 = img.sp };
    frame.x[0] = img.argc;
    frame.x[1] = img.argv;
    threads[s.slot].context = frame;
    threads[s.slot].ttbr0 = img.ttbr0;
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

// --- helpers for exception-context callers (syscalls, faults) ---

pub fn killCurrent(frame: *Frame, reason: []const u8) *Frame {
    log.kprintf("sched: '{s}' killed ({s})\n", .{ threads[current].name, reason });
    threads[current].state = .finished;
    return reschedule(frame);
}

pub fn exitInHandler(frame: *Frame, code: u64) *Frame {
    log.kprintf("sched: '{s}' exited (code {d})\n", .{ threads[current].name, code });
    threads[current].state = .finished;
    return reschedule(frame);
}

pub fn sleepInHandler(frame: *Frame, ticks_n: u64) *Frame {
    threads[current].state = .sleeping;
    threads[current].wake_at = timer.now() + ticks_n;
    return reschedule(frame);
}

pub fn ps() void {
    for (&threads, 0..) |*t, i| {
        if (t.state == .unused) continue;
        log.kprintf("  {d}  {s: <12} {s}{s}\n", .{
            i, t.name, @tagName(t.state), if (t.ttbr0 != null) @as([]const u8, "  [user]") else "",
        });
    }
}

// Called from exception context (timer tick or svc). Saves the
// interrupted thread's frame and picks the next ready one.
pub fn reschedule(frame: *Frame) *Frame {
    if (!started) return frame;

    reapFinished();
    wakeExpired();

    threads[current].context = frame;
    if (threads[current].state == .running) threads[current].state = .ready;

    var i = (current + 1) % MAX_THREADS;
    var scanned: usize = 0;
    while (scanned < MAX_THREADS) : (scanned += 1) {
        if (threads[i].state == .ready) {
            current = i;
            threads[i].state = .running;
            switchUserTable(threads[i].ttbr0);
            return threads[i].context;
        }
        i = (i + 1) % MAX_THREADS;
    }
    @panic("scheduler: no runnable threads");
}

// Point TTBR0 at the next process's table. Kernel threads keep whatever
// table is loaded — they never touch low addresses. No ASIDs yet, so a
// switch pays a full TLB flush.
var hw_ttbr0: u64 = mmu.BOOT_TABLE_PHYS;
var kernel_low: u64 = mmu.BOOT_TABLE_PHYS;

pub fn setKernelLowTable(phys: u64) void {
    kernel_low = phys;
    hw_ttbr0 = phys;
}

fn switchUserTable(table: ?u64) void {
    const t = table orelse kernel_low;
    if (t == hw_ttbr0) return;
    hw_ttbr0 = t;
    asm volatile (
        \\msr ttbr0_el1, %[t]
        \\tlbi vmalle1
        \\dsb nsh
        \\isb
        :
        : [t] "r" (t),
    );
}
