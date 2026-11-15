# LoopGamer

Emulador de consoles retro para Android construído em Flutter, com frontend
nativo C++/JNI rodando cores **libretro** (.so) — PPSSPP (PSP), PCSX-ReARMed
(PS1), Snes9x, Genesis Plus GX, Mupen64Plus etc.

Destaques:

- **Backend Vulkan** (padrão, experimental) com **OpenGL ES** e **software CPU**
  como fallback — frontend Vulkan próprio baseado na interface oficial
  `retro_hw_render_interface_vulkan` v5 do libretro.
- Renderer EGL/GLES próprio (substitui `ANativeWindow_lock`), HW render com
  FBO + depth/stencil para cores que usam GPU.
- Configurações de gráficos estilo PPSSPP: resolução de render 1x–10x/1080p/4K,
  MSAA, resolução de tela, filtros, textura replacement, toggles de performance.
- Save states, turbo/fast-forward, gamepad Bluetooth/USB, telemetria de FPS.

## Documentação

- [`docs/BACKEND.md`](docs/BACKEND.md) — Kotlin + JNI + C++ (libretro, EGL/GLES,
  Vulkan, áudio, save states, build nativo).
- [`docs/FRONTEND.md`](docs/FRONTEND.md) — Flutter/Dart (telas, services,
  `AppSettings`, canais nativos).
- [`AGENTS.md`](AGENTS.md) — contexto rápido e comandos de build para agentes
  de IA continuarem o trabalho.

## Build

```bash
./build-apk.sh    # gera loopgamer-release.apk
flutter analyze   # lint
```

Toolchain portátil em `~/.local/share/loopgamer-toolchain`
(Flutter + JDK 17 + Android SDK); NDK 27 do sistema em `/opt/android-ndk`.
