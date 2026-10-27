#include <erl_nif.h>
#include <stdint.h>

/* Reflected Castagnoli polynomial; no final XOR in update. Slicing by eight
 * uses explicit byte loads, independent of host endianness and alignment.
 * Tables are initialized before publication and never mutated afterward. */
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

static uint32_t table[CRC32C_SLICE_BYTES][CRC32C_BYTE_VALUES];

static uint32_t crc_update(uint32_t crc, const unsigned char *p, size_t size)
{
    while (size >= CRC32C_SLICE_BYTES) {
        uint32_t first = crc ^ (uint32_t)p[0] ^
                         ((uint32_t)p[1] << CRC32C_BITS_PER_BYTE) ^
                         ((uint32_t)p[2] << (2 * CRC32C_BITS_PER_BYTE)) ^
                         ((uint32_t)p[3] << (3 * CRC32C_BITS_PER_BYTE));
        /* Byte positions 0..7 select slices 7..0: each earlier byte has
         * more trailing bytes to advance through the polynomial. */
        crc = table[7][first & CRC32C_BYTE_MASK] ^
              table[6][(first >> CRC32C_BITS_PER_BYTE) & CRC32C_BYTE_MASK] ^
              table[5][(first >> (2 * CRC32C_BITS_PER_BYTE)) & CRC32C_BYTE_MASK] ^
              table[4][first >> (3 * CRC32C_BITS_PER_BYTE)] ^
              table[3][p[4]] ^ table[2][p[5]] ^ table[1][p[6]] ^ table[0][p[7]];
        p += CRC32C_SLICE_BYTES;
        size -= CRC32C_SLICE_BYTES;
    }
    while (size > 0) {
        crc = (crc >> CRC32C_BITS_PER_BYTE) ^ table[0][(crc ^ *p++) & CRC32C_BYTE_MASK];
        size--;
    }
    return crc;
}

static ERL_NIF_TERM update_dirty(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int reg;
    ErlNifBinary bytes;
    if (argc != UPDATE_ARITY || !enif_get_uint(env, argv[UPDATE_REGISTER_ARG], &reg) ||
        !enif_inspect_binary(env, argv[UPDATE_BYTES_ARG], &bytes))
        return enif_make_badarg(env);
    return enif_make_uint(env, crc_update((uint32_t)reg, bytes.data, bytes.size));
}

static ERL_NIF_TERM update(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int reg;
    ErlNifBinary bytes;
    if (argc != UPDATE_ARITY || !enif_get_uint(env, argv[UPDATE_REGISTER_ARG], &reg) ||
        !enif_inspect_binary(env, argv[UPDATE_BYTES_ARG], &bytes))
        return enif_make_badarg(env);
    if (bytes.size > CRC32C_REGULAR_MAX_BYTES)
        return enif_schedule_nif(env, "crc32c_update", ERL_NIF_DIRTY_JOB_CPU_BOUND,
                                 update_dirty, argc, argv);
    return enif_make_uint(env, crc_update((uint32_t)reg, bytes.data, bytes.size));
}

static ERL_NIF_TERM available(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "true");
}

static ERL_NIF_TERM record_checksums_result(ErlNifEnv *env,
                                           const ErlNifBinary *header,
                                           const ErlNifBinary *payload)
{
    uint32_t header_state = crc_update(CRC32C_INITIAL_REGISTER, header->data, header->size);
    uint32_t record_state = crc_update(header_state, payload->data, payload->size);
    return enif_make_tuple2(env,
                           enif_make_uint(env, header_state ^ CRC32C_FINAL_XOR),
                           enif_make_uint(env, record_state ^ CRC32C_FINAL_XOR));
}

static ERL_NIF_TERM record_checksums_dirty(ErlNifEnv *env, int argc,
                                          const ERL_NIF_TERM argv[])
{
    ErlNifBinary header, payload;
    if (argc != RECORD_ARITY ||
        !enif_inspect_binary(env, argv[RECORD_HEADER_ARG], &header) ||
        !enif_inspect_binary(env, argv[RECORD_PAYLOAD_ARG], &payload))
        return enif_make_badarg(env);
    return record_checksums_result(env, &header, &payload);
}

static ERL_NIF_TERM record_checksums(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary header, payload;
    if (argc != RECORD_ARITY ||
        !enif_inspect_binary(env, argv[RECORD_HEADER_ARG], &header) ||
        !enif_inspect_binary(env, argv[RECORD_PAYLOAD_ARG], &payload))
        return enif_make_badarg(env);
    /* Keep update/2's per-buffer limit, avoiding a dirty-scheduler transition
     * for a short header plus a payload that previously ran on a regular one.
     * Regular work is bounded by twice CRC32C_REGULAR_MAX_BYTES; no size sum. */
    if (header.size > CRC32C_REGULAR_MAX_BYTES ||
        payload.size > CRC32C_REGULAR_MAX_BYTES)
        return enif_schedule_nif(env, "crc32c_record_checksums", ERL_NIF_DIRTY_JOB_CPU_BOUND,
                                 record_checksums_dirty, argc, argv);
    return record_checksums_result(env, &header, &payload);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    (void)env;
    (void)priv;
    (void)info;
    for (unsigned int i = 0; i < CRC32C_BYTE_VALUES; i++) {
        uint32_t crc = i;
        for (unsigned int bit = 0; bit < CRC32C_BITS_PER_BYTE; bit++)
            crc = (crc >> 1) ^ ((crc & 1) ? CRC32C_REFLECTED_POLYNOMIAL : 0);
        table[0][i] = crc;
    }
    for (unsigned int n = 1; n < CRC32C_SLICE_BYTES; n++)
        for (unsigned int i = 0; i < CRC32C_BYTE_VALUES; i++) {
            uint32_t crc = table[n - 1][i];
            table[n][i] = (crc >> CRC32C_BITS_PER_BYTE) ^ table[0][crc & CRC32C_BYTE_MASK];
        }
    return 0;
}

static ErlNifFunc functions[] = {
    {"update", UPDATE_ARITY, update, 0},
    {"record_checksums", RECORD_ARITY, record_checksums, 0},
    {"available?", 0, available, 0}
};

ERL_NIF_INIT(Elixir.Tay.Storage.CRC32C.Native, functions, load, NULL, NULL, NULL)
