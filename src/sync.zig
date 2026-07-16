// Synchronization primitives built on the scheduler's block/wake.

const arch = @import("arch.zig").impl;
const sched = @import("sched.zig");

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
