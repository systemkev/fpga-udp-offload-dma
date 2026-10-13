import common_pkg::*;

module udp_rx (
    input  logic i_clk,
    input  logic i_n_reset,

    // Reduced IPv4 metadata inputs: only fields UDP RX actually consumes.
    input  logic [47:0] i_src_mac,
    input  logic [31:0] i_src_ip,
    input  logic [15:0] i_ipv4_payload_len,
    input  logic        i_ipv4_meta_valid,
    output logic        o_ipv4_meta_ready,

    // AXIS8 UDP datagram input
    input  logic [7:0] s_axis_tdata,
    input  logic       s_axis_tvalid,
    input  logic       s_axis_tlast,
    output logic       s_axis_tready,

    // AXIS8 UDP payload output
    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    output logic       m_axis_tlast,
    input  logic       m_axis_tready,

    // Use the project's existing metadata type.  No new package typedef is required.
    output t_udp_metadata o_udp_meta,
    output logic          o_udp_meta_valid,
    input  logic          i_udp_meta_ready,

    input  logic [15:0] i_local_udp_port
);
    typedef enum logic [2:0] {
        UDP_IDLE,
        UDP_HEADER,
        UDP_METADATA,
        UDP_STREAM,
        UDP_DROP
    } t_udp_state;

    t_udp_state state;
    logic [2:0] header_ptr;

    logic [47:0] remote_mac_reg;
    logic [31:0] remote_ip_reg;
    logic [15:0] remote_port_reg;
    logic [15:0] ipv4_payload_len_reg;
    logic [7:0]  dst_port_hi_reg;
    logic [15:0] udp_length_reg;
    logic [15:0] payload_length_reg;
    logic        tlast_on_header;

    always_comb begin
        o_ipv4_meta_ready = (state == UDP_IDLE);

        s_axis_tready = 1'b0;
        if (state == UDP_HEADER || state == UDP_DROP)
            s_axis_tready = 1'b1;
        else if (state == UDP_STREAM)
            s_axis_tready = m_axis_tready;

        m_axis_tdata  = s_axis_tdata;
        m_axis_tvalid = (state == UDP_STREAM) && s_axis_tvalid;
        m_axis_tlast  = s_axis_tlast;

        // Fill the existing t_udp_metadata structure.  Only src_* and
        // payload_length are needed by the minimal echo path; the rest are
        // deterministic zeros rather than extra state/registers.
        o_udp_meta                = '0;
        o_udp_meta.src_mac        = remote_mac_reg;
        o_udp_meta.src_ip         = remote_ip_reg;
        o_udp_meta.src_port       = remote_port_reg;
        o_udp_meta.payload_length = payload_length_reg;
        o_udp_meta_valid          = (state == UDP_METADATA);
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            state                <= UDP_IDLE;
            header_ptr           <= '0;
            remote_mac_reg       <= '0;
            remote_ip_reg        <= '0;
            remote_port_reg      <= '0;
            ipv4_payload_len_reg <= '0;
            dst_port_hi_reg      <= '0;
            udp_length_reg       <= '0;
            payload_length_reg   <= '0;
            tlast_on_header      <= 1'b0;
        end else begin
            case (state)
                UDP_IDLE: begin
                    header_ptr      <= '0;
                    dst_port_hi_reg <= '0;
                    udp_length_reg  <= '0;
                    tlast_on_header <= 1'b0;

                    if (i_ipv4_meta_valid && o_ipv4_meta_ready) begin
                        remote_mac_reg       <= i_src_mac;
                        remote_ip_reg        <= i_src_ip;
                        ipv4_payload_len_reg <= i_ipv4_payload_len;
                        state                <= UDP_HEADER;
                    end
                end

                UDP_HEADER: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        case (header_ptr)
                            3'd0: remote_port_reg[15:8] <= s_axis_tdata;
                            3'd1: remote_port_reg[7:0]  <= s_axis_tdata;
                            3'd2: dst_port_hi_reg <= s_axis_tdata;

                            3'd3: begin
                                if ({dst_port_hi_reg, s_axis_tdata} != i_local_udp_port)
                                    state <= UDP_DROP;
                            end

                            3'd4: udp_length_reg[15:8] <= s_axis_tdata;

                            3'd5: begin
                                udp_length_reg[7:0] <= s_axis_tdata;
                                if ({udp_length_reg[15:8], s_axis_tdata} < 16'd8 ||
                                    {udp_length_reg[15:8], s_axis_tdata} != ipv4_payload_len_reg) begin
                                    state <= UDP_DROP;
                                end else begin
                                    payload_length_reg <=
                                        {udp_length_reg[15:8], s_axis_tdata} - 16'd8;
                                end
                            end

                            3'd6: begin end // checksum high byte ignored

                            3'd7: begin
                                // Earlier malformed-field checks may already have
                                // moved us to UDP_DROP.  Only publish metadata if
                                // this datagram is still valid.
                                if (state == UDP_HEADER)
                                    state <= UDP_METADATA;
                            end

                            default: begin end
                        endcase

                        if (s_axis_tlast) begin
                            if (header_ptr == 3'd7)
                                tlast_on_header <= 1'b1;
                            else
                                state <= UDP_IDLE;
                        end else begin
                            header_ptr <= header_ptr + 1'b1;
                        end
                    end
                end

                UDP_METADATA: begin
                    if (o_udp_meta_valid && i_udp_meta_ready) begin
                        if (tlast_on_header || payload_length_reg == 16'd0)
                            state <= UDP_IDLE;
                        else
                            state <= UDP_STREAM;
                    end
                end

                UDP_STREAM: begin
                    if (m_axis_tvalid && m_axis_tready && m_axis_tlast)
                        state <= UDP_IDLE;
                end

                UDP_DROP: begin
                    if (s_axis_tvalid && s_axis_tready && s_axis_tlast)
                        state <= UDP_IDLE;
                end

                default: state <= UDP_IDLE;
            endcase
        end
    end
endmodule
