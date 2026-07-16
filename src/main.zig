const std = @import("std");
const build_options = @import("build_options");
const arch = @import("arch.zig").impl;
const log = @import("log.zig");
const exceptions = @import("exceptions.zig");
const dtb = @import("dtb.zig");
const mmu = @import("mmu.zig");
const mem = @import("mem.zig");
const heap = @import("heap.zig");
const gic = @import("gic.zig");
const timer = @import("timer.zig");
const sched = @import("sched.zig");
const sync = @import("sync.zig");

const kprint = log.kprint;
const kprintf = log.kprintf;

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    kprint("KERNEL PANIC: ");
    kprint(msg);
    kprint("\n");
    arch.halt();
}

var items = sync.Semaphore{};

fn producer() callconv(.c) void {
    for (0..5) |n| {
        sched.sleep(5);
        items.signal();
        kprintf("producer: item {d} ready at tick {d}\n", .{ n, timer.now() });
    }
}

fn consumer() callconv(.c) void {
    for (0..5) |n| {
        items.wait();
        kprintf("consumer: got item {d} at tick {d}\n", .{ n, timer.now() });
    }
}

// Entered from boot.S on core 0 in the higher half: MMU on, TTBR0
// walks disabled, stack ready, BSS cleared. dtb_virt is the device
// tree address through the direct map.
export fn kmain(dtb_virt: usize) callconv(.c) noreturn {
    arch.init();
    exceptions.install();

    kprint("Hello, Cedar!\n\n");
    kprintf("boot: direct kernel image, no bootloader, EL{d}\n", .{arch.currentEl()});
    kprintf("mmu: higher half, hhdm at 0x{x}, low half {s}\n", .{
        mmu.HHDM,
        if (mmu.lowHalfDisabled()) @as([]const u8, "disabled") else "ENABLED?!",
    });
    kprintf("exception vectors: installed (VBAR_EL1)\n", .{});

    var dt_store: ?dtb.Dtb = null;
    var ram: ?dtb.Reg = null;
    if (dtb.Dtb.init(dtb_virt)) |dt| {
        kprintf("dtb: ok at 0x{x}, version {d}, {d} bytes\n", .{ dtb_virt, dt.version, dt.raw.len });
        if (dt.rootProp("model")) |model| {
            kprintf("machine: {s}\n", .{dtb.str(model)});
        }
        if (dt.findByNodePrefix("memory")) |m| {
            kprintf("memory: 0x{x} + 0x{x} ({d} MiB)\n", .{ m.addr, m.size, m.size >> 20 });
            ram = m;
        }
        if (dt.findByCompatible("arm,pl011")) |u| {
            arch.setUartBase(mmu.p2v(u.addr));
            kprintf("uart: pl011 at phys 0x{x} (dtb-discovered, via hhdm)\n", .{u.addr});
        }
        dt_store = dt;
    } else |err| {
        kprintf("dtb: invalid at 0x{x} ({s})\n", .{ dtb_virt, @errorName(err) });
    }

    if (dt_store) |*dt| {
        if (ram) |m| {
            mem.init(dt, m, dtb_virt);
            kprintf("pmm: {d} MiB free of {d} MiB ({d} frames)\n", .{
                mem.freeMiB(), mem.totalMiB(), mem.frames.frames,
            });

            const f = mem.frames.alloc().?;
            kprintf("pmm: test frame at 0x{x}, freeing it back\n", .{f});
            mem.frames.free(f);

            if (heap.init(256)) {
                var list: std.ArrayList(u8) = .empty;
                const a = heap.allocator();
                defer list.deinit(a);
                list.appendSlice(a, "heap: 1 MiB online, ArrayList works\n") catch {};
                kprint(list.items);
            } else {
                kprint("heap: init failed\n");
            }
        }
    }

    if (dt_store) |*dt| {
        var regs: [2]dtb.Reg = undefined;
        if (dt.findRegsByCompatible("arm,cortex-a15-gic", &regs) >= 2) {
            gic.init(mmu.p2v(regs[0].addr), mmu.p2v(regs[1].addr));
            kprintf("gic: v2, distributor 0x{x}, cpu interface 0x{x} (phys, via hhdm)\n", .{ regs[0].addr, regs[1].addr });
            timer.init(10);
            sched.init();
            arch.enableIrqs();
            kprint("irq: unmasked, ticking\n");

            sched.spawn("producer", producer) catch |e| kprintf("spawn failed: {s}\n", .{@errorName(e)});
            sched.spawn("consumer", consumer) catch |e| kprintf("spawn failed: {s}\n", .{@errorName(e)});
            kprint("sched: producer sleeps 5 ticks per item, consumer blocks on a semaphore\n");
        } else {
            kprint("gic: no v2 controller in dtb, interrupts stay off\n");
        }
    }

    if (build_options.test_exception) {
        kprint("\ntriggering brk #0 to exercise the exception path...\n");
        asm volatile ("brk #0");
    }

    if (build_options.test_fault) {
        kprint("\ndereferencing (near-)null 0x10 — the low half must fault...\n");
        const bad: *volatile u32 = @ptrFromInt(0x10);
        _ = bad.*;
    }

    arch.halt();
}
