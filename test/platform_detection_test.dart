import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/services/rom_download_service.dart';
import 'package:loopgamer/services/rom_platform_detector.dart';

File _writeImage(
  Directory dir,
  String name,
  Map<int, String> markers, {
  int size = 8 * 1024,
}) {
  final bytes = Uint8List(size);
  markers.forEach((offset, marker) {
    bytes.setAll(offset, ascii.encode(marker));
  });
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(bytes);
  return file;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('loopgamer_platform_detect');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('RomPlatformDetector.fromExtension', () {
    test('extensões exclusivas apontam para o console certo', () {
      expect(RomPlatformDetector.fromExtension('game.gba'), 'gba');
      expect(RomPlatformDetector.fromExtension('game.nes'), 'nes');
      expect(RomPlatformDetector.fromExtension('z64game.z64'), 'n64');
      expect(RomPlatformDetector.fromExtension('disc.rvz'), 'gamecube');
      expect(RomPlatformDetector.fromExtension('disc.wbfs'), 'wii');
      expect(RomPlatformDetector.fromExtension('game.cso'), 'psp');
      expect(RomPlatformDetector.fromExtension('game.pbp'), 'psp');
      expect(RomPlatformDetector.fromExtension('game.cdi'), 'dreamcast');
      expect(RomPlatformDetector.fromExtension('game.gdi'), 'dreamcast');
      expect(RomPlatformDetector.fromExtension('game.pkg'), 'ps3');
    });

    test('extensões ambíguas NÃO caem em fallback ps2', () {
      const ambiguous = [
        'jogo.iso',
        'jogo.chd',
        'jogo.cue',
        'jogo.bin',
        'jogo.img',
        'jogo.isz',
        'pacote.zip',
        'arquivo.qualquer',
      ];
      for (final name in ambiguous) {
        expect(
          RomPlatformDetector.fromExtension(name),
          isNull,
          reason: '$name não deve assumir plataforma',
        );
      }
    });
  });

  group('RomPlatformDetector.fromFileName', () {
    test('seriais Sony separam PS1 (0xxxx) de PS2 (2xxxx/5xxxx)', () {
      expect(
        RomPlatformDetector.fromFileName(
          'Ace Combat - Shattered Skies (USA) (SLUS-20159).chd',
        ),
        'ps2',
      );
      expect(
        RomPlatformDetector.fromFileName('Gran Turismo 3 (SLUS_202.99).iso'),
        'ps2',
      );
      expect(
        RomPlatformDetector.fromFileName(
          'Final Fantasy VII (USA) (SLUS-00001).chd',
        ),
        'ps1',
      );
      expect(
        RomPlatformDetector.fromFileName('Street Fighter EX3 (SLUS_015.23).iso'),
        'ps1',
      );
    });

    test('tokens de console no nome e no caminho', () {
      expect(
        RomPlatformDetector.fromFileName(
          'Harry Potter e o Calice de Fogo (PS2).iso',
        ),
        'ps2',
      );
      expect(RomPlatformDetector.fromFileName('/sdcard/PS2/game.iso'), 'ps2');
      expect(RomPlatformDetector.fromFileName('Wii Sports (USA).rvz'), 'wii');
      expect(
        RomPlatformDetector.fromFileName('Resident Evil 2 (PSX).cue'),
        'ps1',
      );
      expect(RomPlatformDetector.fromFileName('God of War (PSP).iso'), 'psp');
    });

    test('sem pistas confiáveis retorna null', () {
      expect(
        RomPlatformDetector.fromFileName(
          'Resident Evil - Code Veronica (USA).chd',
        ),
        isNull,
      );
      expect(RomPlatformDetector.fromFileName('sonic.bin'), isNull);
    });
  });

  group('RomPlatformDetector.sniffContent', () {
    test('ISO PS2 é reconhecido por BOOT2 mesmo com "PLAYSTATION" no PVD', () async {
      final iso = _writeImage(
        tmp,
        'ps2.iso',
        {
          0x8000: 'PLAYSTATION',
          128 * 1024: 'BOOT2 = cdrom0:\\SLUS_202.99;1',
        },
        size: 256 * 1024,
      );
      expect(await RomPlatformDetector.sniffContent(iso.path), 'ps2');
    });

    test('ISO PS1 é reconhecido por PS-X EXE e por SYSTEM.CNF com BOOT =', () async {
      final withExe = _writeImage(tmp, 'ps1_exe.iso', {
        0x8000: 'PLAYSTATION',
        64 * 1024: 'PS-X EXE',
      }, size: 128 * 1024);
      expect(await RomPlatformDetector.sniffContent(withExe.path), 'ps1');

      final withSystemCnf = _writeImage(tmp, 'ps1_boot.iso', {
        0x8000: 'PLAYSTATION',
        64 * 1024: 'BOOT = cdrom0:\\SLUS_005.64;1',
      }, size: 128 * 1024);
      expect(await RomPlatformDetector.sniffContent(withSystemCnf.path), 'ps1');
    });

    test('PSP, Saturn, Dreamcast e Mega Drive têm marcadores próprios', () async {
      final psp = _writeImage(tmp, 'psp.iso', {32 * 1024: 'PSP_GAME'},
          size: 64 * 1024);
      expect(await RomPlatformDetector.sniffContent(psp.path), 'psp');

      final saturn = _writeImage(tmp, 'saturn.bin', {0: 'SEGA SEGASATURN'});
      expect(await RomPlatformDetector.sniffContent(saturn.path), 'saturn');

      final dc = _writeImage(tmp, 'dc.bin', {0: 'SEGA SEGAKATANA'});
      expect(await RomPlatformDetector.sniffContent(dc.path), 'dreamcast');

      final md = _writeImage(tmp, 'md.bin', {0x100: 'SEGA MEGA DRIVE'});
      expect(await RomPlatformDetector.sniffContent(md.path), 'md');
    });

    test('GameCube e Wii são reconhecidos pelo magic do cabeçalho', () async {
      final gcBytes = Uint8List(4096);
      gcBytes[0x1C] = 0xC2;
      gcBytes[0x1D] = 0x33;
      gcBytes[0x1E] = 0x9F;
      gcBytes[0x1F] = 0x3D;
      final gc = File('${tmp.path}/game.gcm')..writeAsBytesSync(gcBytes);
      expect(await RomPlatformDetector.sniffContent(gc.path), 'gamecube');

      final wiiBytes = Uint8List(4096);
      wiiBytes[0x18] = 0x5D;
      wiiBytes[0x19] = 0x1C;
      wiiBytes[0x1A] = 0x9E;
      wiiBytes[0x1B] = 0xA3;
      final wii = File('${tmp.path}/game_wii.iso')..writeAsBytesSync(wiiBytes);
      expect(await RomPlatformDetector.sniffContent(wii.path), 'wii');
    });

    test('.cue segue o FILE apontado e sniffa o .bin irmão', () async {
      _writeImage(tmp, 'jogo.bin', {40 * 1024: 'PS-X EXE'}, size: 128 * 1024);
      final cue = File('${tmp.path}/jogo.cue')
        ..writeAsStringSync(
          'FILE "jogo.bin" BINARY\n'
          '  TRACK 01 MODE2/2352\n'
          '    INDEX 01 00:00:00\n',
        );
      expect(await RomPlatformDetector.sniffContent(cue.path), 'ps1');
    });

    test('formatos opacos (.chd/.cso/.pbp) não têm leitura de conteúdo', () async {
      final chd = _writeImage(tmp, 'jogo.chd', {
        0: 'MComprHD',
        1024: 'BOOT2 = cdrom0:\\SLUS_202.99;1',
      });
      expect(await RomPlatformDetector.sniffContent(chd.path), isNull);
    });

    test('imagem sem marcadores conhecidos retorna null', () async {
      final unknown = _writeImage(tmp, 'aleatorio.iso', {0: 'QUALQUERCOISA'});
      expect(await RomPlatformDetector.sniffContent(unknown.path), isNull);
    });
  });

  group('RomPlatformDetector.detect', () {
    test('conteúdo do arquivo vence extensão e nome', () async {
      final iso = _writeImage(tmp, 'inuyasha.iso', {
        128 * 1024: 'BOOT2 = cdrom0:\\SLUS_202.01;1',
      }, size: 256 * 1024);
      final detection = await RomPlatformDetector.detect(
        'inuyasha.iso',
        filePath: iso.path,
      );
      expect(detection?.slug, 'ps2');
      expect(detection?.source, RomDetectionSource.content);
      expect(detection?.sourceLabel, 'conteúdo do arquivo');
    });

    test('nome do arquivo vence extensão ambígua', () async {
      final detection = await RomPlatformDetector.detect(
        'Final Fantasy VII (SLUS-00001).pbp',
      );
      expect(detection?.slug, 'ps1');
      expect(detection?.source, RomDetectionSource.fileName);
    });

    test('extensão exclusiva é usada quando não há outras pistas', () async {
      final detection = await RomPlatformDetector.detect('metroid.gba');
      expect(detection?.slug, 'gba');
      expect(detection?.source, RomDetectionSource.extension);
    });

    test('sem nenhuma pista confiável retorna null (escolha manual)', () async {
      final iso = _writeImage(tmp, 'aleatorio2.iso', {0: 'XYZ'});
      expect(
        await RomPlatformDetector.detect('aleatorio2.iso', filePath: iso.path),
        isNull,
      );
      expect(await RomPlatformDetector.detect('aleatorio.chd'), isNull);
      expect(await RomPlatformDetector.detect('aleatorio.cue'), isNull);
      expect(await RomPlatformDetector.detect('aleatorio.bin'), isNull);
    });
  });

  group('RomPlatformDetector.fromSize', () {
    test('estima PS1/PS2 pelo tamanho como último recurso', () {
      expect(RomPlatformDetector.fromSize(700 * 1024 * 1024), 'ps1');
      expect(RomPlatformDetector.fromSize(950 * 1024 * 1024), 'ps2');
      expect(RomPlatformDetector.fromSize(40 * 1024 * 1024), isNull);
      expect(RomPlatformDetector.fromSize(0), isNull);
    });
  });

  group('RomDownloadService.isImportExtensionCompatible', () {
    test('aceita formatos reais de ISO local por plataforma', () {
      expect(
        RomDownloadService.isImportExtensionCompatible('ps1', 'jogo.cue'),
        isTrue,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('ps1', 'jogo.bin'),
        isTrue,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('ps2', 'jogo.iso'),
        isTrue,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('saturn', 'jogo.chd'),
        isTrue,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('dreamcast', 'jogo.cdi'),
        isTrue,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('3ds', 'jogo.cia'),
        isTrue,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('pce', 'jogo.chd'),
        isTrue,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('md', 'jogo.bin'),
        isTrue,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('mame', 'romset.zip'),
        isTrue,
      );
    });

    test('bloqueia extensões que não pertencem à plataforma', () {
      expect(
        RomDownloadService.isImportExtensionCompatible('ps2', 'jogo.gba'),
        isFalse,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('gba', 'jogo.chd'),
        isFalse,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('ps1', 'jogo.wbfs'),
        isFalse,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('snes', 'jogo.iso'),
        isFalse,
      );
      expect(
        RomDownloadService.isImportExtensionCompatible('ps1', 'jogo.txt'),
        isFalse,
      );
    });

    test('importExtensionsForPlatform cobre cue/bin/img além da lista base', () {
      final ps1Exts = RomDownloadService.importExtensionsForPlatform('ps1');
      expect(ps1Exts, containsAll(<String>['.chd', '.pbp', '.iso', '.cue', '.bin']));

      final ps2Exts = RomDownloadService.importExtensionsForPlatform('ps2');
      expect(ps2Exts, containsAll(<String>['.chd', '.iso', '.cue', '.bin']));
    });
  });
}
