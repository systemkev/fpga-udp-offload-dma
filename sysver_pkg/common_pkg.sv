package common_pkg;
    
    parameter int MIN_PAYLOAD_SIZE = 63;
    parameter int MAX_PAYLOAD_SIZE = 1518;

    typedef enum logic [1:0] { 
        ETH_IPV4,
        ETH_ARP,
        ETH_INVALID
    } t_ethernet_types;

    typedef logic [15:0] t_ethertype;
    parameter t_ethertype IPV4_ETHERTYPE = 16'h0800;
    parameter t_ethertype ARP_ETHERTYPE  = 16'h0806;

    // IPv4 Protocol field values
    parameter logic [7:0] IP_PROTOCOL_ICMP = 8'd1;
    parameter logic [7:0] IP_PROTOCOL_TCP  = 8'd6;
    parameter logic [7:0] IP_PROTOCOL_UDP  = 8'd17;

    // UDP header
    parameter logic [3:0] UDP_HEAD_NUM_BYTES = 4'd8;

    // S2MM constants
    parameter int FIFO_ENTRY_WIDTH = 37;
    parameter int FIFO_DEPTH = 16;
    parameter int MAX_BURST = 16;
    parameter logic [12:0] FOUR_KB_BOUNDARY = 13'h1000;

    typedef struct packed {
        // Carried from Ethernet layer
        logic [47:0] src_mac;
        logic [47:0] dst_mac;

        // IPv4 header information
        logic [3:0]  version;
        logic [3:0]  ihl;

        logic [15:0] total_len;
        logic [15:0] payload_len;

        logic [15:0] id_field;

        logic [2:0]  flags;
        logic [12:0] frag_offset;

        logic [7:0]  ttl;
        logic [7:0]  protocol;

        logic [31:0] src_ip;
        logic [31:0] dst_ip;

    } t_ipv4_metadata;

    typedef struct packed {
        // Layer 2
        logic [47:0] src_mac;
        logic [47:0] dst_mac;

        // Layer 3
        logic [31:0] src_ip;
        logic [31:0] dst_ip;

        // Layer 4
        logic [15:0] src_port;
        logic [15:0] dst_port;

        // Application data length, excluding UDP header
        logic [15:0] payload_length;

    } t_udp_metadata;

endpackage