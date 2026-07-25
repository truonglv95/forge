// OpenGL ES 3.0 backend for Forge IDE — GPU-accelerated rendering on Linux.
//
// This module implements GPU rendering via OpenGL ES 3.0 on X11/EGL.
// It provides batched rect rendering and SDF text rendering, matching
// the Metal backend's capabilities on macOS.
//
// Architecture:
//   - EGL context on X11 window
//   - VBO for batched vertices (same as Metal)
//   - GLSL ES 3.0 shaders for rect fill + SDF text
//   - Framebuffer: render to FBO, blit to X11 window
//
// Usage: Called from gpu_backend.zig when backend == .opengl_es

#include "../shared/backend.h"

#ifdef __linux__

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- Shaders (GLSL ES 3.0) ---

static const char* kRectVS =
    "#version 300 es\n"
    "layout(location=0) in vec2 a_position;\n"
    "layout(location=1) in vec4 a_color;\n"
    "uniform vec2 u_viewport;\n"
    "out vec4 v_color;\n"
    "void main() {\n"
    "    vec2 clip = a_position / u_viewport * 2.0 - 1.0;\n"
    "    gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);\n"
    "    v_color = a_color;\n"
    "}\n";

static const char* kRectFS =
    "#version 300 es\n"
    "precision mediump float;\n"
    "in vec4 v_color;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    fragColor = v_color;\n"
    "}\n";

static const char* kTextVS =
    "#version 300 es\n"
    "layout(location=0) in vec2 a_position;\n"
    "layout(location=1) in vec2 a_texcoord;\n"
    "layout(location=2) in vec4 a_color;\n"
    "uniform vec2 u_viewport;\n"
    "uniform float u_smoothing;\n"
    "out vec2 v_texcoord;\n"
    "out vec4 v_color;\n"
    "void main() {\n"
    "    vec2 clip = a_position / u_viewport * 2.0 - 1.0;\n"
    "    gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);\n"
    "    v_texcoord = a_texcoord;\n"
    "    v_color = a_color;\n"
    "}\n";

static const char* kTextFS =
    "#version 300 es\n"
    "precision mediump float;\n"
    "in vec2 v_texcoord;\n"
    "in vec4 v_color;\n"
    "uniform sampler2D u_atlas;\n"
    "uniform float u_smoothing;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    float dist = texture(u_atlas, v_texcoord).r;\n"
    "    float alpha = smoothstep(0.5 - u_smoothing, 0.5 + u_smoothing, dist);\n"
    "    fragColor = vec4(v_color.rgb, v_color.a * alpha);\n"
    "}\n";

// --- OpenGL state ---

static EGLDisplay g_egl_display = EGL_NO_DISPLAY;
static EGLContext g_egl_context = EGL_NO_CONTEXT;
static EGLSurface g_egl_surface = EGL_NO_SURFACE;
static GLuint g_rect_program = 0;
static GLuint g_text_program = 0;
static GLuint g_rect_vbo = 0;
static GLuint g_text_vbo = 0;
static GLuint g_atlas_texture = 0;
static int g_gl_initialized = 0;

// Batched rect vertices (same layout as Metal)
#define GL_MAX_RECT_VERTS 65536
typedef struct {
    float position[2];
    float color[4];
} GLVertex;
static GLVertex g_rect_verts[GL_MAX_RECT_VERTS];
static int g_rect_count = 0;

// --- Shader compilation ---

static GLuint compile_shader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char log[512];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "[gpu_opengl] shader compile error: %s\n", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint link_program(GLuint vs, GLuint fs) {
    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[512];
        glGetProgramInfoLog(program, sizeof(log), NULL, log);
        fprintf(stderr, "[gpu_opengl] program link error: %s\n", log);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

// --- Initialization ---

int forge_gpu_opengl_init(void* x11_display, unsigned long x11_window) {
    Display* dpy = (Display*)x11_display;
    if (!dpy) return 0;

    g_egl_display = eglGetDisplay((EGLNativeDisplayType)dpy);
    if (g_egl_display == EGL_NO_DISPLAY) return 0;

    EGLint major, minor;
    if (!eglInitialize(g_egl_display, &major, &minor)) return 0;

    EGLint config_attribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config;
    EGLint num_configs;
    if (!eglChooseConfig(g_egl_display, config_attribs, &config, 1, &num_configs) || num_configs == 0) {
        fprintf(stderr, "[gpu_opengl] no suitable EGL config\n");
        return 0;
    }

    g_egl_surface = eglCreateWindowSurface(g_egl_display, config, (EGLNativeWindowType)x11_window, NULL);
    if (g_egl_surface == EGL_NO_SURFACE) {
        fprintf(stderr, "[gpu_opengl] cannot create EGL surface\n");
        return 0;
    }

    eglBindAPI(EGL_OPENGL_ES_API);

    EGLint context_attribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    g_egl_context = eglCreateContext(g_egl_display, config, EGL_NO_CONTEXT, context_attribs);
    if (g_egl_context == EGL_NO_CONTEXT) {
        fprintf(stderr, "[gpu_opengl] cannot create EGL context\n");
        return 0;
    }

    if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context)) {
        fprintf(stderr, "[gpu_opengl] eglMakeCurrent failed\n");
        return 0;
    }

    // Compile shaders
    GLuint rect_vs = compile_shader(GL_VERTEX_SHADER, kRectVS);
    GLuint rect_fs = compile_shader(GL_FRAGMENT_SHADER, kRectFS);
    g_rect_program = link_program(rect_vs, rect_fs);
    glDeleteShader(rect_vs);
    glDeleteShader(rect_fs);

    GLuint text_vs = compile_shader(GL_VERTEX_SHADER, kTextVS);
    GLuint text_fs = compile_shader(GL_FRAGMENT_SHADER, kTextFS);
    g_text_program = link_program(text_vs, text_fs);
    glDeleteShader(text_vs);
    glDeleteShader(text_fs);

    if (!g_rect_program) {
        fprintf(stderr, "[gpu_opengl] rect program failed, falling back to CPU\n");
        return 0;
    }

    // Create VBOs
    glGenBuffers(1, &g_rect_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g_rect_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(GLVertex) * GL_MAX_RECT_VERTS, NULL, GL_DYNAMIC_DRAW);

    // Enable blending
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    g_gl_initialized = 1;
    fprintf(stderr, "[gpu_opengl] initialized (EGL %d.%d, GLES 3.0)\n", major, minor);
    return 1;
}

// --- Batched rect rendering ---

void forge_gpu_opengl_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) {
    if (g_rect_count + 6 > GL_MAX_RECT_VERTS) return;
    int base = g_rect_count;
    g_rect_verts[base + 0] = (GLVertex){{x, y}, {r, g, b, a}};
    g_rect_verts[base + 1] = (GLVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 2] = (GLVertex){{x, y + h}, {r, g, b, a}};
    g_rect_verts[base + 3] = (GLVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 4] = (GLVertex){{x + w, y + h}, {r, g, b, a}};
    g_rect_verts[base + 5] = (GLVertex){{x, y + h}, {r, g, b, a}};
    g_rect_count += 6;
}

// --- Frame flush ---

void forge_gpu_opengl_flush(float viewport_w, float viewport_h) {
    if (!g_gl_initialized || g_rect_count == 0) return;

    glViewport(0, 0, (int)viewport_w, (int)viewport_h);
    glUseProgram(g_rect_program);

    GLint viewport_loc = glGetUniformLocation(g_rect_program, "u_viewport");
    glUniform2f(viewport_loc, viewport_w, viewport_h);

    // Upload vertex data
    glBindBuffer(GL_ARRAY_BUFFER, g_rect_vbo);
    glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(GLVertex) * g_rect_count, g_rect_verts);

    // Set vertex attributes
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(GLVertex), (void*)offsetof(GLVertex, position));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, sizeof(GLVertex), (void*)offsetof(GLVertex, color));

    // Draw batched rects
    glDrawArrays(GL_TRIANGLES, 0, g_rect_count);

    g_rect_count = 0;
}

// --- Present (swap buffers) ---

void forge_gpu_opengl_present(void) {
    if (g_egl_display != EGL_NO_DISPLAY && g_egl_surface != EGL_NO_SURFACE) {
        eglSwapBuffers(g_egl_display, g_egl_surface);
    }
}

// --- Check if OpenGL ES is available ---

int forge_gpu_opengl_available(void* x11_display) {
    Display* dpy = (Display*)x11_display;
    if (!dpy) return 0;
    EGLDisplay edpy = eglGetDisplay((EGLNativeDisplayType)dpy);
    return edpy != EGL_NO_DISPLAY;
}

// --- Load SDF atlas texture ---

void forge_gpu_opengl_load_atlas(const unsigned char* png_data, int width, int height) {
    if (!g_gl_initialized) return;
    glGenTextures(1, &g_atlas_texture);
    glBindTexture(GL_TEXTURE_2D, g_atlas_texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, width, height, 0, GL_RED, GL_UNSIGNED_BYTE, png_data);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

#else // !__linux__

// Stubs for non-Linux platforms
int forge_gpu_opengl_init(void* dpy, unsigned long win) { (void)dpy; (void)win; return 0; }
void forge_gpu_opengl_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) { (void)x; (void)y; (void)w; (void)h; (void)r; (void)g; (void)b; (void)a; }
void forge_gpu_opengl_flush(float vw, float vh) { (void)vw; (void)vh; }
void forge_gpu_opengl_present(void) {}
int forge_gpu_opengl_available(void* dpy) { (void)dpy; return 0; }
void forge_gpu_opengl_load_atlas(const unsigned char* data, int w, int h) { (void)data; (void)w; (void)h; }

#endif // __linux__
