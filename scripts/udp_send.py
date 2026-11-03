#!/usr/bin/env python3
"""Host-side test for the FPGA UDP node (run on the laptop connected by the Ethernet cable).

  python3 scripts/udp_send.py text "HELLO FROM PYTHON"   # shows up on the VGA screen (UDP port 5005)
  python3 scripts/udp_send.py echo [count]               # UDP echo test on port 7777 with round-trip times

Set the laptop's Ethernet adapter to a fixed address first, e.g. 192.168.1.1 / 255.255.255.0.
"""
import socket, sys, time

FPGA_IP = "192.168.1.10"
PORT_ECHO, PORT_TEXT = 7777, 5005

def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    if sys.argv[1] == "text":
        msg = (sys.argv[2] if len(sys.argv) > 2 else "HELLO FPGA").encode()[:32]
        s.sendto(msg, (FPGA_IP, PORT_TEXT))
        try:
            data, _ = s.recvfrom(2048)
            print("echoed back:", data)
        except socket.timeout:
            print("no reply (check cable, IP settings, ARP)")
    elif sys.argv[1] == "echo":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 20
        rtts, lost = [], 0
        for i in range(n):
            payload = bytes([i & 0xFF]) * 64
            t0 = time.perf_counter()
            s.sendto(payload, (FPGA_IP, PORT_ECHO))
            try:
                data, _ = s.recvfrom(2048)
                ok = data == payload
                rtts.append((time.perf_counter() - t0) * 1e3)
                if not ok: print(f"packet {i}: payload mismatch")
            except socket.timeout:
                lost += 1
            time.sleep(0.01)          # the node has one frame buffer: do not flood it
        if rtts:
            print(f"{len(rtts)}/{n} replies, RTT min/avg/max = {min(rtts):.2f}/{sum(rtts)/len(rtts):.2f}/{max(rtts):.2f} ms, lost {lost}")
        else:
            print("no replies")

if __name__ == "__main__":
    main()
