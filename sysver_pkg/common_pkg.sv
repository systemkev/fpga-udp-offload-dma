package common_pkg;

    localparam logic [15:0] IPV4_ETHERTYPE = 16'h0800;
    localparam logic [15:0] ARP_ETHERTYPE  = 16'h0806;

    localparam int unsigned MAX_PAYLOAD_SIZE = 1518;
    localparam int unsigned MIN_PAYLOAD_SIZE = 64;
    localparam int unsigned UDP_HEAD_NUM_BYTES = 8;

    // Kept for compatibility with the original S2MM source.
    localparam int unsigned FIFO_DEPTH       = 16;
    localparam int unsigned FIFO_ENTRY_WIDTH = 37; // {TLAST,TKEEP[3:0],TDATA[31:0]}
    localparam int unsigned BOUNDARY_4KB      = 4096;

    typedef enum logic [1:0] {
        ETH_INVALID = 2'd0,
        ETH_IPV4    = 2'd1,
        ETH_ARP     = 2'd2
    } t_ethernet_types;

    typedef struct packed {
        logic [47:0] src_mac;
        logic [47:0] dst_mac;
        logic [3:0]  version;
        logic [3:0]  ihl;
        logic [15:0] total_len;
        logic [15:0] id_field;
        logic [12:0] frag_offset;
        logic [7:0]  ttl;
        logic [7:0]  protocol;
        logic [31:0] src_ip;
        logic [31:0] dst_ip;
        logic [15:0] payload_len;
    } t_ipv4_metadata;

    typedef struct packed {
        logic [47:0] src_mac;
        logic [31:0] src_ip;
        logic [15:0] src_port;
        logic [47:0] dst_mac;
        logic [31:0] dst_ip;
        logic [15:0] dst_port;
        logic [15:0] payload_length;
    } t_udp_metadata;

endpackage
