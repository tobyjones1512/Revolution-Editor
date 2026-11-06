/* Host stand-in for libogc: just enough for the generated runtime to compile and run on the Mac. */
#ifndef STUB_GCCORE_H
#define STUB_GCCORE_H
#include <stdint.h>
#include <stdlib.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef int8_t s8; typedef int16_t s16; typedef int32_t s32; typedef float f32;
#define FALSE 0
#define TRUE 1
static inline void DCFlushRange(void *p, u32 n) { (void)p; (void)n; }

#define PAD_BUTTON_LEFT  0x0001
#define PAD_BUTTON_RIGHT 0x0002
#define PAD_BUTTON_DOWN  0x0004
#define PAD_BUTTON_UP    0x0008
#define PAD_TRIGGER_Z    0x0010
#define PAD_BUTTON_A     0x0100
#define PAD_BUTTON_B     0x0200
#define PAD_BUTTON_X     0x0400
#define PAD_BUTTON_Y     0x0800
#define PAD_BUTTON_START 0x1000
u32 PAD_Init(void); u32 PAD_ScanPads(void); u16 PAD_ButtonsHeld(int pad); s8 PAD_StickX(int pad); s8 PAD_StickY(int pad);
#endif
