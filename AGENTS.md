# LoopGamer — contexto para agentes de IA

Emulador libretro Android em Flutter. Leia `docs/BACKEND.md` (nativo:
Kotlin+JNI+C++/Vulkan/GL) e `docs/FRONTEND.md` (Flutter/Dart) antes de mexer.

## Build

```bash
flutter analyze     # deve sair "No issues found"
./build-apk.sh      # gera loopgamer-release.apk (toolchain portátil próprio)
```

Compilação C++ isolada rápida (pega erros sem Gradle):

```bash
NDK=/opt/android-ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
$NDK/aarch64-linux-android26-clang++ -std=c++17 -O2 -fPIC -c \
  android/app/src/main/cpp/libretro_jni.cpp -o /tmp/jni.o
$NDK/aarch64-linux-android26-clang++ -std=c++17 -O2 -fPIC -c \
  android/app/src/main/cpp/libretro_vulkan.cpp -o /tmp/vk.o
```

## Arquitetura em 1 parágrafo

Flutter (`lib/`) → `EmulatorService` (MethodChannel
`org.loopgamer.libretro/methods` + EventChannel `.../events`) →
`MainActivity.kt` (SurfaceTexture/Surface, AudioTrack, thread
`LibretroTurboThread` com pacing) → JNI `libretro_jni.cpp` (`dlopen` do core
`.so`, callbacks libretro, EGL/GLES renderer, fallback `ANativeWindow_lock`,
HW render GL via FBO) → `libretro_vulkan.cpp` (frontend Vulkan thin:
instance/device/swapchain/blit, libvulkan via dlopen).

## Regras importantes

- ABI libretro é intocável: assinaturas de callbacks e structs têm layout fixo.
- `retro_hw_render_callback`: campos "Set by frontend" devem ser escritos no
  `cb` do core, não só em cópia local.
- Vulkan: `context_reset` do core só pode ser chamado DEPOIS do
  `SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE` + init completo.
- Backend Vulkan é o padrão (`GpuBackend.vulkan`); GL e software são fallback.
- Novo parâmetro de emulação exige alteração em cadeia:
  `AppSettings` → player screen → `EmulatorService` → channel arg →
  `MainActivity.kt` → JNI.
- Flags de release agressivas: `-O3 -ffast-math -flto -DNDEBUG`.
- Não linkar `libvulkan` no CMake — é `dlopen` proposital (devices sem Vulkan).

## Estado atual / pendências

- Vulkan implementado e compilando, **sem teste em device** — validar com PPSSPP
  core em aparelho/emulador com Vulkan; se falhar, logcat + fallback GL.
- Frame dup 60Hz não implementado no path Vulkan.
- `ppsspp_*` core options: defaults hardcoded em `get_core_variable()` +
  overrides do usuário via `k=v;k=v`.
