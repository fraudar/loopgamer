import 'package:flutter/material.dart';

import '../services/game_asset_service.dart';
import '../theme/ps5_hydra_theme.dart';
import 'procedural_cover.dart';

/// Cartão de port Android no mesmo formato 3:4 dos outros jogos do catálogo.
///
/// A capa é resolvida por título pelos mesmos providers do catálogo
/// (Steam/GOG/Wikidata, mais RAWG e SteamGridDB quando configurados). Se não
/// houver capa confiável, cai no fallback procedural com as iniciais — nunca
/// reaproveita a capa de outro jogo por id.
class PortCoverCard extends StatefulWidget {
  const PortCoverCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.onTap,
    this.badge,
    this.searchTitle,
  });

  final String title;
  final String subtitle;
  final Color accentColor;
  final VoidCallback onTap;
  final String? badge;
  final String? searchTitle;

  @override
  State<PortCoverCard> createState() => _PortCoverCardState();
}

class _PortCoverCardState extends State<PortCoverCard> {
  static const String _platformSlug = 'android-port';

  String? _coverUrl;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolveCover();
  }

  @override
  void didUpdateWidget(covariant PortCoverCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKey = oldWidget.searchTitle ?? oldWidget.title;
    final newKey = widget.searchTitle ?? widget.title;
    if (oldKey != newKey) {
      _coverUrl = null;
      _resolved = false;
      _resolveCover();
    }
  }

  Future<void> _resolveCover() async {
    final key = widget.searchTitle ?? widget.title;
    final service = GameAssetService.instance;
    final cached = service.getCachedAssets(key, platformSlug: _platformSlug);
    if (cached != null) {
      final url = cached.coverImageUrl;
      if (mounted) {
        setState(() {
          _coverUrl = (url == null || url.isEmpty) ? null : url;
          _resolved = true;
        });
      }
      return;
    }
    try {
      final assets = await service.fetchAssetsByTitle(
        key,
        platformSlug: _platformSlug,
      );
      final url = assets.coverImageUrl;
      if (!mounted) return;
      setState(() {
        _coverUrl = (url == null || url.isEmpty) ? null : url;
        _resolved = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _resolved = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Abrir port ${widget.title}',
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ProceduralCover(
                    title: widget.title,
                    platformName: 'ANDROID PORT',
                    accentColor: widget.accentColor,
                    imageUrl: _coverUrl,
                    showBottomLabel: false,
                    memCacheWidth: 320,
                  ),
                  if (!_resolved)
                    const Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFFFFB454),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (widget.badge != null)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.72),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: widget.accentColor.withOpacity(0.65),
                          ),
                        ),
                        child: Text(
                          widget.badge!,
                          style: TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: widget.accentColor,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: PS5HydraTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              widget.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Rubik',
                fontSize: 10,
                color: PS5HydraTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
