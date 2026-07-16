#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/extensions/XShm.h>
#include <sys/shm.h>
#include <sys/ipc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <unistd.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <fontconfig/fontconfig.h>

#include "../shared/backend.h"

static Display* g_display = NULL;
static Window g_window = 0;
static GC g_gc = NULL;
static XImage* g_image = NULL;
static XShmSegmentInfo g_shm_info;
static int g_shm_attached = 0;
static int g_width = 1024;
static int g_height = 768;
static uint32_t* g_pixels = NULL;

static ForgeRenderCallback g_render_cb = NULL;
static ForgeKeyCallback g_key_cb = NULL;
static ForgeMouseCallback g_mouse_cb = NULL;
static atomic_ullong g_redraw_requests = 0;
static atomic_ullong g_frames_drawn = 0;
static int g_continuous = 0;

static FT_Library g_ft = NULL;
static FT_Face g_face = NULL;
static pthread_mutex_t g_ft_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_font_family[256] = "sans-serif";
static int g_font_weight = 0;

static int g_clip_active = 0;
static int g_clip_x = 0, g_clip_y = 0, g_clip_w = 0, g_clip_h = 0;

static inline uint32_t rgba_to_bgra(float r, float g, float b, float a) {
    uint8_t R = (uint8_t)(r * 255.0f + 0.5f);
    uint8_t G = (uint8_t)(g * 255.0f + 0.5f);
    uint8_t B = (uint8_t)(b * 255.0f + 0.5f);
    uint8_t A = (uint8_t)(a * 255.0f + 0.5f);
    R = (uint8_t)((R * A) / 255);
    G = (uint8_t)((G * A) / 255);
    B = (uint8_t)((B * A) / 255);
    return (uint32_t)A << 24 | (uint32_t)R << 16 | (uint32_t)G << 8 | (uint32_t)B;
}

static inline uint32_t blend_pixel(uint32_t dst, uint32_t src) {
    uint8_t sa = (uint8_t)(src >> 24);
    if (sa == 0) return dst;
    if (sa == 255) return src;
    uint8_t sr = (uint8_t)(src >> 16);
    uint8_t sg = (uint8_t)(src >> 8);
    uint8_t sb = (uint8_t)(src);
    uint8_t dr = (uint8_t)(dst >> 16);
    uint8_t dg = (uint8_t)(dst >> 8);
    uint8_t db = (uint8_t)(dst);
    uint8_t inv = 255 - sa;
    uint8_t or_ = (uint8_t)((sr * 255 + dr * inv) / 255);
    uint8_t og = (uint8_t)((sg * 255 + dg * inv) / 255);
    uint8_t ob = (uint8_t)((sb * 255 + db * inv) / 255);
    return (uint32_t)255 << 24 | (uint32_t)or_ << 16 | (uint32_t)og << 8 | (uint32_t)ob;
}

static int allocate_framebuffer(int width, int height) {
    size_t bytes = (size_t)width * (size_t)height * 4;
    if (g_pixels) { free(g_pixels); g_pixels = NULL; }
    if (g_image) {
        if (g_shm_attached) { XShmDetach(g_display, &g_shm_info); g_shm_attached = 0; }
        XDestroyImage(g_image); g_image = NULL;
    }
    if (g_shm_info.shmaddr) { shmdt(g_shm_info.shmaddr); g_shm_info.shmaddr = NULL; }

    g_pixels = (uint32_t*)calloc(width * height, sizeof(uint32_t));
    if (!g_pixels) return 0;

    if (XShmQueryExtension(g_display)) {
        g_image = XShmCreateImage(g_display, DefaultVisual(g_display, DefaultScreen(g_display)),
                                  24, ZPixmap, NULL, &g_shm_info, width, height);
        if (g_image) {
            g_shm_info.shmid = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0777);
            if (g_shm_info.shmid >= 0) {
                g_shm_info.shmaddr = shmat(g_shm_info.shmid, NULL, 0);
                g_shm_info.readOnly = False;
                if (g_shm_info.shmaddr != (void*)-1) {
                    g_image->data = g_shm_info.shmaddr;
                    if (XShmAttach(g_display, &g_shm_info)) { g_shm_attached = 1; return 1; }
                }
                shmdt(g_shm_info.shmaddr); g_shm_info.shmaddr = NULL;
            }
        }
    }
    g_image = XCreateImage(g_display, DefaultVisual(g_display, DefaultScreen(g_display)),
                           24, ZPixmap, 0, (char*)g_pixels, width, height, 32, width * 4);
    return g_image != NULL;
}

static int load_font(void) {
    pthread_mutex_lock(&g_ft_lock);
    if (g_face) { FT_Done_Face(g_face); g_face = NULL; }
    if (!g_ft) { if (FT_Init_FreeType(&g_ft) != 0) { pthread_mutex_unlock(&g_ft_lock); return 0; } }
    FcConfig* cfg = FcInitLoadConfigAndFonts();
    if (!cfg) { pthread_mutex_unlock(&g_ft_lock); return 0; }
    FcPattern* pat = FcPatternCreate();
    FcPatternAddString(pat, FC_FAMILY, (const FcChar8*)g_font_family);
    int fc_weight = FC_WEIGHT_REGULAR;
    switch (g_font_weight) { case 1: fc_weight = FC_WEIGHT_MEDIUM; break; case 2: fc_weight = FC_WEIGHT_DEMIBOLD; break; case 3: fc_weight = FC_WEIGHT_BOLD; break; default: break; }
    FcPatternAddInteger(pat, FC_WEIGHT, fc_weight);
    FcConfigSubstitute(cfg, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);
    FcResult result;
    FcPattern* match = FcFontMatch(cfg, pat, &result);
    FcChar8* font_file = NULL;
    if (match) FcPatternGetString(match, FC_FILE, 0, &font_file);
    int ok = 0;
    if (font_file) { if (FT_New_Face(g_ft, (const char*)font_file, 0, &g_face) == 0) ok = 1; }
    if (match) FcPatternDestroy(match);
    FcPatternDestroy(pat);
    FcConfigDestroy(cfg);
    pthread_mutex_unlock(&g_ft_lock);
    return ok;
}

static inline int in_clip(int x, int y) {
    if (!g_clip_active) return 1;
    return x >= g_clip_x && x < g_clip_x + g_clip_w && y >= g_clip_y && y < g_clip_y + g_clip_h;
}

static void put_pixel(int x, int y, uint32_t premul_bgra) {
    if (x < 0 || y < 0 || x >= g_width || y >= g_height) return;
    if (!in_clip(x, y)) return;
    uint32_t* dst = &g_pixels[(size_t)y * g_width + x];
    *dst = blend_pixel(*dst, premul_bgra);
}

void forge_backend_draw_rect(float xf, float yf, float wf, float hf, float r, float g, float b, float a) {
    if (a <= 0.0f) return;
    int x0 = (int)xf, y0 = (int)yf;
    int x1 = (int)(xf + wf), y1 = (int)(yf + hf);
    if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0;
    if (x1 > g_width) x1 = g_width; if (y1 > g_height) y1 = g_height;
    uint32_t color = rgba_to_bgra(r, g, b, a);
    if (a >= 0.999f) {
        for (int y = y0; y < y1; y++) { uint32_t* row = &g_pixels[(size_t)y * g_width]; for (int x = x0; x < x1; x++) if (in_clip(x, y)) row[x] = color; }
    } else {
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) put_pixel(x, y, color);
    }
}

void forge_backend_draw_rounded_rect(float xf, float yf, float wf, float hf, float r, float g, float b, float a, float corner_radius) {
    if (a <= 0.0f) return;
    int x0 = (int)xf, y0 = (int)yf, x1 = (int)(xf + wf), y1 = (int)(yf + hf);
    int rad = (int)corner_radius;
    if (rad <= 0) { forge_backend_draw_rect(xf, yf, wf, hf, r, g, b, a); return; }
    if (2 * rad > x1 - x0) rad = (x1 - x0) / 2;
    if (2 * rad > y1 - y0) rad = (y1 - y0) / 2;
    if (rad < 0) rad = 0;
    uint32_t color = rgba_to_bgra(r, g, b, a);
    for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) {
        int dx = 0, dy = 0;
        if (x < x0 + rad && y < y0 + rad) { dx = x0 + rad - x; dy = y0 + rad - y; }
        else if (x >= x1 - rad && y < y0 + rad) { dx = x - (x1 - rad - 1); dy = y0 + rad - y; }
        else if (x < x0 + rad && y >= y1 - rad) { dx = x0 + rad - x; dy = y - (y1 - rad - 1); }
        else if (x >= x1 - rad && y >= y1 - rad) { dx = x - (x1 - rad - 1); dy = y - (y1 - rad - 1); }
        if (dx > 0 && dy > 0 && dx * dx + dy * dy > rad * rad) continue;
        put_pixel(x, y, color);
    }
}

static void draw_glyph_bitmap(FT_Bitmap* bitmap, int dx, int dy, float r, float g, float b, float a) {
    uint8_t R = (uint8_t)(r*255), G = (uint8_t)(g*255), B = (uint8_t)(b*255);
    for (unsigned int y = 0; y < bitmap->rows; y++) {
        int py = dy + (int)y; if (py < 0 || py >= g_height) continue;
        for (unsigned int x = 0; x < bitmap->width; x++) {
            int px = dx + (int)x; if (px < 0 || px >= g_width) continue;
            uint8_t ga = bitmap->buffer[y * bitmap->pitch + x]; if (ga == 0) continue;
            float alpha = (ga / 255.0f) * a;
            uint32_t premul = ((uint32_t)(alpha*255) << 24) | ((uint32_t)(R*alpha) << 16) | ((uint32_t)(G*alpha) << 8) | (uint32_t)(B*alpha);
            put_pixel(px, py, premul);
        }
    }
}

static void render_text_run(const char* text, size_t len, float x, float y, float font_size, float r, float g, float b, float a) {
    if (len == 0 || !g_face) return;
    pthread_mutex_lock(&g_ft_lock);
    FT_Set_Pixel_Sizes(g_face, 0, (unsigned int)(font_size + 0.5f));
    float pen_x = x;
    float pen_y = y + (g_face->size->metrics.ascender >> 6);
    size_t i = 0;
    while (i < len) {
        unsigned long cp = 0; size_t adv = 0;
        uint8_t c = (uint8_t)text[i];
        if (c < 0x80) { cp = c; adv = 1; }
        else if ((c & 0xE0) == 0xC0 && i+1 < len) { cp = ((c&0x1F)<<6)|((uint8_t)text[i+1]&0x3F); adv = 2; }
        else if ((c & 0xF0) == 0xE0 && i+2 < len) { cp = ((c&0x0F)<<12)|(((uint8_t)text[i+1]&0x3F)<<6)|((uint8_t)text[i+2]&0x3F); adv = 3; }
        else if ((c & 0xF8) == 0xF0 && i+3 < len) { cp = ((c&0x07)<<18)|(((uint8_t)text[i+1]&0x3F)<<12)|(((uint8_t)text[i+2]&0x3F)<<6)|((uint8_t)text[i+3]&0x3F); adv = 4; }
        else { adv = 1; }
        i += adv;
        FT_UInt gi = FT_Get_Char_Index(g_face, cp);
        if (FT_Load_Glyph(g_face, gi, FT_LOAD_RENDER) != 0) continue;
        FT_GlyphSlot slot = g_face->glyph;
        draw_glyph_bitmap(&slot->bitmap, (int)pen_x + slot->bitmap_left, (int)pen_y - slot->bitmap_top, r, g, b, a);
        pen_x += (float)(slot->advance.x >> 6);
    }
    pthread_mutex_unlock(&g_ft_lock);
}

void forge_backend_draw_text_len(const char* text, size_t len, float x, float y, float fs, float r, float g, float b, float a) {
    if (text && len > 0) render_text_run(text, len, x, y, fs, r, g, b, a);
}

void forge_backend_draw_styled_text(const char* text, size_t len, float x, float y, float fs, const ForgeTextSpan* spans, size_t n) {
    if (!text || len == 0) return;
    if (n == 0) { forge_backend_draw_text_len(text, len, x, y, fs, 1, 1, 1, 1); return; }
    for (size_t i = 0; i < n; i++) {
        if (spans[i].offset >= len) continue;
        size_t end = spans[i].offset + spans[i].length; if (end > len) end = len;
        if (end <= spans[i].offset) continue;
        float pw = forge_backend_measure_text_width(text, spans[i].offset, fs);
        forge_backend_draw_text_len(text + spans[i].offset, end - spans[i].offset, x + pw, y, fs, spans[i].r, spans[i].g, spans[i].b, spans[i].a);
    }
}

void forge_backend_draw_svg(const char* svg, float x, float y, float w, float h, float r, float g, float b, float a) {
    (void)svg; forge_backend_draw_rect(x, y, w, h, r, g, b, a * 0.7f);
}

float forge_backend_measure_text_width(const char* text, size_t len, float font_size) {
    if (!text || len == 0 || !g_face) return 0.0f;
    pthread_mutex_lock(&g_ft_lock);
    FT_Set_Pixel_Sizes(g_face, 0, (unsigned int)(font_size + 0.5f));
    float width = 0.0f;
    size_t i = 0;
    while (i < len) {
        unsigned long cp = 0; size_t adv = 0;
        uint8_t c = (uint8_t)text[i];
        if (c < 0x80) { cp = c; adv = 1; }
        else if ((c & 0xE0) == 0xC0 && i+1 < len) { cp = ((c&0x1F)<<6)|((uint8_t)text[i+1]&0x3F); adv = 2; }
        else if ((c & 0xF0) == 0xE0 && i+2 < len) { cp = ((c&0x0F)<<12)|(((uint8_t)text[i+1]&0x3F)<<6)|((uint8_t)text[i+2]&0x3F); adv = 3; }
        else if ((c & 0xF8) == 0xF0 && i+3 < len) { cp = ((c&0x07)<<18)|(((uint8_t)text[i+1]&0x3F)<<12)|(((uint8_t)text[i+2]&0x3F)<<6)|((uint8_t)text[i+3]&0x3F); adv = 4; }
        else { adv = 1; }
        i += adv;
        FT_UInt gi = FT_Get_Char_Index(g_face, cp);
        if (FT_Load_Glyph(g_face, gi, FT_LOAD_DEFAULT) != 0) continue;
        width += (float)(g_face->glyph->advance.x >> 6);
    }
    pthread_mutex_unlock(&g_ft_lock);
    return width;
}

void forge_backend_set_text_style(const char* family, int weight) {
    if (!family) return;
    strncpy(g_font_family, family, sizeof(g_font_family) - 1);
    g_font_family[sizeof(g_font_family)-1] = 0;
    g_font_weight = weight;
    load_font();
}

void forge_backend_set_editor_text_metrics(float fs, float lh, float bl) { (void)fs; (void)lh; (void)bl; }
void forge_backend_get_resolved_font_name(char* buf, size_t cap) { if (buf && cap) { strncpy(buf, g_font_family, cap-1); buf[cap-1] = 0; } }
void forge_backend_get_font_metrics(float fs, float* cw, float* lh, float* bl) {
    if (!g_face) { if (cw) *cw = fs*0.6f; if (lh) *lh = fs*1.2f; if (bl) *bl = fs*0.9f; return; }
    pthread_mutex_lock(&g_ft_lock);
    FT_Set_Pixel_Sizes(g_face, 0, (unsigned int)(fs+0.5f));
    if (cw) *cw = (float)(g_face->size->metrics.max_advance >> 6);
    if (lh) *lh = (float)(g_face->size->metrics.height >> 6);
    if (bl) *bl = (float)(g_face->size->metrics.ascender >> 6);
    pthread_mutex_unlock(&g_ft_lock);
}

void forge_backend_get_window_size(float* w, float* h) { if (w) *w = (float)g_width; if (h) *h = (float)g_height; }
void forge_backend_set_clip_rect(float x, float y, float w, float h) {
    g_clip_x = (int)x; g_clip_y = (int)y; g_clip_w = (int)w; g_clip_h = (int)h;
    if (g_clip_x < 0) { g_clip_w += g_clip_x; g_clip_x = 0; }
    if (g_clip_y < 0) { g_clip_h += g_clip_y; g_clip_y = 0; }
    if (g_clip_x + g_clip_w > g_width) g_clip_w = g_width - g_clip_x;
    if (g_clip_y + g_clip_h > g_height) g_clip_h = g_height - g_clip_y;
    g_clip_active = g_clip_w > 0 && g_clip_h > 0;
}
void forge_backend_clear_clip_rect(void) { g_clip_active = 0; }
void forge_backend_flush_batch(void) {}

void forge_backend_set_clipboard_text(const char* text, size_t len) { (void)text; (void)len; }
size_t forge_backend_get_clipboard_text(char* out, size_t cap) { (void)out; (void)cap; return 0; }
int forge_backend_save_clipboard_png(const char* path) { (void)path; return 0; }

static void handle_event(XEvent* ev) {
    switch (ev->type) {
        case ConfigureNotify: {
            int nw = ev->xconfigure.width, nh = ev->xconfigure.height;
            if (nw > 0 && nh > 0 && (nw != g_width || nh != g_height)) { g_width = nw; g_height = nh; allocate_framebuffer(g_width, g_height); }
            break;
        }
        case KeyPress: { if (g_key_cb) { char buf[32]={0}; KeySym ks=0; Xutf8LookupString(NULL,&ev->xkey,buf,sizeof(buf)-1,&ks,NULL); int mods=0; if(ev->xkey.state&ShiftMask)mods|=1; if(ev->xkey.state&ControlMask)mods|=2; if(ev->xkey.state&Mod1Mask)mods|=4; g_key_cb(ev->xkey.keycode,buf,true,mods); } break; }
        case KeyRelease: { if (g_key_cb) g_key_cb(ev->xkey.keycode,"",false,0); break; }
        case ButtonPress: { if (g_mouse_cb) { int b=ev->xbutton.button; int a=(b==4||b==5)?4:0; g_mouse_cb((float)ev->xbutton.x,(float)ev->xbutton.y,b,a,0); } break; }
        case ButtonRelease: { if (g_mouse_cb) g_mouse_cb((float)ev->xbutton.x,(float)ev->xbutton.y,ev->xbutton.button,1,0); break; }
        case MotionNotify: { if (g_mouse_cb) { int a=((ev->xmotion.state&(Button1Mask|Button2Mask|Button3Mask))!=0)?3:2; g_mouse_cb((float)ev->xmotion.x,(float)ev->xmotion.y,0,a,0); } break; }
        case ClientMessage: {
            if (ev->xclient.format == 32 && (Atom)ev->xclient.data.l[0] == XInternAtom(g_display, "WM_DELETE_WINDOW", False)) exit(0);
            break;
        }
        default: break;
    }
}

void forge_backend_init(void) {
    g_display = XOpenDisplay(NULL);
    if (!g_display) { fprintf(stderr, "forge: cannot open X display\n"); return; }
    load_font();
}

void forge_backend_create_window(const char* title, int width, int height) {
    if (!g_display) return;
    g_width = width; g_height = height;
    int screen = DefaultScreen(g_display);
    g_window = XCreateSimpleWindow(g_display, RootWindow(g_display, screen), 0, 0, width, height, 0, BlackPixel(g_display, screen), BlackPixel(g_display, screen));
    XStoreName(g_display, g_window, title ? title : "Forge");
    XSelectInput(g_display, g_window, ExposureMask|StructureNotifyMask|KeyPressMask|KeyReleaseMask|ButtonPressMask|ButtonReleaseMask|PointerMotionMask);
    Atom wm_delete = XInternAtom(g_display, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(g_display, g_window, &wm_delete, 1);
    g_gc = XCreateGC(g_display, g_window, 0, NULL);
    allocate_framebuffer(width, height);
    XMapWindow(g_display, g_window);
    XFlush(g_display);
}

void forge_backend_set_continuous_rendering(bool enabled) { g_continuous = enabled ? 1 : 0; }
void forge_backend_request_redraw(void) { atomic_fetch_add(&g_redraw_requests, 1); }
void forge_backend_get_render_stats(unsigned long long* rq, unsigned long long* fd) { if (rq) *rq = atomic_load(&g_redraw_requests); if (fd) *fd = atomic_load(&g_frames_drawn); }
void forge_backend_set_render_callback(ForgeRenderCallback cb) { g_render_cb = cb; }
void forge_backend_set_key_callback(ForgeKeyCallback cb) { g_key_cb = cb; }
void forge_backend_set_mouse_callback(ForgeMouseCallback cb) { g_mouse_cb = cb; }
void forge_backend_set_cursor(int type) { (void)type; }

void forge_backend_run(void) {
    if (!g_display) return;
    int pending = 1;
    while (1) {
        while (XPending(g_display)) { XEvent ev; XNextEvent(g_display, &ev); handle_event(&ev); }
        if (pending || g_continuous) {
            for (int i = 0; i < g_width * g_height; i++) g_pixels[i] = 0xFF1E1E1E;
            g_clip_active = 0;
            if (g_render_cb) g_render_cb();
            if (g_shm_attached) { memcpy(g_image->data, g_pixels, (size_t)g_width*g_height*4); XShmPutImage(g_display, g_window, g_gc, g_image, 0, 0, 0, 0, g_width, g_height, False); }
            else if (g_image) XPutImage(g_display, g_window, g_gc, g_image, 0, 0, 0, 0, g_width, g_height);
            XFlush(g_display);
            atomic_fetch_add(&g_frames_drawn, 1);
            pending = 0;
        }
        if (atomic_load(&g_redraw_requests) > 0) { pending = 1; atomic_exchange(&g_redraw_requests, 0); }
        if (!g_continuous) { XEvent ev; XNextEvent(g_display, &ev); handle_event(&ev); pending = 1; }
        else usleep(16000);
    }
}
