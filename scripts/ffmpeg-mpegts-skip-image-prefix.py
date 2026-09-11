#!/usr/bin/env python3
"""让 mpegts 探测像 Exo 一样跳过 PNG/JPEG/GIF 壳，不必另做切片代理。"""
import pathlib
import re
import sys

MARKER = "kotv_image_prefix_skip"

HELPER = r'''
/* kotv_image_prefix_skip: 正片切片常在 TS 前套一层图片头。Exo 会往前找 0x47，这里同样做。 */
static int kotv_image_prefix_skip(const uint8_t *buf, int size)
{
    int i, limit;
    if (!buf || size < 16)
        return 0;
    if (!((buf[0] == 0x89 && buf[1] == 'P' && buf[2] == 'N' && buf[3] == 'G') ||
          (buf[0] == 0xff && buf[1] == 0xd8 && buf[2] == 0xff) ||
          (buf[0] == 'G' && buf[1] == 'I' && buf[2] == 'F')))
        return 0;
    limit = size > 512 * 1024 ? 512 * 1024 : size;
    for (i = 0; i + 376 < limit; i++) {
        if (buf[i] == 0x47 && buf[i + 188] == 0x47 && buf[i + 376] == 0x47)
            return i;
    }
    return 0;
}

'''


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: ffmpeg-mpegts-skip-image-prefix.py <ffmpeg-src>", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1]) / "libavformat" / "mpegts.c"
    if not path.is_file():
        print(f"missing {path}", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"ok already patched {path}")
        return 0
    needle = "static int mpegts_probe(const AVProbeData *p)\n{\n    const int size = p->buf_size;"
    if needle not in text:
        print(f"mpegts_probe shape changed in {path}", file=sys.stderr)
        return 1
    repl = (
        HELPER
        + "static int mpegts_probe(const AVProbeData *p)\n{\n"
        + "    const int kotv_skip = kotv_image_prefix_skip(p->buf, p->buf_size);\n"
        + "    const uint8_t *kotv_buf = p->buf + kotv_skip;\n"
        + "    const int size = p->buf_size - kotv_skip;"
    )
    text = text.replace(needle, repl, 1)
    start = text.find("static int mpegts_probe(const AVProbeData *p)")
    end = text.find("static int parse_pcr(", start)
    if start < 0 or end < 0:
        print("failed to bound mpegts_probe", file=sys.stderr)
        return 1
    body = text[start:end]
    body = re.sub(r"p->buf(?!_)", "kotv_buf", body)
    body = body.replace(
        "kotv_image_prefix_skip(kotv_buf, p->buf_size)",
        "kotv_image_prefix_skip(p->buf, p->buf_size)",
    )
    body = body.replace(
        "const uint8_t *kotv_buf = kotv_buf + kotv_skip;",
        "const uint8_t *kotv_buf = p->buf + kotv_skip;",
    )
    text = text[:start] + body + text[end:]
    path.write_text(text, encoding="utf-8")
    print(f"ok patched {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
