import common_pkg::*;

module axi_stream_top (
    input  logic                  i_clk,
    input  logic                  i_n_reset,

    // Driven by AXI4-Lite registers updated by the MicroBlaze
    input  logic signed [WEIGHT_WIDTH-1:0] i_weight_00, i_weight_01, i_weight_02,
    input  logic signed [WEIGHT_WIDTH-1:0] i_weight_10, i_weight_11, i_weight_12,
    input  logic signed [WEIGHT_WIDTH-1:0] i_weight_20, i_weight_21, i_weight_22,

    // AXI4-Stream slave interface (input from VDMA / host)
    input  logic [DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready, // deasserted when module stalls
    input  logic                  s_axis_tlast,  // high on the last pixel of each line
    input  logic                  s_axis_tuser,  // high on the very first pixel of the frame (SOF)

    // AXI4-Stream master interface (output to VDMA / host)
    output logic [DATA_WIDTH-1:0] m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready, // downstream backpressure signal
    output logic                  m_axis_tlast,  // propagated/delayed tlast for processed output
    output logic                  m_axis_tuser   // propagated/delayed frame start (tuser)
);

    logic [DATA_WIDTH-1:0] win_00, win_01, win_02;
    logic [DATA_WIDTH-1:0] win_10, win_11, win_12;
    logic [DATA_WIDTH-1:0] win_20, win_21, win_22;
    logic [2:0] tlast_delay;
    logic [2:0] tuser_delay;
    logic window_valid;
    logic pipeline_en;

    assign pipeline_en   = s_axis_tvalid & m_axis_tready;
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tlast  = tlast_delay[2];
    assign m_axis_tuser  = tuser_delay[2];
    
    sliding_frame u_sliding_frame (
        .i_clk      (i_clk),
        .i_n_rst    (i_n_reset),
        .i_shift_en (s_axis_tvalid && pipeline_en),

        .i_pixel      (s_axis_tdata),
        .i_start_frame(s_axis_tuser),
        .o_window_vld (window_valid),
        .o_win_00 (win_00), .o_win_01 (win_01), .o_win_02 (win_02),
        .o_win_10 (win_10), .o_win_11 (win_11), .o_win_12 (win_12),
        .o_win_20 (win_20), .o_win_21 (win_21), .o_win_22 (win_22)
    );

    mac_3x3 u_mac_3x3 (
        .i_clk   (i_clk),
        .i_n_rst (i_n_reset),
        .i_en    (pipeline_en),
        .i_vld   (window_valid),

        .i_p00 (win_00), .i_p01 (win_01), .i_p02 (win_02),
        .i_p10 (win_10), .i_p11 (win_11), .i_p12 (win_12),
        .i_p20 (win_20), .i_p21 (win_21), .i_p22 (win_22),

        // weights are driven by AXI4-Lite registers updated by the MicroBlaze
        .i_weight_00(i_weight_00), .i_weight_01(i_weight_01), .i_weight_02(i_weight_02),
        .i_weight_10(i_weight_10), .i_weight_11(i_weight_11), .i_weight_12(i_weight_12),
        .i_weight_20(i_weight_20), .i_weight_21(i_weight_21), .i_weight_22(i_weight_22),

        .o_vld   (m_axis_tvalid),
        .o_pixel (m_axis_tdata)
    );

    // assign the delayed signals to the master AXI ports
    assign m_axis_tlast = tlast_delay[2];
    assign m_axis_tuser = tuser_delay[2];

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            tlast_delay <= '0;
            tuser_delay <= '0;
        end else if (pipeline_en) begin
            tlast_delay <= {tlast_delay[1:0], s_axis_tlast};
            tuser_delay <= {tuser_delay[1:0], s_axis_tuser};
        end
    end

endmodule