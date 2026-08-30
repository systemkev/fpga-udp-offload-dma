import common_pkg::*;

module mii_rx_mac (
    input  logic       i_rx_clk,
    input  logic       i_n_reset,

    // MII interface from Ethernet PHY
    input  logic [3:0] i_mii_rxd,
    input  logic       i_mii_rx_dv,
    input  logic       i_mii_rx_er,

    // Received Ethernet frame bytes
    output logic [7:0] o_rx_data,
    output logic       o_rx_valid,
    output logic       o_rx_last,

    // Frame status
    output logic       o_frame_good,
    output logic       o_frame_bad
);

    function automatic logic [31:0] crc32_next_byte(
        input logic [31:0] crc,
        input logic [7:0]  data
    );
        logic [31:0] current_crc;
        current_crc = crc;
        
        for (int i = 0; i < 8; i++) begin
            if ((current_crc[0] ^ data[i]) == 1'b1) begin
                current_crc = (current_crc >> 1) ^ 32'hEDB88320;
            end else begin
                current_crc = (current_crc >> 1);
            end
        end
        return current_crc;
    endfunction

    // Input registers
    logic [3:0] rxd;
    logic       rxdv;
    logic       rxer;

    always_ff @(posedge i_rx_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            rxd  <= '0;
            rxdv <= 1'b0;
            rxer <= 1'b0;
        end else begin
            rxd  <= i_mii_rxd;
            rxdv <= i_mii_rx_dv;
            rxer <= i_mii_rx_er;
        end
    end

    // Nibble to Byte Assembly
    logic       nibble_phase;
    logic [3:0] low_nibble;
    logic [7:0] rx_byte;
    logic       rx_vld;   

    always_ff @(posedge i_rx_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            nibble_phase  <= 1'b0;
        end else begin 
            if (rxdv) begin
                rx_vld  <= 1'b0;
                nibble_phase  <= ~nibble_phase;
                low_nibble    <= rxd;

                if (nibble_phase == 1'b1) begin
                    rx_vld  <= 1'b1;
                    rx_byte <= {rxd, low_nibble};     
                end
            end else begin 
                rx_vld  <= 1'b0;
                nibble_phase  <= 1'b0;
            end 
        end 
    end

    // FSM and 4-byte FCS Shift Register
    typedef enum logic [2:0] {
        RX_IDLE,
        RX_PREAMBLE,
        RX_FRAME,
        RX_DONE,
        RX_DROP
    } t_rx_state;

    t_rx_state state;

    logic [2:0] arrived_cnt;
    logic [10:0] counter;
    logic [31:0] crc; 
    logic [3:0][7:0] shft_reg;

    always_ff @(posedge i_rx_clk or negedge i_n_reset) begin 
        if (!i_n_reset) begin
            state        <= RX_IDLE;
            crc          <= '1;
            shft_reg     <= '0;
            o_frame_bad  <= 1'b0;
            o_frame_good <= 1'b0;
            o_rx_last    <= 1'b0;
            o_rx_valid   <= 1'b0;
            arrived_cnt  <= '0;
            counter      <= '0;
        end else begin
            if (rxer && rxdv && state != RX_DROP) begin 
                state        <= RX_DROP;
                o_frame_bad  <= 1'b1;
            end else begin 
                o_rx_last  <= 1'b0;
                o_rx_valid <= 1'b0;
                o_frame_good <= 1'b0;
                o_frame_bad  <= 1'b0;

                case (state)

                    RX_IDLE : begin 
                        arrived_cnt <= '0;
                        counter     <= '0;
                        crc         <= '1;
                        if (rx_vld && rx_byte == 8'h55) begin 
                            state <= RX_PREAMBLE;
                        end 
                    end 

                    RX_PREAMBLE : begin 
                        if (rx_byte == 8'h55) begin 
                            // do nothing
                        end else if (rx_byte == 8'hD5) begin 
                            state       <= RX_FRAME;
                        end else begin 
                            o_frame_bad <= 1'b1;
                            state       <= RX_DROP;
                        end
                    end

                    RX_FRAME : begin 
                        if (rxdv) begin 
                            if (counter >= MAX_PAYLOAD_SIZE) begin 
                                o_frame_bad <= 1'b1;
                                state       <= RX_DROP;
                            end else if (rx_vld) begin 
                                shft_reg <= {shft_reg[2:0], rx_byte};

                                counter <= counter + 1;

                                if (arrived_cnt < 4) begin 
                                    arrived_cnt <= arrived_cnt + 1;
                                end else begin 
                                    crc <= crc32_next_byte(crc, shft_reg[3]);
                                    
                                    o_rx_valid <= 1'b1;
                                    o_rx_data  <= shft_reg[3];
                                end 
                            end 
                        end else begin 
                            o_rx_last  <= 1'b1;
                            o_rx_valid <= 1'b1;
                            o_rx_data  <= shft_reg[3];
                            crc        <= crc32_next_byte(crc, shft_reg[3]);
                            state      <= RX_DONE; 
                        end 
                    end

                    RX_DONE : begin 
                        state <= RX_DROP;

                        if (counter < MIN_PAYLOAD_SIZE) begin 
                            o_frame_bad  <= 1'b1;
                        end else if (~crc == {rx_byte, shft_reg[0], shft_reg[1], shft_reg[2]}) begin 
                            o_frame_good <= 1'b1;
                        end else begin 
                            o_frame_bad  <= 1'b1;
                        end 
                    end

                    RX_DROP : begin 
                        if (!rxdv) begin 
                            state <= RX_IDLE;
                        end 
                    end

                endcase 
            end 
        end
    end
endmodule