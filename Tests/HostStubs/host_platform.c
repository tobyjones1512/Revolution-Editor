/* Host implementations of the libogc input/sound calls the runtime makes. */
#include <string.h>
#include "host.h"
#include <asndlib.h>

u32 host_wpad_held[4]; ir_t host_ir; u16 host_pad_held[4]; int host_pad_stick_x[4], host_pad_stick_y[4];
int host_nunchuk[4]; float host_nunchuk_mag[4], host_nunchuk_ang[4];
int host_sounds_started; s32 host_last_sound_rate, host_last_sound_bytes;
static u32 prev[4], down[4];
static WPADData data[4];

s32 WPAD_Init(void) { return 0; }
s32 WPAD_SetDataFormat(s32 c, s32 f) { (void)c; (void)f; return 0; }
s32 WPAD_SetVRes(s32 c, u32 x, u32 y) { (void)c; (void)x; (void)y; return 0; }
s32 WPAD_ScanPads(void) {
    for (int c = 0; c < 4; c++) {
        down[c] = host_wpad_held[c] & ~prev[c]; prev[c] = host_wpad_held[c];
        memset(&data[c], 0, sizeof data[c]);
        if (host_nunchuk[c]) { data[c].exp.type = WPAD_EXP_NUNCHUK; data[c].exp.nunchuk.js.mag = host_nunchuk_mag[c]; data[c].exp.nunchuk.js.ang = host_nunchuk_ang[c]; }
    }
    return 0;
}
u32 WPAD_ButtonsDown(int c) { return down[c]; }
u32 WPAD_ButtonsHeld(int c) { return host_wpad_held[c]; }
void WPAD_IR(int c, ir_t *o) { *o = c == 0 ? host_ir : (ir_t){ 0 }; }
WPADData *WPAD_Data(int c) { return &data[c]; }

u32 PAD_Init(void) { return 0; } u32 PAD_ScanPads(void) { return 0; }
u16 PAD_ButtonsHeld(int p) { return host_pad_held[p]; }
s8 PAD_StickX(int p) { return (s8)host_pad_stick_x[p]; } s8 PAD_StickY(int p) { return (s8)host_pad_stick_y[p]; }

void ASND_Init(void) {} void ASND_Pause(s32 p) { (void)p; } s32 ASND_GetFirstUnusedVoice(void) { return 1; }
s32 ASND_SetVoice(s32 v, s32 f, s32 pitch, s32 d, void *snd, s32 n, s32 l, s32 r, void (*cb)(s32)) {
    (void)v; (void)f; (void)d; (void)snd; (void)l; (void)r; (void)cb;
    host_sounds_started++; host_last_sound_rate = pitch; host_last_sound_bytes = n; return 0;
}

s32 ASND_StatusVoice(s32 v) { (void)v; return SND_UNUSED; }
s32 ASND_StopVoice(s32 v) { (void)v; return 0; }
s32 ASND_AddVoice(s32 v, void *snd, s32 n) { (void)v; (void)snd; (void)n; return 0; }
s32 ASND_ChangeVolumeVoice(s32 v, s32 l, s32 r) { (void)v; (void)l; (void)r; return 0; }
s32 ASND_TestVoiceBufferReady(s32 v) { (void)v; return 0; }
