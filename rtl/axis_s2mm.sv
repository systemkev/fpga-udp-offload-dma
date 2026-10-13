// Minimal, correctness-first AXIS32 -> AXI4 S2MM engine.
// Uses one AXI beat per burst (AWLEN=0). This is intentionally slower than the
// roadmap's burst DMA, but is enough for a functional echo design because the
// RX frame is already buffered and can be backpressured in the system clock domain.
module axis_s2mm (
    input  logic        i_clk,
    input  logic        i_n_reset,

    input  logic        i_start,
    input  logic [31:0] i_base_addr,

    input  logic [31:0] s_axis_tdata,
    input  logic [3:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    output logic        o_busy,
    output logic        o_done,
    output logic [15:0] o_actual_length,
    output logic        o_error,

    output logic [31:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,

    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,

    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_WAIT_AXIS,
        ST_SEND_AW,
        ST_SEND_W,
        ST_WAIT_B
    } t_state;

    t_state state;

    logic [31:0] curr_addr;
    logic [31:0] data_reg;
    logic [3:0]  keep_reg;
    logic        last_reg;

    function automatic logic [2:0] keep_count(input logic [3:0] keep);
        keep_count = keep[0] + keep[1] + keep[2] + keep[3];
    endfunction

    always_comb begin
        s_axis_tready = (state == ST_WAIT_AXIS);

        m_axi_awaddr  = curr_addr;
        m_axi_awlen   = 8'd0;
        m_axi_awsize  = 3'b010; // 4 bytes
        m_axi_awburst = 2'b01;  // INCR
        m_axi_awvalid = (state == ST_SEND_AW);

        m_axi_wdata   = data_reg;
        m_axi_wstrb   = keep_reg;
        m_axi_wlast   = 1'b1;
        m_axi_wvalid  = (state == ST_SEND_W);

        m_axi_bready  = (state == ST_WAIT_B);
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            state           <= ST_IDLE;
            curr_addr       <= '0;
            data_reg        <= '0;
            keep_reg        <= '0;
            last_reg        <= 1'b0;
            o_busy          <= 1'b0;
            o_done          <= 1'b0;
            o_actual_length <= '0;
            o_error         <= 1'b0;
        end else begin
            o_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    o_busy  <= 1'b0;
                    o_error <= 1'b0;
                    if (i_start) begin
                        curr_addr       <= i_base_addr;
                        o_actual_length <= 16'd0;
                        o_busy          <= 1'b1;
                        state           <= ST_WAIT_AXIS;
                    end
                end

                ST_WAIT_AXIS: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        data_reg        <= s_axis_tdata;
                        keep_reg        <= s_axis_tkeep;
                        last_reg        <= s_axis_tlast;
                        o_actual_length <= o_actual_length + keep_count(s_axis_tkeep);
                        state           <= ST_SEND_AW;
                    end
                end

                ST_SEND_AW: begin
                    if (m_axi_awvalid && m_axi_awready)
                        state <= ST_SEND_W;
                end

                ST_SEND_W: begin
                    if (m_axi_wvalid && m_axi_wready)
                        state <= ST_WAIT_B;
                end

                ST_WAIT_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        if (m_axi_bresp != 2'b00) begin
                            o_error <= 1'b1;
                            o_busy  <= 1'b0;
                            o_done  <= 1'b1;
                            state   <= ST_IDLE;
                        end else if (last_reg) begin
                            o_busy <= 1'b0;
                            o_done <= 1'b1;
                            state  <= ST_IDLE;
                        end else begin
                            curr_addr <= curr_addr + 32'd4;
                            state     <= ST_WAIT_AXIS;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
