import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/data/pc_port_catalog.dart';
import 'package:loopgamer/models/pc_port.dart';
import 'package:loopgamer/services/pc_port_service.dart';
import 'package:loopgamer/services/rom_platform_detector.dart';

void main() {
  group('Catálogo de ports nativos', () {
    test('inclui os quatro ports de jogos 3D recentes', () {
      final ids = PcPortCatalog.entries.map((e) => e.id).toSet();
      expect(ids, contains('openbonk'));
      expect(ids, contains('xhyn-iv-recomp'));
      expect(ids, contains('gow-hd-collection'));
      expect(ids, contains('cubeevil4'));
    });

    test('ids são únicos', () {
      final ids = PcPortCatalog.entries.map((e) => e.id).toList();
      expect(ids.length, ids.toSet().length);
    });

    test('todo item tem exatamente uma forma de obtenção', () {
      for (final entry in PcPortCatalog.entries) {
        expect(
          entry.hasDirectDownload || entry.externalUrl != null,
          isTrue,
          reason: '${entry.id} não é obtível de nenhuma forma',
        );
        if (entry.source == PcPortSource.githubRelease) {
          expect(entry.githubRepo, isNotNull, reason: entry.id);
          expect(entry.releasesPageUrl,
              'https://github.com/${entry.githubRepo}/releases');
        }
      }
    });

    test('prefixo/sufixo casa com os assets reais dos releases', () {
      // Nomes publicados hoje nos releases oficiais (checados via API).
      const published = <String, List<String>>{
        'openbonk': ['OpenBonk.apk'],
        'xhyn-iv-recomp': [
          'SHA256SUMS.txt',
          'XHYN-IV-0.9.24-xhyn-base-english-test2.apk',
          'XHYN-IV-0.9.24-xhyn-base-english-test2.verification.json',
        ],
        'gow-hd-collection': [
          'GodOfWarCollection-Android-v0.1.2.apk',
          'dados__gow-01.bin',
        ],
        'cubeevil4': ['CubeEvil4-1.1.6-Android.apk'],
      };

      for (final entry in PcPortCatalog.entries) {
        final assets = published[entry.id];
        if (assets == null) continue;
        final matches = assets.where(
          (name) =>
              name.startsWith(entry.apkAssetPrefix ?? '') &&
              name.endsWith(entry.apkAssetSuffix ?? '.apk'),
        );
        expect(matches, isNotEmpty,
            reason: '${entry.id}: nenhum APK casa com o filtro do catálogo');
        expect(
          matches.every((name) => name.toLowerCase().endsWith('.apk')),
          isTrue,
          reason: '${entry.id}: filtro aceitou asset que não é APK',
        );
      }
    });

    test('ports que exigem dump declaram requiresGameFiles', () {
      for (final id in const [
        'openbonk',
        'xhyn-iv-recomp',
        'gow-hd-collection',
        'cubeevil4',
      ]) {
        final entry = PcPortCatalog.entries.firstWhere((e) => e.id == id);
        expect(entry.requiresGameFiles, isNotNull, reason: id);
        expect(entry.requiresGameFiles!.isNotEmpty, isTrue, reason: id);
      }
    });

    test('God of War declara os pacotes de dados obrigatórios', () {
      final gow = PcPortCatalog.entries
          .firstWhere((e) => e.id == 'gow-hd-collection');
      expect(gow.extraAssetPrefixes, contains('dados__'));
      expect(
        PcPortService.entryPrefixesMatch(gow.extraAssetPrefixes,
            'dados__gow-01.bin'),
        isTrue,
      );
      expect(
        PcPortService.entryPrefixesMatch(gow.extraAssetPrefixes,
            'opcional-texturas_hd__gow-01.bin'),
        isFalse,
      );
    });
  });

  group('Detecção de ISO grande', () {
    const gb = 1024 * 1024 * 1024;

    test('ISO acima de 10 GB é PS3, não PS2', () {
      expect(RomPlatformDetector.fromSize(20 * gb), 'ps3');
      expect(RomPlatformDetector.fromSize(50 * gb), 'ps3');
    });

    test('DVD de PS2 permanece PS2', () {
      expect(RomPlatformDetector.fromSize(900 * 1024 * 1024 + 1), 'ps2');
      expect(RomPlatformDetector.fromSize(8 * gb), 'ps2');
    });

    test('CD de PS1 e tamanhos inválidos permanecem como antes', () {
      expect(RomPlatformDetector.fromSize(700 * 1024 * 1024), 'ps1');
      expect(RomPlatformDetector.fromSize(0), isNull);
      expect(RomPlatformDetector.fromSize(-1), isNull);
    });
  });
}
