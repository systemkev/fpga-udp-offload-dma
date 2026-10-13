`timescale 1ns / 1ps

import common_pkg::*;

module ipv4_rx_TB;

    // Rigorous regression for the split IPv4 receive layer:
    // - ethernet_dispatch has already selected IPv4 before this module
    // - ipv4_rx parses/validates IPv4 and strips the IPv4 header
    // - protocol is metadata only; ipv4_rx does not dispatch L4 protocols
    // - UDP validation belongs downstream in udp_rx
    // - directed weak-area tests cover length consistency and FSM recovery
    // - counter-boundary payload sweeps and dual-channel backpressure stress
    // - 1000-packet constrained-random regression

    // ================================================================
    // Configuration
    // ================================================================

    localparam time CLK_PERIOD = 10ns;

    localparam logic [31:0] LOCAL_IP = 32'hC0_A8_01_32; // 192.168.1.50

    localparam int DEFAULT_TIMEOUT = 3000;
    localparam int LARGE_TIMEOUT   = 10000;

    typedef byte unsigned byte_t;


    // ================================================================
    // DUT Signals
    // ================================================================

    logic i_clk;
    logic i_n_reset;

    logic [7:0] s_axis_tdata;
    logic       s_axis_tvalid;
    logic       s_axis_tlast;
    logic       s_axis_tready;

    logic [47:0] i_src_mac;
    logic [47:0] i_dst_mac;
    logic [10:0] i_frame_size;

    logic [7:0] m_axis_tdata;
    logic       m_axis_tvalid;
    logic       m_axis_tlast;
    logic       m_axis_tready;

    t_ipv4_metadata o_ipv4_meta;
    logic           o_ipv4_meta_valid;
    logic           i_ipv4_meta_ready;

    logic [31:0] i_local_ip;


    // ================================================================
    // DUT
    // ================================================================

    ipv4_rx dut (
        .i_clk               (i_clk),
        .i_n_reset           (i_n_reset),

        .s_axis_tdata        (s_axis_tdata),
        .s_axis_tvalid       (s_axis_tvalid),
        .s_axis_tlast        (s_axis_tlast),
        .s_axis_tready       (s_axis_tready),

        .i_src_mac           (i_src_mac),
        .i_dst_mac           (i_dst_mac),
        .i_frame_size        (i_frame_size),

        .m_axis_tdata        (m_axis_tdata),
        .m_axis_tvalid       (m_axis_tvalid),
        .m_axis_tlast        (m_axis_tlast),
        .m_axis_tready       (m_axis_tready),

        .o_ipv4_meta         (o_ipv4_meta),
        .o_ipv4_meta_valid   (o_ipv4_meta_valid),
        .i_ipv4_meta_ready   (i_ipv4_meta_ready),

        .i_local_ip          (i_local_ip)
    );


    // ================================================================
    // Clock
    // ================================================================

    initial begin
        i_clk = 1'b0;

        forever
            #(CLK_PERIOD/2) i_clk = ~i_clk;
    end


    // ================================================================
    // Packet configuration
    // ================================================================

    typedef struct packed {
        logic [47:0] dst_mac;
        logic [47:0] src_mac;

        logic [3:0]  version;
        logic [3:0]  ihl;

        logic [7:0]  dscp_ecn;

        logic [15:0] total_len;
        logic [15:0] id_field;

        //
        // IPv4 bytes 6-7:
        //
        // [15]   Reserved
        // [14]   DF
        // [13]   MF
        // [12:0] Fragment offset
        //
        logic [15:0] flags_frag;

        logic [7:0]  ttl;
        logic [7:0]  protocol;

        logic [15:0] checksum;

        logic [31:0] src_ip;
        logic [31:0] dst_ip;

    } ipv4_cfg_t;


    // ================================================================
    // Scoreboard
    // ================================================================

    typedef struct packed {
        logic [7:0] data;
        logic       last;
    } payload_expect_t;


    t_ipv4_metadata expected_meta_q[$];
    payload_expect_t expected_payload_q[$];


    int tests_run    = 0;
    int tests_failed = 0;
    int error_count  = 0;

    int test_start_errors;

    int meta_handshake_count    = 0;
    int payload_handshake_count = 0;

    string current_test;
    string current_subcase;


    bit scoreboard_enable = 1'b1;

    bit expect_no_outputs       = 1'b0;
    bit expect_drop_ready       = 1'b0;
    bit check_stream_ready_rule = 1'b0;

    bit random_m_ready_enable    = 1'b0;
    bit random_meta_ready_enable = 1'b0;


    // ================================================================
    // Reporting
    // ================================================================

    task automatic tb_error(input string msg);

        error_count++;

        if (current_subcase != "") begin
            $display(
                "[ERROR @ %0t] %s [%s]: %s",
                $time,
                current_test,
                current_subcase,
                msg
            );
        end
        else begin
            $display(
                "[ERROR @ %0t] %s: %s",
                $time,
                current_test,
                msg
            );
        end

    endtask


    task automatic start_test(input string name);

        current_test       = name;
        current_subcase    = "";
        test_start_errors  = error_count;

        tests_run++;

        $display("");
        $display("============================================================");
        $display("TEST: %s", name);
        $display("============================================================");

    endtask


    task automatic finish_test();

        current_subcase = "";

        repeat (2)
            @(posedge i_clk);

        if (error_count == test_start_errors) begin
            $display("[PASS] %s", current_test);
        end
        else begin
            tests_failed++;
            $display("[FAIL] %s", current_test);
        end

    endtask


    // ================================================================
    // Random READY generation
    // ================================================================

    always @(negedge i_clk) begin

        if (i_n_reset) begin

            if (random_m_ready_enable)
                m_axis_tready <= ($urandom_range(0, 9) < 7);

            if (random_meta_ready_enable)
                i_ipv4_meta_ready <= ($urandom_range(0, 9) < 6);

        end

    end


    // ================================================================
    // Main scoreboard
    // ================================================================

    always @(posedge i_clk) begin

        if (i_n_reset && scoreboard_enable) begin

            // --------------------------------------------------------
            // Metadata handshake
            // --------------------------------------------------------

            if (o_ipv4_meta_valid && i_ipv4_meta_ready) begin

                meta_handshake_count++;

                if (expected_meta_q.size() == 0) begin

                    tb_error(
                        "Unexpected IPv4 metadata handshake"
                    );

                end
                else begin

                    t_ipv4_metadata expected;

                    expected = expected_meta_q.pop_front();

                    if (o_ipv4_meta !== expected) begin

                        $display("EXPECTED:");
                        $display("  src_mac      = %012h", expected.src_mac);
                        $display("  dst_mac      = %012h", expected.dst_mac);
                        $display("  version      = %0d",   expected.version);
                        $display("  ihl          = %0d",   expected.ihl);
                        $display("  total_len    = %0d",   expected.total_len);
                        $display("  id_field     = %04h",  expected.id_field);
                        $display("  frag_offset  = %04h",  expected.frag_offset);
                        $display("  ttl          = %0d",   expected.ttl);
                        $display("  protocol     = %0d",   expected.protocol);
                        $display("  src_ip       = %08h",  expected.src_ip);
                        $display("  dst_ip       = %08h",  expected.dst_ip);
                        $display("  payload_len  = %0d",   expected.payload_len);

                        $display("ACTUAL:");
                        $display("  src_mac      = %012h", o_ipv4_meta.src_mac);
                        $display("  dst_mac      = %012h", o_ipv4_meta.dst_mac);
                        $display("  version      = %0d",   o_ipv4_meta.version);
                        $display("  ihl          = %0d",   o_ipv4_meta.ihl);
                        $display("  total_len    = %0d",   o_ipv4_meta.total_len);
                        $display("  id_field     = %04h",  o_ipv4_meta.id_field);
                        $display("  frag_offset  = %04h",  o_ipv4_meta.frag_offset);
                        $display("  ttl          = %0d",   o_ipv4_meta.ttl);
                        $display("  protocol     = %0d",   o_ipv4_meta.protocol);
                        $display("  src_ip       = %08h",  o_ipv4_meta.src_ip);
                        $display("  dst_ip       = %08h",  o_ipv4_meta.dst_ip);
                        $display("  payload_len  = %0d",   o_ipv4_meta.payload_len);

                        tb_error("IPv4 metadata mismatch");

                    end

                end

            end


            // --------------------------------------------------------
            // Payload handshake
            // --------------------------------------------------------

            if (m_axis_tvalid && m_axis_tready) begin

                payload_handshake_count++;

                if (expected_payload_q.size() == 0) begin

                    tb_error(
                        $sformatf(
                            "Unexpected output payload byte 0x%02h TLAST=%0b",
                            m_axis_tdata,
                            m_axis_tlast
                        )
                    );

                end
                else begin

                    payload_expect_t expected;

                    expected = expected_payload_q.pop_front();

                    if (m_axis_tdata !== expected.data) begin

                        tb_error(
                            $sformatf(
                                "Payload mismatch: expected 0x%02h got 0x%02h",
                                expected.data,
                                m_axis_tdata
                            )
                        );

                    end

                    if (m_axis_tlast !== expected.last) begin

                        tb_error(
                            $sformatf(
                                "Payload TLAST mismatch on byte 0x%02h: expected %0b got %0b",
                                expected.data,
                                expected.last,
                                m_axis_tlast
                            )
                        );

                    end

                end

            end


            // --------------------------------------------------------
            // Rejected packet must not produce anything
            // --------------------------------------------------------

            if (expect_no_outputs) begin

                if (o_ipv4_meta_valid)
                    tb_error(
                        "Metadata became valid for packet expected to be dropped"
                    );

                if (m_axis_tvalid)
                    tb_error(
                        "Payload became valid for packet expected to be dropped"
                    );

            end


            // --------------------------------------------------------
            // ST_DROP behavior
            // --------------------------------------------------------

            if (expect_drop_ready) begin

                if (s_axis_tready !== 1'b1) begin

                    tb_error(
                        "s_axis_tready was not asserted while draining dropped packet"
                    );

                end

            end


            // --------------------------------------------------------
            // Required streaming backpressure relation
            // --------------------------------------------------------

            if (check_stream_ready_rule) begin

                if (
                    s_axis_tready !==
                    ((m_axis_tready && !m_axis_tlast) || !m_axis_tvalid)
                ) begin

                    tb_error(
                        $sformatf(
                            "STREAM ready equation violated: s_ready=%0b m_ready=%0b m_valid=%0b m_last=%0b",
                            s_axis_tready,
                            m_axis_tready,
                            m_axis_tvalid,
                            m_axis_tlast
                        )
                    );

                end

            end

        end

    end


    // ================================================================
    // Protocol assertions
    // ================================================================

    //
    // AXI payload must remain stable while downstream stalls.
    //
    property p_payload_stable_when_stalled;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        m_axis_tvalid && !m_axis_tready
        |=>
        m_axis_tvalid &&
        $stable(m_axis_tdata) &&
        $stable(m_axis_tlast);

    endproperty


    assert property (p_payload_stable_when_stalled)
    else begin

        tb_error(
            "m_axis changed while TVALID=1 and TREADY=0"
        );

    end


    //
    // Metadata must remain asserted/stable until accepted.
    //
    property p_metadata_stable_when_stalled;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        o_ipv4_meta_valid && !i_ipv4_meta_ready
        |=>
        o_ipv4_meta_valid &&
        $stable(o_ipv4_meta);

    endproperty


    assert property (p_metadata_stable_when_stalled)
    else begin

        tb_error(
            "IPv4 metadata changed or valid deasserted while stalled"
        );

    end


    //
    // Metadata must be accepted before payload is allowed to appear.
    // A stalled metadata transaction therefore blocks both upstream
    // progress and payload presentation.
    //
    property p_metadata_stall_blocks_payload;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        o_ipv4_meta_valid && !i_ipv4_meta_ready
        |->
        !m_axis_tvalid && !s_axis_tready;

    endproperty


    assert property (p_metadata_stall_blocks_payload)
    else begin

        tb_error(
            "Payload/upstream progressed while IPv4 metadata was stalled"
        );

    end


    //
    // A transferred output TLAST must be a real transfer, never a pulse
    // detached from TVALID. This catches end-of-payload bookkeeping bugs.
    //
    property p_output_last_requires_valid;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        m_axis_tlast |-> m_axis_tvalid;

    endproperty


    assert property (p_output_last_requires_valid)
    else begin

        tb_error(
            "m_axis_tlast asserted without m_axis_tvalid"
        );

    end


    //
    // Verify our own testbench AXIS source obeys ready/valid.
    //
    property p_source_stable_when_stalled;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        s_axis_tvalid && !s_axis_tready
        |=>
        s_axis_tvalid &&
        $stable(s_axis_tdata) &&
        $stable(s_axis_tlast);

    endproperty


    assert property (p_source_stable_when_stalled)
    else begin

        tb_error(
            "TB source changed AXIS data while DUT had TREADY low"
        );

    end


    //
    // No unknown payload fields while valid.
    //
    property p_payload_known;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        m_axis_tvalid
        |->
        !$isunknown({m_axis_tdata, m_axis_tlast});

    endproperty


    assert property (p_payload_known)
    else begin

        tb_error("Unknown/X found on valid payload output");

    end


    //
    // No unknown metadata while valid.
    //
    property p_metadata_known;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        o_ipv4_meta_valid
        |->
        !$isunknown(o_ipv4_meta);

    endproperty


    assert property (p_metadata_known)
    else begin

        tb_error("Unknown/X found in valid IPv4 metadata");

    end


    // ================================================================
    // Coverage
    // ================================================================

    cover property (
        @(posedge i_clk)
        o_ipv4_meta_valid &&
        !i_ipv4_meta_ready
    );

    cover property (
        @(posedge i_clk)
        m_axis_tvalid &&
        !m_axis_tready
    );

    cover property (
        @(posedge i_clk)
        s_axis_tvalid &&
        s_axis_tready &&
        s_axis_tlast
    );


    // ================================================================
    // Default valid packet configuration
    // ================================================================

    function automatic ipv4_cfg_t default_cfg(
        input int payload_length
    );

        ipv4_cfg_t cfg;

        cfg = '0;

        cfg.dst_mac = 48'h02_00_00_00_00_01;
        cfg.src_mac = 48'h10_20_30_40_50_60;

        cfg.version = 4;
        cfg.ihl     = 5;

        cfg.dscp_ecn = 8'h00;

        cfg.total_len = 16'(20 + payload_length);

        cfg.id_field = 16'h1234;

        cfg.flags_frag = 16'h0000;

        cfg.ttl      = 8'd64;
        cfg.protocol = 8'd17;

        //
        // RX checksum isn't validated by this module.
        //
        cfg.checksum = 16'hABCD;

        cfg.src_ip = 32'hC0_A8_01_0A;
        cfg.dst_ip = LOCAL_IP;

        return cfg;

    endfunction


    // ================================================================
    // Packet builder
    // ================================================================

    task automatic build_packet(
        input  ipv4_cfg_t cfg,
        input  byte_t     payload[$],
        input  byte_t     trailing_bytes[$],
        output byte_t     packet[$]
    );

        packet.delete();

        // Byte 0
        packet.push_back({
            cfg.version,
            cfg.ihl
        });

        // Byte 1
        packet.push_back(
            cfg.dscp_ecn
        );

        // Bytes 2-3: total length
        packet.push_back(
            cfg.total_len[15:8]
        );

        packet.push_back(
            cfg.total_len[7:0]
        );

        // Bytes 4-5: identification
        packet.push_back(
            cfg.id_field[15:8]
        );

        packet.push_back(
            cfg.id_field[7:0]
        );

        // Bytes 6-7: flags + fragment offset
        packet.push_back(
            cfg.flags_frag[15:8]
        );

        packet.push_back(
            cfg.flags_frag[7:0]
        );

        // Byte 8: TTL
        packet.push_back(
            cfg.ttl
        );

        // Byte 9: protocol
        packet.push_back(
            cfg.protocol
        );

        // Bytes 10-11: checksum
        packet.push_back(
            cfg.checksum[15:8]
        );

        packet.push_back(
            cfg.checksum[7:0]
        );

        // Bytes 12-15: source IP
        packet.push_back(
            cfg.src_ip[31:24]
        );

        packet.push_back(
            cfg.src_ip[23:16]
        );

        packet.push_back(
            cfg.src_ip[15:8]
        );

        packet.push_back(
            cfg.src_ip[7:0]
        );

        // Bytes 16-19: destination IP
        packet.push_back(
            cfg.dst_ip[31:24]
        );

        packet.push_back(
            cfg.dst_ip[23:16]
        );

        packet.push_back(
            cfg.dst_ip[15:8]
        );

        packet.push_back(
            cfg.dst_ip[7:0]
        );

        // IP payload
        for (int i = 0; i < payload.size(); i++)
            packet.push_back(
                payload[i]
            );

        //
        // Bytes physically present after IPv4 total_len.
        //
        // These model Ethernet padding.
        //
        for (int i = 0; i < trailing_bytes.size(); i++)
            packet.push_back(
                trailing_bytes[i]
            );

    endtask


    // ================================================================
    // Generate expected metadata + payload
    // ================================================================

    task automatic expect_valid_packet(
        input ipv4_cfg_t cfg,
        input byte_t     payload[$]
    );

        t_ipv4_metadata expected;

        expected = '0;

        expected.src_mac = cfg.src_mac;
        expected.dst_mac = cfg.dst_mac;

        expected.version = cfg.version;
        expected.ihl     = cfg.ihl;

        expected.total_len = cfg.total_len;
        expected.id_field  = cfg.id_field;

        expected.frag_offset =
            cfg.flags_frag[12:0];

        expected.ttl      = cfg.ttl;
        expected.protocol = cfg.protocol;

        expected.src_ip = cfg.src_ip;
        expected.dst_ip = cfg.dst_ip;

        expected.payload_len =
            cfg.total_len -
            {cfg.ihl, 2'b00};

        expected_meta_q.push_back(
            expected
        );

        for (int i = 0; i < payload.size(); i++) begin

            payload_expect_t p;

            p.data = payload[i];
            p.last = (
                i == payload.size()-1
            );

            expected_payload_q.push_back(
                p
            );

        end

    endtask


    // ================================================================
    // Payload generators
    // ================================================================

    task automatic random_payload(
        input  int    length,
        output byte_t payload[$]
    );

        payload.delete();

        for (int i = 0; i < length; i++) begin

            payload.push_back(
                $urandom_range(0,255)
            );

        end

    endtask


    task automatic incrementing_payload(
        input  int    length,
        output byte_t payload[$]
    );

        payload.delete();

        for (int i = 0; i < length; i++) begin

            payload.push_back(
                byte'(i)
            );

        end

    endtask


    // ================================================================
    // AXIS input driver
    // ================================================================

    task automatic send_sequence(
        input byte_t data_q[$],
        input bit    last_q[$],
        input int    gap_max
    );

        int gap;

        if (data_q.size() != last_q.size()) begin
            tb_error("TB internal data/TLAST queue size mismatch");
            return;
        end

        for (int i = 0; i < data_q.size(); i++) begin

            gap = (
                gap_max == 0
            ) ? 0 : $urandom_range(0, gap_max);

            if (i == 0) begin

                @(negedge i_clk);

            end
            else begin

                @(negedge i_clk);

                if (gap != 0) begin

                    s_axis_tvalid <= 1'b0;
                    s_axis_tlast  <= 1'b0;

                    repeat (gap)
                        @(negedge i_clk);

                end

            end

            s_axis_tdata  <= data_q[i];
            s_axis_tlast  <= last_q[i];
            s_axis_tvalid <= 1'b1;

            //
            // Hold beat until accepted.
            //
            do begin
                @(posedge i_clk);
            end
            while (!s_axis_tready);

        end

        @(negedge i_clk);

        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;

    endtask


    // ================================================================
    // Send entire packet
    // ================================================================

    task automatic send_packet(
        input ipv4_cfg_t cfg,
        input byte_t     payload[$],
        input byte_t     trailing_bytes[$],
        input int        gap_max
    );

        byte_t packet[$];
        bit    last_q[$];

        build_packet(
            cfg,
            payload,
            trailing_bytes,
            packet
        );

        last_q.delete();

        for (int i = 0; i < packet.size(); i++) begin

            last_q.push_back(
                i == packet.size()-1
            );

        end

        i_src_mac    = cfg.src_mac;
        i_dst_mac    = cfg.dst_mac;
        i_frame_size = 11'(packet.size());

        send_sequence(
            packet,
            last_q,
            gap_max
        );

    endtask


    // ================================================================
    // Send data without TLAST
    // ================================================================

    task automatic send_no_last(
        input byte_t data_q[$]
    );

        bit last_q[$];

        last_q.delete();

        for (int i = 0; i < data_q.size(); i++)
            last_q.push_back(1'b0);

        send_sequence(
            data_q,
            last_q,
            0
        );

    endtask


    // ================================================================
    // Queue status
    // ================================================================

    task automatic wait_for_scoreboard_empty(
        input  int max_cycles,
        output bit success
    );

        success = 1'b0;

        for (int cycle = 0; cycle < max_cycles; cycle++) begin

            @(posedge i_clk);

            if (
                expected_meta_q.size()    == 0 &&
                expected_payload_q.size() == 0
            ) begin

                success = 1'b1;
                break;

            end

        end

    endtask


    task automatic require_scoreboard_empty(
        input int max_cycles
    );

        bit success;

        wait_for_scoreboard_empty(
            max_cycles,
            success
        );

        if (!success) begin

            tb_error(
                $sformatf(
                    "Timeout: still expecting %0d metadata item(s), %0d payload byte(s)",
                    expected_meta_q.size(),
                    expected_payload_q.size()
                )
            );

        end

    endtask


    // ================================================================
    // Wait for metadata valid
    // ================================================================

    task automatic wait_for_metadata_valid();

        bit found;

        found = 1'b0;

        for (int i = 0; i < 200; i++) begin

            @(posedge i_clk);

            if (o_ipv4_meta_valid) begin
                found = 1'b1;
                break;
            end

        end

        if (!found)
            tb_error(
                "Timeout waiting for o_ipv4_meta_valid"
            );

    endtask


    // ================================================================
    // Reset helpers
    // ================================================================

    task automatic reset_dut();

        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        expect_no_outputs        = 1'b0;
        expect_drop_ready        = 1'b0;
        check_stream_ready_rule  = 1'b0;

        scoreboard_enable = 1'b0;

        expected_meta_q.delete();
        expected_payload_q.delete();

        @(negedge i_clk);

        i_n_reset <= 1'b0;

        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        s_axis_tdata  <= '0;
        i_frame_size  <= '0;

        repeat (3)
            @(posedge i_clk);

        @(negedge i_clk);

        i_n_reset <= 1'b1;

        i_ipv4_meta_ready <= 1'b1;
        m_axis_tready     <= 1'b1;

        repeat (2)
            @(posedge i_clk);

        scoreboard_enable = 1'b1;

    endtask


    task automatic assert_reset_and_check();

        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        scoreboard_enable = 1'b0;

        @(negedge i_clk);

        i_n_reset <= 1'b0;

        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;

        #1;

        if (m_axis_tvalid !== 1'b0)
            tb_error(
                "m_axis_tvalid did not clear immediately on reset"
            );

        if (o_ipv4_meta_valid !== 1'b0)
            tb_error(
                "o_ipv4_meta_valid did not clear immediately on reset"
            );

        repeat (2)
            @(posedge i_clk);

        #1;

        if (m_axis_tvalid !== 1'b0)
            tb_error(
                "m_axis_tvalid asserted during reset"
            );

        if (o_ipv4_meta_valid !== 1'b0)
            tb_error(
                "o_ipv4_meta_valid asserted during reset"
            );

        if (o_ipv4_meta !== '0)
            tb_error(
                "o_ipv4_meta did not clear during reset"
            );


        //
        // Optional white-box reset checks.
        //
        // Compile with:
        //
        //   +define+IPV4_RX_WHITEBOX
        //
`ifdef IPV4_RX_WHITEBOX

        if (dut.header_ptr !== '0)
            tb_error(
                "header_ptr did not clear during reset"
            );

        if (dut.payload_ptr !== '0)
            tb_error(
                "payload_ptr did not clear during reset"
            );

        if (dut.state !== 3'd0)
            tb_error(
                "FSM did not return to ST_IDLE during reset"
            );

`endif

        @(negedge i_clk);

        i_n_reset <= 1'b1;

        i_ipv4_meta_ready <= 1'b1;
        m_axis_tready     <= 1'b1;

        repeat (2)
            @(posedge i_clk);

        scoreboard_enable = 1'b1;

    endtask


    // ================================================================
    // Recovery check
    //
    // After malformed/truncated traffic, send a known-good packet.
    // This proves the FSM actually returned to IDLE.
    // ================================================================

    task automatic check_recovery();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        bit success;

        cfg = default_cfg(3);

        cfg.src_mac = 48'hAA_BB_CC_DD_EE_FF;
        cfg.dst_mac = 48'h11_22_33_44_55_66;

        payload.delete();
        trailing.delete();

        payload.push_back(8'hCA);
        payload.push_back(8'hFE);
        payload.push_back(8'h55);

        expect_valid_packet(
            cfg,
            payload
        );

        send_packet(
            cfg,
            payload,
            trailing,
            0
        );

        wait_for_scoreboard_empty(
            300,
            success
        );

        if (!success) begin

            tb_error(
                "DUT failed to recover for following valid packet"
            );

            expected_meta_q.delete();
            expected_payload_q.delete();

            reset_dut();

        end

    endtask


    // ================================================================
    // TEST 1 — Reset
    // ================================================================

    task automatic test_reset();

        start_test("Reset behavior");

        assert_reset_and_check();

        finish_test();

    endtask


    // ================================================================
    // TEST 2 — Standard packet / every metadata field
    // ================================================================

    task automatic test_standard_packet();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("Standard IPv4 packet and metadata extraction");

        reset_dut();

        incrementing_payload(
            37,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        cfg.dst_mac  = 48'h01_23_45_67_89_AB;
        cfg.src_mac  = 48'hFE_DC_BA_98_76_54;

        cfg.dscp_ecn = 8'hA5;

        cfg.id_field = 16'hBEEF;

        cfg.ttl      = 8'h7B;
        cfg.protocol = 8'd17;

        cfg.checksum = 16'h1357;

        cfg.src_ip = 32'h0A_14_1E_28;
        cfg.dst_ip = LOCAL_IP;

        expect_valid_packet(
            cfg,
            payload
        );

        send_packet(
            cfg,
            payload,
            trailing,
            0
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 3 — MAC metadata captured at packet start
    // ================================================================

    task automatic test_mac_capture();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];
        byte_t packet[$];

        byte_t first_byte[$];
        byte_t remainder[$];

        bit remainder_last[$];

        start_test("Ethernet MAC sideband captured with packet");

        reset_dut();

        random_payload(
            8,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        cfg.src_mac = 48'h10_11_12_13_14_15;
        cfg.dst_mac = 48'h20_21_22_23_24_25;

        build_packet(
            cfg,
            payload,
            trailing,
            packet
        );

        expect_valid_packet(
            cfg,
            payload
        );

        //
        // Present original MAC metadata for first byte.
        //
        i_src_mac    = cfg.src_mac;
        i_dst_mac    = cfg.dst_mac;
        i_frame_size = 11'(packet.size());

        first_byte.push_back(
            packet[0]
        );

        send_no_last(
            first_byte
        );

        //
        // Deliberately modify sideband values.
        //
        // DUT should already have captured the original pair.
        //
        i_src_mac = 48'hFF_FF_FF_FF_FF_FF;
        i_dst_mac = 48'h00_00_00_00_00_00;

        for (int i = 1; i < packet.size(); i++) begin

            remainder.push_back(
                packet[i]
            );

            remainder_last.push_back(
                i == packet.size()-1
            );

        end

        send_sequence(
            remainder,
            remainder_last,
            0
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 4 — DF flag accepted
    //
    // DF != fragmentation.
    // MF and fragment offset are what this module rejects.
    // ================================================================

    task automatic test_df_flag_allowed();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("DF flag accepted");

        reset_dut();

        random_payload(
            12,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        //
        // Flags = 010 => DF=1, MF=0.
        //
        cfg.flags_frag = 16'h4000;

        expect_valid_packet(
            cfg,
            payload
        );

        send_packet(
            cfg,
            payload,
            trailing,
            0
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 5 — IPv4 protocol field pass-through
    //
    // ipv4_rx is protocol-agnostic.  It parses byte 9 into metadata but
    // MUST NOT use that field as an acceptance criterion.  ip_dispatch
    // and protocol-specific receivers (for example udp_rx) own protocol
    // selection/validation downstream.
    //
    // Sweep every possible 8-bit protocol value to make accidental
    // UDP-only filtering impossible to hide.
    // ================================================================

    task automatic test_protocol_passthrough();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("All IPv4 protocol values are passed through");

        reset_dut();

        random_payload(
            7,
            payload
        );

        trailing.delete();

        random_m_ready_enable     = 1'b1;
        random_meta_ready_enable = 1'b1;

        for (int protocol = 0; protocol < 256; protocol++) begin

            current_subcase =
                $sformatf(
                    "protocol=%0d (0x%02h)",
                    protocol,
                    protocol[7:0]
                );

            cfg = default_cfg(
                payload.size()
            );

            cfg.protocol = protocol[7:0];
            cfg.id_field = 16'(protocol);
            cfg.src_ip   = 32'h0A_00_00_00 | protocol[7:0];

            expect_valid_packet(
                cfg,
                payload
            );

            send_packet(
                cfg,
                payload,
                trailing,
                $urandom_range(0,2)
            );

            require_scoreboard_empty(
                LARGE_TIMEOUT
            );

        end

        current_subcase = "";

        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        m_axis_tready     = 1'b1;
        i_ipv4_meta_ready = 1'b1;

        finish_test();

    endtask


    // ================================================================
    // TEST 6 — Layer-4 payload is opaque to ipv4_rx
    //
    // These payloads intentionally look like malformed UDP headers.
    // ipv4_rx must not inspect source/destination ports, UDP length, or
    // UDP checksum.  It only strips the IPv4 header and forwards exactly
    // total_len-IHL*4 bytes to ip_dispatch / the next layer.
    // ================================================================

    task automatic test_transport_payload_opaque();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("Layer-4 payload is opaque to ipv4_rx");

        reset_dut();

        trailing.delete();

        for (int n = 0; n < 5; n++) begin

            payload.delete();

            case (n)

                // UDP-looking header with illegal UDP length 0.
                0: begin
                    payload.push_back(8'h12);
                    payload.push_back(8'h34);
                    payload.push_back(8'h0F);
                    payload.push_back(8'hA0);
                    payload.push_back(8'h00);
                    payload.push_back(8'h00);
                    payload.push_back(8'hBE);
                    payload.push_back(8'hEF);
                end

                // UDP-looking header with illegal UDP length 7 (< 8).
                1: begin
                    payload.push_back(8'h00);
                    payload.push_back(8'h01);
                    payload.push_back(8'hFF);
                    payload.push_back(8'hFF);
                    payload.push_back(8'h00);
                    payload.push_back(8'h07);
                    payload.push_back(8'h00);
                    payload.push_back(8'h00);
                end

                // UDP-looking header declares more bytes than IP carries.
                2: begin
                    payload.push_back(8'hCA);
                    payload.push_back(8'hFE);
                    payload.push_back(8'hBA);
                    payload.push_back(8'hBE);
                    payload.push_back(8'h12);
                    payload.push_back(8'h34);
                    payload.push_back(8'h55);
                    payload.push_back(8'hAA);
                    payload.push_back(8'hDE);
                    payload.push_back(8'hAD);
                    payload.push_back(8'hBE);
                    payload.push_back(8'hEF);
                end

                // Arbitrary ports/checksum and one data byte.
                3: begin
                    payload.push_back(8'hFF);
                    payload.push_back(8'hFF);
                    payload.push_back(8'h00);
                    payload.push_back(8'h00);
                    payload.push_back(8'h00);
                    payload.push_back(8'h09);
                    payload.push_back(8'h12);
                    payload.push_back(8'h34);
                    payload.push_back(8'hA5);
                end

                // Too short to even contain a transport header.  Still a
                // legal generic IPv4 payload from ipv4_rx's perspective.
                default: begin
                    payload.push_back(8'h11);
                    payload.push_back(8'h22);
                    payload.push_back(8'h33);
                end

            endcase

            current_subcase =
                $sformatf(
                    "opaque L4 case %0d, payload_len=%0d",
                    n,
                    payload.size()
                );

            cfg = default_cfg(
                payload.size()
            );

            // Use UDP's protocol number deliberately.  Malformed UDP
            // contents are not ipv4_rx's responsibility.
            cfg.protocol = 8'd17;

            expect_valid_packet(
                cfg,
                payload
            );

            send_packet(
                cfg,
                payload,
                trailing,
                $urandom_range(0,3)
            );

            require_scoreboard_empty(
                DEFAULT_TIMEOUT
            );

        end

        current_subcase = "";

        finish_test();

    endtask


    // ================================================================
    // TEST 7 — Arbitrary byte 1/checksum are ignored
    // ================================================================

    task automatic test_ignored_header_fields();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("DSCP/ECN and checksum ignored");

        reset_dut();

        random_payload(
            9,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        cfg.dscp_ecn = 8'hFF;
        cfg.checksum = 16'h0000;

        expect_valid_packet(
            cfg,
            payload
        );

        send_packet(
            cfg,
            payload,
            trailing,
            2
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        cfg = default_cfg(
            payload.size()
        );

        cfg.dscp_ecn = 8'h5A;
        cfg.checksum = 16'hFFFF;

        expect_valid_packet(
            cfg,
            payload
        );

        send_packet(
            cfg,
            payload,
            trailing,
            2
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 8 — Invalid version
    // ================================================================

    task automatic test_invalid_version();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("Invalid IPv4 version");

        reset_dut();

        random_payload(
            20,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        cfg.version = 4'd6;

        expect_no_outputs = 1'b1;

        send_packet(
            cfg,
            payload,
            trailing,
            2
        );

        repeat (3)
            @(posedge i_clk);

        expect_no_outputs = 1'b0;

        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 9 — Invalid IHL values
    // ================================================================

    task automatic test_invalid_ihl();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        int ihl_values[4];

        start_test("Invalid IHL / unsupported options");

        reset_dut();

        random_payload(
            12,
            payload
        );

        trailing.delete();

        ihl_values[0] = 0;
        ihl_values[1] = 4;
        ihl_values[2] = 6;
        ihl_values[3] = 15;

        for (int n = 0; n < 4; n++) begin

            current_subcase =
                $sformatf(
                    "IHL=%0d",
                    ihl_values[n]
                );

            cfg = default_cfg(
                payload.size()
            );

            cfg.ihl =
                ihl_values[n][3:0];

            expect_no_outputs = 1'b1;

            send_packet(
                cfg,
                payload,
                trailing,
                1
            );

            repeat (2)
                @(posedge i_clk);

            expect_no_outputs = 1'b0;

            check_recovery();

        end

        current_subcase = "";

        finish_test();

    endtask


    // ================================================================
    // TEST 10 — total_len < 20
    // ================================================================

    task automatic test_invalid_total_length();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        int invalid_lengths[5];

        start_test("Invalid IPv4 total length");

        reset_dut();

        random_payload(
            10,
            payload
        );

        trailing.delete();

        invalid_lengths[0] = 0;
        invalid_lengths[1] = 1;
        invalid_lengths[2] = 4;
        invalid_lengths[3] = 18;
        invalid_lengths[4] = 19;

        for (int n = 0; n < 5; n++) begin

            current_subcase =
                $sformatf(
                    "total_len=%0d",
                    invalid_lengths[n]
                );

            cfg = default_cfg(
                payload.size()
            );

            cfg.total_len =
                invalid_lengths[n];

            expect_no_outputs = 1'b1;

            send_packet(
                cfg,
                payload,
                trailing,
                2
            );

            repeat (2)
                @(posedge i_clk);

            expect_no_outputs = 1'b0;

            check_recovery();

        end

        current_subcase = "";

        finish_test();

    endtask


    // ================================================================
    // TEST 11 — MF rejection
    // ================================================================

    task automatic test_mf_flag();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("More Fragments flag rejection");

        reset_dut();

        random_payload(
            16,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        //
        // MF = 1
        //
        cfg.flags_frag = 16'h2000;

        expect_no_outputs = 1'b1;

        send_packet(
            cfg,
            payload,
            trailing,
            0
        );

        repeat (3)
            @(posedge i_clk);

        expect_no_outputs = 1'b0;

        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 12 — Fragment offset rejection
    // ================================================================

    task automatic test_fragment_offset();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        logic [12:0] offsets[4];

        start_test("Nonzero fragment offset rejection");

        reset_dut();

        random_payload(
            16,
            payload
        );

        trailing.delete();

        offsets[0] = 13'h0001;
        offsets[1] = 13'h0002;
        offsets[2] = 13'h0100;
        offsets[3] = 13'h1FFF;

        for (int n = 0; n < 4; n++) begin

            current_subcase =
                $sformatf(
                    "offset=0x%04h",
                    offsets[n]
                );

            cfg = default_cfg(
                payload.size()
            );

            cfg.flags_frag[12:0] =
                offsets[n];

            expect_no_outputs = 1'b1;

            send_packet(
                cfg,
                payload,
                trailing,
                2
            );

            repeat (2)
                @(posedge i_clk);

            expect_no_outputs = 1'b0;

            check_recovery();

        end

        current_subcase = "";

        finish_test();

    endtask


    // ================================================================
    // TEST 13 — Wrong destination IP
    // ================================================================

    task automatic test_wrong_destination_ip();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        logic [31:0] wrong_ips[4];

        start_test("Destination IP filtering");

        reset_dut();

        random_payload(
            8,
            payload
        );

        trailing.delete();

        wrong_ips[0] = 32'hC0_A8_01_33;
        wrong_ips[1] = 32'h00_00_00_00;
        wrong_ips[2] = 32'hFF_FF_FF_FF;
        wrong_ips[3] = 32'h0A_00_00_01;

        for (int n = 0; n < 4; n++) begin

            current_subcase =
                $sformatf(
                    "dst_ip=%08h",
                    wrong_ips[n]
                );

            cfg = default_cfg(
                payload.size()
            );

            cfg.dst_ip =
                wrong_ips[n];

            expect_no_outputs = 1'b1;

            send_packet(
                cfg,
                payload,
                trailing,
                1
            );

            repeat (2)
                @(posedge i_clk);

            expect_no_outputs = 1'b0;

            check_recovery();

        end

        current_subcase = "";

        finish_test();

    endtask


    // ================================================================
    // TEST 14 — Explicit DROP drain
    //
    // Downstream readiness is deliberately zero.
    // DROP must still consume incoming bytes.
    // ================================================================

    task automatic test_drop_drain();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];
        byte_t packet[$];

        byte_t first[$];
        byte_t remainder[$];

        bit remainder_last[$];

        start_test("ST_DROP drains packet independently of downstream");

        reset_dut();

        random_payload(
            40,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        cfg.version = 6;

        build_packet(
            cfg,
            payload,
            trailing,
            packet
        );

        i_src_mac    = cfg.src_mac;
        i_dst_mac    = cfg.dst_mac;
        i_frame_size = 11'(packet.size());

        //
        // Downstream cannot accept anything.
        //
        i_ipv4_meta_ready = 1'b0;
        m_axis_tready     = 1'b0;

        first.push_back(
            packet[0]
        );

        expect_no_outputs = 1'b1;

        //
        // Invalid version gets consumed.
        //
        send_no_last(
            first
        );

        expect_drop_ready = 1'b1;

        for (int i = 1; i < packet.size(); i++) begin

            remainder.push_back(
                packet[i]
            );

            remainder_last.push_back(
                i == packet.size()-1
            );

        end

        send_sequence(
            remainder,
            remainder_last,
            3
        );

        expect_drop_ready  = 1'b0;
        expect_no_outputs  = 1'b0;

        i_ipv4_meta_ready = 1'b1;
        m_axis_tready     = 1'b1;

        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 15 — EVERY header truncation position
    //
    // TLAST on bytes:
    //
    //   0 .. 18
    //
    // Byte 19 is a complete 20-byte header and is tested separately.
    // ================================================================

    task automatic test_every_header_truncation();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];
        byte_t packet[$];

        byte_t runt[$];
        bit    runt_last[$];

        start_test("Truncated header at every byte");

        reset_dut();

        random_payload(
            8,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        build_packet(
            cfg,
            payload,
            trailing,
            packet
        );

        for (int last_byte = 0; last_byte <= 18; last_byte++) begin

            current_subcase =
                $sformatf(
                    "TLAST on header byte %0d",
                    last_byte
                );

            runt.delete();
            runt_last.delete();

            i_src_mac = cfg.src_mac;
            i_dst_mac = cfg.dst_mac;

            for (int i = 0; i <= last_byte; i++) begin

                runt.push_back(
                    packet[i]
                );

                runt_last.push_back(
                    i == last_byte
                );

            end

            // Advertise the actual number of physical IPv4-side bytes
            // in this intentionally truncated frame.
            i_frame_size = 11'(runt.size());

            expect_no_outputs = 1'b1;

            send_sequence(
                runt,
                runt_last,
                $urandom_range(0,2)
            );

            repeat (3)
                @(posedge i_clk);

            expect_no_outputs = 1'b0;

            //
            // Critical:
            // the next packet must start from a clean IDLE state.
            //
            check_recovery();

        end

        current_subcase = "";

        finish_test();

    endtask


    // ================================================================
    // TEST 16 — Metadata backpressure
    // ================================================================

    task automatic test_metadata_backpressure();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        t_ipv4_metadata held_meta;

        start_test("IPv4 metadata backpressure");

        reset_dut();

        random_payload(
            20,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        expect_valid_packet(
            cfg,
            payload
        );

        i_ipv4_meta_ready = 1'b0;
        m_axis_tready     = 1'b1;

        fork

            begin

                send_packet(
                    cfg,
                    payload,
                    trailing,
                    0
                );

            end


            begin

                wait_for_metadata_valid();

                #1;

                held_meta = o_ipv4_meta;

                //
                // ST_META must block upstream payload.
                //
                if (s_axis_tready !== 1'b0)
                    tb_error(
                        "s_axis_tready not low during metadata stall"
                    );

                if (m_axis_tvalid !== 1'b0)
                    tb_error(
                        "Payload appeared before metadata handshake"
                    );

                repeat (12) begin

                    @(posedge i_clk);
                    #1;

                    if (!o_ipv4_meta_valid)
                        tb_error(
                            "Metadata valid dropped before handshake"
                        );

                    if (o_ipv4_meta !== held_meta)
                        tb_error(
                            "Metadata changed while meta_ready=0"
                        );

                    if (s_axis_tready !== 1'b0)
                        tb_error(
                            "Upstream was not stalled during metadata wait"
                        );

                    if (m_axis_tvalid)
                        tb_error(
                            "Payload leaked before metadata accepted"
                        );

                end

                @(negedge i_clk);

                i_ipv4_meta_ready <= 1'b1;

            end

        join

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 17 — Payload backpressure
    // ================================================================

    task automatic test_payload_backpressure();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        int meta_before;

        start_test("Random payload backpressure");

        reset_dut();

        incrementing_payload(
            128,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        expect_valid_packet(
            cfg,
            payload
        );

        i_ipv4_meta_ready = 1'b1;

        meta_before =
            meta_handshake_count;

        //
        // Start downstream blocked.
        //
        m_axis_tready = 1'b0;

        fork

            begin

                send_packet(
                    cfg,
                    payload,
                    trailing,
                    0
                );

            end


            begin

                //
                // Wait for metadata handshake.
                //
                while (
                    meta_handshake_count ==
                    meta_before
                )
                    @(posedge i_clk);

                check_stream_ready_rule = 1'b1;

                //
                // With m_axis empty, one input byte may be accepted into
                // the output register despite TREADY=0.
                //
                begin

                    bit found_valid;

                    found_valid = 1'b0;

                    for (int i = 0; i < 100; i++) begin

                        @(posedge i_clk);

                        if (m_axis_tvalid) begin
                            found_valid = 1'b1;
                            break;
                        end

                    end

                    if (!found_valid)
                        tb_error(
                            "Output TVALID never asserted under downstream stall"
                        );

                end

                //
                // Hold hard stall.
                //
                repeat (8)
                    @(posedge i_clk);

                //
                // Randomize remainder.
                //
                random_m_ready_enable = 1'b1;

            end

        join

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        random_m_ready_enable  = 1'b0;
        check_stream_ready_rule = 1'b0;

        m_axis_tready = 1'b1;

        finish_test();

    endtask


    // ================================================================
    // TEST 18 — Upstream starvation
    // ================================================================

    task automatic test_upstream_starvation();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("Random upstream TVALID gaps");

        reset_dut();

        incrementing_payload(
            100,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        expect_valid_packet(
            cfg,
            payload
        );

        i_ipv4_meta_ready = 1'b1;
        m_axis_tready     = 1'b1;

        //
        // 0-5 idle cycles can occur between ANY input bytes.
        //
        send_packet(
            cfg,
            payload,
            trailing,
            5
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 19 — TLAST while TVALID=0
    //
    // Prevents code from treating raw TLAST as a transfer.
    // ================================================================

    task automatic test_tlast_without_tvalid();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];
        byte_t packet[$];

        byte_t prefix[$];
        byte_t remainder[$];

        bit remainder_last[$];

        start_test("TLAST ignored when TVALID=0");

        reset_dut();

        random_payload(
            10,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        build_packet(
            cfg,
            payload,
            trailing,
            packet
        );

        expect_valid_packet(
            cfg,
            payload
        );

        i_src_mac    = cfg.src_mac;
        i_dst_mac    = cfg.dst_mac;
        i_frame_size = 11'(packet.size());

        //
        // Accept bytes 0..6 normally.
        //
        for (int i = 0; i < 7; i++)
            prefix.push_back(
                packet[i]
            );

        send_no_last(
            prefix
        );

        //
        // Wiggle TLAST and data with TVALID=0.
        //
        repeat (8) begin

            @(negedge i_clk);

            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b1;
            s_axis_tdata  <= $urandom_range(0,255);

        end

        //
        // Resume byte 7.
        //
        for (int i = 7; i < packet.size(); i++) begin

            remainder.push_back(
                packet[i]
            );

            remainder_last.push_back(
                i == packet.size()-1
            );

        end

        send_sequence(
            remainder,
            remainder_last,
            2
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 20 — One-byte payload
    // ================================================================

    task automatic test_one_byte_payload();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("One-byte IP payload");

        reset_dut();

        payload.push_back(
            8'hA5
        );

        trailing.delete();

        cfg = default_cfg(1);

        expect_valid_packet(
            cfg,
            payload
        );

        send_packet(
            cfg,
            payload,
            trailing,
            0
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 21 — Zero-byte payload / TLAST on header byte 19
    // ================================================================

    task automatic test_zero_payload();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("Zero-byte payload");

        reset_dut();

        payload.delete();
        trailing.delete();

        cfg = default_cfg(0);

        expect_valid_packet(
            cfg,
            payload
        );

        send_packet(
            cfg,
            payload,
            trailing,
            0
        );

        //
        // Only metadata is expected.
        //
        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        repeat (5) begin

            @(posedge i_clk);

            if (m_axis_tvalid)
                tb_error(
                    "Payload output generated for total_len=20 packet"
                );

        end

        //
        // This is critical: zero-length packets must not leave the FSM
        // stranded waiting for nonexistent payload.
        //
        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 22 — Ethernet padding after zero-length IP payload
    //
    // IP total_len = 20.
    //
    // Physical Ethernet payload may still contain padding.
    // None of the padding belongs on the IP payload output.
    // ================================================================

    task automatic test_zero_payload_with_padding();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t padding[$];

        start_test("Zero-byte payload with Ethernet padding");

        reset_dut();

        payload.delete();

        //
        // Ethernet minimum data field = 46 bytes.
        //
        // IPv4 packet = 20 bytes.
        //
        // Therefore 26 pad bytes can physically follow it.
        //
        for (int i = 0; i < 26; i++)
            padding.push_back(
                8'h00
            );

        cfg = default_cfg(0);

        expect_valid_packet(
            cfg,
            payload
        );

        send_packet(
            cfg,
            payload,
            padding,
            0
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        repeat (5)
            @(posedge i_clk);

        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 23 — Small payload followed by Ethernet padding
    //
    // TLAST on m_axis MUST correspond to IP payload length,
    // not Ethernet TLAST.
    // ================================================================

    task automatic test_payload_with_padding();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t padding[$];

        start_test("IP payload length excludes Ethernet padding");

        reset_dut();

        payload.push_back(8'h11);
        payload.push_back(8'h22);
        payload.push_back(8'h33);
        payload.push_back(8'h44);
        payload.push_back(8'h55);

        //
        // IPv4 packet = 25 bytes.
        // To make Ethernet data field 46 bytes:
        //
        // padding = 21 bytes.
        //
        for (int i = 0; i < 21; i++)
            padding.push_back(
                8'hEE
            );

        cfg = default_cfg(
            payload.size()
        );

        expect_valid_packet(
            cfg,
            payload
        );

        send_packet(
            cfg,
            payload,
            padding,
            1
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 24 — Maximum normal IPv4 payload for Ethernet MTU
    //
    // 1500-byte IP packet:
    //
    //   20 header
    // + 1480 payload
    // ================================================================

    task automatic test_maximum_payload();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("1480-byte IPv4 payload");

        reset_dut();

        random_payload(
            1480,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        expect_valid_packet(
            cfg,
            payload
        );

        random_m_ready_enable     = 1'b1;
        random_meta_ready_enable = 1'b1;

        send_packet(
            cfg,
            payload,
            trailing,
            2
        );

        require_scoreboard_empty(
            LARGE_TIMEOUT
        );

        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        m_axis_tready       = 1'b1;
        i_ipv4_meta_ready   = 1'b1;

        finish_test();

    endtask


    // ================================================================
    // Continuous two-packet sender
    //
    // TVALID never intentionally goes low between packets.
    // ================================================================

    task automatic send_two_packets_contiguous(
        input ipv4_cfg_t cfg1,
        input byte_t     payload1[$],

        input ipv4_cfg_t cfg2,
        input byte_t     payload2[$]
    );

        byte_t no_tail[$];

        byte_t packet1[$];
        byte_t packet2[$];

        no_tail.delete();

        build_packet(
            cfg1,
            payload1,
            no_tail,
            packet1
        );

        build_packet(
            cfg2,
            payload2,
            no_tail,
            packet2
        );

        //
        // First frame.
        //
        i_src_mac    = cfg1.src_mac;
        i_dst_mac    = cfg1.dst_mac;
        i_frame_size = 11'(packet1.size());

        for (int i = 0; i < packet1.size(); i++) begin

            @(negedge i_clk);

            s_axis_tdata  <= packet1[i];
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= (
                i == packet1.size()-1
            );

            do begin
                @(posedge i_clk);
            end
            while (!s_axis_tready);

        end


        //
        // NO TVALID GAP.
        //
        // Sideband MAC metadata changes simultaneously with first byte
        // of packet 2.
        //
        i_src_mac    = cfg2.src_mac;
        i_dst_mac    = cfg2.dst_mac;
        i_frame_size = 11'(packet2.size());

        for (int i = 0; i < packet2.size(); i++) begin

            @(negedge i_clk);

            s_axis_tdata  <= packet2[i];
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= (
                i == packet2.size()-1
            );

            do begin
                @(posedge i_clk);
            end
            while (!s_axis_tready);

        end

        @(negedge i_clk);

        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;

    endtask


    // ================================================================
    // TEST 25 — Back-to-back packets with no source bubble
    // ================================================================

    task automatic test_back_to_back_packets();

        ipv4_cfg_t cfg1;
        ipv4_cfg_t cfg2;

        byte_t payload1[$];
        byte_t payload2[$];

        start_test("Back-to-back valid IPv4 packets");

        reset_dut();

        random_payload(
            31,
            payload1
        );

        random_payload(
            47,
            payload2
        );

        cfg1 = default_cfg(
            payload1.size()
        );

        cfg1.src_mac = 48'h10_10_10_10_10_10;
        cfg1.dst_mac = 48'h20_20_20_20_20_20;

        cfg1.src_ip   = 32'h0A_00_00_01;
        cfg1.id_field = 16'h1111;


        cfg2 = default_cfg(
            payload2.size()
        );

        cfg2.src_mac = 48'h30_30_30_30_30_30;
        cfg2.dst_mac = 48'h40_40_40_40_40_40;

        cfg2.src_ip   = 32'h0A_00_00_02;
        cfg2.id_field = 16'h2222;


        expect_valid_packet(
            cfg1,
            payload1
        );

        expect_valid_packet(
            cfg2,
            payload2
        );

        i_ipv4_meta_ready = 1'b1;
        m_axis_tready     = 1'b1;

        send_two_packets_contiguous(
            cfg1,
            payload1,
            cfg2,
            payload2
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 26 — Reset during header
    // ================================================================

    task automatic test_reset_during_header();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];
        byte_t packet[$];
        byte_t prefix[$];

        start_test("Reset during header parsing");

        reset_dut();

        scoreboard_enable = 1'b0;

        random_payload(
            20,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        build_packet(
            cfg,
            payload,
            trailing,
            packet
        );

        i_src_mac    = cfg.src_mac;
        i_dst_mac    = cfg.dst_mac;
        i_frame_size = 11'(packet.size());

        //
        // Stop after byte 8.
        //
        for (int i = 0; i < 9; i++)
            prefix.push_back(
                packet[i]
            );

        send_no_last(
            prefix
        );

        assert_reset_and_check();

        scoreboard_enable = 1'b1;

        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 27 — Reset during metadata stall
    // ================================================================

    task automatic test_reset_during_metadata();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];
        byte_t packet[$];
        byte_t header[$];

        start_test("Reset during metadata handshake");

        reset_dut();

        scoreboard_enable = 1'b0;

        random_payload(
            16,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        build_packet(
            cfg,
            payload,
            trailing,
            packet
        );

        i_src_mac    = cfg.src_mac;
        i_dst_mac    = cfg.dst_mac;
        i_frame_size = 11'(packet.size());

        i_ipv4_meta_ready = 1'b0;

        //
        // Send complete header without TLAST.
        //
        for (int i = 0; i < 20; i++)
            header.push_back(
                packet[i]
            );

        send_no_last(
            header
        );

        wait_for_metadata_valid();

        if (!o_ipv4_meta_valid)
            tb_error(
                "Failed to reach metadata phase before reset"
            );

        assert_reset_and_check();

        scoreboard_enable = 1'b1;

        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 28 — Reset during payload stream
    // ================================================================

    task automatic test_reset_during_stream();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];
        byte_t packet[$];
        byte_t header[$];

        start_test("Reset during payload streaming");

        reset_dut();

        scoreboard_enable = 1'b0;

        random_payload(
            32,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        build_packet(
            cfg,
            payload,
            trailing,
            packet
        );

        i_src_mac    = cfg.src_mac;
        i_dst_mac    = cfg.dst_mac;
        i_frame_size = 11'(packet.size());

        i_ipv4_meta_ready = 1'b1;

        for (int i = 0; i < 20; i++)
            header.push_back(
                packet[i]
            );

        send_no_last(
            header
        );

        //
        // Wait enough for metadata handshake.
        //
        repeat (5)
            @(posedge i_clk);

        //
        // Allow one input payload byte into DUT's output buffer while
        // blocking its downstream acceptance.
        //
        @(negedge i_clk);

        m_axis_tready <= 1'b0;

        s_axis_tdata  <= payload[0];
        s_axis_tvalid <= 1'b1;
        s_axis_tlast  <= 1'b0;

        do begin
            @(posedge i_clk);
        end
        while (!s_axis_tready);

        @(negedge i_clk);

        s_axis_tvalid <= 1'b0;

        //
        // m_axis_tvalid should now eventually be visible.
        //
        begin

            bit found;

            found = 1'b0;

            for (int i = 0; i < 100; i++) begin

                @(posedge i_clk);

                if (m_axis_tvalid) begin
                    found = 1'b1;
                    break;
                end

            end

            if (!found)
                tb_error(
                    "Could not establish active payload stream before reset"
                );

        end

        assert_reset_and_check();

        scoreboard_enable = 1'b1;

        m_axis_tready = 1'b1;

        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 29 — Reset while dropping
    // ================================================================

    task automatic test_reset_during_drop();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];
        byte_t packet[$];
        byte_t prefix[$];

        start_test("Reset during ST_DROP");

        reset_dut();

        scoreboard_enable = 1'b0;

        random_payload(
            20,
            payload
        );

        trailing.delete();

        cfg = default_cfg(
            payload.size()
        );

        cfg.version = 6;

        build_packet(
            cfg,
            payload,
            trailing,
            packet
        );

        i_src_mac    = cfg.src_mac;
        i_dst_mac    = cfg.dst_mac;
        i_frame_size = 11'(packet.size());

        //
        // Invalid byte 0 + several following bytes, without TLAST.
        //
        for (int i = 0; i < 8; i++)
            prefix.push_back(
                packet[i]
            );

        send_no_last(
            prefix
        );

        assert_reset_and_check();

        scoreboard_enable = 1'b1;

        check_recovery();

        finish_test();

    endtask


    // ================================================================
    // TEST 30 — Many sequential good packets
    // ================================================================

    task automatic test_many_packets();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("100 sequential valid IPv4 packets");

        reset_dut();

        trailing.delete();

        i_ipv4_meta_ready = 1'b1;
        m_axis_tready     = 1'b1;

        for (int packet_num = 0; packet_num < 100; packet_num++) begin

            random_payload(
                $urandom_range(1,128),
                payload
            );

            cfg = default_cfg(
                payload.size()
            );

            cfg.src_mac = {
                16'h0002,
                $urandom()
            };

            cfg.dst_mac = {
                16'h0004,
                $urandom()
            };

            cfg.id_field =
                packet_num[15:0];

            cfg.src_ip =
                32'h0A_00_00_00 |
                (packet_num + 1);

            expect_valid_packet(
                cfg,
                payload
            );

            send_packet(
                cfg,
                payload,
                trailing,
                $urandom_range(0,2)
            );

            require_scoreboard_empty(
                DEFAULT_TIMEOUT
            );

        end

        finish_test();

    endtask


    // ================================================================
    // TEST 31 — Randomized regression
    // ================================================================

    task automatic test_random_regression();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        int packet_kind;
        int payload_length;
        bit packet_should_pass;

        start_test("1000-packet constrained-random regression");

        reset_dut();

        trailing.delete();

        random_m_ready_enable     = 1'b1;
        random_meta_ready_enable = 1'b1;

        for (int n = 0; n < 1000; n++) begin

            current_subcase =
                $sformatf(
                    "random packet %0d",
                    n
                );

            payload_length =
                $urandom_range(1,128);

            random_payload(
                payload_length,
                payload
            );

            cfg = default_cfg(
                payload.size()
            );

            cfg.id_field =
                $urandom();

            cfg.ttl =
                $urandom_range(1,255);

            // Protocol is metadata only at this layer.  Randomize it for
            // every baseline packet so valid traffic continuously proves
            // ipv4_rx is not accidentally acting as a UDP filter.
            cfg.protocol = $urandom_range(0,255);

            cfg.checksum =
                $urandom();

            cfg.src_ip =
                $urandom();

            cfg.src_mac = {
                $urandom(),
                $urandom()
            };

            cfg.dst_mac = {
                $urandom(),
                $urandom()
            };

            packet_kind =
                $urandom_range(0,9);

            packet_should_pass = 1'b0;

            case (packet_kind)

                // ----------------------------------------------------
                // Valid
                // ----------------------------------------------------

                0,
                1: begin

                    expect_valid_packet(
                        cfg,
                        payload
                    );

                    packet_should_pass = 1'b1;

                end


                // ----------------------------------------------------
                // Valid DF
                // ----------------------------------------------------

                2: begin

                    cfg.flags_frag =
                        16'h4000;

                    expect_valid_packet(
                        cfg,
                        payload
                    );

                    packet_should_pass = 1'b1;

                end


                // ----------------------------------------------------
                // Bad version
                // ----------------------------------------------------

                3: begin

                    cfg.version = 6;

                    expect_no_outputs = 1'b1;

                end


                // ----------------------------------------------------
                // Bad IHL
                // ----------------------------------------------------

                4: begin

                    cfg.ihl = 6;

                    expect_no_outputs = 1'b1;

                end


                // ----------------------------------------------------
                // Invalid length
                // ----------------------------------------------------

                5: begin

                    cfg.total_len =
                        $urandom_range(0,19);

                    expect_no_outputs = 1'b1;

                end


                // ----------------------------------------------------
                // Fragment
                // ----------------------------------------------------

                6: begin

                    if ($urandom_range(0,1))
                        cfg.flags_frag = 16'h2000;
                    else
                        cfg.flags_frag =
                            $urandom_range(1,16'h1FFF);

                    expect_no_outputs = 1'b1;

                end


                // ----------------------------------------------------
                // Wrong IP
                // ----------------------------------------------------

                7: begin

                    cfg.dst_ip =
                        LOCAL_IP ^ 32'h0000_0001;

                    expect_no_outputs = 1'b1;

                end


                // ----------------------------------------------------
                // Protocol corner value is still valid IPv4
                // ----------------------------------------------------

                8: begin

                    case ($urandom_range(0,4))
                        0: cfg.protocol = 8'd0;
                        1: cfg.protocol = 8'd1;
                        2: cfg.protocol = 8'd6;
                        3: cfg.protocol = 8'd17;
                        default: cfg.protocol = 8'hFF;
                    endcase

                    expect_valid_packet(
                        cfg,
                        payload
                    );

                    packet_should_pass = 1'b1;

                end


                // ----------------------------------------------------
                // Combined invalid conditions
                // ----------------------------------------------------

                default: begin

                    cfg.version = 6;
                    // Protocol remains arbitrary here; the actual rejection
                    // reasons are invalid IPv4 fields below.
                    cfg.protocol = $urandom_range(0,255);
                    cfg.dst_ip = LOCAL_IP ^ 32'h0101_0101;
                    cfg.flags_frag = 16'h2001;

                    expect_no_outputs = 1'b1;

                end

            endcase


            send_packet(
                cfg,
                payload,
                trailing,
                $urandom_range(0,4)
            );


            if (packet_should_pass) begin

                require_scoreboard_empty(
                    LARGE_TIMEOUT
                );

            end
            else begin

                repeat (3)
                    @(posedge i_clk);

            end

            expect_no_outputs = 1'b0;

        end

        current_subcase = "";

        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        m_axis_tready       = 1'b1;
        i_ipv4_meta_ready   = 1'b1;

        finish_test();

    endtask


    // ================================================================
    // TEST 32 — Counter and payload-length boundary sweep
    //
    // Targets off-by-one errors in total_len/payload_ptr and TLAST
    // generation at binary/counter boundaries, plus the MTU limit.
    // ================================================================

    task automatic test_payload_length_boundaries();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        int lengths[22];

        start_test("IPv4 payload length boundary sweep");

        reset_dut();

        trailing.delete();

        lengths[0]  = 0;
        lengths[1]  = 1;
        lengths[2]  = 2;
        lengths[3]  = 3;
        lengths[4]  = 4;
        lengths[5]  = 5;
        lengths[6]  = 7;
        lengths[7]  = 8;
        lengths[8]  = 15;
        lengths[9]  = 16;
        lengths[10] = 17;
        lengths[11] = 31;
        lengths[12] = 32;
        lengths[13] = 33;
        lengths[14] = 63;
        lengths[15] = 64;
        lengths[16] = 65;
        lengths[17] = 255;
        lengths[18] = 256;
        lengths[19] = 257;
        lengths[20] = 1479;
        lengths[21] = 1480;

        random_m_ready_enable     = 1'b1;
        random_meta_ready_enable = 1'b1;

        for (int n = 0; n < 22; n++) begin

            current_subcase =
                $sformatf(
                    "payload_len=%0d",
                    lengths[n]
                );

            random_payload(
                lengths[n],
                payload
            );

            cfg = default_cfg(
                payload.size()
            );

            cfg.id_field = 16'h8000 + n;
            cfg.src_ip   = 32'h0A_00_10_00 + n;

            expect_valid_packet(
                cfg,
                payload
            );

            send_packet(
                cfg,
                payload,
                trailing,
                $urandom_range(0,3)
            );

            require_scoreboard_empty(
                LARGE_TIMEOUT
            );

        end

        current_subcase = "";

        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        m_axis_tready       = 1'b1;
        i_ipv4_meta_ready   = 1'b1;

        finish_test();

    endtask


    // ================================================================
    // TEST 33 — Declared total length larger than physical frame
    //
    // This directly targets the Day-5 requirement that total_length be
    // consistent with the received frame. The test is intentionally
    // strict: a physically truncated IPv4 packet must be cleanly
    // rejected rather than advertised as a complete packet.
    // ================================================================

    task automatic test_declared_length_exceeds_frame();

        ipv4_cfg_t cfg;

        byte_t declared_payload[$];
        byte_t physical_payload[$];
        byte_t trailing[$];

        int declared_lengths[4];
        int physical_lengths[4];

        start_test("Declared IPv4 length exceeds physical frame");

        reset_dut();

        trailing.delete();

        declared_lengths[0] = 1;
        physical_lengths[0] = 0;

        declared_lengths[1] = 8;
        physical_lengths[1] = 3;

        declared_lengths[2] = 64;
        physical_lengths[2] = 63;

        declared_lengths[3] = 1480;
        physical_lengths[3] = 64;

        for (int n = 0; n < 4; n++) begin

            current_subcase =
                $sformatf(
                    "declared=%0d physical=%0d",
                    declared_lengths[n],
                    physical_lengths[n]
                );

            random_payload(
                declared_lengths[n],
                declared_payload
            );

            physical_payload.delete();

            for (int i = 0; i < physical_lengths[n]; i++)
                physical_payload.push_back(
                    declared_payload[i]
                );

            cfg = default_cfg(
                declared_lengths[n]
            );

            expect_no_outputs = 1'b1;

            send_packet(
                cfg,
                physical_payload,
                trailing,
                $urandom_range(0,2)
            );

            repeat (5)
                @(posedge i_clk);

            expect_no_outputs = 1'b0;

            check_recovery();

        end

        current_subcase = "";

        finish_test();

    endtask


    // ================================================================
    // TEST 34 — Drop-to-good transition with no source bubble
    //
    // Targets a classic FSM weak point: ST_DROP seeing TLAST and the next
    // packet's first byte on the immediately following transfer.
    // ================================================================

    task automatic test_bad_then_good_contiguous();

        ipv4_cfg_t bad_cfg;
        ipv4_cfg_t good_cfg;

        byte_t bad_payload[$];
        byte_t good_payload[$];

        start_test("Bad packet followed immediately by good packet");

        reset_dut();

        random_payload(
            23,
            bad_payload
        );

        random_payload(
            29,
            good_payload
        );

        bad_cfg = default_cfg(
            bad_payload.size()
        );

        // Fail late enough that most header fields have already been seen.
        bad_cfg.dst_ip = LOCAL_IP ^ 32'h0000_0001;
        bad_cfg.src_mac = 48'hBA_D0_00_00_00_01;
        bad_cfg.dst_mac = 48'hBA_D0_00_00_00_02;

        good_cfg = default_cfg(
            good_payload.size()
        );

        good_cfg.src_mac = 48'h60_61_62_63_64_65;
        good_cfg.dst_mac = 48'h70_71_72_73_74_75;
        good_cfg.src_ip   = 32'h0A_55_AA_01;
        good_cfg.id_field = 16'hCAFE;

        // Only packet 2 may produce outputs. Any leakage from packet 1
        // will corrupt these queues and be reported by the scoreboard.
        expect_valid_packet(
            good_cfg,
            good_payload
        );

        i_ipv4_meta_ready = 1'b1;
        m_axis_tready     = 1'b1;

        send_two_packets_contiguous(
            bad_cfg,
            bad_payload,
            good_cfg,
            good_payload
        );

        require_scoreboard_empty(
            DEFAULT_TIMEOUT
        );

        finish_test();

    endtask


    // ================================================================
    // TEST 35 — Combined metadata and payload pressure across packets
    //
    // Exercises independent ready domains over a sequence instead of one
    // isolated packet, stressing retained metadata and stream state.
    // ================================================================

    task automatic test_multi_packet_dual_backpressure();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("Multi-packet metadata + payload backpressure");

        reset_dut();

        trailing.delete();

        random_m_ready_enable     = 1'b1;
        random_meta_ready_enable = 1'b1;

        for (int n = 0; n < 40; n++) begin

            current_subcase =
                $sformatf(
                    "packet=%0d",
                    n
                );

            random_payload(
                $urandom_range(0,256),
                payload
            );

            cfg = default_cfg(
                payload.size()
            );

            cfg.src_mac = {
                16'h0200,
                $urandom()
            };

            cfg.dst_mac = {
                16'h0400,
                $urandom()
            };

            cfg.src_ip   = $urandom();
            cfg.id_field = $urandom();
            cfg.ttl      = $urandom_range(0,255);

            expect_valid_packet(
                cfg,
                payload
            );

            send_packet(
                cfg,
                payload,
                trailing,
                $urandom_range(0,4)
            );

            // Do not reset between packets. Let any state-retention bug
            // accumulate and become visible.
            require_scoreboard_empty(
                LARGE_TIMEOUT
            );

        end

        current_subcase = "";

        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        m_axis_tready       = 1'b1;
        i_ipv4_meta_ready   = 1'b1;

        finish_test();

    endtask


    // ================================================================
    // TEST 36 — Header field extrema accepted when otherwise legal
    //
    // Ensures fields that are parsed/forwarded but not rejected do not
    // accidentally become hidden filters.
    // ================================================================

    task automatic test_legal_header_extrema();

        ipv4_cfg_t cfg;

        byte_t payload[$];
        byte_t trailing[$];

        start_test("Legal IPv4 header extrema");

        reset_dut();

        random_payload(
            11,
            payload
        );

        trailing.delete();

        for (int n = 0; n < 4; n++) begin

            cfg = default_cfg(
                payload.size()
            );

            case (n)
                0: begin
                    current_subcase = "TTL=0 ID=0";
                    cfg.ttl      = 8'h00;
                    cfg.id_field = 16'h0000;
                end

                1: begin
                    current_subcase = "TTL=255 ID=FFFF";
                    cfg.ttl      = 8'hFF;
                    cfg.id_field = 16'hFFFF;
                end

                2: begin
                    current_subcase = "DSCP/ECN=FF checksum=0000";
                    cfg.dscp_ecn = 8'hFF;
                    cfg.checksum = 16'h0000;
                end

                default: begin
                    current_subcase = "DF with extrema";
                    cfg.flags_frag = 16'h4000;
                    cfg.ttl        = 8'h00;
                    cfg.id_field   = 16'hFFFF;
                    cfg.checksum   = 16'hFFFF;
                end
            endcase

            expect_valid_packet(
                cfg,
                payload
            );

            send_packet(
                cfg,
                payload,
                trailing,
                1
            );

            require_scoreboard_empty(
                DEFAULT_TIMEOUT
            );

        end

        current_subcase = "";

        finish_test();

    endtask


    // ================================================================
    // Global watchdog
    // ================================================================

    initial begin

        #50ms;

        $fatal(
            1,
            "GLOBAL IPV4_RX TESTBENCH TIMEOUT"
        );

    end


    // ================================================================
    // Main
    // ================================================================

    initial begin

        int unsigned seed;

        seed = 32'h1F4A_2026;

        if ($value$plusargs("SEED=%d", seed))
            $display(
                "Using user random seed: %0d",
                seed
            );
        else
            $display(
                "Using default random seed: 0x%08h",
                seed
            );

        $srandom(seed);


        // ------------------------------------------------------------
        // Initial signals
        // ------------------------------------------------------------

        i_n_reset = 1'b0;

        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;

        i_src_mac    = '0;
        i_dst_mac    = '0;
        i_frame_size = '0;

        m_axis_tready = 1'b1;

        i_ipv4_meta_ready = 1'b1;

        i_local_ip = LOCAL_IP;

        scoreboard_enable = 1'b0;


        repeat (4)
            @(posedge i_clk);

        @(negedge i_clk);

        i_n_reset = 1'b1;

        scoreboard_enable = 1'b1;

        repeat (2)
            @(posedge i_clk);


        // ============================================================
        // Run directed regression
        // ============================================================

        test_reset();

        test_standard_packet();

        test_mac_capture();

        test_df_flag_allowed();

        test_protocol_passthrough();

        test_transport_payload_opaque();

        test_ignored_header_fields();


        // ------------------------------------------------------------
        // Rejection paths
        // ------------------------------------------------------------

        test_invalid_version();

        test_invalid_ihl();

        test_invalid_total_length();

        test_mf_flag();

        test_fragment_offset();

        test_wrong_destination_ip();

        test_drop_drain();


        // ------------------------------------------------------------
        // Truncation / handshake
        // ------------------------------------------------------------

        test_every_header_truncation();

        test_metadata_backpressure();

        test_payload_backpressure();

        test_upstream_starvation();

        test_tlast_without_tvalid();


        // ------------------------------------------------------------
        // Payload boundary cases
        // ------------------------------------------------------------

        test_one_byte_payload();

        test_zero_payload();

        test_zero_payload_with_padding();

        test_payload_with_padding();

        test_maximum_payload();


        // ------------------------------------------------------------
        // Sequencing
        // ------------------------------------------------------------

        test_back_to_back_packets();


        // ------------------------------------------------------------
        // Reset injection
        // ------------------------------------------------------------

        test_reset_during_header();

        test_reset_during_metadata();

        test_reset_during_stream();

        test_reset_during_drop();


        // ------------------------------------------------------------
        // Stress
        // ------------------------------------------------------------

        test_many_packets();

        test_random_regression();


        // ------------------------------------------------------------
        // Targeted strength / weak-area tests
        // ------------------------------------------------------------

        test_payload_length_boundaries();

        test_declared_length_exceeds_frame();

        test_bad_then_good_contiguous();

        test_multi_packet_dual_backpressure();

        test_legal_header_extrema();


        // ============================================================
        // Final checks
        // ============================================================

        repeat (10)
            @(posedge i_clk);

        if (expected_meta_q.size() != 0)
            tb_error(
                $sformatf(
                    "%0d metadata transaction(s) remain at end",
                    expected_meta_q.size()
                )
            );

        if (expected_payload_q.size() != 0)
            tb_error(
                $sformatf(
                    "%0d payload byte(s) remain at end",
                    expected_payload_q.size()
                )
            );


        // ============================================================
        // Summary
        // ============================================================

        $display("");
        $display("============================================================");
        $display("                    IPV4_RX TEST SUMMARY");
        $display("============================================================");
        $display("Tests run              : %0d", tests_run);
        $display("Tests passed           : %0d", tests_run - tests_failed);
        $display("Tests failed           : %0d", tests_failed);
        $display("Total errors           : %0d", error_count);
        $display("Metadata handshakes    : %0d", meta_handshake_count);
        $display("Payload byte transfers : %0d", payload_handshake_count);
        $display("============================================================");

        if (error_count == 0) begin

            $display("");
            $display("****************************************************");
            $display("*               ALL IPV4_RX TESTS PASSED          *");
            $display("****************************************************");
            $display("");

            $finish;

        end
        else begin

            $fatal(
                1,
                "IPV4_RX TESTBENCH FAILED WITH %0d ERROR(S)",
                error_count
            );

        end

    end

endmodule