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

module sliding_frame (
    input  logic                  i_clk,
    input  logic                  i_n_rst,
    input  logic                  i_shift_en,   // high when incoming pixel is valid and pipeline is moving
    input  logic [DATA_WIDTH-1:0] i_pixel,      // raw pixel coming from input stream
    input  logic                  i_start_frame,

    // 3x3 window outputs 
    output logic                  o_window_vld,
    output logic [DATA_WIDTH-1:0] o_win_00, o_win_01, o_win_02,  // top row (delayed by 2 lines)
    output logic [DATA_WIDTH-1:0] o_win_10, o_win_11, o_win_12,  // middle row (delayed by 1 line)
    output logic [DATA_WIDTH-1:0] o_win_20, o_win_21, o_win_22   // bottom row (current line)
);

    typedef logic [$clog2(IMG_WIDTH)-1:0] t_width;
    typedef logic [$clog2(IMG_HEIGHT)-1:0] t_height;

    logic [DATA_WIDTH-1:0] buff1_output;
    logic [DATA_WIDTH-1:0] buff2_output;

    logic [15:0] pixel_count = '0;

    t_width x;
    t_height y;

    line_buffer u_line_buffer_1 (
        .i_clk      (i_clk),
        .i_n_rst    (i_n_rst),
        .i_shift_en (i_shift_en),
        .i_din      (i_pixel),
        .o_dout     (buff1_output)
    );

    line_buffer u_line_buffer_2 (
        .i_clk      (i_clk),
        .i_n_rst    (i_n_rst),
        .i_shift_en (i_shift_en),
        .i_din      (buff1_output),
        .o_dout     (buff2_output)
    );
    
    always_ff @(posedge i_clk or negedge i_n_rst) begin 
        if (!i_n_rst) begin 
            x <= '0; x[0] <= '1;
            y <= '0;
            o_window_vld <= '0;

            o_win_00 <= '0; o_win_01 <= '0; o_win_02 <= '0;
            o_win_10 <= '0; o_win_11 <= '0; o_win_12 <= '0;
            o_win_20 <= '0; o_win_21 <= '0; o_win_22 <= '0;

        end else if (i_shift_en) begin

            if (i_start_frame) begin 
                o_window_vld <= '0;

                o_win_00 <= '0; o_win_01 <= '0; o_win_02 <= '0;
                o_win_10 <= '0; o_win_11 <= '0; o_win_12 <= '0;
                o_win_20 <= '0; o_win_21 <= '0; o_win_22 <= '0;
            end else begin 
                o_win_00 <= o_win_01; o_win_01 <= o_win_02; o_win_02 <= buff2_output;
                o_win_10 <= o_win_11; o_win_11 <= o_win_12; o_win_12 <= buff1_output;
                o_win_20 <= o_win_21; o_win_21 <= o_win_22; o_win_22 <= i_pixel;

                if (i_start_frame) begin 
                    x <= '0; x[0] <= '1;
                    y <= '0;
                end else begin
                    if (x == IMG_WIDTH - 1) begin
                        x <= '0;
                        if (y == IMG_HEIGHT - 1) begin
                            y <= '0;
                        end else begin
                            y <= y + 1;
                        end
                    end else begin
                        x <= x + 1;
                    end
                end

                if (x >= 2 && y >= 2) begin 
                    o_window_vld <= 1'b1;
                end else begin 
                    o_window_vld <= 1'b0;
                end
            end 
        end
    end 
endmodule