// ============================================================================
// File Name   : 
// Author      : Kevin Toledo Fernandez / GitHub: systemkev
// Date        : 
// Project     : Ethernet-Based AXI4-Stream Image Processing Pipeline
// Description : 
//
// License     : MIT
// ============================================================================

import common_pkg::*;

module line_buffer (
    input  logic i_clk,
    input  logic i_n_rst,
    input  logic i_shift_en,
    
    input  logic [DATA_WIDTH-1:0] i_din,
    output logic [DATA_WIDTH-1:0] o_dout
);

    localparam int DEPTH = IMG_WIDTH - 1;

    logic [DATA_WIDTH-1:0]    buffer [0:DEPTH-1];  // inferred as BRAM 
    logic [$clog2(DEPTH)-1:0] ptr;

    always_ff @(posedge i_clk or negedge i_n_rst) begin 
        if (!i_n_rst) begin 
            ptr <= '0;
        end else if (i_shift_en) begin 
            if (ptr == DEPTH - 1) begin
                ptr <= '0; 
            end else begin
                ptr <= ptr + 1;
            end
        end
    end

    always_ff @(posedge i_clk) begin
        if (i_shift_en) begin
            // read the pixel written here (IMG_WIDTH - 1) cycles ago
            o_dout <= buffer[ptr];
            
            // overwrite that same address with the incoming pixel
            buffer[ptr] <= i_din;
        end
    end

endmodule 