/*
 * Copyright (c) 2024 Libor Miller
 * SPDX-License-Identifier: Apache-2.0
 *
 * SIMON 32/64 block cipher with SPI slave interface
 *
 * SPI Mode 3 (CPOL=1, CPHA=1), MSB first
 *
 * Pin mapping:
 *   uio[0] = SPI CS_n  (chip select, active low)  [input]
 *   uio[1] = SPI MOSI  (master out, slave in)     [input]
 *   uio[2] = SPI MISO  (master in, slave out)     [output]
 *   uio[3] = SPI SCK   (clock from master)        [input]
 *
 * SPI command protocol (first byte of each CS frame):
 *   0x01 = Write Key     (+ 8 data bytes, LSB first)
 *   0x02 = Write Block   (+ 4 data bytes, LSB first)
 *   0x03 = Encrypt       (no data bytes; starts encryption)
 *   0x04 = Decrypt       (no data bytes; starts decryption)
 *   0x05 = Read Status   (+ 1 dummy byte; returns {7'b0, done} on MISO)
 *   0x06 = Read Result   (+ 4 dummy bytes; returns result on MISO, LSB first)
 *
 * Note: SPI SCK frequency must be at most CLK/8 for reliable operation.
 */

`default_nettype none

module tt_um_libormiller_SIMON_SPI (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // Internal Power-On Reset (gated by external rst_n so GL sim works)
    reg [7:0] por_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) por_sr <= 8'h00;
        else        por_sr <= {por_sr[6:0], 1'b1};
    end
    wire internal_rst_n = por_sr[7] & rst_n;

    // Pin Mapping (directly active outputs)
    assign uo_out  = 8'b0;             // dedicated outputs unused
    assign uio_oe  = 8'b0000_0100;     // uio[2]=MISO is output, rest inputs

    wire spi_cs_n  = uio_in[0];
    wire spi_mosi  = uio_in[1];
    wire spi_miso;
    wire spi_sck   = uio_in[3];
    assign uio_out = {5'b0, spi_cs_n ? 1'b0 : spi_miso, 2'b0};


    // SPI Slave Instance (Mode 3: CPOL=1, CPHA=1)
    wire       spi_done;
    wire [7:0] spi_rdata;
    reg  [7:0] spi_tdata;

    spi_slave spi_inst (
        .clk   (clk),
        .rstb  (internal_rst_n),
        .ten   (1'b1),
        .tdata (spi_tdata),
        .mlb   (1'b1),          // MSB first
        .ss    (spi_cs_n),
        .sck   (spi_sck),
        .sdin  (spi_mosi),
        .sdout (spi_miso),
        .done  (spi_done),
        .rdata (spi_rdata)
    );

    // Synchronize CS_n (active-high after sync = CS deasserted)
    reg [3:0] cs_sync;
    always @(posedge clk or negedge internal_rst_n) begin
        if (!internal_rst_n) cs_sync <= 4'b1111;
        else                 cs_sync <= {cs_sync[2:0], spi_cs_n};
    end
    
    reg cs_debounced;
    always @(posedge clk or negedge internal_rst_n) begin
        if (!internal_rst_n) cs_debounced <= 1'b1;
        else begin
            if (cs_sync[3:1] == 3'b000) cs_debounced <= 1'b0;
            else if (cs_sync[3:1] == 3'b111) cs_debounced <= 1'b1;
        end
    end
    wire cs_synced = cs_debounced;
    wire done_pulse = spi_done;

    // Data Registers
    reg [63:0] key_reg;
    reg [31:0] block_reg;
    reg [31:0] result_reg;
    reg        done_status;

    // SPI Transaction Tracking
    reg [3:0]  byte_cnt;
    reg [7:0]  cmd_reg;

    // SIMON Cipher Instance
    reg        cipher_mode;      // 0 = Encrypt, 1 = Decrypt
    reg        cipher_rst_cmd;   // one-cycle pulse to start cipher
    reg        startup;          // one-cycle pulse after system reset
    wire       cipher_rst = cipher_rst_cmd | startup;
    wire       cipher_done;
    wire [31:0] cipher_out;

    simon_rounds simon_inst (
        .clk        (clk),
        .rst        (cipher_rst),
        .mode       (cipher_mode),
        .block      (block_reg),
        .key        (key_reg),
        .ciphertext (cipher_out),
        .done       (cipher_done)
    );

    // Command Constants
    localparam CMD_WRITE_KEY   = 8'h01,
               CMD_WRITE_BLOCK = 8'h02,
               CMD_ENCRYPT     = 8'h03,
               CMD_DECRYPT     = 8'h04,
               CMD_READ_STATUS = 8'h05,
               CMD_READ_RESULT = 8'h06;

    // Main Control FSM (system clock domain)
    always @(posedge clk or negedge internal_rst_n) begin
        if (!internal_rst_n) begin
            byte_cnt       <= 4'd0;
            cmd_reg        <= 8'h00;
            key_reg        <= 64'b0;
            block_reg      <= 32'b0;
            result_reg     <= 32'b0;
            done_status    <= 1'b0;
            cipher_mode    <= 1'b0;
            cipher_rst_cmd <= 1'b0;
            startup        <= 1'b1;
            spi_tdata      <= 8'h00;
        end else begin
            // ------- Startup: pulse cipher reset once after power-on -------
            if (startup) startup <= 1'b0;

            // ------- Deassert cipher_rst_cmd after one cycle -------
            if (cipher_rst_cmd) cipher_rst_cmd <= 1'b0;

            // ------- Capture cipher result when computation finishes -------
            if (cipher_done && !done_status && !cipher_rst) begin
                result_reg  <= cipher_out;
                done_status <= 1'b1;
            end

            // ------- CS_n high -> reset byte counter -------
            if (cs_synced) begin
                byte_cnt <= 4'd0;
            end

            // ------- Process each received SPI byte -------
            if (done_pulse) begin
                if (byte_cnt == 4'd0) begin
                    // ---- Command byte (byte 0) ----
                    cmd_reg  <= spi_rdata;
                    byte_cnt <= 4'd1;

                    case (spi_rdata)
                        CMD_ENCRYPT: begin
                            cipher_mode    <= 1'b0;
                            cipher_rst_cmd <= 1'b1;
                            done_status    <= 1'b0;
                        end
                        CMD_DECRYPT: begin
                            cipher_mode    <= 1'b1;
                            cipher_rst_cmd <= 1'b1;
                            done_status    <= 1'b0;
                        end
                        CMD_READ_STATUS: spi_tdata <= {7'b0, done_status};
                        CMD_READ_RESULT: spi_tdata <= result_reg[7:0];
                        default:         spi_tdata <= 8'h00;
                    endcase
                end else begin
                    // ---- Data bytes (byte 1+) ----
                    byte_cnt <= byte_cnt + 4'd1;

                    case (cmd_reg)
                        CMD_WRITE_KEY: begin
                            case (byte_cnt)
                                4'd1: key_reg[ 7: 0] <= spi_rdata;
                                4'd2: key_reg[15: 8] <= spi_rdata;
                                4'd3: key_reg[23:16] <= spi_rdata;
                                4'd4: key_reg[31:24] <= spi_rdata;
                                4'd5: key_reg[39:32] <= spi_rdata;
                                4'd6: key_reg[47:40] <= spi_rdata;
                                4'd7: key_reg[55:48] <= spi_rdata;
                                4'd8: key_reg[63:56] <= spi_rdata;
                                default: ;
                            endcase
                        end

                        CMD_WRITE_BLOCK: begin
                            case (byte_cnt)
                                4'd1: block_reg[ 7: 0] <= spi_rdata;
                                4'd2: block_reg[15: 8] <= spi_rdata;
                                4'd3: block_reg[23:16] <= spi_rdata;
                                4'd4: block_reg[31:24] <= spi_rdata;
                                default: ;
                            endcase
                        end

                        CMD_READ_RESULT: begin
                            case (byte_cnt)
                                4'd1: spi_tdata <= result_reg[15: 8];
                                4'd2: spi_tdata <= result_reg[23:16];
                                4'd3: spi_tdata <= result_reg[31:24];
                                default: spi_tdata <= 8'h00;
                            endcase
                        end

                        default: ;
                    endcase
                end
            end
        end
    end

    // Suppress unused-input warnings
    wire _unused = &{ena, ui_in[7:3], uio_in, 1'b0};

endmodule