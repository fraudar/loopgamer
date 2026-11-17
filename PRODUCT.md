# LoopGamer — Product Truth (PRODUCT.md)

## Overview
**LoopGamer** is a high-performance, open-source, account-free multi-platform console emulator and direct-download game launcher built natively in **Dart (Flutter)** and **C++20 (`dart:ffi` + Libretro/PPSSPP Vulkan Core + GLSL Fragment Shaders)** for Android (`.apk`), iOS (`.ipa`), and Linux/Desktop.

## Visual & Interactive Architecture
1. **PS5 Console Dashboard UX:**
   - Top horizontal media/game switcher strip with animated expanding focus tile (`88×88dp` active vs `60×60dp` resting), clean top mode tabs (`Jogos`, `Catálogo Hydra`, `Gamepad Studio`, `Motor C++`), and minimal system status cluster.
   - Full-bleed hero canvas driven by the **4-Stage Aurora Material Pipeline (`Shapes -> Blur -> Texture -> Design`)**: curved organic bands of Hydra Bluish-Green Aurora (`#00F5A0`, `#00D2B4`, `#0892A5`, `#032B38`) blurred into pure pitch black (`#000000`), overlaid with a normal-mapped **3D embossed waffle/grid displacement texture** and fine surface grain that dissolves smoothly into the obsidian lower screen.
   - Lower-left PS5 focal hub with oversized crisp typography, pill primary CTA (`Jogar`), and horizontal PS5 Activity / Quick-Resume cards + floating translucent Control Center dock.
2. **Native C++20 Emulation & Shader Core (`libloopgamer_core.so`):**
   - Multi-platform C++20 core manager bridging PPSSPP (PSP), DuckStation (PS1), mGBA (GBA), Snes9x (SNES), Mupen64Plus (N64), and MelonDS (NDS) via zero-copy `dart:ffi` shared memory buffers.
   - Hardware Vulkan 1.3 / OpenGL ES 3.2 upscaling (`1x` to `4x 1440p`) and real-time GLSL post-processing shaders.
3. **Hydra Direct Download Engine (C++ & JSON Manifests):**
   - Decentralized Hydra-compatible JSON repository parser and direct CHD/ISO downloader with CRC32 verification—download classics like *God of War: Ghost of Sparta*, *God of War: Chains of Olympus*, *Tekken 6*, and *GTA: Liberty City Stories* directly inside the app with zero login.
4. **Zero-Lag Touch Gamepad & 1-Tap Combo Macro Engine:**
   - Freeform drag-and-drop button editor (position, scale, opacity, magnetic grid, gyroscope tilt) and C++ frame-accurate macro sequencer (`M1: Fúria de Esparta L1+R1`, `M2: Pluma de Prometeu □·□·△`).
