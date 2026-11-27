/// Port Android publicado no APKVision, com APK e/ou pacote de dados
/// (`.7z`, `.zip`, `.rar`, `.iso`, ...) hospedado no CDN do próprio site.
///
/// Estes itens não passam pelo catálogo curado de ports open-source: são
/// ports prontos para instalar, com a página oficial mantida pelo site.
class ApkVisionPortEntry {
  const ApkVisionPortEntry({
    required this.id,
    required this.title,
    required this.version,
    required this.category,
    required this.pageUrl,
    required this.dataKind,
    required this.note,
    this.apkUrl,
    this.dataUrl,
  });

  final String id;
  final String title;
  final String version;
  final String category;
  final String pageUrl;
  final String? apkUrl;
  final String? dataUrl;
  final ApkVisionArchiveKind dataKind;
  final String note;

  bool get hasApk => apkUrl != null && apkUrl!.isNotEmpty;
  bool get hasData => dataUrl != null && dataUrl!.isNotEmpty;

  String get dataLabel => switch (dataKind) {
        ApkVisionArchiveKind.sevenZ => '7Z',
        ApkVisionArchiveKind.zip => 'ZIP',
        ApkVisionArchiveKind.rar => 'RAR',
        ApkVisionArchiveKind.iso => 'ISO',
        ApkVisionArchiveKind.rvz => 'RVZ',
        ApkVisionArchiveKind.obb => 'OBB',
        ApkVisionArchiveKind.romfs => 'ROMFS',
        ApkVisionArchiveKind.tarXz => 'TAR.XZ',
        ApkVisionArchiveKind.exe => 'EXE',
        ApkVisionArchiveKind.none => 'SEM DADOS',
      };

  String get dataFileName {
    if (!hasData) return '';
    final path = Uri.parse(dataUrl!).path;
    final name = path.split('/').last;
    return name.isEmpty ? 'game-data' : name;
  }
}

enum ApkVisionArchiveKind {
  none,
  sevenZ,
  zip,
  rar,
  iso,
  rvz,
  obb,
  romfs,
  tarXz,
  exe,
}
