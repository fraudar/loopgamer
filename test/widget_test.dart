import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/main.dart';
import 'package:loopgamer/screens/home_screen.dart';
import 'package:loopgamer/widgets/animated_game_logo.dart';

void main() {
  testWidgets('LoopGamer GameHub Horizontal Console-First smoke test', (
    WidgetTester tester,
  ) async {
    // Modo Horizontal Exclusivo (Landscape Console-First - 915x412)
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LoopGamerApp());
    expect(find.text('LOOPGAMER'), findsOneWidget);
    expect(find.text('Destaques da Coleção'), findsOneWidget);
    expect(find.byType(AnimatedGameLogo), findsAtLeastNWidgets(1));
    expect(find.byType(AnimatedPositioned), findsAtLeastNWidgets(1));

    final homeVerticalScrollable = find
        .descendant(
          of: find.byType(HomeScreen),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Continuar jogando'),
      180,
      scrollable: homeVerticalScrollable,
    );
    expect(find.text('Continuar jogando'), findsOneWidget);
    expect(find.text('Nenhum jogo em andamento'), findsOneWidget);

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

    await tester.tap(find.text('Início'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('LOOPGAMER'),
      -200,
      scrollable: homeVerticalScrollable,
    );
    final title = tester.widget<Text>(find.text('LOOPGAMER'));
    expect(title.style?.fontFamily, 'PressStart2P');
  });
}
