#ifndef KOTV_VLC_DECODE_H
#define KOTV_VLC_DECODE_H

/* Soft/auto decode (avcodec-hw). Declared here so gopls always sees them. */
int kotv_vlc_set_decode(int soft);
int kotv_vlc_can_decode(void);

#endif
