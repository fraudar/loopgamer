# LoopGamer — Design System (`DESIGN.md`)

## 1. Visual Direction & Architecture
- **Stack:** Dart (Flutter) + C++20 (`dart:ffi`, `libloopgamer_core.so`, GLSL Fragment Shaders `shaders/aurora_waffle.frag`, and Native Linux/Android C++20 Renderer). Zero HTML/CSS/JS.
- **Spatial Model:** **PlayStation 5 (PS5) Console Dashboard** paired with the **4-Stage (`Shapes -> Blur -> Texture -> Design`) Hydra Bluish-Green Aurora Surface**:
  1. **Stage 1 (`Shapes`):** Sweeping organic curved bands across the upper canvas (`#00F5A0` Spring Mint, `#D6FFF2` Seafoam Mist, `#00D2B4` Cyan-Teal, `#06768D` Ocean Cerulean, `#02242E` Abyssal Trench) meeting pure **Pitch Black (`#000000`)** below.
  2. **Stage 2 (`Blur`):** Smooth atmospheric vertical diffusion blending the curved aurora bands into the pitch-black floor.
  3. **Stage 3 (`Texture`):** 3D embossed rounded-square waffle grid displacement (`shaders/aurora_waffle.frag` & `lg_render_aurora_waffle_bg`) with directional specular highlights and dark recessed grooves that fade seamlessly into `#000000`.
  4. **Stage 4 (`Design`):** High-contrast PS5 console UI — top horizontal media/game switcher row where the focused game tile expands (`88×88px` desktop / `76×76px` mobile) with a `2.2px` glowing `#00F5A0` border, lower-left focal block leading directly with the game title (`Readex Pro Bold`), sleek stadium-pill CTAs (`Jogar Agora`), right-hand PS5 Activity/Save-State & Hydra Direct cards, and a floating translucent bottom PS5 Control Center Dock.

## 2. Color Tokens (Pitch Black + Hydra Bluish-Green Aurora)
| Token | Hex | Role |
| :--- | :--- | :--- |
| `pitchBlack` | `#000000` | Primary lower focal floor & OLED canvas |
| `obsidianGlass` | `#050B0D` | Translucent PS5 HUD pills, top switcher bar & floating dock |
| `abyssalCard` | `#0A1416` | PS5 Activity / Save-State cards & secondary pill buttons |
| `auroraSpringMint` | `#00F5A0` | Primary Hydra Bluish-Green Aurora accent, active pill & focus ring |
| `auroraSeafoamMist` | `#D6FFF2` | Upper aurora specular crest |
| `auroraCyanTeal` | `#00D2B4` | Mid-band bioluminescent teal transition |
| `auroraOceanCerulean`| `#06768D` | Deep ocean blue-teal aurora band |
| `auroraDeepTrench` | `#02242E` | Abyssal transition before `#000000` |
| `textPrimary` | `#F2FBF9` | Primary headings & focal titles |
| `textSecondary` | `#9EC4BC` | Tinted seafoam-silver body & synopsis copy (never neutral gray) |
| `textOnAurora` | `#020D09` | High-contrast dark ink on `#00F5A0` primary pills (`15.1:1` AAA) |
| `borderSubtle` | `#1A3631` | `1px` structural hairline on cards and pills |
| `dangerRose` | `#F24C5C` | Exit emulator (`Sair (PS5)`) & destructive actions |

## 3. Typography & Scannable Hierarchy
- **Display & Focal Titles (`--font-display`):** `Readex Pro` (`Bold 700`, `SemiBold 600`), tight tracking (`-0.025em`), leading directly in the focal block without any kicker or eyebrow label above the heading.
- **UI & Synopsis Copy (`--font-sans`):** `Rubik` (`400`, `500`, `600`), comfortable line height (`1.45–1.48`).
- **Telemetry, CRC32 & Frame Timings (`--font-mono`):** `JetBrains Mono` (`tabular-nums`) for `60 FPS (Preset)`, `1.14 GB CHD`, `CRC32: 9F4A2C1E`, and macro sequences (`M1: L1+R1`, `M2: Q+Q+T`).

## 4. Ergonomics & Craft Guardrails
- **Touch Targets:** Every interactive button, game switcher tile, dock item, and virtual gamepad control is at least `48×48px` with `>= 8px` separation.
- **Zero In-Game Overlap:** In landscape gameplay (`915×412`), `L1`/`L2` and `R2`/`R1` shoulder triggers flank the centered health/combo HUD bar (`240px` wide) with over `140px` of horizontal clearance, and all face buttons use pure vector geometry (Triangle, Circle, Cross, Square) with zero Unicode symbol icons.
- **Honest Telemetry Labels:** Simulated or preset metrics explicitly carry `(Preset)`, `(Demo)`, or `(Sim)` markers.
