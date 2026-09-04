import common_pkg::*;

module udp_rx (
    // System
    input  logic i_clk,
    input  logic i_n_reset,

    // IPv4 metadata input from ip_dispatch
    input  t_ipv4_metadata i_ipv4_meta,
    input  logic           i_ipv4_meta_valid,
    output logic           o_ipv4_meta_ready,

    // AXIS8 UDP datagram input from ip_dispatch
    input  logic [7:0] s_axis_tdata,
    input  logic       s_axis_tvalid,
    input  logic       s_axis_tlast,
    output logic       s_axis_tready,

    // AXIS8 UDP payload output
    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    output logic       m_axis_tlast,
    input  logic       m_axis_tready,

    // UDP metadata output
    output t_udp_metadata o_udp_meta,
    output logic          o_udp_meta_valid,
    input  logic          i_udp_meta_ready,

    // Configuration
    input  logic [15:0]   i_local_udp_port
);

    typedef enum logic [2:0] {
        UDP_IDLE,
        UDP_HEADER,
        UDP_METADATA,
        UDP_STREAM,
        UDP_DROP
    } t_udp_states;

    t_udp_states state;
    t_ipv4_metadata ipv4_meta;  
    t_udp_metadata udp_meta;

    logic [2:0] header_ptr;

    always_comb begin 
        case (state) 
            UDP_IDLE : begin 
                o_ipv4_meta_ready = 1'b1;
                s_axis_tready     = 1'b0;
            end 

            UDP_HEADER : begin 
                o_ipv4_meta_ready = 1'b0;
                s_axis_tready     = 1'b1;
            end 

            UDP_METADATA : begin 
                o_ipv4_meta_ready = 1'b0;
                s_axis_tready     = 1'b0;
            end 

            UDP_STREAM : begin 
                o_ipv4_meta_ready = 1'b0;
                s_axis_tready     = ((m_axis_tready && !m_axis_tlast) || !m_axis_tvalid);
            end 

            UDP_DROP : begin 
                o_ipv4_meta_ready = 1'b0;
                s_axis_tready     = 1'b1;
            end 

            default : begin 
                o_ipv4_meta_ready = 1'b0;
                s_axis_tready     = 1'b0;
            end 
        endcase 
    end 

    logic tlast_on_header;
    logic [15:0] checksum;
    logic [15:0] udp_length;

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            ipv4_meta  <= '0;
            header_ptr <= '0;
            udp_meta   <= '0;
            state      <= UDP_IDLE;

            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;

            o_udp_meta_valid <= 1'b0;
            tlast_on_header  <= 1'b0;
        end else begin
            case (state)
                UDP_IDLE : begin 
                    ipv4_meta   <= '0;
                    header_ptr  <= '0;
                    udp_meta    <= '0;
                    
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    
                    o_udp_meta_valid <= 1'b0;
                    tlast_on_header  <= 1'b0;

                    if (o_ipv4_meta_ready && i_ipv4_meta_valid) begin 
                        ipv4_meta <= i_ipv4_meta;
                        state     <= UDP_HEADER;
                    end 
                end 

                UDP_HEADER : begin 
                    if (s_axis_tvalid && s_axis_tready) begin 
                        header_ptr <= header_ptr + 1;

                        case (header_ptr)

                            3'd0 : begin 
                                udp_meta.src_port[15:8] <= s_axis_tdata;

                                udp_meta.src_mac <= ipv4_meta.src_mac;
                                udp_meta.dst_mac <= ipv4_meta.dst_mac;
                                udp_meta.src_ip  <= ipv4_meta.src_ip;
                                udp_meta.dst_ip  <= ipv4_meta.dst_ip;
                            end 

                            3'd1 : begin 
                                udp_meta.src_port[7:0]  <= s_axis_tdata;
                            end 

                            3'd2 : begin 
                                udp_meta.dst_port[15:8] <= s_axis_tdata;
                            end 

                            3'd3 : begin 
                                udp_meta.dst_port[7:0]  <= s_axis_tdata;

                                if (i_local_udp_port != {udp_meta.dst_port[15:8], s_axis_tdata}) begin 
                                    state <= UDP_DROP;
                                end 
                            end 

                            3'd4 : begin 
                                // we're storing the total length in this field for now
                                // we will need to subtract 8 later since 
                                // payload length = total length - header length (8)
                                udp_length[15:8] <= s_axis_tdata;
                            end 

                            3'd5 : begin 
                                udp_length[7:0] <= s_axis_tdata;

                                if ({udp_length[15:8], s_axis_tdata} < 8 || 
                                    {udp_length[15:8], s_axis_tdata} != ipv4_meta.payload_len) 
                                begin
                                    state <= UDP_DROP;
                                end 

                                udp_meta.payload_length <= {udp_length[15:8], s_axis_tdata} - UDP_HEAD_NUM_BYTES;
                            end 

                            3'd6 : begin 
                                checksum[15:8] <= s_axis_tdata;
                            end 

                            3'd7 : begin 
                                checksum[7:0]  <= s_axis_tdata;
                                
                                state <= UDP_METADATA;
                            end 
                        endcase 

                        if (s_axis_tlast) begin 
                            if (header_ptr == 3'd7) begin 
                                tlast_on_header <= 1'b1;
                            end else begin 
                                state <= UDP_IDLE;
                            end 
                        end 
                    end 
                end 

                UDP_METADATA : begin
                    o_udp_meta       <= udp_meta;
                    o_udp_meta_valid <= 1'b1;

                    if (o_udp_meta_valid && i_udp_meta_ready) begin 
                        o_udp_meta_valid <= 1'b0;
                        
                        state <= (tlast_on_header)? UDP_IDLE : UDP_STREAM;
                    end 
                end 

                UDP_STREAM : begin 
                    if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin 
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast  <= 1'b0;
                        state         <= UDP_IDLE;
                    end else if (s_axis_tready) begin 
                        if (s_axis_tvalid) begin 
                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata  <= s_axis_tdata;
                            m_axis_tlast  <= s_axis_tlast;
                        end else begin 
                            m_axis_tvalid <= 1'b0;
                        end 
                    end 
                end 

                UDP_DROP : begin 
                    if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin 
                        state <= UDP_IDLE;
                    end 
                end 
            endcase 
        end 
    end 

endmodule 