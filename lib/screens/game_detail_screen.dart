import 'package:flutter/material.dart';
import '../models/emulation_game.dart';
import '../services/rom_download_service.dart';
import 'explore_screen.dart';

class GameDetailScreen extends StatelessWidget {
  const GameDetailScreen({
    super.key,
    required this.game,
    required this.downloadService,
    required this.initialStatus,
    required this.onStatusChanged,
    required this.onPlayPressed,
  });

  final EmulationGame game;
  final RomDownloadService downloadService;
  final RomDownloadStatus initialStatus;
  final ValueChanged<RomDownloadStatus> onStatusChanged;
  final ValueChanged<String> onPlayPressed;

  static Future<void> showAsModal(
    BuildContext context, {
    required EmulationGame game,
    required RomDownloadService downloadService,
    required RomDownloadStatus initialStatus,
    required ValueChanged<RomDownloadStatus> onStatusChanged,
    required ValueChanged<String> onPlayPressed,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GameDetailSheet(
        game: game,
        downloadService: downloadService,
        initialStatus: initialStatus,
        onStatusChanged: onStatusChanged,
        onPlayPressed: onPlayPressed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GameDetailSheet(
        game: game,
        downloadService: downloadService,
        initialStatus: initialStatus,
        onStatusChanged: onStatusChanged,
        onPlayPressed: onPlayPressed,
      ),
    );
  }
}
