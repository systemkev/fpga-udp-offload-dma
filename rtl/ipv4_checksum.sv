module ipv4_checksum (
    input  logic [15:0] i_total_length,
    input  logic [15:0] i_identification,
    input  logic [7:0]  i_ttl,
    input  logic [7:0]  i_protocol,
    input  logic [31:0] i_src_ip,
    input  logic [31:0] i_dst_ip,
    output logic [15:0] o_checksum
);
    logic [31:0] sum;
    logic [16:0] fold1;
    logic [16:0] fold2;
    logic [16:0] fold3;

    always_comb begin
        // Fixed 20-byte IPv4 header.  The checksum word itself is zero here.
        sum = 32'd0;
        sum = sum + 16'h4500;
        sum = sum + i_total_length;
        sum = sum + i_identification;
        sum = sum + 16'h0000; // flags + fragment offset
        sum = sum + {i_ttl, i_protocol};
        sum = sum + 16'h0000; // checksum field
        sum = sum + i_src_ip[31:16];
        sum = sum + i_src_ip[15:0];
        sum = sum + i_dst_ip[31:16];
        sum = sum + i_dst_ip[15:0];

        fold1 = {1'b0, sum[15:0]} + {1'b0, sum[31:16]};
        fold2 = {1'b0, fold1[15:0]} + fold1[16];
        // Consume the possible carry from fold2 instead of letting synthesis
        // trim bit 16.  This is also the mathematically correct final fold.
        fold3 = {1'b0, fold2[15:0]} + fold2[16];
        o_checksum = ~fold3[15:0];
    end
endmodule
