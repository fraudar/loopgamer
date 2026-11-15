#include <jni.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <sys/resource.h>
#include <sys/stat.h>
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
void set_freedreno_preset(const char* preset);
void set_backend(int mode); // 0 = GL, 1 = software, 2 = Vulkan
void set_vsync(bool enabled);
bool vulkan_requested();    // usuário pediu Vulkan e probe passou
bool is_active();
bool on_negotiation_iface(const void* iface, ANativeWindow* window);
bool get_render_interface(void** out);
void context_reset();
void context_destroy();
bool begin_frame();
void consume_signal_semaphore();
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
constexpr unsigned RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL = 54;
constexpr unsigned RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY = 55;
constexpr unsigned RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER = 56;
constexpr unsigned RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE = 58;
constexpr unsigned RETRO_ENVIRONMENT_SET_MESSAGE_EXT = 60;
constexpr unsigned RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 = 67;
constexpr unsigned RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL = 68;
constexpr unsigned RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK = 69;
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

struct retro_message {
  const char* msg;
  unsigned frames;
};

struct retro_message_ext {
  const char* msg;
  unsigned duration;
  unsigned priority;
  int level;
  int target;
  int type;
  int8_t progress;
};

typedef void (*retro_log_printf_t)(int level, const char* fmt, ...);
struct retro_log_callback {
  retro_log_printf_t log;
};

std::mutex g_core_diag_mutex;
std::string g_last_core_error;
std::string g_last_core_message;
bool g_last_core_error_fatal = false;
std::atomic<bool> g_core_shutdown_requested{false};
std::atomic<bool> g_has_rendered_frame{false};
std::optional<std::string> g_prev_external_storage;
bool g_overrode_external_storage = false;

std::string to_lower_ascii(std::string_view s) {
  std::string out(s);
  for (char& ch : out) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  return out;
}

bool contains_ci(std::string_view haystack, std::string_view needle) {
  if (needle.empty()) return true;
  return to_lower_ascii(haystack).find(to_lower_ascii(needle)) != std::string::npos;
}

bool is_informative_core_failure(std::string_view text) {
  return contains_ci(text, "decryption") ||
         contains_ci(text, "redump key") ||
         contains_ci(text, "firmware_missing") ||
         contains_ci(text, "Firmware is missing") ||
         contains_ci(text, "Firmware is too old") ||
         contains_ci(text, "Permission denied") ||
         (contains_ci(text, "booting ") && contains_ci(text, " failed:")) ||
         contains_ci(text, "could not be opened") ||
         contains_ci(text, "invalid_file_or_folder") ||
         contains_ci(text, "PS3UPDAT.PUP") ||
         contains_ci(text, "EBOOT.BIN");
}

std::string format_friendly_core_error(const std::string& raw) {
  if (raw.empty()) return {};
  if (contains_ci(raw, "redump key") ||
      contains_ci(raw, "decryption_error") ||
      contains_ci(raw, "decryption key") ||
      contains_ci(raw, "Decryption failed")) {
    return "ISO de PS3 criptografada (Redump): o arquivo precisa de descriptografia ou da chave .dkey correspondente (" +
           raw + ").";
  }
  if (contains_ci(raw, "firmware_missing") ||
      contains_ci(raw, "Firmware is missing") ||
      contains_ci(raw, "Firmware is too old")) {
    return "Firmware de PS3 (PS3UPDAT.PUP) ausente, desatualizado ou não instalado corretamente (" +
           raw + ").";
  }
  if (contains_ci(raw, "invalid_file_or_folder")) {
    return "Estrutura de disco/pasta PS3 inválida para o RPCS3 (" + raw + ").";
  }
  return raw;
}

void clear_core_diagnostics() {
  std::lock_guard<std::mutex> lock(g_core_diag_mutex);
  g_last_core_error.clear();
  g_last_core_message.clear();
  g_last_core_error_fatal = false;
  g_core_shutdown_requested.store(false, std::memory_order_release);
  g_has_rendered_frame.store(false, std::memory_order_release);
}

void record_core_diagnostic(const char* text, bool is_error, bool fatal) {
  if (!text || text[0] == '\0') return;
  std::string msg(text);
  while (!msg.empty() && (msg.back() == '\n' || msg.back() == '\r')) {
    msg.pop_back();
  }
  if (msg.empty()) return;

  std::lock_guard<std::mutex> lock(g_core_diag_mutex);
  if (is_error) {
    const bool prev_informative = is_informative_core_failure(g_last_core_error);
    const bool curr_informative = is_informative_core_failure(msg);
    if (g_last_core_error.empty() || curr_informative || !prev_informative) {
      g_last_core_error = format_friendly_core_error(msg);
    }
    if (fatal || curr_informative) {
      g_last_core_error_fatal = true;
    }
  } else {
    g_last_core_message = msg;
    if (is_informative_core_failure(msg)) {
      g_last_core_error = format_friendly_core_error(msg);
      g_last_core_error_fatal = true;
    }
  }
}

bool ensure_dir_recursive(const std::string& path) {
  if (path.empty()) return false;
  std::string cur;
  cur.reserve(path.size());
  for (size_t i = 0; i < path.size(); ++i) {
    cur.push_back(path[i]);
    if (path[i] == '/' || i + 1 == path.size()) {
      if (cur == "/") continue;
      if (::mkdir(cur.c_str(), 0755) != 0 && errno != EEXIST) {
        return false;
      }
    }
  }
  struct stat st {};
  return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

void apply_play_storage_env_locked(const std::string& core_path,
                                   const std::string& saves_dir) {
  if (!contains_ci(core_path, "play_libretro") || saves_dir.empty()) return;
  const std::string play_storage = saves_dir + "/play_storage";
  if (!ensure_dir_recursive(play_storage)) {
    __android_log_print(ANDROID_LOG_WARN, "loopgamer-core",
                        "Falha ao criar diretório play_storage: %s",
                        play_storage.c_str());
    return;
  }
  if (!g_overrode_external_storage) {
    const char* prev = std::getenv("EXTERNAL_STORAGE");
    g_prev_external_storage =
        prev ? std::optional<std::string>(prev) : std::nullopt;
    g_overrode_external_storage = true;
  }
  ::setenv("EXTERNAL_STORAGE", play_storage.c_str(), 1);
  __android_log_print(ANDROID_LOG_INFO, "loopgamer-core",
                      "Play! EXTERNAL_STORAGE redirecionado para %s",
                      play_storage.c_str());
}

void restore_external_storage_env_locked() {
  if (!g_overrode_external_storage) return;
  if (g_prev_external_storage.has_value()) {
    ::setenv("EXTERNAL_STORAGE", g_prev_external_storage->c_str(), 1);
  } else {
    ::unsetenv("EXTERNAL_STORAGE");
  }
  g_prev_external_storage.reset();
  g_overrode_external_storage = false;
}

// Eleva RLIMIT_NOFILE e RLIMIT_MEMLOCK para o core PS3 (rpcs3_libretro),
// evitando falha ao abrir ISOs/PSARCs grandes, dev_flash e mapas JIT LLVM/SPU
// (abordagem observada no aps3e_emu.cpp).
void boost_process_rlimits_for_rpcs3(const std::string& core_path) {
  if (!contains_ci(core_path, "rpcs3_libretro")) return;
  struct rlimit rlim{};
  if (::getrlimit(RLIMIT_NOFILE, &rlim) == 0) {
    const rlim_t target = std::min<rlim_t>(rlim.rlim_max, 8192);
    if (rlim.rlim_cur < target) {
      struct rlimit next{target, rlim.rlim_max};
      if (::setrlimit(RLIMIT_NOFILE, &next) == 0) {
        __android_log_print(
            ANDROID_LOG_INFO, "loopgamer-core",
            "RPCS3 RLIMIT_NOFILE elevado de %llu para %llu (max=%llu)",
            static_cast<unsigned long long>(rlim.rlim_cur),
            static_cast<unsigned long long>(target),
            static_cast<unsigned long long>(rlim.rlim_max));
      } else {
        __android_log_print(
            ANDROID_LOG_WARN, "loopgamer-core",
            "Falha ao elevar RLIMIT_NOFILE para %llu: errno=%d",
            static_cast<unsigned long long>(target), errno);
      }
    }
  }
  if (::getrlimit(RLIMIT_MEMLOCK, &rlim) == 0 && rlim.rlim_cur < rlim.rlim_max) {
    struct rlimit next{rlim.rlim_max, rlim.rlim_max};
    if (::setrlimit(RLIMIT_MEMLOCK, &next) == 0) {
      __android_log_print(
          ANDROID_LOG_INFO, "loopgamer-core",
          "RPCS3 RLIMIT_MEMLOCK elevado para %llu",
          static_cast<unsigned long long>(rlim.rlim_max));
    }
  }
}

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
  if (level >= 3) {
    record_core_diagnostic(buf, /*is_error=*/true, /*fatal=*/false);
  } else if (!g_has_rendered_frame.load(std::memory_order_relaxed) &&
             !is_informative_core_failure(buf) &&
             (contains_ci(buf, "compiling") ||
              contains_ci(buf, "llvm") ||
              contains_ci(buf, "spu cache") ||
              contains_ci(buf, "building") ||
              contains_ci(buf, "loading"))) {
    record_core_diagnostic(buf, /*is_error=*/false, /*fatal=*/false);
  }
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

struct retro_system_info {
  const char* library_name;
  const char* library_version;
  const char* valid_extensions;
  bool need_fullpath;
  bool block_extract;
};

struct LibretroCoreSymbols {
  void* handle = nullptr;
  void (*retro_init)(void) = nullptr;
  void (*retro_deinit)(void) = nullptr;
  void (*retro_get_system_info)(retro_system_info*) = nullptr;
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
std::mutex g_state_mutex;

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

bool jni_check_clear(JNIEnv* env, const char* tag) {
  if (env && env->ExceptionCheck()) {
    __android_log_print(ANDROID_LOG_WARN, "loopgamer-core",
                        "Exceção JNI detectada em %s", tag ? tag : "unknown");
    env->ExceptionClear();
    return true;
  }
  return false;
}

bool jstring_to_std(JNIEnv* env, jstring jstr, std::string& out,
                    const char* tag) {
  out.clear();
  if (!env || !jstr) return false;
  const char* utf = env->GetStringUTFChars(jstr, nullptr);
  if (jni_check_clear(env, tag) || !utf) {
    if (utf) env->ReleaseStringUTFChars(jstr, utf);
    return false;
  }
  out.assign(utf);
  env->ReleaseStringUTFChars(jstr, utf);
  jni_check_clear(env, tag);
  return true;
}

std::atomic<uint32_t> g_joypad_mask{0};
std::atomic<uint32_t> g_turbo_mask{0};
std::atomic<int> g_turbo_half_period{3};
std::atomic<uint32_t> g_emu_frame_count{0};
std::atomic<int16_t> g_left_x{0};
std::atomic<int16_t> g_left_y{0};
std::atomic<int16_t> g_right_x{0};
std::atomic<int16_t> g_right_y{0};
std::atomic<int> g_frame_skip{0};

inline void reset_input_state() {
  g_joypad_mask.store(0, std::memory_order_relaxed);
  g_left_x.store(0, std::memory_order_relaxed);
  g_left_y.store(0, std::memory_order_relaxed);
  g_right_x.store(0, std::memory_order_relaxed);
  g_right_y.store(0, std::memory_order_relaxed);
}
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
int g_gpuConsecutiveFailures = 0;
uint32_t g_gpuRetryAfterFrame = 0;
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
uint64_t g_swPresentCount = 0;
std::vector<uint32_t> g_swConvertBuf;
double g_appliedWindowFps = 0.0;

// Baseado no EmuWindow_Android::OnSurfaceChanged do Eden: informa o frame rate
// exato do núcleo ao SurfaceFlinger (Android 11+/12+) para paineis LTPO/120Hz.
void apply_window_frame_rate(ANativeWindow* window, double fps) {
  if (!window || fps <= 10.0) return;
  if (std::abs(fps - g_appliedWindowFps) < 0.05) return;
  using PfnSetFrameRateChange = int32_t (*)(ANativeWindow*, float, int8_t, int8_t);
  using PfnSetFrameRate = int32_t (*)(ANativeWindow*, float, int8_t);
  static auto fnChange = reinterpret_cast<PfnSetFrameRateChange>(
      dlsym(RTLD_DEFAULT, "ANativeWindow_setFrameRateWithChangeStrategy"));
  static auto fnBasic = reinterpret_cast<PfnSetFrameRate>(
      dlsym(RTLD_DEFAULT, "ANativeWindow_setFrameRate"));
  const float rate = static_cast<float>(fps);
  // 1 = FIXED_SOURCE, 0 = CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS
  if (fnChange) {
    fnChange(window, rate, 1, 0);
    g_appliedWindowFps = fps;
  } else if (fnBasic) {
    fnBasic(window, rate, 1);
    g_appliedWindowFps = fps;
  }
}

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

bool g_isPlayCore = false;

bool is_play_core_path(const std::string& path) {
  std::string lower;
  lower.reserve(path.size());
  for (unsigned char c : path) {
    lower.push_back(static_cast<char>(std::tolower(c)));
  }
  return lower.find("play_libretro") != std::string::npos;
}
GLuint g_prevHwTex = 0;
unsigned g_prevHwW = 0;
unsigned g_prevHwH = 0;
bool g_hasPrevHwFrame = false;
bool g_deintLogged = false;
GLuint g_deintProgram = 0;
GLint g_deintPosLoc = -1;
GLint g_deintUScaleLoc = -1;
GLint g_deintVScaleLoc = -1;
GLint g_deintVOffsetLoc = -1;
GLint g_deintPrevTexelLoc = -1;
GLint g_deintCurrTexLoc = -1;
GLint g_deintPrevTexLoc = -1;

std::atomic<bool> g_frameDup{false};
std::atomic<bool> g_vsyncEnabled{false};
std::atomic<bool> g_presentedThisStep{false};
std::unordered_map<std::string, std::string> g_coreVars;
std::set<std::string> g_returnedVarStrings;
std::atomic<bool> g_coreVarsDirty{false};

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
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 vUv;
uniform sampler2D uTex;
uniform float uSwizzleRB;
void main() {
  vec4 c = texture2D(uTex, vUv);
  vec3 rgb = uSwizzleRB > 0.5 ? c.bgr : c.rgb;
  gl_FragColor = vec4(rgb, 1.0);
}
)GLSL";

const char* kDeintVertexShader = R"GLSL(
attribute vec2 aPos;
varying vec2 vCurrUv;
varying vec2 vPrevUv;
uniform float uUScale;
uniform float uVScale;
uniform float uVOffset;
void main() {
  vec2 unit = aPos * 0.5 + 0.5;
  vCurrUv = vec2(unit.x * uUScale, aPos.y * 0.5 * uVScale + uVOffset);
  vPrevUv = unit;
  gl_Position = vec4(aPos, 0.0, 1.0);
}
)GLSL";

// Deinterlacer temporal motion-adaptive com proteção anti-bob vertical:
// estabiliza oscilação par/ímpar (480i/2x) em HUD/texto/cenário estático
// mantendo objetos em movimento rápido nítidos sem ghosting.
const char* kDeintFragmentShader = R"GLSL(
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 vCurrUv;
varying vec2 vPrevUv;
uniform sampler2D uCurrTex;
uniform sampler2D uPrevTex;
uniform vec2 uPrevTexel;
void main() {
  vec3 curr = texture2D(uCurrTex, vCurrUv).rgb;
  float dy = uPrevTexel.y;
  vec3 p0  = texture2D(uPrevTex, vPrevUv).rgb;
  vec3 pm1 = texture2D(uPrevTex, clamp(vPrevUv - vec2(0.0, dy), 0.0, 1.0)).rgb;
  vec3 pp1 = texture2D(uPrevTex, clamp(vPrevUv + vec2(0.0, dy), 0.0, 1.0)).rgb;
  vec3 pm2 = texture2D(uPrevTex, clamp(vPrevUv - vec2(0.0, 2.0 * dy), 0.0, 1.0)).rgb;
  vec3 pp2 = texture2D(uPrevTex, clamp(vPrevUv + vec2(0.0, 2.0 * dy), 0.0, 1.0)).rgb;
  vec3 minP = min(min(p0, min(pm1, pp1)), min(pm2, pp2));
  vec3 maxP = max(max(p0, max(pm1, pp1)), max(pm2, pp2));
  vec3 outOfRange = max(max(minP - curr, curr - maxP), vec3(0.0));
  float diff = max(outOfRange.r, max(outOfRange.g, outOfRange.b));
  float motion = smoothstep(0.03, 0.14, diff);
  float blend = 0.5 * (1.0 - motion);
  vec3 rgb = mix(curr, p0, blend);
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
  if (g_glReady || g_eglDisplay != EGL_NO_DISPLAY) {
    if (g_eglDisplay != EGL_NO_DISPLAY && g_eglSurface != EGL_NO_SURFACE &&
        g_eglContext != EGL_NO_CONTEXT) {
      if (eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface,
                         g_eglContext) == EGL_TRUE) {
        if (g_swTex != 0) glDeleteTextures(1, &g_swTex);
        if (g_hwColorTex != 0) glDeleteTextures(1, &g_hwColorTex);
        if (g_prevHwTex != 0) glDeleteTextures(1, &g_prevHwTex);
        if (g_hwDepthRb != 0) glDeleteRenderbuffers(1, &g_hwDepthRb);
        if (g_hwStencilRb != 0) glDeleteRenderbuffers(1, &g_hwStencilRb);
        if (g_hwFbo != 0) glDeleteFramebuffers(1, &g_hwFbo);
        if (g_blitVao != 0 && g_glDeleteVertexArrays) {
          g_glDeleteVertexArrays(1, &g_blitVao);
        }
        if (g_blitVbo != 0) glDeleteBuffers(1, &g_blitVbo);
        if (g_blitProgram != 0) glDeleteProgram(g_blitProgram);
        if (g_deintProgram != 0) glDeleteProgram(g_deintProgram);
        glFinish();
      }
      gl_release_context();
    }
    g_swTex = g_hwColorTex = g_prevHwTex = g_hwDepthRb = g_hwStencilRb = g_hwFbo =
        g_blitVao = g_blitVbo = g_blitProgram = g_deintProgram = 0;
    g_blitUScaleLoc = -1;
    g_deintPosLoc = g_deintUScaleLoc = g_deintVScaleLoc = g_deintVOffsetLoc =
        g_deintPrevTexelLoc = g_deintCurrTexLoc = g_deintPrevTexLoc = -1;
    g_prevHwW = g_prevHwH = 0;
    g_hasPrevHwFrame = false;
    g_deintLogged = false;
    g_glGenVertexArrays = nullptr;
    g_glDeleteVertexArrays = nullptr;
    g_glBindVertexArray = nullptr;
    g_glBindSampler = nullptr;
    g_swTexW = g_swTexH = 0;
    g_swPresentCount = 0;
    g_swConvertBuf.clear();
    g_appliedWindowFps = 0.0;
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
  if (g_libGles3) {
    dlclose(g_libGles3);
    g_libGles3 = nullptr;
  }
}

bool gl_ensure_current() {
  if (!g_window) return false;
  const uint32_t curFrame = g_emu_frame_count.load(std::memory_order_relaxed);
  if (g_gpuFailed) {
    if (g_gpuConsecutiveFailures >= 3 || curFrame < g_gpuRetryAfterFrame) {
      return false;
    }
    g_gpuFailed = false;
  }
  if (g_glReady) {
    if (g_glThreadId == std::this_thread::get_id()) return true;
    if (eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext) ==
        EGL_TRUE) {
      g_glThreadId = std::this_thread::get_id();
      return true;
    }
    const EGLint err = eglGetError();
    __android_log_print(ANDROID_LOG_WARN, "loopgamer-core",
                        "eglMakeCurrent falhou (err=0x%x)", err);
    if (err == EGL_CONTEXT_LOST || err == EGL_BAD_SURFACE ||
        err == EGL_BAD_NATIVE_WINDOW || err == EGL_BAD_DISPLAY) {
      gl_shutdown();
      ++g_gpuConsecutiveFailures;
      g_gpuRetryAfterFrame = curFrame + 60;
      g_gpuFailed = true;
    }
    return false;
  }

  g_eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (g_eglDisplay == EGL_NO_DISPLAY) {
    ++g_gpuConsecutiveFailures;
    g_gpuRetryAfterFrame = curFrame + 60;
    g_gpuFailed = true;
    return false;
  }
  EGLint maj = 0, min = 0;
  if (!eglInitialize(g_eglDisplay, &maj, &min)) {
    g_eglDisplay = EGL_NO_DISPLAY;
    ++g_gpuConsecutiveFailures;
    g_gpuRetryAfterFrame = curFrame + 60;
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
    ++g_gpuConsecutiveFailures;
    g_gpuRetryAfterFrame = curFrame + 60;
    g_gpuFailed = true;
    return false;
  }

  g_glThreadId = std::this_thread::get_id();
  g_glReady = true;
  eglSwapInterval(g_eglDisplay,
                  g_vsyncEnabled.load(std::memory_order_relaxed) ? 1 : 0);

  if (!init_blit_program()) {
    gl_shutdown();
    ++g_gpuConsecutiveFailures;
    g_gpuRetryAfterFrame = curFrame + 60;
    g_gpuFailed = true;
    return false;
  }
  g_gpuConsecutiveFailures = 0;
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
  if (!eglSwapBuffers(g_eglDisplay, g_eglSurface)) {
    const EGLint err = eglGetError();
    __android_log_print(ANDROID_LOG_WARN, "loopgamer-core",
                        "eglSwapBuffers falhou (err=0x%x)", err);
    if (err == EGL_CONTEXT_LOST || err == EGL_BAD_SURFACE ||
        err == EGL_BAD_NATIVE_WINDOW) {
      gl_shutdown();
      ++g_gpuConsecutiveFailures;
      g_gpuRetryAfterFrame =
          g_emu_frame_count.load(std::memory_order_relaxed) + 30;
      g_gpuFailed = true;
    }
    return;
  }
  g_gpuConsecutiveFailures = 0;
  g_presentedThisStep.store(true, std::memory_order_relaxed);
  double fps = 60.0;
  {
    std::lock_guard<std::mutex> state_lock(g_state_mutex);
    fps = g_target_fps;
  }
  // Duplicação de frames: jogos a ~30fps passam a entregar 60 frames/s
  if (g_frameDup.load(std::memory_order_relaxed) && fps <= 30.5) {
    eglSwapBuffers(g_eglDisplay, g_eglSurface);
  }
}

bool hw_ensure_fbo() {
  if (!gl_ensure_current()) return false;
  unsigned lastW = 512, lastH = 512;
  {
    std::lock_guard<std::mutex> state_lock(g_state_mutex);
    lastW = g_last_width > 0 ? g_last_width : 512;
    lastH = g_last_height > 0 ? g_last_height : 512;
  }
  unsigned w = g_hwMaxW > 0 ? g_hwMaxW : lastW;
  unsigned h = g_hwMaxH > 0 ? g_hwMaxH : lastH;
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

bool ensure_deint_program() {
  if (g_deintProgram != 0) return true;
  GLuint vs = compile_shader(GL_VERTEX_SHADER, kDeintVertexShader);
  GLuint fs = compile_shader(GL_FRAGMENT_SHADER, kDeintFragmentShader);
  if (!vs || !fs) {
    if (vs) glDeleteShader(vs);
    if (fs) glDeleteShader(fs);
    return false;
  }
  g_deintProgram = glCreateProgram();
  glAttachShader(g_deintProgram, vs);
  glAttachShader(g_deintProgram, fs);
  glBindAttribLocation(g_deintProgram, 0, "aPos");
  glLinkProgram(g_deintProgram);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint linked = GL_FALSE;
  glGetProgramiv(g_deintProgram, GL_LINK_STATUS, &linked);
  if (!linked) {
    glDeleteProgram(g_deintProgram);
    g_deintProgram = 0;
    return false;
  }
  g_deintPosLoc = glGetAttribLocation(g_deintProgram, "aPos");
  g_deintUScaleLoc = glGetUniformLocation(g_deintProgram, "uUScale");
  g_deintVScaleLoc = glGetUniformLocation(g_deintProgram, "uVScale");
  g_deintVOffsetLoc = glGetUniformLocation(g_deintProgram, "uVOffset");
  g_deintPrevTexelLoc = glGetUniformLocation(g_deintProgram, "uPrevTexel");
  g_deintCurrTexLoc = glGetUniformLocation(g_deintProgram, "uCurrTex");
  g_deintPrevTexLoc = glGetUniformLocation(g_deintProgram, "uPrevTex");
  return true;
}

bool ensure_prev_hw_tex(unsigned width, unsigned height) {
  if (width == 0 || height == 0) return false;
  if (g_prevHwTex != 0 && g_prevHwW == width && g_prevHwH == height) {
    return true;
  }
  if (g_prevHwTex != 0) {
    glDeleteTextures(1, &g_prevHwTex);
    g_prevHwTex = 0;
  }
  glActiveTexture(GL_TEXTURE0);
  glGenTextures(1, &g_prevHwTex);
  glBindTexture(GL_TEXTURE_2D, g_prevHwTex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, static_cast<GLsizei>(width),
               static_cast<GLsizei>(height), 0, GL_RGBA, GL_UNSIGNED_BYTE,
               nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindTexture(GL_TEXTURE_2D, 0);
  g_prevHwW = width;
  g_prevHwH = height;
  g_hasPrevHwFrame = false;
  return g_prevHwTex != 0;
}

void gl_draw_play_deint(GLuint currTex, GLuint prevTex, float uScale,
                        float vScale, float vOffset, unsigned prevW,
                        unsigned prevH) {
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

  GLint prevSampler0 = 0, prevSampler1 = 0;
  if (g_glBindSampler) {
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(0x8919 /*GL_SAMPLER_BINDING*/, &prevSampler0);
    g_glBindSampler(0, 0);
    glActiveTexture(GL_TEXTURE1);
    glGetIntegerv(0x8919 /*GL_SAMPLER_BINDING*/, &prevSampler1);
    g_glBindSampler(1, 0);
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

  glUseProgram(g_deintProgram);
  if (g_deintUScaleLoc >= 0) glUniform1f(g_deintUScaleLoc, uScale);
  if (g_deintVScaleLoc >= 0) glUniform1f(g_deintVScaleLoc, vScale);
  if (g_deintVOffsetLoc >= 0) glUniform1f(g_deintVOffsetLoc, vOffset);
  if (g_deintPrevTexelLoc >= 0) {
    glUniform2f(g_deintPrevTexelLoc,
                prevW > 0 ? 1.0f / static_cast<float>(prevW) : 0.0f,
                prevH > 0 ? 1.0f / static_cast<float>(prevH) : 0.0f);
  }
  if (g_deintCurrTexLoc >= 0) glUniform1i(g_deintCurrTexLoc, 0);
  if (g_deintPrevTexLoc >= 0) glUniform1i(g_deintPrevTexLoc, 1);

  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, currTex);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, prevTex);

  if (!useVao && g_deintPosLoc >= 0) {
    glBindBuffer(GL_ARRAY_BUFFER, g_blitVbo);
    glEnableVertexAttribArray(g_deintPosLoc);
    glVertexAttribPointer(g_deintPosLoc, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
  }
  glDrawArrays(GL_TRIANGLES, 0, 3);
  if (!useVao && g_deintPosLoc >= 0) {
    glDisableVertexAttribArray(g_deintPosLoc);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
  }
  if (g_glBindVertexArray) {
    g_glBindVertexArray(static_cast<GLuint>(prevVao));
  }
  if (g_glBindSampler) {
    g_glBindSampler(0, static_cast<GLuint>(prevSampler0));
    g_glBindSampler(1, static_cast<GLuint>(prevSampler1));
  }
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, 0);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, 0);
  glUseProgram(0);
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

  const bool usePlayDeint =
      g_isPlayCore && g_eglGlesVersion >= 3 && width > 0 && height > 0;
  if (usePlayDeint && ensure_deint_program() &&
      ensure_prev_hw_tex(width, height) && g_hasPrevHwFrame) {
    gl_draw_play_deint(g_hwColorTex, g_prevHwTex, uScale, vMax, 0.5f * vMax,
                       g_prevHwW, g_prevHwH);
  } else {
    gl_draw_bound(g_hwColorTex, uScale, vMax, 0.5f * vMax, false);
  }

  if (usePlayDeint && g_prevHwTex != 0) {
    glBindFramebuffer(0x8CA8 /*GL_READ_FRAMEBUFFER*/, g_hwFbo);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, g_prevHwTex);
    glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0,
                        static_cast<GLsizei>(width),
                        static_cast<GLsizei>(height));
    glBindFramebuffer(0x8CA8 /*GL_READ_FRAMEBUFFER*/, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    g_hasPrevHwFrame = true;
    if (!g_deintLogged) {
      g_deintLogged = true;
      __android_log_print(ANDROID_LOG_INFO, "loopgamer-core",
                          "Play! temporal deinterlace ativo (%ux%u)",
                          width, height);
    }
  }
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

bool present_sw_frame_gl(const void* data, unsigned w, unsigned h, size_t pitch,
                         retro_pixel_format pixel_format) {
  if (!data || w == 0 || h == 0) return false;
  const bool isRgb565 = (pixel_format == RETRO_PIXEL_FORMAT_RGB565);
  const bool isXrgb8888 = (pixel_format == RETRO_PIXEL_FORMAT_XRGB8888);
  const bool is0Rgb1555 = (pixel_format == RETRO_PIXEL_FORMAT_0RGB1555);
  if (!isRgb565 && !isXrgb8888 && !is0Rgb1555) return false;

  const size_t srcBytesPerPx = isXrgb8888 ? sizeof(uint32_t) : sizeof(uint16_t);
  if (static_cast<size_t>(w) > SIZE_MAX / srcBytesPerPx) return false;
  if (pitch < static_cast<size_t>(w) * srcBytesPerPx) return false;

  if (!gl_ensure_current()) return false;

  if (g_eglGlesVersion >= 3) {
    glBindBuffer(0x88EC /*GL_PIXEL_UNPACK_BUFFER*/, 0);
    glPixelStorei(0x0CF2 /*GL_UNPACK_ROW_LENGTH*/, 0);
  }

  // (Re)aloca a textura quando a resolução ou o pixel format do core mudam
  if (g_swTex == 0 || w != g_swTexW || h != g_swTexH ||
      pixel_format != g_swTexFormat) {
    if (g_swTex != 0) glDeleteTextures(1, &g_swTex);
    glGenTextures(1, &g_swTex);
    glBindTexture(GL_TEXTURE_2D, g_swTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (isRgb565) {
      // Adreno/GLES2+ exige GL_RGB (não GL_RGB565) em format/internalformat
      // combinado com GL_UNSIGNED_SHORT_5_6_5 para não retornar GL_INVALID_ENUM.
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, static_cast<GLsizei>(w),
                   static_cast<GLsizei>(h), 0, GL_RGB,
                   GL_UNSIGNED_SHORT_5_6_5, nullptr);
    } else {
      // Upload universal via GL_RGBA/GL_RGBA (XRGB8888 usa swizzle no shader;
      // 0RGB1555 é convertido em buffer compacto já em ordem RGBA).
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, static_cast<GLsizei>(w),
                   static_cast<GLsizei>(h), 0, GL_RGBA, GL_UNSIGNED_BYTE,
                   nullptr);
    }
    g_swTexW = w;
    g_swTexH = h;
    g_swTexFormat = pixel_format;
  }

  glBindTexture(GL_TEXTURE_2D, g_swTex);
  const uint8_t* uploadBytes = static_cast<const uint8_t*>(data);
  size_t uploadPitch = pitch;

  if (is0Rgb1555) {
    const size_t totalPx = static_cast<size_t>(w) * static_cast<size_t>(h);
    if (g_swConvertBuf.size() < totalPx) {
      g_swConvertBuf.resize(totalPx);
    }
    const auto* srcBytes = static_cast<const uint8_t*>(data);
    for (unsigned y = 0; y < h; ++y) {
      const auto* srcRow = reinterpret_cast<const uint16_t*>(
          srcBytes + static_cast<size_t>(y) * pitch);
      uint32_t* dstRow = g_swConvertBuf.data() + static_cast<size_t>(y) * w;
      for (unsigned x = 0; x < w; ++x) {
        const uint16_t px = srcRow[x];
        const uint32_t r5 = (px >> 10) & 0x1Fu;
        const uint32_t g5 = (px >> 5) & 0x1Fu;
        const uint32_t b5 = px & 0x1Fu;
        const uint32_t r = (r5 << 3) | (r5 >> 2);
        const uint32_t g = (g5 << 3) | (g5 >> 2);
        const uint32_t b = (b5 << 3) | (b5 >> 2);
        dstRow[x] = 0xFF000000u | (b << 16) | (g << 8) | r;
      }
    }
    uploadBytes = reinterpret_cast<const uint8_t*>(g_swConvertBuf.data());
    uploadPitch = static_cast<size_t>(w) * sizeof(uint32_t);
  }

  glPixelStorei(GL_UNPACK_ALIGNMENT, isRgb565 ? 2 : 4);
  const size_t bytesPerPx = isRgb565 ? sizeof(uint16_t) : sizeof(uint32_t);
  const size_t rowBytes = static_cast<size_t>(w) * bytesPerPx;
  const GLenum uploadFmt = isRgb565 ? GL_RGB : GL_RGBA;
  const GLenum uploadType =
      isRgb565 ? GL_UNSIGNED_SHORT_5_6_5 : GL_UNSIGNED_BYTE;
  if (uploadPitch == rowBytes) {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, static_cast<GLsizei>(w),
                    static_cast<GLsizei>(h), uploadFmt, uploadType, uploadBytes);
  } else if (g_eglGlesVersion >= 3 && uploadPitch > rowBytes &&
             (uploadPitch % bytesPerPx) == 0) {
    // Cores como mGBA entregam pitch=512 para width=240: GLES3 faz upload em 1 chamada.
    glPixelStorei(0x0CF2 /*GL_UNPACK_ROW_LENGTH*/,
                  static_cast<GLint>(uploadPitch / bytesPerPx));
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, static_cast<GLsizei>(w),
                    static_cast<GLsizei>(h), uploadFmt, uploadType, uploadBytes);
    glPixelStorei(0x0CF2 /*GL_UNPACK_ROW_LENGTH*/, 0);
  } else {
    for (unsigned y = 0; y < h; ++y) {
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, static_cast<GLsizei>(y),
                      static_cast<GLsizei>(w), 1, uploadFmt, uploadType,
                      uploadBytes + static_cast<size_t>(y) * uploadPitch);
    }
  }
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  // Frames de software têm origem top-left: v = 0.5 - 0.5*y → [1, 0]
  gl_draw_bound(g_swTex, 1.0f, -1.0f, 0.5f, isXrgb8888);
  const GLenum err = glGetError();
  ++g_swPresentCount;
  if (g_swPresentCount <= 3 ||
      (err != GL_NO_ERROR && err != g_lastLoggedGlErr)) {
    if (err != GL_NO_ERROR) g_lastLoggedGlErr = err;
    __android_log_print(
        err == GL_NO_ERROR ? ANDROID_LOG_INFO : ANDROID_LOG_WARN,
        "loopgamer-core",
        "SW GL present #%llu: frame=%ux%u pitch=%zu fmt=%d gles=%d err=0x%x",
        static_cast<unsigned long long>(g_swPresentCount),
        w, h, pitch, static_cast<int>(pixel_format), g_eglGlesVersion, err);
  }
  gl_finish_frame();
  return true;
}

// Fallback: caminho original via ANativeWindow_lock (lento, usado só se EGL falhar)
void present_sw_frame_cpu(const void* data, unsigned width, unsigned height,
                          size_t pitch, retro_pixel_format pixel_format) {
  if (!g_window || !data || width == 0 || height == 0) return;
  if (pixel_format != RETRO_PIXEL_FORMAT_RGB565 &&
      pixel_format != RETRO_PIXEL_FORMAT_XRGB8888 &&
      pixel_format != RETRO_PIXEL_FORMAT_0RGB1555) {
    return;
  }
  const size_t src_bytes_per_px =
      (pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) ? sizeof(uint32_t)
                                                    : sizeof(uint16_t);
  if (static_cast<size_t>(width) > SIZE_MAX / src_bytes_per_px) return;
  if (pitch < static_cast<size_t>(width) * src_bytes_per_px) return;

  const int32_t desired_format =
      (pixel_format == RETRO_PIXEL_FORMAT_RGB565)
          ? WINDOW_FORMAT_RGB_565
          : WINDOW_FORMAT_RGBA_8888;
  if (width != g_configured_width || height != g_configured_height ||
      desired_format != g_configured_win_format) {
    ANativeWindow_setBuffersGeometry(g_window, static_cast<int32_t>(width),
                                     static_cast<int32_t>(height),
                                     desired_format);
    g_configured_width = width;
    g_configured_height = height;
    g_configured_win_format = desired_format;
  }
  ANativeWindow_Buffer buffer{};
  if (ANativeWindow_lock(g_window, &buffer, nullptr) != 0) return;
  if (!buffer.bits || buffer.width <= 0 || buffer.height <= 0 ||
      buffer.stride < buffer.width) {
    ANativeWindow_unlockAndPost(g_window);
    return;
  }
  const unsigned copy_w =
      std::min(width, static_cast<unsigned>(buffer.width));
  const unsigned copy_h =
      std::min(height, static_cast<unsigned>(buffer.height));
  if (copy_w == 0 || copy_h == 0) {
    ANativeWindow_unlockAndPost(g_window);
    return;
  }
  const size_t dst_stride = static_cast<size_t>(buffer.stride);
  const auto* __restrict__ src_bytes = static_cast<const uint8_t*>(data);

  if (buffer.format == WINDOW_FORMAT_RGB_565 &&
      pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
    auto* __restrict__ dst_base = static_cast<uint16_t*>(buffer.bits);
    if (dst_stride == copy_w && copy_w == width &&
        pitch == static_cast<size_t>(copy_w) * sizeof(uint16_t)) {
      std::memcpy(dst_base, src_bytes,
                  static_cast<size_t>(copy_w) * copy_h * sizeof(uint16_t));
    } else {
      const size_t row_bytes = static_cast<size_t>(copy_w) * sizeof(uint16_t);
      for (unsigned y = 0; y < copy_h; ++y) {
        std::memcpy(dst_base + static_cast<size_t>(y) * dst_stride,
                    src_bytes + static_cast<size_t>(y) * pitch, row_bytes);
      }
    }
  } else if (buffer.format == WINDOW_FORMAT_RGBA_8888 ||
             buffer.format == WINDOW_FORMAT_RGBX_8888) {
    auto* __restrict__ dst_base = static_cast<uint32_t*>(buffer.bits);
    if (pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
      for (unsigned y = 0; y < copy_h; ++y) {
        uint32_t* __restrict__ dst_row =
            dst_base + static_cast<size_t>(y) * dst_stride;
        const auto* __restrict__ src_row = reinterpret_cast<const uint32_t*>(
            src_bytes + static_cast<size_t>(y) * pitch);
        unsigned x = 0;
#if defined(__aarch64__) || defined(__ARM_NEON)
        for (; x + 15 < copy_w; x += 16) {
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
        for (; x < copy_w; ++x) {
          const uint32_t px = src_row[x];
          dst_row[x] = 0xFF000000u | ((px & 0x000000FFu) << 16) |
                       (px & 0x0000FF00u) | ((px & 0x00FF0000u) >> 16);
        }
      }
    } else if (pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
      for (unsigned y = 0; y < copy_h; ++y) {
        uint32_t* __restrict__ dst_row =
            dst_base + static_cast<size_t>(y) * dst_stride;
        const auto* __restrict__ src_row = reinterpret_cast<const uint16_t*>(
            src_bytes + static_cast<size_t>(y) * pitch);
        for (unsigned x = 0; x < copy_w; ++x) {
          const uint16_t px = src_row[x];
          const uint32_t r5 = (px >> 11) & 0x1Fu;
          const uint32_t g6 = (px >> 5) & 0x3Fu;
          const uint32_t b5 = px & 0x1Fu;
          const uint32_t r = (r5 << 3) | (r5 >> 2);
          const uint32_t g = (g6 << 2) | (g6 >> 4);
          const uint32_t b = (b5 << 3) | (b5 >> 2);
          dst_row[x] = 0xFF000000u | (b << 16) | (g << 8) | r;
        }
      }
    } else {
      for (unsigned y = 0; y < copy_h; ++y) {
        uint32_t* __restrict__ dst_row =
            dst_base + static_cast<size_t>(y) * dst_stride;
        const auto* __restrict__ src_row = reinterpret_cast<const uint16_t*>(
            src_bytes + static_cast<size_t>(y) * pitch);
        for (unsigned x = 0; x < copy_w; ++x) {
          const uint16_t px = src_row[x];
          const uint32_t r5 = (px >> 10) & 0x1Fu;
          const uint32_t g5 = (px >> 5) & 0x1Fu;
          const uint32_t b5 = px & 0x1Fu;
          const uint32_t r = (r5 << 3) | (r5 >> 2);
          const uint32_t g = (g5 << 3) | (g5 >> 2);
          const uint32_t b = (b5 << 3) | (b5 >> 2);
          dst_row[x] = 0xFF000000u | (b << 16) | (g << 8) | r;
        }
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

const char* intern_var_string_locked(const std::string& val) {
  auto res = g_returnedVarStrings.insert(val);
  return res.first->c_str();
}

const char* get_core_variable(const char* key) {
  if (!key) return nullptr;
  const std::string_view k(key);

  std::lock_guard<std::mutex> state_lock(g_state_mutex);

  // Garante fallback automático Vulkan → OpenGL ES (ou software se forçado)
  // quando o dispositivo não passa no probe Vulkan.
  if (k == "ppsspp_backend") {
    if (g_forceSoftwareCore) return "none";
    const auto it = g_coreVars.find(key);
    if (it != g_coreVars.end()) {
      if (it->second == "vulkan" && !vkfe::vulkan_requested()) return "opengl";
      return intern_var_string_locked(it->second);
    }
    return vkfe::vulkan_requested() ? "vulkan" : "opengl";
  }
  if (k == "ppsspp_software_rendering" && g_forceSoftwareCore) {
    return "enabled";
  }

  // Overrides vindos das configurações do usuário (k=v;k=v via JNI)
  const auto it = g_coreVars.find(key);
  if (it != g_coreVars.end()) return intern_var_string_locked(it->second);

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
  // Keep FastMemory enabled: on ARM64 with FastMemory disabled, upstream PPSSPP's
  // CompIR_ValidateAddress emits `mov w1, #0x11` (32-bit W17) before ReportBadAddress,
  // truncating the 64-bit guest memory pointer and crashing in gameplay with SIGSEGV.
  if (k == "ppsspp_fast_memory") return "enabled";
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
  if (k == "pcsx_rearmed_bios") return "auto";
  if (k == "pcsx_rearmed_region") return "Auto";
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

  // Play! (PS2)
  if (k == "play_res_multi") return "2x";
  if (k == "play_bilinear_filtering") return "true";
  if (k == "play_presentation_mode") return "Fit Screen";

  return nullptr;
}

bool environment_callback(unsigned cmd, void* data) {
  switch (cmd) {
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      const auto* fmt = static_cast<const retro_pixel_format*>(data);
      if (fmt) {
        std::lock_guard<std::mutex> state_lock(g_state_mutex);
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
      bool forceSoftware = false;
      {
        std::lock_guard<std::mutex> state_lock(g_state_mutex);
        forceSoftware = g_forceSoftwareCore;
      }
      if (!cb || forceSoftware) return false;
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
      {
        std::lock_guard<std::mutex> state_lock(g_state_mutex);
        if (av->geometry.base_width > 0 && av->geometry.base_height > 0) {
          g_last_width = av->geometry.base_width;
          g_last_height = av->geometry.base_height;
        }
        if (av->timing.fps > 10.0) {
          g_target_fps = av->timing.fps;
        }
        if (av->timing.sample_rate > 8000.0) {
          g_sample_rate = static_cast<int>(av->timing.sample_rate);
        }
      }
      if (av->geometry.max_width > 0 && av->geometry.max_height > 0) {
        g_hwMaxW = av->geometry.max_width;
        g_hwMaxH = av->geometry.max_height;
      }
      if (av->timing.fps > 10.0) {
        apply_window_frame_rate(g_window, av->timing.fps);
      }
      return true;
    }
    case RETRO_ENVIRONMENT_SET_GEOMETRY: {
      const auto* geom = static_cast<const retro_game_geometry*>(data);
      if (!geom) return false;
      if (geom->base_width > 0 && geom->base_height > 0) {
        std::lock_guard<std::mutex> state_lock(g_state_mutex);
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
        std::lock_guard<std::mutex> state_lock(g_state_mutex);
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
      if (data) {
        *static_cast<bool*>(data) =
            g_coreVarsDirty.exchange(false, std::memory_order_acq_rel);
      }
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
      if (data) *static_cast<unsigned*>(data) = 2;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_MESSAGE: {
      const auto* msg = static_cast<const retro_message*>(data);
      if (msg && msg->msg && msg->msg[0] != '\0') {
        __android_log_print(ANDROID_LOG_INFO, "loopgamer-core",
                            "SET_MESSAGE (%u frames): %s", msg->frames,
                            msg->msg);
        record_core_diagnostic(msg->msg, /*is_error=*/false, /*fatal=*/false);
      }
      return true;
    }
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT: {
      const auto* msg = static_cast<const retro_message_ext*>(data);
      if (msg && msg->msg && msg->msg[0] != '\0') {
        const bool is_err = msg->level >= 3;
        __android_log_print(is_err ? ANDROID_LOG_ERROR : ANDROID_LOG_INFO,
                            "loopgamer-core", "SET_MESSAGE_EXT (lvl=%d): %s",
                            msg->level, msg->msg);
        record_core_diagnostic(msg->msg, is_err, /*fatal=*/is_err);
      }
      return true;
    }
    case RETRO_ENVIRONMENT_SHUTDOWN: {
      __android_log_print(ANDROID_LOG_INFO, "loopgamer-core",
                          "Core solicitou RETRO_ENVIRONMENT_SHUTDOWN");
      g_core_shutdown_requested.store(true, std::memory_order_release);
      return true;
    }
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
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
      bool forceSoftware = false;
      {
        std::lock_guard<std::mutex> state_lock(g_state_mutex);
        forceSoftware = g_forceSoftwareCore;
      }
      if (!data || forceSoftware) return false;
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
  if (width == 0 || height == 0) {
    if (vkfe::is_active()) vkfe::consume_signal_semaphore();
    return;
  }

  {
    std::lock_guard<std::mutex> state_lock(g_state_mutex);
    g_last_width = width;
    g_last_height = height;
  }

  const bool is_hw_frame =
      data != nullptr &&
      reinterpret_cast<uintptr_t>(data) == ~static_cast<uintptr_t>(0);
  if (data == nullptr) {
    // Frame duplicado/pulo intencional pelo core (ex.: 30fps / AutoFrameSkip):
    // em Vulkan, sinaliza signalSem pendente conforme libretro_vulkan.h.
    if (vkfe::is_active()) vkfe::consume_signal_semaphore();
    return;
  }

  // Frames de HW (especialmente Vulkan) não devem pular present para não
  // deixar swapchain/semáforos do retro_run órfãos.
  if (!is_hw_frame && should_skip_present()) return;

  g_has_rendered_frame.store(true, std::memory_order_release);

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

  retro_pixel_format pixel_format;
  {
    std::lock_guard<std::mutex> state_lock(g_state_mutex);
    pixel_format = g_pixel_format;
  }

  // Caminho GPU: upload para textura + blit (RGB565 nativo, XRGB8888 via swizzle,
  // ou 0RGB1555 convertido em RGBA8888 compacto). Verifica formato ANTES de bind EGL
  // para não bloquear ANativeWindow_lock caso caia no fallback CPU.
  const bool format_ok =
      pixel_format == RETRO_PIXEL_FORMAT_RGB565 ||
      pixel_format == RETRO_PIXEL_FORMAT_XRGB8888 ||
      pixel_format == RETRO_PIXEL_FORMAT_0RGB1555;
  if (format_ok && gl_ensure_current() && g_blitProgram != 0) {
    if (present_sw_frame_gl(data, width, height, pitch, pixel_format)) return;
  }
  present_sw_frame_cpu(data, width, height, pitch, pixel_format);
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
  if (device == 5) {
    if (index == 0) {
      if (id == 0) return g_left_x.load(std::memory_order_relaxed);
      if (id == 1) return g_left_y.load(std::memory_order_relaxed);
      return 0;
    }
    if (index == 1) {
      if (id == 0) return g_right_x.load(std::memory_order_relaxed);
      if (id == 1) return g_right_y.load(std::memory_order_relaxed);
      return 0;
    }
  }
  return 0;
}

void unload_core_locked() {
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
  g_gpuFailed = false;
  g_gpuConsecutiveFailures = 0;
  g_gpuRetryAfterFrame = 0;
  g_hwCbActive = false;
  g_hwActive = false;
  g_hwIsVulkan = false;
  g_hwCoreReset = nullptr;
  g_hwCb = retro_hw_render_callback{};
  g_isPlayCore = false;
  g_hasPrevHwFrame = false;
  g_deintLogged = false;
  g_configured_width = 0;
  g_configured_height = 0;
  g_configured_win_format = 0;
  g_videoCbThisStep = false;
  g_hwCbCalledThisStep = false;
  g_hwEverPresented = false;
  g_hwPresentCount = 0;
  g_presentedThisStep.store(false, std::memory_order_relaxed);
  reset_input_state();
  if (g_window) {
    ANativeWindow_release(g_window);
    g_window = nullptr;
  }
  restore_external_storage_env_locked();
  {
    std::lock_guard<std::mutex> state_lock(g_state_mutex);
    g_returnedVarStrings.clear();
    g_coreVarsDirty.store(false, std::memory_order_relaxed);
  }
  std::lock_guard<std::mutex> audio_lock(g_audio_mutex);
  g_audio_read_idx = 0;
  g_audio_write_idx = 0;
  g_audio_count = 0;
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

  // Garante limpeza completa de sessão anterior antes de sobrescrever handles
  unload_core_locked();
  clear_core_diagnostics();

  if (!env || !surface_j) {
    __android_log_print(ANDROID_LOG_ERROR, "loopgamer-core",
                        "nativeLoadCoreAndRom: JNIEnv ou Surface nulo");
    return JNI_FALSE;
  }

  std::string core_path;
  std::string rom_path;
  std::string sys_dir;
  std::string sav_dir;
  if (!jstring_to_std(env, core_path_j, core_path, "nativeLoadCoreAndRom(core)") ||
      !jstring_to_std(env, rom_path_j, rom_path, "nativeLoadCoreAndRom(rom)") ||
      !jstring_to_std(env, system_dir_j, sys_dir, "nativeLoadCoreAndRom(sys)") ||
      !jstring_to_std(env, saves_dir_j, sav_dir, "nativeLoadCoreAndRom(saves)") ||
      core_path.empty() || rom_path.empty()) {
    __android_log_print(ANDROID_LOG_ERROR, "loopgamer-core",
                        "nativeLoadCoreAndRom: caminhos inválidos");
    return JNI_FALSE;
  }

  g_window = ANativeWindow_fromSurface(env, surface_j);
  if (jni_check_clear(env, "ANativeWindow_fromSurface") || !g_window) {
    __android_log_print(ANDROID_LOG_ERROR, "loopgamer-core",
                        "ANativeWindow_fromSurface retornou nullptr");
    unload_core_locked();
    return JNI_FALSE;
  }

  g_system_dir = std::move(sys_dir);
  g_saves_dir = std::move(sav_dir);

  g_core.handle = dlopen(core_path.c_str(), RTLD_LAZY);
  if (!g_core.handle) {
    __android_log_print(ANDROID_LOG_ERROR, "loopgamer-core",
                        "dlopen failed for %s: %s", core_path.c_str(),
                        dlerror());
    unload_core_locked();
    return JNI_FALSE;
  }

  // Cores carregados via dlopen() não recebem JNI_OnLoad automaticamente pela ART.
  // O Play! (PS2) depende de Framework::CJavaVM::m_vm preenchido antes da thread
  // PS2VM chamar AttachCurrentThread; inicializamos via símbolo exportado se existir.
  JavaVM* jvm = nullptr;
  if (env->GetJavaVM(&jvm) == JNI_OK && jvm != nullptr) {
    using SetJavaVMFn = void (*)(JavaVM*);
    auto set_java_vm = reinterpret_cast<SetJavaVMFn>(
        dlsym(g_core.handle, "_ZN9Framework7CJavaVM9SetJavaVMEP7_JavaVM"));
    if (set_java_vm) {
      set_java_vm(jvm);
      __android_log_print(ANDROID_LOG_INFO, "loopgamer-core",
                          "Play! Framework::CJavaVM::SetJavaVM(%p) inicializado",
                          static_cast<void*>(jvm));
    }
  }

  #define LOAD_SYM(name) \
    g_core.name = reinterpret_cast<decltype(g_core.name)>(dlsym(g_core.handle, #name)); \
    if (!g_core.name) { \
      __android_log_print(ANDROID_LOG_ERROR, "loopgamer-core", "Missing symbol: %s", #name); \
      unload_core_locked(); \
      return JNI_FALSE; \
    }

  LOAD_SYM(retro_init)
  LOAD_SYM(retro_deinit)
  g_core.retro_get_system_info = reinterpret_cast<decltype(g_core.retro_get_system_info)>(
      dlsym(g_core.handle, "retro_get_system_info"));
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

  g_configured_width = 0;
  g_configured_height = 0;
  g_configured_win_format = 0;
  g_frame_counter = 0;
  g_gpuFailed = false;
  g_gpuConsecutiveFailures = 0;
  g_gpuRetryAfterFrame = 0;
  g_glReady = false;
  g_eglDisplay = EGL_NO_DISPLAY;
  g_eglSurface = EGL_NO_SURFACE;
  g_eglContext = EGL_NO_CONTEXT;
  // Tenta GLES3 primeiro (es3Candidates faz fallback automático para ES2),
  // habilitando GL_UNPACK_ROW_LENGTH (mGBA/SNES) e VAOs nos cores de software.
  g_eglGlesVersion = 3;
  {
    std::lock_guard<std::mutex> state_lock(g_state_mutex);
    g_pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;
    g_coreVarsDirty.store(false, std::memory_order_relaxed);
  }
  g_swTexFormat = RETRO_PIXEL_FORMAT_RGB565;
  g_swPresentCount = 0;
  g_appliedWindowFps = 0.0;
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
  g_isPlayCore = is_play_core_path(core_path);
  g_hasPrevHwFrame = false;
  g_deintLogged = false;
  g_swTex = 0;
  g_swTexW = g_swTexH = 0;
  g_videoCbThisStep = false;
  g_hwCbCalledThisStep = false;
  g_hwEverPresented = false;
  g_hwPresentCount = 0;
  g_lastLoggedGlErr = GL_NO_ERROR;
  g_presentedThisStep.store(false, std::memory_order_relaxed);
  reset_input_state();

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
  apply_play_storage_env_locked(core_path, g_saves_dir);
  boost_process_rlimits_for_rpcs3(core_path);
  g_core.retro_init();

  retro_system_info sys_info{};
  if (g_core.retro_get_system_info) {
    g_core.retro_get_system_info(&sys_info);
  }

  retro_game_info info{};
  info.path = rom_path.c_str();
  std::vector<uint8_t> rom_buffer;
  auto ends_with_ci = [](const std::string& s, const char* suffix) {
    const size_t sl = s.size();
    const size_t tl = std::strlen(suffix);
    if (sl < tl) return false;
    for (size_t i = 0; i < tl; ++i) {
      const char a = s[sl - tl + i];
      const char b = suffix[i];
      if (std::tolower(static_cast<unsigned char>(a)) !=
          std::tolower(static_cast<unsigned char>(b))) {
        return false;
      }
    }
    return true;
  };
  if (g_core.retro_get_system_info && !sys_info.need_fullpath &&
      !ends_with_ci(rom_path, ".zip") && !ends_with_ci(rom_path, ".7z")) {
    std::ifstream rom_in(rom_path, std::ios::binary | std::ios::ate);
    if (rom_in) {
      const auto end_pos = rom_in.tellg();
      constexpr std::streamoff kMaxInMemRom = 64LL * 1024LL * 1024LL;
      if (end_pos > 0 && end_pos <= kMaxInMemRom) {
        rom_buffer.resize(static_cast<size_t>(end_pos));
        rom_in.seekg(0, std::ios::beg);
        if (rom_in.read(reinterpret_cast<char*>(rom_buffer.data()), end_pos)) {
          info.data = rom_buffer.data();
          info.size = rom_buffer.size();
        } else {
          rom_buffer.clear();
        }
      }
    }
  }

  if (!g_core.retro_load_game(&info)) {
    rom_buffer.clear();
    unload_core_locked();
    return JNI_FALSE;
  }
  rom_buffer.clear();

  retro_system_av_info av{};
  g_core.retro_get_system_av_info(&av);
  unsigned baseW = 480;
  unsigned baseH = 272;
  double targetFps = 60.0;
  {
    std::lock_guard<std::mutex> state_lock(g_state_mutex);
    if (av.geometry.base_width > 0 && av.geometry.base_height > 0) {
      g_last_width = av.geometry.base_width;
      g_last_height = av.geometry.base_height;
    }
    baseW = g_last_width;
    baseH = g_last_height;
    if (av.timing.fps > 10.0) {
      g_target_fps = av.timing.fps;
    }
    targetFps = g_target_fps;
    if (av.timing.sample_rate > 8000.0) {
      g_sample_rate = static_cast<int>(av.timing.sample_rate);
    }
  }
  apply_window_frame_rate(g_window, targetFps);
  g_hwMaxW = av.geometry.max_width;
  g_hwMaxH = av.geometry.max_height;

  // Dispara context_reset só após retro_load_game retornar true e av_info
  // popular g_hwMaxW/g_hwMaxH (cores como PPSSPP só definem Libretro::ctx depois).
  if (g_hwCbActive) {
    if (g_hwIsVulkan) {
      if (vkfe::is_active()) {
        if (g_hwCoreReset) g_hwCoreReset();
        bool fatal_after_reset = false;
        {
          std::lock_guard<std::mutex> diag_lock(g_core_diag_mutex);
          fatal_after_reset = g_last_core_error_fatal;
        }
        if (fatal_after_reset || g_core_shutdown_requested.load(std::memory_order_acquire)) {
          __android_log_print(
              ANDROID_LOG_ERROR, "loopgamer-core",
              "HW context_reset reportou erro fatal de boot/core — abortando");
          unload_core_locked();
          return JNI_FALSE;
        }
        g_hwActive = true;
        __android_log_print(
            ANDROID_LOG_INFO, "loopgamer-core",
            "HW context_reset OK: Vulkan active (max=%ux%u base=%ux%u)",
            g_hwMaxW, g_hwMaxH, baseW, baseH);
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
          g_eglGlesVersion, g_hwMaxW, g_hwMaxH, baseW, baseH);
    } else {
      __android_log_print(ANDROID_LOG_WARN, "loopgamer-core",
                          "HW context_reset failed: gl_ensure_current false");
      g_hwCbActive = false;
      g_hwActive = false;
    }
  }

  // O contexto EGL pode ter sido criado na thread principal/IO durante
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
    // Vulkan: adquire a próxima imagem do swapchain antes do retro_run
    // (get_sync_index do core precisa retornar um índice válido durante o run).
    // Se acquire falhar, não avança retro_run() dessincronizado do swapchain.
    if (vkfe::is_active()) {
      if (!vkfe::begin_frame()) return;
    } else if (g_hwCbActive) {
      // Se o core usa HW render GL, o contexto EGL precisa estar current
      gl_ensure_current();
    }
    g_emu_frame_count.fetch_add(1, std::memory_order_relaxed);
    g_videoCbThisStep = false;
    g_hwCbCalledThisStep = false;
    g_presentedThisStep.store(false, std::memory_order_relaxed);
    g_core.retro_run();
    // Fallback apenas se o core desenhou no FBO HW mas não chamou video_refresh
    // (nunca força swap em frames anulados via video_refresh(nullptr)).
    if (g_hwCbActive && !g_hwIsVulkan &&
        !g_videoCbThisStep &&
        g_hwCbCalledThisStep &&
        g_hwEverPresented &&
        !g_presentedThisStep.load(std::memory_order_relaxed) &&
        g_hwColorTex != 0) {
      unsigned lastW = 480, lastH = 272;
      {
        std::lock_guard<std::mutex> state_lock(g_state_mutex);
        lastW = g_last_width;
        lastH = g_last_height;
      }
      present_hw_frame(lastW, lastH);
    }
  }
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeReleaseRenderThreadContext(
    JNIEnv*, jobject) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_eglDisplay != EGL_NO_DISPLAY &&
      g_glThreadId == std::this_thread::get_id()) {
    gl_release_context();
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
  if (!env || !out_pcm) return 0;
  std::lock_guard<std::mutex> lock(g_audio_mutex);
  if (g_audio_count == 0) return 0;
  const jsize cap = env->GetArrayLength(out_pcm);
  if (jni_check_clear(env, "nativeDrainAudioBuffer(GetArrayLength)") || cap <= 0) {
    return 0;
  }
  const size_t count = std::min(static_cast<size_t>(cap), g_audio_count);

  int16_t temp[4096];
  const size_t batch = std::min(count, static_cast<size_t>(4096));
  for (size_t i = 0; i < batch; ++i) {
    temp[i] = g_audio_ring[(g_audio_read_idx + i) & (kAudioRingCapacity - 1)];
  }
  env->SetShortArrayRegion(out_pcm, 0, static_cast<jsize>(batch), temp);
  if (jni_check_clear(env, "nativeDrainAudioBuffer(SetShortArrayRegion)")) {
    return 0;
  }
  g_audio_read_idx = (g_audio_read_idx + batch) & (kAudioRingCapacity - 1);
  g_audio_count -= batch;
  return static_cast<jint>(batch);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetCoreOptions(
    JNIEnv* env, jobject, jstring options_j) {
  if (!env || !options_j) return;
  std::string opts;
  if (!jstring_to_std(env, options_j, opts, "nativeSetCoreOptions")) return;
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
  std::lock_guard<std::mutex> state_lock(g_state_mutex);
  g_coreVars = std::move(parsed);
  g_coreVarsDirty.store(true, std::memory_order_release);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetRendererMode(
    JNIEnv*, jobject, jboolean software) {
  {
    std::lock_guard<std::mutex> state_lock(g_state_mutex);
    g_forceSoftwareCore = (software == JNI_TRUE);
  }
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
  auto to_std = [env](jstring s, const char* tag) -> std::string {
    std::string out;
    if (s) jstring_to_std(env, s, out, tag);
    return out;
  };
  const std::string hookDir = to_std(hook_dir_j, "customDriver(hook)");
  const std::string tmpDir = to_std(tmp_dir_j, "customDriver(tmp)");
  const std::string drvDir = to_std(drv_dir_j, "customDriver(dir)");
  const std::string drvName = to_std(drv_name_j, "customDriver(name)");
  vkfe::set_custom_driver(hookDir.c_str(), tmpDir.c_str(), drvDir.c_str(),
                          drvName.c_str(), turbo == JNI_TRUE);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetFreedrenoPreset(
    JNIEnv* env, jobject, jstring preset_j) {
  std::string preset;
  if (env && preset_j) {
    jstring_to_std(env, preset_j, preset, "nativeSetFreedrenoPreset");
  }
  vkfe::set_freedreno_preset(preset.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSetGpuBackend(
    JNIEnv*, jobject, jint mode) {
  // 0 = OpenGL ES, 1 = software CPU, 2 = Vulkan
  vkfe::set_backend(mode);
  std::lock_guard<std::mutex> state_lock(g_state_mutex);
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
  std::lock_guard<std::mutex> state_lock(g_state_mutex);
  return static_cast<jint>(g_sample_rate);
}

extern "C" JNIEXPORT jdouble JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeGetTargetFps(JNIEnv*, jobject) {
  std::lock_guard<std::mutex> state_lock(g_state_mutex);
  return static_cast<jdouble>(g_target_fps);
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeUpdateInput(
    JNIEnv*, jobject, jint mask, jshort lx, jshort ly, jshort rx, jshort ry) {
  g_joypad_mask.store(static_cast<uint32_t>(mask), std::memory_order_relaxed);
  g_left_x.store(lx, std::memory_order_relaxed);
  g_left_y.store(ly, std::memory_order_relaxed);
  g_right_x.store(rx, std::memory_order_relaxed);
  g_right_y.store(ry, std::memory_order_relaxed);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeSaveState(
    JNIEnv* env, jobject, jstring path_j) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_core.handle || !g_core.retro_serialize_size || !g_core.retro_serialize) {
    return JNI_FALSE;
  }
  std::string path;
  if (!jstring_to_std(env, path_j, path, "nativeSaveState") || path.empty()) {
    return JNI_FALSE;
  }
  const size_t sz = g_core.retro_serialize_size();
  if (sz == 0) return JNI_FALSE;
  std::vector<uint8_t> buf(sz);
  if (!g_core.retro_serialize(buf.data(), sz)) return JNI_FALSE;

  const std::string tmp_path = path + ".tmp";
  std::ofstream ofs(tmp_path, std::ios::binary | std::ios::trunc);
  if (!ofs) return JNI_FALSE;
  ofs.write(reinterpret_cast<const char*>(buf.data()),
            static_cast<std::streamsize>(sz));
  ofs.flush();
  const bool write_ok = static_cast<bool>(ofs) && !ofs.fail();
  ofs.close();
  if (!write_ok) {
    std::remove(tmp_path.c_str());
    return JNI_FALSE;
  }
  if (std::rename(tmp_path.c_str(), path.c_str()) != 0) {
    std::remove(tmp_path.c_str());
    return JNI_FALSE;
  }
  return JNI_TRUE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeLoadState(
    JNIEnv* env, jobject, jstring path_j) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_core.handle || !g_core.retro_unserialize) return JNI_FALSE;
  std::string path;
  if (!jstring_to_std(env, path_j, path, "nativeLoadState") || path.empty()) {
    return JNI_FALSE;
  }

  std::ifstream ifs(path, std::ios::binary | std::ios::ate);
  if (!ifs) return JNI_FALSE;
  const std::streamoff sz = ifs.tellg();
  constexpr std::streamoff kMaxStateBytes = 256LL * 1024LL * 1024LL;
  if (sz <= 0 || sz > kMaxStateBytes) return JNI_FALSE;
  ifs.seekg(0, std::ios::beg);
  std::vector<uint8_t> buf(static_cast<size_t>(sz));
  if (!ifs.read(reinterpret_cast<char*>(buf.data()), sz) || ifs.gcount() != sz) {
    return JNI_FALSE;
  }
  return g_core.retro_unserialize(buf.data(), buf.size()) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeGetFrameWidth(JNIEnv*, jobject) {
  std::lock_guard<std::mutex> state_lock(g_state_mutex);
  return static_cast<jint>(g_last_width);
}

extern "C" JNIEXPORT jint JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeGetFrameHeight(JNIEnv*, jobject) {
  std::lock_guard<std::mutex> state_lock(g_state_mutex);
  return static_cast<jint>(g_last_height);
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeGetLastCoreError(
    JNIEnv* env, jobject) {
  if (!env) return nullptr;
  std::lock_guard<std::mutex> lock(g_core_diag_mutex);
  const std::string& chosen =
      !g_last_core_error.empty() ? g_last_core_error : g_last_core_message;
  if (chosen.empty()) return nullptr;
  return env->NewStringUTF(chosen.c_str());
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeIsCoreErrorFatal(
    JNIEnv*, jobject) {
  std::lock_guard<std::mutex> lock(g_core_diag_mutex);
  return g_last_core_error_fatal ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeIsCoreShutdownRequested(
    JNIEnv*, jobject) {
  return g_core_shutdown_requested.load(std::memory_order_acquire)
             ? JNI_TRUE
             : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeHasRenderedFrame(
    JNIEnv*, jobject) {
  return g_has_rendered_frame.load(std::memory_order_acquire)
             ? JNI_TRUE
             : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_org_loopgamer_emulator_MainActivity_nativeUnloadCore(JNIEnv*, jobject) {
  std::lock_guard<std::mutex> lock(g_mutex);
  unload_core_locked();
}
