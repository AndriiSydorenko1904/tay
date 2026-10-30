#ifndef TAY_CRC32C_FUZZ
#include <erl_nif.h>
#endif
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

/* CRC-32C uses the reflected Castagnoli polynomial. Updates return the raw
 * register; only completed checksums receive the final XOR. */
#define CRC32C_REFLECTED_POLYNOMIAL UINT32_C(0x82F63B78)
#define CRC32C_INITIAL_REGISTER UINT32_MAX
#define CRC32C_FINAL_XOR UINT32_MAX

enum {
    CRC32C_BITS_PER_BYTE = 8,
    CRC32C_BYTE_VALUES = 1U << CRC32C_BITS_PER_BYTE,
    CRC32C_BYTE_MASK = CRC32C_BYTE_VALUES - 1,
    CRC32C_SLICE_BYTES = 8,
    /* Bound work on ordinary BEAM schedulers; larger buffers use dirty CPU. */
    CRC32C_REGULAR_MAX_BYTES = 4096
};

enum update_argument {
    UPDATE_REGISTER_ARG = 0,
    UPDATE_BYTES_ARG,
    UPDATE_ARITY
};

enum record_argument {
    RECORD_HEADER_ARG = 0,
    RECORD_PAYLOAD_ARG,
    RECORD_ARITY
};

/* Initialized during NIF load, before any calls, and read-only afterward.
 * Slice N accounts for a byte followed by N additional bytes. */
static uint32_t crc32c_table[CRC32C_SLICE_BYTES][CRC32C_BYTE_VALUES];

static uint32_t crc32c_update_byte(uint32_t crc, unsigned char byte)
{
    return (crc >> CRC32C_BITS_PER_BYTE) ^
           crc32c_table[0][(crc ^ byte) & CRC32C_BYTE_MASK];
}

static void initialize_crc32c_tables(void)
{
    for (unsigned int byte = 0; byte < CRC32C_BYTE_VALUES; byte++) {
        uint32_t crc = byte;
        for (unsigned int bit = 0; bit < CRC32C_BITS_PER_BYTE; bit++) {
            bool low_bit_set = (crc & 1U) != 0;
            crc >>= 1;
            if (low_bit_set) {
                crc ^= CRC32C_REFLECTED_POLYNOMIAL;
            }
        }
        crc32c_table[0][byte] = crc;
    }

    /* Each next slice advances the previous slice by one zero byte. */
    for (unsigned int slice = 1; slice < CRC32C_SLICE_BYTES; slice++) {
        for (unsigned int byte = 0; byte < CRC32C_BYTE_VALUES; byte++) {
            crc32c_table[slice][byte] = crc32c_update_byte(crc32c_table[slice - 1][byte], 0);
        }
    }
}

static uint32_t load_u32_le(const unsigned char *bytes)
{
    /* Explicit byte loads work on every host endianness and alignment. */
    return (uint32_t)bytes[0] |
           ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[3] << 24);
}

static uint32_t crc32c_update(uint32_t crc, const unsigned char *bytes, size_t size)
{
    while (size >= CRC32C_SLICE_BYTES) {
        uint32_t mixed = crc ^ load_u32_le(bytes);

        /* Process eight bytes at once. Earlier bytes have more trailing
         * bytes, so byte positions 0..7 use slices 7..0 respectively. */
        crc = crc32c_table[7][mixed & CRC32C_BYTE_MASK] ^
              crc32c_table[6][(mixed >> 8) & CRC32C_BYTE_MASK] ^
              crc32c_table[5][(mixed >> 16) & CRC32C_BYTE_MASK] ^
              crc32c_table[4][mixed >> 24] ^
              crc32c_table[3][bytes[4]] ^
              crc32c_table[2][bytes[5]] ^
              crc32c_table[1][bytes[6]] ^
              crc32c_table[0][bytes[7]];

        bytes += CRC32C_SLICE_BYTES;
        size -= CRC32C_SLICE_BYTES;
    }

    /* Finish the remaining zero to seven bytes individually. */
    while (size > 0) {
        crc = crc32c_update_byte(crc, *bytes);
        bytes++;
        size--;
    }
    return crc;
}

#ifndef TAY_CRC32C_FUZZ
/* A scheduled NIF receives the original Erlang terms. Inspect them again in
 * the dirty callback instead of retaining binary views from the first call. */
static bool read_update_arguments(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[],
                                  unsigned int *register_value, ErlNifBinary *bytes)
{
    return argc == UPDATE_ARITY &&
           enif_get_uint(env, argv[UPDATE_REGISTER_ARG], register_value) &&
           enif_inspect_binary(env, argv[UPDATE_BYTES_ARG], bytes);
}

static bool read_record_arguments(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[],
                                  ErlNifBinary *header, ErlNifBinary *payload)
{
    return argc == RECORD_ARITY &&
           enif_inspect_binary(env, argv[RECORD_HEADER_ARG], header) &&
           enif_inspect_binary(env, argv[RECORD_PAYLOAD_ARG], payload);
}

static ERL_NIF_TERM update_dirty(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int register_value;
    ErlNifBinary bytes;
    if (!read_update_arguments(env, argc, argv, &register_value, &bytes)) {
        return enif_make_badarg(env);
    }
    return enif_make_uint(env, crc32c_update((uint32_t)register_value, bytes.data, bytes.size));
}

static ERL_NIF_TERM update(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int register_value;
    ErlNifBinary bytes;
    if (!read_update_arguments(env, argc, argv, &register_value, &bytes)) {
        return enif_make_badarg(env);
    }
    if (bytes.size > CRC32C_REGULAR_MAX_BYTES) {
        return enif_schedule_nif(env, "crc32c_update", ERL_NIF_DIRTY_JOB_CPU_BOUND,
                                 update_dirty, argc, argv);
    }
    return enif_make_uint(env, crc32c_update((uint32_t)register_value, bytes.data, bytes.size));
}

static ERL_NIF_TERM record_checksums_result(ErlNifEnv *env,
                                           const ErlNifBinary *header,
                                           const ErlNifBinary *payload)
{
    uint32_t header_state = crc32c_update(CRC32C_INITIAL_REGISTER, header->data, header->size);
    /* Continue from the raw header register; do not finalize between chunks. */
    uint32_t record_state = crc32c_update(header_state, payload->data, payload->size);
    return enif_make_tuple2(env,
                           enif_make_uint(env, header_state ^ CRC32C_FINAL_XOR),
                           enif_make_uint(env, record_state ^ CRC32C_FINAL_XOR));
}

static ERL_NIF_TERM record_checksums_dirty(ErlNifEnv *env, int argc,
                                          const ERL_NIF_TERM argv[])
{
    ErlNifBinary header, payload;
    if (!read_record_arguments(env, argc, argv, &header, &payload)) {
        return enif_make_badarg(env);
    }
    return record_checksums_result(env, &header, &payload);
}

static ERL_NIF_TERM record_checksums(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary header, payload;
    if (!read_record_arguments(env, argc, argv, &header, &payload)) {
        return enif_make_badarg(env);
    }
    /* Apply update/2's limit to each buffer separately. This keeps a small
     * header plus a 4096-byte payload on the regular scheduler as before.
     * At most 8192 bytes run here; separate comparisons avoid size overflow. */
    if (header.size > CRC32C_REGULAR_MAX_BYTES ||
        payload.size > CRC32C_REGULAR_MAX_BYTES) {
        return enif_schedule_nif(env, "crc32c_record_checksums", ERL_NIF_DIRTY_JOB_CPU_BOUND,
                                 record_checksums_dirty, argc, argv);
    }
    return record_checksums_result(env, &header, &payload);
}

static ERL_NIF_TERM available(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "true");
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    (void)env;
    (void)priv;
    (void)info;
    initialize_crc32c_tables();
    return 0;
}

static ErlNifFunc functions[] = {
    {"update", UPDATE_ARITY, update, 0},
    {"record_checksums", RECORD_ARITY, record_checksums, 0},
    {"available?", 0, available, 0}
};

ERL_NIF_INIT(Elixir.Tay.Storage.CRC32C.Native, functions, load, NULL, NULL, NULL)

#endif /* !TAY_CRC32C_FUZZ */
