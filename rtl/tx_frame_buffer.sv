// Two-bank whole-frame CDC buffer: system clock writer -> MII TX clock reader.
// Storage is one 4096x8 simple-dual-port, dual-clock RAM so Vivado can infer BRAM.
module tx_frame_buffer #(
    parameter int DEPTH = 2048
) (
    input  logic       i_clk,
    input  logic       i_n_reset,

    input  logic [7:0] s_axis_tdata,
    input  logic       s_axis_tvalid,
    output logic       s_axis_tready,
    input  logic       s_axis_tlast,

    input  logic       i_tx_clk,
    input  logic       i_tx_n_reset,

    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    input  logic       m_axis_tready,
    output logic       m_axis_tlast
);
    localparam int PTR_W = $clog2(DEPTH);

    (* ram_style = "block" *) logic [7:0] frame_mem [0:(2*DEPTH)-1];

    logic           ram_we;
    logic [PTR_W:0] ram_waddr;
    logic [PTR_W:0] ram_raddr;
    logic [7:0]     ram_rdata;

    // BRAM write port.  Keep memory access out of resettable state-machine logic.
    always_ff @(posedge i_clk) begin
        if (ram_we)
            frame_mem[ram_waddr] <= s_axis_tdata;
    end

    // BRAM read port.  No asynchronous reset here: this is a BRAM-inference template.
    always_ff @(posedge i_tx_clk) begin
        ram_rdata <= frame_mem[ram_raddr];
    end

    logic pub_toggle0, pub_toggle1;
    logic ack_toggle0, ack_toggle1;
    logic [PTR_W:0] len0, len1;

    (* ASYNC_REG = "TRUE" *) logic ack0_ff1, ack0_sync;
    (* ASYNC_REG = "TRUE" *) logic ack1_ff1, ack1_sync;
    (* ASYNC_REG = "TRUE" *) logic pub0_ff1, pub0_sync;
    (* ASYNC_REG = "TRUE" *) logic pub1_ff1, pub1_sync;

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            ack0_ff1  <= 1'b0;
            ack0_sync <= 1'b0;
            ack1_ff1  <= 1'b0;
            ack1_sync <= 1'b0;
        end else begin
            ack0_ff1  <= ack_toggle0;
            ack0_sync <= ack0_ff1;
            ack1_ff1  <= ack_toggle1;
            ack1_sync <= ack1_ff1;
        end
    end

    always_ff @(posedge i_tx_clk or negedge i_tx_n_reset) begin
        if (!i_tx_n_reset) begin
            pub0_ff1  <= 1'b0;
            pub0_sync <= 1'b0;
            pub1_ff1  <= 1'b0;
            pub1_sync <= 1'b0;
        end else begin
            pub0_ff1  <= pub_toggle0;
            pub0_sync <= pub0_ff1;
            pub1_ff1  <= pub_toggle1;
            pub1_sync <= pub1_ff1;
        end
    end

    logic free0, free1, ready0, ready1;
    always_comb begin
        free0  = (ack0_sync == pub_toggle0);
        free1  = (ack1_sync == pub_toggle1);
        ready0 = (pub0_sync != ack_toggle0);
        ready1 = (pub1_sync != ack_toggle1);
    end

    // ---------------------------------------------------------------------
    // System-clock AXIS writer
    // ---------------------------------------------------------------------
    typedef enum logic {WR_IDLE, WR_WRITE} t_wr_state;
    t_wr_state wr_state;
    logic wr_sel;
    logic [PTR_W:0] wr_count;
    logic chosen_free_bank;

    always_comb begin
        chosen_free_bank = free0 ? 1'b0 : 1'b1;

        case (wr_state)
            WR_IDLE:  s_axis_tready = free0 || free1;
            WR_WRITE: s_axis_tready = (wr_count < DEPTH);
            default:  s_axis_tready = 1'b0;
        endcase

        ram_we    = 1'b0;
        ram_waddr = '0;
        if (s_axis_tvalid && s_axis_tready) begin
            if (wr_state == WR_IDLE) begin
                ram_we    = 1'b1;
                ram_waddr = {chosen_free_bank, {PTR_W{1'b0}}};
            end else begin
                ram_we    = 1'b1;
                ram_waddr = {wr_sel, wr_count[PTR_W-1:0]};
            end
        end
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            pub_toggle0 <= 1'b0;
            pub_toggle1 <= 1'b0;
            len0        <= '0;
            len1        <= '0;
            wr_state    <= WR_IDLE;
            wr_sel      <= 1'b0;
            wr_count    <= '0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    wr_count <= '0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        wr_sel <= chosen_free_bank;
                        if (s_axis_tlast) begin
                            if (!chosen_free_bank) begin
                                len0        <= {{PTR_W{1'b0}},1'b1};
                                pub_toggle0 <= ~pub_toggle0;
                            end else begin
                                len1        <= {{PTR_W{1'b0}},1'b1};
                                pub_toggle1 <= ~pub_toggle1;
                            end
                        end else begin
                            wr_count <= {{PTR_W{1'b0}},1'b1};
                            wr_state <= WR_WRITE;
                        end
                    end
                end

                WR_WRITE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (s_axis_tlast) begin
                            if (!wr_sel) begin
                                len0        <= wr_count + 1'b1;
                                pub_toggle0 <= ~pub_toggle0;
                            end else begin
                                len1        <= wr_count + 1'b1;
                                pub_toggle1 <= ~pub_toggle1;
                            end
                            wr_count <= '0;
                            wr_state <= WR_IDLE;
                        end else begin
                            wr_count <= wr_count + 1'b1;
                        end
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // TX-clock reader.  BRAM is prefetched so m_axis_tvalid can stay asserted
    // continuously while mii_tx_mac requests one byte every two MII clocks.
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] {RD_IDLE, RD_PRIME, RD_STREAM} t_rd_state;
    t_rd_state rd_state;
    logic rd_sel;
    logic [PTR_W:0] rd_len;
    logic [PTR_W-1:0] rd_ptr;

    assign m_axis_tdata  = ram_rdata;
    assign m_axis_tvalid = (rd_state == RD_STREAM);
    assign m_axis_tlast  = (rd_state == RD_STREAM) &&
                           ({1'b0, rd_ptr} == (rd_len - 1'b1));

    always_comb begin
        ram_raddr = {rd_sel, rd_ptr};

        case (rd_state)
            RD_IDLE: begin
                if (ready0)
                    ram_raddr = {1'b0, {PTR_W{1'b0}}};
                else if (ready1)
                    ram_raddr = {1'b1, {PTR_W{1'b0}}};
            end

            RD_PRIME: begin
                ram_raddr = {rd_sel, {PTR_W{1'b0}}};
            end

            RD_STREAM: begin
                if (m_axis_tvalid && m_axis_tready && !m_axis_tlast)
                    ram_raddr = {rd_sel, (rd_ptr + 1'b1)};
            end

            default: ram_raddr = '0;
        endcase
    end

    always_ff @(posedge i_tx_clk or negedge i_tx_n_reset) begin
        if (!i_tx_n_reset) begin
            ack_toggle0 <= 1'b0;
            ack_toggle1 <= 1'b0;
            rd_state    <= RD_IDLE;
            rd_sel      <= 1'b0;
            rd_len      <= '0;
            rd_ptr      <= '0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    rd_ptr <= '0;
                    if (ready0) begin
                        rd_sel   <= 1'b0;
                        rd_len   <= len0;
                        rd_state <= RD_PRIME;
                    end else if (ready1) begin
                        rd_sel   <= 1'b1;
                        rd_len   <= len1;
                        rd_state <= RD_PRIME;
                    end
                end

                RD_PRIME: begin
                    // ram_rdata now contains byte 0.
                    rd_ptr   <= '0;
                    rd_state <= RD_STREAM;
                end

                RD_STREAM: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (m_axis_tlast) begin
                            if (!rd_sel)
                                ack_toggle0 <= pub0_sync;
                            else
                                ack_toggle1 <= pub1_sync;
                            rd_state <= RD_IDLE;
                        end else begin
                            rd_ptr <= rd_ptr + 1'b1;
                        end
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

endmodule
