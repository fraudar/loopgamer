# LoopGamer — Redesign de UI Vertical & Polimento Horizontal (`UI-REDESIGN.md`)

> **Escopo deste documento:** diagnóstico do layout **portrait (mobile)**, direção visual
> proposta, wireframes, tokens novos e plano de tarefas priorizado.
> **Não substitui** o `DESIGN.md` (design system) nem o `PRODUCT.md` (verdade do produto) —
> complementa ambos. Nenhum token existente é removido; apenas novos são adicionados.

---

## 0. Alvos de viewport (contrato)

| Modo | Viewport | Prioridade |
| :--- | :--- | :--- |
| Portrait mobile | `412×915` (mín. suportado `360×640`) | 🔴 é o que precisa de redesign |
| Handheld landscape | `915×412` | 🟡 polimento |
| Desktop landscape | `1280×800` / `1280×830` | 🟢 já está bom — não quebrar |

**Regra de decisão de layout:** usar **orientação + shortSide**, nunca apenas `maxWidth`.
Hoje `ps5_dashboard_screen.dart:39` decide por `maxWidth < 760`, o que faz um **tablet de
768px em portrait receber o layout landscape espremido**.

```dart
// Decisão correta (substituir o `compact` atual):
final bool isPortrait = constraints.maxHeight > constraints.maxWidth;
final bool isPhone   = constraints.shortestSide < 600;
final bool useCompactLayout = isPortrait || isPhone;
```

---

## 1. Diagnóstico — por que o vertical parece "IA / feio / bagunçado"

| # | Problema | Evidência (código / captura) |
| :--- | :--- | :--- |
| 1 | **Buraco vazio de ~330px** entre a fita de jogos e o título. Em landscape lê como respiro de hero; em portrait lê como bug. | `lib/screens/ps5_dashboard_screen.dart:59` (`const Spacer()`) |
| 2 | **Aurora ocupando 52% da altura** (~475px de textura berrante) exatamente atrás da área interativa (tabs + switcher). O conteúdo vive em cima da parte mais ruidosa da imagem. | `ps5_dashboard_screen.dart:42` (`curveDepthRatio: 0.52`) |
| 3 | **Textura granulada demais em 412px**: célula fixa de `36px` gera só ~11 colunas gordinhas — parece *wallpaper*, não material. | `lib/widgets/aurora_waffle_background.dart:125` |
| 4 | **Sem scroll**: `Column` + `Spacer` em altura fixa estoura em aparelhos de 640dp e não permite respirar o conteúdo. | `ps5_dashboard_screen.dart:49` |
| 5 | **Nenhuma orientação tratada/travada**: não existe `MediaQuery`/`OrientationBuilder`/`SystemChrome.setPreferredOrientations` em todo `lib/`. Girar o celular na tela do emulador desmantela todos os `Positioned`. | `emulator_ingame_screen.dart:37-171` |
| 6 | **Gamepad Studio e Catálogo não têm branch portrait**: `Row(flex:7 / flex:4)` deixa o inspetor com ~150px em 412px de largura. | `gamepad_studio_screen.dart:190`, `hydra_catalog_screen.dart:45` |
| 7 | **~14 pílulas com borda neon numa tela só** (4 tabs + 3 badges + 2 secundários + CTA + dock de 4 itens). Essa é a assinatura nº 1 do "look IA": tudo é pill, tudo tem borda 1px, tudo tem glow. | `ps5_dashboard_screen.dart` (inteiro) |
| 8 | **Navegação duplicada**: as 4 tabs do topo levam aos mesmos destinos do dock flutuante de baixo. | `:96-116` vs `:540-566` |
| 9 | **Ícones genéricos + todos os tiles marcados `PSP` + zero arte de capa** = cara de placeholder. É o que mais grita "gerado por IA". | `:209-230` |
| 10 | **Hierarquia fraca**: salto de `28px → 13.5px` é pequeno, e mono `11px` aparece em 6 lugares competindo pela mesma atenção. | `theme/ps5_hydra_theme.dart:62-103` |
| 11 | **Header do Catálogo**: botão voltar + título `displayMedium` + subtítulo de 4 linhas todos na mesma `Row` — em 412px fica espremido. | `hydra_catalog_screen.dart:45-73` |

---

## 2. Direção escolhida

### ⭐ Direção A — "Console OLED" (RECOMENDADA)

**Tese:** o preto `#000000` é o protagonista. A aurora vira um **"céu" limitado ao topo
(~300px)** com fade deliberado para o preto; todo o conteúdo vive sobre preto puro,
agrupado em **superfície de vidro**, com **uma única intenção de neon** por tela.

- Menos elementos, mais vazio *proposital*.
- Estrutura por **agrupamento** (card hero), não por borda em cada pill.
- Capas procedurais no lugar de ícones genéricos.
- Navegação **uma só** por modo.

### Direção B — "PS5 Fiel Mobile" (menor mudança, mais segura)

Mantém a aurora grande e o bloco focal ancorado embaixo (igual ao desktop atual), mas:
com `CustomScrollView` + scrim + sem `Spacer`. Mais próximo do que já existe; corrige a
estranheza sem mudar a identidade.

### Direção C — "Hydra Minimal" (mais corajosa, a mais anti-IA)

Quase tudo `#000000`; a aurora sobra apenas como **glow** atrás do tile em foco e do CTA.
Cards **sem borda** (só superfície `abyssalCard`). Diverge um pouco da identidade PS5, mas
é o que mais parece "design de verdade".

> **Recomendação:** implementar **A**, mantendo os tokens do `DESIGN.md` intactos.
> Se o resultado ficar "muito limpo" demais em relação ao desktop, migrar os pontos
> marcados como *opcionais* para o comportamento da Direção B.

---

## 3. Wireframes

### 3.1 Portrait — Direção A (`412×915`)

```
┌──────────────────────────────┐
│ ▒▒▒ CÉU AURORA (~300px) ▒▒▒▒ │  curveDepthRatio: 0.36
│  loopgamer      [• FFI C++20]│  header: marca + 1 chip de status
│  [ Jogos | Hydra | Gamepad ] │  segmented scrollável (SEM Shaders:
│ ┌────┐ ┌────┐ ┌────┐ ┌────┐ │   vira item de config no dock)
│ └────┘ └────┘ └────┘ └────┘ │  capas 3:4, foco 1.15x + glow
│▒▒▒ fade scrim → #000 ▒▒▒▒▒▒▒│  ← scrim garante legibilidade
├──────────────────────────────┤  (preto puro a partir daqui)
│ ╭── HERO CARD (vidro) ─────╮ │
│ │ ▓capa▓  God of War:      │ │  capa 3:4 (procedural)
│ │ ▓3:4 ▓  Ghost of Sparta  │ │  título displayMedium 28→30
│ │       │ PSP · VULKAN ·   │ │  ← META ROW mono 11 com
│ │       │ 60 FPS · 1.14 GB │ │    divisórios, NÃO pills
│ │       │ sinopse 2 linhas │ │
│ │       │ [ ▶ Jogar Agora ]│ │  ← único neon sólido da tela
│ ╰──────────────────────────╯ │
│ ┌─ Save State ─┬─ Hydra ────┐ │  ← 2 colunas (hoje empilhado)
│ │ ▓▓▓▓▓▓ 68%  │ M1: L1+R1  │ │
│ │ CRC32 · 14h  │ M2: Q+Q+T  │ │
│ └──────────────┴────────────┘ │
│ ▓▓▓ BOTTOM NAV (safe area) ▓ │  ← substitui o dock flutuante
└──────────────────────────────┘
```

**Fluxo de rolagem:** um único `CustomScrollView` com `SliverAppBar` leve (ou header
fixo), `SliverToBoxAdapter` para o céu + switcher, e o resto como slivers empilhados.
Nada de altura fixa — **zero overflow** em 360×640.

### 3.2 Landscape desktop (`1280×800`) — refino do buraco do meio

Hoje: switcher no topo → **~300px de textura vazia** → focal embaixo.

```
┌────────────────────────────────────────────────────────────┐
│ [Jogos PS5 UI][Hydra][Gamepad][Shaders]   loopgamer  [•FFI]│
│ ┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐                       │
│ └────┘└────┘└────┘└────┘└────┘└────┘                       │
│                                                            │
│        ▒▒▒ KEY ART / PAINEL DE ATIVIDADE ▒▒▒               │  ← opção (a)
│        ▒▒▒  full-bleed com máscara de fade ▒▒▒             │
│                                                            │
│ God of War: Ghost of Sparta        [Save State] [Hydra]    │
│ PSP · VULKAN · 60 FPS · 1.14 GB    ▓▓▓ 68%   M1: L1+R1    │
│ sinopse…                                                          │
│ [▶ Jogar] [Gamepad & Macros] [Importar ISO]                │
│                     ▓▓▓ dock flutuante ▓▓▓                 │
└────────────────────────────────────────────────────────────┘
```

**3 opções para preencher o vazio (escolher UMA):**

| Opção | Descrição | Esforço |
| :--- | :--- | :--- |
| **(a) Key art** | Bloco de arte grande à direita/full-bleed com `ShaderMask` de fade para o preto. Mais fiel ao PS5 real. | médio |
| **(b) Switcher maior** | Aumentar a fita para `120–140px` com capa + nome do jogo embaixo do tile focado (o switcher do PS5 ocupa ~30% da altura). | baixo |
| **(c) Cards subindo** | Mover as Activity cards para a coluna direita alinhadas ao switcher, transformando a composição em **2 colunas** em vez de faixas empilhadas. | médio |

---

## 4. Mudanças por tela (portrait)

### 4.1 `ps5_dashboard_screen.dart`

| Item | Antes | Depois |
| :--- | :--- | :--- |
| Layout | `Column` + `Spacer` fixo | `CustomScrollView` — sem buraco, sem overflow |
| Fundo | `curveDepthRatio: 0.52` | `0.36` em portrait / mantém `0.56` em landscape |
| Scrim | inexistente | `ShaderMask`/`GradientRect` `#000` `0% → 0.88%` sobre os 45% inferiores |
| Tabs topo | 4 pills (duplica o dock) | **portrait:** sai; vira `SegmentedButton` de 3 modos (Jogos/Hydra/Gamepad). **landscape:** mantém como está |
| Focal | texto solto sobre textura | **Hero Card** (`obsidianGlass` 92%, hairline `borderSubtle`, raio 20, padding 20) |
| Badges | 3 pills separadas | **Meta Row**: `PSP · VULKAN C++ · 60 FPS · 1.14 GB CHD` em `JetBrainsMono` 11 com divisórios verticais `1px` |
| Cards | empilhados full-width | Grade **2 colunas** (`Save State` + `Hydra & Macros`) com `AspectRatio`/`Expanded` |
| Dock | pill flutuante centralizada | **Bottom nav** com `SafeArea`, 4 itens, indicador ativo (barra 2px `#00F5A0`) |
| Switcher | tiles 56/76px com ícone genérico | tiles **3:4 com capa procedural**; foco `1.15x` + glow `boxShadow(blur 18, #00F5A0 45%)` + **nome do jogo visível** (hoje some em compact: `:235`) |
| Textura | célula `36px` | célula `28px`, opacidade `~0.6` em portrait |

**Sugestão de widget para a Meta Row** (substitui `_buildMetadataBadgesRow`):

```dart
Container(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  decoration: BoxDecoration(
    color: PS5HydraTheme.abyssalCard.withValues(alpha: 0.92),
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: PS5HydraTheme.borderSubtle),
  ),
  child: Row(mainAxisSize: MainAxisSize.min, children: [
    _meta('PSP'), _divider(), _meta('VULKAN C++'),
    _divider(), _meta('60 FPS'), _divider(), _meta('1.14 GB CHD'),
  ]),
);
```

### 4.2 `gamepad_studio_screen.dart`

- **Portrait:** empilhar — palco com `AspectRatio(16/9)` em cima, inspetor embaixo dentro
  de um **bottom sheet arrastável** (padrão mobile natural) ou em `ListView`.
- **Landscape:** o palco hoje **não preenche a altura** (sobra metade preta embaixo na
  captura `gamepad-studio.png`) — fazer o `Row` ocupar 100% e adicionar uma **faixa de
  status/dicas** no rodapé (`Arraste para mover · toque para selecionar · M1 dispara via FFI`).

### 4.3 `hydra_catalog_screen.dart`

- **Portrait:** quebrar a `Row` do cabeçalho — linha 1 = botão voltar sozinho; linha 2 =
  título; linha 3 = subtítulo com `maxLines: 2` + `ellipsis`.
- Item da lista: em portrait, botão de download **full-width abaixo** do conteúdo
  (`Row` → `Column`), não à direita.
- Filtro de plataforma: manter `ChoiceChip`, mas com `scrollDirection: horizontal` explícito
  para não estourar em 360px.

### 4.4 `emulator_ingame_screen.dart`

- **Travar em landscape** ao entrar na rota e restaurar ao sair (ver Tarefa 1).
- `Stack` + `Positioned` absolutos → em portrait, exibir **tela de bloqueio** com ícone de
  rotação e botão "Girar dispositivo" em vez de quebrar.
- Adicionar **scrim 60% preto** atrás da HUD bar (a textura atrás está barulhenta demais).
- Estados de toque nos botões: `scale(0.96)` + glow interno no `onTapDown/onTapUp`.
- Placa escura atrás do score/health bar.

### 4.5 `main.dart`

```dart
// Na entrada da rota ingameEmulator:
SystemChrome.setPreferredOrientations([
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
]);
// Ao voltar ao hub:
SystemChrome.setPreferredOrientations(DeviceOrientation.values);
```

---

## 5. Tokens novos (adicionar ao `DESIGN.md` / `ps5_hydra_theme.dart`)

| Token | Valor | Uso |
| :--- | :--- | :--- |
| `scrimBottom` | `LinearGradient(#000000 0% → #000000 88%)` | legibilidade sobre a aurora (portrait) |
| `skyDepthPortrait` | `0.36` | `curveDepthRatio` em portrait |
| `waffleCellPortrait` | `28.0` | célula da textura em portrait |
| `surfaceGlass` | `obsidianGlass @ 0.92` + hairline `borderSubtle` + raio `20` | hero card, bottom nav |
| `glowFocus` | `BoxShadow(color: #00F5A0 @ 45%, blurRadius: 18, spreadRadius: 0)` | tile em foco, CTA (alternativa à borda 2.2px) |
| `metaRowDivider` | `1px` vertical `borderSubtle` | separador da meta row |
| `radiusCard` | `20` | cards de superfície |
| `radiusChip` | `10` | meta row, chips internos |
| `spaceScale` | `4 / 8 / 12 / 16 / 24 / 32` | escala única de espaçamento (hoje há `6, 10, 14, 18, 22` soltos) |

---

## 6. Capa procedural (resolve o maior "cara de IA")

Sem assets reais, gerar a capa no próprio Dart:

```
Container
├─ fundo: LinearGradient( accentColor escurecido → obsidianGlass )
├─ sobreposição: textura waffle sutil (0.25 de opacidade, célula 22px)
├─ centro: monograma da plataforma em ReadexPro 700 (PSP / PS1 / GBA)
└─ base: faixa com o nome curto do jogo, 1 linha, ellipsis
```

Aplicar em: **tiles do switcher (3:4)**, **capa do hero card**, e **itens do Catálogo
Hydra** (thumb 56×76 à esquerda). Custo: zero asset, 1 widget reutilizável
(`lib/widgets/procedural_cover.dart`).

---

## 7. Regras anti-"IA" (checklist de revisão)

1. **Máximo 1 elemento neon sólido por tela** (o CTA principal). O resto usa hairline ou glow discreto.
2. **Tudo que é texto solto deve estar agrupado em superfície** (card/hero/nav). Nada de parágrafo flutuando sobre textura.
3. **Badges viram meta row**, não mais pills.
4. **Sem navegação duplicada** (topo ≠ dock apontando para os mesmos destinos).
5. **Arte > ícone genérico**. Proibido `Icons.sports_esports_outlined` em tile de jogo.
6. **Contraste de escala real:** título ≥ `28px`, corpo `14px`, meta `11px mono`. Nada de 3 tamanhos colados.
7. **Espaçamento da escala `spaceScale`** — nenhum valor fora dela.
8. **Cada tela tem um único "momento"** — no portrait é o hero card + CTA; o resto recua (borda mais fraca, menos glow).
9. **Centralizar só navegação** — conteúdo alinhado à esquerda (grid).
10. **Telemetria honesta** — manter os marcadores `(Preset)`, `(Sim)`, `(Demo)` (regra do `DESIGN.md`).

---

## 8. Plano de tarefas priorizado

| Prio | Tarefa | Arquivos | Esforço | Critério de aceite |
| :--- | :--- | :--- | :--- | :--- |
| 🔴 **1** | Travar orientação por rota (emulador = landscape, restaurar ao sair) + bloqueio de portrait no in-game | `main.dart`, `emulator_ingame_screen.dart` | baixo | Girar o celular não quebra nenhum `Positioned` |
| 🔴 **2** | Portrait do dashboard: `CustomScrollView` + scrim + hero card + `skyDepthPortrait 0.36` + remover `Spacer` | `ps5_dashboard_screen.dart`, `aurora_waffle_background.dart` | médio | Sem buraco, sem overflow em 360×640, texto legível sobre o fundo |
| 🔴 **3** | Meta row no lugar das badge pills; nav unificada (saiem as 4 tabs do portrait) | `ps5_dashboard_screen.dart` | baixo | 1 navegação por modo; ≤1 neon sólido na tela |
| 🟡 **4** | Capa procedural nos tiles, no hero e no catálogo | novo `lib/widgets/procedural_cover.dart` | médio | Zero `Icons.sports_esports_outlined` em tile |
| 🟡 **5** | Portrait do Gamepad Studio (empilhar + bottom sheet) e do Catálogo (header em 3 linhas, botão full-width) | `gamepad_studio_screen.dart`, `hydra_catalog_screen.dart` | médio | Nenhum widget espremido em 412px |
| 🟡 **6** | Bottom nav real com `SafeArea` + indicador ativo (substitui dock flutuante em portrait) | `ps5_dashboard_screen.dart` | baixo | Alcançável com o polegar, sem sobrepor o CTA |
| 🟢 **7** | Landscape: preencher o buraco (opção a/b/c) | `ps5_dashboard_screen.dart` | médio | Composição em 2 colunas, sem faixa vazia |
| 🟢 **8** | Animações: glow no tile focado, entrada escalonada 40ms, `AnimatedSwitcher` no título, pulso no dot de status | `ps5_dashboard_screen.dart` | baixo | Troca de jogo tem feedback visual |
| 🟢 **9** | In-game: scrim atrás da HUD, press states nos botões, placa escura no score | `emulator_ingame_screen.dart` | baixo | HUD legível; botões respondem ao toque |
| 🟢 **10** | Gamepad Studio landscape: palco preenchendo a altura + faixa de dicas | `gamepad_studio_screen.dart` | baixo | Sem metade preta vazia |

---

## 9. Riscos / não fazer

- **Não alterar** os tokens existentes do `DESIGN.md` (paleta, tipografia, regras de ergonomia `≥48×48px`).
- **Não remover** a textura waffle nem o shader — reduzir opacidade/célula em portrait, nunca apagar.
- **Não centralizar** o conteúdo do hero (a identidade é ancorada à esquerda).
- **Não adicionar** mais de 1 animação por elemento — o objetivo é parecer *console*, não *web app*.
- Cuidado com `withValues(alpha:)` em superfícies sobrepostas: empilhar 3 camadas de
  `obsidianGlass` já escurece demais; usar no máximo 2.
- Testar em `360×640` (Android compacto) após cada tarefa da prioridade 🔴.
