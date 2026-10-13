// Two-bank RX whole-frame buffer.
//
// The storage is coded as one 4096x8 simple-dual-port, dual-clock RAM.  The
// RAM read/write processes intentionally have NO asynchronous reset; this is
// important for Vivado block-RAM inference.  Control/state is reset in separate
// processes.
module rx_frame_buffer #(
    parameter int DEPTH = 2048
) (
    input  logic       i_rx_clk,
    input  logic       i_rx_n_reset,

    input  logic [7:0] i_rx_data,
    input  logic       i_rx_valid,
    input  logic       i_rx_last,
    input  logic       i_frame_good,
    input  logic       i_frame_bad,

    input  logic       i_clk,
    input  logic       i_n_reset,

    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    input  logic       m_axis_tready,
    output logic       m_axis_tlast,

    input  logic        i_meta_ready,
    output logic        o_meta_valid,
    output logic [10:0] o_frame_size,

    output logic       o_buf_ovf
);
    localparam int PTR_W = $clog2(DEPTH);

    // One bank-select bit + PTR_W address bits => 2*DEPTH bytes.
    (* ram_style = "block" *) logic [7:0] frame_mem [0:(2*DEPTH)-1];

    logic                 ram_we;
    logic [PTR_W:0]       ram_waddr;
    logic [PTR_W:0]       ram_raddr;
    logic [7:0]           ram_rdata;

    // BRAM write port: RX clock.  Do not add reset logic here.
    always_ff @(posedge i_rx_clk) begin
        if (ram_we)
            frame_mem[ram_waddr] <= i_rx_data;
    end

    // BRAM read port: system clock, synchronous read.  Do not add reset logic here.
    always_ff @(posedge i_clk) begin
        ram_rdata <= frame_mem[ram_raddr];
    end

    // ---------------------------------------------------------------------
    // CDC ownership handshake signals.  Declarations are intentionally above
    // every use, eliminating Synth 8-6901 "used before declaration" warnings.
    // ---------------------------------------------------------------------
    logic pub_toggle0, pub_toggle1;
    logic ack_toggle0, ack_toggle1;
    logic [PTR_W:0] len0, len1;

    (* ASYNC_REG = "TRUE" *) logic ack0_ff1, ack0_sync;
    (* ASYNC_REG = "TRUE" *) logic ack1_ff1, ack1_sync;
    (* ASYNC_REG = "TRUE" *) logic pub0_ff1, pub0_sync;
    (* ASYNC_REG = "TRUE" *) logic pub1_ff1, pub1_sync;

    always_ff @(posedge i_rx_clk or negedge i_rx_n_reset) begin
        if (!i_rx_n_reset) begin
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

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
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

    logic free0, free1;
    logic ready0, ready1;
    always_comb begin
        free0  = (ack0_sync == pub_toggle0);
        free1  = (ack1_sync == pub_toggle1);
        ready0 = (pub0_sync != ack_toggle0);
        ready1 = (pub1_sync != ack_toggle1);
    end

    // ---------------------------------------------------------------------
    // RX-clock writer
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] {WR_IDLE, WR_WRITE, WR_WAIT, WR_DROP} t_wr_state;
    t_wr_state wr_state;
    logic wr_sel;
    logic [PTR_W:0] wr_count;       // number of bytes already written
    logic [PTR_W:0] pending_len;
    logic chosen_free_bank;

    always_comb begin
        chosen_free_bank = free0 ? 1'b0 : 1'b1;

        ram_we    = 1'b0;
        ram_waddr = '0;

        if (i_rx_valid) begin
            case (wr_state)
                WR_IDLE: begin
                    if (free0 || free1) begin
                        ram_we    = 1'b1;
                        ram_waddr = {chosen_free_bank, {PTR_W{1'b0}}};
                    end
                end

                WR_WRITE: begin
                    if (wr_count < DEPTH) begin
                        ram_we    = 1'b1;
                        ram_waddr = {wr_sel, wr_count[PTR_W-1:0]};
                    end
                end

                default: begin end
            endcase
        end
    end

    // Overflow is a pulse/level associated with the first byte of a frame for
    // which neither bank is free.  It is combinational and therefore does not
    // create a set/reset-priority warning.
    assign o_buf_ovf = (wr_state == WR_IDLE) && i_rx_valid && !(free0 || free1);

    always_ff @(posedge i_rx_clk or negedge i_rx_n_reset) begin
        if (!i_rx_n_reset) begin
            pub_toggle0 <= 1'b0;
            pub_toggle1 <= 1'b0;
            len0        <= '0;
            len1        <= '0;
            wr_state    <= WR_IDLE;
            wr_sel      <= 1'b0;
            wr_count    <= '0;
            pending_len <= '0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    wr_count <= '0;
                    if (i_rx_valid) begin
                        if (free0 || free1) begin
                            wr_sel      <= chosen_free_bank;
                            pending_len <= {{PTR_W{1'b0}},1'b1};
                            if (i_rx_last) begin
                                wr_state <= WR_WAIT;
                            end else begin
                                wr_count <= {{PTR_W{1'b0}},1'b1};
                                wr_state <= WR_WRITE;
                            end
                        end else begin
                            wr_state <= i_rx_last ? WR_IDLE : WR_DROP;
                        end
                    end
                end

                WR_WRITE: begin
                    if (i_rx_valid) begin
                        if (wr_count >= DEPTH) begin
                            wr_state <= i_rx_last ? WR_IDLE : WR_DROP;
                        end else if (i_rx_last) begin
                            pending_len <= wr_count + 1'b1;
                            wr_state    <= WR_WAIT;
                        end else begin
                            wr_count <= wr_count + 1'b1;
                        end
                    end
                end

                WR_WAIT: begin
                    // A bad indication wins if both were ever asserted together.
                    if (i_frame_bad) begin
                        wr_state <= WR_IDLE;
                    end else if (i_frame_good) begin
                        if (!wr_sel) begin
                            len0        <= pending_len;
                            pub_toggle0 <= ~pub_toggle0;
                        end else begin
                            len1        <= pending_len;
                            pub_toggle1 <= ~pub_toggle1;
                        end
                        wr_state <= WR_IDLE;
                    end
                end

                WR_DROP: begin
                    if (i_rx_valid && i_rx_last)
                        wr_state <= WR_IDLE;
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // System-clock reader.  The synchronous BRAM read is prefetched so that,
    // once streaming starts, one byte can transfer every system clock.
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] {RD_IDLE, RD_META, RD_STREAM} t_rd_state;
    t_rd_state rd_state;
    logic rd_sel;
    logic [PTR_W:0] rd_len;
    logic [PTR_W-1:0] rd_ptr;

    assign o_meta_valid   = (rd_state == RD_META);
    assign o_frame_size   = rd_len[10:0];
    assign m_axis_tvalid  = (rd_state == RD_STREAM);
    assign m_axis_tdata   = ram_rdata;
    assign m_axis_tlast   = (rd_state == RD_STREAM) &&
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

            RD_META: begin
                ram_raddr = {rd_sel, {PTR_W{1'b0}}};
            end

            RD_STREAM: begin
                if (m_axis_tvalid && m_axis_tready && !m_axis_tlast)
                    ram_raddr = {rd_sel, (rd_ptr + 1'b1)};
            end

            default: ram_raddr = '0;
        endcase
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
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
                        rd_state <= RD_META;
                    end else if (ready1) begin
                        rd_sel   <= 1'b1;
                        rd_len   <= len1;
                        rd_state <= RD_META;
                    end
                end

                RD_META: begin
                    if (i_meta_ready) begin
                        rd_ptr   <= '0;
                        rd_state <= RD_STREAM;
                    end
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
