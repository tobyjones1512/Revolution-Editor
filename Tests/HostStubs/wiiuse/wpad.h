#ifndef STUB_WPAD_H
#define STUB_WPAD_H
#include "../gccore.h"
#define WPAD_BUTTON_2     0x0001
#define WPAD_BUTTON_1     0x0002
#define WPAD_BUTTON_B     0x0004
#define WPAD_BUTTON_A     0x0008
#define WPAD_BUTTON_MINUS 0x0010
#define WPAD_BUTTON_HOME  0x0080
#define WPAD_BUTTON_LEFT  0x0100
#define WPAD_BUTTON_RIGHT 0x0200
#define WPAD_BUTTON_DOWN  0x0400
#define WPAD_BUTTON_UP    0x0800
#define WPAD_BUTTON_PLUS  0x1000
#define WPAD_CLASSIC_BUTTON_UP    (0x0001u<<16)
#define WPAD_CLASSIC_BUTTON_LEFT  (0x0002u<<16)
#define WPAD_CLASSIC_BUTTON_X     (0x0008u<<16)
#define WPAD_CLASSIC_BUTTON_A     (0x0010u<<16)
#define WPAD_CLASSIC_BUTTON_Y     (0x0020u<<16)
#define WPAD_CLASSIC_BUTTON_B     (0x0040u<<16)
#define WPAD_CLASSIC_BUTTON_PLUS  (0x0400u<<16)
#define WPAD_CLASSIC_BUTTON_MINUS (0x1000u<<16)
#define WPAD_CLASSIC_BUTTON_DOWN  (0x4000u<<16)
#define WPAD_CLASSIC_BUTTON_RIGHT (0x8000u<<16)
#define WPAD_FMT_BTNS_ACC_IR 1
#define WPAD_ERR_NONE 0
enum { WPAD_EXP_NONE = 0, WPAD_EXP_NUNCHUK, WPAD_EXP_CLASSIC };
typedef struct { int valid; float x, y; } ir_t;
typedef struct { float mag, ang; } joystick_t;
typedef struct { int err; struct { int type; struct { struct { joystick_t js; } nunchuk; struct { joystick_t ljs; } classic; }; } exp; } WPADData;
s32 WPAD_Init(void); s32 WPAD_SetDataFormat(s32 chan, s32 fmt); s32 WPAD_SetVRes(s32 chan, u32 xres, u32 yres);
s32 WPAD_ScanPads(void); u32 WPAD_ButtonsDown(int chan); u32 WPAD_ButtonsHeld(int chan); void WPAD_IR(int chan, ir_t *ir); WPADData *WPAD_Data(int chan);
#endif
