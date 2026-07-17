# 🌲 Cedar OS

> A modern, monolithic operating system written from scratch in **Zig** for the **ARM64 (AArch64)** architecture.

Cedar OS is a hobby operating system focused on clarity, reliability, and learning. It is built from the ground up without relying on existing kernels — or even a bootloader — featuring strict memory isolation, a preemptive scheduler, a custom filesystem, and an isolated EL0 userspace runtime.

---

# 🚀 Key Features

## 🏗️ Boot & Kernel Space (EL1)

- **No Bootloader**
  - The kernel is a raw image with a Linux arm64 boot header, loaded directly by QEMU's `-kernel` (and, in the future, by the Raspberry Pi firmware as `kernel8.img`).
  - Every instruction from `_start` on is Cedar's own code: page tables and the MMU are brought up in the boot stub itself.

- **Higher-Half Kernel**
  - Runs at **Exception Level 1 (EL1)**, linked into the Higher-Half Direct Mapping region:
    ```
    0xffffff8000000000 + physical
    ```

- **Strict NULL Pointer Protection**
  - Address zero is never mapped — neither for the kernel nor for processes.
  - Any null-pointer dereference immediately generates a hardware exception with a full CPU register dump instead of silently corrupting memory.

- **Hardware Discovery**
  - Parses the Device Tree (DTB) during boot.
  - Detects:
    - machine model
    - available physical RAM
    - PL011 UART, GICv2, virtio and fw_cfg devices using compatible strings

---

## ⏱️ Scheduling & Synchronization

### Preemptive Scheduler

- Round-Robin scheduler
- Driven by:
  - GICv2 interrupt controller
  - ARM Generic Virtual Timer
- Tick frequency:
  ```
  10 Hz
  ```

### Thread Isolation

- Every kernel thread has its own stack.
- Every userspace process has its own isolated user stack *and* kernel stack.

### Synchronization

Supports:

- `yield()` (`svc #0`)
- deadline-based `sleep()`
- blocking counting semaphores

Threads sleep instead of busy-waiting, avoiding unnecessary CPU usage.

---

## 💾 Memory Management & Cedar FS

### Physical Memory

Two-level memory management:

- bitmap page-frame allocator
- `std.mem.Allocator` compatible kernel heap

### Cedar FS

An in-memory filesystem with:

- case-insensitive lookup
- case-preserving names (macOS-style)
- created/modified timestamps on every node

Default layout:

```
/
├── System
├── Programs
└── Home
```

### Persistent Storage

Backed by a custom **VirtIO Block Driver**.

The entire filesystem tree can be snapshotted:

```text
save
```

Snapshots are written to the virtual disk image and automatically restored during boot. The snapshot header is committed last, so a crash mid-save never destroys the previous snapshot. `/System` and `/Programs` are always refreshed from the running kernel.

---

## 🖥️ Console, Keyboard & Shell

- **Framebuffer console**: a ramfb display (1024×768) configured through QEMU's fw_cfg channel; every line of kernel output is mirrored to the screen with a built-in bitmap font.
- **Keyboard**: PL011 UART receive interrupts feed a ring buffer; a keypress wakes the shell instantly.
- **Interactive shell** at the `cedar>` prompt:
  - system: `help`, `about`, `uptime`, `mem`, `clear`, `ps`, `save`
  - files: `ls`, `cat`, `write`, `mkdir`, `rm`
  - processes: `run <path> [args...]`

---

## 👤 Userspace Runtime (EL0)

### Process Isolation

Every userspace process executes in its own hardware-isolated EL0 address space (per-process TTBR0 page tables).

### Program Execution

Supports passing arguments System V style.

Example:

```bash
run /Programs/cat /Home/note.txt
```

Arguments are placed on the userspace stack and delivered through:

- `x0` → `argc`
- `x1` → `argv`

### System Calls

Current syscall set includes:

- `write`
- `sleep`
- `exit`
- `ticks`
- `open`
- `read`
- `close`

Each process owns its own file descriptor table.

### Fault Recovery

If a userspace process crashes:

- a diagnostic (exception class, ELR, FAR) is printed
- the process is terminated
- all owned memory pages are reclaimed automatically

Kernel execution continues normally.

---

# 🛠️ Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Zig 0.16.0 |
| Architecture | ARM64 (AArch64) |
| Bootloader | None — direct kernel image |
| Emulator | QEMU (`-M virt`) |
| Interrupt Controller | GICv2 |
| UART | PL011 |
| Display | ramfb via fw_cfg |
| Storage | VirtIO Block |

---

# 📸 Demo

![Cedar shell on the framebuffer console](docs/screenshot.png)

Example session:

```text
cedar> ls
     dir  System/  (1 items)
     dir  Programs/  (4 items)
     dir  Home/  (1 items)

cedar> write /Home/note.txt Hello from Cedar OS!
20 bytes -> /Home/note.txt

cedar> run /Programs/cat /Home/note.txt
Hello from Cedar OS!
sched: 'cat' exited (code 0)

cedar> save
fs: snapshot saved, 1893 bytes
```

---

# 🚀 Quick Start

Prerequisites: [Zig 0.16.0](https://ziglang.org/download/) and QEMU (`qemu-system-aarch64`).

Clone the repository:

```bash
git clone https://github.com/NaumRedlo/Cedar.git
cd Cedar
```

Build and launch immediately:

```bash
zig build run
```

A QEMU window opens with the Cedar screen; type commands in the terminal you launched from (input goes over serial). A 16 MiB `disk.img` for snapshots is created automatically on first run.

Run the host-side unit tests (FS, DTB parser, frame allocator):

```bash
zig build test
```

---

# 🌱 Project Goals

Cedar is an educational and experimental operating system focused on building a clean architecture from first principles.

Current goals include:

- robust virtual memory
- multitasking
- isolated userspace
- persistent filesystem
- simple and understandable kernel architecture

Future plans may include:

- typing directly into the QEMU window (virtio-input)
- Raspberry Pi hardware support
- SMP (multi-core scheduling)
- networking
- graphical desktop environment
- ELF program loading

---

## License

*TODO: choose a license before publishing (MIT, BSD-2-Clause, Apache-2.0, GPL, ...).*
