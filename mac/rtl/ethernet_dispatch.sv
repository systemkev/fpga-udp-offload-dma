import common_pkg::*;

module ethernet_dispatch (
    // System
    input  logic       i_clk,
    input  logic       i_n_reset,

    // AXIS input from rx_frame_buffer
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,

    // payload output
    input  logic        m_axis_tready,
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,

    // metadata/classification
    input  logic              i_meta_ready,
    output logic              o_meta_valid,
    output logic [47:0]       o_dst_mac,
    output logic [47:0]       o_src_mac,
    output t_ethernet_types   o_ethertype
);

    logic [13:0][7:0] mac_reg;
    logic [3:0] ptr;

    typedef enum logic [2:0] { 
        DISP_IDLE,
        DISP_MAC_REG,
        DISP_OUTPUT,
        DISP_STREAM,
        DISP_DROP
    } t_dispatch_fsm;

    t_dispatch_fsm disp_state;

    // in the stream phase, we are ready to accept new data if 
    //      1. m_axis_tvalid is currently 0 (we are not driving anything, no valid output)
    //      2. this cycle, an output byte is being consumed (m_axis_tready && m_axis_tvalid)
    always_comb begin 
        case (disp_state)
            DISP_STREAM: 
                s_axis_tready = (m_axis_tready || !m_axis_tvalid);

            DISP_IDLE, DISP_MAC_REG, DISP_DROP: 
                s_axis_tready = 1'b1;

            DISP_OUTPUT: 
                s_axis_tready = 1'b0;

            default:
                s_axis_tready = 1'b0;
        endcase 
    end 

    always_ff @(posedge i_clk or negedge i_n_reset) begin 
        if (!i_n_reset) begin 
            disp_state     <= DISP_IDLE;
            ptr            <= '0;
            m_axis_tvalid  <= 1'b0;
            m_axis_tlast   <= 1'b0;
            m_axis_tdata   <= '0;
            o_dst_mac      <= '0;
            o_src_mac      <= '0;
            o_meta_valid   <= 1'b0;
            o_ethertype    <= ETH_INVALID;
        end else begin 
            case (disp_state)
                DISP_IDLE : begin 
                    ptr <= '0;
                    m_axis_tlast  <= 1'b0;
                    m_axis_tvalid <= 1'b0;
                    o_meta_valid  <= 1'b0;

                    if (s_axis_tvalid && s_axis_tready) begin 
                        mac_reg[0] <= s_axis_tdata;

                        if (s_axis_tlast) begin
                            disp_state <= DISP_IDLE;
                            ptr        <= '0;
                        end else begin
                            disp_state <= DISP_MAC_REG;
                            ptr        <= 4'd1;
                        end
                    end 
                end 

                DISP_MAC_REG : begin 
                    if (s_axis_tvalid && s_axis_tready) begin 
                        ptr <= ptr + 1;
                        mac_reg[ptr] <= s_axis_tdata;

                        if (s_axis_tlast) begin 
                            disp_state <= DISP_IDLE;
                        end else if (ptr == 4'd13) begin 
                            disp_state <= DISP_OUTPUT;
                        end 
                    end 
                end 

                DISP_OUTPUT : begin 
                    if ({mac_reg[12], mac_reg[13]} == IPV4_ETHERTYPE) begin 
                        o_meta_valid     <= 1'b1;
                        o_dst_mac        <= {mac_reg[0], mac_reg[1], mac_reg[2], mac_reg[3], mac_reg[4], mac_reg[5]};
                        o_src_mac        <= {mac_reg[6], mac_reg[7], mac_reg[8], mac_reg[9], mac_reg[10], mac_reg[11]};
                        o_ethertype      <= ETH_IPV4;
                    end else if ({mac_reg[12], mac_reg[13]} == ARP_ETHERTYPE) begin 
                        o_meta_valid     <= 1'b1;
                        o_dst_mac        <= {mac_reg[0], mac_reg[1], mac_reg[2], mac_reg[3], mac_reg[4], mac_reg[5]};
                        o_src_mac        <= {mac_reg[6], mac_reg[7], mac_reg[8], mac_reg[9], mac_reg[10], mac_reg[11]};
                        o_ethertype      <= ETH_ARP;
                    end else begin 
                        o_meta_valid     <= 1'b0;
                        disp_state       <= DISP_DROP;
                    end 

                    if (o_meta_valid && i_meta_ready) begin 
                        o_meta_valid     <= 1'b0;
                        disp_state       <= DISP_STREAM;
                    end 
                end 

                DISP_STREAM : begin 
                    if (m_axis_tready && m_axis_tvalid && m_axis_tlast) begin 
                        disp_state      <= DISP_IDLE;
                        m_axis_tvalid   <= 1'b0;
                        m_axis_tlast    <= 1'b0;
                    end else if (s_axis_tready) begin 
                        if (s_axis_tvalid) begin 
                            m_axis_tvalid <= 1'b1; 
                            m_axis_tdata  <= s_axis_tdata;
                            m_axis_tlast  <= s_axis_tlast;
                        end else begin 
                            m_axis_tvalid <= 1'b0; 
                            m_axis_tlast  <= 1'b0;
                        end 
                    end 
                end 

                DISP_DROP : begin 
                    if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin 
                        disp_state <= DISP_IDLE;
                    end 
                end 

                default: begin
                    disp_state    <= DISP_IDLE;
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    o_meta_valid  <= 1'b0;
                end
            endcase 
        end 
    end 
endmodule 