`timescale 1ns/1ps

module mii_rx_mac_TB;

    localparam int          CLK_PERIOD   = 10;
    localparam int          RANDOM_TESTS = 100;
    localparam int unsigned RANDOM_SEED  = 32'h5EED_1234;
    localparam int          MIN_ACCEPTED_PREAMBLE_BYTES = 1;

    // MII presents one byte every two clocks. A receiver that must wait for
    // RX_DV to fall before tagging the final payload byte may insert one extra
    // cycle immediately before the final byte.
    localparam bit ALLOW_ONE_EXTRA_CYCLE_BEFORE_LAST = 1'b1;

    logic       rx_clk;
    logic       n_reset;
    logic [3:0] mii_rxd;
    logic       mii_rx_dv;
    logic       mii_rx_er;

    logic [7:0] rx_data;
    logic       rx_valid;
    logic       rx_last;
    logic       frame_good;
    logic       frame_bad;

    typedef logic [7:0] byte_q_t[$];

    // ------------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------------

    mii_rx_mac dut (
        .i_rx_clk      (rx_clk),
        .i_n_reset     (n_reset),

        .i_mii_rxd     (mii_rxd),
        .i_mii_rx_dv   (mii_rx_dv),
        .i_mii_rx_er   (mii_rx_er),

        .o_rx_data     (rx_data),
        .o_rx_valid    (rx_valid),
        .o_rx_last     (rx_last),

        .o_frame_good  (frame_good),
        .o_frame_bad   (frame_bad)
    );

    // ------------------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------------------

    initial
        rx_clk = 1'b0;

    always #(CLK_PERIOD/2)
        rx_clk = ~rx_clk;


    // ========================================================================
    // REFERENCE CRC
    // ========================================================================

    function automatic logic [31:0] calculate_fcs(
        input byte_q_t data
    );
        logic [31:0] crc;

        crc = 32'hFFFF_FFFF;

        foreach (data[i]) begin
            for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin

                if (crc[0] ^ data[i][bit_idx])
                    crc = (crc >> 1) ^ 32'hEDB88320;
                else
                    crc = crc >> 1;

            end
        end

        return ~crc;
    endfunction


    task automatic append_fcs(
        input  byte_q_t data,
        output byte_q_t wire_frame
    );
        logic [31:0] fcs;

        wire_frame = data;
        fcs = calculate_fcs(data);

        // Ethernet FCS byte ordering: least-significant byte first
        wire_frame.push_back(fcs[7:0]);
        wire_frame.push_back(fcs[15:8]);
        wire_frame.push_back(fcs[23:16]);
        wire_frame.push_back(fcs[31:24]);
    endtask


    // ========================================================================
    // RANDOM FRAME GENERATION
    // ========================================================================

    task automatic make_random_data(
        input  int      length,
        output byte_q_t data
    );
        data.delete();

        repeat (length)
            data.push_back($urandom_range(255, 0));
    endtask


    task automatic make_constant_data(
        input  int         length,
        input  logic [7:0] value,
        output byte_q_t    data
    );
        data.delete();
        repeat (length)
            data.push_back(value);
    endtask


    task automatic make_alternating_data(
        input  int         length,
        input  logic [7:0] a,
        input  logic [7:0] b,
        output byte_q_t    data
    );
        data.delete();
        for (int i = 0; i < length; i++)
            data.push_back((i & 1) ? b : a);
    endtask


    task automatic make_incrementing_data(
        input  int      length,
        output byte_q_t data
    );
        data.delete();
        for (int i = 0; i < length; i++)
            data.push_back(i[7:0]);
    endtask


    // ========================================================================
    // MII DRIVER
    //
    // Drive on falling edge so all inputs are stable before DUT samples them
    // on rising edge.
    // ========================================================================

    task automatic drive_nibble(
        input logic [3:0] nibble,
        input logic       dv,
        input logic       er
    );
        @(negedge rx_clk);

        mii_rxd   = nibble;
        mii_rx_dv = dv;
        mii_rx_er = er;
    endtask


    task automatic drive_stream_byte(
        input logic [7:0] data,
        input int         error_nibble,
        inout int         nibble_index
    );

        // MII sends low nibble first
        drive_nibble(
            data[3:0],
            1'b1,
            nibble_index == error_nibble
        );

        nibble_index++;


        drive_nibble(
            data[7:4],
            1'b1,
            nibble_index == error_nibble
        );

        nibble_index++;

    endtask


    // ------------------------------------------------------------------------
    // Send:
    //
    // 55 x preamble_count
    // SFD
    // frame bytes including FCS
    //
    // error_nibble = -1 means no RX_ER injection.
    //
    // Nibble index starts at first nibble of first preamble byte.
    // ------------------------------------------------------------------------

    task automatic send_wire_frame(
        input byte_q_t    wire_frame,
        input int         preamble_count,
        input logic [7:0] sfd,
        input int         error_nibble
    );

        int nibble_index;

        nibble_index = 0;

        // Preamble
        repeat (preamble_count) begin
            drive_stream_byte(
                8'h55,
                error_nibble,
                nibble_index
            );
        end

        // SFD
        drive_stream_byte(
            sfd,
            error_nibble,
            nibble_index
        );

        // Frame data + FCS
        foreach (wire_frame[i]) begin
            drive_stream_byte(
                wire_frame[i],
                error_nibble,
                nibble_index
            );
        end

        // End frame
        drive_nibble(
            4'h0,
            1'b0,
            1'b0
        );

    endtask


    // Send a valid preamble/SFD and then intentionally terminate RX_DV early.
    // complete_wire_bytes counts bytes from the Ethernet frame including any
    // FCS bytes already sent. If send_low_nibble_of_next is set, only the low
    // nibble of the next byte is transmitted before RX_DV drops.
    task automatic send_truncated_wire_frame(
        input byte_q_t wire_frame,
        input int      complete_wire_bytes,
        input bit      send_low_nibble_of_next
    );
        int nibble_index;

        nibble_index = 0;

        repeat (7)
            drive_stream_byte(8'h55, -1, nibble_index);

        drive_stream_byte(8'hD5, -1, nibble_index);

        for (int i = 0; i < complete_wire_bytes; i++)
            drive_stream_byte(wire_frame[i], -1, nibble_index);

        if (send_low_nibble_of_next) begin
            drive_nibble(
                wire_frame[complete_wire_bytes][3:0],
                1'b1,
                1'b0
            );
            nibble_index++;
        end

        drive_nibble(4'h0, 1'b0, 1'b0);
    endtask


    task automatic idle_clocks(
        input int count
    );

        repeat (count) begin
            drive_nibble(
                4'h0,
                1'b0,
                1'b0
            );
        end

    endtask


    // ========================================================================
    // OUTPUT MONITOR / SCOREBOARD
    // ========================================================================

    byte_q_t observed_data;

    int observed_valid_count;
    int observed_last_count;
    int observed_good_count;
    int observed_bad_count;
    int last_without_valid_count;
    int unknown_control_count;
    int unknown_data_count;

    int last_positions[$];
    int valid_cycle_positions[$];
    int last_cycle_positions[$];
    int good_cycle_positions[$];
    int bad_cycle_positions[$];
    int dv_fall_cycle_positions[$];

    int   cycle_count;
    logic prev_mii_rx_dv;


    always @(posedge rx_clk) begin
        cycle_count++;

        // Let DUT NBA assignments settle.
        #1;

        if (n_reset) begin

            if (prev_mii_rx_dv && !mii_rx_dv)
                dv_fall_cycle_positions.push_back(cycle_count);

            if (
                $isunknown(rx_valid) ||
                $isunknown(rx_last) ||
                $isunknown(frame_good) ||
                $isunknown(frame_bad)
            ) begin
                unknown_control_count++;
            end

            if (rx_valid === 1'b1) begin

                if ($isunknown(rx_data))
                    unknown_data_count++;

                valid_cycle_positions.push_back(cycle_count);

                if (rx_last === 1'b1) begin
                    observed_last_count++;
                    last_positions.push_back(observed_data.size());
                    last_cycle_positions.push_back(cycle_count);
                end

                observed_data.push_back(rx_data);
                observed_valid_count++;

            end else if (rx_last === 1'b1) begin

                last_without_valid_count++;

            end

            if (frame_good === 1'b1) begin
                observed_good_count++;
                good_cycle_positions.push_back(cycle_count);
            end

            if (frame_bad === 1'b1) begin
                observed_bad_count++;
                bad_cycle_positions.push_back(cycle_count);
            end

        end

        prev_mii_rx_dv = mii_rx_dv;
    end


    task automatic clear_observations;

        observed_data.delete();
        last_positions.delete();
        valid_cycle_positions.delete();
        last_cycle_positions.delete();
        good_cycle_positions.delete();
        bad_cycle_positions.delete();
        dv_fall_cycle_positions.delete();

        observed_valid_count      = 0;
        observed_last_count       = 0;
        observed_good_count       = 0;
        observed_bad_count        = 0;
        last_without_valid_count  = 0;
        unknown_control_count     = 0;
        unknown_data_count        = 0;

    endtask


    // ========================================================================
    // TEST RESULT HELPERS
    // ========================================================================

    int tests_run;
    int tests_failed;


    task automatic record_result(
        input string name,
        input bit    pass
    );

        tests_run++;

        if (pass) begin
            $display("[PASS] %s", name);
        end else begin
            tests_failed++;
            $display("[FAIL] %s", name);
        end

    endtask


    task automatic wait_for_status(
        input  int required_status_count,
        input  int timeout_cycles,
        output bit success
    );

        success = 1'b0;

        for (int i = 0; i < timeout_cycles; i++) begin

            @(negedge rx_clk);

            if (
                observed_good_count +
                observed_bad_count >= required_status_count
            ) begin
                success = 1'b1;
                break;
            end

        end

    endtask


    function automatic bit queues_equal(
        input byte_q_t a,
        input byte_q_t b
    );

        if (a.size() != b.size())
            return 1'b0;

        foreach (a[i]) begin
            if (a[i] !== b[i])
                return 1'b0;
        end

        return 1'b1;

    endfunction


    task automatic check_no_unknown_outputs(
        inout bit pass
    );
        if (unknown_control_count != 0) begin
            $display(
                "       Unknown/X control output observed %0d time(s)",
                unknown_control_count
            );
            pass = 1'b0;
        end

        if (unknown_data_count != 0) begin
            $display(
                "       Unknown/X o_rx_data observed while o_rx_valid was high %0d time(s)",
                unknown_data_count
            );
            pass = 1'b0;
        end
    endtask


    // Check the byte-rate contract of an MII receiver. Consecutive payload
    // bytes should normally be separated by exactly two MII clocks. The final
    // byte may be delayed by one additional clock if the implementation waits
    // for RX_DV deassertion before deciding which buffered byte is the last
    // non-FCS byte.
    task automatic check_output_cadence(
        input int expected_bytes,
        inout bit pass
    );
        int delta;

        if (valid_cycle_positions.size() != expected_bytes) begin
            $display(
                "       Valid-cycle count = %0d, expected %0d",
                valid_cycle_positions.size(),
                expected_bytes
            );
            pass = 1'b0;
        end

        for (int i = 1; i < valid_cycle_positions.size(); i++) begin
            delta = valid_cycle_positions[i] - valid_cycle_positions[i-1];

            if (
                ALLOW_ONE_EXTRA_CYCLE_BEFORE_LAST &&
                (i == valid_cycle_positions.size()-1)
            ) begin
                if ((delta != 2) && (delta != 3)) begin
                    $display(
                        "       Output cadence error before final byte: byte %0d arrived %0d clocks after byte %0d; expected 2 or 3",
                        i, delta, i-1
                    );
                    pass = 1'b0;
                end
            end else if (delta != 2) begin
                $display(
                    "       Output cadence error: byte %0d arrived %0d clocks after byte %0d; expected 2",
                    i, delta, i-1
                );
                pass = 1'b0;
            end
        end
    endtask


    task automatic check_good_status_timing(
        inout bit pass
    );
        if (
            good_cycle_positions.size() == 1 &&
            valid_cycle_positions.size() != 0 &&
            good_cycle_positions[0] < valid_cycle_positions[valid_cycle_positions.size()-1]
        ) begin
            $display(
                "       frame_good asserted before the final payload byte was presented"
            );
            pass = 1'b0;
        end
    endtask


    task automatic check_bad_status_timing(
        inout bit pass
    );
        if (
            bad_cycle_positions.size() == 1 &&
            valid_cycle_positions.size() != 0 &&
            bad_cycle_positions[0] < valid_cycle_positions[valid_cycle_positions.size()-1]
        ) begin
            $display(
                "       frame_bad asserted before the final streamed payload byte"
            );
            pass = 1'b0;
        end
    endtask


    // For a completed good/CRC-checked frame, status and o_rx_last must not be
    // asserted before the receiver has actually sampled RX_DV low.
    task automatic check_end_of_frame_timing(
        input bit status_is_good,
        inout bit pass
    );
        int status_cycle;

        if (dv_fall_cycle_positions.size() != 1) begin
            $display(
                "       Expected exactly one RX_DV falling edge, observed %0d",
                dv_fall_cycle_positions.size()
            );
            pass = 1'b0;
        end else begin
            if (status_is_good) begin
                if (good_cycle_positions.size() == 1) begin
                    status_cycle = good_cycle_positions[0];
                    if (status_cycle < dv_fall_cycle_positions[0]) begin
                        $display("       frame_good asserted before RX_DV fell");
                        pass = 1'b0;
                    end
                end
            end else begin
                if (bad_cycle_positions.size() == 1) begin
                    status_cycle = bad_cycle_positions[0];
                    if (status_cycle < dv_fall_cycle_positions[0]) begin
                        $display("       frame_bad asserted before RX_DV fell");
                        pass = 1'b0;
                    end
                end
            end

            if (
                last_cycle_positions.size() == 1 &&
                last_cycle_positions[0] < dv_fall_cycle_positions[0]
            ) begin
                $display("       o_rx_last asserted before RX_DV fell");
                pass = 1'b0;
            end
        end
    endtask


    // ========================================================================
    // CHECK GOOD FRAME
    // ========================================================================

    task automatic check_good_frame(
        input string   name,
        input byte_q_t expected
    );

        bit status_seen;
        bit pass;

        pass = 1'b1;

        wait_for_status(
            1,
            50,
            status_seen
        );

        // Watch a couple more clocks for duplicate outputs/status pulses
        repeat (3) @(negedge rx_clk);


        if (!status_seen) begin
            $display("       No frame status received.");
            pass = 1'b0;
        end


        if (observed_good_count != 1) begin
            $display(
                "       frame_good count = %0d, expected 1",
                observed_good_count
            );
            pass = 1'b0;
        end


        if (observed_bad_count != 0) begin
            $display(
                "       frame_bad count = %0d, expected 0",
                observed_bad_count
            );
            pass = 1'b0;
        end


        if (!queues_equal(observed_data, expected)) begin

            $display(
                "       Output byte mismatch: received %0d expected %0d",
                observed_data.size(),
                expected.size()
            );

            for (
                int i = 0;
                i < observed_data.size() && i < expected.size();
                i++
            ) begin

                if (observed_data[i] !== expected[i]) begin
                    $display(
                        "       First mismatch at byte %0d: got %02X expected %02X",
                        i,
                        observed_data[i],
                        expected[i]
                    );
                    break;
                end

            end

            pass = 1'b0;
        end


        if (observed_last_count != 1) begin
            $display(
                "       o_rx_last count = %0d, expected 1",
                observed_last_count
            );
            pass = 1'b0;
        end


        if (last_without_valid_count != 0) begin
            $display(
                "       o_rx_last occurred without o_rx_valid %0d time(s)",
                last_without_valid_count
            );
            pass = 1'b0;
        end


        if (
            expected.size() != 0 &&
            last_positions.size() == 1
        ) begin

            if (
                last_positions[0] !=
                expected.size() - 1
            ) begin

                $display(
                    "       TLAST at byte %0d, expected byte %0d",
                    last_positions[0],
                    expected.size()-1
                );

                pass = 1'b0;

            end
        end


        check_output_cadence(expected.size(), pass);
        check_good_status_timing(pass);
        check_end_of_frame_timing(1'b1, pass);
        check_no_unknown_outputs(pass);

        record_result(name, pass);

    endtask


    // ========================================================================
    // CHECK BAD FRAME
    //
    // Used when exact streamed data is not part of the test.
    // ========================================================================

    task automatic check_bad_status(
        input string name
    );

        bit status_seen;
        bit pass;

        pass = 1'b1;

        wait_for_status(
            1,
            50,
            status_seen
        );

        repeat (3) @(negedge rx_clk);


        if (!status_seen) begin
            $display("       No frame_bad/frame_good status received.");
            pass = 1'b0;
        end


        if (observed_good_count != 0) begin
            $display(
                "       frame_good asserted %0d time(s)",
                observed_good_count
            );
            pass = 1'b0;
        end


        if (observed_bad_count != 1) begin
            $display(
                "       frame_bad count = %0d, expected 1",
                observed_bad_count
            );
            pass = 1'b0;
        end


        check_bad_status_timing(pass);
        check_no_unknown_outputs(pass);

        record_result(name, pass);

    endtask


    // Used for failures that occur before payload reception begins. In these
    // cases the receiver should reject the frame without emitting any data.
    task automatic check_bad_no_output(
        input string name
    );
        bit status_seen;
        bit pass;

        pass = 1'b1;

        wait_for_status(1, 50, status_seen);
        repeat (3) @(negedge rx_clk);

        if (!status_seen) begin
            $display("       No frame_bad/frame_good status received.");
            pass = 1'b0;
        end

        if (observed_good_count != 0) begin
            $display(
                "       frame_good asserted %0d time(s)",
                observed_good_count
            );
            pass = 1'b0;
        end

        if (observed_bad_count != 1) begin
            $display(
                "       frame_bad count = %0d, expected 1",
                observed_bad_count
            );
            pass = 1'b0;
        end

        if (observed_valid_count != 0) begin
            $display(
                "       Malformed pre-frame input emitted %0d payload byte(s); expected 0",
                observed_valid_count
            );
            pass = 1'b0;
        end

        if (observed_last_count != 0 || last_without_valid_count != 0) begin
            $display("       o_rx_last asserted for a frame rejected before payload start");
            pass = 1'b0;
        end

        check_no_unknown_outputs(pass);
        record_result(name, pass);
    endtask



    // ========================================================================
    // CHECK BAD CRC FRAME
    //
    // Since the MAC cannot know FCS is bad until the frame ends, payload data
    // may already have streamed out. Therefore also verify the data path.
    // ========================================================================

    task automatic check_bad_crc_frame(
        input string   name,
        input byte_q_t expected_data
    );

        bit status_seen;
        bit pass;

        pass = 1'b1;

        wait_for_status(
            1,
            50,
            status_seen
        );

        repeat (3) @(negedge rx_clk);


        if (!status_seen)
            pass = 1'b0;


        if (observed_good_count != 0)
            pass = 1'b0;


        if (observed_bad_count != 1)
            pass = 1'b0;


        if (!queues_equal(observed_data, expected_data)) begin
            $display(
                "       Streamed data does not match received frame data."
            );
            pass = 1'b0;
        end


        if (observed_last_count != 1) begin
            $display(
                "       Expected exactly one o_rx_last."
            );
            pass = 1'b0;
        end


        if (last_without_valid_count != 0) begin
            $display(
                "       o_rx_last occurred without o_rx_valid %0d time(s)",
                last_without_valid_count
            );
            pass = 1'b0;
        end

        if (
            expected_data.size() != 0 &&
            last_positions.size() == 1 &&
            last_positions[0] != expected_data.size()-1
        ) begin
            $display(
                "       o_rx_last was not aligned with the final streamed byte"
            );
            pass = 1'b0;
        end

        check_output_cadence(expected_data.size(), pass);
        check_bad_status_timing(pass);
        check_end_of_frame_timing(1'b0, pass);
        check_no_unknown_outputs(pass);

        record_result(name, pass);

    endtask


    // ========================================================================
    // TEST: GOOD FRAME HELPER
    // ========================================================================

    task automatic run_good_frame_test(
        input string   name,
        input byte_q_t data
    );

        byte_q_t wire_frame;

        append_fcs(
            data,
            wire_frame
        );

        clear_observations();

        send_wire_frame(
            wire_frame,
            7,
            8'hD5,
            -1
        );

        check_good_frame(
            name,
            data
        );

        idle_clocks(5);

    endtask


    // ========================================================================
    // TEST: GOOD FRAME WITH EXPLICIT PREAMBLE LENGTH
    // ========================================================================

    task automatic run_good_frame_preamble_test(
        input string   name,
        input byte_q_t data,
        input int      preamble_count
    );
        byte_q_t wire_frame;

        append_fcs(data, wire_frame);
        clear_observations();

        send_wire_frame(
            wire_frame,
            preamble_count,
            8'hD5,
            -1
        );

        check_good_frame(name, data);
        idle_clocks(5);
    endtask


    // ========================================================================
    // TEST: TRUNCATED FRAME/FCS
    // ========================================================================

    task automatic test_truncated_frame(
        input int    complete_wire_bytes,
        input bit    send_low_nibble_of_next,
        input string name
    );
        byte_q_t data;
        byte_q_t wire_frame;

        make_random_data(60, data);
        append_fcs(data, wire_frame);
        clear_observations();

        send_truncated_wire_frame(
            wire_frame,
            complete_wire_bytes,
            send_low_nibble_of_next
        );

        check_bad_status(name);
        idle_clocks(5);
    endtask


    // ========================================================================
    // TEST: KNOWN CRC CHECK VECTOR
    // ========================================================================

    task automatic test_known_crc_vector;

        byte_q_t data;
        logic [31:0] fcs;
        bit pass;

        string test_string;

        test_string = "123456789";

        data.delete();

        for (int i = 0; i < test_string.len(); i++)
            data.push_back(test_string[i]);

        fcs = calculate_fcs(data);

        pass = (fcs === 32'hCBF43926);

        if (!pass) begin
            $display(
                "       Got CRC = %08X, expected CBF43926",
                fcs
            );
        end

        record_result(
            "Known CRC-32 vector '123456789'",
            pass
        );

    endtask


    // ========================================================================
    // TEST: BAD FCS BYTE
    // ========================================================================

    task automatic test_bad_fcs_byte(
        input int fcs_byte
    );

        byte_q_t data;
        byte_q_t wire_frame;
        string name;

        make_random_data(
            60,
            data
        );

        append_fcs(
            data,
            wire_frame
        );

        // Corrupt selected FCS byte
        wire_frame[data.size() + fcs_byte] ^= 8'h01;

        clear_observations();

        send_wire_frame(
            wire_frame,
            7,
            8'hD5,
            -1
        );

        name = $sformatf(
            "Corrupted FCS byte %0d",
            fcs_byte
        );

        check_bad_crc_frame(
            name,
            data
        );

        idle_clocks(5);

    endtask


    // ========================================================================
    // TEST: CORRUPTED FRAME DATA
    // ========================================================================

    task automatic test_corrupted_data(
        input int corrupt_index,
        input string name
    );

        byte_q_t original_data;
        byte_q_t received_data;
        byte_q_t wire_frame;

        make_random_data(
            60,
            original_data
        );

        append_fcs(
            original_data,
            wire_frame
        );

        // Corrupt data AFTER CRC was generated
        wire_frame[corrupt_index] ^= 8'h01;

        received_data = original_data;
        received_data[corrupt_index] ^= 8'h01;

        clear_observations();

        send_wire_frame(
            wire_frame,
            7,
            8'hD5,
            -1
        );

        check_bad_crc_frame(
            name,
            received_data
        );

        idle_clocks(5);

    endtask


    // ========================================================================
    // TEST: RX_ER
    // ========================================================================

    task automatic test_rx_error(
        input int    error_nibble,
        input string name,
        input bit    expect_no_output
    );

        byte_q_t data;
        byte_q_t wire_frame;

        make_random_data(
            60,
            data
        );

        append_fcs(
            data,
            wire_frame
        );

        clear_observations();

        send_wire_frame(
            wire_frame,
            7,
            8'hD5,
            error_nibble
        );

        if (expect_no_output)
            check_bad_no_output(name);
        else
            check_bad_status(name);

        idle_clocks(5);

    endtask


    // ========================================================================
    // TEST: RX_ER AFTER RX_DV FALLS
    //
    // Should NOT invalidate the frame that just finished.
    // ========================================================================

    task automatic test_error_after_dv;

        byte_q_t data;
        byte_q_t wire_frame;

        make_random_data(
            60,
            data
        );

        append_fcs(
            data,
            wire_frame
        );

        clear_observations();

        send_wire_frame(
            wire_frame,
            7,
            8'hD5,
            -1
        );

        // Physical RX_DV is already low.
        // Assert RX_ER while DV remains low.
        drive_nibble(
            4'h0,
            1'b0,
            1'b1
        );

        drive_nibble(
            4'h0,
            1'b0,
            1'b0
        );

        check_good_frame(
            "RX_ER after RX_DV deassertion ignored",
            data
        );

        idle_clocks(5);

    endtask


    // ========================================================================
    // TEST: INCOMPLETE BYTE
    //
    // Send only the low nibble of a byte, then drop RX_DV.
    // ========================================================================

    task automatic test_incomplete_nibble;

        byte_q_t data;
        byte_q_t wire_frame;

        int nibble_index;

        make_random_data(
            60,
            data
        );

        append_fcs(
            data,
            wire_frame
        );

        clear_observations();

        nibble_index = 0;


        // Normal preamble
        repeat (7) begin
            drive_stream_byte(
                8'h55,
                -1,
                nibble_index
            );
        end


        // SFD
        drive_stream_byte(
            8'hD5,
            -1,
            nibble_index
        );


        // Send several complete frame bytes
        for (int i = 0; i < 10; i++) begin
            drive_stream_byte(
                wire_frame[i],
                -1,
                nibble_index
            );
        end


        // Send ONLY low nibble of next byte
        drive_nibble(
            wire_frame[10][3:0],
            1'b1,
            1'b0
        );


        // Drop RX_DV before high nibble arrives
        drive_nibble(
            4'h0,
            1'b0,
            1'b0
        );


        check_bad_status(
            "RX_DV drops after only one nibble"
        );

        idle_clocks(5);

    endtask


    // ========================================================================
    // TEST: BAD PREAMBLE CONTENT
    // ========================================================================

    task automatic test_bad_preamble_byte;

        byte_q_t data;
        byte_q_t wire_frame;

        int nibble_index;

        make_random_data(
            60,
            data
        );

        append_fcs(
            data,
            wire_frame
        );

        clear_observations();

        nibble_index = 0;

        drive_stream_byte(8'h55, -1, nibble_index);
        drive_stream_byte(8'h55, -1, nibble_index);
        drive_stream_byte(8'h55, -1, nibble_index);

        // Invalid byte inside preamble
        drive_stream_byte(8'h54, -1, nibble_index);

        drive_stream_byte(8'hD5, -1, nibble_index);

        foreach (wire_frame[i])
            drive_stream_byte(
                wire_frame[i],
                -1,
                nibble_index
            );

        drive_nibble(
            4'h0,
            1'b0,
            1'b0
        );

        check_bad_no_output(
            "Bad byte inside preamble"
        );

        idle_clocks(5);

    endtask


    // ========================================================================
    // TEST: BACK-TO-BACK FRAMES
    // ========================================================================

    task automatic test_back_to_back;

        byte_q_t data_a;
        byte_q_t data_b;

        byte_q_t wire_a;
        byte_q_t wire_b;

        byte_q_t expected;

        bit status_seen;
        bit pass;

        make_random_data(60, data_a);
        make_random_data(100, data_b);

        append_fcs(data_a, wire_a);
        append_fcs(data_b, wire_b);

        expected = data_a;

        foreach (data_b[i])
            expected.push_back(data_b[i]);

        clear_observations();


        send_wire_frame(
            wire_a,
            7,
            8'hD5,
            -1
        );


        // Ethernet minimum IFG is 96 bit-times.
        // MII = 4 bits / clock => 24 clocks.
        idle_clocks(24);


        send_wire_frame(
            wire_b,
            7,
            8'hD5,
            -1
        );


        wait_for_status(
            2,
            100,
            status_seen
        );

        repeat (3) @(negedge rx_clk);

        pass = 1'b1;


        if (!status_seen)
            pass = 1'b0;

        if (observed_good_count != 2)
            pass = 1'b0;

        if (observed_bad_count != 0)
            pass = 1'b0;

        if (!queues_equal(observed_data, expected))
            pass = 1'b0;

        if (observed_last_count != 2)
            pass = 1'b0;


        if (last_positions.size() == 2) begin

            if (
                last_positions[0] !=
                data_a.size() - 1
            )
                pass = 1'b0;

            if (
                last_positions[1] !=
                data_a.size() +
                data_b.size() - 1
            )
                pass = 1'b0;

        end else begin
            pass = 1'b0;
        end


        if (last_without_valid_count != 0)
            pass = 1'b0;

        check_no_unknown_outputs(pass);

        record_result(
            "Two frames separated by minimum IFG",
            pass
        );

        idle_clocks(5);

    endtask


    // ========================================================================
    // TEST: RESET DURING FRAME
    // ========================================================================

    task automatic test_reset_mid_frame;

        byte_q_t data;
        byte_q_t wire_frame;

        int nibble_index;

        make_random_data(
            60,
            data
        );

        append_fcs(
            data,
            wire_frame
        );

        clear_observations();

        nibble_index = 0;


        // Start a valid frame
        repeat (7)
            drive_stream_byte(
                8'h55,
                -1,
                nibble_index
            );

        drive_stream_byte(
            8'hD5,
            -1,
            nibble_index
        );


        // Send enough data that internal state is active
        for (int i = 0; i < 20; i++)
            drive_stream_byte(
                wire_frame[i],
                -1,
                nibble_index
            );


        // Reset in the middle of the frame
        @(negedge rx_clk);

        n_reset   = 1'b0;
        mii_rx_dv = 1'b0;
        mii_rx_er = 1'b0;
        mii_rxd   = 4'h0;


        repeat (4)
            @(negedge rx_clk);


        n_reset = 1'b1;


        idle_clocks(4);

        // Ignore anything associated with abandoned frame
        clear_observations();


        // Receiver should now recover normally
        send_wire_frame(
            wire_frame,
            7,
            8'hD5,
            -1
        );


        check_good_frame(
            "Recovery after reset during frame",
            data
        );

        idle_clocks(5);

    endtask


    // ========================================================================
    // INITIAL RESET OUTPUT TEST
    // ========================================================================

    task automatic test_reset_outputs;

        bit pass;

        pass = 1'b1;

        repeat (3) begin

            @(posedge rx_clk);
            #1;

            if (rx_valid !== 1'b0)
                pass = 1'b0;

            if (rx_last !== 1'b0)
                pass = 1'b0;

            if (frame_good !== 1'b0)
                pass = 1'b0;

            if (frame_bad !== 1'b0)
                pass = 1'b0;

        end


        record_result(
            "Outputs inactive during reset",
            pass
        );

    endtask


    // ========================================================================
    // MAIN REGRESSION
    // ========================================================================

    initial begin

        byte_q_t data;
        byte_q_t wire_frame;

        int random_length;
        int unsigned random_seed;
        int unsigned seed_discard;

        tests_run    = 0;
        tests_failed = 0;

        cycle_count    = 0;
        prev_mii_rx_dv = 1'b0;
        clear_observations();

        random_seed = RANDOM_SEED;
        seed_discard = $urandom(random_seed);
        $display("Random seed  : 0x%08X", RANDOM_SEED);

        n_reset   = 1'b0;
        mii_rxd   = 4'h0;
        mii_rx_dv = 1'b0;
        mii_rx_er = 1'b0;


        // ================================================================
        // RESET
        // ================================================================

        test_reset_outputs();


        repeat (2)
            @(negedge rx_clk);

        n_reset = 1'b1;

        idle_clocks(5);


        // ================================================================
        // REFERENCE CRC SANITY CHECK
        // ================================================================

        test_known_crc_vector();


        // ================================================================
        // GOOD FRAME BOUNDARIES
        // ================================================================

        make_random_data(60, data);
        run_good_frame_test(
            "Minimum legal Ethernet frame: 60 bytes before FCS",
            data
        );


        make_random_data(61, data);
        run_good_frame_test(
            "61-byte frame",
            data
        );


        make_random_data(64, data);
        run_good_frame_test(
            "64-byte frame",
            data
        );


        make_random_data(1514, data);
        run_good_frame_test(
            "Maximum normal frame: 1514 bytes before FCS",
            data
        );


        // ================================================================
        // DETERMINISTIC DATA PATTERNS
        // ================================================================

        make_constant_data(60, 8'h00, data);
        run_good_frame_test("Deterministic payload: all 00", data);

        make_constant_data(60, 8'hFF, data);
        run_good_frame_test("Deterministic payload: all FF", data);

        make_alternating_data(60, 8'h55, 8'hAA, data);
        run_good_frame_test("Deterministic payload: alternating 55/AA", data);

        make_incrementing_data(256, data);
        run_good_frame_test("Deterministic payload: incrementing 00..FF", data);

        make_constant_data(60, 8'hD5, data);
        run_good_frame_test("Deterministic payload: repeated D5", data);


        // ================================================================
        // SHORTENED PREAMBLE ACCEPTANCE
        //
        // This regression is configured to accept any shortened preamble
        // down to MIN_ACCEPTED_PREAMBLE_BYTES complete 0x55 bytes.
        // ================================================================

        make_incrementing_data(60, data);

        for (int preamble_bytes = MIN_ACCEPTED_PREAMBLE_BYTES;
             preamble_bytes <= 6;
             preamble_bytes++) begin
            run_good_frame_preamble_test(
                $sformatf(
                    "Short preamble accepted: %0d byte(s) of 55",
                    preamble_bytes
                ),
                data,
                preamble_bytes
            );
        end


        // ================================================================
        // RANDOM GOOD FRAMES
        // ================================================================

        for (int test_num = 0;
             test_num < RANDOM_TESTS;
             test_num++) begin

            random_length =
                $urandom_range(1514, 60);

            make_random_data(
                random_length,
                data
            );

            run_good_frame_test(
                $sformatf(
                    "Random good frame %0d, length=%0d",
                    test_num,
                    random_length
                ),
                data
            );

        end


        // ================================================================
        // BAD FCS
        // ================================================================

        for (int i = 0; i < 4; i++)
            test_bad_fcs_byte(i);


        // ================================================================
        // DATA CORRUPTION
        //
        // Generate FCS first, then corrupt received data.
        // ================================================================

        test_corrupted_data(
            0,
            "Corruption in first frame byte"
        );

        test_corrupted_data(
            30,
            "Corruption in middle frame byte"
        );

        test_corrupted_data(
            59,
            "Corruption in final frame byte"
        );


        make_random_data(60, data);
        append_fcs(data, wire_frame);

        clear_observations();

        send_wire_frame(
            wire_frame,
            7,
            8'hD4,      // incorrect SFD
            -1
        );

        check_bad_no_output(
            "Incorrect SFD"
        );

        idle_clocks(5);


        test_bad_preamble_byte();


        // ================================================================
        // RX_ER TESTS
        //
        // Stream nibble numbering:
        //
        // 0-13   = preamble
        // 14-15  = SFD
        // 16...  = frame bytes
        //
        // For 60 bytes + 4 FCS:
        //
        // total bytes =
        // 7 preamble + 1 SFD + 64 frame/FCS
        // = 72 bytes = 144 nibbles
        //
        // final nibble index = 143
        // ================================================================

        test_rx_error(
            0,
            "RX_ER on first preamble nibble",
            1'b1
        );

        test_rx_error(
            15,
            "RX_ER on final SFD nibble",
            1'b1
        );

        test_rx_error(
            16,
            "RX_ER on first frame-data nibble",
            1'b0
        );

        test_rx_error(
            16 + (30 * 2),
            "RX_ER in middle of frame",
            1'b0
        );

        test_rx_error(
            16 + (59 * 2) + 1,
            "RX_ER on final data-byte high nibble",
            1'b0
        );

        test_rx_error(
            16 + (60 * 2),
            "RX_ER on first FCS nibble",
            1'b0
        );

        test_rx_error(
            143,
            "RX_ER on final FCS nibble",
            1'b0
        );


        // RX_ER after DV falls must not affect previous frame
        test_error_after_dv();


        // ================================================================
        // INCOMPLETE BYTE
        // ================================================================

        test_incomplete_nibble();


        // ================================================================
        // BYTE-BOUNDARY / FCS TRUNCATION
        //
        // For the 60-byte data frame used by test_truncated_frame():
        // wire bytes 0..59 = frame data, 60..63 = FCS0..FCS3.
        // ================================================================

        test_truncated_frame(
            0,
            1'b0,
            "RX_DV drops immediately after SFD"
        );

        test_truncated_frame(
            1,
            1'b0,
            "RX_DV drops after first frame byte"
        );

        test_truncated_frame(
            59,
            1'b0,
            "RX_DV drops after 59 frame bytes"
        );

        test_truncated_frame(
            60,
            1'b0,
            "RX_DV drops after final data byte before FCS"
        );

        test_truncated_frame(
            61,
            1'b0,
            "RX_DV drops after FCS byte 0"
        );

        test_truncated_frame(
            62,
            1'b0,
            "RX_DV drops after FCS byte 1"
        );

        test_truncated_frame(
            63,
            1'b0,
            "RX_DV drops after FCS byte 2"
        );

        test_truncated_frame(
            63,
            1'b1,
            "RX_DV drops after low nibble of final FCS byte"
        );


        // ================================================================
        // LENGTH ERRORS
        //
        // These require your MAC to actually implement length validation.
        // Current RTL will probably fail these.
        // ================================================================

        make_random_data(
            59,
            data
        );

        append_fcs(
            data,
            wire_frame
        );

        clear_observations();

        send_wire_frame(
            wire_frame,
            7,
            8'hD5,
            -1
        );

        check_bad_status(
            "Runt frame: 59 bytes before FCS"
        );

        idle_clocks(5);


        make_random_data(
            1515,
            data
        );

        append_fcs(
            data,
            wire_frame
        );

        clear_observations();

        send_wire_frame(
            wire_frame,
            7,
            8'hD5,
            -1
        );

        check_bad_status(
            "Oversized frame: 1515 bytes before FCS"
        );

        idle_clocks(5);


        // ================================================================
        // MULTIPLE FRAMES / STATE CLEANUP
        // ================================================================

        test_back_to_back();


        // ================================================================
        // RESET RECOVERY
        // ================================================================

        test_reset_mid_frame();


        // ================================================================
        // FINAL RESULT
        // ================================================================

        $display("");
        $display("==================================================");
        $display("                TEST SUMMARY");
        $display("==================================================");
        $display("Tests run    : %0d", tests_run);
        $display("Tests passed : %0d", tests_run - tests_failed);
        $display("Tests failed : %0d", tests_failed);
        $display("Random seed  : 0x%08X", RANDOM_SEED);
        $display("==================================================");


        if (tests_failed == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $fatal(
                1,
                "%0d TEST(S) FAILED",
                tests_failed
            );
        end


        $finish;

    end

endmodule