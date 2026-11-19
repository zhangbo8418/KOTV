/*
 * Dolby Vision profile 7 to profile 8.1 RPU conversion, for the hardware
 * decoders that only take profile 8.1.
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "config.h"

#include <stddef.h>
#include <stdint.h>

#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"

#include "dovi_convert.h"

// --- dovi p7 conversion core

#if CONFIG_LIBDOVI

#include <string.h>

#include <libdovi/rpu_parser.h>

/*
 * libdovi before 3.4.0 panics -- an abort through its C API -- on an RPU
 * whose payload, once its emulation prevention bytes are cleared and its
 * trailing zero bytes trimmed, is shorter than the prefix, CRC32 and final
 * byte it then indexes. The apple group links a prebuilt libdovi 3.3.2 with
 * no such check, so refuse that shape here, at the bound libdovi 3.4.0 uses:
 * the prefix byte, one payload byte, the CRC32 and the final byte. Anything
 * libdovi rejects on its own -- shorter than 25 bytes, or not starting with
 * the NAL header and RPU prefix below -- is left to its error path.
 */
static int dovi_rpu_long_enough(const uint8_t *nal, size_t size)
{
    static const uint8_t start[] = { 0x7C, 0x01, 0x19, 0x08, 0x09 };
    const uint8_t *rpu = nal + 2;
    size_t len, kept = 0, end = 0;

    if (size < 25 || memcmp(nal, start, sizeof(start)))
        return 1;
    len = size - 2;
    for (size_t i = 0; i < len; i++) {
        // libdovi drops every 3 that follows two zero bytes of the input.
        if (i >= 2 && !rpu[i - 2] && !rpu[i - 1] && rpu[i] == 3)
            continue;
        kept++;
        if (rpu[i])
            end = kept;
    }
    return end >= 7;
}

int ff_dovi_convert_p7_rpu_to_p81(const uint8_t *nal, size_t size,
                                  uint8_t **out, size_t *out_size, void *logctx)
{
    DoviRpuOpaque *rpu;
    const DoviData *data;
    const char *error;
    int ret = 0;

    *out = NULL;
    *out_size = 0;

    if (!dovi_rpu_long_enough(nal, size)) {
        av_log(logctx, AV_LOG_WARNING,
               "Dolby Vision RPU conversion failed: RPU data too short\n");
        return AVERROR_INVALIDDATA;
    }

    rpu = dovi_parse_unspec62_nalu(nal, size);
    if (!rpu) {
        av_log(logctx, AV_LOG_WARNING, "Failed to allocate a Dolby Vision RPU\n");
        return AVERROR(ENOMEM);
    }
    error = dovi_rpu_get_error(rpu);
    /* Mode 2: profile 8.1 compatible, mapping curves set to no-op. */
    if (!error && dovi_convert_rpu_with_mode(rpu, 2) < 0)
        error = dovi_rpu_get_error(rpu);
    data = error ? NULL : dovi_write_unspec62_nalu(rpu);
    if (!data) {
        av_log(logctx, AV_LOG_WARNING, "Dolby Vision RPU conversion failed: %s\n",
               error ? error : "unknown error");
        ret = AVERROR_INVALIDDATA;
    } else if (data->len > UINT32_MAX) {
        // Every caller passes the converted size on as a uint32_t length;
        // refuse a NAL that cannot survive that instead of truncating it.
        ret = AVERROR_INVALIDDATA;
    } else {
        *out = av_memdup(data->data, data->len);
        if (*out)
            *out_size = data->len;
        else
            ret = AVERROR(ENOMEM);
    }
    if (data)
        dovi_data_free(data);
    dovi_rpu_free(rpu);
    return ret;
}

#else

int ff_dovi_convert_p7_rpu_to_p81(const uint8_t *nal, size_t size,
                                  uint8_t **out, size_t *out_size, void *logctx)
{
    *out = NULL;
    *out_size = 0;
    av_log(logctx, AV_LOG_WARNING, "Dolby Vision profile 7 conversion needs libdovi\n");
    return AVERROR(ENOSYS);
}

#endif

// --- end dovi p7 conversion core
