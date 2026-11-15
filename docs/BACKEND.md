# Backend — LoopGamer (nativo Android)

Camada nativa do emulador: Kotlin (`MainActivity` + `EmulationForegroundService`) + C++ JNI (`libretro_jni.cpp`) + frontend Vulkan próprio (`libretro_vulkan.cpp`). Este documento descreve a arquitetura, o contrato libretro implementado, regras de build/segurança e limitações conhecidas.

## Arquivos

| Arquivo | Papel |
|---|---|
| `android/app/src/main/kotlin/org/loopgamer/emulator/MainActivity.kt` | Activity Flutter; dono do `SurfaceTexture`/`Surface`, `AudioTrack`, executor `LibretroNativeIO`, ciclo de vida, mapeamento de controle físico e thread `LibretroTurboThread`. |
| `android/app/src/main/kotlin/org/loopgamer/emulator/EmulationForegroundService.kt` | Foreground Service `mediaPlayback` (ID `4101`, canal `loopgamer_emulation_playback`) ativo durante sessões de emulação (Android 14+ compatível). |
| `android/app/src/main/cpp/libretro_jni.cpp` | JNI: `dlopen` do core `.so`, mutex `g_state_mutex`, callbacks libretro, renderer EGL/GLES, fallback CPU com checagem de stride/bounds/`buffer.format`, HW render GL via FBO, opções de core e save states atômicos (`.tmp` + `rename`). |
| `android/app/src/main/cpp/libretro_vulkan.cpp` | Frontend Vulkan "thin": loader via `dlopen` ou `adrenotools`, instance/device/queue via negotiation interface do core, swapchain e blit da imagem do core para a tela com recuperação de superfície/fila. |
| `android/app/src/main/cpp/CMakeLists.txt` | Build do `liblibretro_jni.so`. Em `arm64-v8a` inclui `third_party/libadrenotools` (`LOOPGAMER_HAS_ADRENOTOOLS=1`) e linka `adrenotools`. Flags `-O3 -ffast-math -fomit-frame-pointer -funroll-loops -flto -DNDEBUG` restritas ao target `libretro_jni` (sem propagar para `adrenotools`). Linka `android EGL GLESv2 log dl` (`libvulkan.so` é `dlopen`). |
| `android/app/src/main/AndroidManifest.xml` | Permissões (`INTERNET`, `VIBRATE`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `POST_NOTIFICATIONS`), declaração do `EmulationForegroundService` e `networkSecurityConfig`. |
| `android/app/src/main/res/xml/network_security_config.xml` | Bloqueia HTTP em texto claro globalmente (`cleartextTrafficPermitted="false"`, HTTPS com CAs do sistema) e libera HTTP apenas para domínios/hosts locais/LAN (`localhost`, `127.0.0.1`, `10.0.2.2`, `local`, `lan`, `home.arpa`, `internal`, `intranet`, `romm`, `romm.local`). |
| `android/app/build.gradle` e `android/app/proguard-rules.pro` | Config Gradle (`compileSdk 35`, `targetSdk 35`, `minSdk 26`, `ndkVersion "27.0.12077973"`, `versionCode 240`, `versionName "2.4.0"`); release com `--split-per-abi` (`arm64-v8a`), R8 (`minifyEnabled true`, `shrinkResources true`) e regras keep para JNI/plugins Flutter/Manifest. |

## Fluxo de uma sessão

1. Flutter chama `startLibretroSession` no `MethodChannel` `org.loopgamer.libretro/methods` com:
   `corePath`, `romPath`, `systemDir`, `savesDir`, `resolutionScale` (usado no Dart para `ppsspp.ini`/opções), `frameSkip`, `vsyncEnabled`, `audioEnabled`, `masterVolume`, `softwareRendering` (bool legado), `gpuBackend` (`"vulkan"|"opengl"|"software"`), `screenScale`, `frameDup`, `coreOptions` (`"k=v;k=v"`), `platform`, `customDriverDir`, `customDriverName`, `adrenoTurbo`, `freedrenoPreset`.
2. Na UI thread, Kotlin cria `SurfaceTexture`/`Surface`, calcula `setDefaultBufferSize` inicial (clamped `64..4096`, mínimo `640x480` para PS1) e invalida sessões anteriores via `sessionToken` + `isRunning.set(false)`.
3. No executor serializado `LibretroNativeIO`, Kotlin executa `stopLibretroLoopInternal()`, aplica driver Vulkan customizado (`nativeSetCustomVulkanDriver` + `nativeSetFreedrenoPreset`), backend (`nativeSetGpuBackend`), flags e `coreOptions`, e chama `nativeLoadCoreAndRom(...)`.
4. No JNI: `unload_core_locked()` garante limpeza de qualquer core anterior, valida `ANativeWindow_fromSurface`, carrega o `.so` via `dlopen`, resolve símbolos `retro_*`, registra callbacks e executa `retro_init()` + `retro_load_game()`.
5. Se carregou: Kotlin ajusta `setDefaultBufferSize(base * screenScale)` para o tamanho reportado por `nativeGetFrameWidth/Height`, inicializa `AudioTrack`, sobe `LibretroTurboThread` (`MAX_PRIORITY`, `THREAD_PRIORITY_URGENT_DISPLAY`), inicia `EmulationForegroundService` (`mediaPlayback`) e devolve `entry.id()` na `mainHandler`. Em falha ou cancelamento, `stopLibretroLoopInternal()` libera core/áudio/superfícies/FGS e retorna erro ao Flutter.
6. Loop de emulação (`LibretroTurboThread`): `nativeStepFrame()` → drena `nativeDrainAudioBuffer` → escreve no `AudioTrack` (`WRITE_NON_BLOCKING`) → pacing via `LockSupport.parkNanos`. Ao sair do loop, `finally` chama `nativeReleaseRenderThreadContext()`.
7. A cada ~750ms emite evento `{"fps","frameTimeMs","width","height","coreName"}` no `EventChannel` `org.loopgamer.libretro/events`.
8. Ciclo de vida: `onPause`/`onStop` zeram máscaras de entrada (`touch`, hardware botões e eixos) e pausam loop/áudio; `onResume` sincroniza retomada e notificação do FGS.
9. `stopLibretroSession` (e `onDestroy`) incrementam `sessionToken`, param FGS e enfileiram `stopLibretroLoopInternal()` no `LibretroNativeIO` (descarregando core/áudio/superfícies incondicionalmente mesmo se o loop nunca iniciou).

## JNI exports (`libretro_jni.cpp`)

`nativeLoadCoreAndRom`, `nativeStepFrame`, `nativeReleaseRenderThreadContext`, `nativeUnloadCore`, `nativeSetFrameSkip`, `nativeSetCoreOptions`, `nativeSetGpuBackend`, `nativeSetRendererMode` (legado bool), `nativeSetCustomVulkanDriver`, `nativeSetFreedrenoPreset`, `nativeSetFrameDup`, `nativeSetVsync`, `nativeSetTurboConfig`, `nativeDrainAudioBuffer`, `nativeGetSampleRate`, `nativeGetTargetFps`, `nativeUpdateInput`, `nativeSaveState`, `nativeLoadState`, `nativeGetFrameWidth`, `nativeGetFrameHeight`.

## Pipeline de vídeo (3 caminhos)

Ordem de decisão em `video_refresh_callback` para frames HW (`data == (void*)~0` = `RETRO_HW_FRAME_BUFFER_VALID`):

- **Vulkan ativo** (`vkfe::is_active()`): `vkfe::present(w,h)` — blit da imagem do core para o swapchain + `vkQueuePresentKHR`.
- **GL ativo**: `present_hw_frame()` — blit do FBO do core para a janela EGL.
- **Software**: `present_sw_frame_gl()` (textura + blit) ou `present_sw_frame_cpu()` (`ANativeWindow_lock` com validação de `pitch`, dimensões e `buffer.format`, fallback se EGL falhar).

`nativeStepFrame` chama `vkfe::begin_frame()` (adquire swapchain) antes de `retro_run()` quando Vulkan está ativo e pula `retro_run()` se o acquire falhar; caso contrário chama `gl_ensure_current()` quando há HW GL. Em frame duplicado (`data == nullptr`), Vulkan consome/sinaliza `signalSem` uma única vez via `vkfe::consume_signal_semaphore()`.

### Estado EGL/GLES (`g_egl*`)

Criado lazy na thread de emulação via `gl_ensure_current()`; pode ser criado no executor `LibretroNativeIO` durante `retro_load_game` (`context_reset` do core) e é liberado com `gl_release_context()` ao fim do load (e `gl_shutdown()` fecha também o handle `g_libGles3`). Inclui cooldown/retry em falhas transitórias de `eglInitialize`/`eglCreateContext`. FBO do core (`g_hwFbo`) possui color texture + depth/stencil renderbuffer, redimensionado por `hw_ensure_fbo()`. `get_proc_address` resolve via `eglGetProcAddress`.

### Vulkan (`libretro_vulkan.cpp`, namespace `vkfe`)

Interface implementada: `retro_hw_render_interface_vulkan` **v5** + `retro_hw_render_context_negotiation_interface_vulkan` **v2** (definições locais, sem dependência de headers do RetroArch).

Sequência de init (em `retro_load_game`, thread `LibretroNativeIO`):

1. Core chama `SET_HW_RENDER` (`RETRO_HW_CONTEXT_VULKAN`) → aceito se `vkfe::vulkan_requested()` e probe bem-sucedido (falha transitória no probe não fica permanentemente cacheada). `context_reset` do core é **guardado** em `g_hwCoreReset`.
2. Core chama `SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE` → `vkfe::on_negotiation_iface()` executa: `load_loader()` (`adrenotools_open_libvulkan` quando há driver custom em `arm64-v8a` + validação de `vkGetInstanceProcAddr`/`vkCreateInstance`/`vkDestroyInstance` antes de cachear `g_loadedDriverKey`, ou `dlopen("libvulkan.so")`) → `vkCreateInstance` → `vkCreateAndroidSurfaceKHR` → pick de `VkPhysicalDevice` (GRAPHICS+COMPUTE+present) → `neg->create_device()` → command pool + swapchain FIFO + eventual `adrenotools_patch_bcn`.
3. Sucesso → `g_hwCoreReset()` → core chama `GET_HW_RENDER_INTERFACE` e recebe `&g_fe.iface` (v5).

Por frame (thread `LibretroTurboThread`): `vkfe::begin_frame()` → `vkAcquireNextImageKHR` (timeout 1s) → `retro_run()` → `video_refresh` → `vkfe::present(w,h)` → barriers + `vkCmdBlitImage` (`VK_FILTER_LINEAR`) + ownership transfer se `src_queue_family != fe.queueFamily` → `vkQueueSubmit` → `vkQueuePresentKHR`.

Proteções implementadas no backend Vulkan:
- Semáforos e command buffers enviados pelo core ficam em `std::vector` dinâmicos (sem truncamento em 8/16).
- `queueMutex` é `std::recursive_mutex`; `free_sync_objects()` adquire `fenceMutex`.
- `consume_signal_semaphore()` garante consumo/sinalização única de `signalSem`.
- Tratamento explícito de erros em `vkQueueSubmit` e recuperação em `VK_ERROR_OUT_OF_DATE_KHR` / `VK_ERROR_SURFACE_LOST_KHR` (`recreate_surface_if_lost()`) / `VK_ERROR_DEVICE_LOST`.

### Environment commands tratados

| cmd | significado |
|---|---|
| `SET_PIXEL_FORMAT` | aceita RGB565 / XRGB8888 / 0RGB1555 (registrado sob `g_state_mutex`) |
| `GET_SYSTEM_DIRECTORY` / `GET_SAVE_DIRECTORY` | paths passados pelo JNI |
| `GET_CAN_DUPE` | `true` |
| `SET_HW_RENDER` | GL (sempre, salvo software) + Vulkan (se escolhido e probe OK) |
| `GET_VARIABLE` / `SET_VARIABLES` / `GET_VARIABLE_UPDATE` | core vars: overrides de `g_coreVars` (`k=v;k=v`) têm prioridade; defaults `ppsspp_*` no fallback; strings armazenadas em `g_returnedVarStrings` sob `g_state_mutex` |
| `GET_PREFERRED_HW_RENDER` (56) | `VULKAN` se selecionado, senão `OPENGLES3`; `false` se software |
| `GET_HW_RENDER_INTERFACE` (41\|EXP) | devolve `retro_hw_render_interface_vulkan` v5 |
| `SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE` (43\|EXP) | dispara init Vulkan + `g_hwCoreReset()` |
| `GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT` (73\|EXP) | declara suporte a negotiation Vulkan v2 |
| `SET_SERIALIZATION_QUIRKS`, `SET_HW_SHARED_CONTEXT`, `GET_AUDIO_VIDEO_ENABLE`, `GET_CORE_OPTIONS_VERSION`, `GET_INPUT_BITMASKS`, `GET_JIT_CAPABLE`, `GET_FASTFORWARDING` | stubs / ack coerentes |

> **Atenção**: os campos "Set by frontend" de `retro_hw_render_callback` (`get_proc_address`, `get_current_framebuffer`, `depth`, `stencil`, `bottom_left_origin`, `version_*`, `cache_context`, `debug_context`) DEVEM ser escritos no `cb` passado pelo core — `g_hwCb` é apenas referência local.

## Áudio, Entrada e Save States

- **Áudio**: ring buffer `g_audio_ring` (`kAudioRingCapacity = 32768` samples) protegido por mutex no JNI. No Kotlin, `AudioTrack` (`MODE_STREAM`, PCM 16-bit estéreo) valida `getMinBufferSize` (fallback se `<= 0`) com margem de 4x (`>= 16384` bytes alinhado em 4 bytes), escrita `WRITE_NON_BLOCKING` com tratamento de `ERROR_DEAD_OBJECT` e park breve (`350µs`) em escrita parcial/zero quando não em fast-forward.
- **Entrada combinada**: `MainActivity.kt` mescla toque (`touchJoypadMask`) + botões/eixos de controle físico (`onKeyDown`, `onKeyUp`, `onGenericMotionEvent`), remapeando `L2`/`R2` para `L`/`R` em `SINGLE_TRIGGER_PLATFORMS` (`psp`, `gba`, `snes`, `nds`, `gbc`, `gb`, `nes`, `gamegear`, `mastersystem`, `md`, `pce`). Eventos de gamepad físico notificam `{"event": "hardwareGamepadActive"}`.
- **Save states**: `nativeSaveState` / `nativeLoadState` executam no executor `LibretroNativeIO` em `MainActivity.kt` (sem bloquear UI thread); em C++, `nativeSaveState` grava em `<path>.tmp` com `fflush` + `rename` atômico e retorna o booleano real da serialização (`retro_serialize` / `retro_unserialize`).

## Build

```bash
./build-apk.sh   # toolchain portátil em ~/.local/share/loopgamer-toolchain
```

O script executa `flutter build apk --release --target-platform android-arm64 --split-per-abi` (com `--dart-define` opcionais para IGDB/SGDB) e copia `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` para `loopgamer-release.apk`.

Compilação C++ isolada (sem Gradle):

```bash
NDK=/opt/android-ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
$NDK/aarch64-linux-android26-clang++ -std=c++17 -O2 -fPIC -c \
  android/app/src/main/cpp/libretro_jni.cpp -o /tmp/jni.o
$NDK/aarch64-linux-android26-clang++ -std=c++17 -O2 -fPIC \
  -DLOOPGAMER_HAS_ADRENOTOOLS=1 \
  -Iandroid/app/src/main/cpp/third_party/libadrenotools/include -c \
  android/app/src/main/cpp/libretro_vulkan.cpp -o /tmp/vk.o
```

## Estado / limitações conhecidas

- **Vulkan e drivers Turnip não foram testados em device físico** — compilação e validações estáticas passaram; runtime depende de teste em aparelho Android ARM64.
- `minImageCount` do swapchain usa `max(caps.minImageCount + 1, 3)` limitado por `caps.maxImageCount` (quando `> 0`), respeitando mínimo `caps.minImageCount` e mínimo `2` (quando suportado).
- Frame dup 60Hz no path Vulkan apenas sinaliza/consome `signalSem` em frames `nullptr`, sem re-blit no swapchain.
- `network_security_config.xml`: IPs numéricos arbitrários na LAN (ex.: `192.168.x.x`) não são cobertos por wildcards no parser XML do Android — para RomM em HTTP local use `.local`/hostname listado ou HTTPS.
- `g_state_mutex` protege variáveis de estado e `g_returnedVarStrings` mantém ponteiros de `GET_VARIABLE` válidos até o unload do core.
