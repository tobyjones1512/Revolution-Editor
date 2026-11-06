/* A software stand-in for the GX backend (wgfx_gx.c): draws the same quads into an RGB canvas.
   It decodes the Wii's 4x4-tiled RGB5A3 / IA8 textures, so the generated texture data is checked
   as well as the drawing logic. */
#include <string.h>
#include <stdio.h>
#include "wgfx.h"
#include "host.h"

#define W 640
#define H 480
static unsigned char canvas[W * H * 3];
static unsigned char shown[W * H * 3];
unsigned host_frames_presented;

void wgfx_init(int game_w) { (void)game_w; }
void wgfx_screen_size(int *w, int *h) { *w = W; *h = H; }
void wgfx_screen_to_game(int sx, int sy, int *gx, int *gy) { *gx = sx; *gy = sy; }

void wgfx_begin(int r, int g, int b) {
    for (int i = 0; i < W * H; i++) { canvas[i * 3] = r; canvas[i * 3 + 1] = g; canvas[i * 3 + 2] = b; }
}

static void texel(const wgfx_texture *t, int x, int y, int *r, int *g, int *b, int *a) {
    int tiles_per_row = t->pw / 4;
    int off = (((y / 4) * tiles_per_row + (x / 4)) * 16 + (y % 4) * 4 + (x % 4)) * 2;
    unsigned v = (t->data[off] << 8) | t->data[off + 1];
    if (t->format == WGFX_IA8) { *a = t->data[off]; *r = *g = *b = t->data[off + 1]; return; }
    if (v & 0x8000) { *r = ((v >> 10) & 31) * 255 / 31; *g = ((v >> 5) & 31) * 255 / 31; *b = (v & 31) * 255 / 31; *a = 255; }
    else { *a = ((v >> 12) & 7) * 255 / 7; *r = ((v >> 8) & 15) * 17; *g = ((v >> 4) & 15) * 17; *b = (v & 15) * 17; }
}

void wgfx_quad(wgfx_texture *t, float x, float y, float w, float h, float u0, float v0, float u1, float v1, int r, int g, int b, int a) {
    int x0 = (int)(x + 0.5f), y0 = (int)(y + 0.5f), x1 = (int)(x + w + 0.5f), y1 = (int)(y + h + 0.5f);
    for (int py = y0; py < y1; py++) {
        if (py < 0 || py >= H) continue;
        for (int px = x0; px < x1; px++) {
            if (px < 0 || px >= W) continue;
            int tr = 255, tg = 255, tb = 255, ta = 255;
            if (t) {
                float u = u0 + (u1 - u0) * ((px - x0) + 0.5f) / (x1 - x0), v = v0 + (v1 - v0) * ((py - y0) + 0.5f) / (y1 - y0);
                int tx = (int)(u * t->pw), ty = (int)(v * t->ph);
                if (tx < 0) tx = 0;
                if (ty < 0) ty = 0;
                if (tx >= t->pw) tx = t->pw - 1;
                if (ty >= t->ph) ty = t->ph - 1;
                texel(t, tx, ty, &tr, &tg, &tb, &ta);
            }
            int al = ta * a / 255;
            unsigned char *p = &canvas[(py * W + px) * 3];
            p[0] = p[0] + ((tr * r / 255 - p[0]) * al) / 255;
            p[1] = p[1] + ((tg * g / 255 - p[1]) * al) / 255;
            p[2] = p[2] + ((tb * b / 255 - p[2]) * al) / 255;
        }
    }
}

void wgfx_set_fps(int fps) { (void)fps; }
void wgfx_end(void) { memcpy(shown, canvas, sizeof canvas); host_frames_presented++; }
void host_pixel(int x, int y, int *r, int *g, int *b) { unsigned char *p = &shown[(y * W + x) * 3]; *r = p[0]; *g = p[1]; *b = p[2]; }
void host_dump_ppm(const char *path) { FILE *f = fopen(path, "wb"); fprintf(f, "P6\n%d %d\n255\n", W, H); fwrite(shown, 3, W * H, f); fclose(f); }
