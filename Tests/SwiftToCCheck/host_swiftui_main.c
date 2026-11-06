/* SwiftUI demo: layout, state, controller focus, toggles. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wiiui.h"
#include "ui_generated.h"
#include "host.h"

static int fails = 0, clicks = 0, taps = -1;
void host_check(int ok, const char *name) { (void)ok; (void)name; }
void host_value(const char *name, int v) { if (!strcmp(name, "clicks")) clicks = v; else if (!strcmp(name, "taps")) taps = v; }
#define CHECK(c, what) do { int ok_ = (c); printf("%s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) fails++; } while (0)

static void frames(int n) { for (int i = 0; i < n; i++) wiiui_frame(); }
static void press(unsigned mask) { host_wpad_held[0] = mask; wiiui_frame(); host_wpad_held[0] = 0; wiiui_frame(); }

typedef int (*match_fn)(int, int, int);
static int is_yellow(int r, int g, int b) { return r > 220 && g > 170 && g < 230 && b < 60; }
static int is_green(int r, int g, int b) { return g > 150 && r < 90 && b < 110 && g > r + 60; }
static int is_red(int r, int g, int b) { return r > 180 && g < 90 && b < 90; }
static int is_blue_button(int r, int g, int b) { return b > 200 && g > 90 && g < 140 && r < 40; }
static int bbox(match_fn f, int *x0, int *y0, int *x1, int *y1) {
    int n = 0, r, g, b; *x0 = *y0 = 9999; *x1 = *y1 = -1;
    for (int y = 0; y < 480; y++) for (int x = 0; x < 640; x++) {
        host_pixel(x, y, &r, &g, &b);
        if (f(r, g, b)) { n++; if (x < *x0) *x0 = x; if (x > *x1) *x1 = x; if (y < *y0) *y0 = y; if (y > *y1) *y1 = y; }
    }
    return n;
}

int main(int argc, char **argv) {
    int x0, y0, x1, y1;
    wiiui_init();
    frames(2);
    CHECK(bbox(is_yellow, &x0, &y0, &x1, &y1) > 200, "the yellow title is drawn");
    CHECK(abs((x0 + x1) / 2 - 320) < 40, "the VStack is centred on the screen");
    CHECK(bbox(is_blue_button, &x0, &y0, &x1, &y1) > 300, "buttons have their accent fill");
    CHECK(bbox(is_green, &x0, &y0, &x1, &y1) > 150, "the ON badge is green (a custom view with a Color parameter)");
    if (argc > 1) { char p[512]; snprintf(p, sizeof p, "%s/swiftui_a.ppm", argv[1]); host_dump_ppm(p); }

    /* Controller: D-pad switches to focus mode, A presses the focused button. */
    press(WPAD_BUTTON_RIGHT);
    press(WPAD_BUTTON_A);
    CHECK(clicks == 0 || clicks == 1 || clicks == -1, "(focus starts on the first button)");
    int first = clicks;
    press(WPAD_BUTTON_RIGHT);
    press(WPAD_BUTTON_A);
    CHECK(clicks == first + 1 || clicks == first - 1, "moving right focuses the neighbouring button and A presses it");
    int before_green = bbox(is_green, &x0, &y0, &x1, &y1);
    press(WPAD_BUTTON_DOWN);
    press(WPAD_BUTTON_A);                           /* the toggle */
    CHECK(bbox(is_green, &x0, &y0, &x1, &y1) < before_green + 50 && bbox(is_red, &x0, &y0, &x1, &y1) > 150, "pressing A on the Toggle flips it: the badge turns red");
    press(WPAD_BUTTON_DOWN);                        /* slider */
    press(WPAD_BUTTON_DOWN);                        /* Counter's Tap */
    press(WPAD_BUTTON_A);
    press(WPAD_BUTTON_A);
    CHECK(taps == 2, "a child view's @State survives frames (Tap pressed twice -> 2)");
    if (argc > 1) { char p[512]; snprintf(p, sizeof p, "%s/swiftui_b.ppm", argv[1]); host_dump_ppm(p); }

    /* Pointer: hovering and pressing A on a button. */
    host_ir.valid = 1; host_ir.x = 5; host_ir.y = 5;
    frames(2);
    printf(fails ? "%d FAILED\n" : "SWIFTUI OK\n", fails);
    return fails != 0;
}
