#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/Xlocale.h>
#include <X11/extensions/XShm.h>
#ifdef __has_include
  #if __has_include(<X11/extensions/Xdbe.h>)
    #define FORGE_HAS_XDBE 1
    #include <X11/extensions/Xdbe.h>
  #endif
#endif
#include <sys/shm.h>
#include <sys/ipc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <unistd.h>
#include <math.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <fontconfig/fontconfig.h>

#define NANOSVG_IMPLEMENTATION
#include "nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvgrast.h"

/* OpenGL (GLX) for GPU rendering mode — uses desktop OpenGL via GLX.
 * Available on any X11 system with libGL (Mesa). No EGL/GLES needed. */
#ifdef FORGE_HAS_GLX
#include <GL/gl.h>
#include <GL/glx.h>
#endif

#include "../shared/backend.h"

static Display* g_display = NULL;
static Window g_window = 0;
static GC g_gc = NULL;
#ifdef FORGE_HAS_XDBE
static XdbeBackBuffer g_dbe_back_buffer = 0;
static XdbeSwapInfo g_dbe_swap_info;
static int g_dbe_available = 0;
#endif
static XImage* g_image = NULL;
static XShmSegmentInfo g_shm_info;
static int g_shm_attached = 0;
static int g_width = 1024;
static int g_height = 768;
static uint32_t* g_pixels = NULL;

static ForgeRenderCallback g_render_cb = NULL;
static ForgeKeyCallback g_key_cb = NULL;
static ForgeMouseCallback g_mouse_cb = NULL;
static ForgeImeCompositionCallback g_ime_cb = NULL;

/* XIM/XIC — Input Method for international text input (Vietnamese,
 * Chinese, Japanese, Korean, etc.). Without XIC, Xutf8LookupString
 * can't receive composed text from IME. */
static XIM g_xim = NULL;
static XIC g_xic = NULL;
static atomic_ullong g_redraw_requests = 0;
static atomic_ullong g_frames_drawn = 0;
static int g_continuous = 0;

static FT_Library g_ft = NULL;
static FT_Face g_face = NULL;
static FT_Face g_face_bold = NULL; /* Bold variant for headings/UI emphasis */
static pthread_mutex_t g_ft_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_font_family[256] = "sans-serif";
static int g_font_weight = 0;

/* Font fallback chain — when primary face lacks a glyph, try these. */
#define MAX_FALLBACK_FACES 4
static FT_Face g_fallback_faces[MAX_FALLBACK_FACES];
static int g_fallback_count = 0;

/* Glyph cache — avoids re-rendering the same glyph every frame.
 * Keyed by (codepoint, font_size). Stores rendered bitmap + metrics.
 * This is the #1 performance fix: without it, every drawText call
 * re-runs FT_Load_Glyph + FT_Render_Glyph which is extremely slow.
 * Supports both normal (FT_PIXEL_MODE_GRAY) and LCD (FT_PIXEL_MODE_LCD)
 * subpixel rendering modes. */
#define GLYPH_CACHE_SIZE 4096
#define USE_LCD_SUBPIXEL 1  /* 1 = LCD subpixel rendering, 0 = normal AA */
typedef struct {
    unsigned long cp;       /* codepoint, 0 = empty slot */
    unsigned int font_size; /* pixel size */
    unsigned int glyph_index; /* FT_Get_Char_Index result, cached for kerning */
    int bitmap_left;
    int bitmap_top;
    int advance_x;          /* in pixels (already >> 6) */
    unsigned int width;     /* bitmap width (for LCD: 3x logical) */
    unsigned int rows;
    unsigned char* data;    /* owned, malloc'd */
    int is_lcd;             /* 1 if LCD subpixel bitmap, 0 if gray */
} CachedGlyph;
static CachedGlyph g_glyph_cache[GLYPH_CACHE_SIZE];
static int g_glyph_cache_init = 0;

static void init_glyph_cache(void) {
    if (g_glyph_cache_init) return;
    for (int i = 0; i < GLYPH_CACHE_SIZE; i++) {
        g_glyph_cache[i].cp = 0;
        g_glyph_cache[i].data = NULL;
    }
    g_glyph_cache_init = 1;
}

/* Simple hash: cp ^ font_size ^ (cp >> 8) */
static unsigned int glyph_cache_hash(unsigned long cp, unsigned int fs) {
    return (unsigned int)((cp ^ (cp >> 8) ^ (fs * 2654435761u)) % GLYPH_CACHE_SIZE);
}

static CachedGlyph* glyph_cache_lookup(unsigned long cp, unsigned int fs) {
    if (!g_glyph_cache_init) init_glyph_cache();
    unsigned int start = glyph_cache_hash(cp, fs);
    for (int i = 0; i < 8; i++) {
        unsigned int idx = (start + i) % GLYPH_CACHE_SIZE;
        if (g_glyph_cache[idx].cp == cp && g_glyph_cache[idx].font_size == fs) {
            return &g_glyph_cache[idx];
        }
        if (g_glyph_cache[idx].cp == 0) return NULL;
    }
    return NULL;
}

static CachedGlyph* glyph_cache_put(unsigned long cp, unsigned int fs, unsigned int glyph_index, FT_GlyphSlot slot) {
    if (!g_glyph_cache_init) init_glyph_cache();
    unsigned int start = glyph_cache_hash(cp, fs);
    /* Determine if this is an LCD bitmap (width = 3x logical, pixel_mode = LCD) */
    int is_lcd = (slot->bitmap.pixel_mode == FT_PIXEL_MODE_LCD) ? 1 : 0;
    for (int i = 0; i < 8; i++) {
        unsigned int idx = (start + i) % GLYPH_CACHE_SIZE;
        if (g_glyph_cache[idx].cp == 0 || (g_glyph_cache[idx].cp == cp && g_glyph_cache[idx].font_size == fs)) {
            if (g_glyph_cache[idx].data) { free(g_glyph_cache[idx].data); }
            CachedGlyph* g = &g_glyph_cache[idx];
            g->cp = cp;
            g->font_size = fs;
            g->glyph_index = glyph_index;
            g->bitmap_left = slot->bitmap_left;
            g->bitmap_top = slot->bitmap_top;
            g->advance_x = (int)(slot->advance.x >> 6);
            g->width = slot->bitmap.width;
            g->rows = slot->bitmap.rows;
            g->is_lcd = is_lcd;
            size_t sz = (size_t)g->width * g->rows;
            g->data = (unsigned char*)malloc(sz ? sz : 1);
            if (g->data && sz) memcpy(g->data, slot->bitmap.buffer, sz);
            return g;
        }
    }
    /* Cache line full — evict slot at start */
    unsigned int idx = start % GLYPH_CACHE_SIZE;
    if (g_glyph_cache[idx].data) free(g_glyph_cache[idx].data);
    CachedGlyph* g = &g_glyph_cache[idx];
    g->cp = cp;
    g->font_size = fs;
    g->glyph_index = glyph_index;
    g->bitmap_left = slot->bitmap_left;
    g->bitmap_top = slot->bitmap_top;
    g->advance_x = (int)(slot->advance.x >> 6);
    g->width = slot->bitmap.width;
    g->rows = slot->bitmap.rows;
    g->is_lcd = is_lcd;
    size_t sz = (size_t)g->width * g->rows;
    g->data = (unsigned char*)malloc(sz ? sz : 1);
    if (g->data && sz) memcpy(g->data, slot->bitmap.buffer, sz);
    return g;
}

static int g_clip_active = 0;
static int g_clip_x = 0, g_clip_y = 0, g_clip_w = 0, g_clip_h = 0;

/* HiDPI scale factor (1.0 = normal, 2.0 = retina/4K). */
static float g_dpi_scale = 1.0f;

/* Dirty region: when 0, skip full framebuffer clear (panels manage their
 * own regions via clip rect). Set to 1 by Zig when any panel is dirty
 * or on first frame. */
static int g_full_clear_needed = 1;

void forge_backend_set_full_clear(int needed) {
    g_full_clear_needed = needed;
}

/* GPU rendering mode — when enabled, rect rendering uses GLX/OpenGL
 * batched draw calls instead of CPU per-pixel fill. */
#ifdef FORGE_HAS_GLX
static int g_gpu_mode = 0; /* 0=CPU, 1=GPU (GLX/OpenGL) */

/* Forward declarations for GPU init (defined in gpu_glx.c) */
extern int forge_gpu_glx_init(void* x11_display, unsigned long x11_window);
extern void forge_gpu_glx_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a);
extern void forge_gpu_glx_flush(float viewport_w, float viewport_h);
extern void forge_gpu_glx_present(void* x11_display, unsigned long x11_window);
extern void forge_gpu_glx_clear(float r, float g, float b, float a);
extern int forge_gpu_glx_available(void* x11_display);
#else
static int g_gpu_mode = 0; /* Always CPU when GLX not available */
#endif

static void detect_dpi_scale(void) {
    /* Detect DPI from X11 screen and compute scale factor.
     * 96 DPI = 1.0x, 192 DPI = 2.0x (retina). */
    if (!g_display) return;
    int screen = DefaultScreen(g_display);
    int width_mm = DisplayWidthMM(g_display, screen);
    int width_px = DisplayWidth(g_display, screen);
    if (width_mm > 0) {
        double dpi = (double)width_px / (double)width_mm * 25.4;
        if (dpi >= 180) g_dpi_scale = 2.0f;
        else if (dpi >= 140) g_dpi_scale = 1.5f;
        else if (dpi >= 110) g_dpi_scale = 1.25f;
        else g_dpi_scale = 1.0f;
    }
}

/* SVG icon cache — parse + rasterize once, reuse on subsequent draws.
 * Keyed by SVG string pointer (icons are static constants, so pointer
 * identity is stable). Stores rasterized RGBA bitmap at common sizes. */
#define SVG_CACHE_SIZE 256
typedef struct {
    const char* svg_ptr;     /* pointer to SVG string, NULL = empty */
    unsigned int size;        /* rendered size (w=h=size) */
    unsigned char* data;     /* RGBA bitmap, owned */
    unsigned int width;
    unsigned int height;
} CachedSvg;
static CachedSvg g_svg_cache[SVG_CACHE_SIZE];
static int g_svg_cache_init = 0;
static NSVGrasterizer* g_svg_rasterizer = NULL;

static void init_svg_cache(void) {
    if (g_svg_cache_init) return;
    for (int i = 0; i < SVG_CACHE_SIZE; i++) {
        g_svg_cache[i].svg_ptr = NULL;
        g_svg_cache[i].data = NULL;
    }
    g_svg_rasterizer = nsvgCreateRasterizer();
    g_svg_cache_init = 1;
}

/* Hash function for SVG cache: based on pointer + size.
 * Open addressing with 8 probes per slot (same as glyph cache). */
static unsigned int svg_cache_hash(const char* svg_ptr, unsigned int size) {
    /* Knuth multiplicative hash on pointer bits + size */
    uintptr_t ptr_val = (uintptr_t)svg_ptr;
    return (unsigned int)((ptr_val ^ (ptr_val >> 8) ^ (size * 2654435761u)) % SVG_CACHE_SIZE);
}

static CachedSvg* svg_cache_lookup(const char* svg_ptr, unsigned int size) {
    if (!g_svg_cache_init) init_svg_cache();
    unsigned int start = svg_cache_hash(svg_ptr, size);
    for (int i = 0; i < 8; i++) {
        unsigned int idx = (start + i) % SVG_CACHE_SIZE;
        if (g_svg_cache[idx].svg_ptr == svg_ptr && g_svg_cache[idx].size == size) {
            return &g_svg_cache[idx];
        }
        if (g_svg_cache[idx].svg_ptr == NULL) return NULL;
    }
    return NULL;
}

static CachedSvg* svg_cache_put(const char* svg_ptr, unsigned int size, unsigned char* data, unsigned int w, unsigned int h) {
    if (!g_svg_cache_init) init_svg_cache();
    /* Find empty slot or evict */
    for (int i = 0; i < SVG_CACHE_SIZE; i++) {
        if (g_svg_cache[i].svg_ptr == NULL) {
            g_svg_cache[i].svg_ptr = svg_ptr;
            g_svg_cache[i].size = size;
            g_svg_cache[i].data = data;
            g_svg_cache[i].width = w;
            g_svg_cache[i].height = h;
            return &g_svg_cache[i];
        }
    }
    /* Evict slot 0 */
    if (g_svg_cache[0].data) free(g_svg_cache[0].data);
    g_svg_cache[0].svg_ptr = svg_ptr;
    g_svg_cache[0].size = size;
    g_svg_cache[0].data = data;
    g_svg_cache[0].width = w;
    g_svg_cache[0].height = h;
    return &g_svg_cache[0];
}

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
    /* g_pixels is either a plain calloc'd buffer (non-SHM) or a pointer
     * into the SHM segment. When SHM is attached, g_pixels is NOT
     * separately allocated — it points into g_shm_info.shmaddr, so we
     * must NOT call free() on it. The detach below handles SHM cleanup. */
    if (g_pixels && !g_shm_attached) { free(g_pixels); g_pixels = NULL; }
    g_pixels = NULL;
    if (g_image) {
        if (g_shm_attached) { XShmDetach(g_display, &g_shm_info); g_shm_attached = 0; }
        XDestroyImage(g_image); g_image = NULL;
    }
    if (g_shm_info.shmaddr) { shmdt(g_shm_info.shmaddr); g_shm_info.shmaddr = NULL; }

    /* Performance optimization: when XShm is available, we attach the
     * shared memory segment directly to `g_pixels` so the renderer writes
     * straight into the SHM buffer that XShmPutImage reads from. This
     * eliminates the 8MB memcpy per frame that the previous code did
     * (copying from a separate `g_pixels` buffer into `g_image->data`).
     * On a 1920x1080 display that's ~8MB saved per frame = ~480MB/s at
     * 60fps, freeing up significant CPU budget for rendering work.
     *
     * If SHM init fails we fall back to a plain calloc'd buffer and
     * accept the memcpy cost (non-SHM X servers are rare on Linux). */
    g_pixels = NULL; /* Will be set below — either SHM-backed or calloc'd. */

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
                    if (XShmAttach(g_display, &g_shm_info)) {
                        g_shm_attached = 1;
                        /* Point g_pixels at the SHM segment so the
                         * renderer writes directly into the buffer that
                         * XShmPutImage reads from. No per-frame memcpy. */
                        g_pixels = (uint32_t*)g_shm_info.shmaddr;
                        return 1;
                    }
                }
                shmdt(g_shm_info.shmaddr); g_shm_info.shmaddr = NULL;
            }
        }
    }
    g_pixels = (uint32_t*)calloc(width * height, sizeof(uint32_t));
    if (!g_pixels) return 0;
    g_image = XCreateImage(g_display, DefaultVisual(g_display, DefaultScreen(g_display)),
                           24, ZPixmap, 0, (char*)g_pixels, width, height, 32, width * 4);
    return g_image != NULL;
}

static int load_font(void) {
    pthread_mutex_lock(&g_ft_lock);
    /* Clear glyph cache BEFORE freeing faces — cached glyphs hold
     * pointers into the face's glyph slot data, so freeing a face
     * invalidates all cached glyphs that came from it. Must clear
     * the cache first to prevent use-after-free in render_text_run. */
    if (g_glyph_cache_init) {
        for (int i = 0; i < GLYPH_CACHE_SIZE; i++) {
            if (g_glyph_cache[i].data) { free(g_glyph_cache[i].data); g_glyph_cache[i].data = NULL; }
            g_glyph_cache[i].cp = 0;
        }
    }
    /* Initialize FreeType library BEFORE freeing faces. If g_ft is NULL
     * (e.g. first call, or after a previous teardown), calling FT_Done_Face
     * on a stale face pointer will segfault inside FreeType because the
     * library handle it references is invalid. By ensuring g_ft is valid
     * first, FT_Done_Face can safely free the face. */
    if (!g_ft) { if (FT_Init_FreeType(&g_ft) != 0) { pthread_mutex_unlock(&g_ft_lock); return 0; } }
    if (g_face) { FT_Done_Face(g_face); g_face = NULL; }
    if (g_face_bold) { FT_Done_Face(g_face_bold); g_face_bold = NULL; }

    /* Try system fonts first via fontconfig — prefers JetBrains Mono
     * (a programmer font with clear 0/O, 1/l/I distinction) when
     * available, then falls back to bundled DejaVu. This gives users
     * who install JetBrains Mono a nicer editing experience without
     * breaking systems that don't have it. */
    int is_mono = (strstr(g_font_family, "Mono") != NULL || strstr(g_font_family, "mono") != NULL ||
                   strstr(g_font_family, "Menlo") != NULL || strstr(g_font_family, "Consolas") != NULL);

    /* Preferred font families in order — first one that fontconfig
     * finds on the system wins. */
    const char* preferred_mono[] = {
        "JetBrains Mono",
        "Fira Code",
        "Cascadia Code",
        "Source Code Pro",
        "DejaVu Sans Mono",
        "Liberation Mono",
    };
    const char* preferred_sans[] = {
        "Inter",
        "SF Pro Text",
        "Liberation Sans",
        "DejaVu Sans",
    };
    const char** preferred = is_mono ? preferred_mono : preferred_sans;
    const size_t preferred_count = is_mono ? (sizeof(preferred_mono)/sizeof(preferred_mono[0])) : (sizeof(preferred_sans)/sizeof(preferred_sans[0]));

    FcConfig* cfg = FcInitLoadConfigAndFonts();
    int loaded = 0;
    if (cfg) {
        for (size_t fi = 0; fi < preferred_count && !loaded; fi++) {
            FcPattern* fpat = FcPatternCreate();
            FcPatternAddString(fpat, FC_FAMILY, (const FcChar8*)preferred[fi]);
            FcConfigSubstitute(cfg, fpat, FcMatchPattern);
            FcDefaultSubstitute(fpat);
            FcResult fresult;
            FcPattern* fmatch = FcFontMatch(cfg, fpat, &fresult);
            FcChar8* ffile = NULL;
            if (fmatch) FcPatternGetString(fmatch, FC_FILE, 0, &ffile);
            if (ffile) {
                if (FT_New_Face(g_ft, (const char*)ffile, 0, &g_face) == 0) {
                    FT_Select_Charmap(g_face, FT_ENCODING_UNICODE);
                    /* Look for bold variant of same family */
                    FcPatternDestroy(fmatch);
                    FcPatternDestroy(fpat);
                    FcPattern* bpat = FcPatternCreate();
                    FcPatternAddString(bpat, FC_FAMILY, (const FcChar8*)preferred[fi]);
                    FcPatternAddInteger(bpat, FC_WEIGHT, FC_WEIGHT_BOLD);
                    FcConfigSubstitute(cfg, bpat, FcMatchPattern);
                    FcDefaultSubstitute(bpat);
                    FcPattern* bmatch = FcFontMatch(cfg, bpat, &fresult);
                    FcChar8* bfile = NULL;
                    if (bmatch) FcPatternGetString(bmatch, FC_FILE, 0, &bfile);
                    if (g_face_bold) { FT_Done_Face(g_face_bold); g_face_bold = NULL; }
                    if (bfile) FT_New_Face(g_ft, (const char*)bfile, 0, &g_face_bold);
                    if (g_face_bold) FT_Select_Charmap(g_face_bold, FT_ENCODING_UNICODE);
                    if (bmatch) FcPatternDestroy(bmatch);
                    FcPatternDestroy(bpat);
                    loaded = 1;
                }
            }
            if (fmatch) FcPatternDestroy(fmatch);
            if (fpat) FcPatternDestroy(fpat);
        }
    }

    /* Fall back to bundled fonts if no system font matched */
    if (!loaded) {
        const char* bundled_fonts[] = {
            "packages/renderer/assets/fonts/DejaVuSansMono.ttf",
            "packages/renderer/assets/fonts/LiberationSans-Regular.ttf",
        };
        const char* bundled_bold_fonts[] = {
            "packages/renderer/assets/fonts/DejaVuSansMono-Bold.ttf",
            "packages/renderer/assets/fonts/LiberationSans-Bold.ttf",
        };
        const char* bundled = is_mono ? bundled_fonts[0] : bundled_fonts[1];
        const char* bundled_bold = is_mono ? bundled_bold_fonts[0] : bundled_bold_fonts[1];
        if (FT_New_Face(g_ft, bundled, 0, &g_face) == 0) {
            FT_Select_Charmap(g_face, FT_ENCODING_UNICODE);
            if (g_face_bold) { FT_Done_Face(g_face_bold); g_face_bold = NULL; }
            FT_New_Face(g_ft, bundled_bold, 0, &g_face_bold);
            if (g_face_bold) FT_Select_Charmap(g_face_bold, FT_ENCODING_UNICODE);
            loaded = 1;
        }
    }

    if (loaded && cfg) {
        /* Load fallbacks from system fonts for missing glyphs */
        g_fallback_count = 0;
        const char* fallback_families[] = {"DejaVu Sans", "Noto Sans", "Liberation Sans", "DejaVu Sans Mono"};
        for (size_t fi = 0; fi < sizeof(fallback_families)/sizeof(fallback_families[0]) && g_fallback_count < MAX_FALLBACK_FACES; fi++) {
            FcPattern* fpat = FcPatternCreate();
            FcPatternAddString(fpat, FC_FAMILY, (const FcChar8*)fallback_families[fi]);
            FcConfigSubstitute(cfg, fpat, FcMatchPattern);
            FcDefaultSubstitute(fpat);
            FcResult fresult;
            FcPattern* fmatch = FcFontMatch(cfg, fpat, &fresult);
            FcChar8* ffile = NULL;
            if (fmatch) FcPatternGetString(fmatch, FC_FILE, 0, &ffile);
            if (ffile) {
                FT_Face fface = NULL;
                if (FT_New_Face(g_ft, (const char*)ffile, 0, &fface) == 0) {
                    FT_Select_Charmap(fface, FT_ENCODING_UNICODE);
                    g_fallback_faces[g_fallback_count++] = fface;
                }
            }
            if (fmatch) FcPatternDestroy(fmatch);
            FcPatternDestroy(fpat);
        }
        FcConfigDestroy(cfg);
    }

    if (loaded) {
        /* Clear glyph cache */
        if (g_glyph_cache_init) {
            for (int i = 0; i < GLYPH_CACHE_SIZE; i++) {
                if (g_glyph_cache[i].data) { free(g_glyph_cache[i].data); g_glyph_cache[i].data = NULL; }
                g_glyph_cache[i].cp = 0;
            }
        }
        pthread_mutex_unlock(&g_ft_lock);
        return 1;
    }

    /* Last resort: try fontconfig without family preference */
    if (cfg) FcConfigDestroy(cfg);
    FcConfig* cfg2 = FcInitLoadConfigAndFonts();
    if (!cfg2) { pthread_mutex_unlock(&g_ft_lock); return 0; }
    FcPattern* pat = FcPatternCreate();
    FcPatternAddString(pat, FC_FAMILY, (const FcChar8*)g_font_family);
    int fc_weight = FC_WEIGHT_REGULAR;
    switch (g_font_weight) { case 1: fc_weight = FC_WEIGHT_MEDIUM; break; case 2: fc_weight = FC_WEIGHT_DEMIBOLD; break; case 3: fc_weight = FC_WEIGHT_BOLD; break; default: break; }
    FcPatternAddInteger(pat, FC_WEIGHT, fc_weight);
    FcConfigSubstitute(cfg2, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);
    FcResult result;
    FcPattern* match = FcFontMatch(cfg2, pat, &result);
    FcChar8* font_file = NULL;
    if (match) FcPatternGetString(match, FC_FILE, 0, &font_file);
    int ok = 0;
    if (font_file) {
        if (FT_New_Face(g_ft, (const char*)font_file, 0, &g_face) == 0) {
            FT_Select_Charmap(g_face, FT_ENCODING_UNICODE);
            if (g_face_bold) { FT_Done_Face(g_face_bold); g_face_bold = NULL; }
            ok = 1;
        }
    }
    if (match) FcPatternDestroy(match);
    FcPatternDestroy(pat);
    FcConfigDestroy(cfg2);
    if (g_glyph_cache_init) {
        for (int i = 0; i < GLYPH_CACHE_SIZE; i++) {
            if (g_glyph_cache[i].data) { free(g_glyph_cache[i].data); g_glyph_cache[i].data = NULL; }
            g_glyph_cache[i].cp = 0;
        }
    }
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
    /* GPU mode: batch rect for GLX/OpenGL draw call (flush at end of frame) */
#ifdef FORGE_HAS_GLX
    if (g_gpu_mode) {
        forge_gpu_glx_draw_rect(xf, yf, wf, hf, r, g, b, a);
        return;
    }
#endif
    /* Fast path: opaque fill — use memset-style fill for maximum speed.
     * The inner loop writes 32-bit pixels; we unroll by 4 to give the
     * compiler a better chance to vectorize with SSE/AVX. On 1080p
     * full-screen fills this saves ~1ms vs the naive per-pixel write. */
    if (a >= 0.999f) {
        int x0 = (int)xf; if (x0 < 0) x0 = 0;
        int y0 = (int)yf; if (y0 < 0) y0 = 0;
        int x1 = (int)(xf + wf); if (x1 > g_width) x1 = g_width;
        int y1 = (int)(yf + hf); if (y1 > g_height) y1 = g_height;
        if (x0 >= x1 || y0 >= y1) return;
        uint32_t color = ((uint32_t)255 << 24) | ((uint32_t)(r*255+0.5f) << 16) | ((uint32_t)(g*255+0.5f) << 8) | (uint32_t)(b*255+0.5f);
        int count = x1 - x0;
        for (int y = y0; y < y1; y++) {
            uint32_t* row = &g_pixels[(size_t)y * g_width + x0];
            int x = 0;
            /* Unrolled fill — 4 pixels per iteration. The compiler will
             * emit SIMD stores (movdqu/movaps) when targeting SSE2+. */
            for (; x + 4 <= count; x += 4) {
                row[x] = color;
                row[x + 1] = color;
                row[x + 2] = color;
                row[x + 3] = color;
            }
            for (; x < count; x++) row[x] = color;
        }
        return;
    }
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

    /* Pre-compute clip rect bounds for direct framebuffer writes. */
    int clip_x0 = 0, clip_y0 = 0, clip_x1 = g_width, clip_y1 = g_height;
    if (g_clip_active) {
        clip_x0 = g_clip_x; clip_y0 = g_clip_y;
        clip_x1 = g_clip_x + g_clip_w; clip_y1 = g_clip_y + g_clip_h;
    }
    /* Clamp rect to clip rect. */
    if (x0 < clip_x0) x0 = clip_x0;
    if (y0 < clip_y0) y0 = clip_y0;
    if (x1 > clip_x1) x1 = clip_x1;
    if (y1 > clip_y1) y1 = clip_y1;
    if (x0 >= x1 || y0 >= y1) return;

    /* Optimization: split the rounded rect into 5 regions:
     *   - 4 corner regions (rad x rad each) — per-pixel circle test
     *   - 1 inner region (the cross/plus shape) — fast row fill
     * This avoids the per-pixel circle test for the majority of pixels.
     * For a 400x300 rounded rect with rad=8, the corners are 8x8=64px
     * each (256px total) vs 120,000px for the full rect — 468x fewer
     * per-pixel iterations. */

    /* Inner fill: rows that span the full width (y0+rad to y1-rad-1)
     * and the center columns of the top/bottom corner rows. */
    int inner_x0 = x0 + rad;
    int inner_x1 = x1 - rad;
    if (inner_x0 > inner_x1) inner_x0 = x0; /* rect too narrow for corners */

    /* Fast fill the center band (full width, no corners). */
    int center_y0 = y0 + rad;
    int center_y1 = y1 - rad;
    if (center_y0 < y0) center_y0 = y0;
    if (center_y1 > y1) center_y1 = y1;
    if (center_y0 < center_y1 && inner_x1 > inner_x0) {
        int fill_count = inner_x1 - inner_x0;
        for (int y = center_y0; y < center_y1; y++) {
            uint32_t* row = &g_pixels[(size_t)y * g_width + inner_x0];
            int x = 0;
            for (; x + 4 <= fill_count; x += 4) {
                row[x] = color; row[x+1] = color; row[x+2] = color; row[x+3] = color;
            }
            for (; x < fill_count; x++) row[x] = color;
        }
    }

    /* Fill the left and right strips of the top and bottom corner rows
     * (the parts of the corner rows that are NOT in the corner circle). */
    if (center_y0 > y0) {
        /* Top corner rows: y0 to center_y0-1 */
        for (int y = y0; y < center_y0; y++) {
            uint32_t* row = &g_pixels[(size_t)y * g_width];
            /* Left strip: x0 to inner_x0-1 (only the non-corner part) */
            /* Right strip: inner_x1 to x1-1 (only the non-corner part) */
            /* For these rows, the full width between inner_x0 and inner_x1
             * is interior, so fill that. */
            if (inner_x1 > inner_x0) {
                int fill_count = inner_x1 - inner_x0;
                for (int x = 0; x < fill_count; x++) row[inner_x0 + x] = color;
            }
        }
    }
    if (center_y1 < y1) {
        /* Bottom corner rows: center_y1 to y1-1 */
        for (int y = center_y1; y < y1; y++) {
            uint32_t* row = &g_pixels[(size_t)y * g_width];
            if (inner_x1 > inner_x0) {
                int fill_count = inner_x1 - inner_x0;
                for (int x = 0; x < fill_count; x++) row[inner_x0 + x] = color;
            }
        }
    }

    /* Now handle the 4 corner regions with the per-pixel circle test.
     * Only iterate the corner pixels — much fewer than the full rect. */

    /* Top-left corner: center at (x0+rad, y0+rad) */
    for (int y = y0; y < y0 + rad && y < center_y0; y++) {
        uint32_t* row = &g_pixels[(size_t)y * g_width];
        for (int x = x0; x < x0 + rad && x < inner_x0; x++) {
            int dx = x0 + rad - x;
            int dy = y0 + rad - y;
            if (dx > 0 && dy > 0 && dx * dx + dy * dy > rad * rad) continue;
            row[x] = color;
        }
    }
    /* Top-right corner: center at (x1-rad-1, y0+rad) */
    for (int y = y0; y < y0 + rad && y < center_y0; y++) {
        uint32_t* row = &g_pixels[(size_t)y * g_width];
        for (int x = inner_x1; x < x1; x++) {
            int dx = x - (x1 - rad - 1);
            int dy = y0 + rad - y;
            if (dx > 0 && dy > 0 && dx * dx + dy * dy > rad * rad) continue;
            row[x] = color;
        }
    }
    /* Bottom-left corner: center at (x0+rad, y1-rad-1) */
    for (int y = center_y1; y < y1; y++) {
        uint32_t* row = &g_pixels[(size_t)y * g_width];
        for (int x = x0; x < x0 + rad && x < inner_x0; x++) {
            int dx = x0 + rad - x;
            int dy = y - (y1 - rad - 1);
            if (dx > 0 && dy > 0 && dx * dx + dy * dy > rad * rad) continue;
            row[x] = color;
        }
    }
    /* Bottom-right corner: center at (x1-rad-1, y1-rad-1) */
    for (int y = center_y1; y < y1; y++) {
        uint32_t* row = &g_pixels[(size_t)y * g_width];
        for (int x = inner_x1; x < x1; x++) {
            int dx = x - (x1 - rad - 1);
            int dy = y - (y1 - rad - 1);
            if (dx > 0 && dy > 0 && dx * dx + dy * dy > rad * rad) continue;
            row[x] = color;
        }
    }
}

/* Gamma correction lookup table — corrects alpha for sRGB display.
 * Without gamma correction, text at small sizes looks too thin/faint.
 * gamma 2.2: alpha_corrected = pow(alpha, 1/2.2) ≈ sqrt(alpha). */
static float gamma_correct(float alpha) {
    /* Approximate sRGB gamma: linear → sRGB */
    if (alpha <= 0.0031308f) return 12.92f * alpha;
    return 1.055f * powf(alpha, 1.0f / 2.2f) - 0.055f;
}

static void draw_glyph_bitmap(FT_Bitmap* bitmap, int dx, int dy, float r, float g, float b, float a) {
    uint8_t R = (uint8_t)(r*255), G = (uint8_t)(g*255), B = (uint8_t)(b*255);
    /* Pre-compute clip rect bounds — same optimization as draw_glyph_lcd. */
    int clip_x0 = 0, clip_y0 = 0, clip_x1 = g_width, clip_y1 = g_height;
    if (g_clip_active) {
        clip_x0 = g_clip_x;
        clip_y0 = g_clip_y;
        clip_x1 = g_clip_x + g_clip_w;
        clip_y1 = g_clip_y + g_clip_h;
    }
    for (unsigned int y = 0; y < bitmap->rows; y++) {
        int py = dy + (int)y;
        if (py < clip_y0 || py >= clip_y1) continue; /* row outside clip */
        uint32_t* row = &g_pixels[(size_t)py * g_width];
        size_t bmp_idx = (size_t)y * bitmap->pitch;
        for (unsigned int x = 0; x < bitmap->width; x++) {
            int px = dx + (int)x;
            if (px < clip_x0 || px >= clip_x1) continue; /* pixel outside clip */
            uint8_t ga = bitmap->buffer[bmp_idx + x];
            if (ga == 0) continue;
            float alpha = (ga / 255.0f) * a;
            /* Apply gamma correction for smoother text rendering */
            alpha = gamma_correct(alpha);
            uint32_t* dst = &row[px];
            uint8_t dr = (uint8_t)(*dst >> 16);
            uint8_t dg = (uint8_t)(*dst >> 8);
            uint8_t db = (uint8_t)(*dst);
            uint8_t nr = (uint8_t)(R * alpha + dr * (1 - alpha));
            uint8_t ng = (uint8_t)(G * alpha + dg * (1 - alpha));
            uint8_t nb = (uint8_t)(B * alpha + db * (1 - alpha));
            *dst = (uint32_t)255 << 24 | (uint32_t)nr << 16 | (uint32_t)ng << 8 | (uint32_t)nb;
        }
    }
}

/* LCD subpixel rendering — uses FT_LOAD_TARGET_LCD which renders
 * 3 separate alpha values per pixel (R, G, B subpixels). This gives
 * 3x horizontal resolution for text, making it crisper on LCD screens.
 * The glyph bitmap width is 3x the logical width.
 *
 * Performance: row-level clip check (skip rows outside the clip rect
 * entirely) plus a single bounds-checked write per pixel. The previous
 * version called in_clip() per subpixel AND put_pixel() which both
 * checked clipping — double the overhead. This version inlines the
 * bounds check and uses direct framebuffer writes. */
static void draw_glyph_lcd(FT_Bitmap* bitmap, int dx, int dy, float r, float g, float b, float a) {
    uint8_t R = (uint8_t)(r*255), G = (uint8_t)(g*255), B = (uint8_t)(b*255);
    /* LCD bitmaps have width = 3 * logical_width, pixel_mode = FT_PIXEL_MODE_LCD */
    unsigned int logical_width = bitmap->width / 3;
    /* Pre-compute the clip rect bounds so we can skip rows entirely
     * without calling in_clip() per pixel. */
    int clip_x0 = 0, clip_y0 = 0, clip_x1 = g_width, clip_y1 = g_height;
    if (g_clip_active) {
        clip_x0 = g_clip_x;
        clip_y0 = g_clip_y;
        clip_x1 = g_clip_x + g_clip_w;
        clip_y1 = g_clip_y + g_clip_h;
    }
    for (unsigned int y = 0; y < bitmap->rows; y++) {
        int py = dy + (int)y;
        if (py < clip_y0 || py >= clip_y1) continue; /* row outside clip */
        uint32_t* row = &g_pixels[(size_t)py * g_width];
        size_t bmp_idx = (size_t)y * bitmap->pitch;
        for (unsigned int x = 0; x < logical_width; x++) {
            int px = dx + (int)x;
            if (px < clip_x0 || px >= clip_x1) continue; /* pixel outside clip */
            /* 3 bytes per logical pixel: R, G, B subpixel coverage */
            uint8_t sr = bitmap->buffer[bmp_idx + x * 3];
            uint8_t sg = bitmap->buffer[bmp_idx + x * 3 + 1];
            uint8_t sb = bitmap->buffer[bmp_idx + x * 3 + 2];
            if (sr == 0 && sg == 0 && sb == 0) continue;
            /* Blend each subpixel channel independently for crisp text */
            uint32_t* dst = &row[px];
            uint8_t dr = (uint8_t)(*dst >> 16);
            uint8_t dg = (uint8_t)(*dst >> 8);
            uint8_t db = (uint8_t)(*dst);
            float ar = (sr / 255.0f) * a;
            float ag = (sg / 255.0f) * a;
            float ab = (sb / 255.0f) * a;
            uint8_t nr = (uint8_t)(R * ar + dr * (1 - ar));
            uint8_t ng = (uint8_t)(G * ag + dg * (1 - ag));
            uint8_t nb = (uint8_t)(B * ab + db * (1 - ab));
            *dst = (uint32_t)255 << 24 | (uint32_t)nr << 16 | (uint32_t)ng << 8 | (uint32_t)nb;
        }
    }
}

static void render_text_run(const char* text, size_t len, float x, float y, float font_size, float r, float g, float b, float a) {
    if (len == 0 || !g_face) return;
    pthread_mutex_lock(&g_ft_lock);
    unsigned int fs_px = (unsigned int)(font_size + 0.5f);
    /* Skip FT_Set_Pixel_Sizes if the size hasn't changed. FT_Set_Pixel_Sizes
     * recomputes the face's size metrics every call — calling it on every
     * render_text_run (one per visible text span) is expensive. Cache the
     * last-set size and skip if unchanged. Typical frames use 1-3 distinct
     * font sizes (editor body, gutter numbers, status bar). */
    static unsigned int s_last_fs_px = 0;
    static FT_Face s_last_face = NULL;
    if (fs_px != s_last_fs_px || g_face != s_last_face) {
        FT_Set_Pixel_Sizes(g_face, 0, fs_px);
        s_last_fs_px = fs_px;
        s_last_face = g_face;
    }
    float pen_x = x;
    float pen_y = y + (g_face->size->metrics.ascender >> 6);
    FT_UInt prev_gi = 0;
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

        /* Glyph cache lookup FIRST — avoids FT_Get_Char_Index on every
         * character. FT_Get_Char_Index does a charmap lookup which is
         * O(log n) in the cmap table; calling it per-character × per-frame
         * is expensive when the glyph is already cached. The cache stores
         * the rendered bitmap + advance, so if we hit we can skip both
         * FT_Get_Char_Index AND FT_Load_Glyph. */
        CachedGlyph* cg = glyph_cache_lookup(cp, fs_px);
        FT_Face draw_face = g_face;
        FT_UInt gi = 0;
        if (cg) {
            gi = cg->glyph_index; /* cached glyph index */
        } else {
            /* Cache miss — must call FT_Get_Char_Index and possibly load
             * fallback faces. */
            gi = FT_Get_Char_Index(g_face, cp);
            if (gi == 0) {
                /* Try fallback faces (monospace, sans-serif default) */
                for (int fi = 0; fi < g_fallback_count; fi++) {
                    FT_UInt alt_gi = FT_Get_Char_Index(g_fallback_faces[fi], cp);
                    if (alt_gi != 0) {
                        draw_face = g_fallback_faces[fi];
                        gi = alt_gi;
                        if (fs_px != s_last_fs_px || draw_face != s_last_face) {
                            FT_Set_Pixel_Sizes(draw_face, 0, fs_px);
                            s_last_fs_px = fs_px;
                            s_last_face = draw_face;
                        }
                        break;
                    }
                }
            }
            /* Load + cache the glyph. */
            FT_Int32 load_flags = FT_LOAD_RENDER | FT_LOAD_FORCE_AUTOHINT;
#if USE_LCD_SUBPIXEL
            load_flags = FT_LOAD_RENDER | FT_LOAD_FORCE_AUTOHINT | FT_LOAD_TARGET_LCD;
#endif
            if (FT_Load_Glyph(draw_face, gi, load_flags) == 0) {
                cg = glyph_cache_put(cp, fs_px, gi, draw_face->glyph);
            }
        }
        if (!cg) continue;

        /* Kerning: apply kerning delta between prev glyph and current.
         * Only call FT_Get_Kerning when we have a previous glyph (saves
         * a function call on the first character of every run). */
        if (prev_gi != 0 && FT_HAS_KERNING(draw_face)) {
            FT_Vector delta;
            if (FT_Get_Kerning(draw_face, prev_gi, gi, FT_KERNING_DEFAULT, &delta) == 0) {
                pen_x += (float)(delta.x >> 6);
            }
        }
        prev_gi = gi;

        /* Draw from cached bitmap — use LCD or gray renderer based on cache entry */
        if (cg->data && cg->width > 0 && cg->rows > 0) {
            FT_Bitmap tmp_bm;
            tmp_bm.rows = cg->rows;
            tmp_bm.width = cg->width;
            tmp_bm.pitch = (int)cg->width;
            tmp_bm.buffer = cg->data;
            if (cg->is_lcd) {
                tmp_bm.pixel_mode = FT_PIXEL_MODE_LCD;
                draw_glyph_lcd(&tmp_bm, (int)pen_x + cg->bitmap_left, (int)pen_y - cg->bitmap_top, r, g, b, a);
            } else {
                tmp_bm.pixel_mode = FT_PIXEL_MODE_GRAY;
                draw_glyph_bitmap(&tmp_bm, (int)pen_x + cg->bitmap_left, (int)pen_y - cg->bitmap_top, r, g, b, a);
            }
        }
        pen_x += (float)cg->advance_x;
    }
    pthread_mutex_unlock(&g_ft_lock);
}

void forge_backend_draw_text_len(const char* text, size_t len, float x, float y, float fs, float r, float g, float b, float a) {
    if (text && len > 0) render_text_run(text, len, x, y, fs, r, g, b, a);
}

void forge_backend_draw_text_len_style(const char* text, size_t len, float x, float y, float fs, int role, int weight, float r, float g, float b, float a) {
    (void)role;
    /* weight: 0=regular, 1=medium, 2=semibold, 3=bold.
     * Use bold face for weight >= 2 if available. */
    if (weight >= 2 && g_face_bold) {
        /* Swap primary face to bold temporarily for this render */
        FT_Face saved = g_face;
        g_face = g_face_bold;
        render_text_run(text, len, x, y, fs, r, g, b, a);
        g_face = saved;
    } else {
        forge_backend_draw_text_len(text, len, x, y, fs, r, g, b, a);
    }
}

void forge_backend_draw_styled_text(const char* text, size_t len, float x, float y, float fs, const ForgeTextSpan* spans, size_t n) {
    if (!text || len == 0) return;
    if (n == 0) { forge_backend_draw_text_len(text, len, x, y, fs, 1, 1, 1, 1); return; }
    /* Optimization: track pen position across spans instead of measuring
     * from the start of the text for every span. The previous code called
     * forge_backend_measure_text_width(text, spans[i].offset, fs) per span,
     * which re-measures from byte 0 each time — O(n²) per line where n is
     * the number of spans. For a 96-span line that's 96 full measures.
     *
     * New approach: advance the pen by the gap width (measured once per
     * gap) and the span width (measured once per span). Each span now
     * costs exactly 1 measure + 1 draw, not 2 measures + 1 draw. */
    float pen_x = x;
    size_t prev_end = 0;
    for (size_t i = 0; i < n; i++) {
        if (spans[i].offset >= len) continue;
        size_t end = spans[i].offset + spans[i].length; if (end > len) end = len;
        if (end <= spans[i].offset) continue;
        /* Measure gap from prev_end to this span's start. */
        if (spans[i].offset > prev_end) {
            pen_x += forge_backend_measure_text_width(text + prev_end, spans[i].offset - prev_end, fs);
        }
        /* Draw span text at current pen position. */
        forge_backend_draw_text_len(text + spans[i].offset, end - spans[i].offset, pen_x, y, fs, spans[i].r, spans[i].g, spans[i].b, spans[i].a);
        /* Advance pen by span width — measured once. */
        pen_x += forge_backend_measure_text_width(text + spans[i].offset, end - spans[i].offset, fs);
        prev_end = end;
    }
}

void forge_backend_draw_svg(const char* svg, float x, float y, float w, float h, float angle, float r, float g, float b, float a) {
    (void)angle;
    if (!svg || w <= 0 || h <= 0) return;

    /* Render SVG at target size, cache by (svg_ptr, size). */
    unsigned int render_size = (unsigned int)(w > h ? w : h);
    if (render_size < 8) render_size = 8;
    if (render_size > 256) render_size = 256;

    CachedSvg* cv = svg_cache_lookup(svg, render_size);
    if (!cv) {
        /* Parse + rasterize. nsvgParse modifies the input string, so copy it. */
        size_t svg_len = strlen(svg);
        char* svg_copy = (char*)malloc(svg_len + 1);
        if (!svg_copy) return;
        memcpy(svg_copy, svg, svg_len + 1);

        NSVGimage* image = nsvgParse(svg_copy, "px", 96.0f);
        if (!image) { free(svg_copy); return; }

        /* Override shapes: for stroke-based icons (forge_icons), set stroke
         * to white and keep stroke width. For fill-based icons, fill white. */
        for (NSVGshape* shape = image->shapes; shape != NULL; shape = shape->next) {
            if (shape->fill.type == NSVG_PAINT_NONE) {
                /* Stroke-only icon: colorize stroke */
                shape->stroke.type = NSVG_PAINT_COLOR;
                shape->stroke.color = 0xFFFFFFFF;
            } else {
                /* Fill-based icon: fill white */
                shape->fill.type = NSVG_PAINT_COLOR;
                shape->fill.color = 0xFFFFFFFF;
                shape->stroke.type = NSVG_PAINT_NONE;
            }
        }

        unsigned int rw = render_size;
        unsigned int rh = render_size;
        unsigned char* img = (unsigned char*)malloc((size_t)rw * rh * 4);
        if (!img) { free(svg_copy); nsvgDelete(image); return; }

        if (!g_svg_rasterizer) init_svg_cache();
        if (g_svg_rasterizer) {
            /* Scale SVG to fit render_size. nanosvg uses 0,0 origin. */
            float scale = render_size / image->width;
            if (image->height > image->width) scale = render_size / image->height;
            nsvgRasterize(g_svg_rasterizer, image, 0, 0, scale, img, rw, rh, rw * 4);
        }
        nsvgDelete(image);
        free(svg_copy);

        cv = svg_cache_put(svg, render_size, img, rw, rh);
        if (!cv) { free(img); return; }
    }

    /* Tint + alpha-blend the cached RGBA bitmap into the framebuffer.
     * The SVG is rendered white (default fill); we tint with (r,g,b). */
    if (!cv->data) return;
    uint8_t R = (uint8_t)(r * 255.0f + 0.5f);
    uint8_t G = (uint8_t)(g * 255.0f + 0.5f);
    uint8_t B = (uint8_t)(b * 255.0f + 0.5f);

    /* Center the icon in the target rect (w x h). */
    float draw_x = x + (w - (float)cv->width) * 0.5f;
    float draw_y = y + (h - (float)cv->height) * 0.5f;

    for (unsigned int py = 0; py < cv->height; py++) {
        int dst_y = (int)(draw_y + py);
        if (dst_y < 0 || dst_y >= g_height) continue;
        for (unsigned int px = 0; px < cv->width; px++) {
            int dst_x = (int)(draw_x + px);
            if (dst_x < 0 || dst_x >= g_width) continue;
            if (!in_clip(dst_x, dst_y)) continue;
            size_t idx = ((size_t)py * cv->width + px) * 4;
            /* SVG RGBA: use alpha channel, tint with color */
            uint8_t sa = cv->data[idx + 3];
            if (sa == 0) continue;
            float alpha = (sa / 255.0f) * a;
            uint32_t premul = ((uint32_t)(alpha * 255) << 24) |
                              ((uint32_t)(R * alpha) << 16) |
                              ((uint32_t)(G * alpha) << 8) |
                              (uint32_t)(B * alpha);
            uint32_t* dst = &g_pixels[(size_t)dst_y * g_width + dst_x];
            *dst = blend_pixel(*dst, premul);
        }
    }
}

float forge_backend_measure_text_width(const char* text, size_t len, float font_size) {
    if (!text || len == 0 || !g_face) return 0.0f;
    pthread_mutex_lock(&g_ft_lock);
    unsigned int fs_px = (unsigned int)(font_size + 0.5f);
    /* Skip FT_Set_Pixel_Sizes if unchanged — same optimization as
     * render_text_run. measure is called 2× per text span (gap + span
     * width), so skipping the size setup saves significant CPU on
     * text-heavy frames. */
    static unsigned int s_last_fs_px = 0;
    static FT_Face s_last_face = NULL;
    if (fs_px != s_last_fs_px || g_face != s_last_face) {
        FT_Set_Pixel_Sizes(g_face, 0, fs_px);
        s_last_fs_px = fs_px;
        s_last_face = g_face;
    }
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
        /* Use glyph cache for advance width — avoids FT_Load_Glyph on measure */
        CachedGlyph* cg = glyph_cache_lookup(cp, fs_px);
        if (cg) {
            width += (float)cg->advance_x;
        } else {
            FT_UInt gi = FT_Get_Char_Index(g_face, cp);
            if (FT_Load_Glyph(g_face, gi, FT_LOAD_DEFAULT) != 0) continue;
            width += (float)(g_face->glyph->advance.x >> 6);
        }
    }
    pthread_mutex_unlock(&g_ft_lock);
    return width;
}

float forge_backend_measure_text_width_style(const char* text, size_t len, float font_size, int role, int weight) {
    (void)role;
    (void)weight;
    return forge_backend_measure_text_width(text, len, font_size);
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
float forge_backend_get_dpi_scale(void) { return g_dpi_scale; }
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

/* Clipboard support — X11 CLIPBOARD selection.
 *
 * We take ownership of the CLIPBOARD selection and store the text in a
 * malloc'd buffer. When another client requests the selection (via
 * SelectionRequest event), we respond with the stored text. This is
 * the standard X11 clipboard mechanism.
 *
 * We also fall back to XChangeProperty with XA_CUT_BUFFER0 for clients
 * that read from cut buffers (older xterm-based workflows).
 *
 * PASTE: X11 clipboard reads are async — we request the selection, then
 * the actual text arrives via SelectionNotify. We store it in
 * g_pending_paste and the next call to forge_backend_get_clipboard_text
 * returns it. This means paste works on the second call (first call
 * triggers the request, second call reads the result). */
static char* g_clipboard_text = NULL;
static size_t g_clipboard_len = 0;
static Atom g_clipboard_atom = 0;
static Atom g_targets_atom = 0;
static Atom g_utf8_string_atom = 0;
static Atom g_xsel_data_atom = 0;
/* Pending paste text — filled by SelectionNotify, consumed by
 * forge_backend_get_clipboard_text. */
static char* g_pending_paste = NULL;
static size_t g_pending_paste_len = 0;
static int g_paste_requested = 0;

static void init_clipboard_atoms(void) {
    if (g_clipboard_atom) return;
    if (!g_display) return;
    g_clipboard_atom = XInternAtom(g_display, "CLIPBOARD", False);
    g_targets_atom = XInternAtom(g_display, "TARGETS", False);
    g_utf8_string_atom = XInternAtom(g_display, "UTF8_STRING", False);
    g_xsel_data_atom = XInternAtom(g_display, "XSEL_DATA", False);
}

void forge_backend_set_clipboard_text(const char* text, size_t len) {
    if (!g_display) return;
    init_clipboard_atoms();
    /* Free previous clipboard text */
    if (g_clipboard_text) { free(g_clipboard_text); g_clipboard_text = NULL; g_clipboard_len = 0; }
    /* Store new text */
    if (len > 0 && text) {
        g_clipboard_text = (char*)malloc(len + 1);
        if (!g_clipboard_text) return;
        memcpy(g_clipboard_text, text, len);
        g_clipboard_text[len] = 0;
        g_clipboard_len = len;
        /* Take ownership of the CLIPBOARD selection */
        XSetSelectionOwner(g_display, g_clipboard_atom, g_window, CurrentTime);
        /* Also set the primary selection (middle-click paste) */
        XSetSelectionOwner(g_display, XA_PRIMARY, g_window, CurrentTime);
        /* And stash in CUT_BUFFER0 for legacy clients */
        XChangeProperty(g_display, RootWindow(g_display, DefaultScreen(g_display)),
                        XA_CUT_BUFFER0, XA_STRING, 8, PropModeReplace,
                        (const unsigned char*)text, (int)len);
    }
}

size_t forge_backend_get_clipboard_text(char* out, size_t cap) {
    if (!g_display || !out || cap == 0) return 0;
    init_clipboard_atoms();
    /* If we have pending paste text from a previous SelectionNotify,
     * consume and return it. */
    if (g_pending_paste && g_pending_paste_len > 0) {
        size_t n = (g_pending_paste_len < cap - 1) ? g_pending_paste_len : cap - 1;
        memcpy(out, g_pending_paste, n);
        out[n] = 0;
        free(g_pending_paste);
        g_pending_paste = NULL;
        g_pending_paste_len = 0;
        g_paste_requested = 0;
        return n;
    }
    /* If we own the selection, return our stored text directly */
    if (g_clipboard_text && g_clipboard_len > 0) {
        size_t n = (g_clipboard_len < cap - 1) ? g_clipboard_len : cap - 1;
        memcpy(out, g_clipboard_text, n);
        out[n] = 0;
        return n;
    }
    /* Otherwise request the selection from the current owner. The text
     * will arrive via SelectionNotify and be stored in g_pending_paste.
     * Caller should retry on the next tick. */
    if (!g_paste_requested) {
        Window owner = XGetSelectionOwner(g_display, g_clipboard_atom);
        if (owner == None) owner = XGetSelectionOwner(g_display, XA_PRIMARY);
        if (owner != None && owner != g_window) {
            XConvertSelection(g_display, g_clipboard_atom, g_utf8_string_atom,
                              g_xsel_data_atom, g_window, CurrentTime);
            XFlush(g_display);
            g_paste_requested = 1;
        }
    }
    return 0;
}
int forge_backend_save_clipboard_png(const char* path) { (void)path; return 0; }

static void handle_event(XEvent* ev) {
    switch (ev->type) {
        case ConfigureNotify: {
            int nw = ev->xconfigure.width, nh = ev->xconfigure.height;
            if (nw > 0 && nh > 0 && (nw != g_width || nh != g_height)) { g_width = nw; g_height = nh; allocate_framebuffer(g_width, g_height); }
            break;
        }
        case KeyPress: {
            if (!g_key_cb) break;
            /* XFilterEvent must be called BEFORE processing the event.
             * If it returns True, the IME consumed the event (e.g. IME
             * is composing a character) and we should NOT dispatch it
             * as a regular key press. XFilterEvent is called in the
             * main event loop below, but we also handle it here for
             * the KeyPress case specifically. */
            char buf[64] = {0};
            KeySym ks = 0;
            int mods = 0;
            if (ev->xkey.state & ShiftMask) mods |= 1;
            if (ev->xkey.state & ControlMask) mods |= 2;
            if (ev->xkey.state & Mod1Mask) mods |= 4;

            /* Use XIC if available (IME support). XmbLookupString
             * returns composed text from the IME. Without XIC, fall
             * back to Xutf8LookupString with NULL (raw key codes only). */
            if (g_xic) {
                Status status = 0;
                int len = XmbLookupString(g_xic, &ev->xkey, buf, sizeof(buf) - 1, &ks, &status);
                if (status == XBufferOverflow) {
                    /* Buffer too small — retry with larger buffer. */
                    /* For simplicity, skip this event. */
                    break;
                }
                if (status == XLookupChars || status == XLookupBoth) {
                    /* Got composed text (IME input). */
                    buf[len] = 0;
                    g_key_cb(ev->xkey.keycode, buf, 1, mods);
                    break;
                }
                if (status == XLookupKeySym) {
                    /* IME is composing — don't dispatch as regular key. */
                    break;
                }
                /* XLookupNone — no useful data, but still dispatch keycode. */
                g_key_cb(ev->xkey.keycode, "", 1, mods);
            } else {
                /* No XIC — raw keyboard mapping only (no IME). */
                Xutf8LookupString(NULL, &ev->xkey, buf, sizeof(buf) - 1, &ks, NULL);
                g_key_cb(ev->xkey.keycode, buf, 1, mods);
            }
            break;
        }
        case KeyRelease: { if (g_key_cb) g_key_cb(ev->xkey.keycode,"",false,0); break; }
        case ButtonPress: { if (g_mouse_cb) { int b=ev->xbutton.button; int a=(b==4||b==5)?4:0; g_mouse_cb((float)ev->xbutton.x,(float)ev->xbutton.y,b,a,0,a==0?1:0); } break; }
        case ButtonRelease: { if (g_mouse_cb) g_mouse_cb((float)ev->xbutton.x,(float)ev->xbutton.y,ev->xbutton.button,1,0,0); break; }
        case MotionNotify: { if (g_mouse_cb) { int a=((ev->xmotion.state&(Button1Mask|Button2Mask|Button3Mask))!=0)?3:2; g_mouse_cb((float)ev->xmotion.x,(float)ev->xmotion.y,0,a,0,0); } break; }
        case SelectionRequest: {
            /* Another client is requesting our clipboard content. Respond
             * with the stored text (or TARGETS list when asked). */
            if (g_clipboard_text && g_clipboard_len > 0) {
                XSelectionEvent sev = {0};
                sev.type = SelectionNotify;
                sev.display = g_display;
                sev.requestor = ev->xselectionrequest.requestor;
                sev.selection = ev->xselectionrequest.selection;
                sev.target = ev->xselectionrequest.target;
                sev.property = ev->xselectionrequest.property;
                sev.time = ev->xselectionrequest.time;
                if (ev->xselectionrequest.target == g_targets_atom) {
                    /* Advertise supported targets */
                    Atom targets[2] = { g_targets_atom, g_utf8_string_atom };
                    XChangeProperty(g_display, sev.requestor, sev.property, XA_ATOM, 32,
                                    PropModeReplace, (unsigned char*)targets, 2);
                } else if (ev->xselectionrequest.target == g_utf8_string_atom ||
                           ev->xselectionrequest.target == XA_STRING) {
                    XChangeProperty(g_display, sev.requestor, sev.property, g_utf8_string_atom, 8,
                                    PropModeReplace, (unsigned char*)g_clipboard_text, (int)g_clipboard_len);
                } else {
                    /* Unsupported target — refuse by setting property to None */
                    sev.property = None;
                }
                XSendEvent(g_display, sev.requestor, False, 0, (XEvent*)&sev);
                XFlush(g_display);
            }
            break;
        }
        case SelectionClear: {
            /* Another client took ownership — free our copy */
            if (g_clipboard_text) { free(g_clipboard_text); g_clipboard_text = NULL; g_clipboard_len = 0; }
            break;
        }
        case SelectionNotify: {
            /* Response to our XConvertSelection request — the selection
             * owner has placed the text in our g_xsel_data_atom property.
             * Read it into g_pending_paste so the next
             * forge_backend_get_clipboard_text call can consume it. */
            if (ev->xselection.property != None && ev->xselection.property == g_xsel_data_atom) {
                Atom actual_type;
                int actual_format;
                unsigned long nitems, bytes_after;
                unsigned char* prop_data = NULL;
                if (XGetWindowProperty(g_display, g_window, g_xsel_data_atom,
                                       0, 65536, False, AnyPropertyType,
                                       &actual_type, &actual_format, &nitems,
                                       &bytes_after, &prop_data) == Success) {
                    if (prop_data && nitems > 0) {
                        /* Free any previous pending paste */
                        if (g_pending_paste) { free(g_pending_paste); g_pending_paste = NULL; }
                        g_pending_paste = (char*)malloc(nitems + 1);
                        if (g_pending_paste) {
                            memcpy(g_pending_paste, prop_data, nitems);
                            g_pending_paste[nitems] = 0;
                            g_pending_paste_len = nitems;
                        }
                    }
                    if (prop_data) XFree(prop_data);
                }
                /* Delete the property so the owner knows we read it */
                XDeleteProperty(g_display, g_window, g_xsel_data_atom);
            }
            break;
        }
        case ClientMessage: {
            if (ev->xclient.format == 32 && (Atom)ev->xclient.data.l[0] == XInternAtom(g_display, "WM_DELETE_WINDOW", False)) exit(0);
            break;
        }
        default: break;
    }
}

/* Pre-warm glyph cache: render common ASCII characters at common font
 * sizes so the first frame doesn't stall on cache misses. This covers
 * ~95% of UI text (lowercase, uppercase, digits, punctuation). */
static void prewarm_glyph_cache(void) {
    if (!g_face) return;
    pthread_mutex_lock(&g_ft_lock);
    /* Common font sizes used in the IDE UI */
    const unsigned int sizes[] = {11, 12, 13, 14, 16, 18, 24, 34};
    /* ASCII printable range (space to ~) covers most UI text */
    for (size_t si = 0; si < sizeof(sizes)/sizeof(sizes[0]); si++) {
        unsigned int fs_px = sizes[si];
        FT_Set_Pixel_Sizes(g_face, 0, fs_px);
        for (unsigned long cp = 32; cp < 127; cp++) {
            if (glyph_cache_lookup(cp, fs_px)) continue; /* already cached */
            FT_UInt gi = FT_Get_Char_Index(g_face, cp);
            if (gi == 0) continue;
            FT_Int32 load_flags = FT_LOAD_RENDER | FT_LOAD_FORCE_AUTOHINT;
#if USE_LCD_SUBPIXEL
            load_flags = FT_LOAD_RENDER | FT_LOAD_FORCE_AUTOHINT | FT_LOAD_TARGET_LCD;
#endif
            if (FT_Load_Glyph(g_face, gi, load_flags) != 0) continue;
            glyph_cache_put(cp, fs_px, gi, g_face->glyph);
        }
    }
    pthread_mutex_unlock(&g_ft_lock);
}

void forge_backend_init(void) {
    g_display = XOpenDisplay(NULL);
    if (!g_display) { fprintf(stderr, "forge: cannot open X display\n"); return; }
    detect_dpi_scale();
    load_font();
    prewarm_glyph_cache();
}

void forge_backend_create_window(const char* title, int width, int height) {
    if (!g_display) return;
    g_width = width; g_height = height;
    int screen = DefaultScreen(g_display);
    g_window = XCreateSimpleWindow(g_display, RootWindow(g_display, screen), 0, 0, width, height, 0, BlackPixel(g_display, screen), BlackPixel(g_display, screen));
    /* Set window background to the framebuffer clear colour (0x1E1E1E)
     * so X11 Exposure events don't flash black before we redraw.
     * Was BlackPixel which caused a black flash every time the WM sent
     * an Expose event (every few seconds on some compositors). */
    XSetWindowBackground(g_display, g_window, 0x1E1E1E);
    XStoreName(g_display, g_window, title ? title : "Forge");
    XSelectInput(g_display, g_window, ExposureMask|StructureNotifyMask|KeyPressMask|KeyReleaseMask|ButtonPressMask|ButtonReleaseMask|PointerMotionMask);
    Atom wm_delete = XInternAtom(g_display, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(g_display, g_window, &wm_delete, 1);
    g_gc = XCreateGC(g_display, g_window, 0, NULL);
    allocate_framebuffer(width, height);
    XMapWindow(g_display, g_window);
    XFlush(g_display);

    /* Initialize Xdbe double-buffering if available. This eliminates
     * the visual gap between clearing the framebuffer and rendering
     * content by swapping the back buffer atomically. */
#ifdef FORGE_HAS_XDBE
    int dbe_major, dbe_minor;
    if (XdbeQueryExtension(g_display, &dbe_major, &dbe_minor)) {
        g_dbe_back_buffer = XdbeAllocateBackBufferName(g_display, g_window, XdbeUndefined);
        if (g_dbe_back_buffer) {
            g_dbe_available = 1;
            fprintf(stderr, "[forge] Xdbe double-buffering enabled (eliminates flicker)\n");
        }
    }
#endif

    /* GPU mode disabled — GLX init steals X11 window rendering context,
     * breaking CPU framebuffer compositing (XPutImage). GPU mode will be
     * re-enabled when SDF text rendering fully replaces FreeType CPU path,
     * eliminating the need for XPutImage compositing. */
#ifdef FORGE_HAS_GLX
    if (forge_gpu_glx_available(g_display)) {
        fprintf(stderr, "[forge] GPU available (GLX/OpenGL) — CPU mode active (GPU deferred)\n");
    }
#endif

    /* Initialize XIM (X Input Method) for international text input.
     * This enables Vietnamese (ibus/unikey), Chinese, Japanese, Korean
     * IME input. Without XIM, Xutf8LookupString can only produce raw
     * key codes — no composed characters.
     */
    XSetLocaleModifiers("");
    g_xim = XOpenIM(g_display, NULL, NULL, NULL);
    if (g_xim) {
        g_xic = XCreateIC(g_xim,
            XNInputStyle, XIMPreeditNothing | XIMStatusNothing,
            XNClientWindow, g_window,
            XNFocusWindow, g_window,
            NULL);
        if (g_xic) {
            XSetICFocus(g_xic);
            fprintf(stderr, "[forge] XIM input method initialized (Vietnamese/IME support enabled)\n");
        } else {
            fprintf(stderr, "[forge] XCreateIC failed — IME input disabled\n");
        }
    } else {
        fprintf(stderr, "[forge] XOpenIM failed — IME input disabled\n");
    }
}

void forge_backend_set_continuous_rendering(bool enabled) { g_continuous = enabled ? 1 : 0; }
void forge_backend_request_redraw(void) { atomic_fetch_add(&g_redraw_requests, 1); }
void forge_backend_get_render_stats(unsigned long long* rq, unsigned long long* fd) { if (rq) *rq = atomic_load(&g_redraw_requests); if (fd) *fd = atomic_load(&g_frames_drawn); }
void forge_backend_set_render_callback(ForgeRenderCallback cb) { g_render_cb = cb; }
void forge_backend_set_key_callback(ForgeKeyCallback cb) { g_key_cb = cb; }
void forge_backend_set_mouse_callback(ForgeMouseCallback cb) { g_mouse_cb = cb; }
void forge_backend_set_cursor(int type) {
    if (!g_display) return;
    /* Cursor types:
     *   0 = default (left pointer)
     *   1 = I-beam (text input)
     *   2 = horizontal resize (splitter)
     *   3 = vertical resize (splitter)
     *   4 = hand / pointer (clickable elements like buttons, links)
     */
    int shape;
    switch (type) {
        case 1:  shape = 152; /* XC_xterm (I-beam) */ break;
        case 2:  shape = 108; /* XC_sb_h_double_arrow */ break;
        case 3:  shape = 116; /* XC_sb_v_double_arrow */ break;
        case 4:  shape = 60;  /* XC_hand2 (pointing hand) */ break;
        default: shape = 68;  /* XC_left_ptr */ break;
    }
    Cursor cur = XCreateFontCursor(g_display, shape);
    if (cur) {
        XDefineCursor(g_display, g_window, cur);
        XFreeCursor(g_display, cur);
    }
}

/* IME stubs — Linux X11 IME (XIM/XIC) integration is deferred.
 * These no-op implementations satisfy the linker so forge-ide builds on
 * Linux. Real IME support requires XIM/XIC setup in forge_backend_init
 * and XFilterEvent calls in the event loop. See backend.h for the
 * callback signature.
 */
void forge_backend_set_ime_composition_callback(ForgeImeCompositionCallback cb) { g_ime_cb = cb; }

void forge_backend_set_ime_cursor_rect(float x, float y, float w, float h) {
    /* Tell the IME where the cursor is so it can position its preedit
     * window (for "over-the-spot" or "on-the-spot" input styles).
     * For XIMPreeditNothing style this is a no-op, but we implement
     * it for future upgrade to on-the-spot input. */
    if (!g_xic || !g_display) return;
    XPoint spot = { .x = (short)x, .y = (short)(y + h) };
    XVaNestedList attr = XVaCreateNestedList(0, XNSpotLocation, &spot, NULL);
    if (attr) {
        XSetICValues(g_xic, XNPreeditAttributes, attr, NULL);
        XFree(attr);
    }
}

void forge_backend_run(void) {
    if (!g_display) return;
    int pending = 1;
    while (1) {
        while (XPending(g_display)) { XEvent ev; XNextEvent(g_display, &ev); if (XFilterEvent(&ev, g_window)) continue; handle_event(&ev); }
        if (pending || g_continuous) {
#ifdef FORGE_HAS_GLX
            if (g_gpu_mode) {
                /* GPU mode: GLX clear + render callback (batches rects) +
                 * flush + glXSwapBuffers (VSync). */
                forge_gpu_glx_clear(0.118f, 0.118f, 0.137f, 1.0f);
                g_clip_active = 0;
                if (g_render_cb) g_render_cb();
                forge_gpu_glx_flush((float)g_width, (float)g_height);
                forge_gpu_glx_present(g_display, (unsigned long)g_window);
            } else {
#endif
                /* CPU mode: clear framebuffer, render, then present.
                 * When Xdbe is available, we render to a back buffer and
                 * swap atomically — this eliminates the visual gap between
                 * clearing and rendering that caused the flicker.
                 * Without Xdbe, we fall back to XPutImage directly to the
                 * window (the window background is set to the clear colour
                 * to minimise the visible gap).
                 *
                 * Clear optimization: g_full_clear_needed is only set on
                 * first frame or layout changes (theme switch, panel
                 * resize, etc.). When false, the previous frame's pixels
                 * are retained in the framebuffer and each dirty panel's
                 * opaque background fill paints over its own region. This
                 * skips a full-screen memset (3-4ms on 1080p) on the
                 * common typing / scrolling hot path.
                 *
                 * Memcpy optimization: when SHM is attached, g_pixels IS
                 * g_image->data (same memory), so we skip the per-frame
                 * 8MB memcpy. The non-SHM fallback still does the memcpy
                 * because XCreateImage owns its own data buffer. */
                if (g_full_clear_needed) {
                    for (int i = 0; i < g_width * g_height; i++) g_pixels[i] = 0xFF1E1E1E;
                }
                g_clip_active = 0;
                if (g_render_cb) g_render_cb();
#ifdef FORGE_HAS_XDBE
                if (g_dbe_available && g_dbe_back_buffer) {
                    /* Copy framebuffer to back buffer, then swap.
                     * XdbeSwapBuffers is atomic — the window never shows
                     * a partially-rendered frame.
                     *
                     * swap_action = XdbeCopied: the back buffer's
                     * contents are preserved across the swap (copied
                     * from the front buffer). This lets us skip the
                     * full-framebuffer clear in the next frame —
                     * each dirty panel's opaque background fill
                     * paints over only its own region, and undrawed
                     * pixels retain the previous frame's value.
                     * Saves 3-4ms/frame on 1080p in the common
                     * typing/scrolling hot path. */
                    if (g_shm_attached) {
                        /* g_pixels == g_image->data; no memcpy needed. */
                        XShmPutImage(g_display, g_dbe_back_buffer, g_gc, g_image, 0, 0, 0, 0, g_width, g_height, False);
                    } else if (g_image) {
                        XPutImage(g_display, g_dbe_back_buffer, g_gc, g_image, 0, 0, 0, 0, g_width, g_height);
                    }
                    g_dbe_swap_info.swap_window = g_window;
                    g_dbe_swap_info.swap_action = XdbeUndefined;
                    XdbeSwapBuffers(g_display, &g_dbe_swap_info, 1);
                    XSync(g_display, False);
                } else {
#endif
                    /* When SHM is attached, g_pixels points at g_image->data
                     * directly, so no memcpy is needed — XShmPutImage reads
                     * from the same memory the renderer wrote to. */
                    if (g_shm_attached) {
                        XShmPutImage(g_display, g_window, g_gc, g_image, 0, 0, 0, 0, g_width, g_height, False);
                    } else if (g_image) {
                        memcpy(g_image->data, g_pixels, (size_t)g_width * g_height * 4);
                        XPutImage(g_display, g_window, g_gc, g_image, 0, 0, 0, 0, g_width, g_height);
                    }
                    XSync(g_display, False);
#ifdef FORGE_HAS_XDBE
                }
#endif
#ifdef FORGE_HAS_GLX
            }
#endif
            atomic_fetch_add(&g_frames_drawn, 1);
            pending = 0;
        }
        if (atomic_load(&g_redraw_requests) > 0) { pending = 1; atomic_exchange(&g_redraw_requests, 0); }
        if (!g_continuous) { XEvent ev; XNextEvent(g_display, &ev); if (!XFilterEvent(&ev, g_window)) handle_event(&ev); pending = 1; }
        else usleep(16000);
    }
}
