# LoopGamer

Emulador de consoles retro para Android construído em Flutter, com frontend
nativo Kotlin/C++/JNI rodando cores **libretro** (`.so`) — PPSSPP (PSP),
PCSX-ReARMed (PS1), mGBA (GBA), Snes9x, Genesis Plus GX, Mupen64Plus, FBNeo,
Dolphin etc.

## Destaques

- **Backend Vulkan** (`v5` + negotiation `v2` próprio em `libretro_vulkan.cpp`,
  padrão/experimental em device) com suporte a drivers **Adreno Turnip** via
  **AdrenoTools** (`arm64-v8a`), além de **OpenGL ES** e **software CPU** como
  fallback.
- **Renderer EGL/GLES** próprio + HW render com FBO e depth/stencil, além de
  ciclo de vida integrado ao `EmulationForegroundService` (`mediaPlayback`).
- **Configurações estilo PPSSPP**: resolução de render 1x–10x/1080p/4K, MSAA,
  escala de tela, filtros, substituição de texturas, presets Freedreno e
  layout touch customizável isolado em `ValueNotifier` + `RepaintBoundary`.
- **Catálogo, downloads e biblioteca**: integração REST com servidor **RomM**,
  downloads com retomada e validação CRC32, cache de capas SteamGridDB em disco
  e persistência atômica (`.tmp` + `rename` com backup `.corrupt.bak`).
- **Jogabilidade e segurança**: save states atômicos por slot com preview,
  turbo/fast-forward, gamepad Bluetooth/USB, telemetria de FPS/frame-time e
  `networkSecurityConfig` com HTTPS padrão.

## Documentação

- [`docs/BACKEND.md`](docs/BACKEND.md) — Kotlin + JNI + C++ (libretro,
  EGL/GLES, Vulkan/AdrenoTools, áudio, save states, FGS e build nativo).
- [`docs/FRONTEND.md`](docs/FRONTEND.md) — Flutter/Dart (telas, widgets
  compartilhados, serviços, `AppSettings`, persistência e canais nativos).
- [`docs/AGENTS.md`](docs/AGENTS.md) — contexto rápido, regras de arquitetura e
  comandos de build/teste para agentes de IA continuarem o trabalho.

## Build e verificação

```bash
./build-apk.sh    # gera loopgamer-release.apk (arm64-v8a + R8 minify/shrink)
flutter analyze   # lint estrito (analysis_options.yaml)
flutter test      # suíte de testes unitários e de widgets (32 testes)
```

Toolchain portátil em `~/.local/share/loopgamer-toolchain`
(Flutter + JDK 17 + Android SDK); NDK 27 em `/opt/android-ndk` (e no SDK portátil).
