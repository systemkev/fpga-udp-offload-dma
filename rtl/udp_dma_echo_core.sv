import common_pkg::*;

// Minimal integration core.
//
// Clock domains:
//   i_rx_clk : PHY RX_CLK (25 MHz for 100-Mb/s MII)
//   i_tx_clk : PHY TX_CLK (25 MHz for 100-Mb/s MII)
//   i_clk    : system/MIG UI clock
//
// Connect the S2MM and MM2S AXI ports as two masters into SmartConnect/MIG.
module udp_dma_echo_core #(
    parameter logic [47:0] LOCAL_MAC      = 48'h02_00_00_00_00_01,
    parameter logic [31:0] LOCAL_IP       = 32'hC0A8_0132, // 192.168.1.50
    parameter logic [15:0] LOCAL_UDP_PORT = 16'd4000,
    parameter logic [31:0] BUFFER0_BASE   = 32'h8000_0000,
    parameter logic [31:0] BUFFER1_BASE   = 32'h8000_1000
) (
    input  logic        i_clk,
    input  logic        i_n_reset,
    input  logic        i_rx_clk,
    input  logic        i_rx_n_reset,
    input  logic        i_tx_clk,
    input  logic        i_tx_n_reset,

    // MII RX
    input  logic [3:0]  i_mii_rxd,
    input  logic        i_mii_rx_dv,
    input  logic        i_mii_rx_er,

    // MII TX
    output logic [3:0]  o_mii_txd,
    output logic        o_mii_tx_en,
    output logic        o_mii_tx_er,

    // AXI4 write master (S2MM -> DDR)
    output logic [31:0] s2mm_axi_awaddr,
    output logic [7:0]  s2mm_axi_awlen,
    output logic [2:0]  s2mm_axi_awsize,
    output logic [1:0]  s2mm_axi_awburst,
    output logic        s2mm_axi_awvalid,
    input  logic        s2mm_axi_awready,
    output logic [31:0] s2mm_axi_wdata,
    output logic [3:0]  s2mm_axi_wstrb,
    output logic        s2mm_axi_wlast,
    output logic        s2mm_axi_wvalid,
    input  logic        s2mm_axi_wready,
    input  logic [1:0]  s2mm_axi_bresp,
    input  logic        s2mm_axi_bvalid,
    output logic        s2mm_axi_bready,

    // AXI4 read master (DDR -> MM2S)
    output logic [31:0] mm2s_axi_araddr,
    output logic [7:0]  mm2s_axi_arlen,
    output logic [2:0]  mm2s_axi_arsize,
    output logic [1:0]  mm2s_axi_arburst,
    output logic        mm2s_axi_arvalid,
    input  logic        mm2s_axi_arready,
    input  logic [31:0] mm2s_axi_rdata,
    input  logic [1:0]  mm2s_axi_rresp,
    input  logic        mm2s_axi_rlast,
    input  logic        mm2s_axi_rvalid,
    output logic        mm2s_axi_rready,

    output logic        o_rx_buffer_overflow,
    output logic        o_dma_error
);

    // ------------------------------------------------------------------------
    // MII RX -> validated Ethernet frame buffer
    // ------------------------------------------------------------------------
    logic [7:0] rx_mac_data;
    logic       rx_mac_valid;
    logic       rx_mac_last;
    logic       rx_frame_good;
    logic       rx_frame_bad;

    mii_rx_mac u_mii_rx_mac (
        .i_rx_clk      (i_rx_clk),
        .i_n_reset     (i_rx_n_reset),
        .i_mii_rxd     (i_mii_rxd),
        .i_mii_rx_dv   (i_mii_rx_dv),
        .i_mii_rx_er   (i_mii_rx_er),
        .o_rx_data     (rx_mac_data),
        .o_rx_valid    (rx_mac_valid),
        .o_rx_last     (rx_mac_last),
        .o_frame_good  (rx_frame_good),
        .o_frame_bad   (rx_frame_bad)
    );

    logic [7:0] fb_data;
    logic       fb_valid;
    logic       fb_ready;
    logic       fb_last;
    logic       fb_meta_valid;
    logic       fb_meta_ready;
    logic [10:0]fb_frame_size;

    rx_frame_buffer u_rx_frame_buffer (
        .i_rx_clk       (i_rx_clk),
        .i_rx_n_reset   (i_rx_n_reset),
        .i_rx_data      (rx_mac_data),
        .i_rx_valid     (rx_mac_valid),
        .i_rx_last      (rx_mac_last),
        .i_frame_good   (rx_frame_good),
        .i_frame_bad    (rx_frame_bad),
        .i_clk          (i_clk),
        .i_n_reset      (i_n_reset),
        .m_axis_tdata   (fb_data),
        .m_axis_tvalid  (fb_valid),
        .m_axis_tready  (fb_ready),
        .m_axis_tlast   (fb_last),
        .i_meta_ready   (fb_meta_ready),
        .o_meta_valid   (fb_meta_valid),
        .o_frame_size   (fb_frame_size),
        .o_buf_ovf      (o_rx_buffer_overflow)
    );

    // ------------------------------------------------------------------------
    // Ethernet dispatcher
    // ------------------------------------------------------------------------
    logic [7:0] eth_data;
    logic       eth_valid;
    logic       eth_ready;
    logic       eth_last;
    logic       eth_meta_valid;
    logic       eth_meta_ready;
    logic [47:0]eth_dst_mac;
    logic [47:0]eth_src_mac;
    t_ethernet_types eth_type;
    logic [10:0]eth_l3_size;

    ethernet_dispatch u_ethernet_dispatch (
        .i_clk              (i_clk),
        .i_n_reset          (i_n_reset),
        .s_axis_tdata       (fb_data),
        .s_axis_tvalid      (fb_valid),
        .s_axis_tlast       (fb_last),
        .s_axis_tready      (fb_ready),
        .i_frame_meta_valid (fb_meta_valid),
        .o_frame_meta_ready (fb_meta_ready),
        .i_frame_size       (fb_frame_size),
        .m_axis_tready      (eth_ready),
        .m_axis_tdata       (eth_data),
        .m_axis_tvalid      (eth_valid),
        .m_axis_tlast       (eth_last),
        .i_meta_ready       (eth_meta_ready),
        .o_meta_valid       (eth_meta_valid),
        .o_dst_mac          (eth_dst_mac),
        .o_src_mac          (eth_src_mac),
        .o_ethertype        (eth_type),
        .o_frame_size       (eth_l3_size)
    );

    // ------------------------------------------------------------------------
    // Route the Ethernet payload to IPv4 or ARP after metadata is accepted.
    // ------------------------------------------------------------------------
    typedef enum logic [1:0] {R_NONE, R_IPV4, R_ARP} t_route;
    t_route route;
    logic [47:0] route_src_mac, route_dst_mac;
    logic [10:0] route_l3_size;

    logic [7:0] ipv4_in_data;
    logic       ipv4_in_valid, ipv4_in_ready, ipv4_in_last;
    logic [7:0] arp_in_data;
    logic       arp_in_valid, arp_in_ready, arp_in_last;

    assign eth_meta_ready = (route == R_NONE);

    always_comb begin
        ipv4_in_data  = eth_data;
        ipv4_in_valid = (route == R_IPV4) && eth_valid;
        ipv4_in_last  = eth_last;

        arp_in_data   = eth_data;
        arp_in_valid  = (route == R_ARP) && eth_valid;
        arp_in_last   = eth_last;

        case (route)
            R_IPV4: eth_ready = ipv4_in_ready;
            R_ARP:  eth_ready = arp_in_ready;
            default:eth_ready = 1'b0;
        endcase
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            route         <= R_NONE;
            route_src_mac <= '0;
            route_dst_mac <= '0;
            route_l3_size <= '0;
        end else begin
            if (route == R_NONE && eth_meta_valid && eth_meta_ready) begin
                route_src_mac <= eth_src_mac;
                route_dst_mac <= eth_dst_mac;
                route_l3_size <= eth_l3_size;
                if (eth_type == ETH_IPV4) route <= R_IPV4;
                else if (eth_type == ETH_ARP) route <= R_ARP;
                else route <= R_NONE;
            end

            if ((route != R_NONE) && eth_valid && eth_ready && eth_last)
                route <= R_NONE;
        end
    end

    // ------------------------------------------------------------------------
    // IPv4 -> protocol dispatcher -> UDP RX
    // ------------------------------------------------------------------------
    logic [7:0] ip_payload_data;
    logic       ip_payload_valid, ip_payload_ready, ip_payload_last;
    t_ipv4_metadata ipv4_meta;
    logic ipv4_meta_valid, ipv4_meta_ready;

    ipv4_rx u_ipv4_rx (
        .i_clk              (i_clk),
        .i_n_reset          (i_n_reset),
        .s_axis_tdata       (ipv4_in_data),
        .s_axis_tvalid      (ipv4_in_valid),
        .s_axis_tlast       (ipv4_in_last),
        .s_axis_tready      (ipv4_in_ready),
        .i_src_mac          (route_src_mac),
        .i_dst_mac          (route_dst_mac),
        .i_frame_size       (route_l3_size),
        .m_axis_tdata       (ip_payload_data),
        .m_axis_tvalid      (ip_payload_valid),
        .m_axis_tlast       (ip_payload_last),
        .m_axis_tready      (ip_payload_ready),
        .o_ipv4_meta        (ipv4_meta),
        .o_ipv4_meta_valid  (ipv4_meta_valid),
        .i_ipv4_meta_ready  (ipv4_meta_ready),
        .i_local_ip         (LOCAL_IP)
    );

    logic [7:0] udp_datagram_data;
    logic       udp_datagram_valid, udp_datagram_ready, udp_datagram_last;
    t_ipv4_metadata udp_ip_meta;
    logic udp_ip_meta_valid, udp_ip_meta_ready;

    ip_dispatch u_ip_dispatch (
        .i_clk                   (i_clk),
        .i_n_reset               (i_n_reset),
        .i_ipv4_meta             (ipv4_meta),
        .i_ipv4_meta_valid       (ipv4_meta_valid),
        .o_ipv4_meta_ready       (ipv4_meta_ready),
        .s_axis_tdata            (ip_payload_data),
        .s_axis_tvalid           (ip_payload_valid),
        .s_axis_tlast            (ip_payload_last),
        .s_axis_tready           (ip_payload_ready),
        .o_udp_ipv4_meta         (udp_ip_meta),
        .o_udp_ipv4_meta_valid   (udp_ip_meta_valid),
        .i_udp_ipv4_meta_ready   (udp_ip_meta_ready),
        .m_axis_tdata            (udp_datagram_data),
        .m_axis_tvalid           (udp_datagram_valid),
        .m_axis_tlast            (udp_datagram_last),
        .m_axis_tready           (udp_datagram_ready)
    );

    logic [7:0] udp_payload8_data;
    logic       udp_payload8_valid, udp_payload8_ready, udp_payload8_last;
    t_udp_metadata rx_udp_meta;
    logic rx_udp_meta_valid, rx_udp_meta_ready;

    udp_rx u_udp_rx (
        .i_clk              (i_clk),
        .i_n_reset          (i_n_reset),
        .i_src_mac          (udp_ip_meta.src_mac),
        .i_src_ip           (udp_ip_meta.src_ip),
        .i_ipv4_payload_len (udp_ip_meta.payload_len),
        .i_ipv4_meta_valid  (udp_ip_meta_valid),
        .o_ipv4_meta_ready  (udp_ip_meta_ready),
        .s_axis_tdata       (udp_datagram_data),
        .s_axis_tvalid      (udp_datagram_valid),
        .s_axis_tlast       (udp_datagram_last),
        .s_axis_tready      (udp_datagram_ready),
        .m_axis_tdata       (udp_payload8_data),
        .m_axis_tvalid      (udp_payload8_valid),
        .m_axis_tlast       (udp_payload8_last),
        .m_axis_tready      (udp_payload8_ready),
        .o_udp_meta         (rx_udp_meta),
        .o_udp_meta_valid   (rx_udp_meta_valid),
        .i_udp_meta_ready   (rx_udp_meta_ready),
        .i_local_udp_port   (LOCAL_UDP_PORT)
    );

    // ------------------------------------------------------------------------
    // UDP payload -> AXIS32 -> S2MM -> DDR
    // ------------------------------------------------------------------------
    logic [31:0] packed_data;
    logic [3:0]  packed_keep;
    logic        packed_valid, packed_ready, packed_last;

    axis_8_to_32 u_axis_8_to_32 (
        .i_clk          (i_clk),
        .i_n_reset      (i_n_reset),
        .s_axis_tdata   (udp_payload8_data),
        .s_axis_tvalid  (udp_payload8_valid),
        .s_axis_tready  (udp_payload8_ready),
        .s_axis_tlast   (udp_payload8_last),
        .m_axis_tdata   (packed_data),
        .m_axis_tkeep   (packed_keep),
        .m_axis_tvalid  (packed_valid),
        .m_axis_tready  (packed_ready),
        .m_axis_tlast   (packed_last)
    );

    logic s2mm_start, s2mm_busy, s2mm_done, s2mm_error;
    logic [31:0] s2mm_base;
    logic [15:0] s2mm_actual_length;

    axis_s2mm u_axis_s2mm (
        .i_clk            (i_clk),
        .i_n_reset        (i_n_reset),
        .i_start          (s2mm_start),
        .i_base_addr      (s2mm_base),
        .s_axis_tdata     (packed_data),
        .s_axis_tkeep     (packed_keep),
        .s_axis_tvalid    (packed_valid),
        .s_axis_tready    (packed_ready),
        .s_axis_tlast     (packed_last),
        .o_busy           (s2mm_busy),
        .o_done           (s2mm_done),
        .o_actual_length  (s2mm_actual_length),
        .o_error          (s2mm_error),
        .m_axi_awaddr     (s2mm_axi_awaddr),
        .m_axi_awlen      (s2mm_axi_awlen),
        .m_axi_awsize     (s2mm_axi_awsize),
        .m_axi_awburst    (s2mm_axi_awburst),
        .m_axi_awvalid    (s2mm_axi_awvalid),
        .m_axi_awready    (s2mm_axi_awready),
        .m_axi_wdata      (s2mm_axi_wdata),
        .m_axi_wstrb      (s2mm_axi_wstrb),
        .m_axi_wlast      (s2mm_axi_wlast),
        .m_axi_wvalid     (s2mm_axi_wvalid),
        .m_axi_wready     (s2mm_axi_wready),
        .m_axi_bresp      (s2mm_axi_bresp),
        .m_axi_bvalid     (s2mm_axi_bvalid),
        .m_axi_bready     (s2mm_axi_bready)
    );

    // ------------------------------------------------------------------------
    // Buffer manager + MM2S
    // ------------------------------------------------------------------------
    logic mm2s_start, mm2s_busy, mm2s_done, mm2s_error;
    logic [31:0] mm2s_base;
    logic [15:0] mm2s_length;
    logic [31:0] mm2s_data;
    logic [3:0]  mm2s_keep;
    logic        mm2s_valid, mm2s_ready, mm2s_last;

    logic [47:0] tx_remote_mac;
    logic [31:0] tx_remote_ip;
    logic [15:0] tx_remote_port;
    logic [15:0] tx_payload_length;
    logic tx_meta_valid, tx_meta_ready;
    logic rx_no_buffer;

    buffer_manager #(
        .BUFFER0_BASE (BUFFER0_BASE),
        .BUFFER1_BASE (BUFFER1_BASE)
    ) u_buffer_manager (
        .i_clk                 (i_clk),
        .i_n_reset             (i_n_reset),
        .i_enable              (1'b1),
        .i_auto_echo           (1'b1),
        .i_rx_remote_mac       (rx_udp_meta.src_mac),
        .i_rx_remote_ip        (rx_udp_meta.src_ip),
        .i_rx_remote_port      (rx_udp_meta.src_port),
        .i_rx_payload_length   (rx_udp_meta.payload_length),
        .i_rx_meta_valid       (rx_udp_meta_valid),
        .o_rx_meta_ready       (rx_udp_meta_ready),
        .o_s2mm_start          (s2mm_start),
        .o_s2mm_base_addr      (s2mm_base),
        .i_s2mm_busy           (s2mm_busy),
        .i_s2mm_done           (s2mm_done),
        .i_s2mm_error          (s2mm_error),
        .i_s2mm_actual_length  (s2mm_actual_length),
        .o_mm2s_start          (mm2s_start),
        .o_mm2s_base_addr      (mm2s_base),
        .o_mm2s_byte_length    (mm2s_length),
        .i_mm2s_busy           (mm2s_busy),
        .i_mm2s_done           (mm2s_done),
        .i_mm2s_error          (mm2s_error),
        .o_tx_remote_mac       (tx_remote_mac),
        .o_tx_remote_ip        (tx_remote_ip),
        .o_tx_remote_port      (tx_remote_port),
        .o_tx_payload_length   (tx_payload_length),
        .o_tx_meta_valid       (tx_meta_valid),
        .i_tx_meta_ready       (tx_meta_ready),
        .o_rx_no_buffer_drop   (rx_no_buffer)
    );

    mm2s_axis u_mm2s_axis (
        .i_clk           (i_clk),
        .i_n_reset       (i_n_reset),
        .i_start         (mm2s_start),
        .i_base_addr     (mm2s_base),
        .i_byte_length   (mm2s_length),
        .o_busy          (mm2s_busy),
        .o_done          (mm2s_done),
        .o_error         (mm2s_error),
        .m_axis_tdata    (mm2s_data),
        .m_axis_tkeep    (mm2s_keep),
        .m_axis_tvalid   (mm2s_valid),
        .m_axis_tready   (mm2s_ready),
        .m_axis_tlast    (mm2s_last),
        .m_axi_araddr    (mm2s_axi_araddr),
        .m_axi_arlen     (mm2s_axi_arlen),
        .m_axi_arsize    (mm2s_axi_arsize),
        .m_axi_arburst   (mm2s_axi_arburst),
        .m_axi_arvalid   (mm2s_axi_arvalid),
        .m_axi_arready   (mm2s_axi_arready),
        .m_axi_rdata     (mm2s_axi_rdata),
        .m_axi_rresp     (mm2s_axi_rresp),
        .m_axi_rlast     (mm2s_axi_rlast),
        .m_axi_rvalid    (mm2s_axi_rvalid),
        .m_axi_rready    (mm2s_axi_rready)
    );

    // ------------------------------------------------------------------------
    // DDR payload + stored metadata -> complete UDP/IPv4/Ethernet frame
    // ------------------------------------------------------------------------
    logic [7:0] udp_tx_data;
    logic       udp_tx_valid, udp_tx_ready, udp_tx_last;

    udp_ipv4_tx #(
        .LOCAL_MAC      (LOCAL_MAC),
        .LOCAL_IP       (LOCAL_IP),
        .LOCAL_UDP_PORT (LOCAL_UDP_PORT)
    ) u_udp_ipv4_tx (
        .i_clk              (i_clk),
        .i_n_reset          (i_n_reset),
        .i_remote_mac       (tx_remote_mac),
        .i_remote_ip        (tx_remote_ip),
        .i_remote_port      (tx_remote_port),
        .i_payload_length   (tx_payload_length),
        .i_meta_valid       (tx_meta_valid),
        .o_meta_ready       (tx_meta_ready),
        .s_axis_tdata       (mm2s_data),
        .s_axis_tkeep       (mm2s_keep),
        .s_axis_tvalid      (mm2s_valid),
        .s_axis_tready      (mm2s_ready),
        .s_axis_tlast       (mm2s_last),
        .m_axis_tdata       (udp_tx_data),
        .m_axis_tvalid      (udp_tx_valid),
        .m_axis_tready      (udp_tx_ready),
        .m_axis_tlast       (udp_tx_last)
    );

    // ------------------------------------------------------------------------
    // ARP responder
    // ------------------------------------------------------------------------
    logic [7:0] arp_tx_data;
    logic       arp_tx_valid, arp_tx_ready, arp_tx_last;

    arp_responder #(
        .LOCAL_MAC (LOCAL_MAC),
        .LOCAL_IP  (LOCAL_IP)
    ) u_arp_responder (
        .i_clk          (i_clk),
        .i_n_reset      (i_n_reset),
        .s_axis_tdata   (arp_in_data),
        .s_axis_tvalid  (arp_in_valid),
        .s_axis_tready  (arp_in_ready),
        .s_axis_tlast   (arp_in_last),
        .m_axis_tdata   (arp_tx_data),
        .m_axis_tvalid  (arp_tx_valid),
        .m_axis_tready  (arp_tx_ready),
        .m_axis_tlast   (arp_tx_last)
    );

    // ------------------------------------------------------------------------
    // ARP priority over UDP -> whole-frame TX CDC buffer -> MII TX MAC
    // ------------------------------------------------------------------------
    logic [7:0] tx_mux_data;
    logic       tx_mux_valid, tx_mux_ready, tx_mux_last;

    axis_packet_arbiter u_axis_packet_arbiter (
        .i_clk          (i_clk),
        .i_n_reset      (i_n_reset),
        .s0_axis_tdata  (arp_tx_data),
        .s0_axis_tvalid (arp_tx_valid),
        .s0_axis_tready (arp_tx_ready),
        .s0_axis_tlast  (arp_tx_last),
        .s1_axis_tdata  (udp_tx_data),
        .s1_axis_tvalid (udp_tx_valid),
        .s1_axis_tready (udp_tx_ready),
        .s1_axis_tlast  (udp_tx_last),
        .m_axis_tdata   (tx_mux_data),
        .m_axis_tvalid  (tx_mux_valid),
        .m_axis_tready  (tx_mux_ready),
        .m_axis_tlast   (tx_mux_last)
    );

    logic [7:0] tx_fb_data;
    logic       tx_fb_valid, tx_fb_ready, tx_fb_last;

    tx_frame_buffer u_tx_frame_buffer (
        .i_clk          (i_clk),
        .i_n_reset      (i_n_reset),
        .s_axis_tdata   (tx_mux_data),
        .s_axis_tvalid  (tx_mux_valid),
        .s_axis_tready  (tx_mux_ready),
        .s_axis_tlast   (tx_mux_last),
        .i_tx_clk       (i_tx_clk),
        .i_tx_n_reset   (i_tx_n_reset),
        .m_axis_tdata   (tx_fb_data),
        .m_axis_tvalid  (tx_fb_valid),
        .m_axis_tready  (tx_fb_ready),
        .m_axis_tlast   (tx_fb_last)
    );

    mii_tx_mac u_mii_tx_mac (
        .i_tx_clk       (i_tx_clk),
        .i_n_reset      (i_tx_n_reset),
        .s_axis_tdata   (tx_fb_data),
        .s_axis_tvalid  (tx_fb_valid),
        .s_axis_tready  (tx_fb_ready),
        .s_axis_tlast   (tx_fb_last),
        .o_mii_txd      (o_mii_txd),
        .o_mii_tx_en    (o_mii_tx_en),
        .o_mii_tx_er    (o_mii_tx_er)
    );

    assign o_dma_error = s2mm_error | mm2s_error;

endmodule
