/* Runs language.swift: its appOnStart makes every hostCheck call, which are counted here. */
#include <stdio.h>
#include "wiiui.h"
#include "ui_generated.h"
#include "host.h"

static int passed = 0, failed = 0;
void host_check(int ok, const char *name) {
    if (ok) passed++;
    else { failed++; printf("FAIL %s\n", name); }
}

int main(void) {
    wiiui_init();
    wiiui_frame();
    printf("%d checks passed, %d failed\n", passed, failed);
    if (passed < 103) { printf("FAIL too few checks ran (%d)\n", passed); return 1; }
    printf(failed ? "LANGUAGE FAILED\n" : "LANGUAGE OK\n");
    return failed != 0;
}
