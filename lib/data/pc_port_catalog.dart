import '../models/pc_port.dart';

/// Catálogo curado de ports de PC gratuitos/legalmente distribuíveis para
/// Android. Todos os APKs apontam para fontes oficiais (GitHub Releases dos
/// próprios projetos ou lojas oficiais).
///
/// Jogos comerciais (ex.: Hollow Knight) não são distribuídos aqui — usamos
/// apenas o link oficial da loja, respeitando a compra do usuário.
class PcPortCatalog {
  PcPortCatalog._();

  static const List<PcPortEntry> entries = [
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
