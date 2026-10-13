import common_pkg::*;

module mii_rx_mac (
    input  logic       i_rx_clk,
    input  logic       i_n_reset,

    input  logic [3:0] i_mii_rxd,
    input  logic       i_mii_rx_dv,
    input  logic       i_mii_rx_er,

    output logic [7:0] o_rx_data,
    output logic       o_rx_valid,
    output logic       o_rx_last,

    output logic       o_frame_good,
    output logic       o_frame_bad
);
    function automatic logic [31:0] crc32_next_byte(
        input logic [31:0] crc_in,
        input logic [7:0]  data
    );
        logic [31:0] c;
        integer i;
        begin
            c = crc_in;
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0] ^ data[i]) c = (c >> 1) ^ 32'hEDB88320;
                else                c = (c >> 1);
            end
            crc32_next_byte = c;
        end
    endfunction

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

    // Nibble-to-byte assembly.  Every register has one assignment path per
    // clock, avoiding Synth 8-7137 set/reset-at-the-same-priority warnings.
    logic       nibble_phase;
    logic [3:0] low_nibble;
    logic [7:0] rx_byte;
    logic       rx_vld;

    always_ff @(posedge i_rx_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            nibble_phase <= 1'b0;
            low_nibble   <= 4'd0;
            rx_byte      <= 8'd0;
            rx_vld       <= 1'b0;
        end else if (!rxdv) begin
            nibble_phase <= 1'b0;
            rx_vld       <= 1'b0;
        end else if (!nibble_phase) begin
            low_nibble   <= rxd;
            nibble_phase <= 1'b1;
            rx_vld       <= 1'b0;
        end else begin
            rx_byte      <= {rxd, low_nibble};
            nibble_phase <= 1'b0;
            rx_vld       <= 1'b1;
        end
    end

    typedef enum logic [2:0] {
        RX_IDLE,
        RX_PREAMBLE,
        RX_FRAME,
        RX_DONE,
        RX_DROP
    } t_rx_state;

    t_rx_state state, state_n;
    logic [2:0] arrived_cnt, arrived_cnt_n;
    logic [10:0] counter, counter_n;
    logic [31:0] crc, crc_n;
    logic [3:0][7:0] shft_reg, shft_reg_n;

    logic [7:0] rx_data_n;
    logic rx_valid_n, rx_last_n, frame_good_n, frame_bad_n;

    always_comb begin
        state_n       = state;
        arrived_cnt_n = arrived_cnt;
        counter_n     = counter;
        crc_n         = crc;
        shft_reg_n    = shft_reg;

        rx_data_n     = o_rx_data;
        rx_valid_n    = 1'b0;
        rx_last_n     = 1'b0;
        frame_good_n  = 1'b0;
        frame_bad_n   = 1'b0;

        if (rxer && rxdv && state != RX_DROP) begin
            state_n     = RX_DROP;
            frame_bad_n = 1'b1;
        end else begin
            case (state)
                RX_IDLE: begin
                    arrived_cnt_n = '0;
                    counter_n     = '0;
                    crc_n         = 32'hFFFF_FFFF;
                    if (rx_vld && rx_byte == 8'h55)
                        state_n = RX_PREAMBLE;
                end

                RX_PREAMBLE: begin
                    if (rx_vld) begin
                        if (rx_byte == 8'h55) begin
                            state_n = RX_PREAMBLE;
                        end else if (rx_byte == 8'hD5) begin
                            state_n = RX_FRAME;
                        end else begin
                            frame_bad_n = 1'b1;
                            state_n     = RX_DROP;
                        end
                    end
                end

                RX_FRAME: begin
                    if (rxdv) begin
                        if (counter >= MAX_PAYLOAD_SIZE) begin
                            frame_bad_n = 1'b1;
                            state_n     = RX_DROP;
                        end else if (rx_vld) begin
                            shft_reg_n = {shft_reg[2:0], rx_byte};
                            counter_n  = counter + 1'b1;

                            if (arrived_cnt < 3'd4) begin
                                arrived_cnt_n = arrived_cnt + 1'b1;
                            end else begin
                                crc_n      = crc32_next_byte(crc, shft_reg[3]);
                                rx_valid_n = 1'b1;
                                rx_data_n  = shft_reg[3];
                            end
                        end
                    end else begin
                        // The four trailing bytes are the received FCS; emit only
                        // the last delayed frame-data byte here.
                        rx_valid_n = 1'b1;
                        rx_last_n  = 1'b1;
                        rx_data_n  = shft_reg[3];
                        crc_n      = crc32_next_byte(crc, shft_reg[3]);
                        state_n    = RX_DONE;
                    end
                end

                RX_DONE: begin
                    state_n = RX_DROP;
                    if (counter < MIN_PAYLOAD_SIZE) begin
                        frame_bad_n = 1'b1;
                    end else if (~crc == {rx_byte, shft_reg[0], shft_reg[1], shft_reg[2]}) begin
                        frame_good_n = 1'b1;
                    end else begin
                        frame_bad_n = 1'b1;
                    end
                end

                RX_DROP: begin
                    if (!rxdv)
                        state_n = RX_IDLE;
                end

                default: state_n = RX_IDLE;
            endcase
        end
    end

    always_ff @(posedge i_rx_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            state        <= RX_IDLE;
            arrived_cnt  <= '0;
            counter      <= '0;
            crc          <= 32'hFFFF_FFFF;
            shft_reg     <= '0;
            o_rx_data    <= '0;
            o_rx_valid   <= 1'b0;
            o_rx_last    <= 1'b0;
            o_frame_good <= 1'b0;
            o_frame_bad  <= 1'b0;
        end else begin
            state        <= state_n;
            arrived_cnt  <= arrived_cnt_n;
            counter      <= counter_n;
            crc          <= crc_n;
            shft_reg     <= shft_reg_n;
            o_rx_data    <= rx_data_n;
            o_rx_valid   <= rx_valid_n;
            o_rx_last    <= rx_last_n;
            o_frame_good <= frame_good_n;
            o_frame_bad  <= frame_bad_n;
        end
    end
endmodule
