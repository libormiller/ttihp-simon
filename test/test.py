# SPDX-FileCopyrightText: © 2024 Libor Miller
# SPDX-License-Identifier: Apache-2.0

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer

# ---------------------------------------------------------------------------
# SPI bit-bang helpers  (Mode 3: CPOL=1, CPHA=1, MSB first)
# ---------------------------------------------------------------------------
# Pin mapping in uio:
#   bit 0 = CS_n  (idle HIGH)
#   bit 1 = MOSI
#   bit 2 = MISO  (output from slave)
#   bit 3 = SCK   (idle HIGH)

SPI_HALF_NS = 500  # half-period of SPI clock in ns  (-> 1 MHz SCK)


def rotl(x, k): return ((x << k) & 0xFFFF) | (x >> (16 - k))
def rotr(x, k): return ((x >> k) & 0xFFFF) | ((x << (16 - k)) & 0xFFFF)


def simon_32_64_gold(plaintext_int, key_int):
    key = [(key_int >> (i*16)) & 0xFFFF for i in range(4)]
    L = (plaintext_int >> 16) & 0xFFFF; R = (plaintext_int >> 0) & 0xFFFF
    z0 = 0b11111010001001010110000111001101111101000100101011000011100110
    for i in range(32):
        curr_k = key[0]
        f_val = (rotl(L, 1) & rotl(L, 8)) ^ rotl(L, 2)
        new_L = R ^ f_val ^ curr_k
        new_R = L; L = new_L; R = new_R
        c = 0xFFFC; z_bit = (z0 >> (61 - i)) & 1
        tmp = rotr(key[3], 3) ^ key[1]; tmp_ror1 = rotr(tmp, 1)
        k_new = c ^ z_bit ^ key[0] ^ tmp ^ tmp_ror1
        key = key[1:] + [k_new]
    return ((L & 0xFFFF) << 16) | (R & 0xFFFF)


async def spi_begin(dut):
    """Assert CS_n low; SCK stays high (Mode 3 idle)."""
    dut.uio_in.value = 0x08  # SCK=1, MOSI=0, CS_n=0
    await Timer(SPI_HALF_NS, unit="ns")


async def spi_end(dut):
    """De-assert CS_n; SCK stays high."""
    dut.uio_in.value = 0x09  # SCK=1, MOSI=0, CS_n=1
    await Timer(SPI_HALF_NS, unit="ns")


async def spi_xfer_byte(dut, mosi_byte):
    """Clock one byte over SPI. Returns the MISO byte received."""
    miso_byte = 0
    for i in range(8):
        bit = (mosi_byte >> (7 - i)) & 1
        # Falling SCK edge - slave shifts-out next MISO bit, master sets MOSI
        dut.uio_in.value = (bit << 1)          # SCK=0, CS_n=0
        await Timer(SPI_HALF_NS, unit="ns")
        # Rising SCK edge - slave samples MOSI, master samples MISO
        dut.uio_in.value = (bit << 1) | 0x08   # SCK=1, CS_n=0
        await Timer(100, unit="ns")           # settle time
        try:
            miso_bit = (dut.uio_out.value.to_unsigned() >> 2) & 1
        except ValueError:
            miso_bit = 0  # treat x/z as 0 (GL sim before signals settle)
        miso_byte = (miso_byte << 1) | miso_bit
        await Timer(SPI_HALF_NS - 100, unit="ns")
    return miso_byte


# ---------------------------------------------------------------------------
# High-level SPI command wrappers
# ---------------------------------------------------------------------------

async def spi_write_key(dut, key_64):
    """Write 64-bit key (CMD 0x01), LSB first."""
    await spi_begin(dut)
    await spi_xfer_byte(dut, 0x01)
    for i in range(8):
        await spi_xfer_byte(dut, (key_64 >> (i * 8)) & 0xFF)
    await spi_end(dut)


async def spi_write_block(dut, block_32):
    """Write 32-bit block (CMD 0x02), LSB first."""
    await spi_begin(dut)
    await spi_xfer_byte(dut, 0x02)
    for i in range(4):
        await spi_xfer_byte(dut, (block_32 >> (i * 8)) & 0xFF)
    await spi_end(dut)


async def spi_encrypt(dut):
    """Issue encrypt command (CMD 0x03)."""
    await spi_begin(dut)
    await spi_xfer_byte(dut, 0x03)
    await spi_end(dut)


async def spi_decrypt(dut):
    """Issue decrypt command (CMD 0x04)."""
    await spi_begin(dut)
    await spi_xfer_byte(dut, 0x04)
    await spi_end(dut)


async def spi_read_status(dut):
    """Read status byte (CMD 0x05). Returns done bit (0 or 1)."""
    await spi_begin(dut)
    await spi_xfer_byte(dut, 0x05)
    status = await spi_xfer_byte(dut, 0x00)  # dummy -> gets status on MISO
    await spi_end(dut)
    return status & 1


async def spi_read_result(dut):
    """Read 32-bit result (CMD 0x06), LSB first."""
    await spi_begin(dut)
    await spi_xfer_byte(dut, 0x06)
    result = 0
    for i in range(4):
        b = await spi_xfer_byte(dut, 0x00)
        result |= b << (i * 8)
    await spi_end(dut)
    return result


async def wait_done(dut, attempts=20):
    """Poll status until done or timeout. Returns True on success."""
    for _ in range(attempts):
        if await spi_read_status(dut):
            return True
        await ClockCycles(dut.clk, 50)
    return False


async def init_dut(dut):
    """Start clock, apply reset, wait for startup initialisation."""
    clock = Clock(dut.clk, 20, unit="ns")    # 50 MHz  (matches config.json)
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0x09   # SPI idle: SCK=1, MOSI=0, CS_n=1
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 100)  # let startup cipher reset finish (GL sim needs more)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# SIMON 32/64 official test vector (from the SIMON specification):
#   Key        = 0x1918_1110_0908_0100
#   Plaintext  = 0x6565_6877
#   Ciphertext = 0xc69b_e9bb

KEY_TV        = 0x1918111009080100
PLAIN_TV      = 0x65656877
CIPHER_TV     = 0xc69be9bb


@cocotb.test()
async def test_default_key_roundtrip(dut):
    """Encrypt then decrypt a random block using the default key; verify round-trip."""
    await init_dut(dut)
    dut._log.info("=== Default key round-trip test ===")

    plaintext = random.getrandbits(32)
    dut._log.info(f"Plaintext:  0x{plaintext:08X}")

    # We skip writing the key and rely on the hardware reset default
    await spi_write_block(dut, plaintext)
    await spi_encrypt(dut)

    assert await wait_done(dut), "Encryption did not finish"

    ciphertext = await spi_read_result(dut)
    dut._log.info(f"Ciphertext: 0x{ciphertext:08X}")

    await spi_write_block(dut, ciphertext)
    await spi_decrypt(dut)

    assert await wait_done(dut), "Decryption did not finish"

    decrypted = await spi_read_result(dut)
    dut._log.info(f"Decrypted:  0x{decrypted:08X}  (expected 0x{plaintext:08X})")
    assert decrypted == plaintext, f"Round-trip default key mismatch: 0x{decrypted:08X} != 0x{plaintext:08X}"
    dut._log.info("PASS")


@cocotb.test()
async def test_encrypt(dut):
    """Encrypt with known test vector and verify ciphertext."""
    await init_dut(dut)
    dut._log.info("=== Encrypt test ===")

    await spi_write_key(dut, KEY_TV)
    await spi_write_block(dut, PLAIN_TV)
    await spi_encrypt(dut)

    assert await wait_done(dut), "Encryption did not finish"

    ct = await spi_read_result(dut)
    dut._log.info(f"Result:   0x{ct:08X}  (expected 0x{CIPHER_TV:08X})")
    assert ct == CIPHER_TV, f"Encrypt mismatch: 0x{ct:08X} != 0x{CIPHER_TV:08X}"
    dut._log.info("PASS")


@cocotb.test()
async def test_decrypt(dut):
    """Decrypt with known test vector and verify plaintext."""
    await init_dut(dut)
    dut._log.info("=== Decrypt test ===")

    await spi_write_key(dut, KEY_TV)
    await spi_write_block(dut, CIPHER_TV)
    await spi_decrypt(dut)

    assert await wait_done(dut), "Decryption did not finish"

    pt = await spi_read_result(dut)
    dut._log.info(f"Result:   0x{pt:08X}  (expected 0x{PLAIN_TV:08X})")
    assert pt == PLAIN_TV, f"Decrypt mismatch: 0x{pt:08X} != 0x{PLAIN_TV:08X}"
    dut._log.info("PASS")


@cocotb.test()
async def test_roundtrip(dut):
    """Encrypt then decrypt with an arbitrary key; verify round-trip."""
    await init_dut(dut)
    dut._log.info("=== Round-trip test ===")

    KEY       = 0xDEADBEEFCAFEBABE
    PLAINTEXT = 0x12345678

    # Encrypt
    await spi_write_key(dut, KEY)
    await spi_write_block(dut, PLAINTEXT)
    await spi_encrypt(dut)
    assert await wait_done(dut), "Encryption did not finish"
    ct = await spi_read_result(dut)
    dut._log.info(f"Ciphertext: 0x{ct:08X}")

    # Decrypt (key still in registers, just reload block)
    await spi_write_block(dut, ct)
    await spi_decrypt(dut)
    assert await wait_done(dut), "Decryption did not finish"
    pt = await spi_read_result(dut)
    dut._log.info(f"Decrypted:  0x{pt:08X}  (expected 0x{PLAINTEXT:08X})")

    assert pt == PLAINTEXT, f"Roundtrip failed: 0x{pt:08X} != 0x{PLAINTEXT:08X}"
    dut._log.info("PASS")


@cocotb.test()
async def test_random_encrypt_decrypt(dut):
    """Validate random encrypt/decrypt operations against simon_32_64_gold reference model."""
    await init_dut(dut)
    dut._log.info("=== Random encrypt/decrypt with reference model ===")

    NUM_ITERATIONS = 5
    rng = random.Random(42)  # fixed seed for reproducibility

    for iteration in range(NUM_ITERATIONS):
        key = rng.randint(0, (1 << 64) - 1)
        plaintext = rng.randint(0, (1 << 32) - 1)
        expected_ct = simon_32_64_gold(plaintext, key)

        dut._log.info(
            f"[{iteration}] key=0x{key:016X}  pt=0x{plaintext:08X}  "
            f"expected_ct=0x{expected_ct:08X}"
        )

        # --- Encrypt and compare to gold model ---
        await spi_write_key(dut, key)
        await spi_write_block(dut, plaintext)
        await spi_encrypt(dut)
        assert await wait_done(dut), f"[{iteration}] Encryption did not finish"
        ct = await spi_read_result(dut)
        assert ct == expected_ct, (
            f"[{iteration}] Encrypt mismatch: 0x{ct:08X} != 0x{expected_ct:08X}"
        )

        # --- Decrypt ciphertext and verify we recover plaintext ---
        await spi_write_key(dut, key)
        await spi_write_block(dut, ct)
        await spi_decrypt(dut)
        assert await wait_done(dut), f"[{iteration}] Decryption did not finish"
        pt = await spi_read_result(dut)
        assert pt == plaintext, (
            f"[{iteration}] Decrypt mismatch: 0x{pt:08X} != 0x{plaintext:08X}"
        )

        dut._log.info(f"[{iteration}] PASS  ct=0x{ct:08X}  pt=0x{pt:08X}")

    dut._log.info(f"All {NUM_ITERATIONS} random iterations PASSED")
