module async_fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 16 // Typically required to be a power of 2 for Gray code logic
)(
    // Write Domain
    input  logic                    wr_clk,
    input  logic                    wr_rst_n, // Active-low reset synchronized to wr_clk
    input  logic                    wr_en,
    input  logic [DATA_WIDTH-1:0]   wr_data,
    output logic                    wr_full,  // Full flag synced to wr_clk

    // Read Domain
    input  logic                    rd_clk,
    input  logic                    rd_rst_n, // Active-low reset synchronized to rd_clk
    input  logic                    rd_en,
    output logic [DATA_WIDTH-1:0]   rd_data,
    output logic                    rd_empty  // Empty flag synced to rd_clk
);
    // Implementation logic goes here...
endmodule