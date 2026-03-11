/*
 * Hardware Test for SIMON 32/64 FPGA — ESP32 DEVKIT V1
 *
 * ESP32 acts as SPI master, FPGA as SPI slave.
 *
 * Wiring:
 *   ESP32 D23 (GPIO23) -> MOSI  -> FPGA ui_in[1]
 *   ESP32 D22 (GPIO22) -> SCK   -> FPGA ui_in[0]
 *   ESP32 D19 (GPIO19) <- MISO  <- FPGA uo_out[0]
 *   ESP32 D5  (GPIO5)  -> CS_n  -> FPGA ui_in[2]
 *   ESP32 D4  (GPIO4)  -> RST_n -> FPGA rst_n
 *
 * SPI Mode 3 (CPOL=1, CPHA=1), MSB first
 * SPI clock ≤ FPGA_CLK / 8 for reliable operation.
 *
 * Serial console (115200 baud) provides interactive test menu.
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2024 Libor Miller
 */

#include <SPI.h>

// ── Pin definitions ─────────────────────────────────────────────────────────
#define PIN_MOSI  23
#define PIN_SCK   22
#define PIN_MISO  19
#define PIN_CS    5
#define PIN_RST   4    // FPGA rst_n (active low)

// ── SPI settings ────────────────────────────────────────────────────────────
// SPI Mode 3 = CPOL=1, CPHA=1.  1 MHz should be safe for most FPGA clocks.
// Increased to 5 MHz for faster testing (assuming FPGA clock is >= 40 MHz)
#define SPI_SPEED  5000000
SPISettings spiSettings(SPI_SPEED, MSBFIRST, SPI_MODE3);

// ── SPI command opcodes (must match project_top.v) ──────────────────────────
#define CMD_WRITE_KEY    0x01
#define CMD_WRITE_BLOCK  0x02
#define CMD_ENCRYPT      0x03
#define CMD_DECRYPT      0x04
#define CMD_READ_STATUS  0x05
#define CMD_READ_RESULT  0x06

// ── SIMON 32/64 test vector (from the specification) ────────────────────────
static const uint64_t KEY_TV    = 0x1918111009080100ULL;
static const uint32_t PLAIN_TV  = 0x65656877UL;
static const uint32_t CIPHER_TV = 0xC69BE9BBUL;

// ═══════════════════════════════════════════════════════════════════════════
// Low-level SPI helpers
// ═══════════════════════════════════════════════════════════════════════════

static void spi_cs_low() {
    digitalWrite(PIN_CS, LOW);
    delayMicroseconds(1);
}

static void spi_cs_high() {
    delayMicroseconds(1);
    digitalWrite(PIN_CS, HIGH);
    delayMicroseconds(1);  // inter-frame gap
}

/**
 * Pulse FPGA rst_n: LOW for 10 ms, then HIGH.
 * Waits 50 ms after release for startup initialisation.
 */
static void fpga_reset() {
    Serial.println("  Resetting FPGA (rst_n pulse)...");
    digitalWrite(PIN_CS, HIGH);   // make sure SPI is idle during reset
    digitalWrite(PIN_RST, LOW);
    delay(10);
    digitalWrite(PIN_RST, HIGH);
    delay(50);  // let startup cipher_rst finish
    Serial.println("  FPGA reset done.");
}

// ═══════════════════════════════════════════════════════════════════════════
// High-level SPI command wrappers
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Write 64-bit key, LSB first (CMD 0x01).
 */
static void fpga_write_key(uint64_t key) {
    SPI.beginTransaction(spiSettings);
    spi_cs_low();
    SPI.transfer(CMD_WRITE_KEY);
    for (int i = 0; i < 8; i++) {
        SPI.transfer((uint8_t)(key >> (i * 8)));
    }
    spi_cs_high();
    SPI.endTransaction();
}

/**
 * Write 32-bit block, LSB first (CMD 0x02).
 */
static void fpga_write_block(uint32_t block) {
    SPI.beginTransaction(spiSettings);
    spi_cs_low();
    SPI.transfer(CMD_WRITE_BLOCK);
    for (int i = 0; i < 4; i++) {
        SPI.transfer((uint8_t)(block >> (i * 8)));
    }
    spi_cs_high();
    SPI.endTransaction();
}

/**
 * Start encryption (CMD 0x03).
 */
static void fpga_encrypt() {
    SPI.beginTransaction(spiSettings);
    spi_cs_low();
    SPI.transfer(CMD_ENCRYPT);
    spi_cs_high();
    SPI.endTransaction();
}

/**
 * Start decryption (CMD 0x04).
 */
static void fpga_decrypt() {
    SPI.beginTransaction(spiSettings);
    spi_cs_low();
    SPI.transfer(CMD_DECRYPT);
    spi_cs_high();
    SPI.endTransaction();
}

/**
 * Read status register (CMD 0x05).
 * Returns 1 when cipher computation is done, 0 otherwise.
 */
static uint8_t fpga_read_status() {
    SPI.beginTransaction(spiSettings);
    spi_cs_low();
    SPI.transfer(CMD_READ_STATUS);
    uint8_t status = SPI.transfer(0x00);  // dummy byte → MISO carries status
    spi_cs_high();
    SPI.endTransaction();
    return status & 0x01;
}

/**
 * Read 32-bit result, LSB first (CMD 0x06).
 */
static uint32_t fpga_read_result() {
    SPI.beginTransaction(spiSettings);
    spi_cs_low();
    SPI.transfer(CMD_READ_RESULT);
    uint32_t result = 0;
    for (int i = 0; i < 4; i++) {
        result |= (uint32_t)SPI.transfer(0x00) << (i * 8);
    }
    spi_cs_high();
    SPI.endTransaction();
    return result;
}

/**
 * Poll status until done or timeout.
 * Returns true on success, false on timeout.
 */
static bool fpga_wait_done(uint32_t timeout_us = 1000000) {
    uint32_t start = micros();
    while ((micros() - start) < timeout_us) {
        if (fpga_read_status()) return true;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
// SIMON 32/64 software reference model
// ═══════════════════════════════════════════════════════════════════════════

static uint16_t rotl16(uint16_t x, int k) {
    return (x << k) | (x >> (16 - k));
}

static uint16_t rotr16(uint16_t x, int k) {
    return (x >> k) | (x << (16 - k));
}

/**
 * SIMON 32/64 encrypt (gold reference).
 * key_int is 64-bit key, plaintext_int is 32-bit plaintext.
 * Returns 32-bit ciphertext.
 */
static uint32_t simon_32_64_encrypt(uint32_t plaintext_int, uint64_t key_int) {
    uint16_t key[4];
    for (int i = 0; i < 4; i++) {
        key[i] = (uint16_t)(key_int >> (i * 16));
    }

    uint16_t L = (uint16_t)(plaintext_int >> 16);
    uint16_t R = (uint16_t)(plaintext_int & 0xFFFF);

    // z0 sequence for SIMON 32/64 (62 bits, indices 0..61)
    // Binary: 11111010001001010110000111001101111101000100101011000011100110
    const uint64_t z0 = 0x3E8958737D12B0E6ULL;

    for (int i = 0; i < 32; i++) {
        uint16_t curr_k = key[0];
        uint16_t f_val  = (rotl16(L, 1) & rotl16(L, 8)) ^ rotl16(L, 2);
        uint16_t new_L  = R ^ f_val ^ curr_k;
        R = L;
        L = new_L;

        uint16_t c     = 0xFFFC;
        // z0 bit i: extract from the 62-bit z0 sequence
        uint8_t z_bit = (uint8_t)((z0 >> (61 - i)) & 1);
        uint16_t tmp      = rotr16(key[3], 3) ^ key[1];
        uint16_t tmp_ror1 = rotr16(tmp, 1);
        uint16_t k_new    = c ^ z_bit ^ key[0] ^ tmp ^ tmp_ror1;

        key[0] = key[1];
        key[1] = key[2];
        key[2] = key[3];
        key[3] = k_new;
    }

    return ((uint32_t)L << 16) | R;
}

// ═══════════════════════════════════════════════════════════════════════════
// Test routines
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Test 1: Encrypt known test vector, compare to expected ciphertext.
 */
static bool test_encrypt() {
    Serial.println("══════════════════════════════════════");
    Serial.println("  TEST 1: Encrypt test vector");
    Serial.println("══════════════════════════════════════");
    Serial.printf("  Key:       0x%016llX\n", KEY_TV);
    Serial.printf("  Plaintext: 0x%08lX\n",   PLAIN_TV);
    Serial.printf("  Expected:  0x%08lX\n",   CIPHER_TV);

    unsigned long t_start = micros();

    fpga_write_key(KEY_TV);
    fpga_write_block(PLAIN_TV);
    fpga_encrypt();

    if (!fpga_wait_done()) {
        Serial.println("  FAIL — timeout waiting for done");
        return false;
    }

    uint32_t ct = fpga_read_result();
    unsigned long t_elapsed = micros() - t_start;

    Serial.printf("  Result:    0x%08lX\n", ct);
    Serial.printf("  Time:      %lu us\n", t_elapsed);

    if (ct == CIPHER_TV) {
        Serial.println("  >> PASS <<");
        return true;
    } else {
        Serial.printf("  >> FAIL << (expected 0x%08lX, got 0x%08lX)\n", CIPHER_TV, ct);
        return false;
    }
}

/**
 * Test 2: Decrypt known ciphertext, compare to expected plaintext.
 */
static bool test_decrypt() {
    Serial.println("══════════════════════════════════════");
    Serial.println("  TEST 2: Decrypt test vector");
    Serial.println("══════════════════════════════════════");
    Serial.printf("  Key:        0x%016llX\n", KEY_TV);
    Serial.printf("  Ciphertext: 0x%08lX\n",   CIPHER_TV);
    Serial.printf("  Expected:   0x%08lX\n",   PLAIN_TV);

    unsigned long t_start = micros();

    fpga_write_key(KEY_TV);
    fpga_write_block(CIPHER_TV);
    fpga_decrypt();

    if (!fpga_wait_done()) {
        Serial.println("  FAIL — timeout waiting for done");
        return false;
    }

    uint32_t pt = fpga_read_result();
    unsigned long t_elapsed = micros() - t_start;

    Serial.printf("  Result:     0x%08lX\n", pt);
    Serial.printf("  Time:       %lu us\n", t_elapsed);

    if (pt == PLAIN_TV) {
        Serial.println("  >> PASS <<");
        return true;
    } else {
        Serial.printf("  >> FAIL << (expected 0x%08lX, got 0x%08lX)\n", PLAIN_TV, pt);
        return false;
    }
}

/**
 * Test 3: Random encrypt/decrypt round-trip.
 * Generates random plaintext, encrypts on FPGA, verifies against software
 * reference model, then decrypts and checks recovery.
 */
static bool test_random_roundtrip(uint32_t iterations) {
    Serial.println("══════════════════════════════════════");
    Serial.printf("  TEST 3: Random round-trip (%lu iterations)\n", iterations);
    Serial.println("══════════════════════════════════════");

    uint32_t pass_count = 0;
    uint32_t fail_count = 0;
    unsigned long t_total = 0;

    for (uint32_t i = 0; i < iterations; i++) {
        // Generate random 64-bit key and 32-bit plaintext
        uint64_t key = ((uint64_t)esp_random() << 32) | esp_random();
        uint32_t plaintext = esp_random();

        // Software reference encryption
        uint32_t expected_ct = simon_32_64_encrypt(plaintext, key);

        Serial.printf("  [%lu] key=0x%016llX  pt=0x%08lX  ref_ct=0x%08lX\n",
                       i, key, plaintext, expected_ct);

        unsigned long t_iter = micros();

        // ── Encrypt on FPGA ──
        fpga_write_key(key);
        fpga_write_block(plaintext);
        fpga_encrypt();

        if (!fpga_wait_done()) {
            Serial.printf("  [%lu] FAIL — encrypt timeout\n", i);
            fail_count++;
            continue;
        }

        uint32_t hw_ct = fpga_read_result();

        if (hw_ct != expected_ct) {
            Serial.printf("  [%lu] FAIL encrypt — got 0x%08lX, expected 0x%08lX\n",
                           i, hw_ct, expected_ct);
            fail_count++;
            continue;
        }

        // ── Decrypt on FPGA ──
        fpga_write_key(key);
        fpga_write_block(hw_ct);
        fpga_decrypt();

        if (!fpga_wait_done()) {
            Serial.printf("  [%lu] FAIL — decrypt timeout\n", i);
            fail_count++;
            continue;
        }

        uint32_t hw_pt = fpga_read_result();
        unsigned long t_iter_elapsed = micros() - t_iter;
        t_total += t_iter_elapsed;

        if (hw_pt != plaintext) {
            Serial.printf("  [%lu] FAIL decrypt — got 0x%08lX, expected 0x%08lX\n",
                           i, hw_pt, plaintext);
            fail_count++;
            continue;
        }

        Serial.printf("  [%lu] PASS  ct=0x%08lX  pt=0x%08lX  (%lu us)\n",
                       i, hw_ct, hw_pt, t_iter_elapsed);
        pass_count++;
    }

    Serial.println("──────────────────────────────────────");
    Serial.printf("  Results: %lu PASS, %lu FAIL / %lu total\n",
                   pass_count, fail_count, iterations);
    Serial.printf("  Total time:   %lu us\n", t_total);
    if (pass_count > 0)
        Serial.printf("  Avg per iter: %lu us\n", t_total / pass_count);

    if (fail_count == 0) {
        Serial.println("  >> ALL PASSED <<");
        return true;
    } else {
        Serial.println("  >> SOME FAILED <<");
        return false;
    }
}

/**
 * Test 4: FPGA-only round-trip stress test.
 * Random block → encrypt → decrypt → compare.
 * No software reference computation — pure FPGA accelerator throughput test.
 */
static bool test_fpga_stress(uint32_t iterations) {
    Serial.println("══════════════════════════════════════");
    Serial.printf("  TEST 4: FPGA stress round-trip (%lu iter)\n", iterations);
    Serial.println("  (no SW validation, max FPGA load)");
    Serial.println("══════════════════════════════════════");

    uint32_t pass_count = 0;
    uint32_t fail_count = 0;
    unsigned long t_total_start = micros();

    // Use a single random key for the whole run
    uint64_t key = ((uint64_t)esp_random() << 32) | esp_random();
    Serial.printf("  Key: 0x%016llX\n", key);
    fpga_write_key(key);

    for (uint32_t i = 0; i < iterations; i++) {
        uint32_t plaintext = esp_random();

        // ── Encrypt ──
        fpga_write_block(plaintext);
        fpga_encrypt();

        if (!fpga_wait_done()) {
            fail_count++;
            // Re-load key for next iteration (state may be corrupt)
            fpga_write_key(key);
            continue;
        }

        uint32_t ct = fpga_read_result();

        // ── Decrypt ──
        fpga_write_block(ct);
        fpga_decrypt();

        if (!fpga_wait_done()) {
            fail_count++;
            fpga_write_key(key);
            continue;
        }

        uint32_t recovered = fpga_read_result();

        if (recovered != plaintext) {
            fail_count++;
        } else {
            pass_count++;
        }
    }

    unsigned long t_total = micros() - t_total_start;

    Serial.println("──────────────────────────────────────");
    Serial.printf("  Results: %lu PASS, %lu FAIL / %lu total\n",
                   pass_count, fail_count, iterations);
    Serial.printf("  Total time:   %lu us  (%.3f s)\n", t_total, t_total / 1000000.0);
    if (pass_count > 0)
        Serial.printf("  Avg per iter: %lu us\n", t_total / pass_count);
    if (t_total > 0)
        Serial.printf("  Throughput:   %.1f round-trips/s\n",
                       pass_count * 1000000.0 / t_total);

    if (fail_count == 0) {
        Serial.println("  >> ALL PASSED <<");
        return true;
    } else {
        Serial.println("  >> SOME FAILED <<");
        return false;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Console helpers
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Read a positive integer from Serial with prompt.
 * Returns default_val on empty input or timeout.
 */
static uint32_t read_uint(const char *prompt, uint32_t default_val) {
    Serial.printf("%s [default %lu]: ", prompt, default_val);
    String s = "";
    while (true) {
        if (Serial.available()) {
            char c = Serial.read();
            if (c == '\n' || c == '\r') {
                Serial.println();
                break;
            }
            if (c >= '0' && c <= '9') {
                s += c;
                Serial.print(c);
            }
        }
    }
    if (s.length() == 0) return default_val;
    return (uint32_t)s.toInt();
}

static void print_menu() {
    Serial.println();
    Serial.println("╔══════════════════════════════════════╗");
    Serial.println("║  SIMON 32/64 FPGA Hardware Tester   ║");
    Serial.println("║  ESP32 DEVKIT V1                    ║");
    Serial.println("╠══════════════════════════════════════╣");
    Serial.println("║  1 — Encrypt test vector            ║");
    Serial.println("║  2 — Decrypt test vector            ║");
    Serial.println("║  3 — Random encrypt/decrypt (+ ref) ║");
    Serial.println("║  4 — FPGA stress round-trip         ║");
    Serial.println("║  5 — Run all tests (1+2+3+4)        ║");
    Serial.println("║  6 — Read FPGA status register      ║");
    Serial.println("║  7 — Reset FPGA                     ║");
    Serial.println("╚══════════════════════════════════════╝");
    Serial.print(">> Select: ");
}

// ═══════════════════════════════════════════════════════════════════════════
// Arduino setup / loop
// ═══════════════════════════════════════════════════════════════════════════

void setup() {
    Serial.begin(115200);
    while (!Serial) { delay(10); }

    // Configure CS pin manually (SPI library does not drive it for us)
    pinMode(PIN_CS, OUTPUT);
    digitalWrite(PIN_CS, HIGH);  // CS idle high

    // Configure FPGA reset pin
    pinMode(PIN_RST, OUTPUT);
    digitalWrite(PIN_RST, HIGH); // not in reset initially

    // Start SPI on custom pins (pass -1 for SS so SPI lib doesn't touch CS)
    SPI.begin(PIN_SCK, PIN_MISO, PIN_MOSI, -1);

    // Properly reset the FPGA design (LOW pulse then HIGH)
    fpga_reset();

    Serial.println();
    Serial.println("========================================");
    Serial.println(" SIMON 32/64 — FPGA Hardware Test");
    Serial.println(" SPI: SCK=D22, MOSI=D23, MISO=D19, CS=D5");
    Serial.println(" RST: D4");
    Serial.printf(" SPI clock: %d Hz, Mode 3\n", SPI_SPEED);
    Serial.println("========================================");

    print_menu();
}

void loop() {
    if (!Serial.available()) return;

    char c = Serial.read();
    if (c < '1' || c > '7') return;  // ignore invalid input

    Serial.println(c);  // echo selection
    Serial.println();

    switch (c) {
        case '1':
            test_encrypt();
            break;

        case '2':
            test_decrypt();
            break;

        case '3': {
            uint32_t n = read_uint("  Number of iterations", 10);
            test_random_roundtrip(n);
            break;
        }

        case '4': {
            uint32_t n = read_uint("  Number of iterations", 100);
            test_fpga_stress(n);
            break;
        }

        case '5': {
            Serial.println("Running all tests...\n");
            bool ok = true;
            ok &= test_encrypt();
            Serial.println();
            ok &= test_decrypt();
            Serial.println();
            uint32_t n3 = read_uint("  Iterations for random+ref test", 10);
            ok &= test_random_roundtrip(n3);
            Serial.println();
            uint32_t n4 = read_uint("  Iterations for stress test", 100);
            ok &= test_fpga_stress(n4);
            Serial.println();
            Serial.println(ok ? "=== ALL TESTS PASSED ===" : "=== SOME TESTS FAILED ===");
            break;
        }

        case '6': {
            uint8_t st = fpga_read_status();
            Serial.printf("  Status register: 0x%02X (done=%d)\n", st, st & 1);
            break;
        }

        case '7':
            fpga_reset();
            break;
    }

    print_menu();
}
