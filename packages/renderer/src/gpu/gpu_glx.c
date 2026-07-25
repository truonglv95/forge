// OpenGL (GLX) backend for Forge IDE — GPU-accelerated rendering on Linux.
//
// Uses desktop OpenGL via GLX (X11 OpenGL extension) instead of EGL/GLES.
// GLX is available on any X11 system with Mesa/GL drivers — no extra
// dev packages needed beyond libGL.so.1 (already installed).
//
// This avoids the libegl1-mesa-dev / libgles2-mesa-dev dependency.
// Shaders use GLSL 1.30 (desktop OpenGL 3.0) instead of GLSL ES 3.0.

#include "../shared/backend.h"

#ifdef __linux__

#include <GL/glx.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- GLSL Shaders (desktop OpenGL 1.30) ---

static const char* kRectVS =
    "#version 130\n"
    "in vec2 a_position;\n"
    "in vec4 a_color;\n"
    "uniform vec2 u_viewport;\n"
    "out vec4 v_color;\n"
    "void main() {\n"
    "    vec2 clip = a_position / u_viewport * 2.0 - 1.0;\n"
    "    gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);\n"
    "    v_color = a_color;\n"
    "}\n";

static const char* kRectFS =
    "#version 130\n"
    "in vec4 v_color;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    fragColor = v_color;\n"
    "}\n";

// --- GL state ---

static GLXContext g_glx_context = NULL;
static GLXFBConfig g_glx_config = NULL;
static GLuint g_rect_program = 0;
static GLuint g_rect_vbo = 0;
static int g_gl_initialized = 0;

// Batched rect vertices
#define GLX_MAX_RECT_VERTS 65536
typedef struct {
    float position[2];
    float color[4];
} GLXVertex;
static GLXVertex g_rect_verts[GLX_MAX_RECT_VERTS];
static int g_rect_count = 0;

// --- Shader compilation ---

static GLuint compile_shader_glx(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char log[512];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "[gpu_glx] shader error: %s\n", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint link_program_glx(GLuint vs, GLuint fs) {
    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) return 0;
    return program;
}

// --- Initialization ---

int forge_gpu_glx_init(void* x11_display, unsigned long x11_window) {
    Display* dpy = (Display*)x11_display;
    if (!dpy) return 0;

    int attribs[] = {
        GLX_RGBA, GLX_DOUBLEBUFFER,
        GLX_RED_SIZE, 8,
        GLX_GREEN_SIZE, 8,
        GLX_BLUE_SIZE, 8,
        GLX_ALPHA_SIZE, 8,
        GLX_DEPTH_SIZE, 0,
        None
    };

    int fb_count = 0;
    GLXFBConfig* fbc = glXChooseFBConfig(dpy, DefaultScreen(dpy), NULL, &fb_count);
    if (!fbc || fb_count == 0) {
        // Fallback: use glXChooseVisual
        XVisualInfo* vi = glXChooseVisual(dpy, DefaultScreen(dpy), attribs);
        if (!vi) return 0;
        g_glx_context = glXCreateContext(dpy, vi, NULL, GL_TRUE);
        XFree(vi);
    } else {
        g_glx_config = fbc[0];
        XVisualInfo* vi = glXGetVisualFromFBConfig(dpy, g_glx_config);
        if (vi) {
            g_glx_context = glXCreateContext(dpy, vi, NULL, GL_TRUE);
            XFree(vi);
        }
        XFree(fbc);
    }

    if (!g_glx_context) {
        fprintf(stderr, "[gpu_glx] cannot create GLX context\n");
        return 0;
    }

    if (!glXMakeCurrent(dpy, (Window)x11_window, g_glx_context)) {
        fprintf(stderr, "[gpu_glx] glXMakeCurrent failed\n");
        return 0;
    }

    // Compile shaders
    GLuint vs = compile_shader_glx(GL_VERTEX_SHADER, kRectVS);
    GLuint fs = compile_shader_glx(GL_FRAGMENT_SHADER, kRectFS);
    g_rect_program = link_program_glx(vs, fs);
    glDeleteShader(vs);
    glDeleteShader(fs);

    if (!g_rect_program) {
        fprintf(stderr, "[gpu_glx] shader program failed\n");
        return 0;
    }

    // Create VBO
    glGenBuffers(1, &g_rect_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g_rect_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(GLXVertex) * GLX_MAX_RECT_VERTS, NULL, GL_DYNAMIC_DRAW);

    // Enable blending
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    g_gl_initialized = 1;
    fprintf(stderr, "[gpu_glx] initialized (OpenGL %s)\n", glGetString(GL_VERSION));
    return 1;
}

// --- Batched rect rendering ---

void forge_gpu_glx_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) {
    if (g_rect_count + 6 > GLX_MAX_RECT_VERTS) return;
    int base = g_rect_count;
    g_rect_verts[base + 0] = (GLXVertex){{x, y}, {r, g, b, a}};
    g_rect_verts[base + 1] = (GLXVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 2] = (GLXVertex){{x, y + h}, {r, g, b, a}};
    g_rect_verts[base + 3] = (GLXVertex){{x + w, y}, {r, g, b, a}};
    g_rect_verts[base + 4] = (GLXVertex){{x + w, y + h}, {r, g, b, a}};
    g_rect_verts[base + 5] = (GLXVertex){{x, y + h}, {r, g, b, a}};
    g_rect_count += 6;
}

// --- Frame flush ---

void forge_gpu_glx_flush(float viewport_w, float viewport_h) {
    if (!g_gl_initialized || g_rect_count == 0) return;

    glViewport(0, 0, (int)viewport_w, (int)viewport_h);
    glUseProgram(g_rect_program);

    GLint loc = glGetUniformLocation(g_rect_program, "u_viewport");
    glUniform2f(loc, viewport_w, viewport_h);

    glBindBuffer(GL_ARRAY_BUFFER, g_rect_vbo);
    glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(GLXVertex) * g_rect_count, g_rect_verts);

    GLint pos_loc = glGetAttribLocation(g_rect_program, "a_position");
    GLint col_loc = glGetAttribLocation(g_rect_program, "a_color");
    glEnableVertexAttribArray(pos_loc);
    glVertexAttribPointer(pos_loc, 2, GL_FLOAT, GL_FALSE, sizeof(GLXVertex), (void*)0);
    glEnableVertexAttribArray(col_loc);
    glVertexAttribPointer(col_loc, 4, GL_FLOAT, GL_FALSE, sizeof(GLXVertex), (void*)8);

    glDrawArrays(GL_TRIANGLES, 0, g_rect_count);
    g_rect_count = 0;
}

// --- Present (swap buffers + VSync) ---

void forge_gpu_glx_present(void* x11_display, unsigned long x11_window) {
    Display* dpy = (Display*)x11_display;
    if (dpy && g_glx_context) {
        glXSwapBuffers(dpy, (Window)x11_window);
    }
}

// --- Clear ---

void forge_gpu_glx_clear(float r, float g, float b, float a) {
    glClearColor(r, g, b, a);
    glClear(GL_COLOR_BUFFER_BIT);
}

// --- Check availability ---

int forge_gpu_glx_available(void* x11_display) {
    Display* dpy = (Display*)x11_display;
    if (!dpy) return 0;
    return glXQueryExtension(dpy, NULL, NULL);
}

#else // !__linux__

int forge_gpu_glx_init(void* d, unsigned long w) { (void)d; (void)w; return 0; }
void forge_gpu_glx_draw_rect(float x, float y, float w, float h, float r, float g, float b, float a) { (void)x; (void)y; (void)w; (void)h; (void)r; (void)g; (void)b; (void)a; }
void forge_gpu_glx_flush(float vw, float vh) { (void)vw; (void)vh; }
void forge_gpu_glx_present(void* d, unsigned long w) { (void)d; (void)w; }
void forge_gpu_glx_clear(float r, float g, float b, float a) { (void)r; (void)g; (void)b; (void)a; }
int forge_gpu_glx_available(void* d) { (void)d; return 0; }

#endif // __linux__
