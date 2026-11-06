/* The node-based game: a green square moved with the D-pad, drawn in app_on_draw. */
#include <stdio.h>
#include "wiiui.h"
#include "ui_generated.h"
#include "host.h"

static int fails = 0;
#define CHECK(c, what) do { int ok_ = (c); printf("%s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) fails++; } while (0)

/* bounding box of the green square */
static int square(int *x0, int *y0, int *x1, int *y1) {
    int r, g, b, n = 0; *x0 = *y0 = 9999; *x1 = *y1 = -1;
    for (int y = 0; y < 480; y++) for (int x = 0; x < 640; x++) {
        host_pixel(x, y, &r, &g, &b);
        if (abs(r - 80) < 8 && abs(g - 200) < 8 && abs(b - 120) < 8) { n++; if (x < *x0) *x0 = x; if (x > *x1) *x1 = x; if (y < *y0) *y0 = y; if (y > *y1) *y1 = y; }
    }
    return n;
}

int main(int argc, char **argv) {
    int x0, y0, x1, y1;
    wiiui_init();
    wiiui_frame();
    CHECK(square(&x0, &y0, &x1, &y1) == 40 * 40 && x0 == 300 && y0 == 220, "square drawn at its start (300, 220), 40x40");
    host_wpad_held[0] = WPAD_BUTTON_LEFT;
    for (int i = 0; i < 10; i++) wiiui_frame();
    host_wpad_held[0] = WPAD_BUTTON_UP;
    for (int i = 0; i < 5; i++) wiiui_frame();
    host_wpad_held[0] = WPAD_BUTTON_RIGHT | WPAD_BUTTON_DOWN;
    for (int i = 0; i < 2; i++) wiiui_frame();
    host_wpad_held[0] = 0;
    wiiui_frame();
    square(&x0, &y0, &x1, &y1);
    CHECK(x0 == 300 - 40 + 8 && y0 == 220 - 20 + 8, "left 10, up 5, then right+down 2 moves it to (268, 208)");
    if (argc > 1) { char p[512]; snprintf(p, sizeof p, "%s/nodes_game.ppm", argv[1]); host_dump_ppm(p); }
    printf(fails ? "%d FAILED\n" : "NODES GAME OK\n", fails);
    return fails != 0;
}
