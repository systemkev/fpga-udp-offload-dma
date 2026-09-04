module axis_8_to_32 (
    input  logic        i_clk,
    input  logic        i_n_reset,

    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    output logic [31:0] m_axis_tdata,
    output logic [3:0]  m_axis_tkeep,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast
);

    logic [23:0] word;
    logic [1:0] byte_cnt; 

    assign s_axis_tready = !m_axis_tvalid || m_axis_tready;

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
                m_axis_tvalid   <= 1'b0;
                m_axis_tlast    <= 1'b0;
                byte_cnt        <= '0;
        end else begin
            if (m_axis_tready && m_axis_tvalid) begin 
                m_axis_tvalid   <= 1'b0;
                m_axis_tlast    <= 1'b0;
            end 

            if (s_axis_tvalid && s_axis_tready) begin 
                byte_cnt <= byte_cnt + 1;

                case (byte_cnt)
                    2'd0: begin 
                        word[7:0]    <= s_axis_tdata;

                        if (s_axis_tlast) begin 
                            m_axis_tdata    <= {24'b0, s_axis_tdata};
                            m_axis_tvalid   <= 1'b1;
                            m_axis_tlast    <= 1'b1;
                            m_axis_tkeep    <= 4'b0001;
                            byte_cnt        <= '0;
                        end 
                    end 

                    2'd1: begin 
                        word[15:8]   <= s_axis_tdata;

                        if (s_axis_tlast) begin 
                            m_axis_tdata    <= {16'b0, s_axis_tdata, word[7:0]};
                            m_axis_tvalid   <= 1'b1;
                            m_axis_tlast    <= 1'b1;
                            m_axis_tkeep    <= 4'b0011;
                            byte_cnt        <= '0;
                        end 
                    end 

                    2'd2: begin 
                        word[23:16]  <= s_axis_tdata;

                        if (s_axis_tlast) begin 
                            m_axis_tdata    <= {8'b0, s_axis_tdata, word[15:0]};
                            m_axis_tvalid   <= 1'b1;
                            m_axis_tlast    <= 1'b1;
                            m_axis_tkeep    <= 4'b0111;
                            byte_cnt        <= '0;
                        end 
                    end 

                    2'd3: begin 
                        m_axis_tdata    <= {s_axis_tdata, word};
                        m_axis_tvalid   <= 1'b1;
                        byte_cnt        <= '0;
                        m_axis_tkeep    <= 4'b1111;

                        if (s_axis_tlast) begin 
                            m_axis_tlast    <= 1'b1;
                        end 
                    end 
                endcase 
            end
        end 
    end 
endmodule 