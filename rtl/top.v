// top.v - Nexys A7 top level: UDP/Ethernet node with a VGA status display.
//
//   100 MHz board clock -> 50 MHz (RMII reference clock for the LAN8720A PHY, also the stack clock)
//                       -> 25 MHz (VGA pixel clock)
module top (
    input         CLK100MHZ,
    input         CPU_RESETN,       // active-low reset button
    output [15:0] LED,
    // VGA
    output [3:0]  VGA_R,
    output [3:0]  VGA_G,
    output [3:0]  VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    // Ethernet PHY (LAN8720A, RMII)
    output        ETH_REFCLK,       // 50 MHz clock supplied to the PHY
    output        ETH_RSTN,
    input         ETH_CRSDV,
    input  [1:0]  ETH_RXD,
    output        ETH_TXEN,
    output [1:0]  ETH_TXD,
    output        ETH_MDC,
    inout         ETH_MDIO
);
    // ---------------- clocks ----------------
    reg [1:0] div = 2'b00;
    always @(posedge CLK100MHZ) div <= div + 1'b1;

    wire clk50, clk25;
    BUFG b50 (.I(div[0]), .O(clk50));
    BUFG b25 (.I(div[1]), .O(clk25));

    // forward the 50 MHz clock to the PHY through an output register (clean, glitch-free)
    ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) refclk_oddr (
        .Q(ETH_REFCLK), .C(clk50), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));

    // ---------------- reset ----------------
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk50) rst_sync <= {rst_sync[0], ~CPU_RESETN};
    wire rst = rst_sync[1];

    // hold the PHY in reset for ~10 ms (with its clock running), then release it
    reg [19:0] phy_cnt = 20'd0;
    reg        phy_rstn = 1'b0;
    always @(posedge clk50) begin
        if (rst) begin phy_cnt <= 20'd0; phy_rstn <= 1'b0; end
        else if (!phy_cnt[19]) phy_cnt <= phy_cnt + 20'd1;
        else phy_rstn <= 1'b1;
    end
    assign ETH_RSTN = phy_rstn;

    // management interface unused
    assign ETH_MDC  = 1'b0;
    assign ETH_MDIO = 1'bz;

    // ---------------- node ----------------
    wire [31:0] rx_frames, tx_frames;
    wire [255:0] dump_unused, msg_unused;
    wire [31:0] unused32a, unused32b, unused32c, unused32d, unused32e, unused32f;
    wire [31:0] lip; wire [15:0] lport, llen;

    eth_node node (
        .clk(clk50), .clk_vga(clk25), .rst(rst | ~phy_rstn),
        .crs_dv(ETH_CRSDV), .rxd(ETH_RXD), .txen(ETH_TXEN), .txd(ETH_TXD),
        .vga_r(VGA_R), .vga_g(VGA_G), .vga_b(VGA_B), .vga_hs(VGA_HS), .vga_vs(VGA_VS),
        .st_rx_frames(rx_frames), .st_tx_frames(tx_frames), .st_crc_err(unused32a), .st_overrun(unused32b),
        .st_arp(unused32c), .st_icmp(unused32d), .st_udp(unused32e), .st_ignored(unused32f),
        .dump_bytes(dump_unused), .msg_bytes(msg_unused), .last_ip(lip), .last_port(lport), .last_len(llen)
    );

    // LEDs: low byte of received / transmitted frame counters
    assign LED = {tx_frames[7:0], rx_frames[7:0]};
endmodule
