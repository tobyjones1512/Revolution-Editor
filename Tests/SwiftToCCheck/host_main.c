#include <stdio.h>
#include <string.h>
#include "wiiui.h"
#include "ui_generated.h"
#include "host.h"

static int fails = 0;
#define CHECK(c, what) do { int ok_ = (c); printf("%s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) fails++; } while (0)

int main(void) {
    wiiui_init();
    CHECK(strcmp(wiiui_get_text(UI_TITLE), "Hello Wii") == 0, "appOnStart ran; string interpolation of a global");
    host_ir.valid = 1; host_ir.x = 120; host_ir.y = 250;
    host_wpad_held[0] = WPAD_BUTTON_A; wiiui_frame(); host_wpad_held[0] = 0;
    printf("status: %s\n", wiiui_get_text(UI_STATUS));
    CHECK(strcmp(wiiui_get_text(UI_STATUS), "n=1 fib=55 d=5 sum=14 big avg=3.50 c=10 yes 3") == 0, "button handler: struct methods, enums, switch, arrays, loops, recursion, interpolation");
    host_wpad_held[0] = WPAD_BUTTON_B; wiiui_frame(); host_wpad_held[0] = 0;
    CHECK(strcmp(wiiui_get_text(UI_TITLE), "ratio 3") == 0, "appOnWpad: bit test on Button.b, Double arithmetic");
    printf(fails ? "%d FAILED\n" : "SWIFT HOST RUN OK\n", fails);
    return fails != 0;
}
