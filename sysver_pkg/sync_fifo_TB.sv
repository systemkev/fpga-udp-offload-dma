`timescale 1ns/1ps

module tb_sync_fifo #(
    parameter int WIDTH  = 8,
    parameter int DEPTH  = 16,

    // Number of cycles in randomized stress test.
    parameter int RANDOM_CYCLES = 5000,

    // ----------------------------------------------------------------
    // DUT behavior configuration
    // ----------------------------------------------------------------

    // 0:
    //   rd_data is assumed to be a registered read result.
    //   After an accepted read, rd_data must equal the item removed.
    //
    // 1:
    //   First-word-fall-through / show-ahead behavior.
    //   Whenever FIFO is non-empty, rd_data must equal the front item.
    parameter bit FWFT_MODE = 1'b0,

    // At FULL with wr_en=1 and rd_en=1:
    //
    // 0 -> read succeeds, write is rejected.
    //      Occupancy changes DEPTH -> DEPTH-1.
    //
    // 1 -> both succeed.
    //      Oldest item is removed and new item is inserted.
    //      Occupancy stays DEPTH.
    parameter bit ALLOW_WRITE_ON_FULL_WITH_READ = 1'b0,

    // At EMPTY with wr_en=1 and rd_en=1:
    //
    // 0 -> write succeeds, read is rejected.
    //      Occupancy changes 0 -> 1.
    //
    // 1 -> write/read bypass is assumed:
    //      rd_data returns wr_data and occupancy stays 0.
    parameter bit ALLOW_READ_ON_EMPTY_WITH_WRITE = 1'b0
);

    // ================================================================
    // Clock / DUT interface
    // ================================================================

    logic                 clk;
    logic                 rst_n;

    logic                 wr_en;
    logic [WIDTH-1:0]     wr_data;
    logic                 full;

    logic                 rd_en;
    logic [WIDTH-1:0]     rd_data;
    logic                 empty;


    // ================================================================
    // DUT
    // ================================================================

    sync_fifo #(
        .WIDTH (WIDTH),
        .DEPTH (DEPTH)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),

        .wr_en   (wr_en),
        .wr_data (wr_data),
        .full    (full),

        .rd_en   (rd_en),
        .rd_data (rd_data),
        .empty   (empty)
    );


    // ================================================================
    // Reference model
    // ================================================================

    typedef logic [WIDTH-1:0] data_t;

    data_t model_q[$];

    longint unsigned cycle_count;

    int unsigned error_count;
    int unsigned check_count;


    // ================================================================
    // Coverage / event counters
    //
    // These are not functional coverage covergroups; they make sure the
    // directed/random tests actually exercised important event classes.
    // ================================================================

    int unsigned cov_write_accepted;
    int unsigned cov_read_accepted;

    int unsigned cov_write_rejected_full;
    int unsigned cov_read_rejected_empty;

    int unsigned cov_simultaneous;
    int unsigned cov_simultaneous_middle;
    int unsigned cov_simultaneous_full;
    int unsigned cov_simultaneous_empty;

    int unsigned cov_full_seen;
    int unsigned cov_empty_seen;

    int unsigned cov_reset;


    // ================================================================
    // Clock generation
    // ================================================================

    initial clk = 1'b0;

    always #5 clk = ~clk;


    // ================================================================
    // Utility functions
    // ================================================================

    function automatic data_t make_pattern(input int unsigned n);
        data_t result;

        for (int i = 0; i < WIDTH; i++) begin
            result[i] =
                ((n >> (i % 16)) ^
                 (i * 3) ^
                 (n * 7) ^
                 (i >> 2)) & 1;
        end

        return result;
    endfunction


    function automatic data_t random_data();
        data_t result;

        for (int i = 0; i < WIDTH; i++)
            result[i] = {$random} % 2;

        return result;
    endfunction


    // ================================================================
    // Reporting helper
    // ================================================================

    task automatic report_error(input string msg);
        error_count++;

        $error(
            "[TB ERROR] time=%0t cycle=%0d : %s",
            $time,
            cycle_count,
            msg
        );
    endtask


    // ================================================================
    // State checker
    // ================================================================

    task automatic check_state(input string tag = "");

        bit expected_empty;
        bit expected_full;

        expected_empty = (model_q.size() == 0);
        expected_full  = (model_q.size() == DEPTH);

        check_count++;


        // ------------------------------------------------------------
        // Detect X/Z on status flags.
        // ------------------------------------------------------------

        if ($isunknown(empty)) begin
            report_error(
                $sformatf(
                    "%s: EMPTY contains X/Z",
                    tag
                )
            );
        end

        if ($isunknown(full)) begin
            report_error(
                $sformatf(
                    "%s: FULL contains X/Z",
                    tag
                )
            );
        end


        // ------------------------------------------------------------
        // Check EMPTY.
        // ------------------------------------------------------------

        if (empty !== expected_empty) begin
            report_error(
                $sformatf(
                    "%s: EMPTY mismatch. DUT=%b expected=%b occupancy=%0d",
                    tag,
                    empty,
                    expected_empty,
                    model_q.size()
                )
            );
        end


        // ------------------------------------------------------------
        // Check FULL.
        // ------------------------------------------------------------

        if (full !== expected_full) begin
            report_error(
                $sformatf(
                    "%s: FULL mismatch. DUT=%b expected=%b occupancy=%0d DEPTH=%0d",
                    tag,
                    full,
                    expected_full,
                    model_q.size(),
                    DEPTH
                )
            );
        end


        // For any legal FIFO with DEPTH >= 1, FULL and EMPTY cannot
        // both be asserted.
        if ((full === 1'b1) && (empty === 1'b1)) begin
            report_error(
                $sformatf(
                    "%s: FULL and EMPTY are asserted simultaneously",
                    tag
                )
            );
        end


        // Reference model itself must never exceed the configured depth.
        if (model_q.size() > DEPTH) begin
            report_error(
                $sformatf(
                    "%s: TESTBENCH MODEL OVERFLOW: size=%0d DEPTH=%0d",
                    tag,
                    model_q.size(),
                    DEPTH
                )
            );
        end


        // ------------------------------------------------------------
        // FWFT / show-ahead mode
        //
        // When non-empty, rd_data must always show the oldest item.
        // ------------------------------------------------------------

        if (FWFT_MODE && (model_q.size() != 0)) begin

            if ($isunknown(rd_data)) begin
                report_error(
                    $sformatf(
                        "%s: FWFT rd_data contains X/Z while FIFO is non-empty",
                        tag
                    )
                );
            end
            else if (rd_data !== model_q[0]) begin
                report_error(
                    $sformatf(
                        "%s: FWFT rd_data mismatch. DUT=0x%0h expected_front=0x%0h occupancy=%0d",
                        tag,
                        rd_data,
                        model_q[0],
                        model_q.size()
                    )
                );
            end
        end


        if (expected_full)
            cov_full_seen++;

        if (expected_empty)
            cov_empty_seen++;

    endtask


    // ================================================================
    // Main transaction/checking task
    //
    // Inputs are changed on negedge to avoid races with DUT logic.
    //
    // The reference model uses PRE-CLOCK occupancy to determine whether
    // a requested operation is accepted.
    // ================================================================

    task automatic drive_cycle(
        input bit    do_write,
        input bit    do_read,
        input data_t write_value,
        input string tag = ""
    );

        int pre_size;

        bit pre_full;
        bit pre_empty;

        bit write_accepted;
        bit read_accepted;

        bit expected_read_valid;
        data_t expected_read_data;


        // Drive signals away from active DUT clock edge.
        @(negedge clk);

        pre_size  = model_q.size();
        pre_empty = (pre_size == 0);
        pre_full  = (pre_size == DEPTH);


        wr_en   = do_write;
        rd_en   = do_read;
        wr_data = write_value;


        // ------------------------------------------------------------
        // Determine whether requests should be accepted.
        // ------------------------------------------------------------

        write_accepted =
            do_write &&
            (
                !pre_full ||

                (
                    pre_full &&
                    do_read &&
                    ALLOW_WRITE_ON_FULL_WITH_READ
                )
            );


        read_accepted =
            do_read &&
            (
                !pre_empty ||

                (
                    pre_empty &&
                    do_write &&
                    ALLOW_READ_ON_EMPTY_WITH_WRITE
                )
            );


        // ------------------------------------------------------------
        // Event coverage
        // ------------------------------------------------------------

        if (do_write && do_read) begin
            cov_simultaneous++;

            if (pre_empty)
                cov_simultaneous_empty++;
            else if (pre_full)
                cov_simultaneous_full++;
            else
                cov_simultaneous_middle++;
        end


        if (write_accepted)
            cov_write_accepted++;

        if (read_accepted)
            cov_read_accepted++;

        if (do_write && pre_full && !write_accepted)
            cov_write_rejected_full++;

        if (do_read && pre_empty && !read_accepted)
            cov_read_rejected_empty++;


        // ------------------------------------------------------------
        // Calculate expected read data and update the reference model.
        // ------------------------------------------------------------

        expected_read_valid = 1'b0;
        expected_read_data  = 'x;


        // Special EMPTY simultaneous read/write bypass case.
        if (
            pre_empty                             &&
            do_write                              &&
            do_read                               &&
            ALLOW_READ_ON_EMPTY_WITH_WRITE        &&
            write_accepted                        &&
            read_accepted
        ) begin

            // FIFO remains empty, but read obtains the incoming data.
            expected_read_valid = 1'b1;
            expected_read_data  = write_value;

        end
        else begin

            // Normal read: remove oldest item first.
            if (read_accepted) begin

                if (model_q.size() == 0) begin
                    report_error(
                        $sformatf(
                            "%s: internal TB error: attempted model pop while empty",
                            tag
                        )
                    );
                end
                else begin
                    expected_read_valid = 1'b1;
                    expected_read_data  = model_q[0];

                    model_q.pop_front();
                end
            end


            // Normal write: append newest item.
            if (write_accepted) begin

                if (model_q.size() >= DEPTH) begin
                    report_error(
                        $sformatf(
                            "%s: internal TB error: model write would exceed DEPTH",
                            tag
                        )
                    );
                end
                else begin
                    model_q.push_back(write_value);
                end
            end
        end


        // ------------------------------------------------------------
        // Execute DUT cycle.
        // ------------------------------------------------------------

        @(posedge clk);

        // Allow NBA/combinational settling.
        #1;

        cycle_count++;


        // ------------------------------------------------------------
        // Registered-output read check.
        // ------------------------------------------------------------

        if (!FWFT_MODE && expected_read_valid) begin

            if ($isunknown(rd_data)) begin
                report_error(
                    $sformatf(
                        "%s: rd_data contains X/Z after accepted read; expected 0x%0h",
                        tag,
                        expected_read_data
                    )
                );
            end
            else if (rd_data !== expected_read_data) begin
                report_error(
                    $sformatf(
                        "%s: READ DATA MISMATCH: DUT=0x%0h expected=0x%0h",
                        tag,
                        rd_data,
                        expected_read_data
                    )
                );
            end
        end


        // Check occupancy-derived outputs and, in FWFT mode, rd_data.
        check_state(tag);

    endtask


    // ================================================================
    // Reset
    //
    // rst_n is held low across rising clock edges. Therefore this task
    // works for either synchronous-active-low or asynchronous-active-low
    // reset implementations.
    //
    // It intentionally does NOT require flags to change immediately on
    // the falling edge of rst_n, because the user's interface does not
    // specify whether the reset is synchronous or asynchronous.
    // ================================================================

    task automatic reset_dut(input string tag = "reset");

        @(negedge clk);

        rst_n   = 1'b0;
        wr_en   = 1'b0;
        rd_en   = 1'b0;
        wr_data = '0;

        model_q.delete();

        cov_reset++;


        repeat (3) begin
            @(posedge clk);
            #1;
            check_state(tag);
        end


        @(negedge clk);

        rst_n = 1'b1;

        @(posedge clk);
        #1;

        check_state({tag, "_released"});

    endtask


    // ================================================================
    // Helpers
    // ================================================================

    task automatic fill_fifo(input int unsigned base = 0);

        int unsigned seq;

        seq = base;

        while (model_q.size() < DEPTH) begin
            drive_cycle(
                1'b1,
                1'b0,
                make_pattern(seq),
                "fill_fifo"
            );

            seq++;
        end

    endtask


    task automatic drain_fifo();

        while (model_q.size() != 0) begin
            drive_cycle(
                1'b0,
                1'b1,
                '0,
                "drain_fifo"
            );
        end

    endtask


    // ================================================================
    // TEST 1
    // Basic reset behavior
    // ================================================================

    task automatic test_reset();

        $display("\n[TB] TEST: reset");

        reset_dut("basic_reset");

    endtask


    // ================================================================
    // TEST 2
    // Underflow protection
    //
    // Attempts multiple reads while empty, followed by a normal
    // write/read to catch pointer corruption caused by bad underflow
    // handling.
    // ================================================================

    task automatic test_underflow();

        $display("\n[TB] TEST: underflow / empty reads");

        reset_dut("underflow_reset");


        repeat (4) begin
            drive_cycle(
                1'b0,
                1'b1,
                '0,
                "read_while_empty"
            );
        end


        // Verify rejected reads did not corrupt internal state.
        drive_cycle(
            1'b1,
            1'b0,
            make_pattern(32'h1111),
            "post_underflow_write"
        );

        drive_cycle(
            1'b0,
            1'b1,
            '0,
            "post_underflow_read"
        );

    endtask


    // ================================================================
    // TEST 3
    // Basic ordering
    // ================================================================

    task automatic test_basic_ordering();

        $display("\n[TB] TEST: basic FIFO ordering");

        reset_dut("ordering_reset");


        for (int i = 0; i < DEPTH; i++) begin
            drive_cycle(
                1'b1,
                1'b0,
                make_pattern(i + 100),
                "ordering_write"
            );
        end


        for (int i = 0; i < DEPTH; i++) begin
            drive_cycle(
                1'b0,
                1'b1,
                '0,
                "ordering_read"
            );
        end

    endtask


    // ================================================================
    // TEST 4
    // Full flag and overflow protection
    //
    // After filling the FIFO, perform several writes while full.
    // Draining afterwards verifies that rejected writes did not corrupt
    // stored data or pointers.
    // ================================================================

    task automatic test_overflow();

        $display("\n[TB] TEST: overflow / writes while full");

        reset_dut("overflow_reset");

        fill_fifo(1000);


        repeat (4) begin
            drive_cycle(
                1'b1,
                1'b0,
                random_data(),
                "write_while_full"
            );
        end


        drain_fifo();

    endtask


    // ================================================================
    // TEST 5
    // Simultaneous read/write from normal occupancy
    //
    // Occupancy should remain constant while data continues moving
    // through the FIFO.
    // ================================================================

    task automatic test_simultaneous_middle();

        int initial_fill;

        $display("\n[TB] TEST: simultaneous read/write at middle occupancy");

        reset_dut("simul_middle_reset");


        if (DEPTH == 1) begin
            $display(
                "[TB] DEPTH=1: no middle occupancy exists; skipping middle-state test"
            );

            return;
        end


        initial_fill = DEPTH / 2;

        if (initial_fill == 0)
            initial_fill = 1;


        for (int i = 0; i < initial_fill; i++) begin
            drive_cycle(
                1'b1,
                1'b0,
                make_pattern(2000 + i),
                "simul_middle_prefill"
            );
        end


        // Run long enough to cause pointer wraparound during
        // simultaneous activity as well.
        repeat (2 * DEPTH + 5) begin
            drive_cycle(
                1'b1,
                1'b1,
                random_data(),
                "simul_middle"
            );
        end


        drain_fifo();

    endtask


    // ================================================================
    // TEST 6
    // Simultaneous read/write while FULL
    //
    // This specifically targets next-state/full gating mistakes.
    // Behavior follows ALLOW_WRITE_ON_FULL_WITH_READ.
    // ================================================================

    task automatic test_simultaneous_full();

        $display("\n[TB] TEST: simultaneous read/write while FULL");

        reset_dut("simul_full_reset");

        fill_fifo(3000);


        drive_cycle(
            1'b1,
            1'b1,
            make_pattern(32'hF001),
            "simultaneous_at_full"
        );


        // Additional traffic exposes pointer/count corruption that may
        // not be visible immediately.
        if (model_q.size() < DEPTH) begin
            drive_cycle(
                1'b1,
                1'b0,
                make_pattern(32'hF002),
                "write_after_full_simultaneous"
            );
        end


        drain_fifo();

    endtask


    // ================================================================
    // TEST 7
    // Simultaneous read/write while EMPTY
    //
    // Targets next-state/empty gating and optional bypass behavior.
    // ================================================================

    task automatic test_simultaneous_empty();

        $display("\n[TB] TEST: simultaneous read/write while EMPTY");

        reset_dut("simul_empty_reset");


        drive_cycle(
            1'b1,
            1'b1,
            make_pattern(32'hE001),
            "simultaneous_at_empty"
        );


        // If conventional behavior is used, the write remains in the
        // FIFO and this read checks it.
        if (model_q.size() != 0)
            drain_fifo();


        // Verify pointers remain healthy afterwards.
        drive_cycle(
            1'b1,
            1'b0,
            make_pattern(32'hE002),
            "post_empty_simul_write"
        );

        drive_cycle(
            1'b0,
            1'b1,
            '0,
            "post_empty_simul_read"
        );

    endtask


    // ================================================================
    // TEST 8
    // Pointer wraparound
    //
    // Particularly important for:
    //   DEPTH=3
    //   DEPTH=5
    //   DEPTH=6
    //   DEPTH=17
    //
    // because pointer width using $clog2(DEPTH) creates unused binary
    // pointer values that must never address invalid FIFO entries.
    // ================================================================

    task automatic test_pointer_wraparound();

        int move_count;
        int unsigned seq;

        $display("\n[TB] TEST: repeated pointer wraparound");

        reset_dut("wrap_reset");

        seq = 4000;

        fill_fifo(seq);

        seq += DEPTH;


        if (DEPTH > 1)
            move_count = (DEPTH + 1) / 2;
        else
            move_count = 1;


        // Repeatedly advance both pointers across the physical end of
        // the memory while preserving queued ordering.
        repeat (6) begin

            for (int i = 0; i < move_count; i++) begin
                drive_cycle(
                    1'b0,
                    1'b1,
                    '0,
                    "wrap_read"
                );
            end


            for (int i = 0; i < move_count; i++) begin
                drive_cycle(
                    1'b1,
                    1'b0,
                    make_pattern(seq),
                    "wrap_write"
                );

                seq++;
            end

        end


        drain_fifo();

    endtask


    // ================================================================
    // TEST 9
    // Repeated full -> empty -> full transitions
    //
    // Exercises exact count boundary transitions repeatedly rather than
    // only once.
    // ================================================================

    task automatic test_repeated_boundaries();

        int unsigned seq;

        $display("\n[TB] TEST: repeated FULL/EMPTY transitions");

        reset_dut("boundary_reset");

        seq = 5000;


        repeat (4) begin

            while (model_q.size() < DEPTH) begin
                drive_cycle(
                    1'b1,
                    1'b0,
                    make_pattern(seq),
                    "boundary_fill"
                );

                seq++;
            end


            while (model_q.size() != 0) begin
                drive_cycle(
                    1'b0,
                    1'b1,
                    '0,
                    "boundary_drain"
                );
            end

        end

    endtask


    // ================================================================
    // TEST 10
    // Reset while FIFO contains valid data
    //
    // wr_en and rd_en are intentionally asserted when reset is applied
    // to test reset priority over normal FIFO operations.
    // ================================================================

    task automatic test_reset_during_traffic();

        $display("\n[TB] TEST: reset during active traffic");

        reset_dut("traffic_reset_initial");


        // Put some data into FIFO.
        for (int i = 0; (i < DEPTH) && (i < 4); i++) begin
            drive_cycle(
                1'b1,
                1'b0,
                make_pattern(6000 + i),
                "pre_reset_traffic"
            );
        end


        // Assert reset while both operations are requested.
        @(negedge clk);

        wr_en   = 1'b1;
        rd_en   = 1'b1;
        wr_data = make_pattern(32'hDEAD);
        rst_n   = 1'b0;

        model_q.delete();

        cov_reset++;


        @(posedge clk);
        #1;

        cycle_count++;

        check_state("reset_during_traffic_first_edge");


        // Keep reset asserted for another edge.
        @(posedge clk);
        #1;

        cycle_count++;

        check_state("reset_during_traffic_second_edge");


        // Release reset cleanly away from active edge.
        @(negedge clk);

        rst_n   = 1'b1;
        wr_en   = 1'b0;
        rd_en   = 1'b0;
        wr_data = '0;


        @(posedge clk);
        #1;

        cycle_count++;

        check_state("reset_during_traffic_released");


        // Ensure FIFO behaves normally after reset.
        drive_cycle(
            1'b1,
            1'b0,
            make_pattern(32'hBEEF),
            "post_reset_write"
        );

        drive_cycle(
            1'b0,
            1'b1,
            '0,
            "post_reset_read"
        );

    endtask


    // ================================================================
    // TEST 11
    // Randomized stress
    //
    // Random generation intentionally becomes aggressive near FULL and
    // EMPTY so illegal-operation handling and boundary simultaneous
    // cases are repeatedly exercised.
    // ================================================================

    task automatic test_random_stress();

        int choice;
        int current_size;

        bit do_write;
        bit do_read;

        data_t value;

        $display(
            "\n[TB] TEST: randomized stress, %0d cycles",
            RANDOM_CYCLES
        );


        reset_dut("random_reset");


        for (int i = 0; i < RANDOM_CYCLES; i++) begin

            current_size = model_q.size();

            do_write = 1'b0;
            do_read  = 1'b0;

            choice = {$random} % 100;


            // --------------------------------------------------------
            // EMPTY
            //
            // Heavily exercise:
            //   - underflow
            //   - simultaneous empty access
            // --------------------------------------------------------

            if (current_size == 0) begin

                case (choice)
                    inside

                    [0:9]: begin
                        // idle
                        do_write = 0;
                        do_read  = 0;
                    end

                    [10:34]: begin
                        // normal recovery from empty
                        do_write = 1;
                        do_read  = 0;
                    end

                    [35:64]: begin
                        // illegal read / underflow attempt
                        do_write = 0;
                        do_read  = 1;
                    end

                    default: begin
                        // simultaneous at empty
                        do_write = 1;
                        do_read  = 1;
                    end

                endcase

            end


            // --------------------------------------------------------
            // FULL
            //
            // Heavily exercise:
            //   - overflow
            //   - simultaneous full access
            // --------------------------------------------------------

            else if (current_size == DEPTH) begin

                case (choice)
                    inside

                    [0:9]: begin
                        do_write = 0;
                        do_read  = 0;
                    end

                    [10:39]: begin
                        // illegal write / overflow attempt
                        do_write = 1;
                        do_read  = 0;
                    end

                    [40:64]: begin
                        do_write = 0;
                        do_read  = 1;
                    end

                    default: begin
                        do_write = 1;
                        do_read  = 1;
                    end

                endcase

            end


            // --------------------------------------------------------
            // Normal middle occupancy.
            // --------------------------------------------------------

            else begin

                case (choice)
                    inside

                    [0:9]: begin
                        do_write = 0;
                        do_read  = 0;
                    end

                    [10:34]: begin
                        do_write = 1;
                        do_read  = 0;
                    end

                    [35:59]: begin
                        do_write = 0;
                        do_read  = 1;
                    end

                    default: begin
                        do_write = 1;
                        do_read  = 1;
                    end

                endcase

            end


            value = random_data();


            drive_cycle(
                do_write,
                do_read,
                value,
                $sformatf("random_cycle_%0d", i)
            );

        end


        // Finish by draining whatever remains. This catches latent data
        // or pointer corruption created during random traffic.
        drain_fifo();

    endtask


    // ================================================================
    // Coverage sanity checks
    //
    // If these fail, it usually means the testbench configuration or
    // directed tests failed to exercise an important scenario.
    // ================================================================

    task automatic check_coverage();

        $display("\n");
        $display("============================================================");
        $display("                    TEST COVERAGE SUMMARY");
        $display("============================================================");

        $display("Accepted writes                 : %0d",
                 cov_write_accepted);

        $display("Accepted reads                  : %0d",
                 cov_read_accepted);

        $display("Rejected writes while FULL      : %0d",
                 cov_write_rejected_full);

        $display("Rejected reads while EMPTY      : %0d",
                 cov_read_rejected_empty);

        $display("Simultaneous rd/wr requests     : %0d",
                 cov_simultaneous);

        $display("Simultaneous at middle occupancy: %0d",
                 cov_simultaneous_middle);

        $display("Simultaneous while FULL         : %0d",
                 cov_simultaneous_full);

        $display("Simultaneous while EMPTY        : %0d",
                 cov_simultaneous_empty);

        $display("FULL state checks               : %0d",
                 cov_full_seen);

        $display("EMPTY state checks              : %0d",
                 cov_empty_seen);

        $display("Reset sequences                 : %0d",
                 cov_reset);

        $display("Total self-checks               : %0d",
                 check_count);

        $display("============================================================");


        if (cov_write_accepted == 0)
            report_error("Coverage failure: no accepted writes");

        if (cov_read_accepted == 0)
            report_error("Coverage failure: no accepted reads");

        if (cov_simultaneous == 0)
            report_error("Coverage failure: simultaneous read/write never tested");

        if (cov_simultaneous_full == 0)
            report_error("Coverage failure: simultaneous rd/wr at FULL never tested");

        if (cov_simultaneous_empty == 0)
            report_error("Coverage failure: simultaneous rd/wr at EMPTY never tested");

        if (cov_full_seen == 0)
            report_error("Coverage failure: FULL state was never reached");

        if (cov_empty_seen == 0)
            report_error("Coverage failure: EMPTY state was never reached");


        // These rejected-operation checks only apply when the configured
        // semantics actually reject the respective operation.
        if (
            !ALLOW_WRITE_ON_FULL_WITH_READ &&
            (cov_write_rejected_full == 0)
        )
            report_error(
                "Coverage failure: rejected FULL writes were never exercised"
            );


        if (
            !ALLOW_READ_ON_EMPTY_WITH_WRITE &&
            (cov_read_rejected_empty == 0)
        )
            report_error(
                "Coverage failure: rejected EMPTY reads were never exercised"
            );


        if ((DEPTH > 1) && (cov_simultaneous_middle == 0))
            report_error(
                "Coverage failure: simultaneous rd/wr at middle occupancy never tested"
            );

    endtask


    // ================================================================
    // Watchdog
    // ================================================================

    initial begin
        #10_000_000;

        $fatal(
            1,
            "[TB] WATCHDOG TIMEOUT: simulation did not complete"
        );
    end


    // ================================================================
    // Main test sequence
    // ================================================================

    initial begin
        int dummy;

        int unsigned seed;


        // ------------------------------------------------------------
        // Initial values
        // ------------------------------------------------------------

        rst_n   = 1'b0;
        wr_en   = 1'b0;
        rd_en   = 1'b0;
        wr_data = '0;

        model_q.delete();

        cycle_count = 0;
        error_count = 0;
        check_count = 0;

        cov_write_accepted          = 0;
        cov_read_accepted           = 0;
        cov_write_rejected_full     = 0;
        cov_read_rejected_empty     = 0;
        cov_simultaneous            = 0;
        cov_simultaneous_middle     = 0;
        cov_simultaneous_full       = 0;
        cov_simultaneous_empty      = 0;
        cov_full_seen               = 0;
        cov_empty_seen              = 0;
        cov_reset                   = 0;


        // ------------------------------------------------------------
        // Parameter sanity
        // ------------------------------------------------------------

        if (WIDTH < 1)
            $fatal(1, "WIDTH must be >= 1");

        if (DEPTH < 1)
            $fatal(1, "DEPTH must be >= 1");


        // ------------------------------------------------------------
        // Seed control
        //
        // Example:
        //
        //   +SEED=12345
        // ------------------------------------------------------------

        seed = 32'h1BAD_F00D;

        if ($value$plusargs("SEED=%d", seed)) begin
            $display("[TB] Using command-line random seed: %0d", seed);
        end
        else begin
            $display("[TB] Using default random seed: %0d", seed);
        end

        dummy = $random(seed);


        $display("");
        $display("============================================================");
        $display("              SYNCHRONOUS FIFO SELF-CHECKING TB");
        $display("============================================================");
        $display("WIDTH                            = %0d", WIDTH);
        $display("DEPTH                            = %0d", DEPTH);
        $display("RANDOM_CYCLES                    = %0d", RANDOM_CYCLES);
        $display("FWFT_MODE                        = %0d", FWFT_MODE);
        $display("ALLOW_WRITE_ON_FULL_WITH_READ    = %0d",
                 ALLOW_WRITE_ON_FULL_WITH_READ);
        $display("ALLOW_READ_ON_EMPTY_WITH_WRITE   = %0d",
                 ALLOW_READ_ON_EMPTY_WITH_WRITE);
        $display("SEED                             = %0d", seed);
        $display("============================================================");


        // ------------------------------------------------------------
        // Tests
        // ------------------------------------------------------------

        test_reset();

        test_underflow();

        test_basic_ordering();

        test_overflow();

        test_simultaneous_middle();

        test_simultaneous_full();

        test_simultaneous_empty();

        test_pointer_wraparound();

        test_repeated_boundaries();

        test_reset_during_traffic();

        test_random_stress();


        // Final clean idle cycles.
        repeat (3) begin
            drive_cycle(
                1'b0,
                1'b0,
                '0,
                "final_idle"
            );
        end


        check_coverage();


        // ------------------------------------------------------------
        // Final result
        // ------------------------------------------------------------

        $display("");

        if (error_count == 0) begin
            $display("############################################################");
            $display("#                                                          #");
            $display("#                      TEST PASSED                         #");
            $display("#                                                          #");
            $display("#  Total checked cycles : %-8d                         #",
                     cycle_count);
            $display("#  Errors               : 0                               #");
            $display("#                                                          #");
            $display("############################################################");
        end
        else begin
            $display("############################################################");
            $display("#                                                          #");
            $display("#                      TEST FAILED                         #");
            $display("#                                                          #");
            $display("#  Total checked cycles : %-8d                         #",
                     cycle_count);
            $display("#  Errors               : %-8d                         #",
                     error_count);
            $display("#                                                          #");
            $display("############################################################");

            $fatal(
                1,
                "[TB] FIFO verification failed with %0d error(s)",
                error_count
            );
        end


        $finish;

    end

endmodule