/* Exercise the exact production checksum core outside the VM so ASan/UBSan and
 * libFuzzer can instrument every load without injecting runtimes into BEAM. */
#define TAY_CRC32C_FUZZ 1
#include "tay_crc32c.c"
#include <stdlib.h>

static uint32_t reference(uint32_t crc, const uint8_t *data, size_t size)
{
    for (size_t i = 0; i < size; i++) {
        crc ^= data[i];
        for (unsigned int bit = 0; bit < 8; bit++) {
            crc = (crc >> 1) ^ ((crc & 1U) ? UINT32_C(0x82F63B78) : 0);
        }
    }
    return crc;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    static bool initialized;
    if (!initialized) {
        initialize_crc32c_tables();
        initialized = true;
    }
    uint32_t seed = size >= 4 ? load_u32_le(data) : UINT32_MAX;
    uint32_t expected = reference(seed, data, size);
    if (crc32c_update(seed, data, size) != expected) abort();
    size_t split = size ? data[0] % size : 0;
    uint32_t prefix = crc32c_update(seed, data, split);
    if (crc32c_update(prefix, data + split, size - split) != expected) abort();
    /* Byte offsets cover unaligned and zero-length slices as well. */
    size_t offset = size > 8 ? data[size - 1] % 8 : 0;
    if (crc32c_update(seed, data + offset, size - offset) !=
        reference(seed, data + offset, size - offset)) abort();
    return 0;
}

#ifdef TAY_FUZZ_STANDALONE
#include <stdio.h>
#include <string.h>

static uint32_t random_word(uint32_t *state)
{
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return *state;
}

int main(int argc, char **argv)
{
    unsigned long runs = argc > 1 ? strtoul(argv[1], NULL, 10) : 100000;
    if (runs == 0 || runs > 10000000) return 2;
    uint8_t bytes[8192] = {0};
    uint32_t random = UINT32_C(0x657a4c31);
    const size_t boundaries[] = {0, 1, 7, 8, 9, 4095, 4096, 4097, 8191, 8192};
    LLVMFuzzerTestOneInput((const uint8_t *)"123456789", 9);
    if ((crc32c_update(UINT32_MAX, (const uint8_t *)"123456789", 9) ^ UINT32_MAX) != UINT32_C(0xe3069283)) abort();
    for (unsigned long run = 0; run < runs; run++) {
        size_t size = run % 64 == 0 ? boundaries[(run / 64) % 10] : random_word(&random) % 513;
        if (run % 32 == 0) memset(bytes, (int)(random_word(&random) & 255), sizeof(bytes));
        for (unsigned int mutation = 0; mutation < 16; mutation++) {
            bytes[random_word(&random) % sizeof(bytes)] ^= (uint8_t)random_word(&random);
        }
        LLVMFuzzerTestOneInput(bytes, size);
    }
    printf("CRC32C: %lu deterministic mutation cases passed with ASan/UBSan\n", runs);
    return 0;
}
#endif
