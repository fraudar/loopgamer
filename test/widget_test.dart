import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/main.dart';
import 'package:loopgamer/screens/home_screen.dart';

void main() {
  testWidgets('LoopGamer GameHub Portrait & Landscape smoke test', (
    WidgetTester tester,
  ) async {
    // 1. Testa Modo Deitado (Landscape - 915x412)
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LoopGamerApp());
    expect(find.text('LOOPGAMER'), findsOneWidget);
    expect(find.text('Destaques da Coleção'), findsOneWidget);
    expect(find.text('Continuar jogando'), findsOneWidget);

    final homeVerticalScrollable = find
        .descendant(
          of: find.byType(HomeScreen),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Catálogo por Console'),
      200,
      scrollable: homeVerticalScrollable,
    );
    expect(find.text('Catálogo por Console'), findsOneWidget);

    expect(find.text('Início'), findsOneWidget);
    expect(find.text('ROMs'), findsOneWidget);
    expect(find.text('Biblioteca'), findsOneWidget);
    expect(find.text('Ajustes'), findsOneWidget);
    expect(find.bySemanticsLabel('Wi-Fi conectado'), findsOneWidget);
    expect(find.bySemanticsLabel('Buscar ROMs'), findsOneWidget);
    expect(find.bySemanticsLabel('Abrir Biblioteca'), findsAtLeastNWidgets(1));

    // Navega pelas abas em Landscape
    await tester.tap(find.text('ROMs'));
    await tester.pump();
    expect(find.text('Catálogo de ROMs'), findsOneWidget);

    await tester.tap(find.text('Biblioteca'));
    await tester.pump();
    expect(find.text('Nenhum jogo instalado ainda'), findsOneWidget);

    await tester.tap(find.text('Ajustes'));
    await tester.pump();
    expect(find.text('Configurações'), findsOneWidget);

    // 2. Gira para Modo em Pé (Portrait - 412x915)
    tester.view.physicalSize = const Size(412, 915);
    await tester.pump();

    await tester.tap(find.text('Início'));
    await tester.pump();
    expect(find.text('Encontre seu jogo...'), findsOneWidget);
    expect(find.text('Player Rating'), findsOneWidget);
    final portraitTitle = tester.widget<Text>(find.text('LOOPGAMER'));
    expect(portraitTitle.style?.fontFamily, 'PressStart2P');
  });
}
