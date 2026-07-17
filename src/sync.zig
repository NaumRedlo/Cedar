// Synchronization primitives built on the scheduler's block/wake,
// plus the SMP-era spinlock.

const arch = @import("arch.zig").impl;
const sched = @import("sched.zig");

// IRQ-masking spinlock: safe to share between thread and interrupt
// context on any core. Atomics require the MMU — enabled long before
// any lock is touched.
pub const SpinLock = struct {
    v: u32 = 0,

    pub fn lock(self: *SpinLock) u64 {
        const daif = arch.irqSave();
        while (@atomicRmw(u32, &self.v, .Xchg, 1, .acquire) != 0) {
            asm volatile ("" ::: .{ .memory = true });
        }
        return daif;
    }

    pub fn unlock(self: *SpinLock, daif: u64) void {
        @atomicStore(u32, &self.v, 0, .release);
        arch.irqRestore(daif);
    }
};

// One big lock for Cedar FS: shell commands and FS syscalls can run on
// different cores (and preempt each other) — tree mutations must not
// interleave. All FS operations are short and non-blocking.
pub var fs_lock = SpinLock{};

// Counting semaphore. wait() blocks the thread (descheduled, zero CPU)
// until signal() provides an item. Single-core: IRQ masking is the
// critical section.
pub const Semaphore = struct {
    count: u32 = 0,

    pub fn wait(self: *Semaphore) void {
        while (true) {
            const daif = arch.irqSave();
            if (self.count > 0) {
                self.count -= 1;
                arch.irqRestore(daif);
                return;
            }
            sched.blockCurrentOn(@intFromPtr(self));
            arch.irqRestore(daif);
            // A wake landing before this yield just makes it a no-op
            // round trip; the loop re-checks the count either way.
            sched.yield();
        }
    }

    pub fn signal(self: *Semaphore) void {
        const daif = arch.irqSave();
        self.count += 1;
        _ = sched.wakeOne(@intFromPtr(self));
        arch.irqRestore(daif);
    }
};
