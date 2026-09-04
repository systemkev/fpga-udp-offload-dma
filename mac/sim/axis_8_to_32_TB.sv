`timescale 1ns/1ps

module axis_8_to_32_TB;

    // ============================================================
    // Configuration
    // ============================================================

    localparam time CLK_PERIOD = 10ns;

    /*
     * AXI4-Stream does not require bytes whose TKEEP bits are zero
     * to contain any particular TDATA value.
     *
     * 0:
     *   Only valid byte lanes are compared.
     *
     * 1:
     *   Also require unused byte lanes to be zero.
     */
    parameter bit STRICT_ZERO_UNUSED_LANES = 1'b0;

    /*
     * 0:
     *   Continue after errors so that multiple problems can be seen.
     *
     * 1:
     *   Stop immediately at the first error.
     */
    parameter bit STOP_ON_FIRST_ERROR = 1'b0;


    // ============================================================
    // DUT interface
    // ============================================================

    logic        i_clk;
    logic        i_n_reset;

    logic [7:0]  s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;

    logic [31:0] m_axis_tdata;
    logic [3:0]  m_axis_tkeep;
    logic        m_axis_tvalid;
    logic        m_axis_tready;
    logic        m_axis_tlast;


    // ============================================================
    // Instantiate DUT
    // ============================================================

    axis_8_to_32 dut (
        .i_clk          (i_clk),
        .i_n_reset      (i_n_reset),

        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),

        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tkeep   (m_axis_tkeep),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast)
    );


    // ============================================================
    // Clock generation
    // ============================================================

    initial begin
        i_clk = 1'b0;

        forever begin
            #(CLK_PERIOD / 2);
            i_clk = ~i_clk;
        end
    end


    // ============================================================
    // Expected AXIS beat type
    // ============================================================

    typedef struct packed {
        logic [31:0] data;
        logic [3:0]  keep;
        logic        last;
        logic [31:0] packet_id;
        logic [31:0] beat_index;
    } expected_beat_t;


    expected_beat_t expected_q[$];

    int unsigned next_packet_id;


    // ============================================================
    // Downstream ready generation modes
    // ============================================================

    typedef enum logic [1:0] {
        READY_ALWAYS,
        READY_RANDOM_75,
        READY_RANDOM_25,
        READY_NEVER
    } ready_mode_t;

    ready_mode_t ready_mode;


    /*
     * TREADY changes only on the negative edge.
     *
     * This makes the TB deterministic and avoids races with the DUT,
     * because the DUT samples signals on the positive edge.
     */
    always @(negedge i_clk) begin

        if (!i_n_reset) begin
            m_axis_tready <= 1'b0;
        end
        else begin

            case (ready_mode)

                READY_ALWAYS: begin
                    m_axis_tready <= 1'b1;
                end

                READY_RANDOM_75: begin
                    m_axis_tready <=
                        ($urandom_range(0, 99) < 75);
                end

                READY_RANDOM_25: begin
                    m_axis_tready <=
                        ($urandom_range(0, 99) < 25);
                end

                READY_NEVER: begin
                    m_axis_tready <= 1'b0;
                end

                default: begin
                    m_axis_tready <= 1'b0;
                end

            endcase
        end
    end


    // ============================================================
    // Statistics / lightweight coverage counters
    // ============================================================

    int unsigned error_count;

    int unsigned output_beats_checked;

    int unsigned output_stall_cycles;
    int unsigned input_backpressure_cycles;

    int unsigned simultaneous_input_output_handshakes;
    int unsigned back_to_back_packet_boundaries;

    int unsigned keep_0001_count;
    int unsigned keep_0011_count;
    int unsigned keep_0111_count;
    int unsigned keep_1111_count;

    int unsigned nonfinal_full_beat_count;


    // ============================================================
    // Error reporting
    // ============================================================

    task automatic report_error(
        input string msg
    );

        begin

            error_count = error_count + 1;

            $error(
                "[%0t] TB ERROR: %s",
                $time,
                msg
            );

            if (STOP_ON_FIRST_ERROR) begin

                $fatal(
                    1,
                    "STOP_ON_FIRST_ERROR is enabled."
                );

            end

        end

    endtask


    // ============================================================
    // TKEEP -> TDATA mask
    // ============================================================

    function automatic logic [31:0] keep_to_mask(
        input logic [3:0] keep
    );

        logic [31:0] mask;
        int lane;

        begin

            mask = 32'b0;

            for (lane = 0; lane < 4; lane = lane + 1) begin

                if (keep[lane]) begin
                    mask[lane*8 +: 8] = 8'hFF;
                end
                else begin
                    mask[lane*8 +: 8] = 8'h00;
                end

            end

            keep_to_mask = mask;

        end

    endfunction


    // ============================================================
    // Reference model
    //
    // Convert one byte packet into expected AXIS32 beats.
    //
    // Example:
    //
    // input bytes:
    //
    //      11 22 33 44 55
    //
    // expected:
    //
    //      beat 0:
    //          TDATA = 44332211
    //          TKEEP = 1111
    //          TLAST = 0
    //
    //      beat 1:
    //          TDATA valid byte = 55
    //          TKEEP = 0001
    //          TLAST = 1
    // ============================================================

    task automatic enqueue_expected_packet(
        input  byte unsigned packet[],
        output int unsigned  packet_id
    );

        expected_beat_t exp;

        int unsigned byte_index;
        int unsigned beat_index;
        int unsigned lane;

        begin

            if (packet.size() == 0) begin

                $fatal(
                    1,
                    "Zero-length packet cannot be represented by this input interface."
                );

            end


            packet_id = next_packet_id;
            next_packet_id = next_packet_id + 1;

            byte_index = 0;
            beat_index = 0;


            while (byte_index < packet.size()) begin

                exp.data       = 32'b0;
                exp.keep       = 4'b0000;
                exp.last       = 1'b0;
                exp.packet_id  = packet_id;
                exp.beat_index = beat_index;


                for (lane = 0; lane < 4; lane = lane + 1) begin

                    if ((byte_index + lane) < packet.size()) begin

                        exp.data[lane*8 +: 8] =
                            packet[byte_index + lane];

                        exp.keep[lane] = 1'b1;

                    end

                end


                if ((byte_index + 4) >= packet.size()) begin
                    exp.last = 1'b1;
                end
                else begin
                    exp.last = 1'b0;
                end


                expected_q.push_back(exp);

                byte_index = byte_index + 4;
                beat_index = beat_index + 1;

            end

        end

    endtask


    // ============================================================
    // Output scoreboard
    //
    // Only compare a beat when a real AXIS handshake occurs:
    //
    //      TVALID && TREADY
    //
    // This means arbitrary timing/stalling is allowed.
    // ============================================================

    always @(posedge i_clk) begin : scoreboard

        expected_beat_t exp;
        logic [31:0] valid_byte_mask;

        if (i_n_reset) begin

            if (m_axis_tvalid && m_axis_tready) begin

                output_beats_checked =
                    output_beats_checked + 1;


                if (expected_q.size() == 0) begin

                    report_error(
                        $sformatf(
                            "Unexpected output beat: TDATA=%08h TKEEP=%04b TLAST=%0b",
                            m_axis_tdata,
                            m_axis_tkeep,
                            m_axis_tlast
                        )
                    );

                end
                else begin

                    exp = expected_q.pop_front();

                    valid_byte_mask =
                        keep_to_mask(exp.keep);


                    // --------------------------------------------
                    // TKEEP
                    // --------------------------------------------

                    if (m_axis_tkeep !== exp.keep) begin

                        report_error(
                            $sformatf(
                                "Packet %0d beat %0d: TKEEP mismatch. expected=%04b actual=%04b",
                                exp.packet_id,
                                exp.beat_index,
                                exp.keep,
                                m_axis_tkeep
                            )
                        );

                    end


                    // --------------------------------------------
                    // TLAST
                    // --------------------------------------------

                    if (m_axis_tlast !== exp.last) begin

                        report_error(
                            $sformatf(
                                "Packet %0d beat %0d: TLAST mismatch. expected=%0b actual=%0b",
                                exp.packet_id,
                                exp.beat_index,
                                exp.last,
                                m_axis_tlast
                            )
                        );

                    end


                    // --------------------------------------------
                    // TDATA
                    //
                    // Only valid lanes are required by AXI.
                    // --------------------------------------------

                    if (
                        (m_axis_tdata & valid_byte_mask)
                        !==
                        (exp.data & valid_byte_mask)
                    ) begin

                        report_error(
                            $sformatf(
                                "Packet %0d beat %0d: TDATA mismatch. expected=%08h actual=%08h keep=%04b",
                                exp.packet_id,
                                exp.beat_index,
                                exp.data,
                                m_axis_tdata,
                                exp.keep
                            )
                        );

                    end


                    // --------------------------------------------
                    // Optional strict zero fill check
                    // --------------------------------------------

                    if (STRICT_ZERO_UNUSED_LANES) begin

                        if (m_axis_tdata !== exp.data) begin

                            report_error(
                                $sformatf(
                                    "Packet %0d beat %0d: unused TDATA lanes are not zero. expected=%08h actual=%08h",
                                    exp.packet_id,
                                    exp.beat_index,
                                    exp.data,
                                    m_axis_tdata
                                )
                            );

                        end

                    end

                end

            end

        end

    end


    // ============================================================
    // Coverage / activity monitoring
    // ============================================================

    logic previous_cycle_was_packet_end;

    always @(posedge i_clk) begin

        if (!i_n_reset) begin

            previous_cycle_was_packet_end <= 1'b0;

        end
        else begin

            // --------------------------------------------
            // Output stall
            // --------------------------------------------

            if (m_axis_tvalid && !m_axis_tready) begin

                output_stall_cycles =
                    output_stall_cycles + 1;

            end


            // --------------------------------------------
            // Input backpressure
            // --------------------------------------------

            if (s_axis_tvalid && !s_axis_tready) begin

                input_backpressure_cycles =
                    input_backpressure_cycles + 1;

            end


            // --------------------------------------------
            // Simultaneous input/output transfer
            // --------------------------------------------

            if (
                s_axis_tvalid &&
                s_axis_tready &&
                m_axis_tvalid &&
                m_axis_tready
            ) begin

                simultaneous_input_output_handshakes =
                    simultaneous_input_output_handshakes + 1;

            end


            // --------------------------------------------
            // Zero-gap packet boundary detection
            // --------------------------------------------

            if (s_axis_tvalid && s_axis_tready) begin

                if (previous_cycle_was_packet_end) begin

                    back_to_back_packet_boundaries =
                        back_to_back_packet_boundaries + 1;

                end

                previous_cycle_was_packet_end <=
                    s_axis_tlast;

            end
            else begin

                previous_cycle_was_packet_end <=
                    1'b0;

            end


            // --------------------------------------------
            // Output TKEEP observations
            // --------------------------------------------

            if (m_axis_tvalid && m_axis_tready) begin

                case (m_axis_tkeep)

                    4'b0001: begin
                        keep_0001_count =
                            keep_0001_count + 1;
                    end

                    4'b0011: begin
                        keep_0011_count =
                            keep_0011_count + 1;
                    end

                    4'b0111: begin
                        keep_0111_count =
                            keep_0111_count + 1;
                    end

                    4'b1111: begin
                        keep_1111_count =
                            keep_1111_count + 1;
                    end

                    default: begin
                        // Illegal TKEEP is caught separately.
                    end

                endcase


                if (!m_axis_tlast) begin

                    nonfinal_full_beat_count =
                        nonfinal_full_beat_count + 1;

                end

            end

        end

    end


    // ============================================================
    // Assertions
    //
    // If your Vivado/XSim version gives an SVA compatibility error,
    // temporarily add:
    //
    //      `define NO_SVA
    //
    // before this module.
    //
    // Do NOT disable them just because an assertion itself FAILS.
    // A failing assertion is usually exposing a DUT problem.
    // ============================================================

`ifndef NO_SVA


    // ============================================================
    // AXIS rule:
    //
    // Once TVALID is asserted, if TREADY is low, all payload/control
    // information must remain stable.
    // ============================================================

    property p_output_stable_when_stalled;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        (m_axis_tvalid && !m_axis_tready)

        |=>

        (
            m_axis_tvalid &&
            $stable(m_axis_tdata) &&
            $stable(m_axis_tkeep) &&
            $stable(m_axis_tlast)
        );

    endproperty


    a_output_stable_when_stalled:
        assert property (p_output_stable_when_stalled)
        else begin

            report_error(
                "AXIS OUTPUT VIOLATION: output changed while TVALID=1 and TREADY=0."
            );

        end


    // ============================================================
    // Verify that the TESTBENCH source itself obeys AXI.
    //
    // If this assertion fails, the TB driver is wrong.
    // ============================================================

    property p_input_stable_when_stalled;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        (s_axis_tvalid && !s_axis_tready)

        |=>

        (
            s_axis_tvalid &&
            $stable(s_axis_tdata) &&
            $stable(s_axis_tlast)
        );

    endproperty


    a_input_stable_when_stalled:
        assert property (p_input_stable_when_stalled)
        else begin

            $fatal(
                1,
                "TESTBENCH BUG: AXIS source changed its data while stalled."
            );

        end


    // ============================================================
    // TKEEP legality
    //
    // For an 8 -> 32 packer where bytes fill from lane zero upward,
    // only these patterns are valid.
    // ============================================================

    property p_legal_tkeep;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        m_axis_tvalid

        |->

        (
            (m_axis_tkeep == 4'b0001) ||
            (m_axis_tkeep == 4'b0011) ||
            (m_axis_tkeep == 4'b0111) ||
            (m_axis_tkeep == 4'b1111)
        );

    endproperty


    a_legal_tkeep:
        assert property (p_legal_tkeep)
        else begin

            report_error(
                $sformatf(
                    "Illegal TKEEP value observed: %04b",
                    m_axis_tkeep
                )
            );

        end


    // ============================================================
    // Any non-final output beat must contain four valid bytes.
    // ============================================================

    property p_nonfinal_beat_is_full;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        (m_axis_tvalid && !m_axis_tlast)

        |->

        (m_axis_tkeep == 4'b1111);

    endproperty


    a_nonfinal_beat_is_full:
        assert property (p_nonfinal_beat_is_full)
        else begin

            report_error(
                "A non-final output beat did not have TKEEP=1111."
            );

        end


    // ============================================================
    // TLAST makes no sense unless TVALID is also asserted.
    // ============================================================

    property p_last_implies_valid;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        m_axis_tlast

        |->

        m_axis_tvalid;

    endproperty


    a_last_implies_valid:
        assert property (p_last_implies_valid)
        else begin

            report_error(
                "TLAST was asserted while TVALID was low."
            );

        end


    // ============================================================
    // No X/Z bits on a valid output transaction.
    // ============================================================

    property p_no_x_on_valid_output;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        m_axis_tvalid

        |->

        !$isunknown(
            {
                m_axis_tdata,
                m_axis_tkeep,
                m_axis_tlast
            }
        );

    endproperty


    a_no_x_on_valid_output:
        assert property (p_no_x_on_valid_output)
        else begin

            report_error(
                "X or Z detected on a valid AXIS output transaction."
            );

        end


    // ============================================================
    // OPTIONAL WHITE-BOX ASSERTIONS
    //
    // These inspect internal DUT state.
    //
    // Enable by adding:
    //
    //      `define AXIS_8_TO_32_WHITEBOX
    //
    // before this module.
    //
    // The main scoreboard does NOT require these.
    // ============================================================

`ifdef AXIS_8_TO_32_WHITEBOX


    // ------------------------------------------------------------
    // Once an input TLAST is accepted, the next packet must begin
    // at byte lane zero.
    // ------------------------------------------------------------

    property p_tlast_resets_byte_count;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        (
            s_axis_tvalid &&
            s_axis_tready &&
            s_axis_tlast
        )

        |=>

        (dut.byte_cnt == 2'd0);

    endproperty


    a_tlast_resets_byte_count:
        assert property (p_tlast_resets_byte_count)
        else begin

            report_error(
                "WHITEBOX: byte_cnt did not return to zero after accepting input TLAST."
            );

        end


    // ------------------------------------------------------------
    // Every accepted fourth byte completes a 32-bit beat.
    // ------------------------------------------------------------

    property p_fourth_byte_creates_output;

        @(posedge i_clk)
        disable iff (!i_n_reset)

        (
            s_axis_tvalid &&
            s_axis_tready &&
            (dut.byte_cnt == 2'd3)
        )

        |=>

        m_axis_tvalid;

    endproperty


    a_fourth_byte_creates_output:
        assert property (p_fourth_byte_creates_output)
        else begin

            report_error(
                "WHITEBOX: an accepted fourth byte did not produce an output TVALID."
            );

        end


`endif
`endif


    // ============================================================
    // Pattern packet generator
    // ============================================================

    task automatic make_pattern_packet(
        input  int unsigned  length,
        input  byte unsigned base,
        output byte unsigned packet[]
    );

        int unsigned i;

        begin

            packet = new[length];

            for (i = 0; i < length; i = i + 1) begin

                packet[i] = base + i;

            end

        end

    endtask


    // ============================================================
    // Random packet generator
    // ============================================================

    task automatic make_random_packet(
        input  int unsigned  length,
        output byte unsigned packet[]
    );

        int unsigned i;

        begin

            packet = new[length];

            for (i = 0; i < length; i = i + 1) begin

                packet[i] =
                    $urandom_range(0, 255);

            end

        end

    endtask


    // ============================================================
    // Send one byte
    //
    // IMPORTANT:
    //
    // Once TVALID is asserted, this routine does not change TDATA
    // or TLAST until TREADY has been observed high at a rising edge.
    //
    // Therefore the TB source itself follows AXI correctly.
    // ============================================================

    task automatic drive_byte(
        input byte unsigned data,
        input bit           last
    );

        begin

            @(negedge i_clk);

            s_axis_tdata  <= data;
            s_axis_tlast  <= last;
            s_axis_tvalid <= 1'b1;


            // Wait until the DUT accepts this byte.
            do begin

                @(posedge i_clk);

            end
            while (!s_axis_tready);

        end

    endtask


    // ============================================================
    // Send one complete packet
    //
    // gap_cycles = 0:
    //
    //      no idle cycle is intentionally inserted after TLAST.
    //
    // This allows true back-to-back AXIS packets.
    // ============================================================

    task automatic send_packet(
        input byte unsigned packet[],
        input int unsigned  gap_cycles
    );

        int unsigned packet_id;
        int unsigned i;

        begin

            enqueue_expected_packet(
                packet,
                packet_id
            );


            for (i = 0; i < packet.size(); i = i + 1) begin

                drive_byte(
                    packet[i],
                    (i == (packet.size() - 1))
                );

            end


            if (gap_cycles > 0) begin

                @(negedge i_clk);

                s_axis_tvalid <= 1'b0;
                s_axis_tlast  <= 1'b0;
                s_axis_tdata  <= 8'b0;


                repeat (gap_cycles) begin
                    @(posedge i_clk);
                end

            end

        end

    endtask


    // ============================================================
    // Send a packet with random TVALID pauses between bytes.
    //
    // Tests whether partially packed words survive source stalls.
    // ============================================================

    task automatic send_packet_with_random_gaps(
        input byte unsigned packet[],
        input int unsigned  max_internal_gap,
        input int unsigned  packet_gap
    );

        int unsigned packet_id;
        int unsigned i;
        int unsigned gap;

        begin

            enqueue_expected_packet(
                packet,
                packet_id
            );


            for (i = 0; i < packet.size(); i = i + 1) begin

                drive_byte(
                    packet[i],
                    (i == (packet.size() - 1))
                );


                if (i != (packet.size() - 1)) begin

                    gap =
                        $urandom_range(
                            0,
                            max_internal_gap
                        );


                    if (gap != 0) begin

                        @(negedge i_clk);

                        s_axis_tvalid <= 1'b0;
                        s_axis_tlast  <= 1'b0;


                        repeat (gap) begin
                            @(posedge i_clk);
                        end

                    end

                end

            end


            if (packet_gap > 0) begin

                @(negedge i_clk);

                s_axis_tvalid <= 1'b0;
                s_axis_tlast  <= 1'b0;


                repeat (packet_gap) begin
                    @(posedge i_clk);
                end

            end

        end

    endtask


    // ============================================================
    // Stop input source
    // ============================================================

    task automatic stop_source();

        begin

            @(negedge i_clk);

            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
            s_axis_tdata  <= 8'b0;

        end

    endtask


    // ============================================================
    // Reset DUT
    //
    // Any outstanding expected packet is intentionally flushed,
    // because reset aborts the transaction.
    // ============================================================

    task automatic reset_dut(
        input string reason
    );

        begin

            $display("");
            $display(
                "[%0t] RESET: %s",
                $time,
                reason
            );


            if (expected_q.size() != 0) begin

                $display(
                    "Discarding %0d pending expected beat(s) because reset aborts them.",
                    expected_q.size()
                );

                expected_q.delete();

            end


            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
            s_axis_tdata  = 8'b0;

            i_n_reset = 1'b0;


            repeat (4) begin
                @(posedge i_clk);
            end


            #1;


            if (m_axis_tvalid !== 1'b0) begin

                report_error(
                    "m_axis_tvalid was not cleared by reset."
                );

            end


            if (m_axis_tlast !== 1'b0) begin

                report_error(
                    "m_axis_tlast was not cleared by reset."
                );

            end


            i_n_reset = 1'b1;


            repeat (2) begin
                @(posedge i_clk);
            end

        end

    endtask


    // ============================================================
    // Wait for all expected output to be consumed
    // ============================================================

    task automatic drain(
        input string       test_name,
        input int unsigned timeout_cycles
    );

        int unsigned cycles;

        begin

            cycles = 0;


            while (
                (expected_q.size() != 0) ||
                m_axis_tvalid
            ) begin

                @(posedge i_clk);

                cycles = cycles + 1;


                if (cycles >= timeout_cycles) begin

                    report_error(
                        $sformatf(
                            "%s: timeout waiting for output. %0d expected beats remain, TVALID=%0b",
                            test_name,
                            expected_q.size(),
                            m_axis_tvalid
                        )
                    );

                    return;

                end

            end


            /*
             * Give the DUT two extra cycles.
             *
             * If a bogus delayed beat appears, the scoreboard will
             * report it as unexpected.
             */
            repeat (2) begin
                @(posedge i_clk);
            end

        end

    endtask


    // ============================================================
    // Generic isolated length test
    // ============================================================

    task automatic test_length(
        input int unsigned  length,
        input byte unsigned base
    );

        byte unsigned packet[];
        string test_name;

        begin

            test_name =
                $sformatf(
                    "packet length %0d",
                    length
                );


            $display("");
            $display(
                "============================================================"
            );

            $display(
                "TEST: %s",
                test_name
            );

            $display(
                "============================================================"
            );


            reset_dut(
                test_name
            );

            ready_mode =
                READY_ALWAYS;


            make_pattern_packet(
                length,
                base,
                packet
            );


            send_packet(
                packet,
                1
            );


            stop_source();


            drain(
                test_name,
                500
            );

        end

    endtask


    // ============================================================
    // Test: idle
    // ============================================================

    task automatic test_idle();

        int unsigned i;

        begin

            $display("");
            $display(
                "TEST: idle behavior"
            );


            reset_dut(
                "idle test"
            );

            ready_mode =
                READY_ALWAYS;


            for (i = 0; i < 50; i = i + 1) begin

                @(posedge i_clk);


                if (m_axis_tvalid) begin

                    report_error(
                        "DUT generated TVALID while no input packet existed."
                    );

                end

            end

        end

    endtask


    // ============================================================
    // Test: reset while a partial 32-bit word is buffered
    // ============================================================

    task automatic test_reset_mid_partial_word();

        byte unsigned packet[];

        begin

            $display("");
            $display(
                "TEST: reset with partial input word buffered"
            );


            reset_dut(
                "partial word reset setup"
            );

            ready_mode =
                READY_ALWAYS;


            /*
             * Send two bytes WITHOUT TLAST.
             *
             * No output should exist yet.
             */
            drive_byte(
                8'hAA,
                1'b0
            );

            drive_byte(
                8'hBB,
                1'b0
            );


            reset_dut(
                "reset after two buffered bytes"
            );


            /*
             * New packet after reset must have no dependency on AA BB.
             */
            make_pattern_packet(
                3,
                8'h31,
                packet
            );


            send_packet(
                packet,
                1
            );


            stop_source();


            drain(
                "reset mid partial word",
                200
            );

        end

    endtask


    // ============================================================
    // Test: output is valid but downstream refuses it
    //
    // Output must remain completely stable.
    // ============================================================

    task automatic test_output_hold_under_stall();

        byte unsigned packet[];

        begin

            $display("");
            $display(
                "TEST: hold completed output beat while downstream is stalled"
            );


            reset_dut(
                "output stall hold test"
            );

            ready_mode =
                READY_NEVER;


            make_pattern_packet(
                4,
                8'h10,
                packet
            );


            send_packet(
                packet,
                0
            );


            stop_source();


            /*
             * Allow the output to sit stalled for several clocks.
             *
             * p_output_stable_when_stalled checks stability.
             */
            repeat (8) begin
                @(posedge i_clk);
            end


            if (!m_axis_tvalid) begin

                report_error(
                    "Expected a stalled valid output beat, but TVALID was low."
                );

            end


            ready_mode =
                READY_ALWAYS;


            drain(
                "output hold under stall",
                200
            );

        end

    endtask


    // ============================================================
    // Test: reset while an output beat is stalled
    //
    // Reset must flush TVALID and old state.
    // ============================================================

    task automatic test_reset_while_output_stalled();

        byte unsigned packet_before_reset[];
        byte unsigned packet_after_reset[];

        begin

            $display("");
            $display(
                "TEST: reset while output beat is stalled"
            );


            reset_dut(
                "reset while output stalled setup"
            );

            ready_mode =
                READY_NEVER;


            make_pattern_packet(
                4,
                8'h80,
                packet_before_reset
            );


            send_packet(
                packet_before_reset,
                0
            );


            stop_source();


            repeat (4) begin
                @(posedge i_clk);
            end


            if (!m_axis_tvalid) begin

                report_error(
                    "Expected TVALID before asserting reset during stalled-output test."
                );

            end


            /*
             * This resets the DUT and intentionally deletes the expected
             * old output transaction.
             */
            reset_dut(
                "assert reset while old output is stalled"
            );


            ready_mode =
                READY_ALWAYS;


            make_pattern_packet(
                5,
                8'h21,
                packet_after_reset
            );


            send_packet(
                packet_after_reset,
                1
            );


            stop_source();


            drain(
                "reset while output stalled",
                300
            );

        end

    endtask


    // ============================================================
    // CRITICAL CORNER CASE
    //
    // Packer receives:
    //
    //      byte 0
    //      byte 1
    //      byte 2
    //      byte 3
    //
    // byte 3 completes a full output word.
    //
    // Downstream TREADY is 0.
    //
    // Correct behavior:
    //
    //      m_axis_tvalid = 1
    //      full word held stable
    //      s_axis_tready = 0
    //
    // until downstream accepts the word.
    //
    // Your ORIGINAL RTL implementation should fail this test because
    // it did not assert TVALID for the fourth byte unless TLAST=1.
    // ============================================================

    task automatic test_fourth_byte_while_downstream_stalled();

        byte unsigned packet[];

        begin

            $display("");
            $display(
                "TEST: fourth byte completes word while downstream is stalled"
            );


            reset_dut(
                "critical fourth-byte/downstream-stall test"
            );


            ready_mode =
                READY_NEVER;


            make_pattern_packet(
                5,
                8'hA0,
                packet
            );


            fork

                begin

                    send_packet(
                        packet,
                        0
                    );

                    stop_source();

                end


                begin

                    /*
                     * Correct DUT should eventually be holding the
                     * first 4-byte output word while byte 5 waits.
                     */
                    repeat (10) begin
                        @(posedge i_clk);
                    end

                    ready_mode =
                        READY_ALWAYS;

                end

            join


            drain(
                "fourth byte while downstream stalled",
                500
            );

        end

    endtask


    // ============================================================
    // Back-to-back packets
    //
    // NO intentionally inserted TVALID=0 cycle between packets.
    //
    // This specifically targets packet-state reset bugs.
    // ============================================================

    task automatic test_back_to_back_packets();

        byte unsigned p1[];
        byte unsigned p2[];
        byte unsigned p3[];
        byte unsigned p4[];
        byte unsigned p5[];
        byte unsigned p6[];
        byte unsigned p7[];
        byte unsigned p8[];

        begin

            $display("");
            $display(
                "TEST: true zero-gap back-to-back packets"
            );


            reset_dut(
                "back-to-back packet test"
            );


            ready_mode =
                READY_ALWAYS;


            /*
             * Deliberately exercise every possible TLAST lane.
             */
            make_pattern_packet(1, 8'h10, p1);
            make_pattern_packet(2, 8'h20, p2);
            make_pattern_packet(3, 8'h30, p3);
            make_pattern_packet(4, 8'h40, p4);
            make_pattern_packet(5, 8'h50, p5);
            make_pattern_packet(6, 8'h60, p6);
            make_pattern_packet(7, 8'h70, p7);
            make_pattern_packet(8, 8'h80, p8);


            send_packet(p1, 0);
            send_packet(p2, 0);
            send_packet(p3, 0);
            send_packet(p4, 0);
            send_packet(p5, 0);
            send_packet(p6, 0);
            send_packet(p7, 0);
            send_packet(p8, 0);


            stop_source();


            drain(
                "back-to-back packet test",
                1000
            );

        end

    endtask


    // ============================================================
    // Random source-side TVALID gaps
    // ============================================================

    task automatic test_random_source_gaps();

        byte unsigned packet[];

        int unsigned n;
        int unsigned length;
        int unsigned packet_gap;

        begin

            $display("");
            $display(
                "TEST: randomized source-side TVALID gaps"
            );


            reset_dut(
                "random source gap test"
            );


            ready_mode =
                READY_ALWAYS;


            for (n = 0; n < 100; n = n + 1) begin

                length =
                    $urandom_range(
                        1,
                        100
                    );


                packet_gap =
                    $urandom_range(
                        0,
                        2
                    );


                make_random_packet(
                    length,
                    packet
                );


                send_packet_with_random_gaps(
                    packet,
                    4,
                    packet_gap
                );

            end


            stop_source();


            drain(
                "random source gaps",
                10000
            );

        end

    endtask


    // ============================================================
    // Random downstream backpressure
    // ============================================================

    task automatic test_random_backpressure();

        byte unsigned packet[];

        int unsigned n;
        int unsigned length;
        int unsigned packet_gap;

        begin

            $display("");
            $display(
                "TEST: randomized downstream TREADY"
            );


            reset_dut(
                "random downstream backpressure"
            );


            ready_mode =
                READY_RANDOM_75;


            for (n = 0; n < 250; n = n + 1) begin

                length =
                    $urandom_range(
                        1,
                        256
                    );


                packet_gap =
                    $urandom_range(
                        0,
                        2
                    );


                make_random_packet(
                    length,
                    packet
                );


                send_packet(
                    packet,
                    packet_gap
                );

            end


            stop_source();


            drain(
                "random downstream backpressure",
                30000
            );

        end

    endtask


    // ============================================================
    // Random BOTH SIDES
    //
    // Random source gaps + random destination stalls simultaneously.
    // ============================================================

    task automatic test_random_both_sides();

        byte unsigned packet[];

        int unsigned n;
        int unsigned length;
        int unsigned packet_gap;

        begin

            $display("");
            $display(
                "TEST: simultaneous randomized source gaps and downstream stalls"
            );


            reset_dut(
                "random both sides"
            );


            ready_mode =
                READY_RANDOM_75;


            for (n = 0; n < 150; n = n + 1) begin

                length =
                    $urandom_range(
                        1,
                        300
                    );


                packet_gap =
                    $urandom_range(
                        0,
                        2
                    );


                make_random_packet(
                    length,
                    packet
                );


                send_packet_with_random_gaps(
                    packet,
                    3,
                    packet_gap
                );

            end


            stop_source();


            drain(
                "random both sides",
                30000
            );

        end

    endtask


    // ============================================================
    // Heavy randomized stress
    //
    // Only approximately 25% downstream readiness.
    // ============================================================

    task automatic test_heavy_random_stress();

        byte unsigned packet[];

        int unsigned n;
        int unsigned length;

        begin

            $display("");
            $display(
                "TEST: heavy randomized backpressure stress"
            );


            reset_dut(
                "heavy randomized stress"
            );


            ready_mode =
                READY_RANDOM_25;


            for (n = 0; n < 50; n = n + 1) begin

                length =
                    $urandom_range(
                        1,
                        1472
                    );


                make_random_packet(
                    length,
                    packet
                );


                /*
                 * No intentional idle packet gap.
                 */
                send_packet(
                    packet,
                    0
                );

            end


            stop_source();


            drain(
                "heavy randomized stress",
                100000
            );

        end

    endtask


    // ============================================================
    // Maximum / near-maximum intended UDP payloads
    // ============================================================

    task automatic test_large_payloads();

        byte unsigned packet_1471[];
        byte unsigned packet_1472[];

        begin

            $display("");
            $display(
                "TEST: 1471-byte and 1472-byte payloads"
            );


            reset_dut(
                "large payload test"
            );


            ready_mode =
                READY_RANDOM_75;


            make_random_packet(
                1471,
                packet_1471
            );


            make_random_packet(
                1472,
                packet_1472
            );


            send_packet(
                packet_1471,
                0
            );


            send_packet(
                packet_1472,
                1
            );


            stop_source();


            drain(
                "1471/1472 byte payloads",
                30000
            );

        end

    endtask


    // ============================================================
    // Final coverage sanity checks
    //
    // These make sure that the testbench actually exercised important
    // situations instead of merely claiming that it did.
    // ============================================================

    task automatic check_test_coverage();

        begin

            $display("");
            $display(
                "============================================================"
            );

            $display(
                "TEST COVERAGE SUMMARY"
            );

            $display(
                "============================================================"
            );


            $display(
                "TKEEP 0001 observed                 : %0d",
                keep_0001_count
            );

            $display(
                "TKEEP 0011 observed                 : %0d",
                keep_0011_count
            );

            $display(
                "TKEEP 0111 observed                 : %0d",
                keep_0111_count
            );

            $display(
                "TKEEP 1111 observed                 : %0d",
                keep_1111_count
            );

            $display(
                "Non-final full output beats         : %0d",
                nonfinal_full_beat_count
            );

            $display(
                "Output stall cycles                 : %0d",
                output_stall_cycles
            );

            $display(
                "Input backpressure cycles           : %0d",
                input_backpressure_cycles
            );

            $display(
                "Simultaneous input/output handshakes: %0d",
                simultaneous_input_output_handshakes
            );

            $display(
                "Zero-gap packet boundaries          : %0d",
                back_to_back_packet_boundaries
            );


            if (keep_0001_count == 0) begin

                report_error(
                    "Coverage failure: never observed TKEEP=0001."
                );

            end


            if (keep_0011_count == 0) begin

                report_error(
                    "Coverage failure: never observed TKEEP=0011."
                );

            end


            if (keep_0111_count == 0) begin

                report_error(
                    "Coverage failure: never observed TKEEP=0111."
                );

            end


            if (keep_1111_count == 0) begin

                report_error(
                    "Coverage failure: never observed TKEEP=1111."
                );

            end


            if (nonfinal_full_beat_count == 0) begin

                report_error(
                    "Coverage failure: never observed a non-final full output beat."
                );

            end


            if (output_stall_cycles == 0) begin

                report_error(
                    "Coverage failure: output was never stalled."
                );

            end


            if (input_backpressure_cycles == 0) begin

                report_error(
                    "Coverage failure: DUT never backpressured its input."
                );

            end


            if (simultaneous_input_output_handshakes == 0) begin

                report_error(
                    "Coverage failure: never exercised a simultaneous input/output handshake."
                );

            end


            if (back_to_back_packet_boundaries == 0) begin

                report_error(
                    "Coverage failure: never exercised true zero-gap packet boundaries."
                );

            end

        end

    endtask


    // ============================================================
    // Global watchdog
    //
    // Prevent a broken DUT/TB from simulating forever.
    // ============================================================

    initial begin : watchdog

        repeat (2_000_000) begin
            @(posedge i_clk);
        end


        $fatal(
            1,
            "GLOBAL TESTBENCH WATCHDOG EXPIRED."
        );

    end


    // ============================================================
    // Main test sequence
    // ============================================================

    initial begin : main_test

        int unsigned seed;
        int unsigned seed_dummy;


        // --------------------------------------------------------
        // Initial signal values
        // --------------------------------------------------------

        i_n_reset =
            1'b0;

        s_axis_tdata =
            8'b0;

        s_axis_tvalid =
            1'b0;

        s_axis_tlast =
            1'b0;

        ready_mode =
            READY_ALWAYS;


        error_count =
            0;

        output_beats_checked =
            0;

        output_stall_cycles =
            0;

        input_backpressure_cycles =
            0;

        simultaneous_input_output_handshakes =
            0;

        back_to_back_packet_boundaries =
            0;

        keep_0001_count =
            0;

        keep_0011_count =
            0;

        keep_0111_count =
            0;

        keep_1111_count =
            0;

        nonfinal_full_beat_count =
            0;

        next_packet_id =
            0;

        previous_cycle_was_packet_end =
            1'b0;


        // --------------------------------------------------------
        // Reproducible random seed
        //
        // Command-line override example:
        //
        //      +SEED=12345
        // --------------------------------------------------------

        seed =
            32'h8A32_2026;


        if ($value$plusargs("SEED=%d", seed)) begin

            $display(
                "Using command-line random seed: %0d",
                seed
            );

        end
        else begin

            $display(
                "Using default random seed: %0d",
                seed
            );

        end


        seed_dummy =
            $urandom(seed);


        // ========================================================
        // Initial reset
        // ========================================================

        reset_dut(
            "initial reset"
        );


        // ========================================================
        // 1. Idle behavior
        // ========================================================

        test_idle();


        // ========================================================
        // 2. Basic 1/2/3/4-byte cases
        //
        // Exercise every possible final TKEEP.
        // ========================================================

        test_length(
            1,
            8'h10
        );

        test_length(
            2,
            8'h20
        );

        test_length(
            3,
            8'h30
        );

        test_length(
            4,
            8'h40
        );


        // ========================================================
        // 3. First cases containing non-final full beats
        //
        // The ORIGINAL buggy DUT should begin failing here.
        // ========================================================

        test_length(
            5,
            8'h50
        );

        test_length(
            6,
            8'h60
        );

        test_length(
            7,
            8'h70
        );

        test_length(
            8,
            8'h80
        );

        test_length(
            9,
            8'h90
        );


        // ========================================================
        // 4. Important modulo-4 boundaries
        // ========================================================

        test_length(
            15,
            8'h11
        );

        test_length(
            16,
            8'h22
        );

        test_length(
            17,
            8'h33
        );


        test_length(
            31,
            8'h44
        );

        test_length(
            32,
            8'h55
        );

        test_length(
            33,
            8'h66
        );


        test_length(
            63,
            8'h77
        );

        test_length(
            64,
            8'h88
        );

        test_length(
            65,
            8'h99
        );


        test_length(
            255,
            8'hAA
        );

        test_length(
            256,
            8'hBB
        );

        test_length(
            257,
            8'hCC
        );


        // ========================================================
        // 5. Additional realistic packet boundaries
        // ========================================================

        test_length(
            511,
            8'h11
        );

        test_length(
            512,
            8'h22
        );

        test_length(
            513,
            8'h33
        );


        test_length(
            1023,
            8'h44
        );

        test_length(
            1024,
            8'h55
        );

        test_length(
            1025,
            8'h66
        );


        // ========================================================
        // 6. Packet-boundary state handling
        // ========================================================

        test_back_to_back_packets();


        // ========================================================
        // 7. Reset behavior
        // ========================================================

        test_reset_mid_partial_word();

        test_reset_while_output_stalled();


        // ========================================================
        // 8. Output AXIS stability under stall
        // ========================================================

        test_output_hold_under_stall();


        // ========================================================
        // 9. Most important packer/backpressure corner case
        // ========================================================

        test_fourth_byte_while_downstream_stalled();


        // ========================================================
        // 10. Random source TVALID pauses
        // ========================================================

        test_random_source_gaps();


        // ========================================================
        // 11. Random downstream TREADY
        // ========================================================

        test_random_backpressure();


        // ========================================================
        // 12. Randomize both sides simultaneously
        // ========================================================

        test_random_both_sides();


        // ========================================================
        // 13. Heavy backpressure stress
        // ========================================================

        test_heavy_random_stress();


        // ========================================================
        // 14. Near-maximum/max UDP payload
        // ========================================================

        test_large_payloads();


        // ========================================================
        // Testbench coverage sanity
        // ========================================================

        check_test_coverage();


        // ========================================================
        // Final report
        // ========================================================

        $display("");
        $display(
            "============================================================"
        );

        $display(
            "FINAL TESTBENCH RESULT"
        );

        $display(
            "============================================================"
        );


        $display(
            "Output beats checked: %0d",
            output_beats_checked
        );

        $display(
            "Total errors        : %0d",
            error_count
        );


        if (error_count == 0) begin

            $display("");
            $display(
                "************************************************************"
            );

            $display(
                "PASS: axis_8_to_32 passed all tests."
            );

            $display(
                "************************************************************"
            );

        end
        else begin

            $display("");
            $display(
                "************************************************************"
            );

            $display(
                "FAIL: axis_8_to_32 failed with %0d error(s).",
                error_count
            );

            $display(
                "************************************************************"
            );

        end


        $finish;

    end

endmodule