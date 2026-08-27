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

module mac_3x3 (
    input  logic                  i_clk,
    input  logic                  i_n_rst, 
    input  logic                  i_en,
    input  logic                  i_vld,    // passed from window_valid

    // 9 neighborhood inputs from the sliding window
    input  logic [DATA_WIDTH-1:0] i_p00, i_p01, i_p02,
    input  logic [DATA_WIDTH-1:0] i_p10, i_p11, i_p12,
    input  logic [DATA_WIDTH-1:0] i_p20, i_p21, i_p22,

    // Driven by AXI4-Lite registers updated by the MicroBlaze
    input  logic signed [WEIGHT_WIDTH-1:0] i_weight_00, i_weight_01, i_weight_02,
    input  logic signed [WEIGHT_WIDTH-1:0] i_weight_10, i_weight_11, i_weight_12,
    input  logic signed [WEIGHT_WIDTH-1:0] i_weight_20, i_weight_21, i_weight_22,

    output logic                  o_vld,    // high when computed pixel is ready
    output logic [DATA_WIDTH-1:0] o_pixel   // final filtered/clamped 8-bit pixel
);

    logic mult_vld  = '0;
    logic add_vld   = '0;
    logic clamp_vld = '0;

    logic signed [DATA_WIDTH + WEIGHT_WIDTH : 0] mult [0:8];
    logic signed [DATA_WIDTH + WEIGHT_WIDTH + 4 : 0] sum;
    logic signed [DATA_WIDTH + WEIGHT_WIDTH + 4 : 0] shifted_sum;
    
    assign shifted_sum = sum >>> 4;

    always_ff @(posedge i_clk or negedge i_n_rst) begin 
        if (!i_n_rst) begin 
            mult_vld  <= '0;
            add_vld   <= '0;
            clamp_vld <= '0;
            o_vld     <= '0;
        end else if (i_en) begin
            // Pipeline advance 
            mult_vld  <= i_vld; 
            add_vld   <= mult_vld;
            o_vld     <= add_vld;

            // Multiplication phase
            mult[0] <= $signed({1'b0, i_p00}) * i_weight_00;
            mult[1] <= $signed({1'b0, i_p01}) * i_weight_01;
            mult[2] <= $signed({1'b0, i_p02}) * i_weight_02;
            mult[3] <= $signed({1'b0, i_p10}) * i_weight_10;
            mult[4] <= $signed({1'b0, i_p11}) * i_weight_11;
            mult[5] <= $signed({1'b0, i_p12}) * i_weight_12;
            mult[6] <= $signed({1'b0, i_p20}) * i_weight_20;
            mult[7] <= $signed({1'b0, i_p21}) * i_weight_21;
            mult[8] <= $signed({1'b0, i_p22}) * i_weight_22;

            // Addition phase
            sum <= mult[0] + mult[1] + mult[2] + mult[3] + mult[4] + mult[5] + mult[6] + mult[7] + mult[8];

            // Clamp phase
            if (shifted_sum > 255) begin 
                o_pixel <= '1;
            end else if (shifted_sum < 0) begin 
                o_pixel <= '0;
            end else begin 
                o_pixel <= shifted_sum[DATA_WIDTH-1:0];
            end 
        end else begin 
            o_vld <= '0;
        end 
    end 
endmodule 