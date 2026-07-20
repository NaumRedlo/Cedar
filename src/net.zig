// A tiny IPv4 network stack: Ethernet framing, ARP, IPv4, ICMP echo.
// Enough to resolve a neighbour's MAC, ping it, and answer incoming
// ARP requests and echo requests. All packet building/parsing and the
// internet checksum are pure logic, unit-tested on the host; the
// virtio-net driver supplies transmit() and calls rx() from its IRQ.
//
// Static config matches QEMU's user-mode (SLIRP) network:
//   our IP 10.0.2.15, gateway 10.0.2.2, mask /24.

const std = @import("std");

pub const Mac = [6]u8;
pub const Ip = [4]u8;

pub const OUR_IP: Ip = .{ 10, 0, 2, 15 };
pub const GATEWAY: Ip = .{ 10, 0, 2, 2 };

const ETH_ARP: u16 = 0x0806;
const ETH_IP: u16 = 0x0800;
const ARP_REQUEST: u16 = 1;
const ARP_REPLY: u16 = 2;
const IP_PROTO_ICMP: u8 = 1;
const ICMP_ECHO_REQUEST: u8 = 8;
const ICMP_ECHO_REPLY: u8 = 0;

const BROADCAST: Mac = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

// --- internet checksum (RFC 1071) ---

pub fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8; // odd tail byte
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

fn put16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .big);
}

fn get16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .big);
}

// --- runtime state (kernel side) ---

var our_mac: Mac = .{ 0, 0, 0, 0, 0, 0 };
var gw_mac: ?Mac = null;
var arp_pending = false;

var echo_seq: u16 = 0;
var echo_reply_seq: ?u16 = null;

pub var up = false;

pub fn setMac(m: Mac) void {
    our_mac = m;
    up = true;
}

pub fn mac() Mac {
    return our_mac;
}

// The driver wires these in to avoid an import cycle. `poll` drains the
// RX ring (QEMU delivers packets there whether or not it interrupts).
pub var transmit: *const fn (frame: []const u8) void = undefined;
pub var poll: *const fn () void = noPoll;
fn noPoll() void {}

// --- frame builders ---

fn ethernet(buf: []u8, dst: Mac, ethertype: u16) usize {
    @memcpy(buf[0..6], &dst);
    @memcpy(buf[6..12], &our_mac);
    put16(buf, 12, ethertype);
    return 14;
}

pub fn buildArp(buf: []u8, oper: u16, target_mac: Mac, target_ip: Ip) usize {
    const n = ethernet(buf, if (oper == ARP_REQUEST) BROADCAST else target_mac, ETH_ARP);
    const a = buf[n..];
    put16(a, 0, 1); // htype: ethernet
    put16(a, 2, ETH_IP); // ptype: IPv4
    a[4] = 6; // hlen
    a[5] = 4; // plen
    put16(a, 6, oper);
    @memcpy(a[8..14], &our_mac);
    @memcpy(a[14..18], &OUR_IP);
    @memcpy(a[18..24], &target_mac);
    @memcpy(a[24..28], &target_ip);
    return n + 28;
}

// Fill an IPv4 header + return offset of the payload area.
fn ipv4(buf: []u8, dst_mac: Mac, dst_ip: Ip, proto: u8, payload_len: usize) usize {
    const eth = ethernet(buf, dst_mac, ETH_IP);
    const ip = buf[eth..];
    const total = 20 + payload_len;
    ip[0] = 0x45; // version 4, IHL 5
    ip[1] = 0;
    put16(ip, 2, @intCast(total));
    put16(ip, 4, 0); // id
    put16(ip, 6, 0x4000); // don't fragment
    ip[8] = 64; // ttl
    ip[9] = proto;
    put16(ip, 10, 0); // checksum placeholder
    @memcpy(ip[12..16], &OUR_IP);
    @memcpy(ip[16..20], &dst_ip);
    put16(ip, 10, checksum(ip[0..20]));
    return eth + 20;
}

pub fn buildIcmpEcho(buf: []u8, kind: u8, dst_mac: Mac, dst_ip: Ip, id: u16, seq: u16, payload: []const u8) usize {
    const off = ipv4(buf, dst_mac, dst_ip, IP_PROTO_ICMP, 8 + payload.len);
    const ic = buf[off..];
    ic[0] = kind;
    ic[1] = 0;
    put16(ic, 2, 0); // checksum placeholder
    put16(ic, 4, id);
    put16(ic, 6, seq);
    @memcpy(ic[8 .. 8 + payload.len], payload);
    put16(ic, 2, checksum(ic[0 .. 8 + payload.len]));
    return off + 8 + payload.len;
}

// --- receive path (called from the driver's IRQ) ---

pub fn rx(frame: []const u8) void {
    if (frame.len < 14) return;
    const ethertype = get16(frame, 12);
    const payload = frame[14..];
    switch (ethertype) {
        ETH_ARP => handleArp(payload),
        ETH_IP => handleIp(payload),
        else => {},
    }
}

fn ipEq(a: Ip, b: Ip) bool {
    return std.mem.eql(u8, &a, &b);
}

fn handleArp(a: []const u8) void {
    if (a.len < 28) return;
    const oper = get16(a, 6);
    var sha: Mac = undefined;
    @memcpy(&sha, a[8..14]);
    var spa: Ip = undefined;
    @memcpy(&spa, a[14..18]);
    var tpa: Ip = undefined;
    @memcpy(&tpa, a[24..28]);

    if (oper == ARP_REPLY and ipEq(spa, GATEWAY)) {
        gw_mac = sha;
        arp_pending = false;
    } else if (oper == ARP_REQUEST and ipEq(tpa, OUR_IP)) {
        var buf: [64]u8 = undefined;
        const n = buildArp(&buf, ARP_REPLY, sha, spa);
        transmit(buf[0..n]);
    }
}

fn handleIp(ip: []const u8) void {
    if (ip.len < 20) return;
    const ihl = (ip[0] & 0x0f) * 4;
    if (ip.len < ihl) return;
    if (ip[9] != IP_PROTO_ICMP) return;
    var src: Ip = undefined;
    @memcpy(&src, ip[12..16]);
    const icmp = ip[ihl..];
    if (icmp.len < 8) return;

    switch (icmp[0]) {
        ICMP_ECHO_REPLY => {
            echo_reply_seq = get16(icmp, 6);
        },
        ICMP_ECHO_REQUEST => {
            // Reply to whoever pinged us, if we know their MAC.
            var src_mac: Mac = undefined;
            // The reply goes to the frame's source MAC; recover it from
            // the ethernet header, which sits 14 bytes before `ip`.
            @memcpy(&src_mac, (ip.ptr - 14)[6..12]);
            var buf: [1518]u8 = undefined;
            const payload = icmp[8..];
            const cap = @min(payload.len, buf.len - 42);
            const n = buildIcmpEcho(&buf, ICMP_ECHO_REPLY, src_mac, src, get16(icmp, 4), get16(icmp, 6), payload[0..cap]);
            transmit(buf[0..n]);
        },
        else => {},
    }
}

// --- ARP resolution + ping, driven from a thread ---

const arch = @import("arch.zig").impl;
const sched = @import("sched.zig");

fn cntvct() u64 {
    return asm volatile ("mrs %[o], cntvct_el0"
        : [o] "=r" (-> u64),
    );
}

fn cntfrq() u64 {
    return asm volatile ("mrs %[o], cntfrq_el0"
        : [o] "=r" (-> u64),
    );
}

pub const PingError = error{ NoLink, ArpTimeout, EchoTimeout };

// Resolve the gateway MAC (ARP) once, caching it.
fn resolveGateway() PingError!Mac {
    if (gw_mac) |m| return m;
    var buf: [64]u8 = undefined;
    var attempt: u32 = 0;
    while (attempt < 5) : (attempt += 1) {
        arp_pending = true;
        const n = buildArp(&buf, ARP_REQUEST, .{ 0, 0, 0, 0, 0, 0 }, GATEWAY);
        transmit(buf[0..n]);
        var spins: u32 = 0;
        while (spins < 10) : (spins += 1) {
            poll();
            if (gw_mac) |m| return m;
            sched.sleep(1);
        }
    }
    return PingError.ArpTimeout;
}

// Send one ICMP echo to the gateway; return the round-trip in microseconds.
pub fn ping() PingError!u64 {
    if (!up) return PingError.NoLink;
    const dst_mac = try resolveGateway();

    echo_seq +%= 1;
    const seq = echo_seq;
    echo_reply_seq = null;

    var buf: [64]u8 = undefined;
    const payload = "cedar-ping\x00\x00";
    const n = buildIcmpEcho(&buf, ICMP_ECHO_REQUEST, dst_mac, GATEWAY, 0x1234, seq, payload);
    const start = cntvct();
    transmit(buf[0..n]);

    var spins: u32 = 0;
    while (spins < 25) : (spins += 1) {
        poll();
        if (echo_reply_seq) |r| {
            if (r == seq) {
                const elapsed = cntvct() - start;
                return elapsed * 1_000_000 / cntfrq();
            }
        }
        sched.sleep(1);
    }
    return PingError.EchoTimeout;
}

pub fn gatewayMac() ?Mac {
    return gw_mac;
}

// Background thread: keeps the RX ring drained so incoming ARP requests
// and ICMP echoes are answered even when nothing is actively pinging.
// (QEMU delivers to the used ring reliably; we poll rather than lean on
// an interrupt that its legacy virtio-net-device does not raise here.)
pub fn pollLoop() callconv(.c) void {
    while (true) {
        poll();
        sched.sleep(2);
    }
}

// --- host tests ---

const testing = std.testing;

test "internet checksum: known IP header" {
    // A sample IPv4 header (RFC-style) with checksum field zeroed; the
    // computed checksum is a fixed value.
    var hdr = [_]u8{ 0x45, 0x00, 0x00, 0x54, 0x00, 0x00, 0x40, 0x00, 0x40, 0x01, 0x00, 0x00, 10, 0, 2, 15, 10, 0, 2, 2 };
    const c = checksum(&hdr);
    put16(&hdr, 10, c);
    // Verifying: checksum over the header including the field is 0.
    try testing.expectEqual(@as(u16, 0), checksum(&hdr));
}

test "checksum handles odd length" {
    const a = [_]u8{ 0x01, 0x02, 0x03 };
    // 0x0102 + 0x0300 = 0x0402 -> ~ = 0xfbfd
    try testing.expectEqual(@as(u16, 0xfbfd), checksum(&a));
}

fn testSetup() void {
    our_mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    gw_mac = null;
    arp_pending = false;
}

test "build ARP request is well-formed" {
    testSetup();
    var buf: [64]u8 = undefined;
    const n = buildArp(&buf, ARP_REQUEST, .{ 0, 0, 0, 0, 0, 0 }, GATEWAY);
    try testing.expectEqual(@as(usize, 42), n);
    try testing.expectEqualSlices(u8, &BROADCAST, buf[0..6]); // dst broadcast
    try testing.expectEqual(ETH_ARP, get16(&buf, 12));
    try testing.expectEqual(ARP_REQUEST, get16(buf[14..], 6));
    try testing.expectEqualSlices(u8, &GATEWAY, buf[38..42]); // target IP
}

test "ICMP echo has a valid checksum and entry point" {
    testSetup();
    var buf: [128]u8 = undefined;
    const n = buildIcmpEcho(&buf, ICMP_ECHO_REQUEST, .{ 1, 2, 3, 4, 5, 6 }, GATEWAY, 0x1234, 7, "hello");
    try testing.expectEqual(@as(usize, 14 + 20 + 8 + 5), n);
    // IP checksum verifies to zero.
    try testing.expectEqual(@as(u16, 0), checksum(buf[14..34]));
    // ICMP checksum verifies to zero.
    try testing.expectEqual(@as(u16, 0), checksum(buf[34..n]));
    try testing.expectEqual(@as(u8, ICMP_ECHO_REQUEST), buf[34]);
}

test "rx: ARP reply from gateway populates the cache" {
    testSetup();
    var buf: [64]u8 = undefined;
    // Pretend the gateway (mac de:ad:...) replies to our request.
    const gwm: Mac = .{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x01 };
    our_mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const n = buildArpFromSender(&buf, ARP_REPLY, gwm, GATEWAY, our_mac, OUR_IP);
    rx(buf[0..n]);
    try testing.expect(gw_mac != null);
    try testing.expectEqualSlices(u8, &gwm, &gw_mac.?);
}

// Test helper: an ARP packet as if built by some other host.
fn buildArpFromSender(buf: []u8, oper: u16, sha: Mac, spa: Ip, tha: Mac, tpa: Ip) usize {
    @memcpy(buf[0..6], &tha);
    @memcpy(buf[6..12], &sha);
    put16(buf, 12, ETH_ARP);
    const a = buf[14..];
    put16(a, 0, 1);
    put16(a, 2, ETH_IP);
    a[4] = 6;
    a[5] = 4;
    put16(a, 6, oper);
    @memcpy(a[8..14], &sha);
    @memcpy(a[14..18], &spa);
    @memcpy(a[18..24], &tha);
    @memcpy(a[24..28], &tpa);
    return 42;
}
