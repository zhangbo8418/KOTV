/*
 * Dolby Vision profile 7 to profile 8.1 RPU conversion.
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

#ifndef AVCODEC_DOVI_CONVERT_H
#define AVCODEC_DOVI_CONVERT_H

#include <stddef.h>
#include <stdint.h>

/**
 * Rewrite a Dolby Vision profile 7 RPU NAL as its profile 8.1 equivalent,
 * through libdovi's compatibility mode 2 (mapping curves set to no-op), for
 * the decoders that only take profile 8.1. A failure is logged here, once
 * for every NAL it is called with, and leaves the caller to drop the NAL:
 * the frame still decodes through its base layer.
 *
 * @param nal      the full UNSPEC62 NAL unit, header included
 * @param size     its size in bytes
 * @param out      the converted NAL, av_free() it; NULL on failure
 * @param out_size its size in bytes
 * @param logctx   an AVCodecContext or any other av_log() context
 * @return >= 0 on success, a negative AVERROR value otherwise: ENOSYS when
 *         FFmpeg was built without libdovi, ENOMEM, or INVALIDDATA for an
 *         RPU libdovi would not take, or for one whose converted size no
 *         longer fits the uint32_t length every caller passes on.
 */
int ff_dovi_convert_p7_rpu_to_p81(const uint8_t *nal, size_t size,
                                  uint8_t **out, size_t *out_size, void *logctx);

#endif /* AVCODEC_DOVI_CONVERT_H */
