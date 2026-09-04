import common_pkg::*;

module ipv4_rx (
    // System
    input  logic i_clk,
    input  logic i_n_reset,

    // AXIS8 IPv4 packet input from ethernet_dispatch
    input  logic [7:0] s_axis_tdata,
    input  logic       s_axis_tvalid,
    input  logic       s_axis_tlast,
    output logic       s_axis_tready,

    // Ethernet metadata carried with this packet
    input  logic [47:0] i_src_mac,
    input  logic [47:0] i_dst_mac,
    input  logic [10:0] i_frame_size,

    // AXIS8 IP payload output
    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    output logic       m_axis_tlast,
    input  logic       m_axis_tready,

    // IPv4 metadata output
    output t_ipv4_metadata o_ipv4_meta,
    output logic           o_ipv4_meta_valid,
    input  logic           i_ipv4_meta_ready,

    // Configuration
    input  logic [31:0] i_local_ip
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_HEADER,
        ST_META,
        ST_STREAM,
        ST_DROP
    } t_ipv4_rx_fsm; 

    t_ipv4_rx_fsm state;
    t_ipv4_metadata meta;

    logic [4:0] header_ptr; // used to track how many header bytes we've received
    logic [15:0] payload_ptr;

    always_comb begin
        case (state)
            ST_STREAM: 
                s_axis_tready = (m_axis_tready && !m_axis_tlast) || !m_axis_tvalid;

            ST_IDLE, ST_HEADER, ST_DROP: 
                s_axis_tready = 1'b1;

            ST_META:
                s_axis_tready = 1'b0;

            default: 
                s_axis_tready = 1'b0;
        endcase 
    end

    logic is_last_stream;
    logic is_last_meta;

    always_ff @(posedge i_clk or negedge i_n_reset) begin 
        if (!i_n_reset) begin 
            state             <= ST_IDLE;
            m_axis_tdata      <= '0;
            m_axis_tvalid     <= 1'b0;
            m_axis_tlast      <= 1'b0;
            o_ipv4_meta       <= '0;
            o_ipv4_meta_valid <= 1'b0;
            header_ptr        <= '0;
            payload_ptr       <= '0;
            meta              <= '0;
            is_last_meta      <= 1'b0;
            is_last_stream    <= 1'b0;
        end else begin 
            case (state)
                ST_IDLE : begin 
                    meta        <= '0;
                    header_ptr  <= '0;
                    payload_ptr <= '0;

                    is_last_meta      <= 1'b0;
                    is_last_stream    <= 1'b0;
                    o_ipv4_meta       <= '0;
                    o_ipv4_meta_valid <= 1'b0;

                    if (s_axis_tvalid && s_axis_tready) begin 
                        if (s_axis_tdata[7:4] == 4'd4 && s_axis_tdata[3:0] == 4'd5) begin 
                            state         <= ST_HEADER;
                            header_ptr    <= 5'd1;
                            m_axis_tlast  <= 1'b0;
                            m_axis_tvalid <= 1'b0;
                            
                            meta.src_mac <= i_src_mac;
                            meta.dst_mac <= i_dst_mac;
                            meta.version <= s_axis_tdata[7:4];
                            meta.ihl     <= s_axis_tdata[3:0];

                            if (s_axis_tlast) begin 
                                state    <= ST_IDLE;
                            end 
                        end else begin 
                            if (s_axis_tlast) begin 
                                state    <= ST_IDLE;
                            end else begin
                                state    <= ST_DROP;
                            end  
                        end 
                    end 
                end 

                ST_HEADER : begin 
                    if (s_axis_tvalid && s_axis_tready) begin 
                        header_ptr <= header_ptr + 1;

                        case (header_ptr)
                            5'd1 : begin 
                                // byte 1 ignored for now
                            end 

                            5'd2 : begin 
                                meta.total_len[15:8] <= s_axis_tdata;
                            end 

                            5'd3 : begin
                                meta.total_len[7:0] <= s_axis_tdata;

                                // i_frame_size is the complete Ethernet frame length
                                // excluding FCS and the 14-byte Ethernet header.
                                //
                                // Therefore: available IPv4 bytes = i_frame_size 
                                //
                                // IPv4 total_len may be LESS than the available bytes because
                                // Ethernet padding can exist after the IP packet.

                                if ({meta.total_len[15:8], s_axis_tdata} < {meta.ihl, 2'b0}) begin
                                    // IPv4 total length is smaller than its own header.
                                    state <= s_axis_tlast ? ST_IDLE : ST_DROP;

                                end else if (i_frame_size < 11'd14) begin
                                    // Defensive check: an Ethernet frame reaching here should
                                    // always contain at least the Ethernet header.
                                    state <= s_axis_tlast ? ST_IDLE : ST_DROP;

                                end else if ({meta.total_len[15:8], s_axis_tdata} > (i_frame_size)) begin
                                    // IPv4 header claims more bytes than actually exist
                                    // in the containing Ethernet frame.
                                    state <= s_axis_tlast ? ST_IDLE : ST_DROP;
                                end
                            end

                            // no checks, just metadata
                            5'd4 : begin 
                                meta.id_field[15:8] <= s_axis_tdata;
                            end 

                            // no checks, just metadata
                            5'd5 : begin 
                                meta.id_field[7:0] <= s_axis_tdata;
                            end 

                            5'd6 : begin 
                                // ensure MF (more fragments) is 0
                                // we currently dont support MF
                                if (s_axis_tdata[7] || s_axis_tdata[5]) begin 
                                    state <= ST_DROP;
                                end 

                                // start capture of fragment offset (should also be 0 for now)
                                meta.frag_offset[12:8] <= s_axis_tdata[4:0];
                            end 

                            5'd7 : begin 
                                // ensure fragment offset is 0
                                if ({meta.frag_offset[12:8], s_axis_tdata} != '0) begin 
                                    state <= ST_DROP;
                                end 

                                // start capture of fragment offset (should also be 0 for now)
                                meta.frag_offset[7:0] <= s_axis_tdata;
                            end 

                            5'd8 : begin 
                                meta.ttl <= s_axis_tdata;
                            end 

                            5'd9 : begin 
                                meta.protocol <= s_axis_tdata;
                            end 

                            5'd10 : begin 
                                // checksum (nothing for now)

                                // calculate payload length
                                meta.payload_len <= meta.total_len - {meta.ihl, 2'b0};
                            end 

                            5'd11 : begin 
                                // checksum (nothing for now)
                            end 

                            5'd12 : begin 
                                meta.src_ip[31:24] <= s_axis_tdata;
                            end 

                            5'd13 : begin 
                                meta.src_ip[23:16] <= s_axis_tdata;
                            end

                            5'd14 : begin 
                                meta.src_ip[15:8] <= s_axis_tdata;
                            end

                            5'd15 : begin 
                                meta.src_ip[7:0] <= s_axis_tdata;
                            end

                            5'd16 : begin 
                                meta.dst_ip[31:24] <= s_axis_tdata;
                            end

                            5'd17 : begin 
                                meta.dst_ip[23:16] <= s_axis_tdata;
                            end

                            5'd18 : begin 
                                meta.dst_ip[15:8] <= s_axis_tdata;
                            end

                            5'd19 : begin 
                                meta.dst_ip[7:0] <= s_axis_tdata;

                                // check that the destination IP matches our local IP
                                if ({meta.dst_ip[31:8], s_axis_tdata} != i_local_ip) begin  
                                    state <= (s_axis_tlast)? ST_IDLE : ST_DROP;
                                end else begin 
                                    // we have a valid packet, send out metadata
                                    state        <= ST_META;
                                    is_last_meta <= s_axis_tlast;
                                end 
                            end
                        endcase 

                        if (s_axis_tlast && header_ptr < 19) begin 
                            state <= ST_IDLE;
                        end 
                    end 
                end 

                ST_META : begin 
                    o_ipv4_meta       <= meta;
                    o_ipv4_meta_valid <= 1'b1;

                    if (o_ipv4_meta_valid && i_ipv4_meta_ready) begin
                        o_ipv4_meta_valid <= 1'b0;

                        if (is_last_meta) begin 
                            state <= ST_IDLE;
                        end else if (meta.payload_len == '0) begin 
                            state <= ST_DROP;
                        end else begin 
                            state <= ST_STREAM;
                        end 
                    end
                end 

                ST_STREAM : begin 
                    if (m_axis_tready && m_axis_tvalid && m_axis_tlast) begin 
                        m_axis_tvalid   <= 1'b0;
                        m_axis_tlast    <= 1'b0;

                        state <= (is_last_stream)? ST_IDLE : ST_DROP;
                    end else if (s_axis_tready) begin 
                        if (s_axis_tvalid) begin 
                            m_axis_tdata  <= s_axis_tdata;
                            m_axis_tvalid <= 1'b1;
                            m_axis_tlast  <= s_axis_tlast;
                            payload_ptr   <= payload_ptr + 1;

                            if (payload_ptr == meta.payload_len - 1) begin 
                                m_axis_tlast <= 1'b1;
                            end 

                            if (s_axis_tlast) begin 
                                is_last_stream <= 1'b1;
                            end 
                        end else begin 
                            m_axis_tvalid <= 1'b0;
                        end 
                    end
                end 

                ST_DROP : begin 
                    m_axis_tvalid <= 1'b0;

                    if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin 
                        state <= ST_IDLE;
                    end 
                end 
            endcase 
        end 
    end 
endmodule 