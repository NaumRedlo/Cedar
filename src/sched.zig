// Round-robin scheduler over kernel threads, SMP-aware.
//
// The context-switch mechanism rides on the exception path: every
// interrupt/svc lands in vectors.S, which saves the full Frame on the
// interrupted thread's own stack and lets handleException return the
// frame to resume. Returning another thread's saved frame IS the
// context switch — vectors.S repoints sp and erets into it.
//
// Every core schedules from one shared thread table under a spinlock;
// each core has its own `current` slot, idle thread and live TTBR0.
// Lock order: the scheduler lock may be held while taking the log
// lock, never the other way around.

const std = @import("std");
const exceptions = @import("exceptions.zig");
const mem = @import("mem.zig");
const log = @import("log.zig");
const timer = @import("timer.zig");
const arch = @import("arch.zig").impl;
const mmu = @import("mmu.zig");
const user = @import("user.zig");
const fs = @import("fs.zig");
const sync = @import("sync.zig");

const Frame = exceptions.Frame;

pub const MAX_CPUS = 4;
const MAX_THREADS = 16;
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
    cpu: u8 = 0, // owning core — a thread never migrates
    is_idle: bool = false, // per-core idle thread, pinned, never picked
};

pub fn currentThread() *Thread {
    return &threads[current[arch.cpuId()]];
}

var threads: [MAX_THREADS]Thread = @splat(.{});
var current: [MAX_CPUS]usize = @splat(0);
var idle: [MAX_CPUS]usize = @splat(0);
var next_owner: u8 = 0; // round-robin core assignment for new threads
var started = false;
var lock = sync.SpinLock{};

// The boot flow becomes thread 0 — cpu 0's idle; its context gets
// captured by the first preemption automatically.
pub fn init() void {
    threads[0] = .{ .state = .running, .name = "idle0", .cpu = 0, .is_idle = true };
    idle[0] = 0;
    started = true;
}

// A secondary core's boot flow becomes that core's idle thread. Called
// once per core from smp.secondaryMain, on that core.
pub fn adoptIdle(cpu: u64, name: []const u8) void {
    const daif = lock.lock();
    defer lock.unlock(daif);
    const slot = for (&threads, 0..) |*t, i| {
        if (t.state == .unused) break i;
    } else @panic("no slot for idle thread");
    threads[slot] = .{ .state = .running, .name = name, .cpu = @intCast(cpu), .is_idle = true };
    current[cpu] = slot;
    idle[cpu] = slot;
}

pub const SpawnError = error{ NoSlot, NoMemory };

// SPSR for a fresh EL0 process: EL0t, IRQs enabled, D/A/F masked.
const USER_SPSR: u64 = 0x340;

// Free a finished thread's resources and return its slot to the pool.
// Must never run while executing on the thread's own kernel stack or
// with its TTBR0 live — callers guarantee the thread is not current
// on ANY core.
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

fn isCurrentAnywhere(i: usize) bool {
    for (current) |c| {
        if (c == i) return true;
    }
    return false;
}

// Sweep finished threads not current on any core. Deferred by design:
// a thread that just exited is still `current` on its core during its
// own reschedule and only gets reaped later, by which point that core
// runs a different stack with a different TTBR0. Caller holds the lock.
fn reapFinished() void {
    for (&threads, 0..) |*t, i| {
        if (t.state == .finished and !isCurrentAnywhere(i)) reapThread(t);
    }
}

fn allocSlot(name: []const u8) SpawnError!struct { slot: usize, kstack_top: u64 } {
    const daif = lock.lock();
    defer lock.unlock(daif);
    reapFinished();
    const slot = for (&threads, 0..) |*t, i| {
        if (t.state == .unused) break i;
    } else return error.NoSlot;

    const stack_base = mem.frames.allocContiguous(STACK_PAGES) orelse return error.NoMemory;
    const stack_top = mmu.p2v(stack_base + STACK_PAGES * mem.PAGE_SIZE);
    // Assign the new thread to a core round-robin, so work spreads out.
    const owner = next_owner;
    next_owner = (next_owner + 1) % active_cpus;
    threads[slot] = .{ .state = .ready, .name = name, .stack_base = stack_base, .cpu = owner };
    return .{ .slot = slot, .kstack_top = stack_top };
}

var active_cpus: u8 = 1; // raised by smp as cores come online

pub fn setActiveCpus(n: u8) void {
    active_cpus = n;
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
    const cpu = arch.cpuId();
    threads[current[cpu]].state = .finished;
    log.kprintf("sched: thread '{s}' finished\n", .{threads[current[cpu]].name});
    while (true) asm volatile ("wfi"); // descheduled on the next tick, never resumed
}

// Voluntarily give up the rest of the time slice.
pub fn yield() void {
    asm volatile ("svc #0");
}

// Deschedule the current thread until `ticks_n` timer ticks pass.
// Idle threads must never sleep — they guarantee each core always has
// something runnable.
pub fn sleep(ticks_n: u64) void {
    const daif = lock.lock();
    const cur = current[arch.cpuId()];
    std.debug.assert(!threads[cur].is_idle);
    threads[cur].state = .sleeping;
    threads[cur].wake_at = timer.now() + ticks_n;
    lock.unlock(daif);
    yield();
}

// Mark the current thread blocked on a token, then yield. A wake racing
// the yield just makes it a no-op round trip.
pub fn blockCurrentOn(token: usize) void {
    const daif = lock.lock();
    const cur = current[arch.cpuId()];
    std.debug.assert(!threads[cur].is_idle);
    threads[cur].state = .blocked;
    threads[cur].wait_token = token;
    lock.unlock(daif);
}

// Wake one thread blocked on the token. Returns true if someone woke.
pub fn wakeOne(token: usize) bool {
    const daif = lock.lock();
    defer lock.unlock(daif);
    for (&threads) |*t| {
        if (t.state == .blocked and t.wait_token == token) {
            t.state = .ready;
            t.wait_token = 0;
            return true;
        }
    }
    return false;
}

// Caller holds the lock (invoked from inside reschedule).
fn wakeExpiredLocked() void {
    const now = timer.now();
    for (&threads) |*t| {
        if (t.state == .sleeping and t.wake_at <= now) {
            t.state = .ready;
        }
    }
}

// --- helpers for exception-context callers (syscalls, faults) ---

pub fn killCurrent(frame: *Frame, reason: []const u8) *Frame {
    const cpu = arch.cpuId();
    log.kprintf("sched: '{s}' killed ({s})\n", .{ threads[current[cpu]].name, reason });
    threads[current[cpu]].state = .finished;
    return reschedule(frame);
}

pub fn exitInHandler(frame: *Frame, code: u64) *Frame {
    const cpu = arch.cpuId();
    log.kprintf("sched: '{s}' exited (code {d})\n", .{ threads[current[cpu]].name, code });
    threads[current[cpu]].state = .finished;
    return reschedule(frame);
}

pub fn sleepInHandler(frame: *Frame, ticks_n: u64) *Frame {
    const cpu = arch.cpuId();
    threads[current[cpu]].state = .sleeping;
    threads[current[cpu]].wake_at = timer.now() + ticks_n;
    return reschedule(frame);
}

pub fn ps() void {
    const daif = lock.lock();
    defer lock.unlock(daif);
    for (&threads, 0..) |*t, i| {
        if (t.state == .unused) continue;
        log.kprintf("  {d}  cpu{d}  {s: <12} {s}{s}\n", .{
            i, t.cpu, t.name, @tagName(t.state), if (t.ttbr0 != null) @as([]const u8, "  [user]") else "",
        });
    }
}

// Called from exception context (timer tick or svc) on the current
// core. Saves the interrupted thread's frame and picks the next thread
// owned by THIS core; if none is ready, runs this core's idle thread.
// Threads never migrate, so the picked thread's stack/TTBR0 are only
// ever touched here — no cross-core stack hazard.
pub fn reschedule(frame: *Frame) *Frame {
    if (!started) return frame;
    const cpu = arch.cpuId();

    const daif = lock.lock();
    reapFinished();
    wakeExpiredLocked();

    const prev = current[cpu];
    threads[prev].context = frame;
    if (threads[prev].state == .running and !threads[prev].is_idle) {
        threads[prev].state = .ready;
    }

    var chosen = idle[cpu];
    var i = (prev + 1) % MAX_THREADS;
    var scanned: usize = 0;
    while (scanned < MAX_THREADS) : (scanned += 1) {
        if (threads[i].state == .ready and threads[i].cpu == cpu and !threads[i].is_idle) {
            chosen = i;
            break;
        }
        i = (i + 1) % MAX_THREADS;
    }

    current[cpu] = chosen;
    threads[chosen].state = .running;
    const table = threads[chosen].ttbr0;
    const ctx = threads[chosen].context;
    lock.unlock(daif);

    switchUserTable(cpu, table);
    return ctx;
}

// Point this core's TTBR0 at the next process's table. Kernel threads
// keep whatever table is loaded — they never touch low addresses. No
// ASIDs yet, so a switch pays a full local TLB flush. hw_ttbr0 is
// per-core: each core tracks its own live table.
var hw_ttbr0: [MAX_CPUS]u64 = @splat(mmu.BOOT_TABLE_PHYS);
var kernel_low: u64 = mmu.BOOT_TABLE_PHYS;

pub fn setKernelLowTable(phys: u64) void {
    kernel_low = phys;
    hw_ttbr0 = @splat(phys);
}

fn switchUserTable(cpu: u64, table: ?u64) void {
    const t = table orelse kernel_low;
    if (t == hw_ttbr0[cpu]) return;
    hw_ttbr0[cpu] = t;
    asm volatile (
        \\msr ttbr0_el1, %[t]
        \\tlbi vmalle1
        \\dsb nsh
        \\isb
        :
        : [t] "r" (t),
    );
}
