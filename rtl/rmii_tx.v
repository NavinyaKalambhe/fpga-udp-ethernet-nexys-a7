// rmii_tx.v - RMII transmitter: preamble + SFD, frame bytes from the frame RAM, zero padding to
// 60 bytes, CRC-32 FCS, inter-frame gap. 2 bits per 50 MHz clock, LSB first.
module rmii_tx (
    input             clk,
    input             rst,
    input             start,         // pulse: send `len` bytes from the frame RAM (without FCS)
    input      [10:0] len,
    output     [10:0] ram_addr,
    input      [7:0]  ram_rdata,
    output reg        busy,
    output reg        done,          // 1-cycle pulse when the frame and the gap are finished
    output            txen,
    output     [1:0]  txd
);
    localparam T_IDLE = 3'd0, T_PRE = 3'd1, T_DATA = 3'd2, T_FCS = 3'd3, T_IFG = 3'd4;
    localparam [10:0] MIN_LEN = 11'd60;

    reg [2:0]  state = T_IDLE;
    reg [1:0]  ph = 2'd0;            // dibit within the byte
    reg [10:0] cnt = 11'd0;          // byte counter
    reg [10:0] lenr = 11'd0, padlen = 11'd0;
    reg [7:0]  cur = 8'd0;
    reg [31:0] crc = 32'hFFFFFFFF;

    function [31:0] crc32_byte(input [31:0] c_in, input [7:0] d);
        integer i;
        reg [31:0] c;
        begin
            c = c_in ^ {24'd0, d};
            for (i = 0; i < 8; i = i + 1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            crc32_byte = c;
        end
    endfunction

    // RAM address: byte 0 while sending the preamble, then always the NEXT byte to send
    assign ram_addr = (state == T_DATA) ? (cnt + 11'd1) : 11'd0;

    wire [31:0] fcs = ~crc;
    wire [10:0] cnt_n = cnt + 11'd1;

    // Internal (rising-edge) registers.
    reg       txen_r = 1'b0;
    reg [1:0] txd_r  = 2'b00;

    // Output registers on the FALLING edge of the 50 MHz clock (placed in the IO blocks).
    // The PHY samples TXD/TXEN on the rising edge of the REF_CLK we send it. If TXD changed on the same
    // rising edge as REF_CLK there would be ~0 ns of hold time at the PHY (it needs 1.5 ns), so frames
    // would be corrupted. Launching half a clock (10 ns) later gives about 10 ns of setup AND hold.
    // Seen from the testbench (which samples on the rising edge) the timing is unchanged.
    (* IOB = "TRUE" *) reg       txen_n = 1'b0;
    (* IOB = "TRUE" *) reg [1:0] txd_n  = 2'b00;
    always @(negedge clk) begin
        txen_n <= txen_r;
        txd_n  <= txd_r;
    end
    assign txen = txen_n;
    assign txd  = txd_n;

    always @(posedge clk) begin
        done <= 1'b0;
        txen_r <= 1'b0;
        txd_r  <= 2'b00;

        if (rst) begin
            state <= T_IDLE; busy <= 1'b0;
        end else begin
            case (state)
                T_IDLE: if (start) begin
                    lenr <= len; padlen <= (len < MIN_LEN) ? MIN_LEN : len;
                    cnt <= 11'd0; ph <= 2'd0; cur <= 8'h55; busy <= 1'b1; state <= T_PRE;
                end

                T_PRE: begin                       // 7 x 0x55, then SFD 0xD5
                    txen_r <= 1'b1; txd_r <= cur[2*ph +: 2];
                    ph <= ph + 2'd1;
                    if (ph == 2'd3) begin
                        if (cnt == 11'd7) begin
                            state <= T_DATA; cnt <= 11'd0; crc <= 32'hFFFFFFFF;
                            cur <= (lenr != 11'd0) ? ram_rdata : 8'h00;
                        end else begin
                            cnt <= cnt_n; cur <= (cnt_n == 11'd7) ? 8'hD5 : 8'h55;
                        end
                    end
                end

                T_DATA: begin
                    txen_r <= 1'b1; txd_r <= cur[2*ph +: 2];
                    ph <= ph + 2'd1;
                    if (ph == 2'd0) crc <= crc32_byte(crc, cur);
                    if (ph == 2'd3) begin
                        if (cnt_n == padlen) begin
                            state <= T_FCS; cnt <= 11'd0; cur <= fcs[7:0];
                        end else begin
                            cnt <= cnt_n;
                            cur <= (cnt_n < lenr) ? ram_rdata : 8'h00;   // zero padding
                        end
                    end
                end

                T_FCS: begin                       // FCS, least significant byte first
                    txen_r <= 1'b1; txd_r <= cur[2*ph +: 2];
                    ph <= ph + 2'd1;
                    if (ph == 2'd3) begin
                        if (cnt == 11'd3) begin state <= T_IFG; cnt <= 11'd0; end
                        else begin
                            cnt <= cnt_n;
                            case (cnt[1:0])
                                2'd0: cur <= fcs[15:8];
                                2'd1: cur <= fcs[23:16];
                                default: cur <= fcs[31:24];
                            endcase
                        end
                    end
                end

                T_IFG: begin                       // 60 clocks = 120 bit times (> 96 required)
                    cnt <= cnt_n;
                    if (cnt == 11'd59) begin state <= T_IDLE; busy <= 1'b0; done <= 1'b1; end
                end

                default: state <= T_IDLE;
            endcase
        end
    end
endmodule
