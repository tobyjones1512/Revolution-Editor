#ifndef STUB_ASNDLIB_H
#define STUB_ASNDLIB_H
#include "gccore.h"
#define VOICE_MONO_16BIT 1
#define VOICE_STEREO_16BIT 5
#define SND_UNUSED 0
#define SND_WORKING 1
#define SND_WAITING 2
s32 ASND_StatusVoice(s32 voice); s32 ASND_TestVoiceBufferReady(s32 voice); s32 ASND_StopVoice(s32 voice); s32 ASND_AddVoice(s32 voice, void *snd, s32 size_snd); s32 ASND_ChangeVolumeVoice(s32 voice, s32 volume_l, s32 volume_r);
void ASND_Init(void); void ASND_Pause(s32 paused); s32 ASND_GetFirstUnusedVoice(void);
s32 ASND_SetVoice(s32 voice, s32 format, s32 pitch, s32 delay, void *snd, s32 size_snd, s32 volume_l, s32 volume_r, void (*callback)(s32 voice));
#endif
