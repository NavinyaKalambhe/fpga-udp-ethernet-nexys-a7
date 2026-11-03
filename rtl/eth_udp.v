// eth_udp.v - Ethernet/UDP node: RMII receiver + frame RAM + packet engine + RMII transmitter.
//
// One frame buffer is shared by everybody: the receiver fills it, the engine turns the request
// into the reply in place, the transmitter sends it. Frames that arrive while the buffer is busy
// are ignored and counted in `st_overrun` (use a ping-pong buffer to remove this limit).
module eth_udp #(
    parameter [47:0] OUR_MAC   = 48'h02A700000001,
    parameter [31:0] OUR_IP    = 32'hC0A8010A,
    parameter [15:0] PORT_ECHO = 16'd7777,
    parameter [15:0] PORT_TEXT = 16'd5005
) (
    input             clk,              // 50 MHz RMII clock
    input             rst,
    // PHY (RMII)
    input             crs_dv,
    input      [1:0]  rxd,
    output            txen,
    output     [1:0]  txd,
    // statistics / display
    output reg [31:0] st_rx_frames,
    output reg [31:0] st_tx_frames,
    output reg [31:0] st_crc_err,
    output reg [31:0] st_overrun,
    output     [31:0] st_arp,
    output     [31:0] st_icmp,
    output     [31:0] st_udp,
    output     [31:0] st_ignored,
    output     [255:0] dump_bytes,
    output     [255:0] msg_bytes,
    output     [31:0] last_ip,
    output     [15:0] last_port,
    output     [15:0] last_len
);
    // ---- shared frame RAM ----
    wire [10:0] rx_addr, eng_addr, tx_addr, ram_addr;
    wire        rx_we, eng_we, ram_we;
    wire [7:0]  rx_wdata, eng_wdata, ram_wdata, ram_rdata;

    wire        rx_done, rx_good, rx_overrun, tx_busy, tx_done, tx_start, release_buf;
    wire [10:0] rx_len, tx_len;
    reg         hold = 1'b0;                 // buffer owned by engine / transmitter

    wire sel_tx  = tx_busy;
    wire sel_eng = hold & ~tx_busy;
    assign ram_addr  = sel_tx ? tx_addr : sel_eng ? eng_addr : rx_addr;
    assign ram_we    = sel_tx ? 1'b0    : sel_eng ? eng_we   : rx_we;
    assign ram_wdata = sel_eng ? eng_wdata : rx_wdata;

    frame_ram u_ram (.clk(clk), .addr(ram_addr), .we(ram_we), .wdata(ram_wdata), .rdata(ram_rdata));

    rmii_rx u_rx (
        .clk(clk), .rst(rst), .crs_dv_in(crs_dv), .rxd_in(rxd), .busy(hold),
        .ram_we(rx_we), .ram_addr(rx_addr), .ram_wdata(rx_wdata),
        .frame_done(rx_done), .frame_len(rx_len), .frame_good(rx_good), .overrun(rx_overrun)
    );

    net_engine #(.OUR_MAC(OUR_MAC), .OUR_IP(OUR_IP), .PORT_ECHO(PORT_ECHO), .PORT_TEXT(PORT_TEXT)) u_eng (
        .clk(clk), .rst(rst),
        .frame_ready(rx_done & rx_good), .frame_len(rx_len),
        .ram_addr(eng_addr), .ram_we(eng_we), .ram_wdata(eng_wdata), .ram_rdata(ram_rdata),
        .tx_start(tx_start), .tx_len(tx_len), .tx_done(tx_done), .release_buf(release_buf),
        .st_rx(), .st_arp(st_arp), .st_icmp(st_icmp), .st_udp(st_udp), .st_ignored(st_ignored),
        .dump_bytes(dump_bytes), .msg_bytes(msg_bytes),
        .last_ip(last_ip), .last_port(last_port), .last_len(last_len)
    );

    rmii_tx u_tx (
        .clk(clk), .rst(rst), .start(tx_start), .len(tx_len),
        .ram_addr(tx_addr), .ram_rdata(ram_rdata),
        .busy(tx_busy), .done(tx_done), .txen(txen), .txd(txd)
    );

    always @(posedge clk) begin
        if (rst) begin
            hold <= 1'b0;
            st_rx_frames <= 32'd0; st_tx_frames <= 32'd0; st_crc_err <= 32'd0; st_overrun <= 32'd0;
        end else begin
            if (rx_done && rx_good) begin hold <= 1'b1; st_rx_frames <= st_rx_frames + 32'd1; end
            else if (release_buf)   hold <= 1'b0;
            if (rx_done && !rx_good) st_crc_err <= st_crc_err + 32'd1;
            if (rx_overrun)          st_overrun <= st_overrun + 32'd1;
            if (tx_done)             st_tx_frames <= st_tx_frames + 32'd1;
        end
    end
endmodule
