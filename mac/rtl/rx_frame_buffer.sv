module rx_frame_buffer (
    // RX clock domain
    input  logic       i_rx_clk,
    input  logic       i_rx_n_reset,

    // from mii_rx_mac
    input  logic [7:0] i_rx_data,
    input  logic       i_rx_valid,
    input  logic       i_rx_last,
    input  logic       i_frame_good,
    input  logic       i_frame_bad,

    // system-AXI clock domain
    input  logic       i_clk,
    input  logic       i_n_reset,

    // AXI4-Stream output
    output logic [7:0] m_axis_tdata,
    output logic       m_axis_tvalid,
    input  logic       m_axis_tready,
    output logic       m_axis_tlast,

    // status
    output logic       o_buf_ovf
);

    logic [7:0] ping_pong_buf_0 [0:2047];
    logic [7:0] ping_pong_buf_1 [0:2047];

    logic buf_0_used;
    logic buf_1_used;

    logic [10:0] wr_ptr;         // pointer to track writing process
    logic [10:0] wr_ptr_reg_0;   // latched pointer for CDC (buf 0)
    logic [10:0] wr_ptr_reg_1;   // latched pointer for CDC (buf 1)
    logic wr_buf_sel;    // 0 => writing to buf 0, 1 => writing to buf 1
    logic wr_buf_0_full; // 1 => buffer 0 is full and valid, and thus can be read 
    logic wr_buf_1_full; // 1 => buffer 1 is full and valid, and thus can be read

    logic [10:0] rd_ptr;

    typedef enum logic [1:0] {
        WR_READY,
        WR_WRITE, 
        WR_WAIT
    } t_writer_fsm;

    typedef enum logic [1:0] {
        RD_READY,
        RD_READ,
        RD_WAIT
    } t_reader_fsm;

    t_writer_fsm wr_state;
    t_reader_fsm rd_state;

    always_ff @(posedge i_rx_clk or negedge i_rx_n_reset) begin : writer 
        if (!i_rx_n_reset) begin

        end else begin 
            o_buf_ovf <= 1'b0;

            if (wr_buf_0_sent) begin 
                wr_buf_0_full <= 1'b0;
            end else if (wr_buf_1_sent) begin 
                wr_buf_1_full <= 1'b0;
            end 

            case (wr_state)

                WR_READY : begin 
                    if (i_rx_valid) begin 
                        wr_ptr   <= 11'b1;
                        wr_state <= WR_WRITE;

                        if (!buf_0_used) begin 
                            wr_buf_sel <= 1'b0;
                            ping_pong_buf_0[0] <= i_rx_data;
                        end else if (!buf_1_used) begin 
                            wr_buf_sel <= 1'b1;
                            ping_pong_buf_1[0] <= i_rx_data;
                        end else begin 
                            wr_ptr    <= 11'b0;
                            o_buf_ovf <= 1'b1;
                            wr_state  <= WR_READY;
                        end 
                    end 
                end 

                WR_WRITE : begin 
                    if (i_rx_valid) begin 
                        wr_ptr <= wr_ptr + 1;

                        // Buffer 0 is being written to
                        if (wr_buf_sel == 1'b0) begin 
                            ping_pong_buf_0[wr_ptr] <= i_rx_data;
                        // Buffer 1 being written to
                        end else begin 
                            ping_pong_buf_1[wr_ptr] <= i_rx_data;
                        end 

                        if (i_rx_last) begin 
                            wr_state <= WR_WAIT;
                        end 
                    end 
                end 

                WR_WAIT : begin
                    if (i_frame_good) begin 
                        wr_state       <= WR_READY;

                        if (wr_buf_sel == 1'b0) begin 
                            wr_buf_0_full <= 1'b1;
                            wr_ptr_reg_0  <= wr_ptr; 
                        end else begin 
                            wr_buf_1_full <= 1'b1;
                            wr_ptr_reg_1  <= wr_ptr;
                        end 
                    end else if (i_frame_bad) begin 
                        wr_state <= WR_READY;
                    end 
                end
            endcase 
        end 
    end : writer 

    logic [10:0] rd_ptr_size; 
    logic [10:0] rd_ptr;
    logic [7:0] nxt_byte;
    logic rd_buf_sel;   // 0 => buf 0, 1 => buf 1
    logic rd_buf_0_done;
    logic rd_buf_1_done;

    always_ff @(posedge i_clk or negedge i_n_reset) begin : reader 
        if (!i_n_reset) begin
            
        end else begin 
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;

            case (rd_state)

                RD_READY : begin 
                    rd_buf_0_done <= 1'b0;
                    rd_buf_1_done <= 1'b0;

                    if (m_axis_tready) begin 
                        if (rd_buf_0_full) begin 
                            rd_buf_sel  <= 1'b0;
                            state       <= RD_READ;
                            rd_ptr_size <= wr_ptr_reg_0;
                            nxt_byte    <= ping_pong_buf_0[0];
                        end else if (rd_buf_1_full) begin 
                            rd_buf_sel  <= 1'b1;
                            state       <= RD_READ;
                            rd_ptr_size <= wr_ptr_reg_1;
                            nxt_byte    <= ping_pong_buf_0[1];
                        end 
                    end 
                end 

                RD_READ : begin 
                    if (m_axis_tready) begin 
                        if (rd_ptr <= rd_ptr_size) begin 
                            if (rd_buf_sel) begin 
                                nxt_byte <= ping_pong_buf_0[rd_ptr + 1];
                            end else begin 
                                nxt_byte <= ping_pong_buf_1[rd_ptr + 1];
                            end 

                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata  <= nxt_byte;
                        end else begin 
                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata  <= nxt_byte;
                            m_axis_tlast  <= 1'b1;
                            state         <= RD_WAIT;
                        end 
                    end 
                end 

                RD_WAIT : begin 
                    if (rd_buf_sel) begin 
                        rd_buf_0_done <= 1'b1;
                    end else begin 
                        rd_buf_1_done <= 1'b1;
                    end 
                end 

            endcase 
        end 
    end : reader 

    // first flip flop sync
    logic rd_buf_0_full_ff1;
    logic rd_buf_1_full_ff1;

    // second FF sync
    logic rd_buf_0_full;
    logic rd_buf_1_full;

    always_ff @(posedge i_clk or negedge i_n_reset) begin : cdc_wr_to_rd
        if (!i_n_reset) begin
            rd_buf_0_full_ff1 <= 1'b0;
            rd_buf_1_full_ff1 <= 1'b0;
            rd_buf_0_full <= 1'b0;
            rd_buf_1_full <= 1'b0;
        end else begin 
            rd_buf_0_full_ff1 <= buf_0_used;
            rd_buf_1_full_ff1 <= buf_1_used;
            rd_buf_0_full <= rd_buf_0_full_ff1;
            rd_buf_1_full <= rd_buf_1_full_ff1;
        end 
    end : cdc_wr_to_rd

    // first flip flop sync
    logic wr_buf_0_sent_ff;
    logic wr_buf_1_sent_ff;

    // second FF sync
    logic wr_buf_0_sent;
    logic wr_buf_1_sent;
    always_ff @(posedge i_rx_clk or negedge i_rx_n_reset) begin : cdc_rd_to_wr 
        if (!i_rx_n_reset) begin
            wr_buf_0_sent_ff <= 1'b0;
            wr_buf_1_sent_ff <= 1'b0;
            wr_buf_0_sent    <= 1'b0;
            wr_buf_1_sent    <= 1'b0;
        end else begin 
            wr_buf_0_sent_ff <= rd_buf_0_done;
            wr_buf_1_sent_ff <= rd_buf_1_done;
            wr_buf_0_sent <= wr_buf_0_sent_ff;
            wr_buf_1_sent <= wr_buf_1_sent_ff;
        end
    end : cdc_rd_to_wr 

endmodule 