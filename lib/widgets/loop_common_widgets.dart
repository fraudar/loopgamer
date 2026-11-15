import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../models/app_settings.dart';
import '../models/emulation_game.dart';
import '../models/user_library_meta.dart';
import '../services/cover_cache_service.dart';
import '../theme/hydra_tokens.dart';

/// Helper compartilhado de navegação por D-pad / teclado para listas e grids.
///
/// Quando [isActive] é `false` (ex.: aba oculta em um `IndexedStack`), retorna
/// [KeyEventResult.ignored] para impedir competição de foco entre abas.
KeyEventResult handleGamepadNavigationKey({
  required KeyEvent event,
  required int itemCount,
  required int currentIndex,
  required ValueChanged<int> onIndexChanged,
  int crossAxisCount = 1,
  Axis axis = Axis.horizontal,
  bool wrapAround = true,
  ValueChanged<int>? onActivate,
  ValueChanged<int>? onSecondaryAction,
  ValueChanged<int>? onTertiaryAction,
  bool allowSecondaryWhenEmpty = false,
  bool isActive = true,
}) {
  if (!isActive) return KeyEventResult.ignored;
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }

  final key = event.logicalKey;
  final isInitialPress = event is KeyDownEvent;
  final hasItems = itemCount > 0;
  final safeIndex = hasItems ? currentIndex.clamp(0, itemCount - 1) : -1;

  if (isInitialPress) {
    if (key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.select) {
      if (!hasItems || onActivate == null) return KeyEventResult.ignored;
      onActivate(safeIndex);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.gameButtonY) {
      if (onSecondaryAction == null) return KeyEventResult.ignored;
      if (!hasItems && !allowSecondaryWhenEmpty) {
        return KeyEventResult.ignored;
      }
      onSecondaryAction(safeIndex);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.gameButtonX) {
      if (!hasItems || onTertiaryAction == null) return KeyEventResult.ignored;
      onTertiaryAction(safeIndex);
      return KeyEventResult.handled;
    }
  }

  if (!hasItems) return KeyEventResult.ignored;

  final cols = crossAxisCount < 1 ? 1 : crossAxisCount;
  int? targetIndex;

  if (key == LogicalKeyboardKey.gameButtonRight1) {
    targetIndex = _stepIndex(safeIndex, 1, itemCount, wrapAround);
  } else if (key == LogicalKeyboardKey.gameButtonLeft1) {
    targetIndex = _stepIndex(safeIndex, -1, itemCount, wrapAround);
  } else if (cols > 1) {
    if (key == LogicalKeyboardKey.arrowRight) {
      targetIndex = _stepIndex(safeIndex, 1, itemCount, wrapAround);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      targetIndex = _stepIndex(safeIndex, -1, itemCount, wrapAround);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      final candidate = safeIndex + cols;
      targetIndex = candidate < itemCount
          ? candidate
          : (wrapAround ? safeIndex % cols : itemCount - 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      final candidate = safeIndex - cols;
      if (candidate >= 0) {
        targetIndex = candidate;
      } else if (wrapAround) {
        final col = safeIndex % cols;
        var lastInCol = itemCount - 1 - ((itemCount - 1 - col) % cols);
        if (lastInCol >= itemCount) lastInCol -= cols;
        targetIndex = lastInCol.clamp(0, itemCount - 1);
      } else {
        targetIndex = safeIndex;
      }
    }
  } else if (axis == Axis.horizontal) {
    if (key == LogicalKeyboardKey.arrowRight) {
      targetIndex = _stepIndex(safeIndex, 1, itemCount, wrapAround);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      targetIndex = _stepIndex(safeIndex, -1, itemCount, wrapAround);
    }
  } else {
    if (key == LogicalKeyboardKey.arrowDown) {
      targetIndex = _stepIndex(safeIndex, 1, itemCount, wrapAround);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      targetIndex = _stepIndex(safeIndex, -1, itemCount, wrapAround);
    }
  }

  if (targetIndex == null) return KeyEventResult.ignored;
  if (targetIndex != safeIndex) {
    onIndexChanged(targetIndex);
  }
  return KeyEventResult.handled;
}

int _stepIndex(int current, int delta, int length, bool wrapAround) {
  if (length <= 1) return 0;
  if (wrapAround) {
    return (current + delta + length) % length;
  }
  return (current + delta).clamp(0, length - 1);
}

/// Barra linear de progresso estilizada com label e porcentagem compartilhada.
class LoopProgressIndicator extends StatelessWidget {
  const LoopProgressIndicator({
    super.key,
    required this.progress,
    this.label,
    this.showPercentage = true,
    this.showLabelRow = true,
    this.minHeight = 6.0,
    this.borderRadius = 6.0,
    this.color = HydraTokens.accentAmber,
    this.backgroundColor = HydraTokens.surfaceElevated2,
    this.semanticsLabel,
  });

  /// Progresso entre `0.0` e `1.0`, ou `null` para modo indeterminado.
  final double? progress;
  final String? label;
  final bool showPercentage;
  final bool showLabelRow;
  final double minHeight;
  final double borderRadius;
  final Color color;
  final Color backgroundColor;
  final String? semanticsLabel;

  /// Formata uma fração `[0.0..1.0]` como `'0%'`..`'100%'`.
  static String formatPercent(double progress) {
    final clamped = progress.clamp(0.0, 1.0);
    return '${(clamped * 100).round()}%';
  }

  @override
  Widget build(BuildContext context) {
    final clamped = progress?.clamp(0.0, 1.0);
    final percentText = clamped != null ? formatPercent(clamped) : null;
    final hasHeader =
        showLabelRow && (label != null || (showPercentage && percentText != null));

    return Semantics(
      label: semanticsLabel ?? label ?? 'Progresso',
      value: percentText,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasHeader) ...[
            Row(
              mainAxisAlignment: label != null
                  ? MainAxisAlignment.spaceBetween
                  : MainAxisAlignment.end,
              children: [
                if (label != null)
                  Flexible(
                    child: Text(
                      label!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: HydraTokens.textPrimary,
                      ),
                    ),
                  ),
                if (showPercentage && percentText != null) ...[
                  if (label != null) const SizedBox(width: 8),
                  Text(
                    percentText,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 5),
          ],
          ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: LinearProgressIndicator(
              value: clamped,
              minHeight: minHeight,
              backgroundColor: backgroundColor,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Chip filtrável de plataforma com alvo mínimo >= 48dp, highlight de foco
/// para D-pad/controle físico e suporte completo a `Semantics`.
class LoopPlatformChip extends StatefulWidget {
  const LoopPlatformChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.accentColor,
    this.focusNode,
    this.autofocus = false,
    this.semanticsLabel,
    this.compact = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final Color? accentColor;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticsLabel;
  final bool compact;

  @override
  State<LoopPlatformChip> createState() => _LoopPlatformChipState();
}

class _LoopPlatformChipState extends State<LoopPlatformChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final focusColor = widget.accentColor ?? HydraTokens.accentAmber;
    final semanticText = widget.semanticsLabel ??
        (widget.count != null
            ? '${widget.label}, ${widget.count} jogos'
            : widget.label);

    final bgColor = widget.selected
        ? HydraTokens.primaryAurora
        : HydraTokens.bgNearBlack;
    final borderColor = _focused
        ? focusColor
        : (widget.selected
            ? HydraTokens.primaryAurora
            : HydraTokens.borderSubtle10);
    final textColor = widget.selected
        ? HydraTokens.bgPureBlack
        : (_focused ? HydraTokens.textPrimary : HydraTokens.textSecondary);

    return Semantics(
      button: true,
      selected: widget.selected,
      label: semanticText,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            borderRadius: BorderRadius.circular(20),
            onFocusChange: (hasFocus) {
              if (_focused != hasFocus) {
                setState(() => _focused = hasFocus);
              }
            },
            onTap: widget.onTap,
            child: Center(
              widthFactor: 1.0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: EdgeInsets.symmetric(
                  horizontal: widget.compact ? 12 : 14,
                  vertical: widget.compact ? 6.5 : 8,
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: borderColor,
                    width: _focused ? 2.0 : 1.0,
                  ),
                  boxShadow: _focused
                      ? HydraTokens.neonBoxGlow(
                          opacity: 0.30,
                          blur: 10,
                          color: focusColor,
                        )
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: widget.compact ? 11 : 11.5,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                    if (widget.count != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${widget.count}',
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: widget.selected
                              ? HydraTokens.bgPureBlack.withOpacity(0.75)
                              : HydraTokens.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum LoopEmptyStateKind {
  empty,
  loading,
  error,
}

/// Estado reutilizável de vazio, carregamento ou erro com ação opcional.
class LoopEmptyState extends StatelessWidget {
  const LoopEmptyState({
    super.key,
    this.kind = LoopEmptyStateKind.empty,
    required this.title,
    this.subtitle,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.actionIcon,
    this.compact = false,
    this.backgroundColor = HydraTokens.bgNearBlack,
  });

  const LoopEmptyState.loading({
    super.key,
    this.title = 'Carregando catálogo...',
    this.subtitle = 'Buscando jogos e capas compatíveis.',
    this.compact = false,
    this.backgroundColor = HydraTokens.bgNearBlack,
  })  : kind = LoopEmptyStateKind.loading,
        icon = null,
        actionLabel = null,
        onAction = null,
        actionIcon = null;

  const LoopEmptyState.error({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel = 'Tentar novamente',
    this.onAction,
    this.actionIcon,
    this.icon,
    this.compact = false,
    this.backgroundColor = HydraTokens.bgNearBlack,
  }) : kind = LoopEmptyStateKind.error;

  final LoopEmptyStateKind kind;
  final String title;
  final String? subtitle;
  final PhosphorIconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final PhosphorIconData? actionIcon;
  final bool compact;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final resolvedIcon = icon ??
        (kind == LoopEmptyStateKind.error
            ? PhosphorIcons.warningCircle(PhosphorIconsStyle.bold)
            : PhosphorIcons.gameController(PhosphorIconsStyle.bold));

    final iconColor = kind == LoopEmptyStateKind.error
        ? HydraTokens.accentDanger
        : HydraTokens.textSecondary;

    final effectiveActionIcon = actionIcon ??
        (kind == LoopEmptyStateKind.error
            ? PhosphorIcons.arrowClockwise(PhosphorIconsStyle.bold)
            : null);

    return Semantics(
      liveRegion: kind != LoopEmptyStateKind.empty,
      label: subtitle != null ? '$title. $subtitle' : title,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: HydraTexturedCard(
          backgroundColor: backgroundColor,
          borderRadius: compact ? 14 : 18,
          padding: EdgeInsets.all(compact ? 18 : 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (kind == LoopEmptyStateKind.loading)
                const SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.8,
                    color: HydraTokens.accentAmber,
                  ),
                )
              else
                PhosphorIcon(
                  resolvedIcon,
                  size: compact ? 26 : 32,
                  color: iconColor,
                ),
              SizedBox(height: compact ? 10 : 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'ReadexPro',
                  fontSize: compact ? 14.5 : 16.5,
                  fontWeight: FontWeight.w700,
                  color: HydraTokens.textPrimary,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Rubik',
                    fontSize: compact ? 12 : 13.5,
                    height: 1.45,
                    color: HydraTokens.textSecondary,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                SizedBox(height: compact ? 12 : 16),
                Builder(
                  builder: (context) {
                    final style = FilledButton.styleFrom(
                      backgroundColor: HydraTokens.primaryAurora,
                      foregroundColor: HydraTokens.bgPureBlack,
                      minimumSize: const Size(48, 48),
                    );
                    final label = Text(
                      actionLabel!,
                      style: const TextStyle(
                        fontFamily: 'ReadexPro',
                        fontWeight: FontWeight.w700,
                      ),
                    );
                    if (effectiveActionIcon != null) {
                      return FilledButton.icon(
                        onPressed: onAction,
                        style: style,
                        icon: PhosphorIcon(effectiveActionIcon, size: 17),
                        label: label,
                      );
                    }
                    return FilledButton(
                      onPressed: onAction,
                      style: style,
                      child: label,
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Cartão reutilizável "Jogados recentemente" adaptável para portrait e landscape,
/// com suporte a foco visível de controle/D-pad e `Semantics`.
class LoopRecentGameCard extends StatefulWidget {
  const LoopRecentGameCard({
    super.key,
    required this.game,
    required this.playtimeSeconds,
    required this.onTap,
    this.isLandscape = false,
    this.width,
    this.cover,
    this.focusNode,
    this.autofocus = false,
  });

  final EmulationGame game;
  final int playtimeSeconds;
  final VoidCallback onTap;
  final bool isLandscape;
  final double? width;
  final Widget? cover;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<LoopRecentGameCard> createState() => _LoopRecentGameCardState();
}

class _LoopRecentGameCardState extends State<LoopRecentGameCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final playtimeLabel = formatPlaytime(widget.playtimeSeconds);
    final cardWidth = widget.width ?? (widget.isLandscape ? 176.0 : 170.0);
    final coverWidth = widget.isLandscape ? 72.0 : 68.0;
    final bgColor = widget.isLandscape
        ? HydraTokens.bgPureBlack.withOpacity(0.58)
        : HydraTokens.bgNearBlack;

    return Semantics(
      button: true,
      label:
          '${widget.game.name}, ${widget.game.platformName}, tempo jogado $playtimeLabel',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: cardWidth,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focused
                  ? HydraTokens.accentAmber
                  : HydraTokens.borderSubtle10,
              width: _focused ? 2.0 : 1.0,
            ),
            boxShadow: _focused
                ? HydraTokens.neonBoxGlow(
                    opacity: 0.28,
                    blur: 12,
                    color: HydraTokens.accentAmber,
                  )
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                focusNode: widget.focusNode,
                autofocus: widget.autofocus,
                onFocusChange: (hasFocus) {
                  if (_focused != hasFocus) {
                    setState(() => _focused = hasFocus);
                  }
                },
                onTap: widget.onTap,
                child: Row(
                  children: [
                    SizedBox(
                      width: coverWidth,
                      height: double.infinity,
                      child: widget.cover ??
                          LoopCoverImage(
                            url: widget.game.resolvedGridCoverUrl,
                            fit: BoxFit.cover,
                          ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.game.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: HydraTokens.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: widget.isLandscape
                                  ? const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    )
                                  : EdgeInsets.zero,
                              decoration: widget.isLandscape
                                  ? BoxDecoration(
                                      color: HydraTokens.primaryAurora
                                          .withOpacity(0.10),
                                      borderRadius: BorderRadius.circular(6),
                                    )
                                  : null,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PhosphorIcon(
                                    PhosphorIcons.clock(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    size: 10,
                                    color: HydraTokens.textSecondary,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      playtimeLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'JetBrainsMono',
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        color: HydraTokens.textPrimary,
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Grupo parametrizado para os 5 toggles de HUD/Telemetria compartilhado entre
/// `settings_screen.dart` e `libretro_player_screen.dart`.
class LoopHudToggleGroup extends StatelessWidget {
  const LoopHudToggleGroup({
    super.key,
    required this.settings,
    required this.onChanged,
    this.compact = false,
    this.showDividers = true,
    this.specs = AppSettings.hudToggleSpecs,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final bool compact;
  final bool showDividers;
  final List<HudOverlayToggleSpec> specs;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < specs.length; i++) {
      final spec = specs[i];
      final enabled = spec.isEnabled(settings);
      final value = spec.readValue(settings);

      void handleToggle(bool next) {
        onChanged(spec.applyValue(settings, next));
      }

      children.add(
        _HudToggleTile(
          title: spec.title,
          subtitle: spec.subtitle,
          value: value,
          compact: compact,
          onChanged: enabled ? handleToggle : null,
        ),
      );
      if (compact) {
        if (i < specs.length - 1) {
          children.add(const SizedBox(height: 6));
        }
      } else if (showDividers && spec.isMaster && i < specs.length - 1) {
        children.add(
          const Divider(color: HydraTokens.borderSubtle8, height: 16),
        );
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _HudToggleTile extends StatelessWidget {
  const _HudToggleTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.compact,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool compact;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final row = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: enabled ? () => onChanged!(!value) : null,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 4,
          vertical: compact ? 8 : 6,
        ),
        decoration: compact
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: HydraTokens.borderSubtle8),
              )
            : null,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: compact ? 12 : 13.5,
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? HydraTokens.textPrimary
                          : HydraTokens.textMuted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontFamily: 'Rubik',
                      fontSize: compact ? 10.5 : 11.5,
                      color: enabled
                          ? HydraTokens.textSecondary
                          : HydraTokens.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: compact ? 8 : 12),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: HydraTokens.bgPureBlack,
              activeTrackColor: HydraTokens.primaryAurora,
            ),
          ],
        ),
      ),
    );

    return Semantics(
      toggled: value,
      enabled: enabled,
      label: title,
      hint: subtitle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Material(
          color: compact ? HydraTokens.surfaceCatalog : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: row,
        ),
      ),
    );
  }
}
