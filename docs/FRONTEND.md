# Frontend — LoopGamer (Flutter/Dart)

App Flutter (Android) em pt-BR que hospeda um frontend estilo GameHub/Hydra para gerenciamento de biblioteca, catálogos (curado, RomM REST, Archive.org, metadados SteamGridDB), download de cores/ROMs/drivers Turnip e o player libretro com sidebar estilo PPSSPP.

## Estrutura (`lib/` e `test/`)

```
lib/
  main.dart                          # Entrypoint, tema, shell landscape/portrait, ValueNotifiers e lifecycle dos serviços
  theme/
    hydra_tokens.dart                # Design tokens, buildAppTheme(), isWideLayout(), dialogShape, neonBoxGlow
  widgets/
    loop_common_widgets.dart         # Gamepad focus helper (handleGamepadNavigationKey), LoopProgressIndicator,
                                     # LoopPlatformChip, LoopEmptyState, LoopRecentGameCard, LoopHudToggleGroup
  models/
    app_settings.dart                # AppSettings (schema v2), enums de vídeo/controle, hudToggleSpecs, libretroCoreOptions
    emulation_game.dart              # Modelo EmulationGame + stableIdFromKey (FNV-1a) + kRommPlatforms
    user_library_meta.dart           # UserLibraryMeta (schema v1), PlaytimeRecord, favoritos e coleções
  screens/
    home_screen.dart                 # Início, "Continuar jogando", "Favoritos" e carrosséis
    explore_screen.dart              # Catálogo, busca, filtros por plataforma/ordenação e GameDetailSheet
    game_detail_screen.dart          # Helper modal GameDetailScreen.showAsModal (fecha sheet antes de abrir player)
    library_screen.dart              # Biblioteca local (ROMs baixadas/importadas), coleções e gerenciamento
    libretro_player_screen.dart      # Player libretro (~4.4k linhas): viewport, gamepad touch configurável e sidebar
    settings_screen.dart             # Configurações globais, RomM, drivers Vulkan Turnip, firmware PS3 e espaço usado
  services/
    emulator_service.dart            # Ponte única Dart↔nativo (MethodChannel + EventChannel), cores ELF, save states
    rom_download_service.dart        # Download/retomada de ROMs, seleção/validação em Archive.org e CRC32
    library_storage_service.dart     # Manifesto local atômico (schema v1, region), backup .corrupt.bak e CRC32
    settings_storage_service.dart    # Persistência atômica de AppSettings + backup .corrupt.bak
    cover_cache_service.dart         # Cache persistente de capas + LoopCoverImage com presets de decodificação
    igdb_steamgriddb_service.dart    # Catálogo curado, cliente RomM e capas SteamGridDB com CancelToken + semáforo
    gpu_driver_service.dart          # Gerenciador de drivers Adreno Turnip customizados (AdrenoTools, filesDir/gpu_drivers)
test/
  widget_test.dart                   # Smoke test Portrait & Landscape do GameHub
  core_fixes_test.dart               # Regressões de tamanho real de ROMs, busca e seleção Archive.org
  regression_suite_test.dart         # Regressões de persistência atômica, schemas, EmulatorService, Downloads, Turnip e UI
android/...                          # Lado nativo (ver docs/BACKEND.md)
```

## Shell principal (`lib/main.dart`) e UI

- **Tema e Localização**: `HydraTokens.buildAppTheme()` usa apenas pesos declarados no `pubspec.yaml` (`PressStart2P` para logo retrô na Home, `Silkscreen`, `ReadexPro` 600/700, `Rubik` 400–700, `JetBrainsMono` 400/700) com contraste WCAG em `textMuted` (`0xFF9391A6`). `localizationsDelegates` configura `pt-BR`.
- **Responsividade**: `HydraTokens.isWideLayout(context)` (`width >= 600 && width > height`) alterna entre barra superior flutuante em landscape (`_GameHubLandscapeTopBar`, cápsulas translúcidas estilo iOS sobre o conteúdo em tela cheia, com relógio em tempo real `_LiveTopBarClock` e status real de Wi-Fi `_LiveTopBarWifi`) e dock inferior em portrait (`_GameHubPortraitDockBar`).
- **Abas em `IndexedStack`**: Home, Explorar, Biblioteca e Configurações recebem `isActive` para evitar disputa de foco de gamepad em abas ocultas (`handleGamepadNavigationKey`).
- **Notifiers reativos**: `_downloadStatusesNotifier`, `_libraryBadgeCountNotifier`, `_hasActiveDownloadNotifier` e `_hardwareGamepadNotifier` isolam reconstruções de UI.
- **Ciclo de vida**: serviços compartilhados (incluindo `_emulatorService` passado à `SettingsScreen`) têm `dispose()` explícito; abrir o player executa `navigator.popUntil((r) => r.isFirst)` e `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)` é restaurado ao retornar.

## Fluxo do player (`lib/screens/libretro_player_screen.dart`)

1. `_startSession()` envia todos os parâmetros de `_settings` (`AppSettings`) para `EmulatorService.startSession(...)`, incluindo opções de driver Turnip/Freedreno e `coreOptions`.
2. Recebe `textureId` (`SurfaceTexture` do Flutter) e renderiza em `Texture` isolado em `RepaintBoundary`.
3. HUD técnico, toast de status, máscara de gamepad virtual e analógico usam `ValueNotifier`s + `RepaintBoundary` separados para evitar rebuild da tela inteira por frame/toque.
4. Arrasto de botões no editor do overlay usa debounce (`Timer` de 350ms com flush no fim do gesto/`dispose`) para não saturar disco.
5. Sidebar (Saves, Gráficos, Gamepad, HUD/Info) usa `LoopHudToggleGroup` compartilhado com `SettingsScreen` (via `AppSettings.hudToggleSpecs`).
6. Sair do player exibe diálogo de confirmação (`_confirmExitPlayer()`: salvar rápido e sair, sair sem salvar ou cancelar). `saveState`/`loadState` exibem feedback fiel ao booleano retornado pelo nativo; captura de preview do slot é protegida por `timeout(500ms)` e guarda `FLUTTER_TEST`.

## `AppSettings` (`lib/models/app_settings.dart`)

Fonte única de verdade das configurações, versionada (`currentSchemaVersion = 2`) com migração automática de JSON v1 (`gpuRenderer`/`internalResolutionScale`).

- **Enums principais**: `GpuBackend` (**vulkan** padrão, `openGL`, `software`), `TurnipFreedrenoPreset`, `RenderResolutionPreset` (1x–10x PSP, 1080p, 4K → `ppsspp_internal_resolution`), `MsaaLevel`, `ScreenResolutionScale`, `TextureFilterMode`, `AspectRatioPreset`, `VideoFilterPreset`, `TouchOverlayMode`, `GamepadButtonStyle`, `ShoulderTriggerStyle`, `HudOverlayToggleKind`.
- **RomM**: `rommServerUrl`, `rommApiToken` e validador `AppSettings.isValidRommServerUrl()`.
- **Drivers Vulkan Custom**: `customVulkanDriverDir`, `customVulkanDriverName`, `customVulkanDriverLabel`, `adrenoTurboMode`, `freedrenoPreset`.
- **`libretroCoreOptions` (getter)**: gera o mapa `chave=valor` (prioridade sobre defaults hardcoded em `libretro_jni.cpp` quando serializado como `k=v;k=v`).
- **`hudToggleSpecs`**: definição única dos 5 toggles do HUD consumida pelo `LoopHudToggleGroup`.

## `EmulatorService` (`lib/services/emulator_service.dart`)

Única ponte Dart↔nativo:

- `MethodChannel`: `org.loopgamer.libretro/methods`
- `EventChannel`: `org.loopgamer.libretro/events` → `telemetryStream` (`LibretroTelemetryEvent`) e `hardwareGamepadStream`

Principais responsabilidades e proteções:

- `Dio` próprio com timeouts explícitos (`15s`/`60s`/`15s`) e `dispose()`.
- `ensureCoreDownloaded`: verifica assinatura ELF em `isValidElfSharedLibrary` (`>= 16 KB`), descompacta `.zip` em `Isolate.run` e reporta erro descritivo em `lastError`.
- `serializeCoreOptions`: rejeita chaves/valores com `=`, `;`, `\n` ou `\r`.
- `startSession(...)`: provisiona BIOS/sistema quando aplicável (NeoGeo `neogeo.zip`, Dolphin `Sys` em `Isolate.run`, `ppsspp.ini` mínimo para PSP, validação de `PS3UPDAT.PUP` para PS3) e envia no channel: `platform`, `corePath`, `romPath`, `systemDir`, `savesDir`, `resolutionScale`, `frameSkip`, `vsyncEnabled`, `audioEnabled`, `masterVolume`, `softwareRendering`, `gpuBackend`, `screenScale`, `frameDup`, `customDriverDir`, `customDriverName`, `adrenoTurbo`, `freedrenoPreset`, `coreOptions`.
- Controle em execução: `setAudioConfig`, `setPerformanceConfig`, `setFastForward`, `setTurboConfig`, `sendInputState`, `setPaused`, `stopSession`.
- Save states honestos: `saveState` e `loadState` retornam o `bool` real do nativo (sem gravar JSON falso em `.state`), acompanhados de `.png`/`.json` de preview/meta quando `saveState` sucede.

## Persistência, Downloads, Capas e Drivers

- **`LibraryStorageService` / `SettingsStorageService`**: escrita atômica com arquivo `.tmp` único + `rename` sob fila/mutex, recuperação tolerante por entrada no manifesto (preservando `region` e `currentManifestVersion = 1`) + backup `.corrupt.bak` se a raiz JSON falhar, e `computeFileCrc32Hex` em `Isolate.run`.
- **`RomDownloadService`**: timeout de recepção (`45s`), tratamento específico por código HTTP (`401`/`403`/`404`/`416` com reset de `.part`/`408`/`429`/`5xx`) + backoff exponencial (até 3 tentativas) + `DioExceptionType.transformTimeout`, controle de pausa/retomada por `_operationSeq`, preservação de `.zip` importados em `resolveExistingRomPath` (ignorando `_jp2.zip`/`.part` e descartando stubs `< 1024` bytes), verificação opcional de CRC32 e `dispose()`. Na importação externa valida extensão × plataforma via `isImportExtensionCompatible`/`importExtensionsForPlatform` (lista base de downloads + extras `.cue`/`.bin`/`.img`/`.gdi`/`.cdi`/`.cia`).
- **`RomPlatformDetector`**: detecta a plataforma de ISOs/ROMs sem fallback silencioso — prioridade conteúdo do arquivo (marcadores `BOOT2`→PS2, `PS-X EXE`/`BOOT =`→PS1, `PSP_GAME`, `PS3_DISC.SFB`, `SEGA SEGASATURN`/`SEGAKATANA`, magic Wii `0x5D1C9EA3@0x18` e GameCube `0xC2339F3D@0x1C`, `FILE` do `.cue` segue o `.bin` irmão) → nome/caminho (seriais Sony `0xxxx`=PS1, `2xxxx`/`5xxxx`=PS2, tokens `(PS2)`/`PSX`/`Wii`) → extensão exclusiva → tamanho (só `.iso`/`.img`, rotulado como estimativa). Retorna `null` quando nada é confiável e o diálogo de importação força o usuário a escolher o console (botão "Adicionar" fica desabilitado até haver plataforma válida e compatível com a extensão).
- **`IgdbSteamGridService`**: removido código morto de OAuth da Twitch; usa IDs determinísticos (`EmulationGame.stableIdFromKey`), `CancelToken` por consulta, semáforo de no máximo 3 requisições simultâneas no SteamGridDB e `dispose()`.
- **`CoverCacheService` / `LoopCoverImage`**: decode dimensionado por preset (`LoopCoverImagePreset`: `thumbnail`, `card`, `hero`, `original`), correção de estado em `didUpdateWidget` e `dispose()`.
- **`GpuDriverService`**: listagem/download/importação de drivers Turnip em `Isolate.run` com proteção contra zip-slip, validação de ID (`isValidDriverId`) e verificação canônica de caminho em `deleteDriver`.

## Convenções

- Configurações sempre via `AppSettings.copyWith` + `SettingsStorageService.save`.
- ROMs, saves, cores e drivers nunca vão para o repositório — residem nos diretórios da aplicação (`path_provider`).
- UI em pt-BR; mensagens de erro amigáveis na interface e logs técnicos via `debugPrint`.
- Novo parâmetro de emulação deve atravessar toda a cadeia: `AppSettings` → `LibretroPlayerScreen` → `EmulatorService.startSession` → channel arg → `MainActivity.kt` → JNI.

## Build / verificação

```bash
flutter analyze   # lint estrito (0 issues)
flutter test      # 32 testes (unit + widget regressions)
./build-apk.sh    # APK release arm64-v8a com R8 → loopgamer-release.apk
```

Toolchain portátil: `~/.local/share/loopgamer-toolchain/{flutter,jdk-17,android-sdk}`; sistema também possui `/opt/android-ndk` (NDK 27).
