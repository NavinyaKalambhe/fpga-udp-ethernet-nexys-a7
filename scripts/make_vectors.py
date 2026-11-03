#!/usr/bin/env python3
"""Generate test vectors for tb/tb_eth.v.

Every request frame is built with plain `struct` + `zlib` and every EXPECTED reply is built
independently (all checksums and the FCS are recomputed from scratch), so the testbench checks the
hardware's in-place rewriting and incremental checksums against a separate implementation.

Output: tb/vectors/vectors.txt   (see the end of the file for the format)
"""
import random, struct, sys, zlib

OUR_MAC  = bytes.fromhex("02A700000001")
OUR_IP   = bytes([192, 168, 1, 10])
HOST_MAC = bytes.fromhex("AABBCCDDEE01")
HOST_IP  = bytes([192, 168, 1, 1])
OTHER_MAC = bytes.fromhex("0200000000 99".replace(" ", ""))
BCAST = b"\xff" * 6
PORT_ECHO, PORT_TEXT = 7777, 5005

def csum(data):
    if len(data) % 2:
        data += b"\x00"
    s = sum(struct.unpack(">%dH" % (len(data) // 2), data))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

def eth(dst, src, etype, payload):
    f = dst + src + struct.pack(">H", etype) + payload
    return f + b"\x00" * max(0, 60 - len(f))              # pad to the 60-byte minimum

def with_fcs(frame):
    return frame + struct.pack("<I", zlib.crc32(frame) & 0xFFFFFFFF)

def ipv4(src, dst, proto, payload, ident, ttl=64, flags_frag=0x4000, tos=0):
    hdr = struct.pack(">BBHHHBBH4s4s", 0x45, tos, 20 + len(payload), ident, flags_frag, ttl, proto, 0, src, dst)
    hdr = hdr[:10] + struct.pack(">H", csum(hdr)) + hdr[12:]
    return hdr + payload

def icmp_echo(typ, ident, seq, payload):
    m = struct.pack(">BBHHH", typ, 0, 0, ident, seq) + payload
    return m[:2] + struct.pack(">H", csum(m)) + m[4:]

def udp(src_ip, dst_ip, sport, dport, payload):
    length = 8 + len(payload)
    pseudo = src_ip + dst_ip + struct.pack(">BBH", 0, 17, length)
    d = struct.pack(">HHHH", sport, dport, length, 0) + payload
    c = csum(pseudo + d) or 0xFFFF
    return d[:6] + struct.pack(">H", c) + d[8:]

def arp(op, sha, spa, tha, tpa):
    return struct.pack(">HHBBH6s4s6s4s", 1, 0x0800, 6, 4, op, sha, spa, tha, tpa)

rnd = random.Random(2026)
def rbytes(n): return bytes(rnd.randrange(256) for _ in range(n))

frames = []      # (description, request_with_fcs, expected_reply_with_fcs or None, kind, toggle)
def add(desc, req, rep, kind, toggle=0):
    frames.append((desc, with_fcs(req), with_fcs(rep) if rep is not None else None, kind, toggle))

def ping(ident, seq, payload, ipid, desc, toggle=0, ttl=64):
    req = eth(OUR_MAC, HOST_MAC, 0x0800, ipv4(HOST_IP, OUR_IP, 1, icmp_echo(8, ident, seq, payload), ipid, ttl))
    rep = eth(HOST_MAC, OUR_MAC, 0x0800, ipv4(OUR_IP, HOST_IP, 1, icmp_echo(0, ident, seq, payload), ipid, ttl))
    add(desc, req, rep, "icmp", toggle)

def udp_echo(port, payload, ipid, desc, sport=40000, toggle=0, kind="udp"):
    req = eth(OUR_MAC, HOST_MAC, 0x0800, ipv4(HOST_IP, OUR_IP, 17, udp(HOST_IP, OUR_IP, sport, port, payload), ipid))
    rep = eth(HOST_MAC, OUR_MAC, 0x0800, ipv4(OUR_IP, HOST_IP, 17, udp(OUR_IP, HOST_IP, port, sport, payload), ipid))
    add(desc, req, rep, kind, toggle)

# 1: ARP request for our IP (broadcast)
add("ARP who-has 192.168.1.10", eth(BCAST, HOST_MAC, 0x0806, arp(1, HOST_MAC, HOST_IP, b"\0" * 6, OUR_IP)),
    eth(HOST_MAC, OUR_MAC, 0x0806, arp(2, OUR_MAC, OUR_IP, HOST_MAC, HOST_IP)), "arp")
# 2: ARP request for somebody else -> ignored
add("ARP for another IP (ignored)", eth(BCAST, HOST_MAC, 0x0806, arp(1, HOST_MAC, HOST_IP, b"\0" * 6, bytes([192, 168, 1, 99]))),
    None, "drop")
# 3, 4: ping, even and odd payload
ping(0x1234, 1, bytes(range(32)), 0x0001, "ping, 32-byte payload")
ping(0x1234, 2, rbytes(57), 0x0002, "ping, odd 57-byte payload")
# 5, 6: UDP echo / text
udp_echo(PORT_ECHO, b"HELLO FPGA", 0x0010, "UDP echo, short payload (frame padded)")
udp_echo(PORT_TEXT, b"hello from laptop", 0x0011, "UDP text message")
# 7: long UDP echo
udp_echo(PORT_ECHO, rbytes(1000), 0x0012, "UDP echo, 1000-byte payload")
# 8: UDP to a closed port -> ignored
req = eth(OUR_MAC, HOST_MAC, 0x0800, ipv4(HOST_IP, OUR_IP, 17, udp(HOST_IP, OUR_IP, 40000, 9999, b"nobody home"), 0x0013))
add("UDP to closed port 9999 (ignored)", req, None, "drop")
# 9: bad FCS -> counted as CRC error
good = with_fcs(eth(OUR_MAC, HOST_MAC, 0x0800, ipv4(HOST_IP, OUR_IP, 1, icmp_echo(8, 7, 7, b"crc"), 0x0014)))
bad = bytearray(good); bad[20] ^= 0x01
frames.append(("ping with a corrupted byte (bad CRC)", bytes(bad), None, "crc", 0))
# 10: addressed to another MAC -> ignored
req = eth(OTHER_MAC, HOST_MAC, 0x0800, ipv4(HOST_IP, OUR_IP, 1, icmp_echo(8, 9, 9, b"wrong mac"), 0x0015))
add("frame for another MAC (ignored)", req, None, "drop")
# 11: ping whose last bytes arrive with the CRS_DV toggling pattern
ping(0xBEEF, 3, rbytes(40), 0x0016, "ping, RMII CRS_DV toggling at the end", toggle=1)
# 12: IPv4 header checksum wrong -> ignored
p = bytearray(ipv4(HOST_IP, OUR_IP, 1, icmp_echo(8, 5, 5, b"badsum"), 0x0017)); p[10] ^= 0x5A
add("ping with a bad IP header checksum (ignored)", eth(OUR_MAC, HOST_MAC, 0x0800, bytes(p)), None, "drop")
# 13: TCP -> ignored
add("TCP segment (ignored)", eth(OUR_MAC, HOST_MAC, 0x0800, ipv4(HOST_IP, OUR_IP, 6, rbytes(20), 0x0018)), None, "drop")
# 14: big ping
ping(0x4321, 4, rbytes(1400), 0x0019, "ping, 1400-byte payload")
# 15: ping with a different TTL, other source address (not the host above)
src2 = bytes([192, 168, 1, 77])
req = eth(OUR_MAC, HOST_MAC, 0x0800, ipv4(src2, OUR_IP, 1, icmp_echo(8, 1, 1, rbytes(16)), 0x001A, ttl=3))
rep = eth(HOST_MAC, OUR_MAC, 0x0800, ipv4(OUR_IP, src2, 1, icmp_echo(0, 1, 1, req[14 + 20 + 8: 14 + 20 + 8 + 16]), 0x001A, ttl=3))
add("ping from 192.168.1.77, TTL 3", req, rep, "icmp")
# 16: last text message, so the VGA shows something readable at the end
udp_echo(PORT_TEXT, b"FPGA ETHERNET ONLINE", 0x001B, "UDP text message (final)")

counts = dict(arp=0, icmp=0, udp=0, drop=0, crc=0)
for _, _, rep, kind, _ in frames:
    counts[kind] += 1
n_tx = counts["arp"] + counts["icmp"] + counts["udp"]
n_rx = len(frames) - counts["crc"]
last_msg = b"FPGA ETHERNET ONLINE".ljust(32, b" ")

with open("tb/vectors/vectors.txt", "w") as f:
    for desc, req, rep, kind, tog in frames:
        f.write(f"{len(req)} " + " ".join("%02x" % b for b in req) + "\n")
        if rep is None:
            f.write("0\n")
        else:
            f.write(f"{len(rep)} " + " ".join("%02x" % b for b in rep) + "\n")
        f.write(f"{tog}\n")
    f.write("0\n")                                   # end marker (frame length 0)
    f.write(f"{n_rx} {counts['crc']} {counts['arp']} {counts['icmp']} {counts['udp']} {counts['drop']} {n_tx}\n")
    f.write(" ".join("%02x" % b for b in last_msg) + "\n")

for i, (desc, req, rep, kind, tog) in enumerate(frames, 1):
    print(f"{i:2d}. {desc:52s} in={len(req):4d} B  reply={'-' if rep is None else str(len(rep)) + ' B'}")
print(f"expected: rx={n_rx} crc_err={counts['crc']} arp={counts['arp']} icmp={counts['icmp']} udp={counts['udp']} ignored={counts['drop']} tx={n_tx}")
# Vector file format (all numbers decimal except bytes, which are hex):
#   per frame:  <len> <bytes...>        request incl. FCS
#               <len> <bytes...>        expected reply incl. FCS, or just 0 if no reply is expected
#               <toggle>                1 = drive CRS_DV with the end-of-frame toggling pattern
#   then:       0
#               <rx_frames> <crc_err> <arp> <icmp> <udp> <ignored> <tx_frames>
#               32 bytes of the expected final text message
