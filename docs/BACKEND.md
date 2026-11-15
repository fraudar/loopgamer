# Backend — LoopGamer (nativo Android)

Camada nativa do emulador: Kotlin (`MainActivity`) + C++ JNI (`libretro_jni.cpp`)
+ frontend Vulkan próprio (`libretro_vulkan.cpp`). Este documento descreve a
arquitetura, o contrato libretro implementado e as armadilhas conhecidas.

## Arquivos

| Arquivo | Papel |
|---|---|
| `android/app/src/main/kotlin/org/loopgamer/emulator/MainActivity.kt` | Activity Flutter; dono do `SurfaceTexture`/`Surface`, `AudioTrack`, thread de emulação e loop de pacing. |
| `android/app/src/main/cpp/libretro_jni.cpp` | JNI: carrega o core `.so` via `dlopen`, registra callbacks libretro, renderer EGL/GLES, fallback CPU, HW render GL, opções de core, save states. |
| `android/app/src/main/cpp/libretro_vulkan.cpp` | Frontend Vulkan "thin": instance/device/queue via negotiation interface do core + swapchain + blit da imagem do core para a tela. |
| `android/app/src/main/cpp/CMakeLists.txt` | Build do `liblibretro_jni.so` (ambos os .cpp). Flags: `-O3 -ffast-math -flto -DNDEBUG`. Linka `android log EGL GLESv2 dl` (NÃO linka `vulkan` — é dlopen). |

## Fluxo de uma sessão

1. Flutter chama `startLibretroSession` no MethodChannel
   `org.loopgamer.libretro/methods` com: `corePath`, `romPath`, `systemDir`,
   `savesDir`, `resolutionScale`, `frameSkip`, `vsyncEnabled`, `audioEnabled`,
   `masterVolume`, `softwareRendering` (bool, legado), `gpuBackend`
   (`"vulkan"|"opengl"|"software"`), `screenScale`, `frameDup`, `coreOptions`
   (`"k=v;k=v"`), `platform`.
2. Kotlin faz `nativeSetGpuBackend(mode)` (0=GL, 1=software, 2=Vulkan) e chama
   `nativeLoadCoreAndRom(...)` na thread principal.
3. JNI: `dlopen` do core, resolve símbolos `retro_*`, `ANativeWindow_fromSurface`,
   registra callbacks, `retro_init()` + `retro_load_game()`.
4. `nativeGetFrameWidth/Height` → Kotlin faz `st.setDefaultBufferSize(base*screenScale)`
   (limite 4096) — é isso que define o extent do swapchain Vulkan / framebuffer EGL.
5. `startLibretroLoop` cria thread `LibretroTurboThread` (MAX_PRIORITY,
   THREAD_PRIORITY_URGENT_DISPLAY) que itera: `nativeStepFrame()` →
   `nativeDrainAudioBuffer()` → pacing por `LockSupport.parkNanos`.
6. A cada ~750ms emite evento `{"fps","frameTimeMs","width","height","coreName"}`
   pelo EventChannel `org.loopgamer.libretro/events`.
7. `stopLibretroSession` → `nativeUnloadCore()` → `retro_unload_game`,
   `retro_deinit`, `dlclose`, destrói EGL/Vulkan, libera `ANativeWindow`.

## JNI exports (`libretro_jni.cpp`)

`nativeLoadCoreAndRom`, `nativeStepFrame`, `nativeUnloadCore`,
`nativeSetFrameSkip`, `nativeSetCoreOptions`, `nativeSetGpuBackend`,
`nativeSetRendererMode` (legado bool), `nativeSetFrameDup`, `nativeSetVsync`,
`nativeSetTurboConfig`, `nativeDrainAudioBuffer`, `nativeGetSampleRate`,
`nativeGetTargetFps`, `nativeUpdateInput`, `nativeSaveState`, `nativeLoadState`,
`nativeGetFrameWidth`, `nativeGetFrameHeight`.

## Pipeline de vídeo (3 caminhos)

Ordem de decisão em `video_refresh_callback` para frames HW
(`data == (void*)~0` = `RETRO_HW_FRAME_BUFFER_VALID`):

- **Vulkan ativo** (`vkfe::is_active()`): `vkfe::present(w,h)` — blit da imagem
  do core para o swapchain + `vkQueuePresentKHR`.
- **GL ativo**: `present_hw_frame()` — blit do FBO do core para a janela EGL.
- **Software**: `present_sw_frame_gl()` (textura + blit) ou
  `present_sw_frame_cpu()` (`ANativeWindow_lock`, fallback se EGL falhar).

`nativeStepFrame` chama `vkfe::begin_frame()` (adquire swapchain) antes de
`retro_run()` quando Vulkan está ativo; caso contrário `gl_ensure_current()`
quando há HW GL. Frame dup (`data == nullptr`) é ignorado nos dois HW paths.

### Estado EGL/GLES (`g_egl*`)

Criado lazy na thread de emulação via `gl_ensure_current()`; pode ser criado na
thread principal durante `retro_load_game` (context_reset do core) e é liberado
com `gl_release_context()` ao fim do load. FBO do core (`g_hwFbo`) com
color texture + depth/stencil renderbuffer, redimensionado por
`hw_ensure_fbo()` conforme `max_width/max_height` do `retro_system_av_info`.
`get_proc_address` do core resolve via `eglGetProcAddress`.

### Vulkan (`libretro_vulkan.cpp`, namespace `vkfe`)

Interface implementada: `retro_hw_render_interface_vulkan` **v5** +
`retro_hw_render_context_negotiation_interface_vulkan` **v2**
(definições duplicadas localmente — não depende de header do RetroArch).

Sequência de init (tudo dentro de `retro_load_game`, thread principal):

1. Core chama `SET_HW_RENDER` com `context_type = RETRO_HW_CONTEXT_VULKAN` →
   aceito só se `vkfe::vulkan_requested()` (usuário escolheu Vulkan + probe OK).
   `context_reset` do core é **guardado** (`g_hwCoreReset`), não chamado.
2. Core chama `SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE` com a struct que
   contém `create_device`/`destroy_device`/`get_application_info` →
   `vkfe::on_negotiation_iface()` faz init completo:
   `vkCreateInstance` (surface + android_surface + portability_enumeration se
   disponível) → `vkCreateAndroidSurfaceKHR` → pick de `VkPhysicalDevice`
   (melhor tipo com fila GRAPHICS+COMPUTE+present) → `neg->create_device()`
   (o **core** cria o VkDevice com as extensões que pedimos: swapchain +
   portability_subset se suportado) → command pool + swapchain FIFO.
3. Sucesso → `g_hwCoreReset()` → o core chama `GET_HW_RENDER_INTERFACE` →
   devolvemos `&g_fe.iface` (version 5) já preenchido.

Por frame (thread de emulação): `vkfe::begin_frame()` →
`vkAcquireNextImageKHR` (timeout 1s, semaphore único `acquireSem`) →
`retro_run()` (core chama `set_image`/`get_sync_index`/`set_command_buffers`/
`set_signal_semaphore`) → `video_refresh(HW_FRAME_BUFFER_VALID,w,h)` →
`vkfe::present(w,h)`: grava command buffer (barriers dst UNDEFINED→
TRANSFER_DST→PRESENT_SRC, src layout→TRANSFER_SRC→layout original, blit
`VK_FILTER_LINEAR` com extent `w×h` informado pelo core, ownership transfer se
`src_queue_family` ≠ fila de submit) → `vkQueueSubmit` (wait:
`acquireSem` + semáforos do core; signal: `renderSems[idx]` + `signalSem`;
fence por imagem) → `vkQueuePresentKHR`.

`libvulkan.so` é carregado via `dlopen` — **não há link dependency**; probe
falho → Vulkan indisponível → fallback GL/software automático.

### Environment commands tratados

| cmd | significado |
|---|---|
| `SET_PIXEL_FORMAT` | aceita RGB565/XRGB8888 |
| `GET_SYSTEM_DIRECTORY` / `GET_SAVE_DIRECTORY` | paths passados pelo JNI |
| `GET_CAN_DUPE` | true |
| `SET_HW_RENDER` | GL (SEmpre, salvo software) + Vulkan (se pedido e probe OK) |
| `GET_VARIABLE`/`SET_VARIABLES`/`GET_VARIABLE_UPDATE` | core vars: overrides do usuário (`g_coreVars`, string `k=v;k=v`) têm prioridade; defaults hardcoded estilo PPSSPP para `ppsspp_*` |
| `GET_PREFERRED_HW_RENDER` (56) | VULKAN se selecionado, senão OPENGLES3; false se software |
| `GET_HW_RENDER_INTERFACE` (41\|EXP) | devolve `retro_hw_render_interface_vulkan` v5 |
| `SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE` (43\|EXP) | dispara init Vulkan + `g_hwCoreReset()` |
| `GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT` (73\|EXP) | declara suporte a negotiation Vulkan v2 |
| `SET_SERIALIZATION_QUIRKS` (44), `SET_HW_SHARED_CONTEXT` (44\|EXP), `GET_AUDIO_VIDEO_ENABLE`, `GET_CORE_OPTIONS_VERSION`, `GET_INPUT_BITMASKS`, JIT capable | stubs/ack |

> **Atenção**: os campos "Set by frontend" de `retro_hw_render_callback`
> (`get_proc_address`, `get_current_framebuffer`, `depth`, `stencil`,
> `bottom_left_origin`, `version_*`, `cache_context`, `debug_context`) DEVEM
> ser escritos no `cb` do core — o core os lê depois. Versões antigas deste
> código só copiavam para `g_hwCb` (bug corrigido).

## Áudio

Ring buffer próprio `g_audio_ring` (32768 samples) + mutex; `nativeDrainAudioBuffer`
drena para `ShortArray` do Kotlin que escreve no `AudioTrack` (WRITE_NON_BLOCKING).
`nativeSetTurboConfig` = turbo buttons (máscara + half-period). Fast forward é
multiplicador de FPS no pacing Kotlin (`setFastForward`), não no core.

## Build

```bash
./build-apk.sh   # toolchain portátil em ~/.local/share/loopgamer-toolchain
```

Compilação rápida do C++ isolada (sem Gradle):

```bash
NDK=/opt/android-ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
$NDK/aarch64-linux-android26-clang++ -std=c++17 -O2 -fPIC -c \
  android/app/src/main/cpp/libretro_vulkan.cpp -o /tmp/vk.o
$NDK/aarch64-linux-android26-clang++ -std=c++17 -O2 -fPIC -c \
  android/app/src/main/cpp/libretro_jni.cpp -o /tmp/jni.o
```

## Estado / limitações conhecidas

- **Vulkan não foi testado em device** — compilação verificada, runtime pendente.
  Suspeitos se falhar: `create_device` do PPSSPP, extent do swapchain vs
  `setDefaultBufferSize` (recriado em OUT_OF_DATE), semáforos/fences.
- `minImageCount` do swapchain usa `caps.minImageCount` (típico 2–3).
- Frame dup 60Hz não é implementado no path Vulkan (refresh nulo é ignorado).
- `g_hwCb` é cópia só para referência; os callbacks efetivos vivem em `cb`/iface.
- Core options `ppsspp_*` são defaults hardcoded em `get_core_variable`;
  overrides do usuário (`g_coreVars`) têm prioridade — string `k=v;k=v`.
