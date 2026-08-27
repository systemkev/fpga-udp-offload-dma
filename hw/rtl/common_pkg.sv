// ============================================================================
// File Name   : 
// Author      : Kevin Toledo Fernandez / GitHub: systemkev
// Date        : 
// Project     : Ethernet-Based AXI4-Stream Image Processing Pipeline
// Description : 
//
// License     : MIT
// ============================================================================

package common_pkg;
    
    parameter int DATA_WIDTH    = 8;
    parameter int IMG_WIDTH     = 9;
    parameter int IMG_HEIGHT    = 9; 
    parameter int VLD_THRESHOLD = (2 * IMG_WIDTH) + 3;
    parameter int WEIGHT_WIDTH  = 8;

    parameter int AXI_DATA_WIDTH = 32;
    parameter int AXI_ADDR_WIDTH = 8;

    // =========================================================
    // AXI4-Lite Register Map Offsets
    // =========================================================
    parameter logic [7:0] ADDR_CTRL      = 8'h00;  // slv_reg0 (Bit 0: En, Bit 1: Reset)
    parameter logic [7:0] ADDR_STATUS    = 8'h04;  // slv_reg1 
    parameter logic [7:0] ADDR_IMG_W     = 8'h08;  // slv_reg2
    parameter logic [7:0] ADDR_IMG_H     = 8'h0C;  // slv_reg3
    parameter logic [7:0] ADDR_RESERVED  = 8'h10;  // slv_reg4

    // Convolution Weights
    parameter logic [7:0] ADDR_WEIGHT_00 = 8'h14;  // slv_reg5
    parameter logic [7:0] ADDR_WEIGHT_01 = 8'h18;  // slv_reg6
    parameter logic [7:0] ADDR_WEIGHT_02 = 8'h1C;  // slv_reg7
    parameter logic [7:0] ADDR_WEIGHT_10 = 8'h20;  // slv_reg8
    parameter logic [7:0] ADDR_WEIGHT_11 = 8'h24;  // slv_reg9
    parameter logic [7:0] ADDR_WEIGHT_12 = 8'h28;  // slv_reg10
    parameter logic [7:0] ADDR_WEIGHT_20 = 8'h2C;  // slv_reg11
    parameter logic [7:0] ADDR_WEIGHT_21 = 8'h30;  // slv_reg12
    parameter logic [7:0] ADDR_WEIGHT_22 = 8'h34;  // slv_reg13

endpackage