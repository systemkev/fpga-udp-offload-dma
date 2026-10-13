// Two-source AXIS8 packet arbiter. Source 0 has priority over source 1.
// Grant is retained until a TLAST transfer completes.
module axis_packet_arbiter (
    input  logic       i_clk,
    input  logic       i_n_reset,

    input  logic [7:0] s0_axis_tdata,
    input  logic       s0_axis_tvalid,
    output logic       s0_axis_tready,
    input  logic       s0_axis_tlast,

    input  logic [7:0] s1_axis_tdata,
    input  logic       s1_axis_tvalid,
    output logic       s1_axis_tready,
    input  logic       s1_axis_tlast,

    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    input  logic       m_axis_tready,
    output logic       m_axis_tlast
);

    typedef enum logic [1:0] {G_NONE, G_0, G_1} t_grant;
    t_grant grant;

    logic select0, select1;

    always_comb begin
        select0 = 1'b0;
        select1 = 1'b0;

        if (grant == G_0) select0 = 1'b1;
        else if (grant == G_1) select1 = 1'b1;
        else if (s0_axis_tvalid) select0 = 1'b1;
        else if (s1_axis_tvalid) select1 = 1'b1;

        m_axis_tdata  = select0 ? s0_axis_tdata  : s1_axis_tdata;
        m_axis_tvalid = select0 ? s0_axis_tvalid : (select1 ? s1_axis_tvalid : 1'b0);
        m_axis_tlast  = select0 ? s0_axis_tlast  : (select1 ? s1_axis_tlast : 1'b0);

        s0_axis_tready = select0 ? m_axis_tready : 1'b0;
        s1_axis_tready = select1 ? m_axis_tready : 1'b0;
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            grant <= G_NONE;
        end else begin
            case (grant)
                G_NONE: begin
                    if (s0_axis_tvalid) begin
                        if (m_axis_tready && s0_axis_tlast) grant <= G_NONE;
                        else                                grant <= G_0;
                    end else if (s1_axis_tvalid) begin
                        if (m_axis_tready && s1_axis_tlast) grant <= G_NONE;
                        else                                grant <= G_1;
                    end
                end

                G_0: begin
                    if (s0_axis_tvalid && s0_axis_tready && s0_axis_tlast)
                        grant <= G_NONE;
                end

                G_1: begin
                    if (s1_axis_tvalid && s1_axis_tready && s1_axis_tlast)
                        grant <= G_NONE;
                end

                default: grant <= G_NONE;
            endcase
        end
    end
endmodule
