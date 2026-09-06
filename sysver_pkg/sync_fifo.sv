module sync_fifo #(
    parameter WIDTH = 8,
    parameter DEPTH = 16
)(
    // Clock and Reset
    input  logic             clk,
    input  logic             rst_n,   // active-low synchronous or asynchronous reset

    // Write Interface
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    output logic             full,
    //output logic           almost_full, // optional

    // Read Interface
    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic             empty
    //output logic           almost_empty // optional
);
    
    logic [WIDTH-1:0] fifo [0:DEPTH-1];
    logic [$clog2(DEPTH)-1:0] rd_ptr, wr_ptr; 
    logic [$clog2(DEPTH)-1:0] rd_ptr_nxt, wr_ptr_nxt;
    logic rd_wrap, wr_wrap; // used to track wrap-arounds
    logic rd_wrap_nxt, wr_wrap_nxt;

    assign rd_data = fifo[rd_ptr];

    always_comb begin 
        wr_ptr_nxt  = wr_ptr;
        rd_ptr_nxt  = rd_ptr;
        wr_wrap_nxt = wr_wrap;
        rd_wrap_nxt = rd_wrap;

        if (wr_en && !full) begin 
            if (wr_ptr == DEPTH - 1) begin 
                wr_ptr_nxt  = '0;
                wr_wrap_nxt = ~wr_wrap;
            end else begin 
                wr_ptr_nxt  = wr_ptr + 1;
            end 
        end         

        if (rd_en && !empty) begin 
            if (rd_ptr == DEPTH - 1) begin 
                rd_ptr_nxt  = '0;
                rd_wrap_nxt = ~rd_wrap;
            end else begin 
                rd_ptr_nxt  = rd_ptr + 1;
            end 
        end 
    end 

    always_ff @(posedge clk or negedge rst_n) begin 
        if (!rst_n) begin 
            rd_ptr  <= '0;
            wr_ptr  <= '0;
            rd_wrap <= 1'b0;
            wr_wrap <= 1'b0;
            full    <= 1'b0;
            empty   <= 1'b1;
        end else begin 
            if (wr_en && !full) begin
                fifo[wr_ptr] <= wr_data;

                wr_ptr  <= wr_ptr_nxt;
                wr_wrap <= wr_wrap_nxt;
            end

            if (rd_en && !empty) begin 
                rd_ptr  <= rd_ptr_nxt;
                rd_wrap <= rd_wrap_nxt;
            end 

            empty <= 1'b0;
            full  <= 1'b0;

            if ({rd_wrap_nxt, rd_ptr_nxt} == {wr_wrap_nxt, wr_ptr_nxt}) begin 
                empty <= 1'b1;    
            end else if (rd_ptr_nxt == wr_ptr_nxt && rd_wrap_nxt != wr_wrap_nxt) begin 
                full  <= 1'b1;
            end 
        end 
    end 

endmodule