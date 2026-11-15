// Frontend Vulkan "thin" para a interface retro_hw_render_interface_vulkan
// (libretro_vulkan.h v5 / negotiation v1 e v2). O core (ex.: PPSSPP) cria ou
// negocia o VkDevice; providenciamos VkInstance, VkSurfaceKHR, VkPhysicalDevice,
// gerenciamento de swapchain no ANativeWindow, sincronização por frame-in-flight
// e transferência (copy/blit) da imagem entregue via set_image para a tela.
//
// libvulkan.so é carregado via dlopen para não criar dependência de link em
// dispositivos sem Vulkan — se o probe falhar, o core cai para OpenGL ES.

#include <algorithm>
#include <android/log.h>
#include <android/native_window.h>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <vector>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_android.h>

#if defined(LOOPGAMER_HAS_ADRENOTOOLS)
#include <adrenotools/bcenabler.h>
#include <adrenotools/driver.h>
#endif

#ifndef VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME
#define VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME "VK_KHR_portability_subset"
#endif

#ifndef VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
#define VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME \
  "VK_KHR_portability_enumeration"
#endif

#ifndef VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR
#define VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR 0x00000001
#endif

#define VK_LOGI(...) \
  __android_log_print(ANDROID_LOG_INFO, "loopgamer-vk", __VA_ARGS__)
#define VK_LOGW(...) \
  __android_log_print(ANDROID_LOG_WARN, "loopgamer-vk", __VA_ARGS__)
#define VK_LOGE(...) \
  __android_log_print(ANDROID_LOG_ERROR, "loopgamer-vk", __VA_ARGS__)

namespace {

// ---------------------------------------------------------------------------
// Definições espelhando libretro_vulkan.h (RetroArch v5 / negotiation v2)
// ---------------------------------------------------------------------------
struct retro_vulkan_context {
  VkPhysicalDevice gpu;
  VkDevice device;
  VkQueue queue;
  uint32_t queue_family_index;
  VkQueue presentation_queue;
  uint32_t presentation_queue_family_index;
};

typedef bool (*retro_vulkan_create_device_t)(
    retro_vulkan_context* context, VkInstance instance, VkPhysicalDevice gpu,
    VkSurfaceKHR surface, PFN_vkGetInstanceProcAddr get_instance_proc_addr,
    const char** required_device_extensions,
    unsigned num_required_device_extensions,
    const char** required_device_layers,
    unsigned num_required_device_layers,
    const VkPhysicalDeviceFeatures* required_features);

typedef void (*retro_vulkan_destroy_device_t)(void);
typedef const VkApplicationInfo* (*retro_vulkan_get_application_info_t)(void);

typedef VkInstance (*retro_vulkan_create_instance_wrapper_t)(
    void* opaque, const VkInstanceCreateInfo* create_info);
typedef VkInstance (*retro_vulkan_create_instance_t)(
    PFN_vkGetInstanceProcAddr get_instance_proc_addr,
    const VkApplicationInfo* app,
    retro_vulkan_create_instance_wrapper_t create_instance_wrapper,
    void* opaque);

typedef VkDevice (*retro_vulkan_create_device_wrapper_t)(
    VkPhysicalDevice gpu, void* opaque, const VkDeviceCreateInfo* create_info);
typedef bool (*retro_vulkan_create_device2_t)(
    retro_vulkan_context* context, VkInstance instance, VkPhysicalDevice gpu,
    VkSurfaceKHR surface, PFN_vkGetInstanceProcAddr get_instance_proc_addr,
    retro_vulkan_create_device_wrapper_t create_device_wrapper, void* opaque);

struct retro_hw_render_context_negotiation_interface_vulkan {
  int interface_type; // RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN = 0
  unsigned interface_version;
  retro_vulkan_get_application_info_t get_application_info;
  retro_vulkan_create_device_t create_device;
  retro_vulkan_destroy_device_t destroy_device;
  retro_vulkan_create_instance_t create_instance;
  retro_vulkan_create_device2_t create_device2;
};

struct retro_vulkan_image {
  VkImageView image_view;
  VkImageLayout image_layout;
  VkImageViewCreateInfo create_info;
};

typedef void (*retro_vulkan_set_image_t)(void* handle,
                                         const retro_vulkan_image* image,
                                         uint32_t num_semaphores,
                                         const VkSemaphore* semaphores,
                                         uint32_t src_queue_family);
typedef uint32_t (*retro_vulkan_get_sync_index_t)(void* handle);
typedef uint32_t (*retro_vulkan_get_sync_index_mask_t)(void* handle);
typedef void (*retro_vulkan_set_command_buffers_t)(
    void* handle, uint32_t num_cmd, const VkCommandBuffer* cmd);
typedef void (*retro_vulkan_wait_sync_index_t)(void* handle);
typedef void (*retro_vulkan_lock_queue_t)(void* handle);
typedef void (*retro_vulkan_unlock_queue_t)(void* handle);
typedef void (*retro_vulkan_set_signal_semaphore_t)(void* handle,
                                                    VkSemaphore semaphore);

struct retro_hw_render_interface_vulkan_local {
  int interface_type;     // RETRO_HW_RENDER_INTERFACE_VULKAN = 0
  unsigned interface_version; // = 5
  void* handle;
  VkInstance instance;
  VkPhysicalDevice gpu;
  VkDevice device;
  PFN_vkGetDeviceProcAddr get_device_proc_addr;
  PFN_vkGetInstanceProcAddr get_instance_proc_addr;
  VkQueue queue;
  unsigned queue_index;
  retro_vulkan_set_image_t set_image;
  retro_vulkan_get_sync_index_t get_sync_index;
  retro_vulkan_get_sync_index_mask_t get_sync_index_mask;
  retro_vulkan_set_command_buffers_t set_command_buffers;
  retro_vulkan_wait_sync_index_t wait_sync_index;
  retro_vulkan_lock_queue_t lock_queue;
  retro_vulkan_unlock_queue_t unlock_queue;
  retro_vulkan_set_signal_semaphore_t set_signal_semaphore;
};

// ---------------------------------------------------------------------------
// Funções Vulkan carregadas dinamicamente
// ---------------------------------------------------------------------------
struct VulkanFns {
  void* lib = nullptr;
  PFN_vkGetInstanceProcAddr gipa = nullptr;
  PFN_vkCreateInstance createInstance = nullptr;
  PFN_vkDestroyInstance destroyInstance = nullptr;
  PFN_vkEnumerateInstanceExtensionProperties enumInstExt = nullptr;
  PFN_vkEnumerateInstanceVersion enumInstVersion = nullptr;

  // instance-level
  PFN_vkCreateAndroidSurfaceKHR createAndroidSurface = nullptr;
  PFN_vkDestroySurfaceKHR destroySurface = nullptr;
  PFN_vkGetPhysicalDeviceSurfaceSupportKHR surfaceSupport = nullptr;
  PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR surfaceCaps = nullptr;
  PFN_vkGetPhysicalDeviceSurfaceFormatsKHR surfaceFormats = nullptr;
  PFN_vkGetPhysicalDeviceSurfacePresentModesKHR surfacePresentModes = nullptr;
  PFN_vkEnumeratePhysicalDevices enumPhysDevices = nullptr;
  PFN_vkEnumerateDeviceExtensionProperties enumDevExt = nullptr;
  PFN_vkGetPhysicalDeviceProperties physProps = nullptr;
  PFN_vkGetPhysicalDeviceFormatProperties formatProps = nullptr;
  PFN_vkGetPhysicalDeviceQueueFamilyProperties queueProps = nullptr;
  PFN_vkCreateDevice createDevice = nullptr;
  PFN_vkGetDeviceQueue getDeviceQueue = nullptr;

  // device-level
  PFN_vkGetDeviceProcAddr gdpa = nullptr;
  PFN_vkDestroyDevice destroyDevice = nullptr;
  PFN_vkCreateCommandPool createCommandPool = nullptr;
  PFN_vkDestroyCommandPool destroyCommandPool = nullptr;
  PFN_vkAllocateCommandBuffers allocateCommandBuffers = nullptr;
  PFN_vkFreeCommandBuffers freeCommandBuffers = nullptr;
  PFN_vkBeginCommandBuffer beginCommandBuffer = nullptr;
  PFN_vkEndCommandBuffer endCommandBuffer = nullptr;
  PFN_vkCmdPipelineBarrier cmdPipelineBarrier = nullptr;
  PFN_vkCmdBlitImage cmdBlitImage = nullptr;
  PFN_vkCmdCopyImage cmdCopyImage = nullptr;
  PFN_vkQueueSubmit queueSubmit = nullptr;
  PFN_vkQueueWaitIdle queueWaitIdle = nullptr;
  PFN_vkDeviceWaitIdle deviceWaitIdle = nullptr;
  PFN_vkCreateFence createFence = nullptr;
  PFN_vkDestroyFence destroyFence = nullptr;
  PFN_vkWaitForFences waitForFences = nullptr;
  PFN_vkResetFences resetFences = nullptr;
  PFN_vkCreateSemaphore createSemaphore = nullptr;
  PFN_vkDestroySemaphore destroySemaphore = nullptr;
  PFN_vkCreateSwapchainKHR createSwapchain = nullptr;
  PFN_vkDestroySwapchainKHR destroySwapchain = nullptr;
  PFN_vkGetSwapchainImagesKHR getSwapchainImages = nullptr;
  PFN_vkAcquireNextImageKHR acquireNextImage = nullptr;
  PFN_vkQueuePresentKHR queuePresent = nullptr;
};

VulkanFns g_fn;

void clear_instance_and_device_fns() {
  g_fn.createAndroidSurface = nullptr;
  g_fn.destroySurface = nullptr;
  g_fn.surfaceSupport = nullptr;
  g_fn.surfaceCaps = nullptr;
  g_fn.surfaceFormats = nullptr;
  g_fn.surfacePresentModes = nullptr;
  g_fn.enumPhysDevices = nullptr;
  g_fn.enumDevExt = nullptr;
  g_fn.physProps = nullptr;
  g_fn.formatProps = nullptr;
  g_fn.queueProps = nullptr;
  g_fn.createDevice = nullptr;
  g_fn.getDeviceQueue = nullptr;
  g_fn.gdpa = nullptr;
  g_fn.destroyDevice = nullptr;
  g_fn.createCommandPool = nullptr;
  g_fn.destroyCommandPool = nullptr;
  g_fn.allocateCommandBuffers = nullptr;
  g_fn.freeCommandBuffers = nullptr;
  g_fn.beginCommandBuffer = nullptr;
  g_fn.endCommandBuffer = nullptr;
  g_fn.cmdPipelineBarrier = nullptr;
  g_fn.cmdBlitImage = nullptr;
  g_fn.cmdCopyImage = nullptr;
  g_fn.queueSubmit = nullptr;
  g_fn.queueWaitIdle = nullptr;
  g_fn.deviceWaitIdle = nullptr;
  g_fn.createFence = nullptr;
  g_fn.destroyFence = nullptr;
  g_fn.waitForFences = nullptr;
  g_fn.resetFences = nullptr;
  g_fn.createSemaphore = nullptr;
  g_fn.destroySemaphore = nullptr;
  g_fn.createSwapchain = nullptr;
  g_fn.destroySwapchain = nullptr;
  g_fn.getSwapchainImages = nullptr;
  g_fn.acquireNextImage = nullptr;
  g_fn.queuePresent = nullptr;
}

std::string g_hookLibDir;
std::string g_tmpDir;
std::string g_customDriverDir;
std::string g_customDriverName;
std::string g_loadedDriverKey;
std::string g_freedrenoPreset;
bool g_adrenoTurbo = false;
bool g_bcnPatchAttempted = false;

std::string ensure_trailing_slash(const char* raw) {
  if (!raw || !*raw) return {};
  std::string out(raw);
  if (out.back() != '/') out.push_back('/');
  return out;
}

bool ensure_dir_exists(const std::string& path) {
  if (path.empty()) return false;
  struct stat st{};
  if (stat(path.c_str(), &st) == 0) return S_ISDIR(st.st_mode);
  if (mkdir(path.c_str(), 0755) == 0) return true;
  return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// Configura flags Turnip/Freedreno inspiradas no NativeLibrary::SetFreedrenoEnv do Eden
void apply_freedreno_env() {
  if (g_freedrenoPreset == "sysmem") {
    setenv("TU_DEBUG", "sysmem", 1);
    unsetenv("FD_DEV_FEATURES");
  } else if (g_freedrenoPreset == "noubwc") {
    setenv("TU_DEBUG", "noubwc", 1);
    unsetenv("FD_DEV_FEATURES");
  } else if (g_freedrenoPreset == "nobin") {
    setenv("TU_DEBUG", "nobin", 1);
    unsetenv("FD_DEV_FEATURES");
  } else if (g_freedrenoPreset == "noconform") {
    setenv("TU_DEBUG", "noconform", 1);
    unsetenv("FD_DEV_FEATURES");
  } else if (g_freedrenoPreset == "gmem") {
    setenv("TU_DEBUG", "gmem", 1);
    unsetenv("FD_DEV_FEATURES");
  } else {
    unsetenv("TU_DEBUG");
    unsetenv("FD_DEV_FEATURES");
  }
}

bool load_loader() {
  apply_freedreno_env();
  const std::string desiredKey =
      g_customDriverDir + "|" + g_customDriverName;
  if (g_fn.lib && g_loadedDriverKey == desiredKey) {
#if defined(LOOPGAMER_HAS_ADRENOTOOLS)
    adrenotools_set_turbo(g_adrenoTurbo);
#endif
    return true;
  }
  g_fn = VulkanFns{};
  g_loadedDriverKey = desiredKey;
  g_bcnPatchAttempted = false;

#if defined(LOOPGAMER_HAS_ADRENOTOOLS)
  if (!g_customDriverName.empty() && !g_customDriverDir.empty() &&
      !g_hookLibDir.empty()) {
    int flags = ADRENOTOOLS_DRIVER_CUSTOM;
    std::string redirectDir;
    if (!g_tmpDir.empty()) {
      redirectDir = g_tmpDir + "vk_redirect/";
      if (ensure_dir_exists(redirectDir)) {
        flags |= ADRENOTOOLS_DRIVER_FILE_REDIRECT;
      } else {
        redirectDir.clear();
      }
    }
    VK_LOGI("Tentando carregar driver Vulkan custom via adrenotools: %s%s (redirect=%s preset=%s)",
            g_customDriverDir.c_str(), g_customDriverName.c_str(),
            redirectDir.empty() ? "none" : redirectDir.c_str(),
            g_freedrenoPreset.empty() ? "default" : g_freedrenoPreset.c_str());
    g_fn.lib = adrenotools_open_libvulkan(
        RTLD_NOW,
        flags,
        g_tmpDir.empty() ? nullptr : g_tmpDir.c_str(),
        g_hookLibDir.c_str(),
        g_customDriverDir.c_str(),
        g_customDriverName.c_str(),
        redirectDir.empty() ? nullptr : redirectDir.c_str(),
        nullptr);
    if (g_fn.lib) {
      adrenotools_set_turbo(g_adrenoTurbo);
      VK_LOGI("Driver Turnip/Adreno carregado via adrenotools (turbo=%d)",
              g_adrenoTurbo ? 1 : 0);
    } else {
      VK_LOGW("adrenotools_open_libvulkan falhou; usando driver do sistema");
    }
  } else if (g_adrenoTurbo) {
    adrenotools_set_turbo(true);
  }
#endif

  if (!g_fn.lib) {
    g_fn.lib = dlopen("libvulkan.so", RTLD_LAZY | RTLD_LOCAL);
  }
  if (!g_fn.lib) {
    VK_LOGW("dlopen(libvulkan.so) falhou");
    return false;
  }
  g_fn.gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
      dlsym(g_fn.lib, "vkGetInstanceProcAddr"));
  if (!g_fn.gipa) {
    VK_LOGW("vkGetInstanceProcAddr ausente em libvulkan.so");
    return false;
  }
  g_fn.createInstance = reinterpret_cast<PFN_vkCreateInstance>(
      g_fn.gipa(nullptr, "vkCreateInstance"));
  g_fn.destroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(
      g_fn.gipa(nullptr, "vkDestroyInstance"));
  g_fn.enumInstExt =
      reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(
          g_fn.gipa(nullptr, "vkEnumerateInstanceExtensionProperties"));
  g_fn.enumInstVersion =
      reinterpret_cast<PFN_vkEnumerateInstanceVersion>(
          g_fn.gipa(nullptr, "vkEnumerateInstanceVersion"));
  return g_fn.createInstance && g_fn.destroyInstance;
}

// ---------------------------------------------------------------------------
// Estado do frontend Vulkan
// ---------------------------------------------------------------------------
struct FrameSlot {
  VkCommandBuffer cmd = VK_NULL_HANDLE;
  VkFence fence = VK_NULL_HANDLE;
  VkSemaphore acquireSem = VK_NULL_HANDLE;
  bool fenceSubmitted = false;
};

struct VkFe {
  bool wanted = false;
  bool probed = false;
  bool probeOk = false;
  bool active = false;
  std::atomic<bool> vsync{false};

  bool frameValid = false;
  bool hasImage = false;
  bool hasAcquired = false;
  bool needsRecreate = false;
  bool suboptimalTried = false;
  bool deviceFromNegotiation = false;

  ANativeWindow* window = nullptr;
  const retro_hw_render_context_negotiation_interface_vulkan* neg = nullptr;

  VkInstance instance = VK_NULL_HANDLE;
  VkPhysicalDevice gpu = VK_NULL_HANDLE;
  VkDevice device = VK_NULL_HANDLE;
  VkQueue queue = VK_NULL_HANDLE;
  uint32_t queueFamily = 0;
  VkQueue presentQueue = VK_NULL_HANDLE;
  uint32_t presentQueueFamily = 0;

  VkSurfaceKHR surface = VK_NULL_HANDLE;
  VkSwapchainKHR swapchain = VK_NULL_HANDLE;
  VkFormat swapFormat = VK_FORMAT_B8G8R8A8_UNORM;
  VkColorSpaceKHR swapColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
  VkExtent2D extent{480, 272};
  int32_t winWidthAtCreate = 0;
  int32_t winHeightAtCreate = 0;
  std::vector<VkImage> swapImages;

  VkCommandPool cmdPool = VK_NULL_HANDLE;
  std::vector<FrameSlot> slots;
  std::vector<VkSemaphore> renderSems;
  std::vector<int> imageLastSlot;
  uint32_t curSlot = 0;
  uint32_t acquiredIdx = 0;
  uint32_t acquiredSlot = 0;
  uint32_t syncIndex = 0;
  uint32_t syncMask = 0;

  // Cache simples do suporte de filtro linear por formato de origem
  VkFormat cachedSrcFmt = VK_FORMAT_UNDEFINED;
  bool cachedSrcLinearOk = true;

  std::vector<const char*> reqInstExts;
  std::vector<const char*> reqDevExts;

  retro_vulkan_image curImage{};
  uint32_t srcQueueFamily = VK_QUEUE_FAMILY_IGNORED;
  VkSemaphore signalSem = VK_NULL_HANDLE;
  uint32_t pendingSemCount = 0;
  VkSemaphore pendingSems[8]{};
  VkCommandBuffer pendingCmds[16]{};
  uint32_t pendingCmdCount = 0;

  std::mutex queueMutex;
  std::mutex fenceMutex;
  retro_hw_render_interface_vulkan_local iface{};
};

VkFe g_fe;

bool device_has_extension(VkPhysicalDevice pd, const char* extName) {
  if (!g_fn.enumDevExt) return false;
  uint32_t count = 0;
  if (g_fn.enumDevExt(pd, nullptr, &count, nullptr) != VK_SUCCESS || count == 0)
    return false;
  std::vector<VkExtensionProperties> props(count);
  if (g_fn.enumDevExt(pd, nullptr, &count, props.data()) != VK_SUCCESS)
    return false;
  for (const auto& p : props) {
    if (std::strcmp(p.extensionName, extName) == 0) return true;
  }
  return false;
}

bool load_instance_fns(VkInstance inst) {
#define LOADI(field, sym)                                                     \
  g_fn.field = reinterpret_cast<decltype(g_fn.field)>(g_fn.gipa(inst, sym)); \
  if (!g_fn.field) {                                                         \
    VK_LOGW("Falha ao carregar símbolo Vulkan de instância: %s", sym);       \
    return false;                                                            \
  }
  LOADI(createAndroidSurface, "vkCreateAndroidSurfaceKHR")
  LOADI(destroySurface, "vkDestroySurfaceKHR")
  LOADI(surfaceSupport, "vkGetPhysicalDeviceSurfaceSupportKHR")
  LOADI(surfaceCaps, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
  LOADI(surfaceFormats, "vkGetPhysicalDeviceSurfaceFormatsKHR")
  LOADI(surfacePresentModes, "vkGetPhysicalDeviceSurfacePresentModesKHR")
  LOADI(enumPhysDevices, "vkEnumeratePhysicalDevices")
  LOADI(enumDevExt, "vkEnumerateDeviceExtensionProperties")
  LOADI(physProps, "vkGetPhysicalDeviceProperties")
  LOADI(formatProps, "vkGetPhysicalDeviceFormatProperties")
  LOADI(queueProps, "vkGetPhysicalDeviceQueueFamilyProperties")
  LOADI(createDevice, "vkCreateDevice")
  LOADI(getDeviceQueue, "vkGetDeviceQueue")
#undef LOADI
  return true;
}

bool load_device_fns() {
  PFN_vkGetDeviceProcAddr gdpa = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
      g_fn.gipa(g_fe.instance, "vkGetDeviceProcAddr"));
  if (!gdpa) return false;
  g_fn.gdpa = gdpa;
#define LOADD(field, sym)                                                     \
  g_fn.field = reinterpret_cast<decltype(g_fn.field)>(gdpa(g_fe.device, sym)); \
  if (!g_fn.field) {                                                          \
    VK_LOGE("Falha ao carregar símbolo Vulkan de device: %s", sym);           \
    return false;                                                             \
  }
  LOADD(destroyDevice, "vkDestroyDevice")
  LOADD(createCommandPool, "vkCreateCommandPool")
  LOADD(destroyCommandPool, "vkDestroyCommandPool")
  LOADD(allocateCommandBuffers, "vkAllocateCommandBuffers")
  LOADD(freeCommandBuffers, "vkFreeCommandBuffers")
  LOADD(beginCommandBuffer, "vkBeginCommandBuffer")
  LOADD(endCommandBuffer, "vkEndCommandBuffer")
  LOADD(cmdPipelineBarrier, "vkCmdPipelineBarrier")
  LOADD(cmdBlitImage, "vkCmdBlitImage")
  LOADD(cmdCopyImage, "vkCmdCopyImage")
  LOADD(queueSubmit, "vkQueueSubmit")
  LOADD(queueWaitIdle, "vkQueueWaitIdle")
  LOADD(deviceWaitIdle, "vkDeviceWaitIdle")
  LOADD(createFence, "vkCreateFence")
  LOADD(destroyFence, "vkDestroyFence")
  LOADD(waitForFences, "vkWaitForFences")
  LOADD(resetFences, "vkResetFences")
  LOADD(createSemaphore, "vkCreateSemaphore")
  LOADD(destroySemaphore, "vkDestroySemaphore")
  LOADD(createSwapchain, "vkCreateSwapchainKHR")
  LOADD(destroySwapchain, "vkDestroySwapchainKHR")
  LOADD(getSwapchainImages, "vkGetSwapchainImagesKHR")
  LOADD(acquireNextImage, "vkAcquireNextImageKHR")
  LOADD(queuePresent, "vkQueuePresentKHR")
#undef LOADD
  return true;
}

// ---------------------------------------------------------------------------
// Probe: confirma loader, extensões Android e ao menos 1 GPU Vulkan utilizável
// ---------------------------------------------------------------------------
bool do_probe() {
  if (g_fe.probed) return g_fe.probeOk;
  g_fe.probed = true;
  if (!load_loader()) return false;

  uint32_t loaderApi = VK_API_VERSION_1_0;
  if (g_fn.enumInstVersion) {
    g_fn.enumInstVersion(&loaderApi);
  }

  VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
  app.pApplicationName = "loopgamer";
  app.apiVersion =
      loaderApi >= VK_API_VERSION_1_1 ? VK_API_VERSION_1_1 : VK_API_VERSION_1_0;

  const char* exts[] = {VK_KHR_SURFACE_EXTENSION_NAME,
                        VK_KHR_ANDROID_SURFACE_EXTENSION_NAME};
  VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
  ci.pApplicationInfo = &app;
  ci.enabledExtensionCount = 2;
  ci.ppEnabledExtensionNames = exts;

  VkInstance inst = VK_NULL_HANDLE;
  VkResult res = g_fn.createInstance(&ci, nullptr, &inst);
  if (res != VK_SUCCESS || inst == VK_NULL_HANDLE) {
    VK_LOGW("Probe vkCreateInstance falhou: %d", static_cast<int>(res));
    return false;
  }

  bool ok = false;
  auto enumPd = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(
      g_fn.gipa(inst, "vkEnumeratePhysicalDevices"));
  auto qProps = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
      g_fn.gipa(inst, "vkGetPhysicalDeviceQueueFamilyProperties"));
  auto enumExt = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(
      g_fn.gipa(inst, "vkEnumerateDeviceExtensionProperties"));
  if (enumPd && qProps && enumExt) {
    uint32_t count = 0;
    if (enumPd(inst, &count, nullptr) == VK_SUCCESS && count > 0) {
      std::vector<VkPhysicalDevice> pds(count);
      if (enumPd(inst, &count, pds.data()) == VK_SUCCESS) {
        for (VkPhysicalDevice pd : pds) {
          uint32_t qc = 0;
          qProps(pd, &qc, nullptr);
          std::vector<VkQueueFamilyProperties> qp(qc);
          qProps(pd, &qc, qp.data());
          bool hasGfxCompute = false;
          for (const auto& q : qp) {
            if ((q.queueFlags & VK_QUEUE_GRAPHICS_BIT) &&
                (q.queueFlags & VK_QUEUE_COMPUTE_BIT)) {
              hasGfxCompute = true;
              break;
            }
          }
          if (!hasGfxCompute) continue;
          uint32_t ec = 0;
          if (enumExt(pd, nullptr, &ec, nullptr) == VK_SUCCESS && ec > 0) {
            std::vector<VkExtensionProperties> ep(ec);
            enumExt(pd, nullptr, &ec, ep.data());
            for (const auto& e : ep) {
              if (std::strcmp(e.extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) ==
                  0) {
                ok = true;
                break;
              }
            }
          }
          if (ok) break;
        }
      }
    }
  }

  g_fn.destroyInstance(inst, nullptr);
  g_fe.probeOk = ok;
  VK_LOGI("Probe Vulkan: %s", ok ? "OK" : "indisponível");
  return ok;
}

// ---------------------------------------------------------------------------
// Seleção de physical device (GRAPHICS + COMPUTE + present + VK_KHR_swapchain)
// ---------------------------------------------------------------------------
int device_type_score(VkPhysicalDeviceType t) {
  switch (t) {
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:
      return 4;
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU:
      return 3;
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:
      return 2;
    case VK_PHYSICAL_DEVICE_TYPE_CPU:
      return 1;
    default:
      return 0;
  }
}

bool pick_physical_device(VkPhysicalDevice* out) {
  uint32_t count = 0;
  if (g_fn.enumPhysDevices(g_fe.instance, &count, nullptr) != VK_SUCCESS ||
      count == 0)
    return false;
  std::vector<VkPhysicalDevice> devices(count);
  if (g_fn.enumPhysDevices(g_fe.instance, &count, devices.data()) != VK_SUCCESS)
    return false;

  int bestScore = -1;
  VkPhysicalDevice best = VK_NULL_HANDLE;
  for (VkPhysicalDevice pd : devices) {
    if (!device_has_extension(pd, VK_KHR_SWAPCHAIN_EXTENSION_NAME)) continue;

    VkPhysicalDeviceProperties props{};
    g_fn.physProps(pd, &props);
    uint32_t qc = 0;
    g_fn.queueProps(pd, &qc, nullptr);
    std::vector<VkQueueFamilyProperties> qp(qc);
    g_fn.queueProps(pd, &qc, qp.data());

    bool hasCombinedQueue = false;
    bool hasGfxCompute = false;
    bool hasPresent = false;
    for (uint32_t i = 0; i < qc; ++i) {
      const auto& q = qp[i];
      const bool gc = (q.queueFlags & VK_QUEUE_GRAPHICS_BIT) &&
                      (q.queueFlags & VK_QUEUE_COMPUTE_BIT);
      VkBool32 present = VK_FALSE;
      if (g_fn.surfaceSupport(pd, i, g_fe.surface, &present) != VK_SUCCESS)
        present = VK_FALSE;
      if (gc) hasGfxCompute = true;
      if (present) hasPresent = true;
      if (gc && present) {
        hasCombinedQueue = true;
        break;
      }
    }
    if (!hasCombinedQueue && !(hasGfxCompute && hasPresent)) continue;

    // Prefere GPU dedicada/integrada e favorece fila unificada graphics+present
    const int score =
        device_type_score(props.deviceType) * 10 + (hasCombinedQueue ? 5 : 0);
    if (score > bestScore) {
      bestScore = score;
      best = pd;
    }
  }
  if (best == VK_NULL_HANDLE) return false;
  *out = best;
  return true;
}

// ---------------------------------------------------------------------------
// Swapchain, formatos e sincronização
// ---------------------------------------------------------------------------
bool choose_swapchain_format() {
  uint32_t count = 0;
  if (g_fn.surfaceFormats(g_fe.gpu, g_fe.surface, &count, nullptr) !=
          VK_SUCCESS ||
      count == 0)
    return false;
  std::vector<VkSurfaceFormatKHR> formats(count);
  if (g_fn.surfaceFormats(g_fe.gpu, g_fe.surface, &count, formats.data()) !=
      VK_SUCCESS)
    return false;

  auto supports_blit_dst = [&](VkFormat f) -> bool {
    VkFormatProperties fp{};
    g_fn.formatProps(g_fe.gpu, f, &fp);
    return (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_DST_BIT) != 0;
  };
  auto find_fmt = [&](VkFormat f, bool requireBlit) -> VkSurfaceFormatKHR {
    for (const auto& fmt : formats) {
      if (fmt.format == f && (!requireBlit || supports_blit_dst(f))) return fmt;
    }
    return VkSurfaceFormatKHR{VK_FORMAT_UNDEFINED,
                              VK_COLOR_SPACE_SRGB_NONLINEAR_KHR};
  };

  // UNORM evita dupla conversão gama quando cores entregam BGRA/RGBA UNORM
  // (PPSSPP usa VK_FORMAT_B8G8R8A8_UNORM diretamente).
  const VkFormat preferred[] = {
      VK_FORMAT_B8G8R8A8_UNORM,
      VK_FORMAT_R8G8B8A8_UNORM,
      VK_FORMAT_B8G8R8A8_SRGB,
      VK_FORMAT_R8G8B8A8_SRGB,
  };
  VkSurfaceFormatKHR pick{VK_FORMAT_UNDEFINED,
                          VK_COLOR_SPACE_SRGB_NONLINEAR_KHR};
  for (VkFormat f : preferred) {
    pick = find_fmt(f, true);
    if (pick.format != VK_FORMAT_UNDEFINED) break;
  }
  if (pick.format == VK_FORMAT_UNDEFINED) {
    for (const auto& fmt : formats) {
      if (supports_blit_dst(fmt.format)) {
        pick = fmt;
        break;
      }
    }
  }
  if (pick.format == VK_FORMAT_UNDEFINED) pick = formats[0];
  g_fe.swapFormat = pick.format;
  g_fe.swapColorSpace = pick.colorSpace;
  return true;
}

VkCompositeAlphaFlagBitsKHR choose_composite_alpha(
    VkCompositeAlphaFlagsKHR supported) {
  const VkCompositeAlphaFlagBitsKHR order[] = {
      VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
      VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
      VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
      VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
  };
  for (auto bit : order) {
    if (supported & bit) return bit;
  }
  return VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
}

VkPresentModeKHR choose_present_mode() {
  uint32_t count = 0;
  if (g_fn.surfacePresentModes(g_fe.gpu, g_fe.surface, &count, nullptr) !=
          VK_SUCCESS ||
      count == 0) {
    return VK_PRESENT_MODE_FIFO_KHR;
  }
  std::vector<VkPresentModeKHR> modes(count);
  if (g_fn.surfacePresentModes(g_fe.gpu, g_fe.surface, &count, modes.data()) !=
      VK_SUCCESS) {
    return VK_PRESENT_MODE_FIFO_KHR;
  }
  auto has = [&](VkPresentModeKHR m) {
    return std::find(modes.begin(), modes.end(), m) != modes.end();
  };
  if (!g_fe.vsync.load(std::memory_order_relaxed)) {
    // MAILBOX entrega triplo-buffer sem tearing e sem travar FPS pela metade
    if (has(VK_PRESENT_MODE_MAILBOX_KHR)) return VK_PRESENT_MODE_MAILBOX_KHR;
    if (has(VK_PRESENT_MODE_IMMEDIATE_KHR)) return VK_PRESENT_MODE_IMMEDIATE_KHR;
    if (has(VK_PRESENT_MODE_FIFO_RELAXED_KHR))
      return VK_PRESENT_MODE_FIFO_RELAXED_KHR;
  }
  return VK_PRESENT_MODE_FIFO_KHR;
}

void free_sync_objects() {
  if (!g_fe.device) return;
  if (!g_fe.slots.empty()) {
    std::vector<VkCommandBuffer> cbufs;
    cbufs.reserve(g_fe.slots.size());
    for (auto& s : g_fe.slots) {
      if (s.fence != VK_NULL_HANDLE && g_fn.destroyFence)
        g_fn.destroyFence(g_fe.device, s.fence, nullptr);
      if (s.acquireSem != VK_NULL_HANDLE && g_fn.destroySemaphore)
        g_fn.destroySemaphore(g_fe.device, s.acquireSem, nullptr);
      if (s.cmd != VK_NULL_HANDLE) cbufs.push_back(s.cmd);
    }
    if (!cbufs.empty() && g_fe.cmdPool != VK_NULL_HANDLE &&
        g_fn.freeCommandBuffers) {
      g_fn.freeCommandBuffers(g_fe.device, g_fe.cmdPool,
                              static_cast<uint32_t>(cbufs.size()), cbufs.data());
    }
  }
  g_fe.slots.clear();

  for (VkSemaphore sem : g_fe.renderSems) {
    if (sem != VK_NULL_HANDLE && g_fn.destroySemaphore)
      g_fn.destroySemaphore(g_fe.device, sem, nullptr);
  }
  g_fe.renderSems.clear();
  g_fe.imageLastSlot.clear();
  g_fe.hasAcquired = false;
  g_fe.frameValid = false;
  g_fe.curSlot = 0;
  g_fe.acquiredIdx = 0;
  g_fe.acquiredSlot = 0;
}

bool create_swapchain() {
  VkSurfaceCapabilitiesKHR caps{};
  if (g_fn.surfaceCaps(g_fe.gpu, g_fe.surface, &caps) != VK_SUCCESS)
    return false;

  // Triple buffering quando possível para pipeline suave no SurfaceTexture
  uint32_t count = std::max(caps.minImageCount + 1, 3u);
  if (caps.maxImageCount > 0 && count > caps.maxImageCount)
    count = caps.maxImageCount;
  if (count < caps.minImageCount) count = caps.minImageCount;
  if (count < 2 && (caps.maxImageCount == 0 || caps.maxImageCount >= 2))
    count = 2;

  VkExtent2D ext = caps.currentExtent;
  const int32_t winW = g_fe.window ? ANativeWindow_getWidth(g_fe.window) : 0;
  const int32_t winH = g_fe.window ? ANativeWindow_getHeight(g_fe.window) : 0;
  if (ext.width == 0xFFFFFFFFu || ext.height == 0xFFFFFFFFu || ext.width == 0 ||
      ext.height == 0) {
    ext.width = winW > 0 ? static_cast<uint32_t>(winW) : 480u;
    ext.height = winH > 0 ? static_cast<uint32_t>(winH) : 272u;
    ext.width = std::clamp(ext.width, caps.minImageExtent.width,
                           caps.maxImageExtent.width);
    ext.height = std::clamp(ext.height, caps.minImageExtent.height,
                            caps.maxImageExtent.height);
  }
  g_fe.extent = ext;
  g_fe.winWidthAtCreate = winW;
  g_fe.winHeightAtCreate = winH;

  VkImageUsageFlags usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
  if (caps.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) {
    usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
  }
  usage &= caps.supportedUsageFlags;
  if (!(usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT)) {
    VK_LOGE("Swapchain não suporta VK_IMAGE_USAGE_TRANSFER_DST_BIT");
    return false;
  }

  VkSwapchainCreateInfoKHR sci{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
  sci.surface = g_fe.surface;
  sci.minImageCount = count;
  sci.imageFormat = g_fe.swapFormat;
  sci.imageColorSpace = g_fe.swapColorSpace;
  sci.imageExtent = ext;
  sci.imageArrayLayers = 1;
  sci.imageUsage = usage;

  uint32_t qFamilies[2] = {g_fe.queueFamily, g_fe.presentQueueFamily};
  if (g_fe.presentQueueFamily != g_fe.queueFamily) {
    sci.imageSharingMode = VK_SHARING_MODE_CONCURRENT;
    sci.queueFamilyIndexCount = 2;
    sci.pQueueFamilyIndices = qFamilies;
  } else {
    sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
  }

  sci.preTransform = caps.currentTransform;
  sci.compositeAlpha = choose_composite_alpha(caps.supportedCompositeAlpha);
  sci.presentMode = choose_present_mode();
  sci.clipped = VK_TRUE;
  sci.oldSwapchain = VK_NULL_HANDLE;

  VkResult scRes =
      g_fn.createSwapchain(g_fe.device, &sci, nullptr, &g_fe.swapchain);
  if (scRes != VK_SUCCESS || g_fe.swapchain == VK_NULL_HANDLE) {
    VK_LOGE("vkCreateSwapchainKHR falhou: %d", static_cast<int>(scRes));
    return false;
  }

  uint32_t imgCount = 0;
  if (g_fn.getSwapchainImages(g_fe.device, g_fe.swapchain, &imgCount,
                              nullptr) != VK_SUCCESS ||
      imgCount == 0) {
    return false;
  }
  g_fe.swapImages.resize(imgCount);
  if (g_fn.getSwapchainImages(g_fe.device, g_fe.swapchain, &imgCount,
                              g_fe.swapImages.data()) != VK_SUCCESS) {
    return false;
  }

  g_fe.syncMask = 0;
  for (uint32_t i = 0; i < imgCount && i < 32; ++i) g_fe.syncMask |= (1u << i);

  free_sync_objects();
  const uint32_t slotCount = std::max(imgCount + 1, 4u);
  g_fe.slots.resize(slotCount);
  std::vector<VkCommandBuffer> allocCmds(slotCount, VK_NULL_HANDLE);
  VkCommandBufferAllocateInfo cai{
      VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
  cai.commandPool = g_fe.cmdPool;
  cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
  cai.commandBufferCount = slotCount;
  if (g_fn.allocateCommandBuffers(g_fe.device, &cai, allocCmds.data()) !=
      VK_SUCCESS) {
    free_sync_objects();
    return false;
  }

  VkSemaphoreCreateInfo si{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
  VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  for (uint32_t i = 0; i < slotCount; ++i) {
    g_fe.slots[i].cmd = allocCmds[i];
    g_fe.slots[i].fenceSubmitted = false;
    if (g_fn.createFence(g_fe.device, &fi, nullptr, &g_fe.slots[i].fence) !=
            VK_SUCCESS ||
        g_fn.createSemaphore(g_fe.device, &si, nullptr,
                             &g_fe.slots[i].acquireSem) != VK_SUCCESS) {
      free_sync_objects();
      return false;
    }
  }

  g_fe.renderSems.resize(imgCount, VK_NULL_HANDLE);
  g_fe.imageLastSlot.assign(imgCount, -1);
  for (uint32_t i = 0; i < imgCount; ++i) {
    if (g_fn.createSemaphore(g_fe.device, &si, nullptr, &g_fe.renderSems[i]) !=
        VK_SUCCESS) {
      free_sync_objects();
      return false;
    }
  }

  g_fe.needsRecreate = false;
  VK_LOGI(
      "Swapchain criado: %ux%u, imagens=%u, format=%d, presentMode=%d",
      ext.width, ext.height, imgCount, static_cast<int>(g_fe.swapFormat),
      static_cast<int>(sci.presentMode));
  return true;
}

bool destroy_swapchain() {
  if (g_fe.device) {
    std::lock_guard<std::mutex> lock(g_fe.queueMutex);
    if (g_fn.deviceWaitIdle) g_fn.deviceWaitIdle(g_fe.device);
  }
  free_sync_objects();
  if (g_fe.swapchain != VK_NULL_HANDLE && g_fe.device && g_fn.destroySwapchain) {
    g_fn.destroySwapchain(g_fe.device, g_fe.swapchain, nullptr);
    g_fe.swapchain = VK_NULL_HANDLE;
  }
  g_fe.swapImages.clear();
  return true;
}

bool recreate_swapchain() {
  destroy_swapchain();
  return choose_swapchain_format() && create_swapchain();
}

void wait_and_reset_slot_fence_locked(uint32_t slotIdx) {
  if (slotIdx >= g_fe.slots.size()) return;
  FrameSlot& s = g_fe.slots[slotIdx];
  if (!s.fenceSubmitted || s.fence == VK_NULL_HANDLE) return;
  g_fn.waitForFences(g_fe.device, 1, &s.fence, VK_TRUE, UINT64_MAX);
  g_fn.resetFences(g_fe.device, 1, &s.fence);
  s.fenceSubmitted = false;
  for (int& mapped : g_fe.imageLastSlot) {
    if (mapped == static_cast<int>(slotIdx)) mapped = -1;
  }
}

void wait_and_reset_slot_fence(uint32_t slotIdx) {
  std::lock_guard<std::mutex> lock(g_fe.fenceMutex);
  wait_and_reset_slot_fence_locked(slotIdx);
}

void wait_image_in_flight(uint32_t imageIdx) {
  std::lock_guard<std::mutex> lock(g_fe.fenceMutex);
  if (imageIdx >= g_fe.imageLastSlot.size()) return;
  const int prevSlot = g_fe.imageLastSlot[imageIdx];
  if (prevSlot >= 0) {
    wait_and_reset_slot_fence_locked(static_cast<uint32_t>(prevSlot));
  }
}

// ---------------------------------------------------------------------------
// Callbacks retro_hw_render_interface_vulkan v5
// ---------------------------------------------------------------------------
void cb_set_image(void* handle, const retro_vulkan_image* image,
                  uint32_t num_semaphores, const VkSemaphore* semaphores,
                  uint32_t src_queue_family) {
  VkFe& fe = *static_cast<VkFe*>(handle);
  if (!image) return;
  fe.curImage = *image;
  fe.hasImage = true;
  fe.srcQueueFamily = src_queue_family;
  fe.pendingSemCount = num_semaphores > 8 ? 8 : num_semaphores;
  for (uint32_t i = 0; i < fe.pendingSemCount; ++i)
    fe.pendingSems[i] = semaphores[i];
}

uint32_t cb_get_sync_index(void* handle) {
  return static_cast<VkFe*>(handle)->syncIndex;
}

uint32_t cb_get_sync_index_mask(void* handle) {
  return static_cast<VkFe*>(handle)->syncMask;
}

void cb_set_command_buffers(void* handle, uint32_t num_cmd,
                            const VkCommandBuffer* cmd) {
  VkFe& fe = *static_cast<VkFe*>(handle);
  fe.pendingCmdCount = num_cmd > 16 ? 16 : num_cmd;
  for (uint32_t i = 0; i < fe.pendingCmdCount; ++i)
    fe.pendingCmds[i] = cmd[i];
}

void cb_wait_sync_index(void* handle) {
  VkFe& fe = *static_cast<VkFe*>(handle);
  if (!fe.frameValid || fe.syncIndex >= fe.swapImages.size()) return;
  wait_image_in_flight(fe.syncIndex);
}

void cb_lock_queue(void* handle) {
  static_cast<VkFe*>(handle)->queueMutex.lock();
}

void cb_unlock_queue(void* handle) {
  static_cast<VkFe*>(handle)->queueMutex.unlock();
}

void cb_set_signal_semaphore(void* handle, VkSemaphore semaphore) {
  static_cast<VkFe*>(handle)->signalSem = semaphore;
}

// ---------------------------------------------------------------------------
// Gravação do command buffer (Copy 1:1 rápido ou Blit escalado)
// ---------------------------------------------------------------------------
void image_barrier(VkCommandBuffer cbuf, VkImage img, VkImageLayout oldL,
                   VkImageLayout newL, VkAccessFlags srcA, VkAccessFlags dstA,
                   VkPipelineStageFlags srcS, VkPipelineStageFlags dstS,
                   uint32_t srcQ = VK_QUEUE_FAMILY_IGNORED,
                   uint32_t dstQ = VK_QUEUE_FAMILY_IGNORED) {
  VkImageMemoryBarrier b{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
  b.srcAccessMask = srcA;
  b.dstAccessMask = dstA;
  b.oldLayout = oldL;
  b.newLayout = newL;
  b.srcQueueFamilyIndex = srcQ;
  b.dstQueueFamilyIndex = dstQ;
  b.image = img;
  b.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
  g_fn.cmdPipelineBarrier(cbuf, srcS, dstS, 0, 0, nullptr, 0, nullptr, 1, &b);
}

bool supports_linear_filter(VkFormat srcFmt) {
  if (srcFmt == VK_FORMAT_UNDEFINED) return false;
  if (srcFmt == g_fe.cachedSrcFmt) return g_fe.cachedSrcLinearOk;
  VkFormatProperties fp{};
  g_fn.formatProps(g_fe.gpu, srcFmt, &fp);
  const bool ok =
      (fp.optimalTilingFeatures &
       VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT) != 0 &&
      (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_SRC_BIT) != 0;
  g_fe.cachedSrcFmt = srcFmt;
  g_fe.cachedSrcLinearOk = ok;
  return ok;
}

bool record_present_cmd(VkCommandBuffer cmd, uint32_t idx, unsigned frameW,
                        unsigned frameH) {
  VkFe& fe = g_fe;
  VkImage dstImg = fe.swapImages[idx];
  VkImage srcImg = fe.curImage.create_info.image;
  if (srcImg == VK_NULL_HANDLE || dstImg == VK_NULL_HANDLE) return false;

  VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  if (g_fn.beginCommandBuffer(cmd, &bi) != VK_SUCCESS) return false;

  const VkImageLayout srcLayout = fe.curImage.image_layout;
  const uint32_t srcMip = fe.curImage.create_info.subresourceRange.baseMipLevel;
  const uint32_t srcLayer =
      fe.curImage.create_info.subresourceRange.baseArrayLayer;
  const uint32_t srcW = frameW > 0 ? frameW : fe.extent.width;
  const uint32_t srcH = frameH > 0 ? frameH : fe.extent.height;

  // dst: espera acquireSem em TRANSFER_BIT antes de gravar
  image_barrier(cmd, dstImg, VK_IMAGE_LAYOUT_UNDEFINED,
                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0,
                VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT);

  // src: adquire ownership (se preciso) + transição para layout de leitura
  const bool needOwn =
      fe.srcQueueFamily != VK_QUEUE_FAMILY_IGNORED &&
      fe.srcQueueFamily != fe.queueFamily;
  const VkImageLayout srcTransferLayout =
      (srcLayout == VK_IMAGE_LAYOUT_GENERAL ||
       srcLayout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
          ? srcLayout
          : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;

  if (needOwn) {
    // Em acquire barrier de ownership transfer, srcAccessMask deve ser 0
    image_barrier(cmd, srcImg, srcLayout, srcTransferLayout, 0,
                  VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                  VK_PIPELINE_STAGE_TRANSFER_BIT, fe.srcQueueFamily,
                  fe.queueFamily);
  } else {
    // Sempre sincroniza escritas anteriores (shader/renderpass/transfer) do core
    image_barrier(cmd, srcImg, srcLayout, srcTransferLayout,
                  VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
                  VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                  VK_PIPELINE_STAGE_TRANSFER_BIT);
  }

  // Fast path 1:1 via vkCmdCopyImage quando formato e tamanho casam exatamente
  const bool canDirectCopy =
      fe.curImage.create_info.format == fe.swapFormat &&
      srcW == fe.extent.width && srcH == fe.extent.height;
  if (canDirectCopy) {
    VkImageCopy region{};
    region.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, srcMip, srcLayer, 1};
    region.dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    region.extent = {srcW, srcH, 1};
    g_fn.cmdCopyImage(cmd, srcImg, srcTransferLayout, dstImg,
                      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
  } else {
    VkImageBlit blit{};
    blit.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, srcMip, srcLayer, 1};
    blit.srcOffsets[0] = {0, 0, 0};
    blit.srcOffsets[1] = {static_cast<int32_t>(srcW),
                          static_cast<int32_t>(srcH), 1};
    blit.dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    blit.dstOffsets[0] = {0, 0, 0};
    blit.dstOffsets[1] = {static_cast<int32_t>(fe.extent.width),
                          static_cast<int32_t>(fe.extent.height), 1};
    const VkFilter filter =
        supports_linear_filter(fe.curImage.create_info.format)
            ? VK_FILTER_LINEAR
            : VK_FILTER_NEAREST;
    g_fn.cmdBlitImage(cmd, srcImg, srcTransferLayout, dstImg,
                      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, filter);
  }

  // dst → PRESENT_SRC_KHR
  image_barrier(cmd, dstImg, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_ACCESS_TRANSFER_WRITE_BIT,
                0, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);

  // src → restaura layout e devolve ownership para a fila de origem; garante
  // que COLOR_ATTACHMENT_OUTPUT só rode no próximo frame após terminar a cópia.
  if (needOwn) {
    image_barrier(cmd, srcImg, srcTransferLayout, srcLayout,
                  VK_ACCESS_TRANSFER_READ_BIT, 0,
                  VK_PIPELINE_STAGE_TRANSFER_BIT,
                  VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, fe.queueFamily,
                  fe.srcQueueFamily);
  } else {
    image_barrier(cmd, srcImg, srcTransferLayout, srcLayout, 0, 0,
                  VK_PIPELINE_STAGE_TRANSFER_BIT,
                  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                      VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT |
                      VK_PIPELINE_STAGE_TRANSFER_BIT);
  }

  return g_fn.endCommandBuffer(cmd) == VK_SUCCESS;
}

// ---------------------------------------------------------------------------
// Ciclo de frame
// ---------------------------------------------------------------------------
void acquire_frame() {
  VkFe& fe = g_fe;
  fe.frameValid = false;
  fe.hasImage = false;
  fe.pendingCmdCount = 0;
  fe.pendingSemCount = 0;
  fe.signalSem = VK_NULL_HANDLE;
  if (!fe.active || fe.swapchain == VK_NULL_HANDLE || fe.slots.empty()) return;

  // Detecta mudança de tamanho do SurfaceTexture (setDefaultBufferSize pós-load)
  if (fe.window) {
    const int32_t w = ANativeWindow_getWidth(fe.window);
    const int32_t h = ANativeWindow_getHeight(fe.window);
    if (w > 0 && h > 0 &&
        (w != fe.winWidthAtCreate || h != fe.winHeightAtCreate)) {
      fe.needsRecreate = true;
      fe.suboptimalTried = false;
    }
  }

  if (fe.needsRecreate) {
    if (!recreate_swapchain()) return;
  }

  // Se o frame anterior não apresentou (boot, skip, frame nulo), reutiliza a
  // mesma imagem já adquirida sem drenar o pool do swapchain nem sobrescrever
  // o semáforo já sinalizado.
  if (fe.hasAcquired) {
    fe.syncIndex = fe.acquiredIdx;
    fe.frameValid = true;
    return;
  }

  uint32_t slot = fe.curSlot % static_cast<uint32_t>(fe.slots.size());
  wait_and_reset_slot_fence(slot);

  uint32_t idx = 0;
  VkResult res = g_fn.acquireNextImage(fe.device, fe.swapchain, 1000000000ull,
                                       fe.slots[slot].acquireSem,
                                       VK_NULL_HANDLE, &idx);
  if (res == VK_ERROR_OUT_OF_DATE_KHR ||
      (res == VK_SUBOPTIMAL_KHR && !fe.suboptimalTried)) {
    const bool wasSuboptimal = (res == VK_SUBOPTIMAL_KHR);
    if (!recreate_swapchain()) return;
    fe.suboptimalTried = wasSuboptimal;
    slot = 0;
    wait_and_reset_slot_fence(slot);
    res = g_fn.acquireNextImage(fe.device, fe.swapchain, 1000000000ull,
                                fe.slots[slot].acquireSem, VK_NULL_HANDLE, &idx);
  }
  if (res != VK_SUCCESS && res != VK_SUBOPTIMAL_KHR) return;
  if (res == VK_SUCCESS) fe.suboptimalTried = false;

  fe.hasAcquired = true;
  fe.acquiredIdx = idx;
  fe.acquiredSlot = slot;
  fe.curSlot = (slot + 1u) % static_cast<uint32_t>(fe.slots.size());
  fe.syncIndex = idx;
  fe.frameValid = true;
}

void present_frame(unsigned frameW, unsigned frameH) {
  VkFe& fe = g_fe;
  if (!fe.active || !fe.hasAcquired || !fe.frameValid || !fe.hasImage) return;

  const uint32_t idx = fe.acquiredIdx;
  const uint32_t slot = fe.acquiredSlot;
  if (idx >= fe.swapImages.size() || slot >= fe.slots.size()) return;
  FrameSlot& fs = fe.slots[slot];

  // Garante que o renderSems[idx] de apresentações antigas já completou
  if (fe.imageLastSlot[idx] >= 0 &&
      static_cast<uint32_t>(fe.imageLastSlot[idx]) != slot) {
    wait_image_in_flight(idx);
  }

  if (!record_present_cmd(fs.cmd, idx, frameW, frameH)) return;

  VkSemaphore waits[16];
  VkPipelineStageFlags waitStages[16];
  uint32_t waitCount = 0;
  waits[waitCount] = fs.acquireSem;
  waitStages[waitCount] = VK_PIPELINE_STAGE_TRANSFER_BIT;
  ++waitCount;

  const VkPipelineStageFlags coreSemStage =
      fe.pendingCmdCount > 0
          ? VK_PIPELINE_STAGE_ALL_COMMANDS_BIT
          : (VK_PIPELINE_STAGE_TRANSFER_BIT |
             VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT);
  for (uint32_t i = 0; i < fe.pendingSemCount && waitCount < 16; ++i) {
    waits[waitCount] = fe.pendingSems[i];
    waitStages[waitCount] = coreSemStage;
    ++waitCount;
  }

  VkSemaphore signals[16];
  uint32_t sigCount = 0;
  signals[sigCount++] = fe.renderSems[idx];
  if (fe.signalSem != VK_NULL_HANDLE) signals[sigCount++] = fe.signalSem;

  // Ordem correta: command buffers do core PRIMEIRO, blit do frontend DEPOIS
  VkCommandBuffer cmds[17];
  uint32_t cmdCount = 0;
  for (uint32_t i = 0; i < fe.pendingCmdCount && cmdCount < 16; ++i)
    cmds[cmdCount++] = fe.pendingCmds[i];
  cmds[cmdCount++] = fs.cmd;

  VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};
  si.waitSemaphoreCount = waitCount;
  si.pWaitSemaphores = waits;
  si.pWaitDstStageMask = waitStages;
  si.commandBufferCount = cmdCount;
  si.pCommandBuffers = cmds;
  si.signalSemaphoreCount = sigCount;
  si.pSignalSemaphores = signals;

  VkResult pres = VK_SUCCESS;
  bool submitOk = false;
  {
    // queueMutex protege VkQueue contra corrida com threads de render do core
    // (ex.: Worker Vulkan do PPSSPP via lock_queue/unlock_queue).
    std::lock_guard<std::mutex> lock(fe.queueMutex);
    VkResult subRes = g_fn.queueSubmit(fe.queue, 1, &si, fs.fence);
    if (subRes != VK_SUCCESS) {
      VK_LOGE("vkQueueSubmit falhou: %d", static_cast<int>(subRes));
      fe.hasAcquired = false;
      fe.frameValid = false;
      fe.hasImage = false;
      fe.needsRecreate = true;
      return;
    }
    submitOk = true;

    VkPresentInfoKHR pi{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    pi.waitSemaphoreCount = 1;
    pi.pWaitSemaphores = &fe.renderSems[idx];
    pi.swapchainCount = 1;
    pi.pSwapchains = &fe.swapchain;
    pi.pImageIndices = &idx;
    pres = g_fn.queuePresent(fe.presentQueue, &pi);
  }

  if (submitOk) {
    std::lock_guard<std::mutex> flock(fe.fenceMutex);
    fs.fenceSubmitted = true;
    fe.imageLastSlot[idx] = static_cast<int>(slot);
  }

  fe.hasAcquired = false;
  fe.frameValid = false;
  fe.signalSem = VK_NULL_HANDLE;
  fe.pendingSemCount = 0;
  fe.pendingCmdCount = 0;
  fe.hasImage = false;

  if (pres == VK_ERROR_OUT_OF_DATE_KHR) {
    fe.needsRecreate = true;
    fe.suboptimalTried = false;
  } else if (pres == VK_SUBOPTIMAL_KHR && !fe.suboptimalTried) {
    fe.needsRecreate = true;
    fe.suboptimalTried = true;
  }
}

// ---------------------------------------------------------------------------
// Wrappers v2 negotiation & fallback device default
// ---------------------------------------------------------------------------
std::vector<const char*> merge_extensions(const char* const* base,
                                            uint32_t baseCount,
                                            const std::vector<const char*>& req) {
  std::vector<const char*> merged;
  merged.reserve(baseCount + req.size());
  if (base) {
    for (uint32_t i = 0; i < baseCount; ++i) {
      if (base[i]) merged.push_back(base[i]);
    }
  }
  for (const char* r : req) {
    bool present = false;
    for (const char* m : merged) {
      if (std::strcmp(m, r) == 0) {
        present = true;
        break;
      }
    }
    if (!present) merged.push_back(r);
  }
  return merged;
}

VkInstance create_instance_wrapper_cb(void* opaque,
                                      const VkInstanceCreateInfo* createInfo) {
  auto* fe = static_cast<VkFe*>(opaque);
  if (!createInfo || !g_fn.createInstance) return VK_NULL_HANDLE;
  auto exts = merge_extensions(createInfo->ppEnabledExtensionNames,
                               createInfo->enabledExtensionCount,
                               fe->reqInstExts);
  VkInstanceCreateInfo ci = *createInfo;
  ci.enabledExtensionCount = static_cast<uint32_t>(exts.size());
  ci.ppEnabledExtensionNames = exts.data();
  for (const char* e : exts) {
    if (std::strcmp(e, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) == 0) {
      ci.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
      break;
    }
  }
  VkInstance inst = VK_NULL_HANDLE;
  if (g_fn.createInstance(&ci, nullptr, &inst) != VK_SUCCESS)
    return VK_NULL_HANDLE;
  return inst;
}

VkDevice create_device_wrapper_cb(VkPhysicalDevice gpu, void* opaque,
                                  const VkDeviceCreateInfo* createInfo) {
  auto* fe = static_cast<VkFe*>(opaque);
  if (!createInfo || !g_fn.createDevice) return VK_NULL_HANDLE;
  auto exts = merge_extensions(createInfo->ppEnabledExtensionNames,
                               createInfo->enabledExtensionCount,
                               fe->reqDevExts);
  VkDeviceCreateInfo ci = *createInfo;
  ci.enabledExtensionCount = static_cast<uint32_t>(exts.size());
  ci.ppEnabledExtensionNames = exts.data();
  VkDevice dev = VK_NULL_HANDLE;
  if (g_fn.createDevice(gpu, &ci, nullptr, &dev) != VK_SUCCESS)
    return VK_NULL_HANDLE;
  return dev;
}

bool create_default_device(retro_vulkan_context* ctx, VkPhysicalDevice gpu) {
  uint32_t qc = 0;
  g_fn.queueProps(gpu, &qc, nullptr);
  std::vector<VkQueueFamilyProperties> qp(qc);
  g_fn.queueProps(gpu, &qc, qp.data());

  uint32_t gfxFam = UINT32_MAX;
  uint32_t presFam = UINT32_MAX;
  for (uint32_t i = 0; i < qc; ++i) {
    const bool gc = (qp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) &&
                    (qp[i].queueFlags & VK_QUEUE_COMPUTE_BIT);
    VkBool32 present = VK_FALSE;
    if (g_fn.surfaceSupport(gpu, i, g_fe.surface, &present) != VK_SUCCESS)
      present = VK_FALSE;
    if (gc && present) {
      gfxFam = i;
      presFam = i;
      break;
    }
    if (gc && gfxFam == UINT32_MAX) gfxFam = i;
    if (present && presFam == UINT32_MAX) presFam = i;
  }
  if (gfxFam == UINT32_MAX || presFam == UINT32_MAX) return false;

  const float prio = 1.0f;
  VkDeviceQueueCreateInfo qcis[2]{};
  uint32_t qciCount = 1;
  qcis[0].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  qcis[0].queueFamilyIndex = gfxFam;
  qcis[0].queueCount = 1;
  qcis[0].pQueuePriorities = &prio;
  if (presFam != gfxFam) {
    qcis[1].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qcis[1].queueFamilyIndex = presFam;
    qcis[1].queueCount = 1;
    qcis[1].pQueuePriorities = &prio;
    qciCount = 2;
  }

  VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
  dci.queueCreateInfoCount = qciCount;
  dci.pQueueCreateInfos = qcis;
  dci.enabledExtensionCount = static_cast<uint32_t>(g_fe.reqDevExts.size());
  dci.ppEnabledExtensionNames = g_fe.reqDevExts.data();

  VkDevice dev = VK_NULL_HANDLE;
  if (g_fn.createDevice(gpu, &dci, nullptr, &dev) != VK_SUCCESS ||
      dev == VK_NULL_HANDLE)
    return false;

  ctx->gpu = gpu;
  ctx->device = dev;
  ctx->queue_family_index = gfxFam;
  g_fn.getDeviceQueue(dev, gfxFam, 0, &ctx->queue);
  ctx->presentation_queue_family_index = presFam;
  if (presFam == gfxFam) {
    ctx->presentation_queue = ctx->queue;
  } else {
    g_fn.getDeviceQueue(dev, presFam, 0, &ctx->presentation_queue);
  }
  return ctx->queue != VK_NULL_HANDLE;
}

// ---------------------------------------------------------------------------
// Shutdown e Init completo via negotiation interface
// ---------------------------------------------------------------------------
void shutdown_internal(bool force) {
  VkFe& fe = g_fe;
  if (!force && !fe.active && fe.instance == VK_NULL_HANDLE &&
      fe.device == VK_NULL_HANDLE)
    return;

  if (fe.device != VK_NULL_HANDLE) {
    if (g_fn.deviceWaitIdle) g_fn.deviceWaitIdle(fe.device);
    free_sync_objects();
    if (fe.swapchain != VK_NULL_HANDLE && g_fn.destroySwapchain) {
      g_fn.destroySwapchain(fe.device, fe.swapchain, nullptr);
      fe.swapchain = VK_NULL_HANDLE;
    }
    if (fe.cmdPool != VK_NULL_HANDLE && g_fn.destroyCommandPool) {
      g_fn.destroyCommandPool(fe.device, fe.cmdPool, nullptr);
      fe.cmdPool = VK_NULL_HANDLE;
    }
    if (g_fn.destroyDevice) g_fn.destroyDevice(fe.device, nullptr);
    fe.device = VK_NULL_HANDLE;
  } else {
    free_sync_objects();
  }

  if (fe.deviceFromNegotiation && fe.neg && fe.neg->destroy_device) {
    fe.neg->destroy_device();
  }
  fe.deviceFromNegotiation = false;

  if (fe.surface != VK_NULL_HANDLE && fe.instance != VK_NULL_HANDLE &&
      g_fn.destroySurface) {
    g_fn.destroySurface(fe.instance, fe.surface, nullptr);
  }
  fe.surface = VK_NULL_HANDLE;

  if (fe.instance != VK_NULL_HANDLE && g_fn.destroyInstance) {
    g_fn.destroyInstance(fe.instance, nullptr);
  }
  fe.instance = VK_NULL_HANDLE;
  clear_instance_and_device_fns();

  fe.active = false;
  fe.hasImage = false;
  fe.frameValid = false;
  fe.hasAcquired = false;
  fe.needsRecreate = false;
  fe.suboptimalTried = false;
  fe.gpu = VK_NULL_HANDLE;
  fe.queue = VK_NULL_HANDLE;
  fe.presentQueue = VK_NULL_HANDLE;
  fe.window = nullptr;
  fe.swapImages.clear();
  fe.reqInstExts.clear();
  fe.reqDevExts.clear();
  fe.neg = nullptr;
  fe.cachedSrcFmt = VK_FORMAT_UNDEFINED;
}

bool init_from_negotiation(
    const retro_hw_render_context_negotiation_interface_vulkan* neg,
    ANativeWindow* window) {
  VkFe& fe = g_fe;
  if (!neg || !window || !load_loader()) return false;

  shutdown_internal(true);
  fe.neg = neg;
  fe.window = window;

  uint32_t loaderApi = VK_API_VERSION_1_0;
  if (g_fn.enumInstVersion) g_fn.enumInstVersion(&loaderApi);

  VkApplicationInfo appInfo{};
  appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
  appInfo.pApplicationName = "loopgamer";
  appInfo.apiVersion =
      loaderApi >= VK_API_VERSION_1_1 ? VK_API_VERSION_1_1 : VK_API_VERSION_1_0;
  if (neg->get_application_info) {
    const VkApplicationInfo* coreApp = neg->get_application_info();
    if (coreApp) {
      appInfo = *coreApp;
      // Garante Vulkan 1.1 no loader Android quando suportado pelo driver
      if (loaderApi >= VK_API_VERSION_1_1 &&
          appInfo.apiVersion < VK_API_VERSION_1_1) {
        appInfo.apiVersion = VK_API_VERSION_1_1;
      }
    }
  }

  fe.reqInstExts = {VK_KHR_SURFACE_EXTENSION_NAME,
                    VK_KHR_ANDROID_SURFACE_EXTENSION_NAME};
  bool needPortability = false;
  if (g_fn.enumInstExt) {
    uint32_t extCount = 0;
    g_fn.enumInstExt(nullptr, &extCount, nullptr);
    std::vector<VkExtensionProperties> props(extCount);
    if (extCount > 0 &&
        g_fn.enumInstExt(nullptr, &extCount, props.data()) == VK_SUCCESS) {
      for (const auto& p : props) {
        if (std::strcmp(p.extensionName,
                        VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) == 0) {
          fe.reqInstExts.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
          needPortability = true;
          break;
        }
      }
    }
  }

  if (neg->interface_version >= 2 && neg->create_instance) {
    fe.instance = neg->create_instance(g_fn.gipa, &appInfo,
                                       create_instance_wrapper_cb, &fe);
  } else {
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &appInfo;
    ici.enabledExtensionCount = static_cast<uint32_t>(fe.reqInstExts.size());
    ici.ppEnabledExtensionNames = fe.reqInstExts.data();
    if (needPortability)
      ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    if (g_fn.createInstance(&ici, nullptr, &fe.instance) != VK_SUCCESS)
      fe.instance = VK_NULL_HANDLE;
  }

  if (fe.instance == VK_NULL_HANDLE) {
    VK_LOGE("Falha ao criar VkInstance");
    shutdown_internal(true);
    return false;
  }

  if (!load_instance_fns(fe.instance)) {
    shutdown_internal(true);
    return false;
  }

  VkAndroidSurfaceCreateInfoKHR sci{
      VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR};
  sci.window = window;
  VkResult surfRes =
      g_fn.createAndroidSurface(fe.instance, &sci, nullptr, &fe.surface);
  if (surfRes != VK_SUCCESS || fe.surface == VK_NULL_HANDLE) {
    VK_LOGE("vkCreateAndroidSurfaceKHR falhou: %d", static_cast<int>(surfRes));
    shutdown_internal(true);
    return false;
  }

  if (!pick_physical_device(&fe.gpu)) {
    VK_LOGE("Nenhuma GPU Vulkan compatível encontrada");
    shutdown_internal(true);
    return false;
  }

  fe.reqDevExts = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
  if (device_has_extension(fe.gpu, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME)) {
    fe.reqDevExts.push_back(VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME);
  }

  retro_vulkan_context ctx{};
  bool devOk = false;
  if (neg->interface_version >= 2 && neg->create_device2) {
    fe.deviceFromNegotiation = true;
    devOk = neg->create_device2(&ctx, fe.instance, fe.gpu, fe.surface,
                                g_fn.gipa, create_device_wrapper_cb, &fe);
    if (!devOk) {
      devOk = neg->create_device2(&ctx, fe.instance, VK_NULL_HANDLE, fe.surface,
                                  g_fn.gipa, create_device_wrapper_cb, &fe);
    }
  } else if (neg->create_device) {
    fe.deviceFromNegotiation = true;
    devOk = neg->create_device(
        &ctx, fe.instance, fe.gpu, fe.surface, g_fn.gipa,
        fe.reqDevExts.data(), static_cast<unsigned>(fe.reqDevExts.size()),
        nullptr, 0, nullptr);
    if (!devOk) {
      devOk = neg->create_device(
          &ctx, fe.instance, VK_NULL_HANDLE, fe.surface, g_fn.gipa,
          fe.reqDevExts.data(), static_cast<unsigned>(fe.reqDevExts.size()),
          nullptr, 0, nullptr);
    }
  } else {
    fe.deviceFromNegotiation = false;
    devOk = create_default_device(&ctx, fe.gpu);
  }

  if (!devOk || ctx.device == VK_NULL_HANDLE || ctx.queue == VK_NULL_HANDLE) {
    VK_LOGE("create_device Vulkan falhou");
    shutdown_internal(true);
    return false;
  }

  if (ctx.gpu != VK_NULL_HANDLE) fe.gpu = ctx.gpu;
  fe.device = ctx.device;
  fe.queue = ctx.queue;
  fe.queueFamily = ctx.queue_family_index;
  // Trata queue_family_index == 0 corretamente verificando o handle da fila
  fe.presentQueue = ctx.presentation_queue ? ctx.presentation_queue : ctx.queue;
  fe.presentQueueFamily = ctx.presentation_queue
                              ? ctx.presentation_queue_family_index
                              : ctx.queue_family_index;

  if (!load_device_fns()) {
    shutdown_internal(true);
    return false;
  }

  VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
  pi.queueFamilyIndex = fe.queueFamily;
  pi.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT |
             VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
  if (g_fn.createCommandPool(fe.device, &pi, nullptr, &fe.cmdPool) !=
      VK_SUCCESS) {
    VK_LOGE("vkCreateCommandPool falhou");
    shutdown_internal(true);
    return false;
  }

  if (!choose_swapchain_format() || !create_swapchain()) {
    VK_LOGE("Falha ao criar swapchain Vulkan");
    shutdown_internal(true);
    return false;
  }

  VkPhysicalDeviceProperties props{};
  g_fn.physProps(fe.gpu, &props);
  const uint32_t drvMajor = VK_API_VERSION_MAJOR(props.driverVersion);
  const uint32_t drvMinor = VK_API_VERSION_MINOR(props.driverVersion);
#if defined(LOOPGAMER_HAS_ADRENOTOOLS)
  const auto bcnType =
      adrenotools_get_bcn_type(drvMajor, drvMinor, props.vendorID);
  if (!g_customDriverName.empty() && !g_bcnPatchAttempted &&
      bcnType == ADRENOTOOLS_BCN_PATCH && g_fn.formatProps) {
    g_bcnPatchAttempted = true;
    const bool patched =
        adrenotools_patch_bcn(reinterpret_cast<void*>(g_fn.formatProps));
    VK_LOGI("BCeNabler patch Adreno %u.%u: %s", drvMajor, drvMinor,
            patched ? "OK" : "falhou");
  }
#endif
  VK_LOGI("Vulkan ativo na GPU: %s (vendor=0x%04x dev=0x%04x drv=%u.%u api=%u.%u q=%u pq=%u)",
          props.deviceName, props.vendorID, props.deviceID, drvMajor, drvMinor,
          VK_API_VERSION_MAJOR(props.apiVersion),
          VK_API_VERSION_MINOR(props.apiVersion),
          fe.queueFamily, fe.presentQueueFamily);

  fe.iface.interface_type = 0;
  fe.iface.interface_version = 5;
  fe.iface.handle = &fe;
  fe.iface.instance = fe.instance;
  fe.iface.gpu = fe.gpu;
  fe.iface.device = fe.device;
  fe.iface.get_device_proc_addr = g_fn.gdpa;
  fe.iface.get_instance_proc_addr = g_fn.gipa;
  fe.iface.queue = fe.queue;
  fe.iface.queue_index = fe.queueFamily;
  fe.iface.set_image = cb_set_image;
  fe.iface.get_sync_index = cb_get_sync_index;
  fe.iface.get_sync_index_mask = cb_get_sync_index_mask;
  fe.iface.set_command_buffers = cb_set_command_buffers;
  fe.iface.wait_sync_index = cb_wait_sync_index;
  fe.iface.lock_queue = cb_lock_queue;
  fe.iface.unlock_queue = cb_unlock_queue;
  fe.iface.set_signal_semaphore = cb_set_signal_semaphore;

  fe.active = true;
  return true;
}

} // namespace

// ---------------------------------------------------------------------------
// API pública (chamada pelo libretro_jni.cpp)
// ---------------------------------------------------------------------------
namespace vkfe {

void set_custom_driver(const char* hook_lib_dir,
                       const char* tmp_dir,
                       const char* custom_driver_dir,
                       const char* custom_driver_name,
                       bool adreno_turbo) {
  const std::string nextHook = ensure_trailing_slash(hook_lib_dir);
  const std::string nextTmp = ensure_trailing_slash(tmp_dir);
  const std::string nextDir = ensure_trailing_slash(custom_driver_dir);
  const std::string nextName = custom_driver_name ? custom_driver_name : "";
  const bool changed =
      (nextDir != g_customDriverDir || nextName != g_customDriverName);
  g_hookLibDir = nextHook;
  g_tmpDir = nextTmp;
  g_customDriverDir = nextDir;
  g_customDriverName = nextName;
  g_adrenoTurbo = adreno_turbo;
  if (changed && !g_fe.active) {
    g_fe.probed = false;
    g_fe.probeOk = false;
  }
}

void set_freedreno_preset(const char* preset) {
  const std::string next = preset ? preset : "";
  if (next != g_freedrenoPreset) {
    g_freedrenoPreset = next;
    apply_freedreno_env();
    if (!g_fe.active) {
      g_fe.probed = false;
      g_fe.probeOk = false;
    }
  }
}

void set_backend(int mode) {
  g_fe.wanted = (mode == 2);
  if (g_fe.wanted) do_probe();
}

void set_vsync(bool enabled) {
  const bool prev = g_fe.vsync.exchange(enabled, std::memory_order_relaxed);
  if (g_fe.active && prev != enabled) {
    g_fe.needsRecreate = true;
    g_fe.suboptimalTried = false;
  }
}

bool vulkan_requested() { return g_fe.wanted && g_fe.probeOk; }
bool is_active() { return g_fe.active; }

bool on_negotiation_iface(const void* iface, ANativeWindow* window) {
  auto* neg =
      static_cast<const retro_hw_render_context_negotiation_interface_vulkan*>(
          iface);
  if (!neg || neg->interface_type != 0 || !vulkan_requested()) return false;
  return init_from_negotiation(neg, window);
}

bool get_render_interface(void** out) {
  if (!g_fe.active) return false;
  *out = &g_fe.iface;
  return true;
}

void context_reset() {}
void context_destroy() {}
void begin_frame() { acquire_frame(); }
void present(unsigned w, unsigned h) { present_frame(w, h); }
void shutdown_public() { shutdown_internal(false); }

} // namespace vkfe
