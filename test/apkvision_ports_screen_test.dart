import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/screens/pc_ports_screen.dart';

void main() {
  testWidgets('PcPortsScreen abre aba APKVision e mostra filtros de arquivo',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: PcPortsScreen()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Catálogo'), findsOneWidget);
    expect(find.text('APKVision'), findsOneWidget);

    await tester.tap(find.text('APKVision'));
    await tester.pumpAndSettle();

    expect(find.text('7Z'), findsOneWidget);
    expect(find.text('ZIP'), findsOneWidget);
    expect(find.text('RAR'), findsOneWidget);
    expect(find.text('ISO'), findsOneWidget);
    expect(find.text('Só APK'), findsOneWidget);
    expect(find.text('Alien Hominid HD'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('7Z'));
    await tester.pumpAndSettle();

    expect(find.text('Dark Souls 2: Scholar of the First Sin'), findsOneWidget);
    expect(find.text('Alien Hominid HD'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
