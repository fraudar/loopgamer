import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/cover_cache_service.dart';
import '../services/game_asset_service.dart';
import '../theme/ps5_hydra_theme.dart';

/// Capa/Banner via cache persistente em disco ([CoverCacheService]) para jogos
/// baixados e [CachedNetworkImage] com fallback escuro (`obsidianGlass` -> `#000000`).
class ProceduralCover extends StatelessWidget {
  const ProceduralCover({
    super.key,
    required this.title,
    required this.platformName,
    this.accentColor = PS5HydraTheme.auroraSpringMint,
    this.imageUrl,
    this.gameId,
    this.isBanner = false,
    this.borderRadius = 12.0,
    this.showBottomLabel = true,
    this.compact = false,
    this.fit = BoxFit.cover,
    this.memCacheWidth,
    this.memCacheHeight,
  });

  final String title;
  final String platformName;
  final Color accentColor;
  final String? imageUrl;
  final int? gameId;
  final bool isBanner;
  final double borderRadius;
  final bool showBottomLabel;
  final bool compact;
  final BoxFit fit;
  final int? memCacheWidth;
  final int? memCacheHeight;

  /// Extrai as iniciais do nome do jogo (ex.: `God of War` -> `GW`, `Tekken 6` -> `T6`).
  static String extractInitials(String rawTitle) {
    final cleaned = rawTitle
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9\s]'), ' ')
        .trim();
    if (cleaned.isEmpty) return 'LG';
    final words = cleaned
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return 'LG';
    if (words.length == 1) {
      final w = words.first.toUpperCase();
      return w.length >= 2 ? w.substring(0, 2) : w;
    }
    const skip = {'OF', 'THE', 'AND', 'IN', 'ON', 'A', 'AN', 'DE', 'DO', 'DA'};
    final significant =
        words.where((w) => !skip.contains(w.toUpperCase())).toList();
    final pick = significant.length >= 2 ? significant : words;
    final first = pick[0][0].toUpperCase();
    final second = pick[1][0].toUpperCase();
    return '$first$second';
  }

  @override
  Widget build(BuildContext context) {
    final fallback = ProceduralCoverArt(
      title: title,
      initials: extractInitials(title),
      platformName: platformName,
      showBottomLabel: showBottomLabel,
      compact: compact,
    );

    final trimmedUrl = imageUrl?.trim();
    final diskFile = gameId != null
        ? CoverCacheService.instance.getCachedMediaForGame(
            gameId!,
            imageUrl: trimmedUrl,
            isBanner: isBanner,
          )
        : CoverCacheService.instance.getCachedFileFast(trimmedUrl);

    final Widget child;
    if (diskFile != null) {
      child = Image.file(
        diskFile,
        fit: fit,
        cacheWidth: memCacheWidth,
        cacheHeight: memCacheHeight,
        errorBuilder: (_, __, ___) => fallback,
      );
    } else if (trimmedUrl != null &&
        trimmedUrl.isNotEmpty &&
        trimmedUrl.startsWith('http')) {
      child = CachedNetworkImage(
        imageUrl: trimmedUrl,
        cacheManager: SessionMemoryCacheManager.instance,
        fit: fit,
        memCacheWidth: memCacheWidth,
        memCacheHeight: memCacheHeight,
        fadeInDuration: PS5HydraTheme.animStandard,
        fadeOutDuration: PS5HydraTheme.animFast,
        fadeInCurve: Curves.easeOut,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      );
    } else {
      child = fallback;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: child,
    );
  }
}

/// Fallback escuro (`obsidianGlass` -> `#000000`) com as iniciais do jogo.
class ProceduralCoverArt extends StatelessWidget {
  const ProceduralCoverArt({
    super.key,
    required this.title,
    required this.initials,
    required this.platformName,
    this.showBottomLabel = true,
    this.compact = false,
  });

  final String title;
  final String initials;
  final String platformName;
  final bool showBottomLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            PS5HydraTheme.abyssalCard,
            PS5HydraTheme.obsidianGlass,
            PS5HydraTheme.pitchBlack,
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: showBottomLabel ? 14 : 0),
              child: Text(
                initials,
                maxLines: 1,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'ReadexPro',
                  fontWeight: FontWeight.w700,
                  fontSize: compact ? 20 : 26,
                  letterSpacing: 1.4,
                  color: PS5HydraTheme.textPrimary.withOpacity(0.85),
                ),
              ),
            ),
          ),
          if (showBottomLabel)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 6 : 8,
                  vertical: compact ? 4 : 6,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      PS5HydraTheme.pitchBlack.withOpacity(0.92),
                    ],
                  ),
                ),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'ReadexPro',
                    fontWeight: FontWeight.w600,
                    fontSize: compact ? 9.5 : 10.5,
                    color: PS5HydraTheme.textPrimary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
