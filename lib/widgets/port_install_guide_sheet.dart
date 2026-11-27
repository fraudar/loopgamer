import 'package:flutter/material.dart';

import '../models/apkvision_port.dart';
import '../theme/ps5_hydra_theme.dart';

/// Guia pós-download: onde o arquivo caiu, o que extrair, o que apagar e
/// onde a pasta do jogo deve ficar antes de abrir o port.
class PortInstallGuideSheet extends StatelessWidget {
  const PortInstallGuideSheet({
    super.key,
    required this.entry,
    required this.portPath,
    required this.extracted,
    required this.onOpenFolder,
    required this.onCopyPath,
  });

  final ApkVisionPortEntry entry;
  final String portPath;
  final bool extracted;
  final Future<void> Function() onOpenFolder;
  final Future<void> Function() onCopyPath;

  bool get _isArchive =>
      entry.dataKind == ApkVisionArchiveKind.sevenZ ||
      entry.dataKind == ApkVisionArchiveKind.zip ||
      entry.dataKind == ApkVisionArchiveKind.rar ||
      entry.dataKind == ApkVisionArchiveKind.tarXz;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.folder_special_rounded,
                    size: 18,
                    color: Color(0xFFFFB454),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.title,
                      style: const TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: PS5HydraTheme.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    color: PS5HydraTheme.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'Onde o arquivo ficou',
                style: TextStyle(
                  fontFamily: 'ReadexPro',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: PS5HydraTheme.auroraSpringMint,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: PS5HydraTheme.borderSubtle),
                ),
                child: SelectableText(
                  portPath,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.4,
                    color: PS5HydraTheme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => onOpenFolder(),
                    icon: const Icon(Icons.folder_open_rounded, size: 15),
                    label: const Text('Abrir arquivos'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: PS5HydraTheme.textPrimary,
                      side: const BorderSide(color: PS5HydraTheme.borderSubtle),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => onCopyPath(),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('Copiar caminho'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: PS5HydraTheme.textPrimary,
                      side: const BorderSide(color: PS5HydraTheme.borderSubtle),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                extracted ? 'O que fazer agora' : 'Passo a passo',
                style: const TextStyle(
                  fontFamily: 'ReadexPro',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: PS5HydraTheme.auroraSpringMint,
                ),
              ),
              const SizedBox(height: 8),
              ..._steps().map(
                (step) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        margin: const EdgeInsets.only(top: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFB454).withOpacity(0.16),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${step.$1}',
                          style: const TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFFFB454),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              step.$2,
                              style: const TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: PS5HydraTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              step.$3,
                              style: const TextStyle(
                                fontFamily: 'Rubik',
                                fontSize: 11.5,
                                height: 1.45,
                                color: PS5HydraTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1E),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: PS5HydraTheme.borderSubtle),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: Color(0xFFFFB454),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Extraiu e o jogo abriu? O pacote original pode ser apagado — '
                        'deixe só a pasta game/. O APK instalado continua no sistema.',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 11.5,
                          height: 1.45,
                          color: PS5HydraTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<(int, String, String)> _steps() {
    if (!_isArchive) {
      return [
        (
          1,
          'Copie o arquivo ${entry.dataLabel} para a pasta do port',
          'Este port lê a imagem direto. Coloque o arquivo em $portPath '
              'e aponte o launcher para ele — não extraia.',
        ),
        (
          2,
          'Instale o APK',
          'Toque em Baixar APK. Na instalação, permita "instalar apps '
              'desconhecidos" para o LoopGamer.',
        ),
        (
          3,
          'Abra o port e escolha a pasta',
          'No primeiro start, o port pede a pasta do jogo. Selecione '
              '$portPath.',
        ),
        (
          4,
          'Limpe o que sobrou',
          'Depois que o jogo abrir, apague o arquivo grande de _downloads '
              'para liberar espaço.',
        ),
      ];
    }
    return [
      (
        1,
        'Baixe o APK e o pacote ${entry.dataLabel}',
        'O APK instala o port. O pacote ${entry.dataLabel} traz os dados do jogo.',
      ),
      (
        2,
        extracted ? 'Dados já extraídos' : 'Toque em "Extrair ${entry.dataLabel}"',
        extracted
            ? 'O conteúdo está em $portPath/game/.'
            : 'O LoopGamer extrai .7z, .zip, .rar e .tar.xz direto para '
                '$portPath/game/.',
      ),
      (
        3,
        'Apague o pacote original',
        'Com a pasta game/ pronta, o arquivo compactado não serve mais. '
            'Apague em $portPath/_downloads — libera vários GB.',
      ),
      (
        4,
        'Instale e abra o APK',
        'Permita "instalar apps desconhecidos" para o LoopGamer e abra o port.',
      ),
      (
        5,
        'Aponte a pasta dentro do port',
        'No launcher do port, escolha a pasta game/ (ou copie o conteúdo dela '
            'para a pasta que o port pede) e inicie o jogo.',
      ),
    ];
  }
}
