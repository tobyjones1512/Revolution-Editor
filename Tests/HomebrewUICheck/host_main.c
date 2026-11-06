#include <stdio.h>
#include <string.h>
#include "wiiui.h"
#include "ui_generated.h"
#include "host.h"

static int fails = 0;
#define CHECK(c, what) do { int ok_ = (c); printf("%s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) fails++; } while (0)

static int lit_pixels(int x0, int y0, int x1, int y1) {
    int n = 0, r, g, b;
    for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) { host_pixel(x, y, &r, &g, &b); if (r > 200 && g > 200 && b > 200) n++; }
    return n;
}

int main(int argc, char **argv) {
    const char *outdir = argc > 1 ? argv[1] : ".";
    char path[512];
    wiiui_init();
    CHECK(wiiui_widget_count == 3, "three widgets loaded");
    CHECK(strcmp(wiiui_get_text(UI_STATUS), "Point and press A") == 0, "status starts with its design-time text");

    host_ir.valid = 1; host_ir.x = 5; host_ir.y = 5;
    wiiui_frame();
    int r, g, b; host_pixel(630, 470, &r, &g, &b);
    CHECK(r < 40 && g < 40 && b < 60, "background drawn dark");
    CHECK(lit_pixels(40, 40, 300, 100) > 200, "title text drawn from the font atlas (light pixels in the title box)");
    snprintf(path, sizeof path, "%s/before.ppm", outdir); host_dump_ppm(path);

    /* Click "Press me" three times: A held for one frame, then released. */
    for (int i = 0; i < 3; i++) {
        host_ir.x = 120; host_ir.y = 250;
        host_wpad_held[0] = WPAD_BUTTON_A; wiiui_frame();
        host_wpad_held[0] = 0; wiiui_frame();
    }
    CHECK(strcmp(wiiui_get_text(UI_STATUS), "Pressed 3") == 0, "node logic ran: status reads \"Pressed 3\"");

    host_ir.x = 500; host_ir.y = 400;
    host_wpad_held[0] = WPAD_BUTTON_A; wiiui_frame(); host_wpad_held[0] = 0; wiiui_frame();
    CHECK(strcmp(wiiui_get_text(UI_STATUS), "Pressed 3") == 0, "clicking empty space does nothing");

    host_ir.x = 120; host_ir.y = 250;
    wiiui_frame();
    host_pixel(60, 230, &r, &g, &b);
    CHECK(g > r && g > b, "button drawn green (hovered)");
    snprintf(path, sizeof path, "%s/after.ppm", outdir); host_dump_ppm(path);

    host_wpad_held[0] = WPAD_BUTTON_HOME;
    CHECK(wiiui_frame() == 0, "HOME ends the frame loop");
    printf(fails ? "%d FAILED\n" : "HOST RUN OK\n", fails);
    return fails != 0;
}
