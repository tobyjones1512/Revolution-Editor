/* Controls for the host stand-ins: set the "controller" before a frame, read the "screen" after. */
#ifndef HOST_H
#define HOST_H
#include <wiiuse/wpad.h>
extern u32 host_wpad_held[4];          /* buttons held this frame (Wii Remote masks) */
extern ir_t host_ir;                   /* player 1's pointer */
extern u16 host_pad_held[4];           /* GameCube pad buttons */
extern int host_pad_stick_x[4], host_pad_stick_y[4];
extern int host_nunchuk[4];            /* 1 = a Nunchuk is attached */
extern float host_nunchuk_mag[4], host_nunchuk_ang[4];
extern int host_sounds_started;        /* ASND_SetVoice calls */
extern s32 host_last_sound_rate, host_last_sound_bytes;
extern unsigned host_frames_presented;
void host_pixel(int x, int y, int *r, int *g, int *b);     /* the last presented frame */
void host_dump_ppm(const char *path);
#endif
