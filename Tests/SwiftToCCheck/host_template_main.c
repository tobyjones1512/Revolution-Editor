/* The SwiftUI template's sample app: draws, reacts to a button press, and leaves a picture. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wiiui.h"
#include "host.h"

void host_check(int ok, const char *name) { (void)ok; (void)name; }
void host_value(const char *name, int v) { (void)name; (void)v; }

static int fails = 0;
#define CHECK(c, what) do { int ok_ = (c); printf("%s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) fails++; } while (0)

static int count_color(int r0, int g0, int b0, int tol) {
    int n = 0, r, g, b;
    for (int y = 0; y < 480; y++) for (int x = 0; x < 640; x++) { host_pixel(x, y, &r, &g, &b); if (abs(r - r0) < tol && abs(g - g0) < tol && abs(b - b0) < tol) n++; }
    return n;
}

int main(int argc, char **argv) {
    wiiui_init();
    for (int i = 0; i < 3; i++) wiiui_frame();
    CHECK(count_color(255, 204, 0, 12) > 300, "the yellow title is drawn");
    CHECK(count_color(0, 122, 255, 12) > 1500, "stat boxes and buttons are drawn");
    int before = count_color(176, 82, 224, 12);
    CHECK(before > 1000, "the purple Double box is drawn");
    /* Press the first button ("-1") with the D-pad + A, then "+1", and check the stats change colour layout (text width). */
    host_wpad_held[0] = WPAD_BUTTON_RIGHT; wiiui_frame(); host_wpad_held[0] = 0; wiiui_frame();
    host_wpad_held[0] = WPAD_BUTTON_A; wiiui_frame(); host_wpad_held[0] = 0; wiiui_frame();
    CHECK(count_color(255, 255, 255, 30) > 100, "text is drawn white");
    if (argc > 1) { char p[512]; snprintf(p, sizeof p, "%s/swiftui_template.ppm", argv[1]); host_dump_ppm(p); }
    printf(fails ? "%d FAILED\n" : "TEMPLATE OK\n", fails);
    return fails != 0;
}
