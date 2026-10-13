module udp_ipv4_tx #(
    parameter logic [47:0] LOCAL_MAC      = 48'h02_00_00_00_00_01,
    parameter logic [31:0] LOCAL_IP       = 32'hC0A8_0132,
    parameter logic [15:0] LOCAL_UDP_PORT = 16'd4000
) (
    input  logic        i_clk,
    input  logic        i_n_reset,

    // Plain-signal echo metadata; no package typedef dependency.
    input  logic [47:0] i_remote_mac,
    input  logic [31:0] i_remote_ip,
    input  logic [15:0] i_remote_port,
    input  logic [15:0] i_payload_length,
    input  logic        i_meta_valid,
    output logic        o_meta_ready,

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
    typedef enum logic [1:0] {ST_IDLE, ST_HEADER, ST_PAYLOAD} t_state;
    t_state state;

    logic [47:0] remote_mac_reg;
    logic [31:0] remote_ip_reg;
    logic [15:0] remote_port_reg;
    logic [15:0] payload_length_reg;

    logic [15:0] ip_id;
    logic [5:0]  header_index;
    logic [15:0] ip_total_len;
    logic [15:0] udp_total_len;
    logic [15:0] ip_checksum_value;

    logic [7:0] payload8_data;
    logic       payload8_valid;
    logic       payload8_ready;
    logic       payload8_last;
    logic       conv_s_ready;

    assign ip_total_len  = 16'd28 + payload_length_reg;
    assign udp_total_len = 16'd8  + payload_length_reg;

    ipv4_checksum u_ipv4_checksum (
        .i_total_length   (ip_total_len),
        .i_identification (ip_id),
        .i_ttl            (8'd64),
        .i_protocol       (8'd17),
        .i_src_ip         (LOCAL_IP),
        .i_dst_ip         (remote_ip_reg),
        .o_checksum       (ip_checksum_value)
    );

    axis_32_to_8 u_axis_32_to_8 (
        .i_clk          (i_clk),
        .i_n_reset      (i_n_reset),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tkeep   (s_axis_tkeep),
        .s_axis_tvalid  (s_axis_tvalid && (state == ST_PAYLOAD)),
        .s_axis_tready  (conv_s_ready),
        .s_axis_tlast   (s_axis_tlast),
        .m_axis_tdata   (payload8_data),
        .m_axis_tvalid  (payload8_valid),
        .m_axis_tready  (payload8_ready),
        .m_axis_tlast   (payload8_last)
    );

    assign s_axis_tready = (state == ST_PAYLOAD) && conv_s_ready;

    function automatic logic [7:0] header_byte(input logic [5:0] idx);
        begin
            case (idx)
                6'd0:  header_byte = remote_mac_reg[47:40];
                6'd1:  header_byte = remote_mac_reg[39:32];
                6'd2:  header_byte = remote_mac_reg[31:24];
                6'd3:  header_byte = remote_mac_reg[23:16];
                6'd4:  header_byte = remote_mac_reg[15:8];
                6'd5:  header_byte = remote_mac_reg[7:0];
                6'd6:  header_byte = LOCAL_MAC[47:40];
                6'd7:  header_byte = LOCAL_MAC[39:32];
                6'd8:  header_byte = LOCAL_MAC[31:24];
                6'd9:  header_byte = LOCAL_MAC[23:16];
                6'd10: header_byte = LOCAL_MAC[15:8];
                6'd11: header_byte = LOCAL_MAC[7:0];
                6'd12: header_byte = 8'h08;
                6'd13: header_byte = 8'h00;

                6'd14: header_byte = 8'h45;
                6'd15: header_byte = 8'h00;
                6'd16: header_byte = ip_total_len[15:8];
                6'd17: header_byte = ip_total_len[7:0];
                6'd18: header_byte = ip_id[15:8];
                6'd19: header_byte = ip_id[7:0];
                6'd20: header_byte = 8'h00;
                6'd21: header_byte = 8'h00;
                6'd22: header_byte = 8'd64;
                6'd23: header_byte = 8'd17;
                6'd24: header_byte = ip_checksum_value[15:8];
                6'd25: header_byte = ip_checksum_value[7:0];
                6'd26: header_byte = LOCAL_IP[31:24];
                6'd27: header_byte = LOCAL_IP[23:16];
                6'd28: header_byte = LOCAL_IP[15:8];
                6'd29: header_byte = LOCAL_IP[7:0];
                6'd30: header_byte = remote_ip_reg[31:24];
                6'd31: header_byte = remote_ip_reg[23:16];
                6'd32: header_byte = remote_ip_reg[15:8];
                6'd33: header_byte = remote_ip_reg[7:0];

                6'd34: header_byte = LOCAL_UDP_PORT[15:8];
                6'd35: header_byte = LOCAL_UDP_PORT[7:0];
                6'd36: header_byte = remote_port_reg[15:8];
                6'd37: header_byte = remote_port_reg[7:0];
                6'd38: header_byte = udp_total_len[15:8];
                6'd39: header_byte = udp_total_len[7:0];
                6'd40: header_byte = 8'h00; // UDP checksum disabled for IPv4
                6'd41: header_byte = 8'h00;
                default: header_byte = 8'h00;
            endcase
        end
    endfunction

    always_comb begin
        o_meta_ready   = (state == ST_IDLE);
        payload8_ready = 1'b0;
        m_axis_tdata   = 8'h00;
        m_axis_tvalid  = 1'b0;
        m_axis_tlast   = 1'b0;

        if (state == ST_HEADER) begin
            m_axis_tdata  = header_byte(header_index);
            m_axis_tvalid = 1'b1;
            m_axis_tlast  = (header_index == 6'd41) &&
                            (payload_length_reg == 16'd0);
        end else if (state == ST_PAYLOAD) begin
            m_axis_tdata   = payload8_data;
            m_axis_tvalid  = payload8_valid;
            m_axis_tlast   = payload8_last;
            payload8_ready = m_axis_tready;
        end
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            state              <= ST_IDLE;
            remote_mac_reg     <= '0;
            remote_ip_reg      <= '0;
            remote_port_reg    <= '0;
            payload_length_reg <= '0;
            header_index       <= '0;
            ip_id              <= 16'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    header_index <= 6'd0;
                    if (i_meta_valid && o_meta_ready) begin
                        remote_mac_reg     <= i_remote_mac;
                        remote_ip_reg      <= i_remote_ip;
                        remote_port_reg    <= i_remote_port;
                        payload_length_reg <= i_payload_length;
                        ip_id              <= ip_id + 16'd1;
                        state              <= ST_HEADER;
                    end
                end

                ST_HEADER: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (header_index == 6'd41) begin
                            header_index <= 6'd0;
                            if (payload_length_reg == 16'd0)
                                state <= ST_IDLE;
                            else
                                state <= ST_PAYLOAD;
                        end else begin
                            header_index <= header_index + 6'd1;
                        end
                    end
                end

                ST_PAYLOAD: begin
                    if (m_axis_tvalid && m_axis_tready && m_axis_tlast)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
