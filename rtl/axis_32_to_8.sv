module axis_32_to_8 (
    input  logic        i_clk,
    input  logic        i_n_reset,

    input  logic [31:0] s_axis_tdata,
    input  logic [3:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast
);

    logic [31:0] word_reg;
    logic [3:0]  keep_reg;
    logic        last_reg;
    logic [1:0]  byte_index;
    logic        have_word;
    logic [1:0]  last_lane;

    always_comb begin
        casez (keep_reg)
            4'b1???: last_lane = 2'd3;
            4'b01??: last_lane = 2'd2;
            4'b001?: last_lane = 2'd1;
            default: last_lane = 2'd0;
        endcase

        s_axis_tready = !have_word;
        m_axis_tvalid = have_word && keep_reg[byte_index];
        m_axis_tdata  = word_reg[byte_index*8 +: 8];
        m_axis_tlast  = have_word && last_reg && (byte_index == last_lane);
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            word_reg   <= '0;
            keep_reg   <= '0;
            last_reg   <= 1'b0;
            byte_index <= '0;
            have_word  <= 1'b0;
        end else begin
            if (!have_word && s_axis_tvalid && s_axis_tready) begin
                word_reg   <= s_axis_tdata;
                keep_reg   <= s_axis_tkeep;
                last_reg   <= s_axis_tlast;
                byte_index <= 2'd0;
                have_word  <= 1'b1;
            end else if (m_axis_tvalid && m_axis_tready) begin
                if (byte_index == last_lane) begin
                    have_word  <= 1'b0;
                    byte_index <= 2'd0;
                end else begin
                    byte_index <= byte_index + 2'd1;
                end
            end
        end
    end
endmodule
