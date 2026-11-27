/// Port oficial de jogo de PC para Android distribuído de forma legal
/// (open-source, freeware ou link oficial da loja).
///
/// Diferente dos ROMs, estes itens são APKs instaláveis diretamente pelo
/// sistema Android — nenhum emulador é necessário.
class PcPortEntry {
  const PcPortEntry({
    required this.id,
    required this.title,
    required this.developer,
    required this.genre,
    required this.description,
    required this.license,
    required this.source,
    this.githubRepo,
    this.apkAssetPrefix,
    this.apkAssetSuffix,
    this.directApkUrl,
    this.externalUrl,
    this.externalLabel,
    this.archNote,
    this.requiresGameFiles,
    this.extraAssetPrefixes = const <String>[],
    this.minRamMb = 0,
  });

  final String id;
  final String title;
  final String developer;
  final String genre;
  final String description;
  final String license;

  /// Como o item é obtido.
  final PcPortSource source;

  /// `owner/repo` no GitHub quando [source] é [PcPortSource.githubRelease].
  final String? githubRepo;

  /// Prefixo do nome do asset APK no release (ex.: `luanti-`).
  final String? apkAssetPrefix;

  /// Sufixo do nome do asset APK (ex.: `-arm64-v8a.apk`).
  final String? apkAssetSuffix;

  /// URL direta do APK quando [source] é [PcPortSource.directApk].
  final String? directApkUrl;

  /// URL externa (Play Store, F-Droid, site oficial) para abrir no navegador.
  final String? externalUrl;
  final String? externalLabel;

  /// Aviso de arquitetura/requisito exibido ao usuário.
  final String? archNote;

  /// Arquivos originais que o port exige (dump do próprio usuário). Quando
  /// preenchido, o cartão exibe um aviso destacado — o APK sozinho não roda.
  final String? requiresGameFiles;

  /// Prefixos de assets extras (pacotes de dados) publicados no mesmo release
  /// do APK. Baixados para `<docs>/pc_ports/<id>_data/` com o nome original.
  final List<String> extraAssetPrefixes;

  final int minRamMb;

  /// Página de releases no GitHub (todos os assets, não só o APK).
  String? get releasesPageUrl =>
      githubRepo == null ? null : 'https://github.com/$githubRepo/releases';

  /// Há download direto dentro do app (APK via release ou URL fixa).
  bool get hasDirectDownload =>
      source == PcPortSource.githubRelease || source == PcPortSource.directApk;
}

enum PcPortSource {
  /// APK resolvido do release mais recente de um repo GitHub.
  githubRelease,

  /// URL direta e estável para o APK.
  directApk,

  /// Não há download direto — abre link oficial (loja/site do dev).
  external,
}
