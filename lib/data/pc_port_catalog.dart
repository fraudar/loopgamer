import '../models/pc_port.dart';

/// Catálogo curado de ports Android de jogos de PC/console e projetos
/// open-source. Cada item aponta para o release oficial do projeto ou para a
/// loja oficial — nunca para mirror ou APK de terceiros.
///
/// Jogos comerciais recompilados (GTA IV, RE4, God of War, Megabonk) exigem
/// os arquivos originais do próprio usuário; o item declara isso em
/// [PcPortEntry.requiresGameFiles] e o cartão destaca o requisito.
class PcPortCatalog {
  PcPortCatalog._();

  static const List<PcPortEntry> entries = [
    // ---------------------------------------------------------------------
    // Ports nativos de jogos 3D de PC/console (recompilação estática ou
    // reimplementação). Todos exigem os arquivos do jogo original do próprio
    // usuário — o APK é só o motor, nunca o jogo completo.
    // ---------------------------------------------------------------------
    PcPortEntry(
      id: 'openbonk',
      title: 'OpenBonk (Megabonk)',
      developer: 'martin2844 / comunidade',
      genre: 'Roguelike / Survivors 3D',
      description:
          'Port Android não oficial do Megabonk (C#), com controles touch '
          'customizáveis, suporte a controle e opções gráficas. Beta ativo — '
          'releases semanais no GitHub.',
      license: 'Port comunitário (beta)',
      source: PcPortSource.githubRelease,
      githubRepo: 'martin2844/OpenBonk',
      apkAssetPrefix: 'OpenBonk',
      apkAssetSuffix: '.apk',
      requiresGameFiles:
          'Requer os assets do Megabonk original (Steam) na pasta de dados do '
          'app. Sem eles o port abre, mas não carrega nenhum personagem/fase.',
      archNote: 'APK único (~57 MB). Beta: saves podem quebrar entre versões.',
      minRamMb: 3072,
    ),
    PcPortEntry(
      id: 'xhyn-iv-recomp',
      title: 'XHYN IV (GTA IV)',
      developer: 'XHYN-PH / LibertyRecompAndroid',
      genre: 'Mundo aberto / Ação',
      description:
          'Port Android não oficial do GTA IV via recompilação estática da '
          'versão Xbox 360. Controles touch customizáveis, suporte a controle '
          'e ajustes gráficos.',
      license: 'GPL-3.0 (motor) + jogo comercial',
      source: PcPortSource.githubRelease,
      githubRepo: 'XHYN-PH/XHYN-IV-recomp',
      apkAssetPrefix: 'XHYN-IV-',
      apkAssetSuffix: '.apk',
      requiresGameFiles:
          'Requer os arquivos do GTA IV de Xbox 360 (USA) + Title Update 8, '
          'copiados para a pasta do port. Sem o dump o jogo não inicia.',
      archNote:
          'APK ~112 MB. Exige Vulkan e ~8 GB livres; espere 15–25 fps em '
          'Snapdragon 8 Gen 2 / Adreno 740 com Turnip.',
      minRamMb: 8192,
    ),
    PcPortEntry(
      id: 'gow-hd-collection',
      title: 'God of War HD Collection',
      developer: 'luisxl15 / comunidade',
      genre: 'Hack and slash / Ação',
      description:
          'Port Android não oficial da God of War Collection (God of War I e '
          'II em HD), com renderização nativa GLES/Vulkan e controle suportado. '
          'Release atual é demonstração (v0.1.2).',
      license: 'Demo comunitária',
      source: PcPortSource.githubRelease,
      githubRepo: 'luisxl15/GOD-OF-WAR-HD-COLLECTION-ANDROID-PORT',
      apkAssetPrefix: 'GodOfWarCollection-Android-',
      apkAssetSuffix: '.apk',
      requiresGameFiles:
          'Além do APK, baixe na página de releases os pacotes de dados '
          '(dados__gow-01.bin ~2 GB, dados__gow-02.bin, dados__manifesto.bin) e '
          'o opcional de texturas HD (~1.7 GB), e coloque na pasta de dados do '
          'app mantendo os nomes. Sem os pacotes só roda o menu.',
      extraAssetPrefixes: ['dados__'],
      archNote:
          'APK ~32 MB + ~2 GB de dados obrigatórios. Demo: só o início do '
          'jogo é jogável nesta versão.',
      minRamMb: 4096,
    ),
    PcPortEntry(
      id: 'cubeevil4',
      title: 'CubeEvil4 (Resident Evil 4)',
      developer: 'Andiweli / adonis-singh',
      genre: 'Survival horror',
      description:
          'Port nativo Android do protótipo de GameCube de Resident Evil 4 '
          '(build de debug G4BE08, nov/2004), derivado da decompilação '
          'byte-idêntica. OpenGL ES 3 e Vulkan, suporte a controle.',
      license: 'Decompilação (uso pessoal)',
      source: PcPortSource.githubRelease,
      githubRepo: 'Andiweli/CubeEvil4-Android',
      apkAssetPrefix: 'CubeEvil4-',
      apkAssetSuffix: '.apk',
      requiresGameFiles:
          'Requer o dump de GameCube da build G4BE08 (nov/2004) do seu próprio '
          'disco, convertido para a pasta de dados do port. Sem o dump o app '
          'não passa da tela inicial.',
      archNote: 'APK ~24 MB. OpenGL ES 3.2 mínimo; Vulkan recomendado.',
      minRamMb: 4096,
    ),
    PcPortEntry(
      id: 'luanti',
      title: 'Luanti',
      developer: 'Luanti Contributors',
      genre: 'Sandbox / Minecraft-like',
      description:
          'Motor de voxel open-source (ex-Minetest). '
          'Mundos infinitos gerados proceduralmente, mods via Lua e '
          'servidores multiplayer. Port oficial de PC.',
      license: 'LGPL-2.1',
      source: PcPortSource.githubRelease,
      githubRepo: 'luanti-org/luanti',
      apkAssetPrefix: 'luanti-',
      apkAssetSuffix: '-arm64-v8a.apk',
      archNote: 'APK arm64-v8a (maioria dos celulares modernos).',
      minRamMb: 1024,
    ),
    PcPortEntry(
      id: 'unciv',
      title: 'Unciv',
      developer: 'yairm210',
      genre: '4X / Civilization-like',
      description:
          'Clone open-source de Civilization V feito em Kotlin. Turnos, '
          'tecnologia, cidades, diplomacia e mods. APK universal.',
      license: 'Apache-2.0',
      source: PcPortSource.githubRelease,
      githubRepo: 'yairm210/Unciv',
      apkAssetPrefix: 'Unciv-signed',
      apkAssetSuffix: '.apk',
      minRamMb: 512,
    ),
    PcPortEntry(
      id: 'supertux',
      title: 'SuperTux',
      developer: 'SuperTux Team',
      genre: 'Plataforma 2D',
      description:
          'Joguinho de plataforma 2D livre (estilo Mario) com física, '
          'inimigos e fases. Projeto clássico do mundo open-source.',
      license: 'GPL-3.0',
      source: PcPortSource.githubRelease,
      githubRepo: 'SuperTux/supertux',
      apkAssetPrefix: 'SuperTux-',
      apkAssetSuffix: '-arm64-v8a.apk',
      archNote: 'APK arm64-v8a.',
      minRamMb: 256,
    ),
    PcPortEntry(
      id: 'openrct2',
      title: 'OpenRCT2',
      developer: 'OpenRCT2 Team',
      genre: 'Tycoon / RollerCoaster',
      description:
          'Reimplementação open-source do RollerCoaster Tycoon 2. '
          'Requer os arquivos do RCT2 original (você deve possuir o jogo de PC).',
      license: 'GPL-3.0',
      source: PcPortSource.githubRelease,
      githubRepo: 'OpenRCT2/OpenRCT2',
      apkAssetPrefix: 'OpenRCT2-',
      apkAssetSuffix: '-android.apk',
      archNote:
          'Requer arquivos do RCT2 (objetos, sons, música) importados '
          'manualmente — o APK sozinho não contém o jogo completo.',
      minRamMb: 1024,
    ),
    PcPortEntry(
      id: 'scummvm',
      title: 'ScummVM',
      developer: 'ScummVM Team',
      genre: 'Aventuras gráficas',
      description:
          'Motor open-source que roda centenas de point-and-click clássicos '
          '(Monkey Island, Beneath a Steel Sky, Day of the Tentacle etc.). '
          'Muitos jogos são freeware/shareware e podem ser baixados '
          'legalmente.',
      license: 'GPL-2.0',
      source: PcPortSource.external,
      externalUrl: 'https://f-droid.org/packages/org.scummvm.scummvm/',
      externalLabel: 'Baixar no F-Droid',
      archNote: 'F-Droid distribui APKs assinados para todas as arquiteturas.',
      minRamMb: 256,
    ),
    PcPortEntry(
      id: 'wesnoth',
      title: 'Battle for Wesnoth',
      developer: 'Wesnoth Team',
      genre: 'Estratégia por turnos',
      description:
          'Jogo de estratégia tático open-source com campanhas, '
          'multiplayer e centenas de unidades. Um dos maiores jogos '
          'livres do mundo.',
      license: 'GPL-2.0',
      source: PcPortSource.external,
      externalUrl: 'https://f-droid.org/packages/org.wesnoth.wesnoth/',
      externalLabel: 'Baixar no F-Droid',
      minRamMb: 512,
    ),
    PcPortEntry(
      id: 'supertuxkart',
      title: 'SuperTuxKart',
      developer: 'SuperTuxKart Team',
      genre: 'Corrida / Kart',
      description:
          'Corrida de karts open-source (estilo Mario Kart) com '
          'personagens, pistas e itens. Gratuito e multiplataforma.',
      license: 'GPL-3.0',
      source: PcPortSource.external,
      externalUrl: 'https://f-droid.org/packages/org.supertuxkart/',
      externalLabel: 'Baixar no F-Droid',
      minRamMb: 1024,
    ),
    PcPortEntry(
      id: 'cuphead-mobile',
      title: 'Cuphead',
      developer: 'Studio MDHR (Port Mobile)',
      genre: 'Run and Gun / Boss Rush',
      description:
          'Port não oficial completo para Android com batalhas de chefes, '
          'animações clássicas estilo anos 30 e controles touch/gamepad.',
      license: 'Port Android APK (238 MB)',
      source: PcPortSource.directApk,
      directApkUrl:
          'https://archive.org/download/cuphead-mobile-v-0.6.1/Cuphead%20Mobile%20v0.6.1.apk',
      archNote: 'APK Android direto via Internet Archive (~238 MB).',
      minRamMb: 2048,
    ),
    PcPortEntry(
      id: 'hollow-knight-vulkan',
      title: 'Hollow Knight (Port Mobile Vulkan)',
      developer: 'Team Cherry (Port Android)',
      genre: 'Metroidvania / Ação',
      description:
          'Port completo de Android (Vulkan) de Hollow Knight com suporte nativo '
          'a controle Bluetooth/USB e resolução em tela cheia.',
      license: 'Port Android APK (931 MB)',
      source: PcPortSource.directApk,
      directApkUrl:
          'https://archive.org/download/hollow-knight-android/Hollow_Knight_22.10.2022_Vulkan.apk',
      archNote: 'APK Android Vulkan direto via Internet Archive (~931 MB).',
      minRamMb: 3072,
    ),
    PcPortEntry(
      id: 'hollow-knight-silksong',
      title: 'Hollow Knight: Silksong',
      developer: 'Team Cherry',
      genre: 'Metroidvania / Ação',
      description:
          'Sequência oficial de Hollow Knight protagonizada por Hornet. '
          'Título nativo de PC/Consoles sem versão de emulador Android; '
          'abra a página oficial para acompanhar lançamentos.',
      license: 'Comercial (Team Cherry)',
      source: PcPortSource.external,
      externalUrl:
          'https://store.steampowered.com/app/1030300/Hollow_Knight_Silksong/',
      externalLabel: 'Abrir página oficial (Steam)',
      minRamMb: 4096,
    ),
    PcPortEntry(
      id: 'hollow-knight',
      title: 'Hollow Knight (Play Store)',
      developer: 'Team Cherry',
      genre: 'Metroidvania / Ação',
      description:
          'Página oficial de Hollow Knight na loja. '
          'Este atalho abre a loja oficial do desenvolvedor.',
      license: 'Comercial (Team Cherry)',
      source: PcPortSource.external,
      externalUrl:
          'https://play.google.com/store/apps/details?id=com.teamcherry.hollowknight',
      externalLabel: 'Abrir na Play Store',
      minRamMb: 2048,
    ),
  ];
}
