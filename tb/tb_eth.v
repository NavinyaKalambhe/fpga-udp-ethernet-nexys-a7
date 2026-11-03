`timescale 1ns/1ps
// Ethernet/UDP testbench. Plays the frames from tb/vectors/vectors.txt into the RMII receiver
// (like a PHY would: preamble, SFD, LSB-first dibits, CRS_DV), captures every frame the design
// transmits on the RMII transmit pins, and compares it byte by byte with the expected reply
// generated independently by scripts/make_vectors.py.
//   vvp sim +vec=tb/vectors/vectors.txt
module tb_eth;
    reg clk = 0, clk25 = 0, rst = 1;
    always #10 clk   = ~clk;                     // 50 MHz
    always #20 clk25 = ~clk25;                   // 25 MHz VGA pixel clock

    reg        crs_dv = 0;
    reg  [1:0] rxd = 2'b00;
    wire       txen;
    wire [1:0] txd;
    wire [31:0] st_rx, st_tx, st_crc, st_ovr, st_arp, st_icmp, st_udp, st_ign, last_ip;
    wire [255:0] dump_bytes, msg_bytes;
    wire [15:0] last_port, last_len;

    wire [3:0] vr, vg, vb;
    wire       vhs, vvs;

    eth_node dut (
        .clk(clk), .clk_vga(clk25), .rst(rst), .crs_dv(crs_dv), .rxd(rxd), .txen(txen), .txd(txd),
        .vga_r(vr), .vga_g(vg), .vga_b(vb), .vga_hs(vhs), .vga_vs(vvs),
        .st_rx_frames(st_rx), .st_tx_frames(st_tx), .st_crc_err(st_crc), .st_overrun(st_ovr),
        .st_arp(st_arp), .st_icmp(st_icmp), .st_udp(st_udp), .st_ignored(st_ign),
        .dump_bytes(dump_bytes), .msg_bytes(msg_bytes),
        .last_ip(last_ip), .last_port(last_port), .last_len(last_len));

    // ------------------------------------------------------------ PHY receive side
    task dibit(input [1:0] d, input c);
        begin
            @(posedge clk); rxd <= d; crs_dv <= c;
        end
    endtask

    reg [7:0] in_frame  [0:2047];
    reg [7:0] exp_frame [0:2047];

    // preamble, SFD, bytes (LSB first). tog = 1: the last 3 bytes use the toggling CRS_DV pattern
    task send_frame(input integer len, input integer tog);
        integer i, p;
        reg [7:0] v;
        reg c1;
        begin
            for (i = 0; i < 28; i = i + 1) dibit(2'b01, 1'b1);             // 7 x 0x55
            dibit(2'b01, 1'b1); dibit(2'b01, 1'b1); dibit(2'b01, 1'b1); dibit(2'b11, 1'b1);   // 0xD5
            for (i = 0; i < len; i = i + 1) begin
                v = in_frame[i];
                for (p = 0; p < 4; p = p + 1) begin
                    // CRS_DV low on the first dibit of each nibble when toggling (data still valid)
                    c1 = (tog != 0 && i >= len - 3 && (p % 2) == 0) ? 1'b0 : 1'b1;
                    dibit(v[2*p +: 2], c1);
                end
            end
            dibit(2'b00, 1'b0); dibit(2'b00, 1'b0);
        end
    endtask

    // ------------------------------------------------------------ PHY transmit side (capture)
    reg [7:0] cap [0:2047];
    integer cap_n = 0, cap_len = 0, cap_ph = 0, frames_seen = 0;
    reg [1:0] cs = 0;
    reg [7:0] cap_byte = 0;
    reg       got_frame = 0;

    always @(posedge clk) begin
        if (txen) begin
            case (cs)
                2'd0: if (txd == 2'b01) cs <= 2'd1;
                2'd1: if (txd == 2'b11) begin cs <= 2'd2; cap_n = 0; cap_ph = 0; end
                      else if (txd != 2'b01) cs <= 2'd0;
                2'd2: begin
                    cap_byte[2*cap_ph +: 2] = txd;
                    if (cap_ph == 3) begin cap[cap_n] = cap_byte; cap_n = cap_n + 1; cap_ph = 0; end
                    else cap_ph = cap_ph + 1;
                end
            endcase
        end else begin
            if (cs == 2'd2) begin cap_len = cap_n; got_frame = 1; frames_seen = frames_seen + 1; end
            cs <= 2'd0;
        end
    end

    // ------------------------------------------------------------ test sequence
    integer fd, r, idx, i, in_len, exp_len, tog, b, errors, waited;
    integer e_rx, e_crc, e_arp, e_icmp, e_udp, e_drop, e_tx;
    reg [1023:0] vecname;
    reg [255:0] exp_msg;
    reg [7:0] t;
    integer mism;

    task check_reply(input integer n);
        integer m;
        begin
            mism = 0;
            if (cap_len != exp_len) begin
                $display("FAIL  frame %0d: reply length %0d, expected %0d", n, cap_len, exp_len);
                mism = 1;
            end else
                for (m = 0; m < exp_len && mism == 0; m = m + 1)
                    if (cap[m] !== exp_frame[m]) begin
                        $display("FAIL  frame %0d: reply byte %0d is %02x, expected %02x", n, m, cap[m], exp_frame[m]);
                        mism = 1;
                    end
            if (mism == 0) $display("PASS  frame %0d: reply of %0d bytes matches (FCS included)", n, exp_len);
            else errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0; idx = 0;
        if (!$value$plusargs("vec=%s", vecname)) vecname = "tb/vectors/vectors.txt";
        fd = $fopen(vecname, "r");
        if (fd == 0) begin $display("FAIL  cannot open vectors"); $finish; end
        #200 rst = 0;
        repeat (20) @(posedge clk);

        r = $fscanf(fd, "%d", in_len);
        while (in_len > 0) begin
            idx = idx + 1;
            for (i = 0; i < in_len; i = i + 1) begin r = $fscanf(fd, "%h", b); in_frame[i] = b; end
            r = $fscanf(fd, "%d", exp_len);
            for (i = 0; i < exp_len; i = i + 1) begin r = $fscanf(fd, "%h", b); exp_frame[i] = b; end
            r = $fscanf(fd, "%d", tog);

            got_frame = 0;
            send_frame(in_len, tog);
            waited = 0;
            if (exp_len > 0) begin
                while (!got_frame && waited < 20000) begin @(posedge clk); waited = waited + 1; end
                if (!got_frame) begin $display("FAIL  frame %0d: no reply", idx); errors = errors + 1; end
                else check_reply(idx);
                repeat (100) @(posedge clk);          // let the transmitter finish its gap
            end else begin
                repeat (3000) @(posedge clk);
                if (got_frame) begin $display("FAIL  frame %0d: unexpected reply", idx); errors = errors + 1; end
                else $display("PASS  frame %0d: correctly no reply", idx);
            end
            r = $fscanf(fd, "%d", in_len);
        end

        // ---- counters and the VGA text message ----
        r = $fscanf(fd, "%d %d %d %d %d %d %d", e_rx, e_crc, e_arp, e_icmp, e_udp, e_drop, e_tx);
        for (i = 0; i < 32; i = i + 1) begin r = $fscanf(fd, "%h", b); exp_msg[255 - 8*i -: 8] = b; end
        repeat (200) @(posedge clk);
        if (st_rx === e_rx && st_crc === e_crc && st_arp === e_arp && st_icmp === e_icmp &&
            st_udp === e_udp && st_ign === e_drop && st_tx === e_tx)
            $display("PASS  counters: rx=%0d crc=%0d arp=%0d icmp=%0d udp=%0d ignored=%0d tx=%0d",
                     st_rx, st_crc, st_arp, st_icmp, st_udp, st_ign, st_tx);
        else begin
            $display("FAIL  counters rx=%0d/%0d crc=%0d/%0d arp=%0d/%0d icmp=%0d/%0d udp=%0d/%0d ign=%0d/%0d tx=%0d/%0d",
                     st_rx, e_rx, st_crc, e_crc, st_arp, e_arp, st_icmp, e_icmp, st_udp, e_udp, st_ign, e_drop, st_tx, e_tx);
            errors = errors + 1;
        end
        if (msg_bytes === exp_msg) $display("PASS  text message captured for the display");
        else begin $display("FAIL  text message %0h", msg_bytes); errors = errors + 1; end
        if (st_ovr == 0) $display("PASS  no overrun during the sequential test");
        else begin $display("FAIL  unexpected overrun count %0d", st_ovr); errors = errors + 1; end

        // ---- back-to-back frames: the second arrives while the buffer is busy and is dropped ----
        // (re-send the first request twice with a normal 96-bit-time gap)
        fd = $fopen(vecname, "r");
        r = $fscanf(fd, "%d", in_len);
        for (i = 0; i < in_len; i = i + 1) begin r = $fscanf(fd, "%h", b); in_frame[i] = b; end
        r = $fscanf(fd, "%d", exp_len);
        for (i = 0; i < exp_len; i = i + 1) begin r = $fscanf(fd, "%h", b); exp_frame[i] = b; end
        got_frame = 0; idx = frames_seen;
        send_frame(in_len, 0);
        repeat (48) @(posedge clk);
        send_frame(in_len, 0);
        repeat (6000) @(posedge clk);
        if (st_ovr == 1 && frames_seen == idx + 1) $display("PASS  back-to-back frames: second one dropped and counted as overrun");
        else begin $display("FAIL  back-to-back: overrun=%0d replies=%0d", st_ovr, frames_seen - idx); errors = errors + 1; end
        check_reply(0);

        // ---- optional: write one VGA frame (the dashboard) to frame.txt (+dump) ----
        if ($test$plusargs("dump")) begin : dump_frame
            integer fdo;
            fdo = $fopen("frame.txt", "w");
            repeat (200) @(posedge clk25);
            @(negedge vvs);
            @(negedge vvs);                                   // start of a complete frame
            repeat (1) @(posedge clk25);
            begin : cap
                integer nn;
                nn = 0;
                while (nn < 640*480) begin
                    @(posedge clk25);
                    if (dut.u_vga.act3) begin $fwrite(fdo, "%0d %0d %0d\n", vr, vg, vb); nn = nn + 1; end
                end
            end
            $fclose(fdo);
        end

        if (errors == 0) $display("ALL ETHERNET TESTS PASSED");
        else             $display("%0d ETHERNET TEST(S) FAILED", errors);
        $finish;
    end
    initial begin #80_000_000; $display("FAIL  global timeout"); $finish; end
endmodule
