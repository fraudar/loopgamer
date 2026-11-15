#include <jni.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <vector>

#ifndef EGL_OPENGL_ES3_BIT_KHR
#define EGL_OPENGL_ES3_BIT_KHR 0x0040
#endif

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>
#endif

// Frontend Vulkan (libretro_vulkan.cpp): instance/device/swapchain +
// retro_hw_render_interface_vulkan v5 para cores como PPSSPP.
namespace vkfe {
void set_custom_driver(const char* hook_lib_dir,
                       const char* tmp_dir,
                       const char* custom_driver_dir,
                       const char* custom_driver_name,
                       bool adreno_turbo);
void set_backend(int mode); // 0 = GL, 1 = software, 2 = Vulkan
void set_vsync(bool enabled);
bool vulkan_requested();    // usuário pediu Vulkan e probe passou
bool is_active();
bool on_negotiation_iface(const void* iface, ANativeWindow* window);
bool get_render_interface(void** out);
void context_reset();
void context_destroy();
void begin_frame();
void present(unsigned w, unsigned h);
void shutdown_public();
} // namespace vkfe

namespace {

constexpr unsigned RETRO_ENVIRONMENT_SET_ROTATION = 1;
constexpr unsigned RETRO_ENVIRONMENT_GET_OVERSCAN = 2;
constexpr unsigned RETRO_ENVIRONMENT_GET_CAN_DUPE = 3;
constexpr unsigned RETRO_ENVIRONMENT_SET_MESSAGE = 6;
constexpr unsigned RETRO_ENVIRONMENT_SHUTDOWN = 7;
constexpr unsigned RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL = 8;
constexpr unsigned RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY = 9;
constexpr unsigned RETRO_ENVIRONMENT_SET_PIXEL_FORMAT = 10;
constexpr unsigned RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS = 11;
constexpr unsigned RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE = 13;
constexpr unsigned RETRO_ENVIRONMENT_SET_HW_RENDER = 14;
constexpr unsigned RETRO_ENVIRONMENT_GET_VARIABLE = 15;
constexpr unsigned RETRO_ENVIRONMENT_SET_VARIABLES = 16;
constexpr unsigned RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE = 17;
constexpr unsigned RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME = 18;
constexpr unsigned RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES = 24;
constexpr unsigned RETRO_ENVIRONMENT_GET_LOG_INTERFACE = 27;
constexpr unsigned RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY = 31;
constexpr unsigned RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO = 32;
constexpr unsigned RETRO_ENVIRONMENT_SET_CONTROLLER_INFO = 35;
constexpr unsigned RETRO_ENVIRONMENT_SET_GEOMETRY = 37;
constexpr unsigned RETRO_ENVIRONMENT_GET_USERNAME = 38;
constexpr unsigned RETRO_ENVIRONMENT_GET_LANGUAGE = 39;
constexpr unsigned RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE = 47;
constexpr unsigned RETRO_ENVIRONMENT_GET_FASTFORWARDING = (49 | 0x10000);
constexpr unsigned RETRO_ENVIRONMENT_GET_INPUT_BITMASKS = 0x10033;
constexpr unsigned RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION = 52;
constexpr unsigned RETRO_ENVIRONMENT_SET_CORE_OPTIONS = 53;
constexpr unsigned RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY = 55;
constexpr unsigned RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER = 56;
constexpr unsigned RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE = 58;
constexpr unsigned RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK = 60;
constexpr unsigned RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS = (42 | 0x10000);
constexpr unsigned RETRO_ENVIRONMENT_SET_VARIABLE = 70;
constexpr unsigned RETRO_ENVIRONMENT_GET_JIT_CAPABLE = 74;
constexpr unsigned RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE =
    (41 | 0x10000); // RETRO_ENVIRONMENT_EXPERIMENTAL
constexpr unsigned RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE =
    (43 | 0x10000);
constexpr unsigned RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT =
    (73 | 0x10000);
constexpr int RETRO_HW_CONTEXT_NEGOTIATION_INTERFACE_VULKAN = 0;

typedef void (*retro_log_printf_t)(int level, const char* fmt, ...);
struct retro_log_callback {
  retro_log_printf_t log;
};

void core_log_printf(int level, const char* fmt, ...) {
  if (!fmt) return;
  int prio = ANDROID_LOG_INFO;
  if (level <= 0) prio = ANDROID_LOG_DEBUG;
  else if (level == 2) prio = ANDROID_LOG_WARN;
  else if (level >= 3) prio = ANDROID_LOG_ERROR;
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  buf[sizeof(buf) - 1] = '\0';
  __android_log_write(prio, "loopgamer-core", buf);
}

enum retro_pixel_format {
  RETRO_PIXEL_FORMAT_0RGB1555 = 0,
  RETRO_PIXEL_FORMAT_XRGB8888 = 1,
  RETRO_PIXEL_FORMAT_RGB565   = 2
};

enum retro_hw_context_type {
  RETRO_HW_CONTEXT_NONE = 0,
  RETRO_HW_CONTEXT_OPENGL = 1,
  RETRO_HW_CONTEXT_OPENGLES2 = 2,
  RETRO_HW_CONTEXT_OPENGL_CORE = 3,
  RETRO_HW_CONTEXT_OPENGLES3 = 4,
  RETRO_HW_CONTEXT_OPENGLES_CORE = 5,
  RETRO_HW_CONTEXT_VULKAN = 6,
  RETRO_HW_CONTEXT_D3D11 = 7,
  RETRO_HW_CONTEXT_D3D12 = 8,
  RETRO_HW_CONTEXT_D3D9 = 9
};

typedef void (*retro_hw_context_reset_t)(void);
typedef uintptr_t (*retro_hw_get_current_framebuffer_t)(void);
typedef void (*retro_proc_address_t)(void);
typedef retro_proc_address_t (*retro_hw_get_proc_address_t)(const char* sym);

struct retro_hw_render_callback {
  enum retro_hw_context_type context_type;
  retro_hw_context_reset_t context_reset;
  retro_hw_get_current_framebuffer_t get_current_framebuffer;
  retro_hw_get_proc_address_t get_proc_address;
  bool depth;
  bool stencil;
  bool bottom_left_origin;
  unsigned version_major;
  unsigned version_minor;
  bool cache_context;
  retro_hw_context_reset_t context_destroy;
  bool debug_context;
};

struct retro_variable {
  const char* key;
  const char* value;
};

struct retro_game_info {
  const char* path;
  const void* data;
  size_t size;
  const char* meta;
};

struct retro_game_geometry {
  unsigned base_width;
  unsigned base_height;
  unsigned max_width;
  unsigned max_height;
  float aspect_ratio;
};

struct retro_system_timing {
  double fps;
  double sample_rate;
};

struct retro_system_av_info {
  retro_game_geometry geometry;
  retro_system_timing timing;
};

typedef bool (*retro_environment_t)(unsigned cmd, void* data);
typedef void (*retro_video_refresh_t)(const void* data, unsigned width, unsigned height, size_t pitch);
typedef void (*retro_audio_sample_t)(int16_t left, int16_t right);
typedef size_t (*retro_audio_sample_batch_t)(const int16_t* data, size_t frames);
typedef void (*retro_input_poll_t)(void);
typedef int16_t (*retro_input_state_t)(unsigned port, unsigned device, unsigned index, unsigned id);

struct LibretroCoreSymbols {
  void* handle = nullptr;
  void (*retro_init)(void) = nullptr;
  void (*retro_deinit)(void) = nullptr;
  void (*retro_set_environment)(retro_environment_t) = nullptr;
  void (*retro_set_video_refresh)(retro_video_refresh_t) = nullptr;
  void (*retro_set_audio_sample)(retro_audio_sample_t) = nullptr;
  void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t) = nullptr;
  void (*retro_set_input_poll)(retro_input_poll_t) = nullptr;
  void (*retro_set_input_state)(retro_input_state_t) = nullptr;
  void (*retro_get_system_av_info)(retro_system_av_info*) = nullptr;
  bool (*retro_load_game)(const retro_game_info*) = nullptr;
  void (*retro_unload_game)(void) = nullptr;
  void (*retro_run)(void) = nullptr;
  size_t (*retro_serialize_size)(void) = nullptr;
  bool (*retro_serialize)(void*, size_t) = nullptr;
  bool (*retro_unserialize)(const void*, size_t) = nullptr;
};

LibretroCoreSymbols g_core;
ANativeWindow* g_window = nullptr;
std::mutex g_mutex;

// Ring buffer de áudio de baixa latência (evita realocações e memmove por frame)
constexpr size_t kAudioRingCapacity = 32768;
int16_t g_audio_ring[kAudioRingCapacity];
size_t g_audio_read_idx = 0;
size_t g_audio_write_idx = 0;
size_t g_audio_count = 0;
std::mutex g_audio_mutex;

retro_pixel_format g_pixel_format = RETRO_PIXEL_FORMAT_RGB565;
std::string g_system_dir;
std::string g_saves_dir;

std::atomic<uint32_t> g_joypad_mask{0};
std::atomic<uint32_t> g_turbo_mask{0};
std::atomic<int> g_turbo_half_period{3};
std::atomic<uint32_t> g_emu_frame_count{0};
std::atomic<int16_t> g_left_x{0};
std::atomic<int16_t> g_left_y{0};
std::atomic<int> g_frame_skip{0};
unsigned g_frame_counter = 0;

unsigned g_last_width = 480;
unsigned g_last_height = 272;
unsigned g_configured_width = 0;
unsigned g_configured_height = 0;
int32_t g_configured_win_format = 0;
double g_target_fps = 60.0;
int g_sample_rate = 44100;

// ---------------------------------------------------------------------------
// Estado do renderer EGL/GLES (GPU) — substitui o caminho lento de
// ANativeWindow_lock/unlockAndPost e habilita HW render (GLES2/GLES3)
// para cores que suportam (PPSSPP, DuckStation, PCSX2, Flycast etc.)
// ---------------------------------------------------------------------------
bool g_forceSoftwareCore = false;  // core deve renderizar por CPU
bool g_gpuFailed = false;          // EGL indisponível → fallback CPU
bool g_hwActive = false;           // core negociou HW render com sucesso
bool g_hwCbActive = false;         // callbacks HW válidos neste load
bool g_glReady = false;
EGLDisplay g_eglDisplay = EGL_NO_DISPLAY;
EGLSurface g_eglSurface = EGL_NO_SURFACE;
EGLContext g_eglContext = EGL_NO_CONTEXT;
std::thread::id g_glThreadId;
int g_eglGlesVersion = 2;

GLuint g_blitProgram = 0;
GLint g_blitPosLoc = -1;
GLint g_blitUScaleLoc = -1;
GLint g_blitVScaleLoc = -1;
GLint g_blitVOffsetLoc = -1;
GLint g_blitTexLoc = -1;
GLint g_blitSwizzleLoc = -1;
GLuint g_blitVbo = 0;
GLuint g_blitVao = 0;
bool g_bgraUpload = false;

using PfnGlGenVertexArrays = void (*)(GLsizei, GLuint*);
using PfnGlDeleteVertexArrays = void (*)(GLsizei, const GLuint*);
using PfnGlBindVertexArray = void (*)(GLuint);
using PfnGlBindSampler = void (*)(GLuint, GLuint);
PfnGlGenVertexArrays g_glGenVertexArrays = nullptr;
PfnGlDeleteVertexArrays g_glDeleteVertexArrays = nullptr;
PfnGlBindVertexArray g_glBindVertexArray = nullptr;
PfnGlBindSampler g_glBindSampler = nullptr;
void* g_libGles3 = nullptr;

GLuint g_swTex = 0;
unsigned g_swTexW = 0;
unsigned g_swTexH = 0;
retro_pixel_format g_swTexFormat = RETRO_PIXEL_FORMAT_RGB565;

GLuint g_hwFbo = 0;
GLuint g_hwColorTex = 0;
GLuint g_hwDepthRb = 0;
GLuint g_hwStencilRb = 0; // apenas em contexto GLES2
unsigned g_hwFboW = 0;
unsigned g_hwFboH = 0;
unsigned g_hwMaxW = 0;
unsigned g_hwMaxH = 0;
bool g_hwNeedDepth = false;
bool g_hwNeedStencil = false;
bool g_hwPreferredEs3 = false;
bool g_hwIsVulkan = false;
bool g_videoCbThisStep = false;
bool g_hwCbCalledThisStep = false;
bool g_hwEverPresented = false;
uint64_t g_hwPresentCount = 0;
GLenum g_lastLoggedGlErr = GL_NO_ERROR;
retro_hw_context_reset_t g_hwCoreReset = nullptr;
retro_hw_render_callback g_hwCb{};

std::atomic<bool> g_frameDup{false};
std::atomic<bool> g_vsyncEnabled{false};
std::atomic<bool> g_presentedThisStep{false};
std::unordered_map<std::string, std::string> g_coreVars;

retro_proc_address_t resolve_gl_proc(const char* sym) {
  if (!sym) return nullptr;
  if (std::strcmp(sym, "eglGetProcAddress") == 0) {
    return reinterpret_cast<retro_proc_address_t>(&eglGetProcAddress);
  }
  if (auto proc = eglGetProcAddress(sym)) {
    return reinterpret_cast<retro_proc_address_t>(proc);
  }
  if (void* p = dlsym(RTLD_DEFAULT, sym)) {
    return reinterpret_cast<retro_proc_address_t>(p);
  }
  if (!g_libGles3) {
    g_libGles3 = dlopen("libGLESv3.so", RTLD_LAZY | RTLD_LOCAL);
    if (!g_libGles3) {
      g_libGles3 = dlopen("libGLESv2.so", RTLD_LAZY | RTLD_LOCAL);
    }
  }
  if (g_libGles3) {
    if (void* p = dlsym(g_libGles3, sym)) {
      return reinterpret_cast<retro_proc_address_t>(p);
    }
  }
  return nullptr;
}

const char* kBlitVertexShader = R"GLSL(
attribute vec2 aPos;
varying vec2 vUv;
uniform float uUScale;
uniform float uVScale;
uniform float uVOffset;
void main() {
  vUv = vec2((aPos.x * 0.5 + 0.5) * uUScale, aPos.y * 0.5 * uVScale + uVOffset);
  gl_Position = vec4(aPos, 0.0, 1.0);
}
)GLSL";

const char* kBlitFragmentShader = R"GLSL(
precision mediump float;
varying vec2 vUv;
uniform sampler2D uTex;
uniform float uSwizzleRB;
void main() {
  vec4 c = texture2D(uTex, vUv);
  vec3 rgb = uSwizzleRB > 0.5 ? c.bgr : c.rgb;
  gl_FragColor = vec4(rgb, 1.0);
}
)GLSL";

GLuint compile_shader(GLenum type, const char* src) {
  GLuint s = glCreateShader(type);
  if (!s) return 0;
  glShaderSource(s, 1, &src, nullptr);
  glCompileShader(s);
  GLint ok = GL_FALSE;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    glDeleteShader(s);
    return 0;
  }
  return s;
}

bool init_blit_program() {
  GLuint vs = compile_shader(GL_VERTEX_SHADER, kBlitVertexShader);
  GLuint fs = compile_shader(GL_FRAGMENT_SHADER, kBlitFragmentShader);
  if (!vs || !fs) return false;
  g_blitProgram = glCreateProgram();
  glAttachShader(g_blitProgram, vs);
  glAttachShader(g_blitProgram, fs);
  glBindAttribLocation(g_blitProgram, 0, "aPos");
  glLinkProgram(g_blitProgram);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint linked = GL_FALSE;
  glGetProgramiv(g_blitProgram, GL_LINK_STATUS, &linked);
  if (!linked) {
    glDeleteProgram(g_blitProgram);
    g_blitProgram = 0;
    return false;
  }
  g_blitPosLoc = glGetAttribLocation(g_blitProgram, "aPos");
  g_blitUScaleLoc = glGetUniformLocation(g_blitProgram, "uUScale");
  g_blitVScaleLoc = glGetUniformLocation(g_blitProgram, "uVScale");
  g_blitVOffsetLoc = glGetUniformLocation(g_blitProgram, "uVOffset");
  g_blitTexLoc = glGetUniformLocation(g_blitProgram, "uTex");
  g_blitSwizzleLoc = glGetUniformLocation(g_blitProgram, "uSwizzleRB");

  static const float kVerts[6] = {-1.0f, -1.0f, 3.0f, -1.0f, -1.0f, 3.0f};
  glGenBuffers(1, &g_blitVbo);
  glBindBuffer(GL_ARRAY_BUFFER, g_blitVbo);
  glBufferData(GL_ARRAY_BUFFER, sizeof(kVerts), kVerts, GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER, 0);

  if (g_eglGlesVersion >= 3) {
    g_glGenVertexArrays = reinterpret_cast<PfnGlGenVertexArrays>(
        resolve_gl_proc("glGenVertexArrays"));
    g_glDeleteVertexArrays = reinterpret_cast<PfnGlDeleteVertexArrays>(
        resolve_gl_proc("glDeleteVertexArrays"));
    g_glBindVertexArray = reinterpret_cast<PfnGlBindVertexArray>(
        resolve_gl_proc("glBindVertexArray"));
    g_glBindSampler = reinterpret_cast<PfnGlBindSampler>(
        resolve_gl_proc("glBindSampler"));
    if (g_glGenVertexArrays && g_glBindVertexArray && g_blitPosLoc >= 0) {
      g_glGenVertexArrays(1, &g_blitVao);
      g_glBindVertexArray(g_blitVao);
      glBindBuffer(GL_ARRAY_BUFFER, g_blitVbo);
      glEnableVertexAttribArray(g_blitPosLoc);
      glVertexAttribPointer(g_blitPosLoc, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
      glBindBuffer(GL_ARRAY_BUFFER, 0);
      g_glBindVertexArray(0);
    }
  }

  const GLubyte* exts = glGetString(GL_EXTENSIONS);
  g_bgraUpload = exts && strstr(reinterpret_cast<const char*>(exts),
                                "GL_EXT_texture_format_BGRA8888") != nullptr;
  __android_log_print(ANDROID_LOG_INFO, "loopgamer-core",
                      "EGL/GLES%d ready (vao=%u sampler=%d bgra=%d)",
                      g_eglGlesVersion, g_blitVao,
                      g_glBindSampler ? 1 : 0, g_bgraUpload ? 1 : 0);
  return true;
}

void gl_release_context() {
  if (g_eglDisplay != EGL_NO_DISPLAY) {
    eglMakeCurrent(g_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
  g_glThreadId = std::thread::id();
}

void gl_shutdown() {
  if (!g_glReady && g_eglDisplay == EGL_NO_DISPLAY) return;
  if (g_eglDisplay != EGL_NO_DISPLAY && g_eglSurface != EGL_NO_SURFACE &&
      g_eglContext != EGL_NO_CONTEXT) {
    if (eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext) ==
        EGL_TRUE) {
      if (g_swTex != 0) glDeleteTextures(1, &g_swTex);
      if (g_hwColorTex != 0) glDeleteTextures(1, &g_hwColorTex);
      if (g_hwDepthRb != 0) glDeleteRenderbuffers(1, &g_hwDepthRb);
      if (g_hwStencilRb != 0) glDeleteRenderbuffers(1, &g_hwStencilRb);
      if (g_hwFbo != 0) glDeleteFramebuffers(1, &g_hwFbo);
      if (g_blitVao != 0 && g_glDeleteVertexArrays) {
        g_glDeleteVertexArrays(1, &g_blitVao);
      }
      if (g_blitVbo != 0) glDeleteBuffers(1, &g_blitVbo);
      if (g_blitProgram != 0) glDeleteProgram(g_blitProgram);
      glFinish();
    }
    gl_release_context();
  }
  g_swTex = g_hwColorTex = g_hwDepthRb = g_hwStencilRb = g_hwFbo =
      g_blitVao = g_blitVbo = g_blitProgram = 0;
  g_blitUScaleLoc = -1;
  g_glGenVertexArrays = nullptr;
  g_glDeleteVertexArrays = nullptr;
  g_glBindVertexArray = nullptr;
  g_glBindSampler = nullptr;
  g_swTexW = g_swTexH = 0;
  g_hwFboW = g_hwFboH = 0;
  g_hwEverPresented = false;
  g_hwPresentCount = 0;
  g_lastLoggedGlErr = GL_NO_ERROR;
  if (g_eglDisplay != EGL_NO_DISPLAY) {
    if (g_eglSurface != EGL_NO_SURFACE) {
      eglDestroySurface(g_eglDisplay, g_eglSurface);
      g_eglSurface = EGL_NO_SURFACE;
    }
    if (g_eglContext != EGL_NO_CONTEXT) {
      eglDestroyContext(g_eglDisplay, g_eglContext);
      g_eglContext = EGL_NO_CONTEXT;
    }
    eglTerminate(g_eglDisplay);
    g_eglDisplay = EGL_NO_DISPLAY;
  }
  g_glReady = false;
  g_glThreadId = std::thread::id();
}

bool gl_ensure_current() {
  if (g_gpuFailed || !g_window) return false;
  if (g_glReady) {
    if (g_glThreadId == std::this_thread::get_id()) return true;
    if (eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext) ==
        EGL_TRUE) {
      g_glThreadId = std::this_thread::get_id();
      return true;
    }
    return false;
  }

  g_eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (g_eglDisplay == EGL_NO_DISPLAY) {
    g_gpuFailed = true;
    return false;
  }
  EGLint maj = 0, min = 0;
  if (!eglInitialize(g_eglDisplay, &maj, &min)) {
    g_eglDisplay = EGL_NO_DISPLAY;
    g_gpuFailed = true;
    return false;
  }

  struct EglCandidate {
    int ver;
    EGLint renderable;
    EGLint depth;
    EGLint stencil;
  };
  const EglCandidate es3Candidates[] = {
      {3, EGL_OPENGL_ES3_BIT_KHR, 24, 8},
      {3, EGL_OPENGL_ES3_BIT_KHR, 16, 0},
      {3, EGL_OPENGL_ES3_BIT_KHR, 0, 0},
      {2, EGL_OPENGL_ES2_BIT, 24, 8},
      {2, EGL_OPENGL_ES2_BIT, 16, 0},
      {2, EGL_OPENGL_ES2_BIT, 0, 0},
  };
  const EglCandidate es2Candidates[] = {
      {2, EGL_OPENGL_ES2_BIT, 24, 8},
      {2, EGL_OPENGL_ES2_BIT, 16, 0},
      {2, EGL_OPENGL_ES2_BIT, 0, 0},
  };
  const EglCandidate* cands =
      (g_eglGlesVersion >= 3) ? es3Candidates : es2Candidates;
  const size_t candCount = (g_eglGlesVersion >= 3)
                               ? (sizeof(es3Candidates) / sizeof(es3Candidates[0]))
                               : (sizeof(es2Candidates) / sizeof(es2Candidates[0]));

  for (size_t i = 0; i < candCount; ++i) {
    const EglCandidate& cand = cands[i];
    const EGLint cfgAttrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, cand.renderable,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, cand.depth, EGL_STENCIL_SIZE, cand.stencil,
        EGL_NONE};
    EGLConfig cfg = nullptr;
    EGLint numCfg = 0;
    if (!eglChooseConfig(g_eglDisplay, cfgAttrs, &cfg, 1, &numCfg) || numCfg < 1) {
      continue;
    }
    const EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, cand.ver, EGL_NONE};
    EGLContext ctx =
        eglCreateContext(g_eglDisplay, cfg, EGL_NO_CONTEXT, ctxAttrs);
    if (ctx == EGL_NO_CONTEXT) continue;

    EGLSurface surf =
        eglCreateWindowSurface(g_eglDisplay, cfg, g_window, nullptr);
    if (surf == EGL_NO_SURFACE) {
      eglDestroyContext(g_eglDisplay, ctx);
      continue;
    }
    if (!eglMakeCurrent(g_eglDisplay, surf, surf, ctx)) {
      eglDestroySurface(g_eglDisplay, surf);
      eglDestroyContext(g_eglDisplay, ctx);
      continue;
    }
    g_eglContext = ctx;
    g_eglSurface = surf;
    g_eglGlesVersion = cand.ver;
    break;
  }

  if (g_eglContext == EGL_NO_CONTEXT || g_eglSurface == EGL_NO_SURFACE) {
    eglTerminate(g_eglDisplay);
    g_eglDisplay = EGL_NO_DISPLAY;
    g_gpuFailed = true;
    return false;
  }

  g_glThreadId = std::this_thread::get_id();
  g_glReady = true;
  eglSwapInterval(g_eglDisplay,
                  g_vsyncEnabled.load(std::memory_order_relaxed) ? 1 : 0);

  if (!init_blit_program()) {
    gl_shutdown();
    g_gpuFailed = true;
    return false;
  }
  return true;
}

void gl_draw_bound(GLuint tex, float uScale, float vScale, float vOffset,
                   bool swizzleRB) {
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  EGLint sw = 0, sh = 0;
  eglQuerySurface(g_eglDisplay, g_eglSurface, EGL_WIDTH, &sw);
  eglQuerySurface(g_eglDisplay, g_eglSurface, EGL_HEIGHT, &sh);
  glViewport(0, 0, sw > 0 ? sw : 1, sh > 0 ? sh : 1);

  glDisable(GL_SCISSOR_TEST);
  glDisable(GL_CULL_FACE);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_BLEND);
  glDisable(GL_POLYGON_OFFSET_FILL);
  glDisable(GL_SAMPLE_ALPHA_TO_COVERAGE);
  glDisable(GL_SAMPLE_COVERAGE);
  if (g_eglGlesVersion >= 3) {
    glDisable(0x8C89 /*GL_RASTERIZER_DISCARD*/);
  }
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);

  glActiveTexture(GL_TEXTURE0);
  GLint prevSampler = 0;
  if (g_glBindSampler) {
    glGetIntegerv(0x8919 /*GL_SAMPLER_BINDING*/, &prevSampler);
    g_glBindSampler(0, 0);
  }
  GLint prevVao = 0;
  const bool useVao = (g_glBindVertexArray && g_blitVao != 0);
  if (g_glBindVertexArray) {
    glGetIntegerv(0x85B5 /*GL_VERTEX_ARRAY_BINDING*/, &prevVao);
    if (useVao) {
      g_glBindVertexArray(g_blitVao);
    } else {
      g_glBindVertexArray(0);
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    }
  }

  glUseProgram(g_blitProgram);
  if (g_blitUScaleLoc >= 0) {
    glUniform1f(g_blitUScaleLoc, uScale);
  }
  glUniform1f(g_blitVScaleLoc, vScale);
  glUniform1f(g_blitVOffsetLoc, vOffset);
  glUniform1i(g_blitTexLoc, 0);
  if (g_blitSwizzleLoc >= 0) {
    glUniform1f(g_blitSwizzleLoc, swizzleRB ? 1.0f : 0.0f);
  }
  glBindTexture(GL_TEXTURE_2D, tex);
  if (!useVao) {
    glBindBuffer(GL_ARRAY_BUFFER, g_blitVbo);
    glEnableVertexAttribArray(g_blitPosLoc);
    glVertexAttribPointer(g_blitPosLoc, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
  }
  glDrawArrays(GL_TRIANGLES, 0, 3);
  if (!useVao) {
    glDisableVertexAttribArray(g_blitPosLoc);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
  }
  if (g_glBindVertexArray) {
    g_glBindVertexArray(static_cast<GLuint>(prevVao));
  }
  if (g_glBindSampler) {
    g_glBindSampler(0, static_cast<GLuint>(prevSampler));
  }
  glBindTexture(GL_TEXTURE_2D, 0);
  glUseProgram(0);
}

void gl_finish_frame() {
  eglSwapBuffers(g_eglDisplay, g_eglSurface);
  g_presentedThisStep.store(true, std::memory_order_relaxed);
  // Duplicação de frames: jogos a ~30fps passam a entregar 60 frames/s
  if (g_frameDup.load(std::memory_order_relaxed) &&
      g_target_fps <= 30.5) {
    eglSwapBuffers(g_eglDisplay, g_eglSurface);
  }
}

bool hw_ensure_fbo() {
  if (!gl_ensure_current()) return false;
  unsigned w = g_hwMaxW > 0 ? g_hwMaxW : (g_last_width > 0 ? g_last_width : 512);
  unsigned h = g_hwMaxH > 0 ? g_hwMaxH : (g_last_height > 0 ? g_last_height : 512);
  if (g_hwFbo != 0 && w == g_hwFboW && h == g_hwFboH) return true;

  if (g_hwFbo != 0) {
    glDeleteFramebuffers(1, &g_hwFbo);
    glDeleteTextures(1, &g_hwColorTex);
    if (g_hwDepthRb != 0) glDeleteRenderbuffers(1, &g_hwDepthRb);
    if (g_hwStencilRb != 0) glDeleteRenderbuffers(1, &g_hwStencilRb);
    g_hwFbo = g_hwColorTex = g_hwDepthRb = g_hwStencilRb = 0;
  }

  glGenTextures(1, &g_hwColorTex);
  glBindTexture(GL_TEXTURE_2D, g_hwColorTex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, static_cast<GLsizei>(w),
               static_cast<GLsizei>(h), 0, GL_RGBA, GL_UNSIGNED_BYTE,
               nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  GLuint rb = 0;
  GLuint rbStencil = 0;
  if (g_hwNeedDepth || g_hwNeedStencil) {
    if (g_eglGlesVersion >= 3) {
      glGenRenderbuffers(1, &rb);
      glBindRenderbuffer(GL_RENDERBUFFER, rb);
      glRenderbufferStorage(GL_RENDERBUFFER, 0x88F0 /*GL_DEPTH24_STENCIL8*/,
                            static_cast<GLsizei>(w), static_cast<GLsizei>(h));
      g_hwDepthRb = rb;
    } else {
      glGenRenderbuffers(1, &rb);
      glBindRenderbuffer(GL_RENDERBUFFER, rb);
      glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16,
                            static_cast<GLsizei>(w), static_cast<GLsizei>(h));
      g_hwDepthRb = rb;
      if (g_hwNeedStencil) {
        glGenRenderbuffers(1, &rbStencil);
        glBindRenderbuffer(GL_RENDERBUFFER, rbStencil);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_STENCIL_INDEX8,
                              static_cast<GLsizei>(w), static_cast<GLsizei>(h));
        g_hwStencilRb = rbStencil;
      }
    }
  }

  glGenFramebuffers(1, &g_hwFbo);
  glBindFramebuffer(GL_FRAMEBUFFER, g_hwFbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         g_hwColorTex, 0);
  if (rb != 0) {
    if (g_eglGlesVersion >= 3) {
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, 0x821A /*GL_DEPTH_STENCIL_ATTACHMENT*/,
                                GL_RENDERBUFFER, rb);
    } else {
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                GL_RENDERBUFFER, rb);
      if (rbStencil != 0) {
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
                                  GL_RENDERBUFFER, rbStencil);
      }
    }
  }
  const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  if (status == GL_FRAMEBUFFER_COMPLETE) {
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
  }
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glBindTexture(GL_TEXTURE_2D, 0);
  glBindRenderbuffer(GL_RENDERBUFFER, 0);
  if (status != GL_FRAMEBUFFER_COMPLETE) {
    __android_log_print(ANDROID_LOG_ERROR, "loopgamer-core",
                        "HW FBO incomplete: status=0x%x size=%ux%u gles=%d",
                        status, w, h, g_eglGlesVersion);
    if (g_hwFbo != 0) glDeleteFramebuffers(1, &g_hwFbo);
    if (g_hwColorTex != 0) glDeleteTextures(1, &g_hwColorTex);
    if (g_hwDepthRb != 0) glDeleteRenderbuffers(1, &g_hwDepthRb);
    if (g_hwStencilRb != 0) glDeleteRenderbuffers(1, &g_hwStencilRb);
    g_hwFbo = g_hwColorTex = g_hwDepthRb = g_hwStencilRb = 0;
    return false;
  }
  g_hwFboW = w;
  g_hwFboH = h;
  __android_log_print(ANDROID_LOG_INFO, "loopgamer-core",
                      "HW FBO created %ux%u (fbo=%u tex=%u gles=%d)",
                      w, h, g_hwFbo, g_hwColorTex, g_eglGlesVersion);
  return true;
}

void present_hw_frame(unsigned width, unsigned height) {
  if (!gl_ensure_current() || g_hwFbo == 0 || g_hwColorTex == 0) return;
  // Não recria o FBO aqui (descartaria a imagem recém-renderizada pelo core);
  // projeta apenas a sub-região ativa [0..width, 0..height] do FBO.
  const float uScale =
      (g_hwFboW > 0 && width > 0 && width < g_hwFboW)
          ? (static_cast<float>(width) / static_cast<float>(g_hwFboW))
          : 1.0f;
  const float vMax =
      (g_hwFboH > 0 && height > 0 && height < g_hwFboH)
          ? (static_cast<float>(height) / static_cast<float>(g_hwFboH))
          : 1.0f;
  gl_draw_bound(g_hwColorTex, uScale, vMax, 0.5f * vMax, false);
  const GLenum err = glGetError();
  ++g_hwPresentCount;
  if (g_hwPresentCount <= 3 ||
      (err != GL_NO_ERROR && err != g_lastLoggedGlErr)) {
    if (err != GL_NO_ERROR) g_lastLoggedGlErr = err;
    __android_log_print(
        err == GL_NO_ERROR ? ANDROID_LOG_INFO : ANDROID_LOG_WARN,
        "loopgamer-core",
        "HW GL present #%llu: frame=%ux%u fbo=%ux%u tex=%u err=0x%x",
        static_cast<unsigned long long>(g_hwPresentCount),
        width, height, g_hwFboW, g_hwFboH, g_hwColorTex, err);
  }
  gl_finish_frame();
}

void present_sw_frame_gl(const void* data, unsigned w, unsigned h,
                         size_t pitch) {
  if (!gl_ensure_current()) return;

  if (g_eglGlesVersion >= 3) {
    glBindBuffer(0x88EC /*GL_PIXEL_UNPACK_BUFFER*/, 0);
    glPixelStorei(0x0CF2 /*GL_UNPACK_ROW_LENGTH*/, 0);
  }

  // (Re)aloca a textura quando a resolução do core muda
  if (g_swTex == 0 || w != g_swTexW || h != g_swTexH ||
      g_pixel_format != g_swTexFormat) {
    if (g_swTex != 0) glDeleteTextures(1, &g_swTex);
    glGenTextures(1, &g_swTex);
    glBindTexture(GL_TEXTURE_2D, g_swTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (g_pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB565, static_cast<GLsizei>(w),
                   static_cast<GLsizei>(h), 0, GL_RGB565,
                   GL_UNSIGNED_SHORT_5_6_5, nullptr);
    } else if (g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
      // Upload universal via GL_RGBA/GL_RGBA + swizzle B<->R no fragment shader
      // (evita GL_INVALID_OPERATION de GL_RGBA+GL_BGRA_EXT no GLES Android).
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, static_cast<GLsizei>(w),
                   static_cast<GLsizei>(h), 0, GL_RGBA, GL_UNSIGNED_BYTE,
                   nullptr);
    } else {
      glDeleteTextures(1, &g_swTex);
      g_swTex = 0;
      return; // formato não suportado no upload GL → caller usa fallback CPU
    }
    g_swTexW = w;
    g_swTexH = h;
    g_swTexFormat = g_pixel_format;
  }

  glBindTexture(GL_TEXTURE_2D, g_swTex);
  const bool isRgb565 = (g_pixel_format == RETRO_PIXEL_FORMAT_RGB565);
  glPixelStorei(GL_UNPACK_ALIGNMENT, isRgb565 ? 2 : 4);
  const auto* bytes = static_cast<const uint8_t*>(data);
  const GLsizei rowBytes =
      static_cast<GLsizei>(w * (isRgb565 ? sizeof(uint16_t) : sizeof(uint32_t)));
  const GLenum uploadFmt = isRgb565 ? GL_RGB565 : GL_RGBA;
  const GLenum uploadType =
      isRgb565 ? GL_UNSIGNED_SHORT_5_6_5 : GL_UNSIGNED_BYTE;
  if (pitch == static_cast<size_t>(rowBytes)) {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, static_cast<GLsizei>(w),
                    static_cast<GLsizei>(h), uploadFmt, uploadType, bytes);
  } else {
    for (unsigned y = 0; y < h; ++y) {
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, static_cast<GLsizei>(y),
                      static_cast<GLsizei>(w), 1, uploadFmt, uploadType,
                      bytes + y * pitch);
    }
  }
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  // Frames de software têm origem top-left: v = 0.5 - 0.5*y → [1, 0]
  gl_draw_bound(g_swTex, 1.0f, -1.0f, 0.5f,
                g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888);
  gl_finish_frame();
}

// Fallback: caminho original via ANativeWindow_lock (lento, usado só se EGL falhar)
void present_sw_frame_cpu(const void* data, unsigned width, unsigned height,
                          size_t pitch) {
  if (!g_window) return;
  const int32_t desired_format =
      (g_pixel_format == RETRO_PIXEL_FORMAT_RGB565)
          ? WINDOW_FORMAT_RGB_565
          : WINDOW_FORMAT_RGBA_8888;
  if (width != g_configured_width || height != g_configured_height ||
      desired_format != g_configured_win_format) {
    ANativeWindow_setBuffersGeometry(g_window, width, height, desired_format);
    g_configured_width = width;
    g_configured_height = height;
    g_configured_win_format = desired_format;
  }
  ANativeWindow_Buffer buffer;
  if (ANativeWindow_lock(g_window, &buffer, nullptr) != 0) return;
  const auto* __restrict__ src_bytes = static_cast<const uint8_t*>(data);
  if (desired_format == WINDOW_FORMAT_RGB_565) {
    auto* __restrict__ dst_base = static_cast<uint16_t*>(buffer.bits);
    if (buffer.stride == static_cast<int32_t>(width) &&
        pitch == width * sizeof(uint16_t)) {
      std::memcpy(dst_base, src_bytes, width * height * sizeof(uint16_t));
    } else {
      const size_t row_bytes = width * sizeof(uint16_t);
      for (unsigned y = 0; y < height; ++y) {
        std::memcpy(dst_base + y * buffer.stride,
                    src_bytes + y * pitch, row_bytes);
      }
    }
  } else if (g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
    auto* __restrict__ dst_base = static_cast<uint32_t*>(buffer.bits);
    for (unsigned y = 0; y < height; ++y) {
      uint32_t* __restrict__ dst_row = dst_base + y * buffer.stride;
      const auto* __restrict__ src_row =
          reinterpret_cast<const uint32_t*>(src_bytes + y * pitch);
      unsigned x = 0;
#if defined(__aarch64__) || defined(__ARM_NEON)
      for (; x + 15 < width; x += 16) {
        uint8x16x4_t src =
            vld4q_u8(reinterpret_cast<const uint8_t*>(src_row + x));
        uint8x16x4_t dst;
        dst.val[0] = src.val[2];
        dst.val[1] = src.val[1];
        dst.val[2] = src.val[0];
        dst.val[3] = vdupq_n_u8(0xFF);
        vst4q_u8(reinterpret_cast<uint8_t*>(dst_row + x), dst);
      }
#endif
      for (; x < width; ++x) {
        const uint32_t px = src_row[x];
        dst_row[x] = 0xFF000000u | ((px & 0x000000FFu) << 16) |
                     (px & 0x0000FF00u) | ((px & 0x00FF0000u) >> 16);
      }
    }
  } else {
    auto* __restrict__ dst_base = static_cast<uint32_t*>(buffer.bits);
    for (unsigned y = 0; y < height; ++y) {
      uint32_t* __restrict__ dst_row = dst_base + y * buffer.stride;
      const auto* __restrict__ src_row =
          reinterpret_cast<const uint16_t*>(src_bytes + y * pitch);
      for (unsigned x = 0; x < width; ++x) {
        const uint16_t px = src_row[x];
        const uint32_t r = ((px >> 10) & 0x1Fu) << 3;
        const uint32_t g = ((px >> 5) & 0x1Fu) << 3;
        const uint32_t b = (px & 0x1Fu) << 3;
        dst_row[x] = 0xFF000000u | (b << 16) | (g << 8) | r;
      }
    }
  }
  ANativeWindow_unlockAndPost(g_window);
}

// Callbacks do core → frontend (HW render)
void hw_context_reset() {
  // O core chama isso durante retro_load_game/retro_run; garante contexto GL.
  gl_ensure_current();
}

uintptr_t hw_get_current_framebuffer() {
  g_hwCbCalledThisStep = true;
  if (!hw_ensure_fbo()) return 0;
  return static_cast<uintptr_t>(g_hwFbo);
}

retro_proc_address_t hw_get_proc_address(const char* sym) {
  return resolve_gl_proc(sym);
}

bool should_skip_present() {
  const int skip = g_frame_skip.load(std::memory_order_relaxed);
  return skip > 0 && (++g_frame_counter % (skip + 1)) != 0;
}

const char* get_core_variable(const char* key) {
  if (!key) return nullptr;
  const std::string_view k(key);

  // Garante fallback automático Vulkan → OpenGL ES (ou software se forçado)
  // quando o dispositivo não passa no probe Vulkan.
  if (k == "ppsspp_backend") {
    if (g_forceSoftwareCore) return "none";
    const auto it = g_coreVars.find(key);
    if (it != g_coreVars.end()) {
      if (it->second == "vulkan" && !vkfe::vulkan_requested()) return "opengl";
      return it->second.c_str();
    }
    return vkfe::vulkan_requested() ? "vulkan" : "opengl";
  }
  if (k == "ppsspp_software_rendering" && g_forceSoftwareCore) {
    return "enabled";
  }

  // Overrides vindos das configurações do usuário (k=v;k=v via JNI)
  const auto it = g_coreVars.find(key);
  if (it != g_coreVars.end()) return it->second.c_str();

  // PPSSPP: Configurações de Máximo Desempenho (60 FPS) compatíveis com
  // libretro_core_options.h do PPSSPP upstream
  // 1. Resolução nativa 1x (480x272) padrão sem upscaling
  if (k == "ppsspp_internal_resolution") return "480x272";

  // 2. JIT Recompiler ARM64
  if (k == "ppsspp_cpu_core") return "JIT";

  // 3. Skip GPU Readbacks: elimina o maior gargalo em God of War / jogos 3D,
  // mantendo buffer effects habilitados para não causar tela preta nem
  // desativar o AutoFrameSkip do PPSSPP.
  if (k == "ppsspp_skip_gpu_readbacks") return "enabled";
  if (k == "ppsspp_skip_buffer_effects") return "disabled";
  if (k == "ppsspp_lower_resolution_for_effects") return "Balanced";
  if (k == "ppsspp_depth_raster") return "off";

  // 4. Desliga upscaling pesado de texturas em CPU
  if (k == "ppsspp_texture_scaling_type") return "xbrz";
  if (k == "ppsspp_texture_scaling_level") return "disabled";
  if (k == "ppsspp_texture_deposterize") return "disabled";
  if (k == "ppsspp_texture_anisotropic_filtering" ||
      k == "ppsspp_anisotropic_filtering")
    return "disabled";
  if (k == "ppsspp_texture_filtering") return "Auto";

  // 5. Frameskip dinâmico (AutoFrameSkip não reduz FPS quando GPU está livre)
  if (k == "ppsspp_auto_frameskip") return "enabled";
  if (k == "ppsspp_frameskip") return "disabled";
  if (k == "ppsspp_frameskiptype") return "Number of frames";

  // 6. Memória e IO
  if (k == "ppsspp_fast_memory") return "disabled"; // Evita SIGSEGV com ART
  if (k == "ppsspp_ignore_bad_memory_access") return "enabled";
  if (k == "ppsspp_io_timing_method") return "Fast";
  if (k == "ppsspp_locked_cpu_speed") return "disabled";

  // 7. Pipelining multi-thread Vulkan/GL (3 frames inflight)
  if (k == "ppsspp_inflight_frames") return "Up to 2";
  if (k == "ppsspp_vertex_cache") return "enabled";
  if (k == "ppsspp_hardware_transform") return "enabled";
  if (k == "ppsspp_software_skinning") return "enabled";
  if (k == "ppsspp_lazy_texture_caching") return "enabled";
  if (k == "ppsspp_retain_changed_textures") return "enabled";
  if (k == "ppsspp_sound_speedhack") return "enabled";
  if (k == "ppsspp_spline_quality") return "low";
  if (k == "ppsspp_force_max_fps") return "disabled";
  if (k == "ppsspp_separate_sas_thread") return "enabled";
  if (k == "ppsspp_separate_io_thread") return "enabled";
  if (k == "ppsspp_cache_iso") return "enabled";

  // PCSX ReARMed (PS1)
  if (k == "pcsx_rearmed_neon_interlace_enable") return "enabled";
  if (k == "pcsx_rearmed_neon_enhancement_enable") return "disabled";
  if (k == "pcsx_rearmed_frameskip") return "0";
  if (k == "pcsx_rearmed_dithering") return "disabled";

  // Mupen64Plus (N64)
  if (k == "mupen64plus-cpucore") return "dynamic_recompiler";
  if (k == "mupen64plus-rspmode") return "HLE";

  // Snes9x & Genesis Plus GX
  if (k == "snes9x_overclock_superfx") return "100%";
  if (k == "genesis_plus_gx_overclock") return "100%";

  return nullptr;
}

bool environment_callback(unsigned cmd, void* data) {
  switch (cmd) {
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      const auto* fmt = static_cast<const retro_pixel_format*>(data);
      if (fmt) {
        g_pixel_format = *fmt;
        return true;
      }
      return false;
    }
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: {
      *static_cast<const char**>(data) = g_system_dir.c_str();
      return true;
    }
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: {
      *static_cast<const char**>(data) = g_saves_dir.c_str();
      return true;
    }
    case RETRO_ENVIRONMENT_GET_CAN_DUPE: {
      if (data) *static_cast<bool*>(data) = true;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
      auto* cb = static_cast<retro_hw_render_callback*>(data);
      if (!cb || g_forceSoftwareCore) return false;
      const auto t = cb->context_type;

      // Vulkan: o core cria o VkDevice via negotiation interface; nós
      // providenciamos instance/device/queue/swapchain. Só aceitamos se o
      // usuário escolheu Vulkan e o probe passou — senão o core tenta GL.
      if (t == RETRO_HW_CONTEXT_VULKAN) {
        if (!vkfe::vulkan_requested()) return false;
        g_hwCoreReset = cb->context_reset;
        // Campos "set by frontend" que o core pode consultar
        cb->get_current_framebuffer = nullptr;
        cb->get_proc_address = nullptr;
        cb->depth = false;
        cb->stencil = false;
        cb->bottom_left_origin = false;
        cb->version_major = 1;
        cb->version_minor = 0;
        cb->cache_context = false;
        cb->debug_context = false;
        // context_reset NÃO é chamado aqui: só depois que a negotiation
        // interface for processada e o VkDevice/swapchain existirem.
        g_hwCb = *cb;
        g_hwIsVulkan = true;
        g_hwCbActive = true;
        __android_log_print(ANDROID_LOG_INFO, "loopgamer-core",
                            "SET_HW_RENDER Vulkan accepted");
        return true;
      }

      const bool supported =
          t == RETRO_HW_CONTEXT_OPENGLES2 ||
          t == RETRO_HW_CONTEXT_OPENGLES3 ||
          t == RETRO_HW_CONTEXT_OPENGLES_CORE ||
          t == RETRO_HW_CONTEXT_OPENGL_CORE ||
          t == RETRO_HW_CONTEXT_OPENGL;
      if (!supported) return false; // D3D etc.: cai para software

      g_hwCoreReset = cb->context_reset;
      const bool wantEs3 = (t == RETRO_HW_CONTEXT_OPENGLES3 ||
                          t == RETRO_HW_CONTEXT_OPENGL_CORE ||
                          t == RETRO_HW_CONTEXT_OPENGLES_CORE ||
                          g_hwPreferredEs3);
      g_eglGlesVersion = wantEs3 ? 3 : 2;
      g_hwNeedDepth = cb->depth;
      g_hwNeedStencil = cb->stencil;

      if (!gl_ensure_current()) return false;

      // Campos "set by frontend" — devem ser escritos no cb do core para
      // que ele consiga get_proc_address/get_current_framebuffer.
      cb->get_current_framebuffer = hw_get_current_framebuffer;
      cb->get_proc_address = hw_get_proc_address;
      cb->bottom_left_origin = true; // convenção OpenGL
      cb->version_major = static_cast<unsigned>(g_eglGlesVersion);
      cb->version_minor = 0;
      cb->cache_context = false;
      cb->debug_context = false;

      g_hwIsVulkan = false;
      g_hwCb = *cb;

      // context_reset é adiado para pós-retro_load_game (ex.: PPSSPP só atribui
      // Libretro::ctx após CreateGraphicsContext retornar).
      g_hwActive = false;
      g_hwCbActive = true;
      __android_log_print(ANDROID_LOG_INFO, "loopgamer-core",
                          "SET_HW_RENDER GLES%d (req=%d depth=%d stencil=%d)",
                          g_eglGlesVersion, static_cast<int>(t),
                          g_hwNeedDepth ? 1 : 0, g_hwNeedStencil ? 1 : 0);
      return true;
    }
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
      auto* logCb = static_cast<retro_log_callback*>(data);
      if (!logCb) return false;
      logCb->log = core_log_printf;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
      const auto* av = static_cast<const retro_system_av_info*>(data);
      if (!av) return false;
      if (av->geometry.base_width > 0 && av->geometry.base_height > 0) {
        g_last_width = av->geometry.base_width;
        g_last_height = av->geometry.base_height;
      }
      if (av->geometry.max_width > 0 && av->geometry.max_height > 0) {
        g_hwMaxW = av->geometry.max_width;
        g_hwMaxH = av->geometry.max_height;
      }
      if (av->timing.fps > 10.0) g_target_fps = av->timing.fps;
      if (av->timing.sample_rate > 8000.0) {
        g_sample_rate = static_cast<int>(av->timing.sample_rate);
      }
      return true;
    }
    case RETRO_ENVIRONMENT_SET_GEOMETRY: {
      const auto* geom = static_cast<const retro_game_geometry*>(data);
      if (!geom) return false;
      if (geom->base_width > 0 && geom->base_height > 0) {
        g_last_width = geom->base_width;
        g_last_height = geom->base_height;
      }
      if (geom->max_width > 0 && geom->max_height > 0) {
        g_hwMaxW = geom->max_width;
        g_hwMaxH = geom->max_height;
      }
      return true;
    }
    case RETRO_ENVIRONMENT_GET_FASTFORWARDING: {
      if (data) *static_cast<bool*>(data) = false;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE: {
      if (data) *static_cast<bool*>(data) = true;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_VARIABLE: {
      const auto* var = static_cast<const retro_variable*>(data);
      if (var && var->key && var->value) {
        g_coreVars[var->key] = var->value;
        return true;
      }
      return false;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      auto* var = static_cast<retro_variable*>(data);
      if (var && var->key) {
        var->value = get_core_variable(var->key);
        return var->value != nullptr;
      }
      return false;
    }
    case RETRO_ENVIRONMENT_SET_VARIABLES: {
      return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: {
      if (data) *static_cast<bool*>(data) = false;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL: {
      return true;
    }
    case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE: {
      if (data) *static_cast<int*>(data) = 1 | 2;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: {
      if (data) *static_cast<unsigned*>(data) = 1;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
    case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS: {
      return true;
    }
    case RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES: {
      if (data) {
        *static_cast<uint64_t*>(data) = (1ULL << 1) | (1ULL << 5);
      }
      return true;
    }
    case RETRO_ENVIRONMENT_GET_USERNAME: {
      if (data) *static_cast<const char**>(data) = "LoopGamer";
      return true;
    }
    case RETRO_ENVIRONMENT_GET_LANGUAGE: {
      if (data) *static_cast<unsigned*>(data) = 0; // RETRO_LANGUAGE_ENGLISH
      return true;
    }
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: {
      if (data) *static_cast<bool*>(data) = true;
      return true;
    }
    case 44: // SET_SERIALIZATION_QUIRKS
      return true;
    case (44 | 0x10000): { // SET_HW_SHARED_CONTEXT
      return true;
    }
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER: {
      if (!data || g_forceSoftwareCore) return false;
      auto* t = static_cast<int*>(data);
      if (vkfe::vulkan_requested()) {
        g_hwPreferredEs3 = false;
        *t = RETRO_HW_CONTEXT_VULKAN;
      } else {
        g_hwPreferredEs3 = true;
        *t = RETRO_HW_CONTEXT_OPENGLES3;
      }
      return true;
    }
    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE: {
      // Core pede a interface Vulkan pronta (após context_reset).
      auto* out = static_cast<void**>(data);
      if (out && vkfe::get_render_interface(out)) return true;
      return false;
    }
    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE: {
      // Inicializamos Vulkan aqui (instance/surface/device/swapchain) e adiamos
      // context_reset para após retro_load_game retornar (contrato libretro).
      if (data && vkfe::on_negotiation_iface(data, g_window)) {
        return true;
      }
      g_hwIsVulkan = false;
      g_hwCbActive = false;
      vkfe::set_backend(0);
      return false;
    }
    case RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT: {
      // {int interface_type; unsigned interface_version;}
      struct NegSupport {
        int interface_type;
        unsigned interface_version;
      };
      auto* ns = static_cast<NegSupport*>(data);
      if (!ns) return false;
      ns->interface_type = RETRO_HW_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
      ns->interface_version = 2;
      return true;
    }
    default:
      return false;
  }
}

void video_refresh_callback(const void* data, unsigned width, unsigned height, size_t pitch) {
  g_videoCbThisStep = true;
  if (width == 0 || height == 0) return;

  g_last_width = width;
  g_last_height = height;

  const bool is_hw_frame =
      data != nullptr &&
      reinterpret_cast<uintptr_t>(data) == ~static_cast<uintptr_t>(0);
  if (data == nullptr) {
    // Frame duplicado/pulo intencional pelo core (ex.: 30fps / AutoFrameSkip):
    // SurfaceTexture mantém o frame anterior visível sem swap vazio.
    return;
  }

  // Frames de HW (especialmente Vulkan) não devem pular present para não
  // deixar swapchain/semáforos do retro_run órfãos.
  if (!is_hw_frame && should_skip_present()) return;

  if (is_hw_frame) {
    if (vkfe::is_active()) {
      vkfe::present(width, height);
      g_presentedThisStep.store(true, std::memory_order_relaxed);
    } else {
      g_hwEverPresented = true;
      present_hw_frame(width, height);
    }
    return;
  }

  // Caminho GPU: upload para textura + blit (RGB565 nativo ou XRGB8888 via shader swizzle).
  const bool gl_ok = gl_ensure_current() && g_blitProgram != 0;
  const bool format_ok =
      g_pixel_format == RETRO_PIXEL_FORMAT_RGB565 ||
      g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888;
  if (gl_ok && format_ok) {
    present_sw_frame_gl(data, width, height, pitch);
    return;
  }
  present_sw_frame_cpu(data, width, height, pitch);
}

inline void push_audio_sample_unlocked(int16_t s) {
  if (g_audio_count < kAudioRingCapacity) {
    g_audio_ring[g_audio_write_idx] = s;
    g_audio_write_idx = (g_audio_write_idx + 1) & (kAudioRingCapacity - 1);
    ++g_audio_count;
  }
}

void audio_sample_callback(int16_t left, int16_t right) {
  std::lock_guard<std::mutex> lock(g_audio_mutex);
  push_audio_sample_unlocked(left);
  push_audio_sample_unlocked(right);
}

size_t audio_sample_batch_callback(const int16_t* data, size_t frames) {
  if (!data || frames == 0) return 0;
  std::lock_guard<std::mutex> lock(g_audio_mutex);
  const size_t samples = frames * 2;
  for (size_t i = 0; i < samples; ++i) {
    if (g_audio_count >= kAudioRingCapacity) break;
    g_audio_ring[g_audio_write_idx] = data[i];
    g_audio_write_idx = (g_audio_write_idx + 1) & (kAudioRingCapacity - 1);
    ++g_audio_count;
  }
  return frames;
}

void input_poll_callback() {}

int16_t input_state_callback(unsigned port, unsigned device, unsigned index, unsigned id) {
  if (port != 0) return 0;
  if (device == 1) {
    uint32_t mask = g_joypad_mask.load(std::memory_order_relaxed);
    const uint32_t t_mask = g_turbo_mask.load(std::memory_order_relaxed);
    if (t_mask != 0) {
      const int period = g_turbo_half_period.load(std::memory_order_relaxed);
      const uint32_t f = g_emu_frame_count.load(std::memory_order_relaxed);
      const bool active = ((f / (period > 0 ? period : 3)) % 2) == 0;
      if (!active) {
        mask &= ~t_mask;
      }
    }
    // RETRO_DEVICE_ID_JOYPAD_MASK no Libretro é 256
    if (id == 256 || id == 255 || id == 0x10033) {
      return static_cast<int16_t>(mask & 0xFFFF);
    }
    if (id < 16) {
      return (mask & (1u << id)) ? 1 : 0;
    }
  }
  if (device == 5 && index == 0) {
    return (id == 0)
        ? g_left_x.load(std::memory_order_relaxed)
        : g_left_y.load(std::memory_order_relaxed);
  }
  return 0;
}

}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeLoadCoreAndRom(
    JNIEnv* env,
    jobject,
    jstring core_path_j,
    jstring rom_path_j,
    jstring system_dir_j,
    jstring saves_dir_j,
    jobject surface_j) {
  std::lock_guard<std::mutex> lock(g_mutex);

  const char* core_c = env->GetStringUTFChars(core_path_j, nullptr);
  const char* rom_c = env->GetStringUTFChars(rom_path_j, nullptr);
  const char* sys_c = env->GetStringUTFChars(system_dir_j, nullptr);
  const char* sav_c = env->GetStringUTFChars(saves_dir_j, nullptr);

  g_system_dir = sys_c;
  g_saves_dir = sav_c;
  std::string core_path(core_c);
  std::string rom_path(rom_c);

  env->ReleaseStringUTFChars(core_path_j, core_c);
  env->ReleaseStringUTFChars(rom_path_j, rom_c);
  env->ReleaseStringUTFChars(system_dir_j, sys_c);
  env->ReleaseStringUTFChars(saves_dir_j, sav_c);

  g_core.handle = dlopen(core_path.c_str(), RTLD_LAZY);
  if (!g_core.handle) {
    __android_log_print(ANDROID_LOG_ERROR, "loopgamer-core",
                        "dlopen failed for %s: %s", core_path.c_str(),
                        dlerror());
    return JNI_FALSE;
  }

  #define LOAD_SYM(name) \
    g_core.name = reinterpret_cast<decltype(g_core.name)>(dlsym(g_core.handle, #name)); \
    if (!g_core.name) { dlclose(g_core.handle); g_core.handle = nullptr; return JNI_FALSE; }

  LOAD_SYM(retro_init)
  LOAD_SYM(retro_deinit)
  LOAD_SYM(retro_set_environment)
  LOAD_SYM(retro_set_video_refresh)
  LOAD_SYM(retro_set_audio_sample)
  LOAD_SYM(retro_set_audio_sample_batch)
  LOAD_SYM(retro_set_input_poll)
  LOAD_SYM(retro_set_input_state)
  LOAD_SYM(retro_get_system_av_info)
  LOAD_SYM(retro_load_game)
  LOAD_SYM(retro_unload_game)
  LOAD_SYM(retro_run)
  LOAD_SYM(retro_serialize_size)
  LOAD_SYM(retro_serialize)
  LOAD_SYM(retro_unserialize)
  #undef LOAD_SYM

  g_window = ANativeWindow_fromSurface(env, surface_j);
  g_configured_width = 0;
  g_configured_height = 0;
  g_configured_win_format = 0;
  g_frame_counter = 0;
  g_gpuFailed = false;
  g_glReady = false;
  g_eglDisplay = EGL_NO_DISPLAY;
  g_eglSurface = EGL_NO_SURFACE;
  g_eglContext = EGL_NO_CONTEXT;
  g_eglGlesVersion = 2;
  g_pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;
  g_swTexFormat = RETRO_PIXEL_FORMAT_RGB565;
  g_hwNeedDepth = false;
  g_hwNeedStencil = false;
  g_hwPreferredEs3 = false;
  g_hwCbActive = false;
  g_hwActive = false;
  g_hwIsVulkan = false;
  g_hwCoreReset = nullptr;
  g_hwCb = retro_hw_render_callback{};
  g_hwFbo = g_hwColorTex = g_hwDepthRb = g_hwStencilRb = 0;
  g_hwFboW = g_hwFboH = 0;
  g_hwMaxW = g_hwMaxH = 0;
  g_swTex = 0;
  g_swTexW = g_swTexH = 0;
  g_videoCbThisStep = false;
  g_hwCbCalledThisStep = false;
  g_hwEverPresented = false;
  g_hwPresentCount = 0;
  g_lastLoggedGlErr = GL_NO_ERROR;
  g_presentedThisStep.store(false, std::memory_order_relaxed);

  {
    std::lock_guard<std::mutex> audio_lock(g_audio_mutex);
    g_audio_read_idx = 0;
    g_audio_write_idx = 0;
    g_audio_count = 0;
  }

  g_core.retro_set_environment(environment_callback);
  g_core.retro_set_video_refresh(video_refresh_callback);
  g_core.retro_set_audio_sample(audio_sample_callback);
  g_core.retro_set_audio_sample_batch(audio_sample_batch_callback);
  g_core.retro_set_input_poll(input_poll_callback);
  g_core.retro_set_input_state(input_state_callback);
  g_core.retro_init();

  retro_game_info info{};
  info.path = rom_path.c_str();
  if (!g_core.retro_load_game(&info)) {
    if (g_core.retro_deinit) g_core.retro_deinit();
    vkfe::shutdown_public();
    gl_shutdown();
    dlclose(g_core.handle);
    g_core = LibretroCoreSymbols{};
    if (g_window) {
      ANativeWindow_release(g_window);
      g_window = nullptr;
    }
    return JNI_FALSE;
  }

  retro_system_av_info av{};
  g_core.retro_get_system_av_info(&av);
  if (av.geometry.base_width > 0 && av.geometry.base_height > 0) {
    g_last_width = av.geometry.base_width;
    g_last_height = av.geometry.base_height;
  }
  if (av.timing.fps > 10.0) {
    g_target_fps = av.timing.fps;
  }
  if (av.timing.sample_rate > 8000.0) {
    g_sample_rate = static_cast<int>(av.timing.sample_rate);
  }
  g_hwMaxW = av.geometry.max_width;
  g_hwMaxH = av.geometry.max_height;

  // Dispara context_reset só após retro_load_game retornar true e av_info
  // popular g_hwMaxW/g_hwMaxH (cores como PPSSPP só definem Libretro::ctx depois).
  if (g_hwCbActive) {
    if (g_hwIsVulkan) {
      if (vkfe::is_active()) {
        if (g_hwCoreReset) g_hwCoreReset();
        g_hwActive = true;
        __android_log_print(
            ANDROID_LOG_INFO, "loopgamer-core",
            "HW context_reset OK: Vulkan active (max=%ux%u base=%ux%u)",
            g_hwMaxW, g_hwMaxH, g_last_width, g_last_height);
      } else {
        __android_log_print(ANDROID_LOG_WARN, "loopgamer-core",
                            "HW context_reset skipped: Vulkan not active");
        g_hwCbActive = false;
        g_hwIsVulkan = false;
        g_hwActive = false;
      }
    } else if (gl_ensure_current()) {
      if (g_hwCoreReset) g_hwCoreReset();
      g_hwActive = true;
      __android_log_print(
          ANDROID_LOG_INFO, "loopgamer-core",
          "HW context_reset OK: GLES%d active (max=%ux%u base=%ux%u)",
          g_eglGlesVersion, g_hwMaxW, g_hwMaxH, g_last_width, g_last_height);
    } else {
      __android_log_print(ANDROID_LOG_WARN, "loopgamer-core",
                          "HW context_reset failed: gl_ensure_current false");
      g_hwCbActive = false;
      g_hwActive = false;
    }
  }

  // O contexto EGL pode ter sido criado na thread principal durante
  // retro_load_game / context_reset. Libera para a thread de emulação
  // poder fazer eglMakeCurrent.
  if (g_glReady) {
    gl_release_context();
  }

  return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeStepFrame(JNIEnv*, jobject) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_core.handle && g_core.retro_run) {
    g_emu_frame_count.fetch_add(1, std::memory_order_relaxed);
    g_videoCbThisStep = false;
    g_hwCbCalledThisStep = false;
    g_presentedThisStep.store(false, std::memory_order_relaxed);
    // Vulkan: adquire a próxima imagem do swapchain antes do retro_run
    // (get_sync_index do core precisa retornar um índice válido durante o run)
    if (vkfe::is_active()) {
      vkfe::begin_frame();
    } else if (g_hwCbActive) {
      // Se o core usa HW render GL, o contexto EGL precisa estar current
      gl_ensure_current();
    }
    g_core.retro_run();
    // Fallback apenas se o core desenhou no FBO HW mas não chamou video_refresh
    // (nunca força swap em frames anulados via video_refresh(nullptr)).
    if (g_hwCbActive && !g_hwIsVulkan &&
        !g_videoCbThisStep &&
        g_hwCbCalledThisStep &&
        g_hwEverPresented &&
        !g_presentedThisStep.load(std::memory_order_relaxed) &&
        g_hwColorTex != 0) {
      present_hw_frame(g_last_width, g_last_height);
    }
  }
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetTurboConfig(
    JNIEnv*, jobject, jint mask, jint period) {
  g_turbo_mask.store(static_cast<uint32_t>(mask), std::memory_order_relaxed);
  g_turbo_half_period.store(std::clamp(static_cast<int>(period), 1, 10), std::memory_order_relaxed);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetFrameSkip(
    JNIEnv*, jobject, jint skip) {
  g_frame_skip.store(std::clamp(static_cast<int>(skip), 0, 3), std::memory_order_relaxed);
}

extern "C" JNIEXPORT jint JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeDrainAudioBuffer(
    JNIEnv* env, jobject, jshortArray out_pcm) {
  std::lock_guard<std::mutex> lock(g_audio_mutex);
  if (g_audio_count == 0) return 0;
  const jsize cap = env->GetArrayLength(out_pcm);
  const size_t count = std::min(static_cast<size_t>(cap), g_audio_count);

  int16_t temp[4096];
  const size_t batch = std::min(count, static_cast<size_t>(4096));
  for (size_t i = 0; i < batch; ++i) {
    temp[i] = g_audio_ring[g_audio_read_idx];
    g_audio_read_idx = (g_audio_read_idx + 1) & (kAudioRingCapacity - 1);
  }
  g_audio_count -= batch;
  env->SetShortArrayRegion(out_pcm, 0, static_cast<jsize>(batch), temp);
  return static_cast<jint>(batch);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetCoreOptions(
    JNIEnv* env, jobject, jstring options_j) {
  if (!options_j) return;
  const char* opts = env->GetStringUTFChars(options_j, nullptr);
  if (!opts) return;
  std::unordered_map<std::string, std::string> parsed;
  std::string_view sv(opts);
  size_t pos = 0;
  while (pos <= sv.size()) {
    const size_t semi = sv.find(';', pos);
    const std::string_view pair =
        sv.substr(pos, semi == std::string_view::npos ? std::string_view::npos
                                                    : semi - pos);
    const size_t eq = pair.find('=');
    if (eq != std::string_view::npos && eq > 0) {
      parsed[std::string(pair.substr(0, eq))] =
          std::string(pair.substr(eq + 1));
    }
    if (semi == std::string_view::npos) break;
    pos = semi + 1;
  }
  env->ReleaseStringUTFChars(options_j, opts);
  g_coreVars = std::move(parsed);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetRendererMode(
    JNIEnv*, jobject, jboolean software) {
  g_forceSoftwareCore = software == JNI_TRUE;
  vkfe::set_backend(software == JNI_TRUE ? 1 : 0);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetCustomVulkanDriver(
    JNIEnv* env,
    jobject,
    jstring hook_dir_j,
    jstring tmp_dir_j,
    jstring drv_dir_j,
    jstring drv_name_j,
    jboolean turbo) {
  auto to_std = [env](jstring s) -> std::string {
    if (!s) return {};
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string out = c ? c : "";
    if (c) env->ReleaseStringUTFChars(s, c);
    return out;
  };
  const std::string hookDir = to_std(hook_dir_j);
  const std::string tmpDir = to_std(tmp_dir_j);
  const std::string drvDir = to_std(drv_dir_j);
  const std::string drvName = to_std(drv_name_j);
  vkfe::set_custom_driver(hookDir.c_str(), tmpDir.c_str(), drvDir.c_str(),
                          drvName.c_str(), turbo == JNI_TRUE);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetGpuBackend(
    JNIEnv*, jobject, jint mode) {
  // 0 = OpenGL ES, 1 = software CPU, 2 = Vulkan
  vkfe::set_backend(mode);
  g_forceSoftwareCore = (mode == 1);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetFrameDup(
    JNIEnv*, jobject, jboolean enabled) {
  g_frameDup.store(enabled == JNI_TRUE, std::memory_order_relaxed);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetVsync(
    JNIEnv*, jobject, jboolean enabled) {
  const bool on = (enabled == JNI_TRUE);
  g_vsyncEnabled.store(on, std::memory_order_relaxed);
  vkfe::set_vsync(on);
  if (g_glReady && g_glThreadId == std::this_thread::get_id()) {
    eglSwapInterval(g_eglDisplay, on ? 1 : 0);
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeGetSampleRate(JNIEnv*, jobject) {
  return static_cast<jint>(g_sample_rate);
}

extern "C" JNIEXPORT jdouble JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeGetTargetFps(JNIEnv*, jobject) {
  return static_cast<jdouble>(g_target_fps);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeUpdateInput(
    JNIEnv*, jobject, jint mask, jshort lx, jshort ly) {
  g_joypad_mask.store(static_cast<uint32_t>(mask), std::memory_order_relaxed);
  g_left_x.store(lx, std::memory_order_relaxed);
  g_left_y.store(ly, std::memory_order_relaxed);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSaveState(
    JNIEnv* env, jobject, jstring path_j) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_core.handle || !g_core.retro_serialize_size) return JNI_FALSE;
  size_t sz = g_core.retro_serialize_size();
  if (sz == 0) return JNI_FALSE;
  std::vector<uint8_t> buf(sz);
  if (!g_core.retro_serialize(buf.data(), sz)) return JNI_FALSE;

  const char* path_c = env->GetStringUTFChars(path_j, nullptr);
  std::ofstream ofs(path_c, std::ios::binary);
  env->ReleaseStringUTFChars(path_j, path_c);
  if (!ofs) return JNI_FALSE;
  ofs.write(reinterpret_cast<const char*>(buf.data()), static_cast<std::streamsize>(sz));
  return JNI_TRUE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeLoadState(
    JNIEnv* env, jobject, jstring path_j) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_core.handle || !g_core.retro_unserialize) return JNI_FALSE;

  const char* path_c = env->GetStringUTFChars(path_j, nullptr);
  std::ifstream ifs(path_c, std::ios::binary | std::ios::ate);
  env->ReleaseStringUTFChars(path_j, path_c);
  if (!ifs) return JNI_FALSE;
  auto sz = ifs.tellg();
  ifs.seekg(0, std::ios::beg);
  std::vector<uint8_t> buf(static_cast<size_t>(sz));
  ifs.read(reinterpret_cast<char*>(buf.data()), sz);
  return g_core.retro_unserialize(buf.data(), buf.size()) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeGetFrameWidth(JNIEnv*, jobject) {
  return static_cast<jint>(g_last_width);
}

extern "C" JNIEXPORT jint JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeGetFrameHeight(JNIEnv*, jobject) {
  return static_cast<jint>(g_last_height);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeUnloadCore(JNIEnv*, jobject) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_hwActive && g_hwCb.context_destroy) {
    if (!g_hwIsVulkan && g_glReady) gl_ensure_current();
    g_hwCb.context_destroy();
  }
  if (g_core.handle) {
    if (g_core.retro_unload_game) g_core.retro_unload_game();
    if (g_core.retro_deinit) g_core.retro_deinit();
  }
  // Vulkan: espera GPU idle, chama destroy_device (com o .so ainda carregado)
  // e destrói swapchain/device/surface/instance.
  vkfe::shutdown_public();
  if (g_core.handle) {
    dlclose(g_core.handle);
    g_core = LibretroCoreSymbols{};
  }
  // Destrói objetos GL antes de liberar a janela
  gl_shutdown();
  g_hwCbActive = false;
  g_hwActive = false;
  g_hwIsVulkan = false;
  g_hwCoreReset = nullptr;
  g_hwCb = retro_hw_render_callback{};
  if (g_window) {
    ANativeWindow_release(g_window);
    g_window = nullptr;
  }
  std::lock_guard<std::mutex> audio_lock(g_audio_mutex);
  g_audio_read_idx = 0;
  g_audio_write_idx = 0;
  g_audio_count = 0;
}
