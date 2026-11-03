// rmii_rx.v - RMII receiver: preamble/SFD detection, dibit -> byte assembly, CRC-32 check.
//
// RMII (100 Mb/s): 2 bits per 50 MHz clock, LSB first. CRS_DV is "carrier sense OR data valid";
// when the carrier drops before the last data has been delivered the PHY toggles CRS_DV
// (0 on the first dibit of a nibble, 1 on the second), so data validity is taken from CRS_DV on
// the SECOND dibit of every nibble. A nibble with CRS_DV = 0 there ends the frame.
//
// The whole frame (destination MAC ... FCS) is stored in the frame RAM; the CRC residue decides
// whether it is good. Frames that arrive while the buffer is busy are ignored (counted by `overrun`).
module rmii_rx (
    input             clk,          // 50 MHz RMII reference clock
    input             rst,
    input             crs_dv_in,
    input      [1:0]  rxd_in,
    input             busy,         // frame buffer still in use -> ignore new frames
    output reg        ram_we,
    output reg [10:0] ram_addr,
    output reg [7:0]  ram_wdata,
    output reg        frame_done,   // 1-cycle pulse at the end of every frame
    output reg [10:0] frame_len,    // bytes stored, including the 4-byte FCS
    output reg        frame_good,   // CRC ok, whole bytes, >= 18 bytes
    output reg        overrun       // 1-cycle pulse: a frame was ignored because `busy`
);
    localparam [31:0] CRC_RESIDUE = 32'hDEBB20E3;   // CRC register after data + FCS

    // input registers (placed in the IO blocks by the tools)
    (* IOB = "TRUE" *) reg       crs_q = 1'b0;
    (* IOB = "TRUE" *) reg [1:0] rxd_q = 2'b00;

    localparam S_IDLE = 2'd0, S_PRE = 2'd1, S_DATA = 2'd2, S_IGN = 2'd3;
    reg [1:0]  state = S_IDLE;
    reg        ph = 1'b0;            // dibit within the nibble
    reg [1:0]  d0 = 2'b00;           // first dibit of the nibble
    reg        nibcnt = 1'b0;        // 0: next nibble is a low nibble
    reg [3:0]  lo = 4'd0;            // low nibble of the byte being assembled
    reg [31:0] crc = 32'hFFFFFFFF;
    reg [11:0] len = 12'd0;
    reg        ign_lo = 1'b0;

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

    wire [7:0] byte_v = {rxd_q, d0, lo};

    always @(posedge clk) begin
        crs_q <= crs_dv_in;
        rxd_q <= rxd_in;
        ram_we <= 1'b0;
        frame_done <= 1'b0;
        overrun <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (crs_q && rxd_q == 2'b01) begin
                    if (busy) begin state <= S_IGN; ign_lo <= 1'b0; overrun <= 1'b1; end
                    else      state <= S_PRE;
                end

                S_IGN: begin             // wait for the end of a frame we cannot store
                    if (!crs_q) begin
                        if (ign_lo) state <= S_IDLE;
                        ign_lo <= 1'b1;
                    end else ign_lo <= 1'b0;
                end

                S_PRE: begin
                    if (!crs_q)               state <= S_IDLE;
                    else if (rxd_q == 2'b01)  state <= S_PRE;          // preamble
                    else if (rxd_q == 2'b11) begin                     // end of SFD
                        state <= S_DATA; ph <= 1'b0; nibcnt <= 1'b0;
                        crc <= 32'hFFFFFFFF; len <= 12'd0;
                    end else                  state <= S_IDLE;
                end

                S_DATA: begin
                    if (!ph) begin
                        d0 <= rxd_q; ph <= 1'b1;
                    end else begin
                        ph <= 1'b0;
                        if (crs_q) begin                                // nibble is valid
                            if (!nibcnt) begin
                                lo <= {rxd_q, d0}; nibcnt <= 1'b1;
                            end else begin
                                nibcnt <= 1'b0;
                                crc <= crc32_byte(crc, byte_v);
                                if (len < 12'd2048) begin
                                    ram_we <= 1'b1; ram_addr <= len[10:0]; ram_wdata <= byte_v;
                                end
                                if (len != 12'hFFF) len <= len + 12'd1;
                            end
                        end else begin                                  // end of frame
                            state <= S_IDLE;
                            frame_done <= 1'b1;
                            frame_len  <= (len > 12'd2047) ? 11'd2047 : len[10:0];
                            frame_good <= (crc == CRC_RESIDUE) && !nibcnt && (len >= 12'd18) && (len <= 12'd2048);
                        end
                    end
                end
            endcase
        end
    end
endmodule
