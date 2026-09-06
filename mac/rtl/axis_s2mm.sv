import common_pkg::*;

module axis_s2mm (
    input  logic        i_clk,
    input  logic        i_n_reset,

    // Command
    input  logic        i_start,
    input  logic [31:0] i_base_addr,

    // AXIS32 input
    input  logic [31:0] s_axis_tdata,
    input  logic [3:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    // Status
    output logic        o_busy,
    output logic        o_done,
    output logic [15:0] o_actual_length,
    output logic        o_error,

    // AXI4 write address
    output logic [31:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,

    // AXI4 write data
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,

    // AXI4 write response
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready
);

    logic [31:0] curr_addr;

    logic wr_en;
    logic [FIFO_ENTRY_WIDTH-1:0] wr_data;
    logic full;

    logic rd_en;
    logic [FIFO_ENTRY_WIDTH-1:0] rd_data;
    logic empty;

    sync_fifo u_sync_fifo (
        .WIDTH  (FIFO_ENTRY_WIDTH),
        .DEPTH  (FIFO_DEPTH)
    ) (
        .clk        (i_clk),
        .rst_n      (i_n_reset),
        .wr_en      (wr_en),
        .wr_data    (wr_data),
        .full       (full),
        .rd_en      (rd_en),
        .rd_data    (rd_data),
        .empty      (empty)
    );
    
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_LOAD_FIFO,
        ST_SEND_ADDR,
        ST_BURST,
        ST_ACK,
    } t_states;

    t_states state;

    logic [$clog2(FIFO_DEPTH):0] fifo_cnt;
    logic [$clog2(FIFO_DEPTH):0] beat_cnt; 
    logic [$clog2(FIFO_DEPTH):0] total_beats; 
    logic last_received;
    logic last_burst_flag;

    // load FIFO!
    always_comb begin 
        case (state) 
            ST_LOAD_FIFO : begin 
                s_axis_tready = !full;
                wr_en         = s_axis_tready && s_axis_tvalid;
                wr_data       = {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
                rd_en         = 1'b0;
            end

            ST_SEND_ADDR : begin
                s_axis_tready = 1'b0;
                wr_en         = 1'b0;
                wr_data       = '0;
                rd_en         = (m_axi_awready && m_axi_awvalid)? 1'b1 : 1'b0;
            end 

            ST_BURST : begin
                s_axis_tready = 1'b0;
                wr_en         = 1'b0;
                wr_data       = '0;
                rd_en         = m_axi_wready && m_axi_wvalid && !m_axi_wlast;
            end 

            default : begin 
                s_axis_tready = 1'b0;
                wr_en         = 1'b0;
                wr_data       = '0;
                rd_en         = '0;
            end 
        endcase 
    end 

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin 
            o_busy    <= 1'b0;
            o_done    <= 1'b0;
            o_error   <= 1'b0;

            fifo_cnt  <= '0;
            beat_cnt  <= '0;

            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            m_axi_wlast   <= 1'b0;
            m_axi_bready  <= 1'b0;

            state           <= ST_IDLE;
            last_received   <= 1'b0;
            last_burst_flag <= 1'b0;
        end else begin 
            case (state) 
                ST_IDLE : begin 
                    o_busy    <= 1'b0;
                    o_done    <= 1'b0;
                    o_error   <= 1'b0;

                    fifo_cnt  <= '0;
                    beat_cnt  <= '0;

                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_bready  <= 1'b0;
                    
                    last_received   <= 1'b0;
                    last_burst_flag <= 1'b0;
                    
                    if (i_start) begin 
                        curr_addr <= i_base_addr;
                        o_busy    <= 1'b1;
                        state     <= ST_LOAD_FIFO;
                        fifo_cnt  <= '0;
                    end 
                end 

                ST_LOAD_FIFO : begin  
                    beat_cnt <= '0;

                    if (full) begin 
                        state <= ST_SEND_ADDR;
                    end 

                    if (s_axis_tready && s_axis_tvalid) begin 
                        fifo_cnt <= fifo_cnt + 1;

                        if (s_axis_tlast) begin 
                            state           <= ST_SEND_ADDR;
                            last_received   <= 1'b1;
                            last_burst_flag <= 1'b0;
                        end 
                    end 
                end 

                ST_SEND_ADDR : begin 
                    m_axi_awaddr    <= curr_addr;
                    m_axi_awsize    <= 3'b010;  // four bytes per beat
                    m_axi_awburst   <= 2'b01;   // INCR => incrementing
                    m_axi_awvalid   <= 1'b1;

                    if (((BOUNDARY_4KB - curr_addr[11:0])[11:2]) >= fifo_cnt) begin
                        m_axi_awlen     <= fifo_cnt - 1;
                        last_burst_flag <= (last_received)? 1'b1 : 1'b0;
                    end else begin 
                        m_axi_awlen     <= (BOUNDARY_4KB - curr_addr[11:0])[11:2] - 1;
                        last_burst_flag <= 1'b0;
                    end 

                    if (m_axi_awready && m_axi_awvalid) begin 
                        state         <= ST_BURST;
                        m_axi_awvalid <= 1'b0;
                        m_axi_wdata   <= rd_data[31:0];
                        m_axi_wstrb   <= rd_data[35:32];
                        m_axi_wvalid  <= 1'b1;
                        m_axi_wlast   <= (m_axi_awlen == 1)? 1'b1 : 1'b0;
                        total_beats   <= m_axi_awlen + 1;
                    end 
                end 

                ST_BURST : begin
                    if (m_axi_wvalid && m_axi_wready) begin 
                        beat_cnt <= beat_cnt + 1;

                        if (m_axi_wlast) begin
                            state        <= ST_ACK;
                            m_axi_bready <= 1'b1;
                            m_axi_wvalid <= 1'b0;
                            m_axi_wlast  <= 1'b0;
                        end else begin
                            m_axi_wdata <= rd_data[31:0];
                            m_axi_wstrb <= rd_data[35:32];
                            m_axi_wlast <= (beat_cnt == total_beats - 2)? 1'b1 : 1'b0;
                        end 
                    end 
                end

                ST_ACK : begin
                    if (m_axi_bready && m_axi_bvalid) begin
                        m_axi_bready <= 1'b0;
                        beat_cnt     <= '0;

                        if (m_axi_bresp == 2'b0) begin 
                            if (last_received && last_burst_flag) begin 
                                state       <= ST_IDLE;
                                o_busy      <= 1'b0;
                                o_done      <= 1'b1;
                            end else if (last_received && !last_burst_flag) begin
                                state       <= ST_SEND_ADDR;
                                fifo_cnt    <= fifo_cnt - beat_cnt;
                                curr_addr   <= curr_addr + 4 * beat_cnt;
                            end else if (!last_received) begin 
                                state       <= ST_LOAD_FIFO;
                                fifo_cnt    <= '0;
                                curr_addr   <= curr_addr + 4 * beat_cnt;
                            end 
                        end else begin
                            state     <= ST_IDLE;
                            o_error   <= 1'b1;
                            o_busy    <= 1'b0;
                        end
                    end
                end
            endcase 
        end  
    end 
endmodule 