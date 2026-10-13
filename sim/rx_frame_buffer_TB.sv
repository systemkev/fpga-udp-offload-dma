`timescale 1ns/1ps
`default_nettype none

module rx_frame_buffer_TB;

    // ------------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------------
    // rx_frame_buffer receives the complete Ethernet frame bytes emitted by
    // the RX MAC, excluding preamble/SFD and FCS. For normal untagged Ethernet:
    //   14-byte header + 46..1500-byte payload = 60..1514 bytes before FCS.
    localparam int MIN_FRAME_BYTES       = 60;
    localparam int MAX_FRAME_BYTES       = 1514;
    localparam int OVERSIZE_FRAME_BYTES  = 1515;
    localparam int MAX_CAPTURE_BYTES     = 4096;
    localparam int MAX_ACTUAL_BYTES      = 4096;
    localparam int EXP_DEPTH             = 256;
    localparam int RANDOM_STRESS_FRAMES  = 200;

    localparam int PAT_RANDOM      = 0;
    localparam int PAT_ZERO        = 1;
    localparam int PAT_FF          = 2;
    localparam int PAT_ALT         = 3;
    localparam int PAT_INCREMENT   = 4;
    localparam int PAT_A5          = 5;
    localparam int PAT_SPECIAL     = 6;

    localparam int GAP_NONE        = 0;
    localparam int GAP_RANDOM      = 1;
    localparam int GAP_PERIODIC    = 2;

    localparam int RDY_ALWAYS      = 0;
    localparam int RDY_NEVER       = 1;
    localparam int RDY_PERIODIC    = 2;
    localparam int RDY_RANDOM      = 3;
    localparam int RDY_STALL_AFTER = 4;
    localparam int RDY_STALL_TLAST = 5;

    // ------------------------------------------------------------------------
    // DUT interface
    // ------------------------------------------------------------------------
    logic       i_rx_clk;
    logic       i_rx_n_reset;
    logic [7:0] i_rx_data;
    logic       i_rx_valid;
    logic       i_rx_last;
    logic       i_frame_good;
    logic       i_frame_bad;

    logic       i_clk;
    logic       i_n_reset;

    logic [7:0] m_axis_tdata;
    logic       m_axis_tvalid;
    logic       m_axis_tready;
    logic       m_axis_tlast;

    logic       o_buf_ovf;

    rx_frame_buffer dut (
        .i_rx_clk      (i_rx_clk),
        .i_rx_n_reset  (i_rx_n_reset),
        .i_rx_data     (i_rx_data),
        .i_rx_valid    (i_rx_valid),
        .i_rx_last     (i_rx_last),
        .i_frame_good  (i_frame_good),
        .i_frame_bad   (i_frame_bad),
        .i_clk         (i_clk),
        .i_n_reset     (i_n_reset),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast),
        .o_buf_ovf     (o_buf_ovf)
    );

    // ------------------------------------------------------------------------
    // Variable asynchronous clocks
    // ------------------------------------------------------------------------
    time rx_half_period  = 4ns;
    time sys_half_period = 5ns;

    initial begin
        i_rx_clk = 1'b0;
        #1.3ns; // deliberate initial phase offset
        forever begin
            #(rx_half_period);
            i_rx_clk = ~i_rx_clk;
        end
    end

    initial begin
        i_clk = 1'b0;
        #3.7ns; // deliberate initial phase offset
        forever begin
            #(sys_half_period);
            i_clk = ~i_clk;
        end
    end

    task automatic set_clock_periods(input time rx_period, input time sys_period);
        rx_half_period  = rx_period  / 2;
        sys_half_period = sys_period / 2;
        $display("[TB] Clock periods changed: RX=%0t, AXI=%0t", rx_period, sys_period);
    endtask

    // ------------------------------------------------------------------------
    // Global statistics / test bookkeeping
    // ------------------------------------------------------------------------
    integer error_count                 = 0;
    integer directed_pass_count         = 0;
    integer directed_fail_count         = 0;
    integer expected_good_count         = 0;
    integer bad_frame_count             = 0;
    integer oversized_drop_count        = 0;
    integer overflow_drop_count         = 0;
    integer actual_frame_count          = 0;
    integer total_axis_beats            = 0;
    integer overflow_event_count        = 0;
    integer rx_input_frame_count        = 0;

    integer test_error_baseline         = 0;
    string  current_test                = "startup";

    task automatic tb_error(input string msg);
        error_count = error_count + 1;
        $error("[FAIL][%s] %s", current_test, msg);
    endtask

    task automatic test_begin(input string name);
        current_test        = name;
        test_error_baseline = error_count;
        $display("\n============================================================");
        $display("[TEST] %s", name);
        $display("============================================================");
    endtask

    task automatic test_finish(input int quiet_cycles = 30);
        integer q;
        for (q = 0; q < quiet_cycles; q = q + 1)
            @(posedge i_clk);

        if (error_count == test_error_baseline) begin
            directed_pass_count = directed_pass_count + 1;
            $display("[PASS] %s", current_test);
        end
        else begin
            directed_fail_count = directed_fail_count + 1;
            $display("[FAIL] %s (%0d new error(s))",
                     current_test, error_count - test_error_baseline);
        end
    endtask

    // ------------------------------------------------------------------------
    // Public-interface overflow observation
    // ------------------------------------------------------------------------
    always @(posedge o_buf_ovf) begin
        overflow_event_count = overflow_event_count + 1;
    end

    // ------------------------------------------------------------------------
    // Expected-frame ring buffer / black-box reference model
    //
    // Frames are enqueued ONLY from observed RX-side interface behavior:
    //   - frame classified good
    //   - legal Ethernet length <= MAX_FRAME_BYTES
    //   - no observed overflow event while that frame was active
    //
    // No DUT internals are referenced.
    // ------------------------------------------------------------------------
    logic [7:0] exp_data [0:EXP_DEPTH-1][0:MAX_FRAME_BYTES-1];
    integer     exp_len  [0:EXP_DEPTH-1];
    integer     exp_id   [0:EXP_DEPTH-1];
    integer     exp_wr_seq = 0;
    integer     exp_rd_seq = 0;

    logic [7:0] rx_capture [0:MAX_CAPTURE_BYTES-1];
    integer     rx_capture_len       = 0;
    integer     rx_frame_id          = 0;
    integer     rx_ovf_count_start   = 0;
    logic       rx_collecting        = 1'b0;
    logic       rx_last_seen         = 1'b0;
    logic       rx_capture_overflow  = 1'b0;

    integer rx_slot;
    integer rx_copy_i;

    task automatic enqueue_expected_current_frame;
        begin
            if ((exp_wr_seq - exp_rd_seq) >= EXP_DEPTH) begin
                tb_error("Testbench expected-frame ring overflowed; increase EXP_DEPTH");
            end
            else begin
                rx_slot = exp_wr_seq % EXP_DEPTH;
                exp_len[rx_slot] = rx_capture_len;
                exp_id [rx_slot] = rx_frame_id;

                for (rx_copy_i = 0; rx_copy_i < rx_capture_len; rx_copy_i = rx_copy_i + 1)
                    exp_data[rx_slot][rx_copy_i] = rx_capture[rx_copy_i];

                exp_wr_seq         = exp_wr_seq + 1;
                expected_good_count = expected_good_count + 1;
            end
        end
    endtask

    always @(posedge i_rx_clk or negedge i_rx_n_reset or negedge i_n_reset) begin
        if (!i_rx_n_reset || !i_n_reset) begin
            rx_capture_len      = 0;
            rx_collecting       = 1'b0;
            rx_last_seen        = 1'b0;
            rx_capture_overflow = 1'b0;
            exp_wr_seq          = 0;
        end
        else begin
            // Start a new frame on the first valid byte.
            if (i_rx_valid && !rx_collecting) begin
                rx_collecting       = 1'b1;
                rx_last_seen        = 1'b0;
                rx_capture_len      = 0;
                rx_capture_overflow = 1'b0;
                rx_ovf_count_start  = overflow_event_count;
                rx_input_frame_count = rx_input_frame_count + 1;
                rx_frame_id          = rx_input_frame_count;
            end

            // Capture only cycles with i_rx_valid asserted.
            if (i_rx_valid && rx_collecting) begin
                if (rx_capture_len < MAX_CAPTURE_BYTES) begin
                    rx_capture[rx_capture_len] = i_rx_data;
                end
                else if (!rx_capture_overflow) begin
                    tb_error("RX reference capture exceeded MAX_CAPTURE_BYTES");
                    rx_capture_overflow = 1'b1;
                end

                rx_capture_len = rx_capture_len + 1;

                if (i_rx_last)
                    rx_last_seen = 1'b1;
            end

            // Status is allowed on the last-byte cycle or shortly afterward.
            if (rx_collecting && (i_frame_good || i_frame_bad)) begin
                if (i_frame_good && i_frame_bad)
                    tb_error("Input protocol violation: i_frame_good and i_frame_bad asserted together");

                if (!rx_last_seen)
                    tb_error("Input protocol violation: frame status observed before i_rx_last");

                if (i_frame_bad) begin
                    bad_frame_count = bad_frame_count + 1;
                end
                else if (rx_capture_len > MAX_FRAME_BYTES) begin
                    // Oversized frames are expected to be discarded safely.
                    oversized_drop_count = oversized_drop_count + 1;
                end
                else if (overflow_event_count != rx_ovf_count_start) begin
                    // Public overflow indication says this frame was rejected.
                    overflow_drop_count = overflow_drop_count + 1;
                end
                else if (i_frame_good) begin
                    enqueue_expected_current_frame();
                end

                rx_collecting       = 1'b0;
                rx_last_seen        = 1'b0;
                rx_capture_len      = 0;
                rx_capture_overflow = 1'b0;
            end
        end
    end

    // A pulse/event indication must not become permanently stuck high.
    integer ovf_high_cycles = 0;
    always @(posedge i_rx_clk or negedge i_rx_n_reset) begin
        if (!i_rx_n_reset) begin
            ovf_high_cycles = 0;
        end
        else if (o_buf_ovf) begin
            ovf_high_cycles = ovf_high_cycles + 1;
            if (ovf_high_cycles == 20)
                tb_error("o_buf_ovf appears stuck high instead of behaving as an event/pulse");
        end
        else begin
            ovf_high_cycles = 0;
        end
    end

    // ------------------------------------------------------------------------
    // AXI output scoreboard and protocol checking
    // ------------------------------------------------------------------------
    logic [7:0] actual_capture [0:MAX_ACTUAL_BYTES-1];
    integer     actual_len = 0;
    integer     axi_slot;
    integer     cmp_i;
    integer     cmp_limit;

    logic       prev_stalled = 1'b0;
    logic [7:0] prev_tdata   = 8'h00;
    logic       prev_tlast   = 1'b0;

    always @(posedge i_clk or negedge i_n_reset or negedge i_rx_n_reset) begin
        if (!i_n_reset || !i_rx_n_reset) begin
            exp_rd_seq   = 0;
            actual_len   = 0;
            prev_stalled = 1'b0;
            prev_tdata   = 8'h00;
            prev_tlast   = 1'b0;
        end
        else begin
            // AXI stability check: once stalled, TVALID/TDATA/TLAST must hold.
            if (prev_stalled) begin
                if (!m_axis_tvalid)
                    tb_error("AXI TVALID dropped while previous beat was stalled");
                if (m_axis_tdata !== prev_tdata)
                    tb_error("AXI TDATA changed while stalled");
                if (m_axis_tlast !== prev_tlast)
                    tb_error("AXI TLAST changed while stalled");
            end

            prev_stalled = m_axis_tvalid && !m_axis_tready;
            prev_tdata   = m_axis_tdata;
            prev_tlast   = m_axis_tlast;

            // Only an accepted TVALID/TREADY transfer counts.
            if (m_axis_tvalid && m_axis_tready) begin
                total_axis_beats = total_axis_beats + 1;

                // Any accepted byte when no good frame is expected is already
                // a failure, even if the DUT never eventually asserts TLAST.
                if ((exp_rd_seq >= exp_wr_seq) && (actual_len == 0))
                    tb_error("Unexpected AXI byte accepted with no expected good frame queued");

                if (actual_len < MAX_ACTUAL_BYTES) begin
                    actual_capture[actual_len] = m_axis_tdata;
                    actual_len = actual_len + 1;
                end
                else begin
                    tb_error("Observed AXI frame exceeded MAX_ACTUAL_BYTES without TLAST");
                    actual_len = 0;
                end

                // Detect a missing TLAST as soon as the output runs beyond
                // the expected frame length.
                if ((exp_rd_seq < exp_wr_seq) && (actual_len > 0)) begin
                    axi_slot = exp_rd_seq % EXP_DEPTH;
                    if (actual_len == (exp_len[axi_slot] + 1))
                        tb_error("AXI output exceeded expected frame length before TLAST");
                end

                if (m_axis_tlast) begin
                    actual_frame_count = actual_frame_count + 1;

                    if (exp_rd_seq >= exp_wr_seq) begin
                        tb_error("Unexpected AXI frame: no expected good frame is queued");
                    end
                    else begin
                        axi_slot = exp_rd_seq % EXP_DEPTH;

                        if (actual_len != exp_len[axi_slot]) begin
                            tb_error($sformatf(
                                "Frame ID %0d length mismatch: expected %0d bytes, observed %0d bytes",
                                exp_id[axi_slot], exp_len[axi_slot], actual_len));
                        end

                        cmp_limit = (actual_len < exp_len[axi_slot]) ? actual_len : exp_len[axi_slot];
                        for (cmp_i = 0; cmp_i < cmp_limit; cmp_i = cmp_i + 1) begin
                            if (actual_capture[cmp_i] !== exp_data[axi_slot][cmp_i]) begin
                                tb_error($sformatf(
                                    "Frame ID %0d byte[%0d] mismatch: expected 0x%02h, got 0x%02h",
                                    exp_id[axi_slot], cmp_i,
                                    exp_data[axi_slot][cmp_i], actual_capture[cmp_i]));
                            end
                        end

                        exp_rd_seq = exp_rd_seq + 1;
                    end

                    actual_len = 0;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // AXI TREADY generator
    // ------------------------------------------------------------------------
    integer ready_mode          = RDY_ALWAYS;
    integer ready_percent       = 70;
    integer periodic_high       = 5;
    integer periodic_low        = 3;
    integer periodic_count      = 0;
    integer stall_target_beats  = 0;
    integer stall_cycles_cfg    = 6;
    integer stall_cycles_left   = 0;
    integer stall_base_beats    = 0;
    logic   stall_done          = 1'b0;

    always @(negedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            m_axis_tready   = 1'b0;
            periodic_count  = 0;
            stall_cycles_left = 0;
            stall_done      = 1'b0;
        end
        else begin
            case (ready_mode)
                RDY_ALWAYS: begin
                    m_axis_tready = 1'b1;
                end

                RDY_NEVER: begin
                    m_axis_tready = 1'b0;
                end

                RDY_PERIODIC: begin
                    if (periodic_count < periodic_high)
                        m_axis_tready = 1'b1;
                    else
                        m_axis_tready = 1'b0;

                    periodic_count = periodic_count + 1;
                    if (periodic_count >= (periodic_high + periodic_low))
                        periodic_count = 0;
                end

                RDY_RANDOM: begin
                    m_axis_tready = ($urandom_range(0, 99) < ready_percent);
                end

                RDY_STALL_AFTER: begin
                    if (stall_cycles_left > 0) begin
                        m_axis_tready   = 1'b0;
                        stall_cycles_left = stall_cycles_left - 1;
                    end
                    else if (!stall_done && m_axis_tvalid &&
                             ((total_axis_beats - stall_base_beats) >= stall_target_beats)) begin
                        m_axis_tready   = 1'b0;
                        stall_cycles_left = (stall_cycles_cfg > 0) ? stall_cycles_cfg - 1 : 0;
                        stall_done      = 1'b1;
                    end
                    else begin
                        m_axis_tready = 1'b1;
                    end
                end

                RDY_STALL_TLAST: begin
                    if (stall_cycles_left > 0) begin
                        m_axis_tready   = 1'b0;
                        stall_cycles_left = stall_cycles_left - 1;
                    end
                    else if (!stall_done && m_axis_tvalid && m_axis_tlast) begin
                        m_axis_tready   = 1'b0;
                        stall_cycles_left = (stall_cycles_cfg > 0) ? stall_cycles_cfg - 1 : 0;
                        stall_done      = 1'b1;
                    end
                    else begin
                        m_axis_tready = 1'b1;
                    end
                end

                default: m_axis_tready = 1'b1;
            endcase
        end
    end

    task automatic configure_ready(
        input integer mode,
        input integer arg0 = 0,
        input integer arg1 = 0
    );
        begin
            ready_mode        = mode;
            periodic_count    = 0;
            stall_cycles_left = 0;
            stall_done        = 1'b0;
            stall_base_beats  = total_axis_beats;

            case (mode)
                RDY_PERIODIC: begin
                    periodic_high = (arg0 > 0) ? arg0 : 5;
                    periodic_low  = (arg1 > 0) ? arg1 : 3;
                end
                RDY_RANDOM: begin
                    ready_percent = (arg0 > 0) ? arg0 : 70;
                end
                RDY_STALL_AFTER: begin
                    stall_target_beats = arg0;
                    stall_cycles_cfg   = (arg1 > 0) ? arg1 : 6;
                end
                RDY_STALL_TLAST: begin
                    stall_cycles_cfg   = (arg0 > 0) ? arg0 : 6;
                end
                default: begin end
            endcase

            // Allow the negedge-driven ready generator to apply the new mode.
            repeat (2) @(negedge i_clk);
        end
    endtask

    // ------------------------------------------------------------------------
    // Input frame generation
    // ------------------------------------------------------------------------
    function automatic [7:0] make_byte(input integer pattern, input integer idx);
        begin
            case (pattern)
                PAT_ZERO:      make_byte = 8'h00;
                PAT_FF:        make_byte = 8'hFF;
                PAT_ALT:       make_byte = idx[0] ? 8'hAA : 8'h55;
                PAT_INCREMENT: make_byte = idx[7:0];
                PAT_A5:        make_byte = 8'hA5;
                PAT_SPECIAL: begin
                    case (idx % 8)
                        0: make_byte = 8'h00;
                        1: make_byte = 8'hFF;
                        2: make_byte = 8'h55;
                        3: make_byte = 8'hAA;
                        4: make_byte = 8'h01;
                        5: make_byte = 8'h80;
                        6: make_byte = 8'h7F;
                        default: make_byte = $urandom_range(0, 255);
                    endcase
                end
                default: make_byte = $urandom_range(0, 255);
            endcase
        end
    endfunction

    task automatic drive_idle_rx;
        begin
            i_rx_data    = 8'h00;
            i_rx_valid   = 1'b0;
            i_rx_last    = 1'b0;
            i_frame_good = 1'b0;
            i_frame_bad  = 1'b0;
        end
    endtask

    task automatic send_frame(
        input integer length,
        input integer pattern,
        input bit     good,
        input integer status_delay_cycles,
        input integer gap_mode
    );
        integer idx;
        integer g;
        integer gap_cycles;
        begin
            if (length <= 0) begin
                tb_error("send_frame called with non-positive length");
                return;
            end

            // One sender at a time. All bus changes occur on RX falling edges.
            for (idx = 0; idx < length; idx = idx + 1) begin
                gap_cycles = 0;
                if (gap_mode == GAP_RANDOM && idx != 0)
                    gap_cycles = $urandom_range(0, 2);
                else if (gap_mode == GAP_PERIODIC && idx != 0 && (idx % 11) == 0)
                    gap_cycles = 2;

                for (g = 0; g < gap_cycles; g = g + 1) begin
                    @(negedge i_rx_clk);
                    i_rx_valid   = 1'b0;
                    i_rx_last    = 1'b0;
                    i_frame_good = 1'b0;
                    i_frame_bad  = 1'b0;
                end

                @(negedge i_rx_clk);
                i_rx_data  = make_byte(pattern, idx);
                i_rx_valid = 1'b1;
                i_rx_last  = (idx == (length - 1));

                if ((idx == (length - 1)) && (status_delay_cycles == 0)) begin
                    i_frame_good = good;
                    i_frame_bad  = !good;
                end
                else begin
                    i_frame_good = 1'b0;
                    i_frame_bad  = 1'b0;
                end
            end

            if (status_delay_cycles > 0) begin
                for (g = 1; g <= status_delay_cycles; g = g + 1) begin
                    @(negedge i_rx_clk);
                    i_rx_valid = 1'b0;
                    i_rx_last  = 1'b0;
                    if (g == status_delay_cycles) begin
                        i_frame_good = good;
                        i_frame_bad  = !good;
                    end
                    else begin
                        i_frame_good = 1'b0;
                        i_frame_bad  = 1'b0;
                    end
                end
            end

            @(negedge i_rx_clk);
            drive_idle_rx();
        end
    endtask

    // ------------------------------------------------------------------------
    // Reset / settling / drain helpers
    // ------------------------------------------------------------------------
    task automatic reset_dut;
        begin
            drive_idle_rx();
            i_rx_n_reset = 1'b0;
            i_n_reset    = 1'b0;
            ready_mode   = RDY_ALWAYS;

            fork
                begin repeat (6) @(posedge i_rx_clk); end
                begin repeat (6) @(posedge i_clk);    end
            join

            if (m_axis_tvalid !== 1'b0)
                tb_error("m_axis_tvalid was not low during reset");

            if (o_buf_ovf === 1'b1)
                tb_error("o_buf_ovf remained asserted during reset");

            #0.2ns;
            i_rx_n_reset = 1'b1;
            i_n_reset    = 1'b1;

            fork
                begin repeat (6) @(posedge i_rx_clk); end
                begin repeat (6) @(posedge i_clk);    end
            join
        end
    endtask

    task automatic settle_cdc(input integer cycles = 12);
        begin
            fork
                begin repeat (cycles) @(posedge i_rx_clk); end
                begin repeat (cycles) @(posedge i_clk);    end
            join
        end
    endtask

    task automatic wait_for_drain(input integer timeout_cycles = 200000);
        integer c;
        integer quiet;
        begin
            quiet = 0;
            for (c = 0; c < timeout_cycles; c = c + 1) begin
                @(posedge i_clk);

                if ((exp_rd_seq == exp_wr_seq) &&
                    (actual_len == 0) &&
                    !m_axis_tvalid) begin
                    quiet = quiet + 1;
                    if (quiet >= 8)
                        return;
                end
                else begin
                    quiet = 0;
                end
            end

            tb_error($sformatf(
                "Timeout waiting for drain: expected queued=%0d, actual_partial_len=%0d, tvalid=%0b",
                exp_wr_seq - exp_rd_seq, actual_len, m_axis_tvalid));
        end
    endtask

    task automatic wait_for_tvalid(input integer timeout_cycles = 50000);
        integer c;
        begin
            for (c = 0; c < timeout_cycles; c = c + 1) begin
                @(posedge i_clk);
                if (m_axis_tvalid)
                    return;
            end
            tb_error("Timeout waiting for m_axis_tvalid to assert");
        end
    endtask

    task automatic wait_for_axis_beats(
        input integer target_beats,
        input integer timeout_cycles = 50000
    );
        integer c;
        begin
            for (c = 0; c < timeout_cycles; c = c + 1) begin
                @(posedge i_clk);
                if (total_axis_beats >= target_beats)
                    return;
            end
            tb_error($sformatf(
                "Timeout waiting for AXI beat count %0d; observed %0d",
                target_beats, total_axis_beats));
        end
    endtask

    task automatic ensure_no_overflow_since(input integer before_count, input string what);
        begin
            if (overflow_event_count != before_count)
                tb_error($sformatf("Unexpected buffer overflow during %s", what));
        end
    endtask

    task automatic ensure_overflow_since(input integer before_count, input string what);
        begin
            if (overflow_event_count == before_count)
                tb_error($sformatf("Expected buffer overflow was not observed during %s", what));
        end
    endtask

    // ------------------------------------------------------------------------
    // Directed tests
    // ------------------------------------------------------------------------
    task automatic test_01_reset_idle;
        begin
            test_begin("01. Reset / idle behavior");
            reset_dut();
            configure_ready(RDY_ALWAYS);
            repeat (40) @(posedge i_clk);
            if (m_axis_tvalid)
                tb_error("AXI TVALID asserted while idle after reset");
            if (actual_frame_count != 0)
                tb_error("A stale frame emerged after reset");
            test_finish(10);
        end
    endtask

    task automatic test_02_single_good;
        begin
            test_begin("02. Single good frame");
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(73, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_03_two_good;
        begin
            test_begin("03. Two consecutive good frames");
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(61, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            send_frame(97, PAT_ALT,       1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_04_many_good;
        integer n;
        begin
            test_begin("04. Many consecutive good frames");
            set_clock_periods(10ns, 4ns);
            reset_dut();
            configure_ready(RDY_ALWAYS);
            for (n = 0; n < 20; n = n + 1) begin
                send_frame(60 + n*3, (n % 2) ? PAT_SPECIAL : PAT_INCREMENT,
                           1'b1, 0, GAP_NONE);
            end
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_05_single_bad;
        begin
            test_begin("05. Single bad frame");
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(128, PAT_A5, 1'b0, 0, GAP_NONE);
            repeat (80) @(posedge i_clk);
            test_finish(20);
        end
    endtask

    task automatic test_06_good_bad_good;
        begin
            test_begin("06. Good -> bad -> good");
            set_clock_periods(10ns, 6ns);
            reset_dut();
            configure_ready(RDY_NEVER);
            begin : G_B_G_OVF_CHECK
                integer ovf_before;
                ovf_before = overflow_event_count;
                // A remains unread in one bank. B is bad and must release the
                // other bank, allowing C to be accepted despite backpressure.
                send_frame(80,  PAT_INCREMENT, 1'b1, 0, GAP_NONE);
                send_frame(90,  PAT_FF,        1'b0, 0, GAP_NONE);
                send_frame(100, PAT_ALT,       1'b1, 0, GAP_NONE);
                ensure_no_overflow_since(ovf_before, "good/bad/good bank release sequence");
            end
            configure_ready(RDY_ALWAYS);
            wait_for_drain();
            test_finish(40);
        end
    endtask

    task automatic test_07_many_bad;
        integer n;
        begin
            test_begin("07. Multiple consecutive bad frames");
            reset_dut();
            configure_ready(RDY_NEVER);
            begin : BAD_OVF_CHECK
                integer ovf_before;
                ovf_before = overflow_event_count;
                for (n = 0; n < 8; n = n + 1)
                    send_frame(60 + n, PAT_SPECIAL, 1'b0, 0, GAP_NONE);
                // Rejected bad frames must continuously release their bank.
                ensure_no_overflow_since(ovf_before, "consecutive bad frames");
            end
            repeat (100) @(posedge i_clk);
            configure_ready(RDY_ALWAYS);
            test_finish(20);
        end
    endtask

    task automatic test_08_always_ready;
        begin
            test_begin("08. AXI always ready");
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(512, PAT_RANDOM, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_09_periodic_stall;
        begin
            test_begin("09. AXI periodically stalled");
            reset_dut();
            configure_ready(RDY_PERIODIC, 4, 3);
            send_frame(300, PAT_SPECIAL, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_10_random_stall;
        begin
            test_begin("10. AXI randomly stalled");
            reset_dut();
            configure_ready(RDY_RANDOM, 55, 0);
            send_frame(500, PAT_RANDOM, 1'b1, 0, GAP_RANDOM);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_11_stall_first;
        begin
            test_begin("11. Stall on first output byte");
            reset_dut();
            configure_ready(RDY_NEVER);
            send_frame(96, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            wait_for_tvalid();
            repeat (12) @(posedge i_clk);
            configure_ready(RDY_ALWAYS);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_12_stall_middle;
        begin
            test_begin("12. Stall in middle of frame");
            reset_dut();
            configure_ready(RDY_STALL_AFTER, 25, 12);
            send_frame(128, PAT_SPECIAL, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_13_stall_tlast;
        begin
            test_begin("13. Stall on final/TLAST byte");
            reset_dut();
            configure_ready(RDY_STALL_TLAST, 12, 0);
            send_frame(77, PAT_ALT, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_14_long_stall;
        begin
            test_begin("14. Very long AXI stall while frame is buffered");
            reset_dut();
            configure_ready(RDY_NEVER);
            send_frame(700, PAT_RANDOM, 1'b1, 0, GAP_NONE);
            wait_for_tvalid();
            repeat (250) @(posedge i_clk);
            configure_ready(RDY_ALWAYS);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_15_rx_faster;
        begin
            test_begin("15. RX faster than AXI");
            set_clock_periods(8ns, 14ns);
            reset_dut();
            configure_ready(RDY_RANDOM, 75, 0);
            send_frame(600, PAT_SPECIAL, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_16_axi_faster;
        begin
            test_begin("16. AXI faster than RX");
            set_clock_periods(14ns, 6ns);
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(600, PAT_RANDOM, 1'b1, 0, GAP_RANDOM);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_17_noninteger_ratio;
        begin
            test_begin("17. Asynchronous non-integer clock ratio");
            set_clock_periods(7.4ns, 11.3ns);
            reset_dut();
            configure_ready(RDY_RANDOM, 65, 0);
            send_frame(777, PAT_SPECIAL, 1'b1, 1, GAP_RANDOM);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_18_equal_freq_phase;
        begin
            test_begin("18. Equal frequencies with different phase");
            set_clock_periods(10ns, 10ns);
            reset_dut();
            configure_ready(RDY_PERIODIC, 7, 2);
            send_frame(333, PAT_INCREMENT, 1'b1, 0, GAP_PERIODIC);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_19_overlap_rx_tx;
        begin
            test_begin("19. Receive next frame while previous frame is transmitting");
            set_clock_periods(8ns, 10ns);
            reset_dut();
            configure_ready(RDY_PERIODIC, 3, 2);

            send_frame(1000, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            wait_for_tvalid();
            if (m_axis_tvalid)
                send_frame(300, PAT_ALT, 1'b1, 0, GAP_NONE);

            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_20_two_buffers_occupied;
        integer ovf_before;
        begin
            test_begin("20. Two buffers occupied simultaneously");
            reset_dut();
            configure_ready(RDY_NEVER);
            ovf_before = overflow_event_count;

            send_frame(300, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            send_frame(350, PAT_ALT,       1'b1, 0, GAP_NONE);
            repeat (20) @(posedge i_rx_clk);

            ensure_no_overflow_since(ovf_before, "filling the two legal ping-pong banks");

            configure_ready(RDY_ALWAYS);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_21_third_frame_overflow;
        integer ovf_before;
        begin
            test_begin("21. Third frame arrives while both buffers occupied");
            reset_dut();
            configure_ready(RDY_NEVER);

            send_frame(280, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            send_frame(290, PAT_ALT,       1'b1, 0, GAP_NONE);
            ovf_before = overflow_event_count;
            send_frame(400, PAT_A5,        1'b1, 0, GAP_NONE);
            repeat (10) @(posedge i_rx_clk);

            ensure_overflow_since(ovf_before, "third-frame arrival");

            configure_ready(RDY_ALWAYS);
            wait_for_drain();
            test_finish(50);
        end
    endtask

    task automatic test_22_drop_third_completely;
        integer ovf_before;
        begin
            test_begin("22. Overflowed third frame is dropped completely");
            reset_dut();
            configure_ready(RDY_NEVER);

            send_frame(120, PAT_ZERO,      1'b1, 0, GAP_NONE);
            send_frame(130, PAT_FF,        1'b1, 0, GAP_NONE);
            ovf_before = overflow_event_count;
            send_frame(600, PAT_A5,        1'b1, 0, GAP_NONE);
            ensure_overflow_since(ovf_before, "overflow-drop test");

            configure_ready(RDY_ALWAYS);
            wait_for_drain();
            repeat (100) @(posedge i_clk); // catches any late/partial C output
            test_finish(10);
        end
    endtask

    task automatic test_23_free_mid_dropped_frame;
        integer ovf_before;
        begin
            test_begin("23. Buffer frees midway through dropped frame; remainder stays dropped");
            reset_dut();
            configure_ready(RDY_NEVER);

            send_frame(256, PAT_ZERO, 1'b1, 0, GAP_NONE);
            send_frame(256, PAT_FF,   1'b1, 0, GAP_NONE);
            ovf_before = overflow_event_count;

            fork
                begin
                    send_frame(1200, PAT_A5, 1'b1, 0, GAP_NONE);
                end
                begin
                    repeat (120) @(posedge i_rx_clk);
                    configure_ready(RDY_ALWAYS); // frees a bank while C is still arriving
                end
            join

            ensure_overflow_since(ovf_before, "long third frame");
            wait_for_drain();
            repeat (80) @(posedge i_clk);
            test_finish(10);
        end
    endtask

    task automatic test_24_recovery_after_overflow;
        integer ovf_before;
        begin
            test_begin("24. Recovery after overflow");
            reset_dut();
            configure_ready(RDY_NEVER);

            send_frame(200, PAT_ZERO, 1'b1, 0, GAP_NONE);
            send_frame(220, PAT_FF,   1'b1, 0, GAP_NONE);
            ovf_before = overflow_event_count;
            send_frame(240, PAT_A5,   1'b1, 0, GAP_NONE);
            ensure_overflow_since(ovf_before, "overflow recovery setup");

            configure_ready(RDY_ALWAYS);
            wait_for_drain();
            settle_cdc(16);

            send_frame(260, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_25_min_length;
        begin
            test_begin("25. Minimum legal Ethernet frame length (60 bytes before FCS)");
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(MIN_FRAME_BYTES, PAT_SPECIAL, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_26_typical_lengths;
        begin
            test_begin("26. Typical Ethernet frame lengths");
            set_clock_periods(10ns, 4ns);
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(60,   PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            send_frame(64,   PAT_ALT,       1'b1, 0, GAP_NONE);
            send_frame(512,  PAT_SPECIAL,   1'b1, 0, GAP_NONE);
            send_frame(1514, PAT_RANDOM,    1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_27_max_length;
        begin
            test_begin("27. Near-maximum and maximum legal Ethernet frame lengths (1500/1514 bytes)");
            set_clock_periods(10ns, 4ns);
            reset_dut();
            configure_ready(RDY_RANDOM, 85, 0);
            send_frame(1500,            PAT_INCREMENT, 1'b1, 0, GAP_PERIODIC);
            send_frame(MAX_FRAME_BYTES, PAT_SPECIAL,   1'b1, 0, GAP_PERIODIC);
            wait_for_drain(400000);
            test_finish();
        end
    endtask

    task automatic test_28_oversized;
        begin
            test_begin("28. Oversized Ethernet frame (1515 bytes before FCS) is rejected safely");
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(OVERSIZE_FRAME_BYTES, PAT_SPECIAL, 1'b0, 0, GAP_NONE);
            repeat (150) @(posedge i_clk);

            // A legal frame after the oversize proves recovery / no corruption.
            settle_cdc(12);
            send_frame(128, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish(50);
        end
    endtask

    task automatic test_29_data_patterns;
        begin
            test_begin("29. Data patterns: 00, FF, alternating, random, special");
            set_clock_periods(10ns, 4ns);
            reset_dut();
            configure_ready(RDY_PERIODIC, 5, 2);
            send_frame(100, PAT_ZERO,      1'b1, 0, GAP_NONE);
            send_frame(101, PAT_FF,        1'b1, 0, GAP_NONE);
            send_frame(102, PAT_ALT,       1'b1, 0, GAP_NONE);
            send_frame(103, PAT_SPECIAL,   1'b1, 0, GAP_RANDOM);
            send_frame(104, PAT_RANDOM,    1'b1, 0, GAP_RANDOM);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_30_identical_frames;
        integer n;
        begin
            test_begin("30. Multiple identical frames detect duplicate/drop bookkeeping errors");
            set_clock_periods(10ns, 4ns);
            reset_dut();
            configure_ready(RDY_RANDOM, 75, 0);
            for (n = 0; n < 6; n = n + 1)
                send_frame(128, PAT_A5, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_31_reset_idle;
        begin
            test_begin("31. Reset while idle");
            reset_dut();
            repeat (20) @(posedge i_clk);
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(64, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish();
        end
    endtask

    task automatic test_32_reset_receiving;
        begin
            test_begin("32. Reset while receiving");
            reset_dut();
            configure_ready(RDY_ALWAYS);

            fork : RESET_RX_FORK
                begin
                    send_frame(1000, PAT_RANDOM, 1'b1, 0, GAP_NONE);
                end
                begin
                    repeat (80) @(posedge i_rx_clk);
                    // Assert reset immediately so the active sender is aborted
                    // at a precise mid-frame point.
                    i_rx_n_reset = 1'b0;
                    i_n_reset    = 1'b0;
                    drive_idle_rx();
                end
            join_any
            disable RESET_RX_FORK;
            drive_idle_rx();
            reset_dut();

            settle_cdc(10);
            send_frame(96, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish(50);
        end
    endtask

    task automatic test_33_reset_transmitting;
        integer start_beats;
        begin
            test_begin("33. Reset while AXI is transmitting");
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(1200, PAT_SPECIAL, 1'b1, 0, GAP_NONE);

            wait_for_tvalid();
            start_beats = total_axis_beats;
            if (m_axis_tvalid)
                wait_for_axis_beats(start_beats + 20);
            reset_dut();

            send_frame(100, PAT_ALT, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish(50);
        end
    endtask

    task automatic test_34_reset_stalled;
        begin
            test_begin("34. Reset while AXI is stalled");
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(500, PAT_SPECIAL, 1'b1, 0, GAP_NONE);
            wait_for_tvalid();
            configure_ready(RDY_NEVER);
            repeat (12) @(posedge i_clk);
            reset_dut();

            configure_ready(RDY_ALWAYS);
            send_frame(90, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            wait_for_drain();
            test_finish(50);
        end
    endtask

    task automatic test_35_status_same_cycle;
        begin
            test_begin("35. Good/bad status coincident with i_rx_last");
            set_clock_periods(10ns, 4ns);
            reset_dut();
            configure_ready(RDY_ALWAYS);
            send_frame(123, PAT_INCREMENT, 1'b1, 0, GAP_NONE);
            send_frame(124, PAT_FF,        1'b0, 0, GAP_NONE);
            send_frame(125, PAT_ALT,       1'b1, 0, GAP_NONE);
            wait_for_drain();
            repeat (60) @(posedge i_clk);
            test_finish(10);
        end
    endtask

    task automatic test_36_status_delayed;
        begin
            test_begin("36. Good/bad status delayed after i_rx_last");
            set_clock_periods(10ns, 4ns);
            reset_dut();
            configure_ready(RDY_RANDOM, 70, 0);
            send_frame(150, PAT_SPECIAL,   1'b1, 1, GAP_RANDOM);
            send_frame(151, PAT_A5,        1'b0, 2, GAP_NONE);
            send_frame(152, PAT_INCREMENT, 1'b1, 3, GAP_RANDOM);
            wait_for_drain();
            repeat (60) @(posedge i_clk);
            test_finish(10);
        end
    endtask

    // ------------------------------------------------------------------------
    // Randomized asynchronous-clock regression
    // ------------------------------------------------------------------------
    task automatic randomized_stress;
        integer n;
        integer len;
        integer pat;
        integer good;
        integer stat_delay;
        integer gaps;
        integer choice;
        begin
            test_begin($sformatf("Randomized stress regression (%0d frames)", RANDOM_STRESS_FRAMES));
            set_clock_periods(7.4ns, 11.3ns);
            reset_dut();
            configure_ready(RDY_RANDOM, 62, 0);

            for (n = 0; n < RANDOM_STRESS_FRAMES; n = n + 1) begin
                // Periodically change unrelated clock ratios. Because the clocks
                // are never restarted, their relative phase also continuously drifts.
                if ((n % 25) == 0) begin
                    choice = $urandom_range(0, 4);
                    case (choice)
                        0: set_clock_periods(8ns,   13ns);
                        1: set_clock_periods(13ns,  7ns);
                        2: set_clock_periods(7.4ns, 11.3ns);
                        3: set_clock_periods(9.2ns, 6.6ns);
                        default: set_clock_periods(10ns, 10ns);
                    endcase
                end

                // Keep randomized traffic within legal normal Ethernet frame
                // lengths. Oversize rejection is tested explicitly in Test 28.
                case (n % 31)
                    0:  len = MIN_FRAME_BYTES;
                    1:  len = 64;
                    2:  len = 128;
                    3:  len = 512;
                    4:  len = 1500;
                    5:  len = MAX_FRAME_BYTES;
                    default: len = $urandom_range(MIN_FRAME_BYTES, MAX_FRAME_BYTES);
                endcase

                pat        = $urandom_range(PAT_RANDOM, PAT_SPECIAL);
                good       = ($urandom_range(0, 99) < 80);
                stat_delay = $urandom_range(0, 3);
                gaps       = ($urandom_range(0, 99) < 35) ? GAP_RANDOM : GAP_NONE;

                send_frame(len, pat, (good != 0), stat_delay, gaps);

                // Random inter-frame gap.
                repeat ($urandom_range(0, 3)) @(posedge i_rx_clk);
            end

            configure_ready(RDY_ALWAYS);
            wait_for_drain(600000);
            settle_cdc(20);
            repeat (100) @(posedge i_clk);
            test_finish(10);
        end
    endtask

    // ------------------------------------------------------------------------
    // Main regression
    // ------------------------------------------------------------------------
    initial begin
        // Deterministic initialization.
        i_rx_n_reset = 1'b0;
        i_n_reset    = 1'b0;
        drive_idle_rx();
        m_axis_tready = 1'b0;

        // Default asynchronous clocks.
        set_clock_periods(8ns, 10ns);

        test_01_reset_idle();
        test_02_single_good();
        test_03_two_good();
        test_04_many_good();
        test_05_single_bad();
        test_06_good_bad_good();
        test_07_many_bad();
        test_08_always_ready();
        test_09_periodic_stall();
        test_10_random_stall();
        test_11_stall_first();
        test_12_stall_middle();
        test_13_stall_tlast();
        test_14_long_stall();
        test_15_rx_faster();
        test_16_axi_faster();
        test_17_noninteger_ratio();
        test_18_equal_freq_phase();
        test_19_overlap_rx_tx();
        test_20_two_buffers_occupied();
        test_21_third_frame_overflow();
        test_22_drop_third_completely();
        test_23_free_mid_dropped_frame();
        test_24_recovery_after_overflow();
        test_25_min_length();
        test_26_typical_lengths();
        test_27_max_length();
        test_28_oversized();
        test_29_data_patterns();
        test_30_identical_frames();
        test_31_reset_idle();
        test_32_reset_receiving();
        test_33_reset_transmitting();
        test_34_reset_stalled();
        test_35_status_same_cycle();
        test_36_status_delayed();
        randomized_stress();

        $display("\n============================================================");
        $display("FINAL TESTBENCH SUMMARY");
        $display("============================================================");
        $display("Directed/random test groups passed : %0d", directed_pass_count);
        $display("Directed/random test groups failed : %0d", directed_fail_count);
        $display("Total checker errors              : %0d", error_count);
        $display("RX input frames observed          : %0d", rx_input_frame_count);
        $display("Expected good frames accepted     : %0d", expected_good_count);
        $display("Bad frames discarded              : %0d", bad_frame_count);
        $display("Oversized frames discarded        : %0d", oversized_drop_count);
        $display("Overflow-dropped frames           : %0d", overflow_drop_count);
        $display("AXI frames observed               : %0d", actual_frame_count);
        $display("AXI bytes accepted                : %0d", total_axis_beats);
        $display("Overflow events observed          : %0d", overflow_event_count);
        $display("============================================================");

        if (error_count == 0 && directed_fail_count == 0)
            $display("*** OVERALL RESULT: PASS ***");
        else
            $display("*** OVERALL RESULT: FAIL ***");

        $finish;
    end

    // Global simulation watchdog.
    initial begin
        #50ms;
        $fatal(1, "[TB] Global watchdog timeout");
    end

endmodule

`default_nettype wire
