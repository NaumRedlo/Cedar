const std = @import("std");
const build_options = @import("build_options");
const arch = @import("arch.zig").impl;
const log = @import("log.zig");
const exceptions = @import("exceptions.zig");
const dtb = @import("dtb.zig");
const mmu = @import("mmu.zig");
const mem = @import("mem.zig");
const heap = @import("heap.zig");

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

// Entered from boot.S on core 0, stack ready, BSS cleared, MMU off.
// dtb_phys is the device tree blob address QEMU passed in x0.
export fn kmain(dtb_phys: usize) callconv(.c) noreturn {
    arch.init();
    exceptions.install();

    kprint("Hello, Cedar!\n\n");
    kprintf("boot: direct kernel image, no bootloader, EL{d}\n", .{arch.currentEl()});
    kprintf("exception vectors: installed (VBAR_EL1)\n", .{});

    var dt_store: ?dtb.Dtb = null;
    var ram: ?dtb.Reg = null;
    if (dtb.Dtb.init(dtb_phys)) |dt| {
        kprintf("dtb: ok at 0x{x}, version {d}, {d} bytes\n", .{ dtb_phys, dt.version, dt.raw.len });
        if (dt.rootProp("model")) |model| {
            kprintf("machine: {s}\n", .{dtb.str(model)});
        }
        if (dt.findByNodePrefix("memory")) |m| {
            kprintf("memory: 0x{x} + 0x{x} ({d} MiB)\n", .{ m.addr, m.size, m.size >> 20 });
            ram = m;
        }
        if (dt.findByCompatible("arm,pl011")) |u| {
            arch.setUartBase(u.addr);
            kprintf("uart: pl011 at 0x{x} (dtb-discovered, now in use)\n", .{u.addr});
        }
        dt_store = dt;
    } else |err| {
        kprintf("dtb: invalid at 0x{x} ({s})\n", .{ dtb_phys, @errorName(err) });
    }

    if (ram) |m| {
        mmu.enable(m.addr, m.size);
        kprintf("mmu: enabled (identity map, caches on) — sctlr.M={}\n", .{mmu.enabled()});
    } else {
        kprint("mmu: skipped, no memory node in dtb\n");
    }

    if (dt_store) |*dt| {
        if (ram) |m| {
            mem.init(dt, m, dtb_phys);
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

    if (build_options.test_exception) {
        kprint("\ntriggering brk #0 to exercise the exception path...\n");
        asm volatile ("brk #0");
    }

    if (build_options.test_fault) {
        kprint("\nreading unmapped 0x200000000 to exercise the fault path...\n");
        const bad: *volatile u32 = @ptrFromInt(0x2_0000_0000);
        _ = bad.*;
    }

    arch.halt();
}
