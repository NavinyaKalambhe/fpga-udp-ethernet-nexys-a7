// frame_ram.v - single-port 2 KB frame buffer (one Ethernet frame at a time).
// Shared between the receiver, the packet engine and the transmitter.
module frame_ram (
    input             clk,
    input      [10:0] addr,
    input             we,
    input      [7:0]  wdata,
    output reg [7:0]  rdata
);
    reg [7:0] mem [0:2047];
    always @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        rdata <= mem[addr];
    end
endmodule
