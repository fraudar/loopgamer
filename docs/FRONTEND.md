# Frontend — LoopGamer (Flutter/Dart)

App Flutter (Android) que hospeda um player libretro: biblioteca de jogos,
download de cores/ROMs, metadados IGDB/SteamGridDB, e a tela de emulação com
sidebar de configurações estilo PPSSPP.

## Estrutura

```
lib/
  main.dart                          # entrypoint, tema, rotas
  models/
    app_settings.dart                # AppSettings + enums (persistido em JSON)
    emulation_game.dart              # modelo de jogo da biblioteca
    user_library_meta.dart           # metadados do usuário por jogo
  screens/
    home_screen.dart                 # home/carrossel
    explore_screen.dart              # catálogo/download de ROMs
    library_screen.dart              # biblioteca do usuário
    game_detail_screen.dart          # detalhes do jogo
    libretro_player_screen.dart      # PLAYER (maior arquivo, ~3.4k linhas)
    settings_screen.dart             # configurações globais
  services/
    emulator_service.dart            # MethodChannel/EventChannel wrapper
    settings_storage_service.dart    # persistência de AppSettings
    library_storage_service.dart     # biblioteca local
    rom_download_service.dart        # download de ROMs
    cover_cache_service.dart         # cache de capas
    igdb_steamgriddb_service.dart    # metadados/capas
android/.../MainActivity.kt          # lado nativo (ver docs/BACKEND.md)
```

## Fluxo do player (`libretro_player_screen.dart`)

1. `_startSession()` → `EmulatorService.startSession(...)` com todos os
   parâmetros de `_settings` (AppSettings).
2. Recebe `textureId` (SurfaceTexture do Flutter) → renderiza via `Texture`.
3. Sidebar com abas — a aba **"Gráficos"** concentra backend/resolução/filtros;
   outras abas: input/gamepad, save states, desempenho, sobre.
4. Telemetria (`LibretroTelemetryEvent`: fps, frameTimeMs, w/h, coreName)
   atualiza HUD de FPS.
5. `saveState`/`loadState` por slot com preview em arquivo.

## `AppSettings` (`lib/models/app_settings.dart`)

Fonte única de verdade das configurações de emulação. Persistido como JSON via
`SettingsStorageService`. Enums principais:

- `GpuBackend`: **vulkan** (padrão), openGL, software
- `RenderResolutionPreset`: presets de resolução de render (1x–10x PSP,
  1080p, 4K) — `coreValue` vai para `ppsspp_internal_resolution`
- `MsaaLevel`: off/2x/4x → `ppsspp_msaa`
- `ScreenResolutionScale`: nativa/2x/3x/4x — `screenScale` (buffer do surface)
- `TextureFilterMode`, `AspectRatioPreset`, `VideoFilterPreset`
- Toggles: frameDup, vsync, texture replace, lens flare, ignore GPU reads,
  lazy texture cache, hardware transform, software skinning, anisotropic,
  deposterize, frameSkip

`libretroCoreOptions` (getter) gera o mapa `chave=valor` → serializado como
`k=v;k=v` no arg `coreOptions` → vira `g_coreVars` no nativo
(`RETRO_ENVIRONMENT_GET_VARIABLE`, prioridade sobre defaults).

## `EmulatorService` (`lib/services/emulator_service.dart`)

Única ponte Dart↔nativo:

- MethodChannel `org.loopgamer.libretro/methods`
- EventChannel `org.loopgamer.libretro/events` → stream de
  `LibretroTelemetryEvent`/`hardwareGamepadActive`

`startSession(...)` baixa o core se preciso (`ensureCoreDownloaded`), cria
`ppsspp.ini` mínimo para PSP (CPU JIT, FastMemory, Graphics), e invoca
`startLibretroSession` com todos os args.

Args do channel (devem casar com `MainActivity.kt`):
`platform, corePath, romPath, systemDir, savesDir, resolutionScale, frameSkip,
vsyncEnabled, audioEnabled, masterVolume, softwareRendering (bool legado),
gpuBackend ("vulkan"|"opengl"|"software"), screenScale, frameDup, coreOptions`.

Outros métodos: `setAudioConfig`, `setPerformanceConfig` (frameSkip/vsync/dup
ao vivo), `setFastForward`, `setTurboConfig`, `updateInput`, `saveState`/
`loadState`/`deleteSaveState`/`listSaveSlots`, `setPaused`, `stopSession`.

## Convenções

- Settings sempre via `AppSettings.copyWith` + `SettingsStorageService.save`.
- Não commitar ROMs/saves — paths vêm de `getApplicationSupportDirectory()`.
- UI em pt-BR; texto de erro amigável.
- Qualquer novo parâmetro de emulação precisa ser adicionado em **3 lugares**:
  `AppSettings` → `libretroPlayerScreen._startSession` → `EmulatorService.startSession`
  → arg no channel → `MainActivity.kt` → JNI.

## Build / verificação

```bash
flutter analyze                 # lint
./build-apk.sh                  # APK release → loopgamer-release.apk
```

Toolchain portátil: `~/.local/share/loopgamer-toolchain/{flutter,jdk-17,android-sdk}`.
Sistema também tem `/opt/android-ndk` (NDK 27).
