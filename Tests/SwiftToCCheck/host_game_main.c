/* The starter game (Swift and C versions behave the same): paddle, ball sprite, score text, sound. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wiiui.h"
#include "ui_generated.h"
#include "host.h"

static int fails = 0;
#define CHECK(c, what) do { int ok_ = (c); printf("%s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) fails++; } while (0)

static int paddle_left(void) {                       /* leftmost green pixel on the paddle's row */
    int r, g, b;
    for (int x = 0; x < 640; x++) { host_pixel(x, 448, &r, &g, &b); if (abs(r - 80) < 10 && abs(g - 200) < 10 && abs(b - 120) < 10) return x; }
    return -1;
}

static int count(int x0, int y0, int x1, int y1, int (*match)(int, int, int)) {
    int n = 0, r, g, b;
    for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) { host_pixel(x, y, &r, &g, &b); n += match(r, g, b); }
    return n;
}
static int is_orange(int r, int g, int b) { return r > 200 && g > 80 && g < 200 && b < 140; }
static int is_light(int r, int g, int b) { return r > 200 && g > 200 && b > 200; }

int main(int argc, char **argv) {
    wiiui_init();
    wiiui_frame();
    CHECK(paddle_left() == 270, "paddle starts at x = 270");
    CHECK(count(300, 150, 400, 220, is_orange) > 300, "the ball sprite (assets/ball.png) is drawn, from a decoded RGB5A3 texture");
    CHECK(count(15, 8, 300, 50, is_light) > 100, "score text is drawn");

    host_wpad_held[0] = WPAD_BUTTON_RIGHT;
    for (int i = 0; i < 5; i++) wiiui_frame();
    host_wpad_held[0] = 0;
    CHECK(paddle_left() == 270 + 5 * 8, "D-pad right moves the paddle 8 px a frame");

    host_nunchuk[0] = 1; host_nunchuk_mag[0] = 1; host_nunchuk_ang[0] = 270;   /* stick pushed left */
    for (int i = 0; i < 3; i++) wiiui_frame();
    host_nunchuk[0] = 0;
    CHECK(paddle_left() == 270 + 40 - 3 * 8, "a Nunchuk stick moves it too");

    host_ir.valid = 1; host_ir.x = 400; host_ir.y = 300;
    wiiui_frame();
    CHECK(paddle_left() == 350, "pointing the Wii Remote puts the paddle under the pointer");
    host_ir.valid = 0;

    for (int i = 0; i < 120; i++) wiiui_frame();
    CHECK(host_sounds_started > 0 && host_last_sound_rate == 32000 && host_last_sound_bytes > 0, "the ball bouncing plays assets/blip.wav (32 kHz, converted)");
    CHECK(host_frames_presented > 120, "frames are presented");
    if (argc > 1) host_dump_ppm(argv[1]);
    printf(fails ? "%d FAILED\n" : "GAME OK\n", fails);
    return fails != 0;
}
