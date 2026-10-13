import common_pkg::*;

module ip_dispatch (
    // System
    input  logic i_clk,
    input  logic i_n_reset,

    // IPv4 metadata input from ipv4_rx
    input  t_ipv4_metadata i_ipv4_meta,
    input  logic           i_ipv4_meta_valid,
    output logic           o_ipv4_meta_ready,

    // AXIS8 IPv4 payload input from ipv4_rx
    input  logic [7:0] s_axis_tdata,
    input  logic       s_axis_tvalid,
    input  logic       s_axis_tlast,
    output logic       s_axis_tready,

    // IPv4 metadata output to udp_rx
    output t_ipv4_metadata o_udp_ipv4_meta,
    output logic           o_udp_ipv4_meta_valid,
    input  logic           i_udp_ipv4_meta_ready,

    // AXIS8 UDP packet input to udp_rx
    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    output logic       m_axis_tlast,
    input  logic       m_axis_tready
);

    localparam logic [7:0] IPV4_PROTOCOL_UDP = 8'd17;

    typedef enum logic [1:0] {
        DISP_IDLE,
        DISP_META,
        DISP_STREAM,
        DISP_DROP
    } t_ip_dispatch_fsm;

    t_ip_dispatch_fsm state;

    t_ipv4_metadata meta_reg;

    always_comb begin
        o_ipv4_meta_ready     = 1'b0;

        o_udp_ipv4_meta       = meta_reg;
        o_udp_ipv4_meta_valid = 1'b0;

        s_axis_tready         = 1'b0;

        m_axis_tdata          = s_axis_tdata;
        m_axis_tvalid         = 1'b0;
        m_axis_tlast          = 1'b0;

        case (state)

            // Metadata always arrives before the payload from ipv4_rx
            DISP_IDLE : begin
                o_ipv4_meta_ready = 1'b1;
            end

            // for UDP, publish the IPv4 metadata before allowing any
            // transport bytes to move downstream
            DISP_META : begin
                o_udp_ipv4_meta_valid = 1'b1;
            end

            DISP_STREAM : begin
                s_axis_tready = m_axis_tready;
                m_axis_tdata  = s_axis_tdata;
                m_axis_tvalid = s_axis_tvalid;
                m_axis_tlast  = s_axis_tlast;
            end

            // Unsupported IPv4 protocols are consumed completely,
            // independent of downstream readiness.
            DISP_DROP : begin
                s_axis_tready = 1'b1;
            end

            default : begin
                o_ipv4_meta_ready = 1'b0;
                s_axis_tready     = 1'b0;
            end

        endcase
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            
            state    <= DISP_IDLE;
            meta_reg <= '0;

        end else begin

            case (state)
            
                DISP_IDLE : begin
                    if (i_ipv4_meta_valid && o_ipv4_meta_ready) begin
                        meta_reg <= i_ipv4_meta;

                        if (i_ipv4_meta.protocol == IPV4_PROTOCOL_UDP) begin
                            // UDP metadata must be accepted before
                            // transport payload is allowed through.
                            state <= DISP_META;

                        end else if (i_ipv4_meta.payload_len == 16'd0) begin
                            // Unsupported protocol with no payload:
                            // there is nothing left to drain.
                            state <= DISP_IDLE;

                        end else begin
                            state <= DISP_DROP;
                        end
                    end
                end


                DISP_META : begin
                    if (o_udp_ipv4_meta_valid && i_udp_ipv4_meta_ready) begin
                        if (meta_reg.payload_len == 16'd0) begin
                            // Valid zero-byte IPv4 payload. Metadata is
                            // forwarded, but there is no AXIS packet.
                            state <= DISP_IDLE;
                        end else begin
                            state <= DISP_STREAM;
                        end
                    end
                end


                DISP_STREAM : begin
                    if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
                        state <= DISP_IDLE;
                    end
                end


                DISP_DROP : begin
                    if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
                        state <= DISP_IDLE;
                    end
                end


                default : begin
                    state <= DISP_IDLE;
                end

            endcase
        end
    end

endmodule