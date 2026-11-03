// eth_node.v - everything except the board-specific clock and pin primitives:
// Ethernet/UDP stack + VGA text dashboard. (Simulated directly by the testbench.)
module eth_node #(
    parameter [47:0] OUR_MAC   = 48'h02A700000001,
    parameter [31:0] OUR_IP    = 32'hC0A8010A,
    parameter [15:0] PORT_ECHO = 16'd7777,
    parameter [15:0] PORT_TEXT = 16'd5005
) (
    input         clk,              // 50 MHz (RMII reference clock, stack clock)
    input         clk_vga,          // 25 MHz pixel clock
    input         rst,
    // RMII
    input         crs_dv,
    input  [1:0]  rxd,
    output        txen,
    output [1:0]  txd,
    // VGA
    output [3:0]  vga_r,
    output [3:0]  vga_g,
    output [3:0]  vga_b,
    output        vga_hs,
    output        vga_vs,
    // statistics (also used for the LEDs and by the testbench)
    output [31:0] st_rx_frames,
    output [31:0] st_tx_frames,
    output [31:0] st_crc_err,
    output [31:0] st_overrun,
    output [31:0] st_arp,
    output [31:0] st_icmp,
    output [31:0] st_udp,
    output [31:0] st_ignored,
    output [255:0] dump_bytes,
    output [255:0] msg_bytes,
    output [31:0] last_ip,
    output [15:0] last_port,
    output [15:0] last_len
);
    eth_udp #(.OUR_MAC(OUR_MAC), .OUR_IP(OUR_IP), .PORT_ECHO(PORT_ECHO), .PORT_TEXT(PORT_TEXT)) u_eth (
        .clk(clk), .rst(rst), .crs_dv(crs_dv), .rxd(rxd), .txen(txen), .txd(txd),
        .st_rx_frames(st_rx_frames), .st_tx_frames(st_tx_frames), .st_crc_err(st_crc_err),
        .st_overrun(st_overrun), .st_arp(st_arp), .st_icmp(st_icmp), .st_udp(st_udp),
        .st_ignored(st_ignored), .dump_bytes(dump_bytes), .msg_bytes(msg_bytes),
        .last_ip(last_ip), .last_port(last_port), .last_len(last_len)
    );

    wire        tw_en;
    wire [10:0] tw_addr;
    wire [5:0]  tw_data;

    status_writer u_wr (
        .clk(clk),
        .st_rx_frames(st_rx_frames), .st_tx_frames(st_tx_frames), .st_crc_err(st_crc_err),
        .st_overrun(st_overrun), .st_arp(st_arp), .st_icmp(st_icmp), .st_udp(st_udp),
        .st_ignored(st_ignored), .last_ip(last_ip), .last_port(last_port), .last_len(last_len),
        .msg_bytes(msg_bytes), .dump_bytes(dump_bytes),
        .tw_en(tw_en), .tw_addr(tw_addr), .tw_data(tw_data)
    );

    vga_text u_vga (
        .clk_w(clk), .tw_en(tw_en), .tw_addr(tw_addr), .tw_data(tw_data),
        .clk_v(clk_vga), .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs)
    );
endmodule
