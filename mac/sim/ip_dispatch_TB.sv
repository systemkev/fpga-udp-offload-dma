`timescale 1ns / 1ps

import common_pkg::*;

module ip_dispatch_TB;

    localparam time CLK_PERIOD = 10ns;
    localparam int  TIMEOUT_CYCLES = 5000;

    typedef byte unsigned byte_t;

    // ----------------------------------------------------------------
    // DUT signals
    // ----------------------------------------------------------------
    logic i_clk;
    logic i_n_reset;

    t_ipv4_metadata i_ipv4_meta;
    logic           i_ipv4_meta_valid;
    logic           o_ipv4_meta_ready;

    logic [7:0] s_axis_tdata;
    logic       s_axis_tvalid;
    logic       s_axis_tlast;
    logic       s_axis_tready;

    t_ipv4_metadata o_udp_ipv4_meta;
    logic           o_udp_ipv4_meta_valid;
    logic           i_udp_ipv4_meta_ready;

    logic [7:0] m_axis_tdata;
    logic       m_axis_tvalid;
    logic       m_axis_tlast;
    logic       m_axis_tready;


    ip_dispatch dut (
        .i_clk                  (i_clk),
        .i_n_reset              (i_n_reset),

        .i_ipv4_meta            (i_ipv4_meta),
        .i_ipv4_meta_valid      (i_ipv4_meta_valid),
        .o_ipv4_meta_ready      (o_ipv4_meta_ready),

        .s_axis_tdata           (s_axis_tdata),
        .s_axis_tvalid          (s_axis_tvalid),
        .s_axis_tlast           (s_axis_tlast),
        .s_axis_tready          (s_axis_tready),

        .o_udp_ipv4_meta        (o_udp_ipv4_meta),
        .o_udp_ipv4_meta_valid  (o_udp_ipv4_meta_valid),
        .i_udp_ipv4_meta_ready  (i_udp_ipv4_meta_ready),

        .m_axis_tdata           (m_axis_tdata),
        .m_axis_tvalid          (m_axis_tvalid),
        .m_axis_tlast           (m_axis_tlast),
        .m_axis_tready          (m_axis_tready)
    );


    // ----------------------------------------------------------------
    // Clock
    // ----------------------------------------------------------------
    initial begin
        i_clk = 1'b0;
        forever #(CLK_PERIOD/2) i_clk = ~i_clk;
    end


    // ----------------------------------------------------------------
    // Scoreboard
    // ----------------------------------------------------------------
    typedef struct packed {
        logic [7:0] data;
        logic       last;
    } payload_expect_t;

    t_ipv4_metadata expected_meta_q[$];
    payload_expect_t expected_payload_q[$];

    int tests_run;
    int tests_failed;
    int error_count;
    int test_start_errors;

    string current_test;
    string current_subcase;

    bit scoreboard_enable;
    bit expect_no_outputs;
    bit expect_drop_ready;

    bit random_m_ready_enable;
    bit random_meta_ready_enable;


    task automatic tb_error(input string msg);
        error_count++;

        if (current_subcase != "")
            $display(
                "[ERROR @ %0t] %s [%s]: %s",
                $time,
                current_test,
                current_subcase,
                msg
            );
        else
            $display(
                "[ERROR @ %0t] %s: %s",
                $time,
                current_test,
                msg
            );
    endtask


    task automatic start_test(input string name);
        current_test      = name;
        current_subcase   = "";
        test_start_errors = error_count;
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
        end else begin
            tests_failed++;
            $display("[FAIL] %s", current_test);
        end
    endtask


    // ----------------------------------------------------------------
    // Random downstream READY generation
    // ----------------------------------------------------------------
    always @(negedge i_clk) begin
        if (i_n_reset) begin
            if (random_m_ready_enable)
                m_axis_tready <= ($urandom_range(0, 9) < 7);

            if (random_meta_ready_enable)
                i_udp_ipv4_meta_ready <= ($urandom_range(0, 9) < 6);
        end
    end


    // ----------------------------------------------------------------
    // Main scoreboard
    // ----------------------------------------------------------------
    always @(posedge i_clk) begin
        if (i_n_reset && scoreboard_enable) begin

            if (o_udp_ipv4_meta_valid && i_udp_ipv4_meta_ready) begin
                if (expected_meta_q.size() == 0) begin
                    tb_error("Unexpected UDP IPv4 metadata handshake");
                end else begin
                    t_ipv4_metadata exp;

                    exp = expected_meta_q.pop_front();

                    if (o_udp_ipv4_meta !== exp) begin
                        tb_error("UDP IPv4 metadata mismatch");

                        $display("  expected protocol    = %0d", exp.protocol);
                        $display("  actual protocol      = %0d", o_udp_ipv4_meta.protocol);
                        $display("  expected payload_len = %0d", exp.payload_len);
                        $display("  actual payload_len   = %0d", o_udp_ipv4_meta.payload_len);
                        $display("  expected src_ip      = %08h", exp.src_ip);
                        $display("  actual src_ip        = %08h", o_udp_ipv4_meta.src_ip);
                    end
                end
            end


            if (m_axis_tvalid && m_axis_tready) begin
                if (expected_payload_q.size() == 0) begin
                    tb_error(
                        $sformatf(
                            "Unexpected payload byte 0x%02h TLAST=%0b",
                            m_axis_tdata,
                            m_axis_tlast
                        )
                    );
                end else begin
                    payload_expect_t exp;

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
                                "TLAST mismatch: expected %0b got %0b",
                                exp.last,
                                m_axis_tlast
                            )
                        );
                end
            end


            if (expect_no_outputs) begin
                if (o_udp_ipv4_meta_valid)
                    tb_error("UDP metadata asserted for unsupported protocol");

                if (m_axis_tvalid)
                    tb_error("UDP payload asserted for unsupported protocol");
            end


            if (expect_drop_ready) begin
                if (s_axis_tready !== 1'b1)
                    tb_error("s_axis_tready was not asserted while dropping packet");
            end
        end
    end


    // ----------------------------------------------------------------
    // Protocol assertions
    // ----------------------------------------------------------------

    // Output payload must stay stable while downstream stalls.
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
    else tb_error("Output payload changed while stalled");


    // UDP metadata must remain stable and valid until accepted.
    property p_metadata_stable_when_stalled;
        @(posedge i_clk)
        disable iff (!i_n_reset)

        o_udp_ipv4_meta_valid && !i_udp_ipv4_meta_ready
        |=>
        o_udp_ipv4_meta_valid &&
        $stable(o_udp_ipv4_meta);
    endproperty

    assert property (p_metadata_stable_when_stalled)
    else tb_error("UDP metadata changed while stalled");


    // The TB source must obey AXI.
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
    else tb_error("TB AXIS source changed while DUT stalled it");


    // No transport payload may pass while UDP metadata is waiting.
    property p_metadata_blocks_payload;
        @(posedge i_clk)
        disable iff (!i_n_reset)

        o_udp_ipv4_meta_valid && !i_udp_ipv4_meta_ready
        |->
        !m_axis_tvalid &&
        !s_axis_tready;
    endproperty

    assert property (p_metadata_blocks_payload)
    else tb_error("Payload moved before UDP metadata was accepted");


    property p_output_last_requires_valid;
        @(posedge i_clk)
        disable iff (!i_n_reset)

        m_axis_tlast |-> m_axis_tvalid;
    endproperty

    assert property (p_output_last_requires_valid)
    else tb_error("m_axis_tlast asserted without m_axis_tvalid");


    // ----------------------------------------------------------------
    // Metadata/payload helpers
    // ----------------------------------------------------------------
    function automatic t_ipv4_metadata make_meta(
        input logic [7:0] protocol,
        input int         payload_len,
        input int         tag
    );
        t_ipv4_metadata m;

        m = '0;

        m.src_mac     = 48'h10_20_30_40_50_60 ^ tag;
        m.dst_mac     = 48'h02_00_00_00_00_01;
        m.version     = 4'd4;
        m.ihl         = 4'd5;
        m.total_len   = 16'(20 + payload_len);
        m.id_field    = 16'(tag);
        m.frag_offset = 13'd0;
        m.ttl         = 8'd64;
        m.protocol    = protocol;
        m.src_ip      = 32'h0A_00_00_01 ^ tag;
        m.dst_ip      = 32'hC0_A8_01_32;
        m.payload_len = 16'(payload_len);

        return m;
    endfunction


    task automatic random_payload(
        input  int    length,
        output byte_t payload[$]
    );
        payload.delete();

        for (int i = 0; i < length; i++)
            payload.push_back($urandom_range(0,255));
    endtask


    task automatic expect_udp_packet(
        input t_ipv4_metadata meta,
        input byte_t          payload[$]
    );
        expected_meta_q.push_back(meta);

        for (int i = 0; i < payload.size(); i++) begin
            payload_expect_t p;

            p.data = payload[i];
            p.last = (i == payload.size()-1);

            expected_payload_q.push_back(p);
        end
    endtask


    task automatic send_metadata(
        input t_ipv4_metadata meta
    );
        @(negedge i_clk);

        i_ipv4_meta       <= meta;
        i_ipv4_meta_valid <= 1'b1;

        do begin
            @(posedge i_clk);
        end
        while (!o_ipv4_meta_ready);

        @(negedge i_clk);

        i_ipv4_meta_valid <= 1'b0;
    endtask


    task automatic send_payload(
        input byte_t payload[$],
        input int    gap_max
    );
        int gap;

        for (int i = 0; i < payload.size(); i++) begin

            if (i == 0) begin
                @(negedge i_clk);
            end else begin
                @(negedge i_clk);

                gap = (gap_max == 0)
                    ? 0
                    : $urandom_range(0, gap_max);

                if (gap != 0) begin
                    s_axis_tvalid <= 1'b0;
                    s_axis_tlast  <= 1'b0;

                    repeat (gap)
                        @(negedge i_clk);
                end
            end

            s_axis_tdata  <= payload[i];
            s_axis_tlast  <= (i == payload.size()-1);
            s_axis_tvalid <= 1'b1;

            do begin
                @(posedge i_clk);
            end
            while (!s_axis_tready);
        end

        @(negedge i_clk);

        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
    endtask


    task automatic send_packet(
        input t_ipv4_metadata meta,
        input byte_t          payload[$],
        input int             gap_max
    );
        send_metadata(meta);

        if (payload.size() != 0)
            send_payload(payload, gap_max);
    endtask


    task automatic wait_scoreboard_empty();
        bit success;

        success = 1'b0;

        for (int i = 0; i < TIMEOUT_CYCLES; i++) begin
            @(posedge i_clk);

            if ((expected_meta_q.size() == 0) &&
                (expected_payload_q.size() == 0)) begin
                success = 1'b1;
                break;
            end
        end

        if (!success)
            tb_error(
                $sformatf(
                    "Scoreboard timeout: %0d metadata, %0d payload items remain",
                    expected_meta_q.size(),
                    expected_payload_q.size()
                )
            );
    endtask


    task automatic reset_dut();
        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        scoreboard_enable = 1'b0;
        expect_no_outputs = 1'b0;
        expect_drop_ready = 1'b0;

        expected_meta_q.delete();
        expected_payload_q.delete();

        @(negedge i_clk);

        i_n_reset <= 1'b0;

        i_ipv4_meta       <= '0;
        i_ipv4_meta_valid <= 1'b0;

        s_axis_tdata  <= '0;
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;

        i_udp_ipv4_meta_ready <= 1'b1;
        m_axis_tready         <= 1'b1;

        repeat (3)
            @(posedge i_clk);

        #1;

        if (o_udp_ipv4_meta_valid !== 1'b0)
            tb_error("Metadata valid did not clear during reset");

        if (m_axis_tvalid !== 1'b0)
            tb_error("Payload valid did not clear during reset");

        @(negedge i_clk);
        i_n_reset <= 1'b1;

        repeat (2)
            @(posedge i_clk);

        scoreboard_enable = 1'b1;
    endtask


    task automatic send_recovery_packet();
        t_ipv4_metadata meta;
        byte_t payload[$];

        payload = '{8'hCA, 8'hFE, 8'hBA, 8'hBE};

        meta = make_meta(8'd17, payload.size(), 16'hCAFE);

        expect_udp_packet(meta, payload);
        send_packet(meta, payload, 0);
        wait_scoreboard_empty();
    endtask


    // ----------------------------------------------------------------
    // Tests
    // ----------------------------------------------------------------
    task automatic test_reset();
        start_test("Reset behavior");

        reset_dut();

        if (o_ipv4_meta_ready !== 1'b1)
            tb_error("DUT not ready for metadata after reset");

        if (o_udp_ipv4_meta_valid !== 1'b0)
            tb_error("UDP metadata valid active after reset");

        if (m_axis_tvalid !== 1'b0)
            tb_error("Payload valid active after reset");

        finish_test();
    endtask


    task automatic test_basic_udp();
        t_ipv4_metadata meta;
        byte_t payload[$];

        start_test("Basic UDP dispatch");
        reset_dut();

        payload = '{8'h11, 8'h22, 8'h33, 8'h44, 8'h55};
        meta = make_meta(8'd17, payload.size(), 1);

        expect_udp_packet(meta, payload);

        send_packet(meta, payload, 0);

        wait_scoreboard_empty();
        finish_test();
    endtask


    task automatic test_non_udp_drop();
        t_ipv4_metadata meta;
        byte_t payload[$];

        start_test("TCP/unsupported protocol drop");
        reset_dut();

        random_payload(24, payload);
        meta = make_meta(8'd6, payload.size(), 2);

        expect_no_outputs = 1'b1;

        send_metadata(meta);

        expect_drop_ready = 1'b1;
        send_payload(payload, 2);
        expect_drop_ready = 1'b0;

        repeat (3)
            @(posedge i_clk);

        expect_no_outputs = 1'b0;

        send_recovery_packet();

        finish_test();
    endtask


    task automatic test_protocol_sweep();
        t_ipv4_metadata meta;
        byte_t payload[$];

        start_test("IPv4 protocol sweep");
        reset_dut();

        payload = '{8'hA1, 8'hB2, 8'hC3};

        for (int protocol = 0; protocol < 256; protocol++) begin
            current_subcase = $sformatf("protocol=%0d", protocol);

            meta = make_meta(protocol[7:0], payload.size(), protocol);

            if (protocol == 17)
                expect_udp_packet(meta, payload);
            else
                expect_no_outputs = 1'b1;

            send_packet(meta, payload, $urandom_range(0,2));

            if (protocol == 17) begin
                wait_scoreboard_empty();
            end else begin
                repeat (2)
                    @(posedge i_clk);

                expect_no_outputs = 1'b0;
            end
        end

        current_subcase = "";
        finish_test();
    endtask


    task automatic test_metadata_backpressure();
        t_ipv4_metadata meta;
        t_ipv4_metadata held;
        byte_t payload[$];

        start_test("UDP metadata backpressure");
        reset_dut();

        random_payload(16, payload);
        meta = make_meta(8'd17, payload.size(), 3);

        expect_udp_packet(meta, payload);

        i_udp_ipv4_meta_ready = 1'b0;

        fork
            begin
                send_packet(meta, payload, 0);
            end

            begin
                while (!o_udp_ipv4_meta_valid)
                    @(posedge i_clk);

                #1;

                held = o_udp_ipv4_meta;

                repeat (10) begin
                    @(posedge i_clk);
                    #1;

                    if (!o_udp_ipv4_meta_valid)
                        tb_error("Metadata valid dropped while stalled");

                    if (o_udp_ipv4_meta !== held)
                        tb_error("Metadata changed while stalled");

                    if (s_axis_tready !== 1'b0)
                        tb_error("Payload input was not blocked during metadata stall");

                    if (m_axis_tvalid !== 1'b0)
                        tb_error("Payload leaked before metadata handshake");
                end

                @(negedge i_clk);
                i_udp_ipv4_meta_ready <= 1'b1;
            end
        join

        wait_scoreboard_empty();
        finish_test();
    endtask


    task automatic test_payload_backpressure();
        t_ipv4_metadata meta;
        byte_t payload[$];

        start_test("UDP payload backpressure");
        reset_dut();

        random_payload(128, payload);
        meta = make_meta(8'd17, payload.size(), 4);

        expect_udp_packet(meta, payload);

        m_axis_tready = 1'b0;

        fork
            begin
                send_packet(meta, payload, 0);
            end

            begin
                while (!o_udp_ipv4_meta_valid)
                    @(posedge i_clk);

                while (expected_meta_q.size() != 0)
                    @(posedge i_clk);

                // Source is now allowed to present payload, but direct
                // pass-through keeps s_axis_tready low until downstream
                // asserts m_axis_tready.
                repeat (8)
                    @(posedge i_clk);

                random_m_ready_enable = 1'b1;
            end
        join

        random_m_ready_enable = 1'b0;
        m_axis_tready = 1'b1;

        wait_scoreboard_empty();
        finish_test();
    endtask


    task automatic test_zero_payload_udp();
        t_ipv4_metadata meta;
        byte_t payload[$];

        start_test("Zero-payload UDP classification");
        reset_dut();

        payload.delete();
        meta = make_meta(8'd17, 0, 5);

        expect_udp_packet(meta, payload);

        send_packet(meta, payload, 0);

        wait_scoreboard_empty();

        repeat (4) begin
            @(posedge i_clk);

            if (m_axis_tvalid)
                tb_error("Payload invented for zero-payload UDP packet");
        end

        send_recovery_packet();

        finish_test();
    endtask


    task automatic test_zero_payload_non_udp();
        t_ipv4_metadata meta;
        byte_t payload[$];

        start_test("Zero-payload unsupported protocol");
        reset_dut();

        payload.delete();
        meta = make_meta(8'd1, 0, 6);

        expect_no_outputs = 1'b1;

        send_packet(meta, payload, 0);

        repeat (4)
            @(posedge i_clk);

        expect_no_outputs = 1'b0;

        send_recovery_packet();

        finish_test();
    endtask


    task automatic test_upstream_gaps();
        t_ipv4_metadata meta;
        byte_t payload[$];

        start_test("Random upstream TVALID gaps");
        reset_dut();

        random_payload(96, payload);
        meta = make_meta(8'd17, payload.size(), 7);

        expect_udp_packet(meta, payload);

        send_packet(meta, payload, 5);

        wait_scoreboard_empty();
        finish_test();
    endtask


    task automatic test_back_to_back();
        t_ipv4_metadata meta1;
        t_ipv4_metadata meta2;

        byte_t payload1[$];
        byte_t payload2[$];

        start_test("Back-to-back packet transactions");
        reset_dut();

        random_payload(31, payload1);
        random_payload(47, payload2);

        meta1 = make_meta(8'd17, payload1.size(), 16'h1111);
        meta2 = make_meta(8'd17, payload2.size(), 16'h2222);

        expect_udp_packet(meta1, payload1);
        expect_udp_packet(meta2, payload2);

        send_packet(meta1, payload1, 0);
        send_packet(meta2, payload2, 0);

        wait_scoreboard_empty();
        finish_test();
    endtask


    task automatic test_randomized();
        t_ipv4_metadata meta;
        byte_t payload[$];

        int protocol;
        int length;

        start_test("500-packet constrained-random regression");
        reset_dut();

        random_m_ready_enable     = 1'b1;
        random_meta_ready_enable = 1'b1;

        for (int packet = 0; packet < 500; packet++) begin
            current_subcase = $sformatf("packet=%0d", packet);

            length = $urandom_range(0, 128);

            // Roughly half UDP, half other protocols.
            if ($urandom_range(0,1))
                protocol = 17;
            else begin
                protocol = $urandom_range(0,255);

                if (protocol == 17)
                    protocol = 6;
            end

            random_payload(length, payload);

            meta = make_meta(
                protocol[7:0],
                payload.size(),
                packet
            );

            if (protocol == 17)
                expect_udp_packet(meta, payload);
            else
                expect_no_outputs = 1'b1;

            send_packet(
                meta,
                payload,
                $urandom_range(0,3)
            );

            if (protocol == 17) begin
                wait_scoreboard_empty();
            end else begin
                repeat (2)
                    @(posedge i_clk);

                expect_no_outputs = 1'b0;
            end
        end

        current_subcase = "";

        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        m_axis_tready         = 1'b1;
        i_udp_ipv4_meta_ready = 1'b1;

        finish_test();
    endtask


    // ----------------------------------------------------------------
    // Test sequence
    // ----------------------------------------------------------------
    initial begin
        tests_run    = 0;
        tests_failed = 0;
        error_count  = 0;

        current_test    = "";
        current_subcase = "";

        scoreboard_enable = 1'b0;
        expect_no_outputs = 1'b0;
        expect_drop_ready = 1'b0;

        random_m_ready_enable     = 1'b0;
        random_meta_ready_enable = 1'b0;

        i_n_reset = 1'b0;

        i_ipv4_meta       = '0;
        i_ipv4_meta_valid = 1'b0;

        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;

        i_udp_ipv4_meta_ready = 1'b1;
        m_axis_tready         = 1'b1;

        repeat (2)
            @(posedge i_clk);

        test_reset();
        test_basic_udp();
        test_non_udp_drop();
        test_protocol_sweep();
        test_metadata_backpressure();
        test_payload_backpressure();
        test_zero_payload_udp();
        test_zero_payload_non_udp();
        test_upstream_gaps();
        test_back_to_back();
        test_randomized();

        repeat (5)
            @(posedge i_clk);

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

        $display("");
        $display("============================================================");
        $display("                    IP_DISPATCH SUMMARY");
        $display("============================================================");
        $display("Tests run    : %0d", tests_run);
        $display("Tests passed : %0d", tests_run - tests_failed);
        $display("Tests failed : %0d", tests_failed);
        $display("Total errors : %0d", error_count);
        $display("============================================================");

        if (error_count == 0) begin
            $display("ALL IP_DISPATCH TESTS PASSED");
            $finish;
        end else begin
            $fatal(1, "IP_DISPATCH TESTBENCH FAILED WITH %0d ERROR(S)", error_count);
        end
    end


    initial begin
        #20ms;
        $fatal(1, "GLOBAL TESTBENCH TIMEOUT");
    end

endmodule
