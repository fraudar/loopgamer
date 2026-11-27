import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/data/apkvision_offline_catalog.dart';
import 'package:loopgamer/models/apkvision_port.dart';

void main() {
  group('ApkVisionOfflineCatalog', () {
    test('catálogo da tag offline tem entradas válidas e únicas', () {
      expect(ApkVisionOfflineCatalog.entries.length, greaterThanOrEqualTo(70));

      final ids = ApkVisionOfflineCatalog.entries.map((e) => e.id).toSet();
      expect(ids.length, ApkVisionOfflineCatalog.entries.length);

      for (final entry in ApkVisionOfflineCatalog.entries) {
        expect(entry.title, isNotEmpty);
        expect(entry.version, isNotEmpty);
        expect(Uri.parse(entry.pageUrl).host, 'apkvision.org');
        if (entry.apkUrl != null) {
          expect(entry.apkUrl, startsWith('https://dl.apkvision'));
        }
        if (entry.dataUrl != null) {
          expect(entry.dataUrl, startsWith('https://dl.apkvision'));
          expect(entry.hasData, isTrue);
          expect(entry.dataFileName, isNotEmpty);
        }
      }
    });

    test('inclui NieR, Hollow Knight, Silksong e ports com 7z', () {
      final byId = {
        for (final entry in ApkVisionOfflineCatalog.entries) entry.id: entry,
      };

      final nier = byId['nier-136096'];
      expect(nier, isNotNull);
      expect(nier!.dataKind, ApkVisionArchiveKind.zip);
      expect(nier.dataUrl, contains('Nier-ISO-apkvision.zip'));

      final silksong = byId['hollow-knight-silksong-130787'];
      expect(silksong, isNotNull);
      expect(silksong!.hasApk, isTrue);
      expect(silksong.dataKind, ApkVisionArchiveKind.zip);

      final hollow = byId['hollow-knight-mobile-97647'];
      expect(hollow, isNotNull);
      expect(hollow!.hasApk, isTrue);
      expect(hollow.hasData, isFalse);

      final darkSouls2 =
          byId['dark-souls-2-scholar-of-the-first-sin-135960'];
      expect(darkSouls2, isNotNull);
      expect(darkSouls2!.dataKind, ApkVisionArchiveKind.sevenZ);
      expect(darkSouls2.dataLabel, '7Z');
    });

    test('filtro por tipo de arquivo devolve somente o tipo pedido', () {
      final sevenZ = ApkVisionOfflineCatalog.filter(
        kind: ApkVisionArchiveKind.sevenZ,
      );
      expect(sevenZ, isNotEmpty);
      expect(
        sevenZ.every((e) => e.dataKind == ApkVisionArchiveKind.sevenZ),
        isTrue,
      );

      final withData = ApkVisionOfflineCatalog.filter(onlyWithData: true);
      expect(withData, isNotEmpty);
      expect(withData.every((e) => e.hasData), isTrue);

      final nier = ApkVisionOfflineCatalog.filter(query: 'nier');
      expect(nier.length, 1);
      expect(nier.first.id, 'nier-136096');
    });

    test('dataFileName extrai o nome do arquivo da URL', () {
      final entry = ApkVisionOfflineCatalog.entries.firstWhere(
        (e) => e.id == 'nier-136096',
      );
      expect(entry.dataFileName, 'Nier-ISO-apkvision.zip');
    });
  });
}
