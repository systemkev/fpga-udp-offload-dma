module buffer_manager #(
    parameter logic [31:0] BUFFER0_BASE = 32'h8000_0000,
    parameter logic [31:0] BUFFER1_BASE = 32'h8000_1000
) (
    input  logic        i_clk,
    input  logic        i_n_reset,
    input  logic        i_enable,
    input  logic        i_auto_echo,

    // RX metadata as plain signals.  This deliberately avoids introducing a
    // project-wide package typedef just for the echo scheduler.
    input  logic [47:0] i_rx_remote_mac,
    input  logic [31:0] i_rx_remote_ip,
    input  logic [15:0] i_rx_remote_port,
    input  logic [15:0] i_rx_payload_length,
    input  logic        i_rx_meta_valid,
    output logic        o_rx_meta_ready,

    output logic        o_s2mm_start,
    output logic [31:0] o_s2mm_base_addr,
    input  logic        i_s2mm_busy,
    input  logic        i_s2mm_done,
    input  logic        i_s2mm_error,
    input  logic [15:0] i_s2mm_actual_length,

    output logic        o_mm2s_start,
    output logic [31:0] o_mm2s_base_addr,
    output logic [15:0] o_mm2s_byte_length,
    input  logic        i_mm2s_busy,
    input  logic        i_mm2s_done,
    input  logic        i_mm2s_error,

    // TX metadata, also as plain signals.
    output logic [47:0] o_tx_remote_mac,
    output logic [31:0] o_tx_remote_ip,
    output logic [15:0] o_tx_remote_port,
    output logic [15:0] o_tx_payload_length,
    output logic        o_tx_meta_valid,
    input  logic        i_tx_meta_ready,

    output logic        o_rx_no_buffer_drop
);
    typedef enum logic [1:0] {
        B_FREE,
        B_RX_FILL,
        B_FULL,
        B_TX_READ
    } t_buf_state;

    typedef struct packed {
        logic [47:0] remote_mac;
        logic [31:0] remote_ip;
        logic [15:0] remote_port;
        logic [15:0] payload_length;
    } t_slot_meta;

    t_buf_state state0, state1;
    t_slot_meta meta0, meta1;
    logic [15:0] len0, len1;

    logic rx_active, rx_sel;
    logic tx_active, tx_sel;

    logic offer_sel, offer_valid;
    t_slot_meta offer_meta;

    logic free_exists, free_sel;
    logic full_exists, full_sel;

    always_comb begin
        free_exists = 1'b0;
        free_sel    = 1'b0;
        if (state0 == B_FREE) begin
            free_exists = 1'b1;
            free_sel    = 1'b0;
        end else if (state1 == B_FREE) begin
            free_exists = 1'b1;
            free_sel    = 1'b1;
        end

        full_exists = 1'b0;
        full_sel    = 1'b0;
        if (state0 == B_FULL) begin
            full_exists = 1'b1;
            full_sel    = 1'b0;
        end else if (state1 == B_FULL) begin
            full_exists = 1'b1;
            full_sel    = 1'b1;
        end

        o_rx_meta_ready = i_enable && !rx_active && !i_s2mm_busy && free_exists;

        o_tx_remote_mac     = offer_meta.remote_mac;
        o_tx_remote_ip      = offer_meta.remote_ip;
        o_tx_remote_port    = offer_meta.remote_port;
        o_tx_payload_length = offer_meta.payload_length;
        o_tx_meta_valid     = offer_valid;

        o_rx_no_buffer_drop = i_rx_meta_valid && i_enable && !free_exists;
    end

    always_ff @(posedge i_clk or negedge i_n_reset) begin
        if (!i_n_reset) begin
            state0               <= B_FREE;
            state1               <= B_FREE;
            meta0                <= '0;
            meta1                <= '0;
            len0                 <= '0;
            len1                 <= '0;
            rx_active            <= 1'b0;
            rx_sel               <= 1'b0;
            tx_active            <= 1'b0;
            tx_sel               <= 1'b0;
            offer_sel            <= 1'b0;
            offer_valid          <= 1'b0;
            offer_meta           <= '0;
            o_s2mm_start         <= 1'b0;
            o_s2mm_base_addr     <= BUFFER0_BASE;
            o_mm2s_start         <= 1'b0;
            o_mm2s_base_addr     <= BUFFER0_BASE;
            o_mm2s_byte_length   <= '0;
        end else begin
            // One-cycle command pulses.
            o_s2mm_start <= 1'b0;
            o_mm2s_start <= 1'b0;

            // Allocate a FREE DDR buffer when UDP metadata is accepted.
            if (i_rx_meta_valid && o_rx_meta_ready) begin
                rx_sel <= free_sel;

                if (!free_sel) begin
                    meta0.remote_mac     <= i_rx_remote_mac;
                    meta0.remote_ip      <= i_rx_remote_ip;
                    meta0.remote_port    <= i_rx_remote_port;
                    meta0.payload_length <= i_rx_payload_length;
                    len0                 <= i_rx_payload_length;
                    state0               <= (i_rx_payload_length == 16'd0)
                                            ? B_FULL : B_RX_FILL;
                end else begin
                    meta1.remote_mac     <= i_rx_remote_mac;
                    meta1.remote_ip      <= i_rx_remote_ip;
                    meta1.remote_port    <= i_rx_remote_port;
                    meta1.payload_length <= i_rx_payload_length;
                    len1                 <= i_rx_payload_length;
                    state1               <= (i_rx_payload_length == 16'd0)
                                            ? B_FULL : B_RX_FILL;
                end

                if (i_rx_payload_length != 16'd0) begin
                    // Register address before pulsing start.  axis_s2mm samples
                    // both on the next rising edge, so buffer 1 cannot inherit a
                    // stale buffer-0 address.
                    o_s2mm_base_addr <= free_sel ? BUFFER1_BASE : BUFFER0_BASE;
                    o_s2mm_start     <= 1'b1;
                    rx_active        <= 1'b1;
                end
            end

            // S2MM completion owns the actual byte count.
            if (rx_active && (i_s2mm_done || i_s2mm_error)) begin
                rx_active <= 1'b0;

                if (!rx_sel) begin
                    if (i_s2mm_error) begin
                        state0 <= B_FREE;
                    end else begin
                        len0                 <= i_s2mm_actual_length;
                        meta0.payload_length <= i_s2mm_actual_length;
                        state0               <= B_FULL;
                    end
                end else begin
                    if (i_s2mm_error) begin
                        state1 <= B_FREE;
                    end else begin
                        len1                 <= i_s2mm_actual_length;
                        meta1.payload_length <= i_s2mm_actual_length;
                        state1               <= B_FULL;
                    end
                end
            end

            // Latch one FULL buffer's metadata and hold it stable until the
            // packetizer accepts it.
            if (!offer_valid && !tx_active && !i_mm2s_busy &&
                i_auto_echo && full_exists) begin
                offer_sel   <= full_sel;
                offer_valid <= 1'b1;
                offer_meta  <= full_sel ? meta1 : meta0;
            end

            if (offer_valid && i_tx_meta_ready) begin
                offer_valid <= 1'b0;
                tx_sel      <= offer_sel;

                if (offer_meta.payload_length == 16'd0) begin
                    // Header-only UDP datagram: no DDR read is needed.
                    if (!offer_sel) state0 <= B_FREE;
                    else            state1 <= B_FREE;
                end else begin
                    // Register the selected buffer command before MM2S sees the
                    // start pulse on its next clock edge.
                    o_mm2s_base_addr   <= offer_sel ? BUFFER1_BASE : BUFFER0_BASE;
                    o_mm2s_byte_length <= offer_sel ? len1 : len0;
                    o_mm2s_start       <= 1'b1;
                    tx_active          <= 1'b1;

                    if (!offer_sel) state0 <= B_TX_READ;
                    else            state1 <= B_TX_READ;
                end
            end

            // mm2s_done is intentionally tied to acceptance of the final AXIS
            // beat by the TX packetizer, so freeing here is safe.
            if (tx_active && (i_mm2s_done || i_mm2s_error)) begin
                tx_active <= 1'b0;
                if (!tx_sel) state0 <= B_FREE;
                else         state1 <= B_FREE;
            end
        end
    end
endmodule
