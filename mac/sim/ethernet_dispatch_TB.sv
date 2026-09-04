`timescale 1ns / 1ps

import common_pkg::*;

module ethernet_dispatch_TB;

    // ================================================================
    // Configuration
    // ================================================================

    localparam time CLK_PERIOD = 10ns;

    localparam logic [15:0] IPV4_TYPE = 16'h0800;
    localparam logic [15:0] ARP_TYPE  = 16'h0806;

    localparam int SCOREBOARD_TIMEOUT = 5000;

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

    // Frame metadata from rx_frame_buffer
    logic        i_frame_meta_valid;
    logic        o_frame_meta_ready;
    logic [10:0] i_frame_size;

    logic       m_axis_tready;
    logic [7:0] m_axis_tdata;
    logic       m_axis_tvalid;
    logic       m_axis_tlast;

    logic              i_meta_ready;
    logic              o_meta_valid;
    logic [47:0]       o_dst_mac;
    logic [47:0]       o_src_mac;
    t_ethernet_types   o_ethertype;
    logic [10:0]       o_frame_size;


    // ================================================================
    // DUT
    // ================================================================

    ethernet_dispatch dut (
        .i_clk          (i_clk),
        .i_n_reset      (i_n_reset),

        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tlast        (s_axis_tlast),
        .s_axis_tready       (s_axis_tready),

        .i_frame_meta_valid  (i_frame_meta_valid),
        .o_frame_meta_ready  (o_frame_meta_ready),
        .i_frame_size        (i_frame_size),

        .m_axis_tready       (m_axis_tready),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tlast   (m_axis_tlast),

        .i_meta_ready   (i_meta_ready),
        .o_meta_valid   (o_meta_valid),
        .o_dst_mac      (o_dst_mac),
        .o_src_mac      (o_src_mac),
        .o_ethertype    (o_ethertype),
        .o_frame_size   (o_frame_size)
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
    // Scoreboard structures
    // ================================================================

    typedef struct {
        logic [47:0]     dst;
        logic [47:0]     src;
        t_ethernet_types etype;
        logic [10:0]     frame_size; // L3 bytes after 14-byte Ethernet header
    } expected_meta_t;


    typedef struct {
        logic [7:0] data;
        logic       last;
    } expected_payload_t;


    expected_meta_t    expected_meta_q[$];
    expected_payload_t expected_payload_q[$];


    // ================================================================
    // Test bookkeeping
    // ================================================================

    int error_count       = 0;
    int tests_run         = 0;
    int tests_failed      = 0;
    int test_start_errors = 0;

    int meta_hs_count     = 0;
    int payload_hs_count  = 0;

    string current_test;

    bit scoreboard_enable       = 1'b1;
    bit expect_no_outputs       = 1'b0;
    bit expect_drop_ready       = 1'b0;
    bit check_stream_ready_rule = 1'b0;

    bit random_m_ready_enable    = 1'b0;
    bit random_meta_ready_enable = 1'b0;


    // ================================================================
    // Error / test reporting
    // ================================================================

    task automatic tb_error(input string msg);
        begin
            error_count++;

            $display(
                "[ERROR @ %0t] %s: %s",
                $time,
                current_test,
                msg
            );
        end
    endtask


    task automatic start_test(input string name);
        begin
            current_test      = name;
            test_start_errors = error_count;
            tests_run++;

            $display("");
            $display("====================================================");
            $display("TEST: %s", name);
            $display("====================================================");
        end
    endtask


    task automatic finish_test();
        begin
            repeat (3)
                @(posedge i_clk);

            if (error_count == test_start_errors) begin
                $display("[PASS] %s", current_test);
            end
            else begin
                tests_failed++;
                $display("[FAIL] %s", current_test);
            end
        end
    endtask


    // ================================================================
    // Random READY generation
    // ================================================================

    always @(negedge i_clk) begin
        if (i_n_reset) begin

            if (random_m_ready_enable)
                m_axis_tready <= $urandom_range(0, 1);

            if (random_meta_ready_enable)
                i_meta_ready <= $urandom_range(0, 1);

        end
    end


    // ================================================================
    // Main scoreboard
    // ================================================================

    always @(posedge i_clk) begin

        if (i_n_reset) begin

            // --------------------------------------------------------
            // Metadata handshake
            // --------------------------------------------------------

            if (o_meta_valid && i_meta_ready) begin

                meta_hs_count++;

                if (scoreboard_enable) begin

                    if (expected_meta_q.size() == 0) begin

                        tb_error(
                            $sformatf(
                                "Unexpected metadata handshake: dst=%012h src=%012h type=%0d",
                                o_dst_mac,
                                o_src_mac,
                                o_ethertype
                            )
                        );

                    end
                    else begin

                        expected_meta_t exp;

                        exp = expected_meta_q.pop_front();

                        if (o_dst_mac !== exp.dst)
                            tb_error(
                                $sformatf(
                                    "Destination MAC mismatch: expected %012h got %012h",
                                    exp.dst,
                                    o_dst_mac
                                )
                            );

                        if (o_src_mac !== exp.src)
                            tb_error(
                                $sformatf(
                                    "Source MAC mismatch: expected %012h got %012h",
                                    exp.src,
                                    o_src_mac
                                )
                            );

                        if (o_ethertype !== exp.etype)
                            tb_error(
                                $sformatf(
                                    "EtherType classification mismatch: expected %0d got %0d",
                                    exp.etype,
                                    o_ethertype
                                )
                            );

                        if (o_frame_size !== exp.frame_size)
                            tb_error(
                                $sformatf(
                                    "Frame-size mismatch: expected %0d L3 bytes got %0d",
                                    exp.frame_size,
                                    o_frame_size
                                )
                            );

                    end
                end
            end


            // --------------------------------------------------------
            // Payload handshake
            // --------------------------------------------------------

            if (m_axis_tvalid && m_axis_tready) begin

                payload_hs_count++;

                if (scoreboard_enable) begin

                    if (expected_payload_q.size() == 0) begin

                        tb_error(
                            $sformatf(
                                "Unexpected payload byte 0x%02h last=%0b",
                                m_axis_tdata,
                                m_axis_tlast
                            )
                        );

                    end
                    else begin

                        expected_payload_t exp;

                        exp = expected_payload_q.pop_front();

                        if (m_axis_tdata !== exp.data)
                            tb_error(
                                $sformatf(
                                    "Payload mismatch: expected 0x%02h got 0x%02h",
                                    exp.data,
                                    m_axis_tdata
                                )
                            );

                        if (m_axis_tlast !== exp.last)
                            tb_error(
                                $sformatf(
                                    "TLAST mismatch for payload byte 0x%02h: expected %0b got %0b",
                                    exp.data,
                                    exp.last,
                                    m_axis_tlast
                                )
                            );

                    end
                end
            end


            // --------------------------------------------------------
            // Tests in which absolutely no output is legal
            // --------------------------------------------------------

            if (expect_no_outputs) begin

                if (o_meta_valid)
                    tb_error("o_meta_valid asserted for rejected/truncated packet");

                if (m_axis_tvalid)
                    tb_error("m_axis_tvalid asserted for rejected/truncated packet");

            end


            // --------------------------------------------------------
            // DROP state must keep consuming input
            // --------------------------------------------------------

            if (expect_drop_ready) begin

                if (s_axis_tready !== 1'b1)
                    tb_error(
                        "s_axis_tready was not asserted while draining dropped packet"
                    );

            end


            // --------------------------------------------------------
            // Streaming ready relationship required by specification
            // --------------------------------------------------------

            if (check_stream_ready_rule) begin

                if (
                    s_axis_tready !==
                    (m_axis_tready || !m_axis_tvalid)
                )
                    tb_error(
                        $sformatf(
                            "Streaming TREADY rule violated: s_ready=%b m_ready=%b m_valid=%b",
                            s_axis_tready,
                            m_axis_tready,
                            m_axis_tvalid
                        )
                    );

            end

        end
    end


    // ================================================================
    // AXI protocol assertions
    // ================================================================

    //
    // DUT must hold payload data stable while stalled.
    //
    property p_payload_stable_when_stalled;
        @(posedge i_clk)
        disable iff (!i_n_reset)

        m_axis_tvalid && !m_axis_tready
        |=>
        m_axis_tvalid
        && $stable(m_axis_tdata)
        && $stable(m_axis_tlast);
    endproperty


    assert property (p_payload_stable_when_stalled)
    else begin
        tb_error(
            "AXIS output changed while m_axis_tvalid=1 and m_axis_tready=0"
        );
    end


    //
    // Metadata must remain stable while stalled.
    //
    property p_metadata_stable_when_stalled;
        @(posedge i_clk)
        disable iff (!i_n_reset)

        o_meta_valid && !i_meta_ready
        |=>
        o_meta_valid
        && $stable(o_dst_mac)
        && $stable(o_src_mac)
        && $stable(o_ethertype)
        && $stable(o_frame_size);
    endproperty


    assert property (p_metadata_stable_when_stalled)
    else begin
        tb_error(
            "Metadata changed while o_meta_valid=1 and i_meta_ready=0"
        );
    end


    //
    // Our source obeys AXI too. This also validates the TB driver.
    //
    property p_source_stable_when_stalled;
        @(posedge i_clk)
        disable iff (!i_n_reset)

        s_axis_tvalid && !s_axis_tready
        |=>
        s_axis_tvalid
        && $stable(s_axis_tdata)
        && $stable(s_axis_tlast);
    endproperty


    assert property (p_source_stable_when_stalled)
    else begin
        tb_error("TB AXIS source changed data while DUT stalled it");
    end


    //
    // Frame-size metadata source must also obey ready/valid semantics.
    //
    property p_frame_meta_stable_when_stalled;
        @(posedge i_clk)
        disable iff (!i_n_reset)

        i_frame_meta_valid && !o_frame_meta_ready
        |=>
        i_frame_meta_valid
        && $stable(i_frame_size);
    endproperty


    assert property (p_frame_meta_stable_when_stalled)
    else begin
        tb_error("TB frame metadata changed while DUT stalled it");
    end


    // ================================================================
    // Coverage
    // ================================================================

    cover property (
        @(posedge i_clk)
        o_meta_valid && !i_meta_ready
    );

    cover property (
        @(posedge i_clk)
        m_axis_tvalid && !m_axis_tready
    );

    cover property (
        @(posedge i_clk)
        s_axis_tvalid &&
        s_axis_tready &&
        s_axis_tlast
    );


    // ================================================================
    // Utility: clear scoreboard
    // ================================================================

    task automatic clear_scoreboard();
        begin
            expected_meta_q.delete();
            expected_payload_q.delete();
        end
    endtask


    // ================================================================
    // Build Ethernet frame
    //
    // Byte:
    //
    //   0..5   Destination MAC
    //   6..11  Source MAC
    //   12     EtherType MSB
    //   13     EtherType LSB
    //   14..   Payload
    //
    // ================================================================

    task automatic build_frame(
        input  logic [47:0] dst,
        input  logic [47:0] src,
        input  logic [15:0] ethertype,
        input  byte_t       payload[$],
        output byte_t       frame[$]
    );

        frame.delete();

        // Destination MAC
        for (int i = 0; i < 6; i++)
            frame.push_back(
                dst[47-(8*i) -: 8]
            );

        // Source MAC
        for (int i = 0; i < 6; i++)
            frame.push_back(
                src[47-(8*i) -: 8]
            );

        // EtherType — network byte order
        frame.push_back(ethertype[15:8]);
        frame.push_back(ethertype[7:0]);

        // Payload
        for (int i = 0; i < payload.size(); i++)
            frame.push_back(payload[i]);

    endtask


    // ================================================================
    // Add expected valid frame to scoreboard
    // ================================================================

    task automatic expect_valid_frame(
        input logic [47:0]     dst,
        input logic [47:0]     src,
        input t_ethernet_types etype,
        input byte_t           payload[$]
    );

        expected_meta_t meta;

        meta.dst        = dst;
        meta.src        = src;
        meta.etype      = etype;
        meta.frame_size = 11'(payload.size());

        expected_meta_q.push_back(meta);

        for (int i = 0; i < payload.size(); i++) begin

            expected_payload_t p;

            p.data = payload[i];
            p.last = (i == payload.size()-1);

            expected_payload_q.push_back(p);

        end

    endtask


    // ================================================================
    // Generic AXIS sequence sender
    //
    // Maintains TVALID/TDATA/TLAST until handshake.
    //
    // gap_max:
    //
    //   0 = continuous TVALID
    //   N = inject 0..N idle cycles between bytes
    //
    // ================================================================

    task automatic send_sequence(
        input byte_t data_q[$],
        input bit    last_q[$],
        input int    gap_max
    );

        int gap;

        if (data_q.size() != last_q.size()) begin
            tb_error("Internal TB error: data/last queue size mismatch");
            return;
        end

        for (int i = 0; i < data_q.size(); i++) begin

            if (i == 0) begin

                @(negedge i_clk);

            end
            else begin

                gap = (gap_max == 0)
                    ? 0
                    : $urandom_range(0, gap_max);

                if (gap == 0) begin

                    //
                    // No TVALID gap.
                    //
                    @(negedge i_clk);

                end
                else begin

                    //
                    // Insert real upstream latency.
                    //
                    @(negedge i_clk);

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
            // Hold until accepted.
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
    // Send frame-size metadata from rx_frame_buffer
    //
    // The real rx_frame_buffer publishes the complete Ethernet frame
    // size before presenting byte 0 on AXIS. Hold valid until accepted.
    // ================================================================

    task automatic send_frame_metadata(
        input int frame_size
    );

        @(negedge i_clk);

        i_frame_size       <= 11'(frame_size);
        i_frame_meta_valid <= 1'b1;

        do begin
            @(posedge i_clk);
        end
        while (!o_frame_meta_ready);

        @(negedge i_clk);

        i_frame_meta_valid <= 1'b0;

    endtask


    // ================================================================
    // Send complete Ethernet frame
    // ================================================================

    task automatic send_frame(
        input byte_t frame[$],
        input int    gap_max
    );

        bit last_q[$];

        last_q.delete();

        for (int i = 0; i < frame.size(); i++)
            last_q.push_back(
                i == frame.size()-1
            );

        send_frame_metadata(frame.size());

        send_sequence(
            frame,
            last_q,
            gap_max
        );

    endtask


    // ================================================================
    // Send bytes without TLAST
    //
    // Useful for entering a particular FSM phase.
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
    // Send two frames back-to-back using the metadata-before-data contract
    // ================================================================

    task automatic send_two_frames_contiguous(
        input byte_t frame1[$],
        input byte_t frame2[$]
    );

        bit last1[$];
        bit last2[$];

        last1.delete();
        last2.delete();

        for (int i = 0; i < frame1.size(); i++)
            last1.push_back(i == frame1.size()-1);

        for (int i = 0; i < frame2.size(); i++)
            last2.push_back(i == frame2.size()-1);

        // Frame 1 metadata, then frame 1 data.
        send_frame_metadata(frame1.size());
        send_sequence(frame1, last1, 0);

        // The updated interface requires metadata for frame 2 before its
        // byte 0 can be accepted. This models rx_frame_buffer behavior.
        send_frame_metadata(frame2.size());
        send_sequence(frame2, last2, 0);

    endtask


    // ================================================================
    // Wait for expected output
    // ================================================================

    task automatic wait_scoreboard_empty();

        bit success;

        success = 1'b0;

        for (int i = 0; i < SCOREBOARD_TIMEOUT; i++) begin

            @(posedge i_clk);

            if (
                expected_meta_q.size()    == 0 &&
                expected_payload_q.size() == 0
            ) begin

                success = 1'b1;
                break;

            end

        end

        if (!success)
            tb_error(
                $sformatf(
                    "Scoreboard timeout: %0d metadata and %0d payload transfers still expected",
                    expected_meta_q.size(),
                    expected_payload_q.size()
                )
            );

    endtask


    // ================================================================
    // Wait for o_meta_valid
    // ================================================================

    task automatic wait_for_meta_valid();

        bit success;

        success = 1'b0;

        for (int i = 0; i < 200; i++) begin

            @(posedge i_clk);

            if (o_meta_valid) begin
                success = 1'b1;
                break;
            end

        end

        if (!success)
            tb_error("Timeout waiting for o_meta_valid");

    endtask


    // ================================================================
    // Reset
    // ================================================================

    task automatic apply_reset();

        random_m_ready_enable    = 1'b0;
        random_meta_ready_enable = 1'b0;

        @(negedge i_clk);

        i_n_reset          <= 1'b0;
        s_axis_tvalid      <= 1'b0;
        s_axis_tlast       <= 1'b0;
        i_frame_meta_valid <= 1'b0;
        i_frame_size       <= '0;

        //
        // Requirement says outputs cease upon reset assertion.
        //
        #1;

        if (m_axis_tvalid !== 1'b0)
            tb_error("m_axis_tvalid did not immediately clear on reset");

        if (o_meta_valid !== 1'b0)
            tb_error("o_meta_valid did not immediately clear on reset");

        repeat (3)
            @(posedge i_clk);

        #1;

        if (m_axis_tvalid !== 1'b0)
            tb_error("m_axis_tvalid active during reset");

        if (o_meta_valid !== 1'b0)
            tb_error("o_meta_valid active during reset");

        if (o_dst_mac !== 48'b0)
            tb_error("o_dst_mac did not clear during reset");

        if (o_src_mac !== 48'b0)
            tb_error("o_src_mac did not clear during reset");

        if (o_ethertype !== ETH_INVALID)
            tb_error("o_ethertype did not reset to ETH_INVALID");

        if (o_frame_size !== '0)
            tb_error("o_frame_size did not clear during reset");

        @(negedge i_clk);

        i_n_reset <= 1'b1;

        repeat (2)
            @(posedge i_clk);

    endtask


    // ================================================================
    // Random payload generator
    // ================================================================

    task automatic random_payload(
        input  int    length,
        output byte_t payload[$]
    );

        payload.delete();

        for (int i = 0; i < length; i++)
            payload.push_back(
                $urandom_range(0, 255)
            );

    endtask


    // ================================================================
    // Generic recovery frame
    //
    // Used to verify that malformed packets do not poison the next one.
    // ================================================================

    task automatic send_recovery_frame();

        logic [47:0] dst;
        logic [47:0] src;

        byte_t payload[$];
        byte_t frame[$];

        dst = 48'h12_34_56_78_9A_BC;
        src = 48'hDE_AD_BE_EF_01_02;

        payload.delete();

        payload.push_back(8'hCA);
        payload.push_back(8'hFE);

        build_frame(
            dst,
            src,
            IPV4_TYPE,
            payload,
            frame
        );

        expect_valid_frame(
            dst,
            src,
            ETH_IPV4,
            payload
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        send_frame(frame, 0);

        wait_scoreboard_empty();

    endtask


    // ================================================================
    // TEST 1
    // Reset behavior
    // ================================================================

    task automatic test_reset();

        start_test("Reset behavior");

        clear_scoreboard();

        apply_reset();

        if (o_meta_valid !== 1'b0)
            tb_error("Metadata valid active after reset");

        if (m_axis_tvalid !== 1'b0)
            tb_error("Payload valid active after reset");

        if (o_dst_mac !== 48'b0)
            tb_error("Destination MAC nonzero after reset");

        if (o_src_mac !== 48'b0)
            tb_error("Source MAC nonzero after reset");

        finish_test();

    endtask


    // ================================================================
    // TEST 2
    // Basic IPv4
    // ================================================================

    task automatic test_ipv4();

        byte_t payload[$];
        byte_t frame[$];

        start_test("Valid IPv4 frame");

        clear_scoreboard();

        payload = '{
            8'h10,
            8'h20,
            8'h30,
            8'h40,
            8'h50,
            8'h60
        };

        build_frame(
            48'h00_11_22_33_44_55,
            48'hAA_BB_CC_DD_EE_FF,
            IPV4_TYPE,
            payload,
            frame
        );

        expect_valid_frame(
            48'h00_11_22_33_44_55,
            48'hAA_BB_CC_DD_EE_FF,
            ETH_IPV4,
            payload
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        send_frame(frame, 0);

        wait_scoreboard_empty();

        finish_test();

    endtask


    // ================================================================
    // TEST 3
    // Basic ARP
    // ================================================================

    task automatic test_arp();

        byte_t payload[$];
        byte_t frame[$];

        start_test("Valid ARP frame");

        clear_scoreboard();

        payload = '{
            8'h00,
            8'h01,
            8'h08,
            8'h00,
            8'h06,
            8'h04,
            8'h00,
            8'h01
        };

        build_frame(
            48'hFF_FF_FF_FF_FF_FF,
            48'h02_00_00_00_00_01,
            ARP_TYPE,
            payload,
            frame
        );

        expect_valid_frame(
            48'hFF_FF_FF_FF_FF_FF,
            48'h02_00_00_00_00_01,
            ETH_ARP,
            payload
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        send_frame(frame, 0);

        wait_scoreboard_empty();

        finish_test();

    endtask


    // ================================================================
    // TEST 4
    // MAC extraction patterns
    // ================================================================

    task automatic test_mac_patterns();

        logic [47:0] dst_patterns[4];
        logic [47:0] src_patterns[4];

        byte_t payload[$];
        byte_t frame[$];

        start_test("MAC extraction patterns");

        clear_scoreboard();

        dst_patterns[0] = 48'h00_00_00_00_00_00;
        src_patterns[0] = 48'hFF_FF_FF_FF_FF_FF;

        dst_patterns[1] = 48'hFF_FF_FF_FF_FF_FF;
        src_patterns[1] = 48'h00_00_00_00_00_00;

        dst_patterns[2] = 48'hAA_55_AA_55_AA_55;
        src_patterns[2] = 48'h55_AA_55_AA_55_AA;

        dst_patterns[3] = 48'h01_23_45_67_89_AB;
        src_patterns[3] = 48'hFE_DC_BA_98_76_54;

        payload = '{8'h5A};

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        for (int n = 0; n < 4; n++) begin

            build_frame(
                dst_patterns[n],
                src_patterns[n],
                IPV4_TYPE,
                payload,
                frame
            );

            expect_valid_frame(
                dst_patterns[n],
                src_patterns[n],
                ETH_IPV4,
                payload
            );

            send_frame(frame, 0);

            wait_scoreboard_empty();

        end

        finish_test();

    endtask


    // ================================================================
    // TEST 5
    // IPv4 -> ARP without TVALID gap
    // ================================================================

    task automatic test_back_to_back();

        byte_t payload1[$];
        byte_t payload2[$];

        byte_t frame1[$];
        byte_t frame2[$];

        start_test("Back-to-back IPv4 and ARP with per-frame metadata");

        clear_scoreboard();

        payload1 = '{
            8'h11,
            8'h22,
            8'h33
        };

        payload2 = '{
            8'hAA,
            8'hBB,
            8'hCC,
            8'hDD
        };

        build_frame(
            48'h10_20_30_40_50_60,
            48'hA0_B0_C0_D0_E0_F0,
            IPV4_TYPE,
            payload1,
            frame1
        );

        build_frame(
            48'hFF_FF_FF_FF_FF_FF,
            48'h01_02_03_04_05_06,
            ARP_TYPE,
            payload2,
            frame2
        );

        expect_valid_frame(
            48'h10_20_30_40_50_60,
            48'hA0_B0_C0_D0_E0_F0,
            ETH_IPV4,
            payload1
        );

        expect_valid_frame(
            48'hFF_FF_FF_FF_FF_FF,
            48'h01_02_03_04_05_06,
            ETH_ARP,
            payload2
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        send_two_frames_contiguous(
            frame1,
            frame2
        );

        wait_scoreboard_empty();

        finish_test();

    endtask


    // ================================================================
    // TEST 6
    // Unsupported EtherTypes
    // ================================================================

    task automatic test_unsupported_types();

        logic [15:0] bad_types[6];

        byte_t payload[$];
        byte_t frame[$];

        start_test("Unsupported EtherType rejection");

        clear_scoreboard();

        bad_types[0] = 16'h86DD; // IPv6
        bad_types[1] = 16'h8100; // VLAN
        bad_types[2] = 16'h88A8; // QinQ
        bad_types[3] = 16'h0000;
        bad_types[4] = 16'hFFFF;
        bad_types[5] = 16'h0008; // reversed IPv4 bytes

        payload = '{
            8'h01,
            8'h02,
            8'h03,
            8'h04,
            8'h05
        };

        i_meta_ready  = 1'b0;
        m_axis_tready = 1'b0;

        expect_no_outputs = 1'b1;

        for (int i = 0; i < 6; i++) begin

            build_frame(
                48'h11_22_33_44_55_66,
                48'hAA_BB_CC_DD_EE_FF,
                bad_types[i],
                payload,
                frame
            );

            send_frame(frame, $urandom_range(0, 2));

            repeat (2)
                @(posedge i_clk);

        end

        expect_no_outputs = 1'b0;

        finish_test();

    endtask


    // ================================================================
    // TEST 7
    // Explicit DROP draining test
    // ================================================================

    task automatic test_drop_draining();

        byte_t payload[$];
        byte_t frame[$];

        byte_t header[$];
        byte_t remainder[$];

        bit remainder_last[$];

        start_test("DISP_DROP drains remainder regardless of downstream ready");

        clear_scoreboard();

        random_payload(20, payload);

        build_frame(
            48'h11_22_33_44_55_66,
            48'hAA_BB_CC_DD_EE_FF,
            16'h86DD,
            payload,
            frame
        );

        //
        // Send first 14 bytes but DO NOT TLAST them.
        //
        for (int i = 0; i < 14; i++)
            header.push_back(frame[i]);

        i_meta_ready  = 1'b0;
        m_axis_tready = 1'b0;

        expect_no_outputs = 1'b1;

        send_frame_metadata(frame.size());
        send_no_last(header);

        // The header completion puts the DUT in DISP_OUTPUT.
        // Give it one clock to classify the EtherType and enter DISP_DROP.
        @(posedge i_clk);
        #1;

        if (s_axis_tready !== 1'b1)
            tb_error("DUT did not enter DISP_DROP after unsupported EtherType");

        expect_drop_ready = 1'b1;

        for (int i = 14; i < frame.size(); i++) begin

            remainder.push_back(frame[i]);

            remainder_last.push_back(
                i == frame.size()-1
            );

        end

        send_sequence(
            remainder,
            remainder_last,
            2
        );

        expect_drop_ready = 1'b0;
        expect_no_outputs = 1'b0;

        finish_test();

    endtask


    // ================================================================
    // TEST 8
    // Truncation at EVERY header byte
    //
    // TLAST positions:
    //
    //    0 through 12
    //
    // Byte 13 is separately tested as legal zero-payload frame.
    // ================================================================

    task automatic test_all_truncated_headers();

        byte_t payload[$];
        byte_t full_frame[$];

        byte_t runt[$];
        bit    runt_last[$];

        start_test("Every truncated Ethernet-header position");

        clear_scoreboard();

        payload = '{8'hDE, 8'hAD};

        build_frame(
            48'h01_02_03_04_05_06,
            48'h11_12_13_14_15_16,
            IPV4_TYPE,
            payload,
            full_frame
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        for (int final_byte = 0; final_byte <= 12; final_byte++) begin

            runt.delete();
            runt_last.delete();

            for (int i = 0; i <= final_byte; i++) begin

                runt.push_back(full_frame[i]);

                runt_last.push_back(
                    i == final_byte
                );

            end

            expect_no_outputs = 1'b1;

            send_frame_metadata(runt.size());

            send_sequence(
                runt,
                runt_last,
                $urandom_range(0, 2)
            );

            repeat (2)
                @(posedge i_clk);

            expect_no_outputs = 1'b0;

            //
            // Extremely important:
            // verify malformed frame did not leave FSM poisoned.
            //
            send_recovery_frame();

        end

        finish_test();

    endtask


    // ================================================================
    // TEST 9
    // Single-byte frame
    // ================================================================

    task automatic test_single_byte_frame();

        byte_t data_q[$];
        bit    last_q[$];

        start_test("Single-byte Ethernet frame");

        clear_scoreboard();

        data_q.push_back(8'h45);
        last_q.push_back(1'b1);

        expect_no_outputs = 1'b1;

        send_frame_metadata(data_q.size());

        send_sequence(
            data_q,
            last_q,
            0
        );

        repeat (2)
            @(posedge i_clk);

        expect_no_outputs = 1'b0;

        //
        // Must recover immediately.
        //
        send_recovery_frame();

        finish_test();

    endtask


    // ================================================================
    // TEST 10
    // Exactly 14 bytes / no payload
    // ================================================================

    task automatic test_zero_payload();

        byte_t payload[$];
        byte_t frame[$];

        start_test("Valid 14-byte header with zero payload");

        clear_scoreboard();

        payload.delete();

        build_frame(
            48'h01_23_45_67_89_AB,
            48'h10_32_54_76_98_BA,
            IPV4_TYPE,
            payload,
            frame
        );

        //
        // Metadata is expected.
        // Payload is NOT.
        //
        expect_valid_frame(
            48'h01_23_45_67_89_AB,
            48'h10_32_54_76_98_BA,
            ETH_IPV4,
            payload
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        send_frame(frame, 0);

        wait_scoreboard_empty();

        //
        // Must not invent a payload byte or remain stuck streaming.
        //
        repeat (5) begin

            @(posedge i_clk);

            if (m_axis_tvalid)
                tb_error("Payload emitted for zero-payload frame");

        end

        //
        // Verify clean recovery.
        //
        send_recovery_frame();

        finish_test();

    endtask


    // ================================================================
    // TEST 11
    // Metadata stall
    // ================================================================

    task automatic test_metadata_stall();

        byte_t payload[$];
        byte_t frame[$];

        logic [47:0] held_dst;
        logic [47:0] held_src;

        t_ethernet_types held_type;

        start_test("Metadata backpressure / stability");

        clear_scoreboard();

        payload = '{
            8'h10,
            8'h20,
            8'h30,
            8'h40
        };

        build_frame(
            48'h12_34_56_78_9A_BC,
            48'hDE_AD_BE_EF_CA_FE,
            IPV4_TYPE,
            payload,
            frame
        );

        expect_valid_frame(
            48'h12_34_56_78_9A_BC,
            48'hDE_AD_BE_EF_CA_FE,
            ETH_IPV4,
            payload
        );

        i_meta_ready  = 1'b0;
        m_axis_tready = 1'b1;

        fork

            begin
                send_frame(frame, 0);
            end

            begin

                wait_for_meta_valid();

                #1;

                held_dst  = o_dst_mac;
                held_src  = o_src_mac;
                held_type = o_ethertype;

                if (s_axis_tready !== 1'b0)
                    tb_error(
                        "Input was not stalled while waiting for metadata handshake"
                    );

                if (m_axis_tvalid !== 1'b0)
                    tb_error(
                        "Payload began before metadata handshake completed"
                    );

                repeat (10) begin

                    @(posedge i_clk);
                    #1;

                    if (!o_meta_valid)
                        tb_error(
                            "o_meta_valid dropped before metadata handshake"
                        );

                    if (o_dst_mac !== held_dst)
                        tb_error(
                            "Destination MAC changed during metadata stall"
                        );

                    if (o_src_mac !== held_src)
                        tb_error(
                            "Source MAC changed during metadata stall"
                        );

                    if (o_ethertype !== held_type)
                        tb_error(
                            "EtherType changed during metadata stall"
                        );

                    if (s_axis_tready !== 1'b0)
                        tb_error(
                            "s_axis_tready asserted before metadata accepted"
                        );

                    if (m_axis_tvalid)
                        tb_error(
                            "Payload became valid before metadata accepted"
                        );

                end

                @(negedge i_clk);
                i_meta_ready <= 1'b1;

            end

        join

        wait_scoreboard_empty();

        finish_test();

    endtask


    // ================================================================
    // TEST 12
    // Payload backpressure
    // ================================================================

    task automatic test_payload_backpressure();

        byte_t payload[$];
        byte_t frame[$];

        int meta_before;

        start_test("Payload backpressure and AXIS stability");

        clear_scoreboard();

        payload = '{
            8'h01,
            8'h02,
            8'h03,
            8'h04,
            8'h05,
            8'h06,
            8'h07,
            8'h08
        };

        build_frame(
            48'h10_11_12_13_14_15,
            48'h20_21_22_23_24_25,
            IPV4_TYPE,
            payload,
            frame
        );

        expect_valid_frame(
            48'h10_11_12_13_14_15,
            48'h20_21_22_23_24_25,
            ETH_IPV4,
            payload
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b0;

        meta_before = meta_hs_count;

        fork

            begin
                send_frame(frame, 0);
            end

            begin

                //
                // Wait until metadata was accepted.
                //
                while (meta_hs_count == meta_before)
                    @(posedge i_clk);

                check_stream_ready_rule = 1'b1;

                //
                // First payload byte must eventually appear even though
                // downstream isn't ready.
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
                            "Payload TVALID never asserted while downstream stalled"
                        );

                end

                //
                // Hold stall several cycles.
                //
                repeat (6)
                    @(posedge i_clk);

                //
                // Now randomly backpressure the rest.
                //
                random_m_ready_enable = 1'b1;

            end

        join

        random_m_ready_enable  = 1'b0;
        check_stream_ready_rule = 1'b0;

        m_axis_tready = 1'b1;

        wait_scoreboard_empty();

        finish_test();

    endtask


    // ================================================================
    // TEST 13
    // Upstream gaps
    // ================================================================

    task automatic test_upstream_latency();

        byte_t payload[$];
        byte_t frame[$];

        start_test("Intermittent upstream TVALID");

        clear_scoreboard();

        random_payload(64, payload);

        build_frame(
            48'h11_22_33_44_55_66,
            48'h77_88_99_AA_BB_CC,
            IPV4_TYPE,
            payload,
            frame
        );

        expect_valid_frame(
            48'h11_22_33_44_55_66,
            48'h77_88_99_AA_BB_CC,
            ETH_IPV4,
            payload
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        //
        // 0..5 empty cycles between arbitrary bytes.
        //
        send_frame(frame, 5);

        wait_scoreboard_empty();

        finish_test();

    endtask


    // ================================================================
    // TEST 14
    //
    // TLAST while TVALID=0 must be ignored.
    //
    // Extremely useful for catching FSMs written as:
    //
    //     if (s_axis_tlast)
    //
    // instead of:
    //
    //     if (s_axis_tvalid &&
    //         s_axis_tready &&
    //         s_axis_tlast)
    //
    // ================================================================

    task automatic test_tlast_without_tvalid();

        byte_t payload[$];
        byte_t frame[$];

        byte_t first_part[$];
        byte_t second_part[$];

        bit second_last[$];

        start_test("TLAST/data ignored when TVALID=0");

        clear_scoreboard();

        payload = '{
            8'hAA,
            8'hBB,
            8'hCC
        };

        build_frame(
            48'h01_02_03_04_05_06,
            48'h10_20_30_40_50_60,
            IPV4_TYPE,
            payload,
            frame
        );

        expect_valid_frame(
            48'h01_02_03_04_05_06,
            48'h10_20_30_40_50_60,
            ETH_IPV4,
            payload
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        //
        // Send first 5 real bytes.
        //
        for (int i = 0; i < 5; i++)
            first_part.push_back(frame[i]);

        send_frame_metadata(frame.size());
        send_no_last(first_part);

        //
        // Present garbage + TLAST while TVALID=0.
        // DUT must ignore EVERYTHING.
        //
        repeat (5) begin

            @(negedge i_clk);

            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b1;
            s_axis_tdata  <= $urandom_range(0,255);

        end

        //
        // Resume actual packet from byte 5.
        //
        for (int i = 5; i < frame.size(); i++) begin

            second_part.push_back(frame[i]);

            second_last.push_back(
                i == frame.size()-1
            );

        end

        send_sequence(
            second_part,
            second_last,
            2
        );

        wait_scoreboard_empty();

        finish_test();

    endtask


    // ================================================================
    // TEST 15
    // Maximum standard Ethernet payload size: 1500 bytes
    // ================================================================

    task automatic test_large_payload();

        byte_t payload[$];
        byte_t frame[$];

        start_test("1500-byte Ethernet payload");

        clear_scoreboard();

        random_payload(1500, payload);

        build_frame(
            48'h22_33_44_55_66_77,
            48'h88_99_AA_BB_CC_DD,
            IPV4_TYPE,
            payload,
            frame
        );

        expect_valid_frame(
            48'h22_33_44_55_66_77,
            48'h88_99_AA_BB_CC_DD,
            ETH_IPV4,
            payload
        );

        random_m_ready_enable    = 1'b1;
        random_meta_ready_enable = 1'b1;

        send_frame(
            frame,
            3
        );

        wait_scoreboard_empty();

        random_m_ready_enable    = 1'b0;
        random_meta_ready_enable = 1'b0;

        m_axis_tready = 1'b1;
        i_meta_ready  = 1'b1;

        finish_test();

    endtask


    // ================================================================
    // TEST 16
    // Unsupported frame immediately followed by valid frame
    // ================================================================

    task automatic test_drop_then_immediate_valid();

        byte_t bad_payload[$];
        byte_t good_payload[$];

        byte_t bad_frame[$];
        byte_t good_frame[$];

        start_test("Dropped frame immediately followed by valid frame");

        clear_scoreboard();

        bad_payload = '{
            8'hDE,
            8'hAD,
            8'hBE,
            8'hEF
        };

        good_payload = '{
            8'h12,
            8'h34,
            8'h56
        };

        build_frame(
            48'h11_11_11_11_11_11,
            48'h22_22_22_22_22_22,
            16'h86DD,
            bad_payload,
            bad_frame
        );

        build_frame(
            48'h33_33_33_33_33_33,
            48'h44_44_44_44_44_44,
            IPV4_TYPE,
            good_payload,
            good_frame
        );

        expect_valid_frame(
            48'h33_33_33_33_33_33,
            48'h44_44_44_44_44_44,
            ETH_IPV4,
            good_payload
        );

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        //
        // No arbitrary idle delay is inserted; frame 2 begins as soon as its metadata is accepted.
        //
        send_two_frames_contiguous(
            bad_frame,
            good_frame
        );

        wait_scoreboard_empty();

        finish_test();

    endtask


    // ================================================================
    // TEST 17
    // Reset during MAC collection
    // ================================================================

    task automatic test_reset_during_header();

        byte_t payload[$];
        byte_t frame[$];
        byte_t prefix[$];

        start_test("Reset during DISP_MAC_REG");

        clear_scoreboard();

        scoreboard_enable = 1'b0;

        payload = '{8'h11};

        build_frame(
            48'h01_02_03_04_05_06,
            48'h11_12_13_14_15_16,
            IPV4_TYPE,
            payload,
            frame
        );

        //
        // Only five bytes accepted.
        //
        for (int i = 0; i < 5; i++)
            prefix.push_back(frame[i]);

        send_frame_metadata(frame.size());
        send_no_last(prefix);

        apply_reset();

        scoreboard_enable = 1'b1;

        //
        // Must restart from a completely clean parser.
        //
        send_recovery_frame();

        finish_test();

    endtask


    // ================================================================
    // TEST 18
    // Reset while metadata is outstanding
    // ================================================================

    task automatic test_reset_during_metadata();

        byte_t payload[$];
        byte_t frame[$];
        byte_t header[$];

        start_test("Reset during DISP_OUTPUT");

        clear_scoreboard();

        scoreboard_enable = 1'b0;

        payload = '{
            8'h11,
            8'h22
        };

        build_frame(
            48'h12_34_56_78_9A_BC,
            48'hAB_CD_EF_12_34_56,
            IPV4_TYPE,
            payload,
            frame
        );

        for (int i = 0; i < 14; i++)
            header.push_back(frame[i]);

        i_meta_ready  = 1'b0;
        m_axis_tready = 1'b1;

        send_frame_metadata(frame.size());
        send_no_last(header);

        wait_for_meta_valid();

        if (!o_meta_valid)
            tb_error(
                "Failed to enter metadata-output phase before reset"
            );

        apply_reset();

        scoreboard_enable = 1'b1;

        send_recovery_frame();

        finish_test();

    endtask


    // ================================================================
    // TEST 19
    // Reset during payload streaming
    // ================================================================

    task automatic test_reset_during_stream();

        byte_t payload[$];
        byte_t frame[$];

        byte_t header[$];

        start_test("Reset during DISP_STREAM");

        clear_scoreboard();

        scoreboard_enable = 1'b0;

        payload = '{
            8'hAA,
            8'hBB,
            8'hCC
        };

        build_frame(
            48'h01_23_45_67_89_AB,
            48'h10_32_54_76_98_BA,
            IPV4_TYPE,
            payload,
            frame
        );

        for (int i = 0; i < 14; i++)
            header.push_back(frame[i]);

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        send_frame_metadata(frame.size());
        send_no_last(header);

        //
        // Allow metadata handshake.
        //
        repeat (3)
            @(posedge i_clk);

        //
        // Stall first payload byte downstream so m_axis_tvalid is
        // observably asserted when reset occurs.
        //
        @(negedge i_clk);

        m_axis_tready <= 1'b0;

        s_axis_tdata  <= payload[0];
        s_axis_tvalid <= 1'b1;
        s_axis_tlast  <= 1'b0;

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
                    "Could not observe stalled payload before stream reset"
                );

        end

        //
        // Now reset with active payload.
        //
        apply_reset();

        scoreboard_enable = 1'b1;

        m_axis_tready = 1'b1;

        send_recovery_frame();

        finish_test();

    endtask


    // ================================================================
    // TEST 20
    // Reset while dropping unsupported packet
    // ================================================================

    task automatic test_reset_during_drop();

        byte_t payload[$];
        byte_t frame[$];

        byte_t prefix[$];

        start_test("Reset during DISP_DROP");

        clear_scoreboard();

        scoreboard_enable = 1'b0;

        payload = '{
            8'h01,
            8'h02,
            8'h03,
            8'h04
        };

        build_frame(
            48'h01_01_01_01_01_01,
            48'h02_02_02_02_02_02,
            16'h86DD,
            payload,
            frame
        );

        //
        // Header plus one payload byte, no TLAST.
        //
        for (int i = 0; i < 15; i++)
            prefix.push_back(frame[i]);

        send_frame_metadata(frame.size());
        send_no_last(prefix);

        apply_reset();

        scoreboard_enable = 1'b1;

        send_recovery_frame();

        finish_test();

    endtask


    // ================================================================
    // TEST 21
    // Many consecutive frames
    // ================================================================

    task automatic test_many_frames();

        byte_t payload[$];
        byte_t frame[$];

        logic [47:0] dst;
        logic [47:0] src;

        start_test("Many consecutive valid frames");

        clear_scoreboard();

        i_meta_ready  = 1'b1;
        m_axis_tready = 1'b1;

        for (int n = 0; n < 50; n++) begin

            random_payload(
                $urandom_range(1,64),
                payload
            );

            dst = {
                $urandom(),
                $urandom()
            };

            src = {
                $urandom(),
                $urandom()
            };

            if ((n & 1) == 0) begin

                build_frame(
                    dst,
                    src,
                    IPV4_TYPE,
                    payload,
                    frame
                );

                expect_valid_frame(
                    dst,
                    src,
                    ETH_IPV4,
                    payload
                );

            end
            else begin

                build_frame(
                    dst,
                    src,
                    ARP_TYPE,
                    payload,
                    frame
                );

                expect_valid_frame(
                    dst,
                    src,
                    ETH_ARP,
                    payload
                );

            end

            send_frame(
                frame,
                0
            );

            wait_scoreboard_empty();

        end

        finish_test();

    endtask


    // ================================================================
    // TEST 22
    // Full randomized stress regression
    // ================================================================

    task automatic test_randomized_regression();

        byte_t payload[$];
        byte_t frame[$];

        logic [47:0] dst;
        logic [47:0] src;

        logic [15:0] ether;

        int packet_type;
        int len;

        start_test("Randomized handshake / classification regression");

        clear_scoreboard();

        random_m_ready_enable    = 1'b1;
        random_meta_ready_enable = 1'b1;

        for (int packet = 0; packet < 200; packet++) begin

            packet_type = $urandom_range(0, 4);

            //
            // Include zero-length packets occasionally.
            //
            len = $urandom_range(0, 128);

            random_payload(
                len,
                payload
            );

            dst = {
                $urandom(),
                $urandom()
            };

            src = {
                $urandom(),
                $urandom()
            };

            case (packet_type)

                0,
                1: begin

                    ether = IPV4_TYPE;

                    expect_valid_frame(
                        dst,
                        src,
                        ETH_IPV4,
                        payload
                    );

                end

                2: begin

                    ether = ARP_TYPE;

                    expect_valid_frame(
                        dst,
                        src,
                        ETH_ARP,
                        payload
                    );

                end

                3: begin
                    ether = 16'h86DD;
                end

                default: begin
                    ether = 16'h8100;
                end

            endcase

            build_frame(
                dst,
                src,
                ether,
                payload,
                frame
            );

            //
            // Random gaps between input bytes.
            //
            send_frame(
                frame,
                $urandom_range(0, 4)
            );

            wait_scoreboard_empty();

        end

        random_m_ready_enable    = 1'b0;
        random_meta_ready_enable = 1'b0;

        m_axis_tready = 1'b1;
        i_meta_ready  = 1'b1;

        finish_test();

    endtask


    // ================================================================
    // Global simulation watchdog
    // ================================================================

    initial begin

        #10ms;

        $fatal(
            1,
            "GLOBAL TESTBENCH TIMEOUT"
        );

    end


    // ================================================================
    // Main Test Sequence
    // ================================================================

    initial begin

        int unsigned seed;

        seed = 32'hC0FFEE42;

        if ($value$plusargs("SEED=%d", seed))
            $display("Using supplied random seed: %0d", seed);
        else
            $display("Using default random seed: 0x%08h", seed);

        $srandom(seed);


        // ------------------------------------------------------------
        // Initial signal state
        // ------------------------------------------------------------

        i_n_reset = 1'b0;

        s_axis_tdata  = 8'b0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;

        i_frame_meta_valid = 1'b0;
        i_frame_size       = '0;

        m_axis_tready = 1'b0;
        i_meta_ready  = 1'b0;

        random_m_ready_enable    = 1'b0;
        random_meta_ready_enable = 1'b0;

        scoreboard_enable       = 1'b1;
        expect_no_outputs       = 1'b0;
        expect_drop_ready       = 1'b0;
        check_stream_ready_rule = 1'b0;


        // ------------------------------------------------------------
        // Initial reset
        // ------------------------------------------------------------

        repeat (4)
            @(posedge i_clk);

        @(negedge i_clk);

        i_n_reset = 1'b1;

        m_axis_tready = 1'b1;
        i_meta_ready  = 1'b1;

        repeat (2)
            @(posedge i_clk);


        // ------------------------------------------------------------
        // Directed tests
        // ------------------------------------------------------------

        test_reset();

        test_ipv4();

        test_arp();

        test_mac_patterns();

        test_back_to_back();

        test_unsupported_types();

        test_drop_draining();

        test_all_truncated_headers();

        test_single_byte_frame();

        test_zero_payload();

        test_metadata_stall();

        test_payload_backpressure();

        test_upstream_latency();

        test_tlast_without_tvalid();

        test_large_payload();

        test_drop_then_immediate_valid();

        test_reset_during_header();

        test_reset_during_metadata();

        test_reset_during_stream();

        test_reset_during_drop();

        test_many_frames();

        test_randomized_regression();


        // ------------------------------------------------------------
        // Final drain
        // ------------------------------------------------------------

        repeat (10)
            @(posedge i_clk);


        // ------------------------------------------------------------
        // Make sure scoreboard really finished
        // ------------------------------------------------------------

        if (expected_meta_q.size() != 0)
            tb_error(
                $sformatf(
                    "%0d metadata items still expected at end of simulation",
                    expected_meta_q.size()
                )
            );

        if (expected_payload_q.size() != 0)
            tb_error(
                $sformatf(
                    "%0d payload items still expected at end of simulation",
                    expected_payload_q.size()
                )
            );


        // ------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------

        $display("");
        $display("====================================================");
        $display("                 TEST SUMMARY");
        $display("====================================================");
        $display("Tests run    : %0d", tests_run);
        $display("Tests passed : %0d", tests_run - tests_failed);
        $display("Tests failed : %0d", tests_failed);
        $display("Total errors : %0d", error_count);
        $display("Metadata H/S : %0d", meta_hs_count);
        $display("Payload H/S  : %0d", payload_hs_count);
        $display("====================================================");

        if (error_count == 0) begin

            $display("");
            $display("**********************************************");
            $display("*           ALL TESTS PASSED                 *");
            $display("**********************************************");
            $display("");

            $finish;

        end
        else begin

            $fatal(
                1,
                "TESTBENCH FAILED WITH %0d ERROR(S)",
                error_count
            );

        end

    end

endmodule