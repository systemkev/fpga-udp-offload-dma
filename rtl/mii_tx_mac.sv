module mii_tx_mac (
    input  logic       i_tx_clk,
    input  logic       i_n_reset,

    input  logic [7:0] s_axis_tdata,
    input  logic       s_axis_tvalid,
    output logic       s_axis_tready,
    input  logic       s_axis_tlast,

    output logic [3:0] o_mii_txd,
    output logic       o_mii_tx_en,
    output logic       o_mii_tx_er
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_PREAMBLE,
        ST_SFD,
        ST_FRAME,
        ST_PAD,
        ST_FCS,
        ST_IFG
    } t_state;

    t_state state;
    logic nibble_phase;
    logic [2:0] preamble_count;
    logic [7:0] current_byte;
    logic current_last;
    logic [10:0] frame_count;
    logic [31:0] crc;
    logic [31:0] fcs_reg;
    logic [1:0] fcs_index;
    logic [4:0] ifg_count;

    logic [31:0] crc_next_current;
    logic [31:0] crc_next_zero;
    logic [7:0]  fcs_byte;

    function automatic logic [31:0] crc32_next_byte(
        input logic [31:0] crc_in,
        input logic [7:0] data
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

    assign crc_next_current = crc32_next_byte(crc, current_byte);
    assign crc_next_zero    = crc32_next_byte(crc, 8'h00);

    always_comb begin
        case (fcs_index)
            2'd0: fcs_byte = fcs_reg[7:0];
            2'd1: fcs_byte = fcs_reg[15:8];
            2'd2: fcs_byte = fcs_reg[23:16];
            default: fcs_byte = fcs_reg[31:24];
        endcase

        o_mii_txd   = 4'h0;
        o_mii_tx_en = 1'b0;
        o_mii_tx_er = 1'b0;
        s_axis_tready = 1'b0;

        case (state)
            ST_PREAMBLE: begin
                o_mii_tx_en = 1'b1;
                o_mii_txd   = 4'h5;
            end

            ST_SFD: begin
                o_mii_tx_en = 1'b1;
                o_mii_txd   = nibble_phase ? 4'hD : 4'h5;
                // Capture byte 0 while the high SFD nibble is transmitted.
                s_axis_tready = nibble_phase;
            end

            ST_FRAME: begin
                o_mii_tx_en = 1'b1;
                o_mii_txd   = nibble_phase ? current_byte[7:4] : current_byte[3:0];
                // During the high nibble, capture the next byte if this isn't TLAST.
                s_axis_tready = nibble_phase && !current_last;
            end

            ST_PAD: begin
                o_mii_tx_en = 1'b1;
                o_mii_txd   = 4'h0;
            end

            ST_FCS: begin
                o_mii_tx_en = 1'b1;
                o_mii_txd   = nibble_phase ? fcs_byte[7:4] : fcs_byte[3:0];
            end

            default: begin end
        endcase
    end

    always_ff @(posedge i_tx_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            state          <= ST_IDLE;
            nibble_phase   <= 1'b0;
            preamble_count <= '0;
            current_byte   <= '0;
            current_last   <= 1'b0;
            frame_count    <= '0;
            crc            <= 32'hFFFF_FFFF;
            fcs_reg        <= '0;
            fcs_index      <= '0;
            ifg_count      <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    nibble_phase   <= 1'b0;
                    preamble_count <= 3'd0;
                    frame_count    <= 11'd0;
                    crc            <= 32'hFFFF_FFFF;
                    fcs_index      <= 2'd0;
                    ifg_count      <= 5'd0;
                    if (s_axis_tvalid)
                        state <= ST_PREAMBLE;
                end

                ST_PREAMBLE: begin
                    if (!nibble_phase) begin
                        nibble_phase <= 1'b1;
                    end else begin
                        nibble_phase <= 1'b0;
                        if (preamble_count == 3'd6) begin
                            state <= ST_SFD;
                        end else begin
                            preamble_count <= preamble_count + 3'd1;
                        end
                    end
                end

                ST_SFD: begin
                    if (!nibble_phase) begin
                        nibble_phase <= 1'b1;
                    end else if (s_axis_tvalid && s_axis_tready) begin
                        current_byte <= s_axis_tdata;
                        current_last <= s_axis_tlast;
                        nibble_phase <= 1'b0;
                        state        <= ST_FRAME;
                    end
                end

                ST_FRAME: begin
                    if (!nibble_phase) begin
                        nibble_phase <= 1'b1;
                    end else begin
                        nibble_phase <= 1'b0;
                        frame_count  <= frame_count + 11'd1;

                        if (current_last) begin
                            if ((frame_count + 11'd1) < 11'd60) begin
                                crc   <= crc_next_current;
                                state <= ST_PAD;
                            end else begin
                                fcs_reg   <= ~crc_next_current;
                                fcs_index <= 2'd0;
                                state     <= ST_FCS;
                            end
                        end else if (s_axis_tvalid && s_axis_tready) begin
                            crc          <= crc_next_current;
                            current_byte <= s_axis_tdata;
                            current_last <= s_axis_tlast;
                        end else begin
                            // This should never occur with tx_frame_buffer, which
                            // guarantees an uninterrupted AXIS frame once started.
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_PAD: begin
                    if (!nibble_phase) begin
                        nibble_phase <= 1'b1;
                    end else begin
                        nibble_phase <= 1'b0;
                        frame_count  <= frame_count + 11'd1;
                        if ((frame_count + 11'd1) == 11'd60) begin
                            fcs_reg   <= ~crc_next_zero;
                            fcs_index <= 2'd0;
                            state     <= ST_FCS;
                        end else begin
                            crc <= crc_next_zero;
                        end
                    end
                end

                ST_FCS: begin
                    if (!nibble_phase) begin
                        nibble_phase <= 1'b1;
                    end else begin
                        nibble_phase <= 1'b0;
                        if (fcs_index == 2'd3) begin
                            ifg_count <= 5'd0;
                            state     <= ST_IFG;
                        end else begin
                            fcs_index <= fcs_index + 2'd1;
                        end
                    end
                end

                ST_IFG: begin
                    // 96 bit-times / 4 bits per MII clock = 24 clocks.
                    if (ifg_count == 5'd23) begin
                        ifg_count <= 5'd0;
                        state     <= ST_IDLE;
                    end else begin
                        ifg_count <= ifg_count + 5'd1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
