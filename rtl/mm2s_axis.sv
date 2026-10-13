// Minimal AXI4 MM2S reader. One AXI beat per burst (ARLEN=0).
// Completion means the final AXIS beat was accepted by the downstream consumer.
module mm2s_axis (
    input  logic        i_clk,
    input  logic        i_n_reset,

    input  logic        i_start,
    input  logic [31:0] i_base_addr,
    input  logic [15:0] i_byte_length,

    output logic        o_busy,
    output logic        o_done,
    output logic        o_error,

    output logic [31:0] m_axis_tdata,
    output logic [3:0]  m_axis_tkeep,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    output logic [31:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,

    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_SEND_AR,
        ST_WAIT_R,
        ST_OUT
    } t_state;

    t_state state;
    logic [31:0] curr_addr;
    logic [15:0] bytes_left;

    function automatic logic [3:0] keep_for_count(input logic [15:0] count);
        if (count >= 16'd4)      keep_for_count = 4'b1111;
        else if (count == 16'd3) keep_for_count = 4'b0111;
        else if (count == 16'd2) keep_for_count = 4'b0011;
        else if (count == 16'd1) keep_for_count = 4'b0001;
        else                     keep_for_count = 4'b0000;
    endfunction

    always_comb begin
        m_axi_araddr  = curr_addr;
        m_axi_arlen   = 8'd0;
        m_axi_arsize  = 3'b010;
        m_axi_arburst = 2'b01;
        m_axi_arvalid = (state == ST_SEND_AR);
        m_axi_rready  = (state == ST_WAIT_R);
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            state         <= ST_IDLE;
            curr_addr     <= '0;
            bytes_left    <= '0;
            o_busy        <= 1'b0;
            o_done        <= 1'b0;
            o_error       <= 1'b0;
            m_axis_tdata  <= '0;
            m_axis_tkeep  <= '0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else begin
            o_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    o_busy        <= 1'b0;
                    o_error       <= 1'b0;
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    if (i_start) begin
                        curr_addr  <= i_base_addr;
                        bytes_left <= i_byte_length;
                        if (i_byte_length == 16'd0) begin
                            o_done <= 1'b1;
                        end else begin
                            o_busy <= 1'b1;
                            state  <= ST_SEND_AR;
                        end
                    end
                end

                ST_SEND_AR: begin
                    if (m_axi_arvalid && m_axi_arready)
                        state <= ST_WAIT_R;
                end

                ST_WAIT_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (m_axi_rresp != 2'b00 || !m_axi_rlast) begin
                            o_error <= 1'b1;
                            o_busy  <= 1'b0;
                            o_done  <= 1'b1;
                            state   <= ST_IDLE;
                        end else begin
                            m_axis_tdata  <= m_axi_rdata;
                            m_axis_tkeep  <= keep_for_count(bytes_left);
                            m_axis_tlast  <= (bytes_left <= 16'd4);
                            m_axis_tvalid <= 1'b1;
                            state         <= ST_OUT;
                        end
                    end
                end

                ST_OUT: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        m_axis_tvalid <= 1'b0;
                        if (m_axis_tlast) begin
                            m_axis_tlast <= 1'b0;
                            o_busy       <= 1'b0;
                            o_done       <= 1'b1;
                            state        <= ST_IDLE;
                        end else begin
                            curr_addr  <= curr_addr + 32'd4;
                            bytes_left <= bytes_left - 16'd4;
                            state      <= ST_SEND_AR;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
