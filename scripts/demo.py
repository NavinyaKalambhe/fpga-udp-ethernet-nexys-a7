
#!/usr/bin/env python3
"""One-shot demo of the FPGA UDP/Ethernet node (run it in the VS Code terminal).

    python demo.py

Steps: ARP lookup -> ping (ICMP) -> UDP text on the VGA screen -> UDP echo with round-trip times.
Press Enter between steps so you can point the camera at the VGA dashboard and the LEDs.
"""
import platform, socket, subprocess, sys, time

FPGA_IP = "192.168.1.10"
PORT_TEXT, PORT_ECHO = 5005, 7777
WIN = platform.system() == "Windows"


def banner(title):
    print("\n" + "=" * 60 + f"\n  {title}\n" + "=" * 60)


def pause(msg="Press Enter for the next step..."):
    try:
        input(msg)
    except EOFError:
        pass


def step_arp():
    banner("STEP 1 - ARP: the PC asks 'who has 192.168.1.10?' and the FPGA answers")
    if WIN:
        subprocess.run(["arp", "-d", FPGA_IP], capture_output=True)   # needs admin; ignored if not
    # any traffic to the board triggers ARP; ping once to make it happen
    subprocess.run(["ping", "-n" if WIN else "-c", "1", FPGA_IP], capture_output=True)
    out = subprocess.run(["arp", "-a"], capture_output=True, text=True).stdout
    lines = [l for l in out.splitlines() if FPGA_IP in l]
    if lines:
        print("PC ARP table:", lines[0].strip())
        print("(MAC 02-a7-00-00-00-01 is the FPGA. Watch 'ARP REPLIES' on the VGA dashboard.)")
    else:
        print("ARP entry missing -> check cable / IP 192.168.1.1 / bitstream")


def step_ping():
    banner("STEP 2 - ICMP: ping answered by hardware (no CPU)")
    subprocess.run(["ping", "-n" if WIN else "-c", "4", FPGA_IP])
    print("PING REPLIES on the VGA dashboard should have gone up by 4.")


def step_text():
    banner("STEP 3 - UDP port 5005: text appears on the VGA screen")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    for msg in ("HELLO FROM PYTHON", "UDP OVER RMII ON NEXYS A7"):
        s.sendto(msg.encode()[:32], (FPGA_IP, PORT_TEXT))
        try:
            data, addr = s.recvfrom(2048)
            print(f"sent {msg!r:32} -> echoed back {data!r} from {addr[0]}")
        except socket.timeout:
            print(f"sent {msg!r}: NO REPLY")
        time.sleep(2)          # leave each message on screen long enough to film


def step_echo(n=50):
    banner(f"STEP 4 - UDP port 7777: echo {n} packets, measure round-trip time")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    rtts, bad, lost = [], 0, 0
    for i in range(n):
        payload = bytes([i & 0xFF]) * 64
        t0 = time.perf_counter()
        s.sendto(payload, (FPGA_IP, PORT_ECHO))
        try:
            data, _ = s.recvfrom(2048)
            rtts.append((time.perf_counter() - t0) * 1e3)
            if data != payload:
                bad += 1
        except socket.timeout:
            lost += 1
        time.sleep(0.01)       # the node has a single frame buffer, do not flood it
    if rtts:
        print(f"{len(rtts)}/{n} replies   lost={lost}   payload mismatches={bad}")
        print(f"RTT min/avg/max = {min(rtts):.2f} / {sum(rtts)/len(rtts):.2f} / {max(rtts):.2f} ms")
    else:
        print("no replies")


def main():
    print(f"FPGA UDP/Ethernet node demo  ->  target {FPGA_IP}")
    print("Make sure the VGA dashboard and the LEDs are in the camera frame.")
    pause("Press Enter to start...")
    for fn in (step_arp, step_ping, step_text, step_echo):
        fn()
        pause()
    banner("DONE - FRAMES RX / FRAMES TX on the dashboard and LEDs show every packet handled")


if __name__ == "__main__":
    sys.exit(main())