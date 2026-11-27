import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/services/update_service.dart';

void main() {
  group('UpdateService — parsing e comparação de versões', () {
    test('extrai versão de tags com prefixo e sufixo', () {
      expect(UpdateService.versionFromTag('v2.7.1'), '2.7.1');
      expect(UpdateService.versionFromTag('release-2.7.1+build'), '2.7.1');
      expect(UpdateService.versionFromTag('2.6.0'), '2.6.0');
      expect(UpdateService.versionFromTag('sem-versao'), isNull);
    });

    test('detecta 2.7.1 como mais novo que 2.7.0 e 2.6.0', () {
      expect(UpdateService.compareVersions('2.7.1', '2.7.0'), greaterThan(0));
      expect(UpdateService.compareVersions('2.7.0', '2.6.0'), greaterThan(0));
      expect(UpdateService.compareVersions('2.6.0', '2.7.0'), lessThan(0));
      expect(UpdateService.compareVersions('2.7.0', '2.7.0'), 0);
    });

    test('compara componentes ausentes como zero', () {
      expect(UpdateService.compareVersions('2.7', '2.7.0'), 0);
      expect(UpdateService.compareVersions('2.7.0.1', '2.7.0'), greaterThan(0));
    });

    test('UpdateCheckResult.unknown não anuncia atualização', () {
      final result = UpdateCheckResult.unknown(error: 'offline');
      expect(result.hasUpdate, isFalse);
      expect(result.apkUrl, isNull);
      expect(result.error, 'offline');
    });

    test('UpdateState preserva versão dispensada e última checagem', () {
      const state = UpdateState(
        lastCheckMs: 1700000000000,
        lastPromptMs: 1700000600000,
        dismissedVersion: '2.7.0',
        lastKnownVersion: '2.7.1',
      );
      final json = state.toJson();
      final restored = UpdateState.fromJson(json);
      expect(restored.lastCheckMs, 1700000000000);
      expect(restored.lastPromptMs, 1700000600000);
      expect(restored.dismissedVersion, '2.7.0');
      expect(restored.lastKnownVersion, '2.7.1');
    });

    test('UpdateState aceita JSON parcial sem quebrar', () {
      final restored = UpdateState.fromJson(<String, dynamic>{
        'last_check_ms': 'invalido',
        'dismissed_version': '2.7.0',
      });
      expect(restored.lastCheckMs, isNull);
      expect(restored.dismissedVersion, '2.7.0');
    });
  });
}
