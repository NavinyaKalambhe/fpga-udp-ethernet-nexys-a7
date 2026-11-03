// net_engine.v - packet engine: ARP reply, ICMP echo reply (ping) and UDP echo / text display.
//
// How it works: the received frame sits in the frame RAM. The engine copies the first 74 bytes
// into a header register file, decides what the frame is, verifies the IPv4 header checksum, and
// then rewrites the first 42 bytes of the SAME frame in place so that it becomes the reply:
//   * Ethernet: destination <- requester MAC, source <- our MAC
//   * ARP request -> ARP reply (operation = 2, sender/target fields swapped)
//   * IPv4: source <- our IP, destination <- requester IP. Swapping two 16-bit words does not
//     change the ones-complement sum, so the IP header checksum and the UDP checksum stay valid.
//   * ICMP echo request -> reply: type 8 -> 0, checksum += 0x0800 (end-around carry)
//   * UDP: source and destination ports swapped (payload is echoed unchanged)
// The payload bytes beyond the header are never copied: the transmitter streams them straight
// from the same RAM. UDP port PORT_TEXT additionally shows the payload on the VGA screen.
module net_engine #(
    parameter [47:0] OUR_MAC   = 48'h02A700000001,
    parameter [31:0] OUR_IP    = 32'hC0A8010A,       // 192.168.1.10
    parameter [15:0] PORT_ECHO = 16'd7777,
    parameter [15:0] PORT_TEXT = 16'd5005
) (
    input             clk,
    input             rst,
    // from the receiver
    input             frame_ready,       // pulse: a good frame is in the RAM
    input      [10:0] frame_len,         // incl. FCS
    // frame RAM access (combinational address, 1-cycle read latency)
    output     [10:0] ram_addr,
    output            ram_we,
    output     [7:0]  ram_wdata,
    input      [7:0]  ram_rdata,
    // transmitter
    output reg        tx_start,
    output reg [10:0] tx_len,
    input             tx_done,
    output reg        release_buf,       // pulse: the frame buffer is free again
    // statistics / display
    output reg [31:0] st_rx,             // good frames received
    output reg [31:0] st_arp,
    output reg [31:0] st_icmp,
    output reg [31:0] st_udp,
    output reg [31:0] st_ignored,        // good frames that were not for us / unsupported
    output reg [255:0] dump_bytes,       // first 32 bytes of the last accepted frame (byte 0 = MSB)
    output reg [255:0] msg_bytes,        // last text message (UDP port PORT_TEXT), byte 0 = MSB
    output reg [31:0] last_ip,           // source IP of the last accepted frame
    output reg [15:0] last_port,         // UDP source port of the last accepted UDP frame
    output reg [15:0] last_len           // length of the last accepted frame (without FCS)
);
    localparam E_IDLE = 4'd0, E_FETCH = 4'd1, E_DECODE = 4'd2, E_CSUM = 4'd3, E_CHK = 4'd4,
               E_PATCH = 4'd5, E_TX = 4'd6, E_WAIT = 4'd7, E_DONE = 4'd8;
    localparam K_DROP = 2'd0, K_ARP = 2'd1, K_ICMP = 2'd2, K_UDP = 2'd3;
    localparam integer NHDR = 74;

    reg [3:0]  state = E_IDLE;
    reg [6:0]  k = 7'd0;
    reg [1:0]  kind = K_DROP;
    reg        is_text = 1'b0;
    reg [10:0] reply_len = 11'd0;
    reg [19:0] sum = 20'd0;
    reg [7:0]  hdr [0:NHDR-1];

    // ------------------------------------------------------------------ frame classification
    wire [47:0] dst_mac = {hdr[0], hdr[1], hdr[2], hdr[3], hdr[4], hdr[5]};
    wire        for_us  = (dst_mac == OUR_MAC);
    wire        bcast   = (dst_mac == 48'hFFFFFFFFFFFF);
    wire [15:0] etype   = {hdr[12], hdr[13]};

    wire arp_ok = (for_us | bcast) && etype == 16'h0806 &&
                  {hdr[14], hdr[15]} == 16'h0001 && {hdr[16], hdr[17]} == 16'h0800 &&
                  hdr[18] == 8'd6 && hdr[19] == 8'd4 && {hdr[20], hdr[21]} == 16'h0001 &&
                  {hdr[38], hdr[39], hdr[40], hdr[41]} == OUR_IP && frame_len >= 11'd46;

    wire [15:0] ip_len   = {hdr[16], hdr[17]};
    wire [16:0] ip_total = {1'b0, ip_len} + 17'd14;
    wire [16:0] avail    = {6'd0, frame_len} - 17'd4;
    wire        ip_ok    = for_us && etype == 16'h0800 && hdr[14] == 8'h45 &&
                           {hdr[30], hdr[31], hdr[32], hdr[33]} == OUR_IP &&
                           ({hdr[20], hdr[21]} & 16'h3FFF) == 16'h0000 &&
                           ip_len >= 16'd28 && ip_total <= avail;

    wire [15:0] udp_len  = {hdr[38], hdr[39]};
    wire [15:0] dport    = {hdr[36], hdr[37]};
    wire icmp_ok = ip_ok && hdr[23] == 8'd1 && hdr[34] == 8'd8 && hdr[35] == 8'd0;
    wire udp_ok  = ip_ok && hdr[23] == 8'd17 && udp_len >= 16'd8 &&
                   ({1'b0, udp_len} + 17'd20) <= {1'b0, ip_len} &&
                   (dport == PORT_ECHO || dport == PORT_TEXT);

    wire [16:0] fold1 = {1'b0, sum[15:0]} + {13'd0, sum[19:16]};
    wire [15:0] fold2 = fold1[15:0] + {15'd0, fold1[16]};

    // ICMP checksum update for type 8 -> 0
    wire [16:0] csum_raw = {1'b0, hdr[36], hdr[37]} + 17'h00800;
    wire [15:0] csum_new = csum_raw[15:0] + {15'd0, csum_raw[16]};

    // ------------------------------------------------------------------ reply header bytes
    reg [7:0] nb;
    always @* begin
        nb = hdr[k];
        if (k < 7'd6)                nb = hdr[6 + k];                      // dst <- requester MAC
        else if (k < 7'd12)          nb = OUR_MAC[8*(11-k) +: 8];          // src <- our MAC
        else if (kind == K_ARP) begin
            if (k == 7'd20)                            nb = 8'h00;         // operation = 2 (reply)
            else if (k == 7'd21)                       nb = 8'h02;
            else if (k >= 7'd22 && k <= 7'd27)         nb = OUR_MAC[8*(27-k) +: 8];   // sender MAC
            else if (k >= 7'd28 && k <= 7'd31)         nb = OUR_IP[8*(31-k) +: 8];    // sender IP
            else if (k >= 7'd32 && k <= 7'd41)         nb = hdr[k - 10];   // target <- requester
        end else begin                                                     // IPv4
            if (k >= 7'd26 && k <= 7'd29)              nb = OUR_IP[8*(29-k) +: 8];    // src IP
            else if (k >= 7'd30 && k <= 7'd33)         nb = hdr[k - 4];                // dst IP
            else if (kind == K_ICMP) begin
                if (k == 7'd34)                        nb = 8'h00;         // echo reply
                else if (k == 7'd36)                   nb = csum_new[15:8];
                else if (k == 7'd37)                   nb = csum_new[7:0];
            end else if (kind == K_UDP) begin
                if (k == 7'd34)                        nb = hdr[36];       // swap the ports
                else if (k == 7'd35)                   nb = hdr[37];
                else if (k == 7'd36)                   nb = hdr[34];
                else if (k == 7'd37)                   nb = hdr[35];
            end
        end
    end

    assign ram_addr  = {4'd0, k};
    assign ram_we    = (state == E_PATCH);
    assign ram_wdata = nb;

    // ------------------------------------------------------------------ main FSM
    integer j;
    reg [15:0] plen;
    always @(posedge clk) begin
        tx_start    <= 1'b0;
        release_buf <= 1'b0;

        if (rst) begin
            state <= E_IDLE;
            st_rx <= 32'd0; st_arp <= 32'd0; st_icmp <= 32'd0; st_udp <= 32'd0; st_ignored <= 32'd0;
            dump_bytes <= 256'd0; msg_bytes <= {32{8'h20}};
            last_ip <= 32'd0; last_port <= 16'd0; last_len <= 16'd0;
        end else begin
            case (state)
                E_IDLE: if (frame_ready) begin
                    st_rx <= st_rx + 32'd1; k <= 7'd0; state <= E_FETCH;
                end

                E_FETCH: begin                          // copy the first 74 bytes into hdr[]
                    if (k != 7'd0) hdr[k - 7'd1] <= ram_rdata;
                    if (k == NHDR) state <= E_DECODE;
                    k <= k + 7'd1;
                end

                E_DECODE: begin
                    k <= 7'd0; sum <= 20'd0;
                    is_text <= 1'b0;
                    if (arp_ok) begin
                        kind <= K_ARP; reply_len <= 11'd42; state <= E_PATCH;
                    end else if (icmp_ok) begin
                        kind <= K_ICMP; reply_len <= ip_total[10:0]; state <= E_CSUM;
                    end else if (udp_ok) begin
                        kind <= K_UDP; reply_len <= ip_total[10:0]; state <= E_CSUM;
                        is_text <= (dport == PORT_TEXT);
                    end else begin
                        kind <= K_DROP; state <= E_DONE;
                    end
                end

                E_CSUM: begin                           // IPv4 header checksum: 10 words
                    sum <= sum + {4'd0, hdr[14 + 2*k], hdr[15 + 2*k]};
                    k <= k + 7'd1;
                    if (k == 7'd9) state <= E_CHK;
                end

                E_CHK: begin
                    k <= 7'd0;
                    if (fold2 == 16'hFFFF) state <= E_PATCH;
                    else begin kind <= K_DROP; state <= E_DONE; end
                end

                E_PATCH: begin                          // rewrite bytes 0..41 (see nb above)
                    k <= k + 7'd1;
                    if (k == 7'd41) state <= E_TX;
                end

                E_TX: begin
                    tx_start <= 1'b1; tx_len <= reply_len; state <= E_WAIT;
                end

                E_WAIT: if (tx_done) state <= E_DONE;

                E_DONE: begin
                    if (kind == K_DROP) st_ignored <= st_ignored + 32'd1;
                    else begin
                        if (kind == K_ARP)  st_arp  <= st_arp  + 32'd1;
                        if (kind == K_ICMP) st_icmp <= st_icmp + 32'd1;
                        if (kind == K_UDP)  st_udp  <= st_udp  + 32'd1;
                        for (j = 0; j < 32; j = j + 1) dump_bytes[255 - 8*j -: 8] <= hdr[j];
                        last_ip  <= (kind == K_ARP) ? {hdr[28], hdr[29], hdr[30], hdr[31]}
                                                    : {hdr[26], hdr[27], hdr[28], hdr[29]};
                        last_len <= {5'd0, frame_len} - 16'd4;
                        if (kind == K_UDP) last_port <= {hdr[34], hdr[35]};
                        if (kind == K_UDP && is_text) begin
                            plen = udp_len - 16'd8;
                            for (j = 0; j < 32; j = j + 1)
                                msg_bytes[255 - 8*j -: 8] <= (j < plen) ? hdr[42 + j] : 8'h20;
                        end
                    end
                    release_buf <= 1'b1;
                    state <= E_IDLE;
                end

                default: state <= E_IDLE;
            endcase
        end
    end
endmodule
