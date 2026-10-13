module arp_responder #(
    parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
    parameter logic [31:0] LOCAL_IP  = 32'hC0A8_0132
) (
    input  logic       i_clk,
    input  logic       i_n_reset,

    // ARP payload only (Ethernet header already stripped)
    input  logic [7:0] s_axis_tdata,
    input  logic       s_axis_tvalid,
    output logic       s_axis_tready,
    input  logic       s_axis_tlast,

    // Complete Ethernet ARP reply (without preamble/FCS)
    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    input  logic       m_axis_tready,
    output logic       m_axis_tlast
);

    logic [5:0] rx_ptr;
    logic       parse_ok;
    logic       header_done;
    logic       target_match;
    logic [47:0] sender_mac;
    logic [31:0] sender_ip;
    logic [31:0] target_ip;

    logic        reply_active;
    logic [5:0]  reply_ptr;

    assign s_axis_tready = !reply_active;

    function automatic logic [7:0] reply_byte(input logic [5:0] idx);
        begin
            case (idx)
                // Ethernet
                6'd0:  reply_byte = sender_mac[47:40];
                6'd1:  reply_byte = sender_mac[39:32];
                6'd2:  reply_byte = sender_mac[31:24];
                6'd3:  reply_byte = sender_mac[23:16];
                6'd4:  reply_byte = sender_mac[15:8];
                6'd5:  reply_byte = sender_mac[7:0];
                6'd6:  reply_byte = LOCAL_MAC[47:40];
                6'd7:  reply_byte = LOCAL_MAC[39:32];
                6'd8:  reply_byte = LOCAL_MAC[31:24];
                6'd9:  reply_byte = LOCAL_MAC[23:16];
                6'd10: reply_byte = LOCAL_MAC[15:8];
                6'd11: reply_byte = LOCAL_MAC[7:0];
                6'd12: reply_byte = 8'h08;
                6'd13: reply_byte = 8'h06;

                // ARP
                6'd14: reply_byte = 8'h00; // HTYPE Ethernet
                6'd15: reply_byte = 8'h01;
                6'd16: reply_byte = 8'h08; // PTYPE IPv4
                6'd17: reply_byte = 8'h00;
                6'd18: reply_byte = 8'd6;
                6'd19: reply_byte = 8'd4;
                6'd20: reply_byte = 8'h00; // opcode reply
                6'd21: reply_byte = 8'h02;
                6'd22: reply_byte = LOCAL_MAC[47:40];
                6'd23: reply_byte = LOCAL_MAC[39:32];
                6'd24: reply_byte = LOCAL_MAC[31:24];
                6'd25: reply_byte = LOCAL_MAC[23:16];
                6'd26: reply_byte = LOCAL_MAC[15:8];
                6'd27: reply_byte = LOCAL_MAC[7:0];
                6'd28: reply_byte = LOCAL_IP[31:24];
                6'd29: reply_byte = LOCAL_IP[23:16];
                6'd30: reply_byte = LOCAL_IP[15:8];
                6'd31: reply_byte = LOCAL_IP[7:0];
                6'd32: reply_byte = sender_mac[47:40];
                6'd33: reply_byte = sender_mac[39:32];
                6'd34: reply_byte = sender_mac[31:24];
                6'd35: reply_byte = sender_mac[23:16];
                6'd36: reply_byte = sender_mac[15:8];
                6'd37: reply_byte = sender_mac[7:0];
                6'd38: reply_byte = sender_ip[31:24];
                6'd39: reply_byte = sender_ip[23:16];
                6'd40: reply_byte = sender_ip[15:8];
                6'd41: reply_byte = sender_ip[7:0];
                default: reply_byte = 8'h00;
            endcase
        end
    endfunction

    always_comb begin
        m_axis_tdata  = reply_byte(reply_ptr);
        m_axis_tvalid = reply_active;
        m_axis_tlast  = reply_active && (reply_ptr == 6'd41);
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            rx_ptr       <= 6'd0;
            parse_ok     <= 1'b1;
            header_done  <= 1'b0;
            target_match <= 1'b0;
            sender_mac   <= '0;
            sender_ip    <= '0;
            target_ip    <= '0;
            reply_active <= 1'b0;
            reply_ptr    <= 6'd0;
        end else begin
            if (!reply_active && s_axis_tvalid && s_axis_tready) begin
                // Validate the fixed ARP request fields.
                case (rx_ptr)
                    6'd0: parse_ok <= (s_axis_tdata == 8'h00);
                    6'd1: parse_ok <= parse_ok && (s_axis_tdata == 8'h01);
                    6'd2: parse_ok <= parse_ok && (s_axis_tdata == 8'h08);
                    6'd3: parse_ok <= parse_ok && (s_axis_tdata == 8'h00);
                    6'd4: parse_ok <= parse_ok && (s_axis_tdata == 8'd6);
                    6'd5: parse_ok <= parse_ok && (s_axis_tdata == 8'd4);
                    6'd6: parse_ok <= parse_ok && (s_axis_tdata == 8'h00);
                    6'd7: parse_ok <= parse_ok && (s_axis_tdata == 8'h01);
                    default: begin end
                endcase

                case (rx_ptr)
                    6'd8:  sender_mac[47:40] <= s_axis_tdata;
                    6'd9:  sender_mac[39:32] <= s_axis_tdata;
                    6'd10: sender_mac[31:24] <= s_axis_tdata;
                    6'd11: sender_mac[23:16] <= s_axis_tdata;
                    6'd12: sender_mac[15:8]  <= s_axis_tdata;
                    6'd13: sender_mac[7:0]   <= s_axis_tdata;
                    6'd14: sender_ip[31:24]  <= s_axis_tdata;
                    6'd15: sender_ip[23:16]  <= s_axis_tdata;
                    6'd16: sender_ip[15:8]   <= s_axis_tdata;
                    6'd17: sender_ip[7:0]    <= s_axis_tdata;
                    6'd24: target_ip[31:24]  <= s_axis_tdata;
                    6'd25: target_ip[23:16]  <= s_axis_tdata;
                    6'd26: target_ip[15:8]   <= s_axis_tdata;
                    6'd27: begin
                        target_ip[7:0] <= s_axis_tdata;
                        target_match   <= ({target_ip[31:8], s_axis_tdata} == LOCAL_IP);
                        header_done    <= 1'b1;
                    end
                    default: begin end
                endcase

                if (s_axis_tlast) begin
                    // Normal Ethernet ARP requests contain padding, so header_done
                    // is normally already set before TLAST. Also handle no-padding
                    // input for simulation convenience.
                    if ((header_done && parse_ok && target_match) ||
                        ((rx_ptr == 6'd27) && parse_ok &&
                         ({target_ip[31:8], s_axis_tdata} == LOCAL_IP))) begin
                        reply_active <= 1'b1;
                        reply_ptr    <= 6'd0;
                    end
                    rx_ptr       <= 6'd0;
                    parse_ok     <= 1'b1;
                    header_done  <= 1'b0;
                    target_match <= 1'b0;
                end else begin
                    rx_ptr <= rx_ptr + 6'd1;
                end
            end

            if (reply_active && m_axis_tvalid && m_axis_tready) begin
                if (reply_ptr == 6'd41) begin
                    reply_active <= 1'b0;
                    reply_ptr    <= 6'd0;
                end else begin
                    reply_ptr <= reply_ptr + 6'd1;
                end
            end
        end
    end
endmodule
