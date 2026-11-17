# LoopGamer — contexto para agentes de IA

Emulador libretro Android em Flutter. Antes de alterar código, leia [BACKEND.md](BACKEND.md) (nativo: Kotlin + JNI + C++/Vulkan/EGL/AdrenoTools) e [FRONTEND.md](FRONTEND.md) (Flutter/Dart).

## Build e verificação

```bash
flutter analyze     # deve sair "No issues found!" (regras estritas em analysis_options.yaml)
flutter test        # executa toda a suíte (88 testes: widget, core fixes, regressões e detecção de plataforma)
./build-apk.sh      # gera loopgamer-release.apk (arm64-v8a + R8 minify/shrink, toolchain portátil)
```

Compilação C++ isolada rápida (pega erros de sintaxe/ABI sem Gradle):

```bash
NDK=/opt/android-ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
$NDK/aarch64-linux-android26-clang++ -std=c++17 -O2 -fPIC -c \
  android/app/src/main/cpp/libretro_jni.cpp -o /tmp/jni.o
$NDK/aarch64-linux-android26-clang++ -std=c++17 -O2 -fPIC \
  -DLOOPGAMER_HAS_ADRENOTOOLS=1 \
  -Iandroid/app/src/main/cpp/third_party/libadrenotools/include -c \
  android/app/src/main/cpp/libretro_vulkan.cpp -o /tmp/vk.o
```

Toolchain portátil do projeto em `~/.local/share/loopgamer-toolchain/{flutter,jdk-17,android-sdk}` (Android SDK também contém `ndk/27.0.12077973`); sistema também possui `/opt/android-ndk`.

## Arquitetura em 1 parágrafo

Flutter (`lib/main.dart`, screens, `LoopCommonWidgets`, `HydraTokens`) → serviços (`EmulatorService`, `RomDownloadService`, `IgdbSteamGridService`, `CoverCacheService`, `GpuDriverService`, `LibraryStorageService`, `SettingsStorageService`) → ponte única `MethodChannel` (`org.loopgamer.libretro/methods`) + `EventChannel` (`org.loopgamer.libretro/events`) → `MainActivity.kt` (executor serializado `LibretroNativeIO`, `SurfaceTexture`/`Surface`, `AudioTrack` com buffer 4x, thread `LibretroTurboThread` com pacing + controle de ciclo de vida e `EmulationForegroundService` tipo `mediaPlayback`) → JNI `libretro_jni.cpp` (`dlopen` do core `.so`, mutex `g_state_mutex`, callbacks libretro, EGL/GLES renderer, HW render GL via FBO, fallback CPU, save states atômicos `.tmp`) → `libretro_vulkan.cpp` (frontend Vulkan `v5` + negotiation `v2` via `dlopen` ou Adreno Turnip via `libadrenotools`).

## Regras importantes

- **ABI libretro é intocável**: assinaturas de callbacks e structs têm layout fixo.
- **`retro_hw_render_callback`**: campos "Set by frontend" devem ser escritos diretamente no `cb` do core, não só em cópia local.
- **Vulkan**: `context_reset` do core só pode ser chamado DEPOIS de `SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE` + init completo; `GpuBackend.vulkan` é o padrão, com OpenGL ES e software como fallback.
- **Novo parâmetro de emulação** exige alteração em cadeia: `AppSettings` → `LibretroPlayerScreen` → `EmulatorService.startSession` → args do channel → `MainActivity.kt` → JNI.
- **Não linkar `libvulkan` no CMake**: carregamento é intencional via `dlopen`/`adrenotools` para compatibilidade com aparelhos sem Vulkan e troca dinâmica de driver Turnip.
- **Flags de C++ (`CMakeLists.txt`)**: `-O3 -ffast-math -fomit-frame-pointer -funroll-loops -flto -DNDEBUG` devem ficar restritas a `target_compile_options(libretro_jni PRIVATE ...)` e `target_link_options(...)` sem propagar para `third_party/libadrenotools`.
- **Sem bloqueio na UI thread nem falsos sucessos**:
  - Kotlin: `startLibretroSession`, `stopLibretroSession`, `saveState` e `loadState` devem rodar no executor `LibretroNativeIO` devolvendo o resultado real no `mainHandler`.
  - Dart: extração `.zip` e CRC32 rodam em `Isolate.run`; `EmulatorService.saveState/loadState` retornam estritamente o booleano real do nativo (nunca gravar JSON falso em `.state`).
- **Persistência atômica e schemas**: `LibraryStorageService` e `SettingsStorageService` gravam via `.tmp` único + `rename` sob fila/mutex, preservam `.corrupt.bak` se o JSON raiz corromper e versionam schemas (`AppSettings.currentSchemaVersion = 2`, `UserLibraryMeta.currentSchemaVersion = 1`, `LibraryStorageService.currentManifestVersion = 1`).
- **Rede e release Android**: manter `network_security_config.xml` (HTTPS global, HTTP restrito a hosts locais/LAN) e `proguard-rules.pro` (regras keep para JNI, plugins Flutter, `MainActivity`, `EmulationForegroundService` e `FileProvider` sob R8 `minifyEnabled true`/`shrinkResources true`).
- **UI & performance**: manter `ValueNotifier` + `RepaintBoundary` no player (`libretro_player_screen.dart`), guarda `isActive` em `handleGamepadNavigationKey` entre abas do `IndexedStack`, e alvos de toque/foco >= 48dp com `SafeArea`.

## Estado atual / pendências

- Código Flutter, serviços, testes (`88` passando em `flutter test`), C++ (clang++ / NDK 27) e APK release (`loopgamer-release.apk`, `arm64-v8a` com R8) compilam e passam sem warnings no `flutter analyze`.
- **Pendente validação em device físico ARM64**: runtime Vulkan (especialmente `create_device` do PPSSPP, drivers custom Turnip/AdrenoTools e recuperação de `VK_ERROR_SURFACE_LOST_KHR` / `VK_ERROR_DEVICE_LOST`) e teste em aparelho do `EmulationForegroundService` em Android 14+.
- **Frame dup 60Hz no Vulkan**: frames `nullptr` consomem/sinalizam `signalSem` via `consume_signal_semaphore()` sem duplicar blit/present no swapchain.
- **`ppsspp_*` core options**: `AppSettings.libretroCoreOptions` serializa `k=v;k=v` (validado contra `=`, `;`, `\n`, `\r` em `EmulatorService.serializeCoreOptions`), protegidos por `g_state_mutex` + `g_returnedVarStrings` em `libretro_jni.cpp` com fallbacks internos em `get_core_variable()`.
