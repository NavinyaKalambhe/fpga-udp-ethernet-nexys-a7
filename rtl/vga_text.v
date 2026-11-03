// vga_text.v - 40 x 30 character text display on 640x480 @ 60 Hz VGA (8x8 glyphs at 2x).
//
// The character RAM has two independent clocks: it is written by the status writer in the 50 MHz
// domain and read here in the 25 MHz pixel domain, so no extra synchronisers are needed.
// Pipeline: counters -> RAM read -> font ROM -> pixel/colour (3 registered stages).
module vga_text (
    // text RAM write port (50 MHz domain)
    input         clk_w,
    input         tw_en,
    input  [10:0] tw_addr,
    input  [5:0]  tw_data,
    // video (25 MHz pixel clock)
    input         clk_v,
    output reg [3:0] vga_r  = 4'd0,
    output reg [3:0] vga_g  = 4'd0,
    output reg [3:0] vga_b  = 4'd0,
    output reg       vga_hs = 1'b1,
    output reg       vga_vs = 1'b1
);
    localparam H_VIS = 640, H_FP = 16, H_SYNC = 96, H_TOT = 800;
    localparam V_VIS = 480, V_FP = 10, V_SYNC = 2,  V_TOT = 525;

    // ---------------- character RAM ----------------
    (* ram_style = "block" *) reg [5:0] tram [0:2047];
    integer i;
    initial for (i = 0; i < 2048; i = i + 1) tram[i] = 6'd0;      // 0 = space
    always @(posedge clk_w) if (tw_en) tram[tw_addr] <= tw_data;

    // ---------------- sync counters ----------------
    reg [9:0] hcnt = 10'd0, vcnt = 10'd0;
    always @(posedge clk_v) begin
        if (hcnt == H_TOT - 1) begin
            hcnt <= 10'd0;
            vcnt <= (vcnt == V_TOT - 1) ? 10'd0 : vcnt + 10'd1;
        end else hcnt <= hcnt + 10'd1;
    end
    wire active = (hcnt < H_VIS) && (vcnt < V_VIS);
    wire hs = ~((hcnt >= H_VIS + H_FP) && (hcnt < H_VIS + H_FP + H_SYNC));
    wire vs = ~((vcnt >= V_VIS + V_FP) && (vcnt < V_VIS + V_FP + V_SYNC));

    // ---------------- stage 1: character index ----------------
    wire [4:0]  row   = vcnt[8:4];                                   // 16 lines per character row
    wire [5:0]  col   = hcnt[9:4];                                   // 16 pixels per character column
    wire [10:0] caddr = {1'b0, row, 5'b0} + {3'b0, row, 3'b0} + {5'b0, col};   // row*40 + col

    reg [5:0] cidx = 6'd0;
    reg [2:0] px1 = 3'd0, py1 = 3'd0;
    reg [4:0] row1 = 5'd0;
    reg       act1 = 1'b0, hs1 = 1'b1, vs1 = 1'b1;
    always @(posedge clk_v) begin
        cidx <= tram[caddr];
        px1 <= hcnt[3:1]; py1 <= vcnt[3:1]; row1 <= row;
        act1 <= active; hs1 <= hs; vs1 <= vs;
    end

    // ---------------- stage 2: font row ----------------
    wire [7:0] fbits;
    font_rom u_font (.idx(cidx), .row(py1), .bits(fbits));

    reg [7:0] bits2 = 8'd0;
    reg [2:0] px2 = 3'd0;
    reg [4:0] row2 = 5'd0;
    reg       act2 = 1'b0, hs2 = 1'b1, vs2 = 1'b1;
    always @(posedge clk_v) begin
        bits2 <= fbits; px2 <= px1; row2 <= row1;
        act2 <= act1; hs2 <= hs1; vs2 <= vs1;
    end

    // ---------------- stage 3: pixel colour ----------------
    wire pix = bits2[3'd7 - px2];
    reg [11:0] fg;
    always @* begin
        case (row2)
            5'd1, 5'd2:              fg = 12'h0FF;     // title: cyan
            5'd4, 5'd5, 5'd6:        fg = 12'hFFF;     // identity: white
            5'd8, 5'd22, 5'd25:      fg = 12'hFF0;     // headings: yellow
            5'd23:                   fg = 12'hFB4;     // text message: orange
            5'd26, 5'd27, 5'd28:     fg = 12'h8CF;     // hex dump: light blue
            5'd29:                   fg = 12'h999;     // hint: grey
            default:                 fg = 12'h4F4;     // counters: green
        endcase
    end

    reg act3 = 1'b0;                                    // aligned with the outputs (for the testbench)
    always @(posedge clk_v) begin
        {vga_r, vga_g, vga_b} <= act2 ? (pix ? fg : 12'h002) : 12'h000;
        vga_hs <= hs2; vga_vs <= vs2; act3 <= act2;
    end
endmodule
