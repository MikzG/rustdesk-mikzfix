// mikzfix: the customer's Connection Manager as a panel docked to the right edge of the
// primary display (TeamViewer style). It collapses to a small tab with the app logo that stays
// on the edge, and it has no taskbar entry on Windows, so the window can never be "lost":
// it is always on top and every collapse/expand puts it back on the edge.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../models/server_model.dart';

/// Expanded panel (logical pixels).
const double kMikzfixCmPanelWidth = 320;
const double kMikzfixCmPanelHeight = 480;

/// Chat / file-transfer log shown to the left of the panel when opened.
const double kMikzfixCmSidePageWidth = 380;

/// Collapsed tab on the screen edge.
const Size kMikzfixCmTabSize = Size(38, 48);

/// Gap between the expanded panel and the right edge of the work area (the tab is flush).
const double kMikzfixCmEdgeGap = 16;

/// An accepted session collapses to the tab after this long without any pointer activity on
/// the panel (upstream minimized the window after 3 s).
const Duration kMikzfixCmAutoCollapseDelay = Duration(seconds: 10);

class MikzfixCmColors {
  MikzfixCmColors._();
  static const Color brand = Color(0xFF1D4ED8);
  static const Color title = Color(0xFF0F172A);
  static const Color text = Color(0xFF475569);
  static const Color muted = Color(0xFF64748B);
  static const Color divider = Color(0xFFE2E8F0);
  static const Color active = Color(0xFF15803D);
  static const Color activeDot = Color(0xFF22C55E);
  static const Color pending = Color(0xFFB45309);
  static const Color pendingDot = Color(0xFFF59E0B);
  static const Color ended = Color(0xFF64748B);
  static const Color permOnBg = Color(0xFFDBEAFE);
  static const Color permOnFg = Color(0xFF1D4ED8);
  static const Color permOnBorder = Color(0xFF93C5FD);
  static const Color permOffBg = Color(0xFFF1F5F9);
  static const Color permOffFg = Color(0xFF64748B);
  static const Color permOffBorder = Color(0xFFCBD5E1);
  static const Color secondaryBg = Color(0xFFEFF6FF);
  static const Color secondaryBorder = Color(0xFFBFDBFE);
  static const Color danger = Color(0xFFDC2626);
}

class MikzfixCmDock {
  MikzfixCmDock._();

  /// Collapsed to the edge tab. Not persisted: every cm process starts expanded and every new
  /// connection expands it again.
  static final RxBool collapsed = false.obs;

  static bool _applying = false;
  static bool _pending = false;
  static final Set<String> _seenAttention = {};

  /// Once, before the window is first shown.
  static Future<void> prepareWindow() async {
    if (isMacOS) {
      try {
        // The traffic lights would sit on top of the header and fill the 38 px tab. The
        // session is ended with the panel's own "Terminar sessão".
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden,
            windowButtonVisibility: false);
      } catch (e) {
        debugPrint('mikzfix cm dock: setTitleBarStyle failed: $e');
      }
      return;
    }
    if (!isWindows) return;
    try {
      // The default minimum track size of a captioned window (~136 px) would stop the tab
      // from being 38 px wide.
      await windowManager.setMinimumSize(const Size(32, 32));
      await windowManager.setSkipTaskbar(true);
    } catch (e) {
      debugPrint('mikzfix cm dock: prepareWindow failed: $e');
    }
  }

  static Future<void> expand() async {
    if (!collapsed.value) return;
    collapsed.value = false;
    await apply();
  }

  /// [auto] is the idle timer: it never hides a pending request, an incoming voice call or an
  /// open chat. The customer's own click always collapses.
  static Future<void> collapse({bool auto = false}) async {
    if (collapsed.value) return;
    if (auto) {
      if (gFFI.chatModel.isShowCMSidePage) return;
      if (gFFI.serverModel.clients.any(_needsAttention)) return;
    }
    collapsed.value = true;
    if (gFFI.chatModel.isShowCMSidePage) {
      // Closes the side page; it re-docks through apply() itself.
      await gFFI.chatModel.toggleCMSidePage();
    }
    await apply();
  }

  static Future<void> toggle() async =>
      collapsed.value ? await expand() : await collapse();

  static bool _needsAttention(Client c) =>
      (!c.authorized && !c.disconnected) || c.incomingVoiceCall;

  /// Called on every build of the panel. A new access request, an incoming voice call or a
  /// session that just ended expands the panel once (the customer can collapse it again).
  static void watchAttention(List<Client> clients) {
    final keys = <String>{};
    for (final c in clients) {
      if (c.disconnected) {
        keys.add('${c.id}:ended');
      } else if (!c.authorized) {
        keys.add('${c.id}:request');
      }
      if (c.incomingVoiceCall) keys.add('${c.id}:voice');
    }
    final fresh = keys.difference(_seenAttention).isNotEmpty;
    _seenAttention
      ..clear()
      ..addAll(keys);
    if (fresh && collapsed.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => expand());
    }
  }

  /// Size and place the window for the current state. Calls made while one is running are
  /// merged into one more pass, so the last state always wins.
  static Future<void> apply() async {
    if (_applying) {
      _pending = true;
      return;
    }
    _applying = true;
    try {
      do {
        _pending = false;
        await _applyOnce();
      } while (_pending);
    } catch (e) {
      debugPrint('mikzfix cm dock: apply failed: $e');
    } finally {
      _applying = false;
    }
  }

  static Size _targetSize() {
    if (collapsed.value) return kMikzfixCmTabSize;
    final side = gFFI.chatModel.isShowCMSidePage;
    return Size(
        kMikzfixCmPanelWidth + (side ? kMikzfixCmSidePageWidth : 0),
        kMikzfixCmPanelHeight);
  }

  static Future<void> _applyOnce() async {
    final size = _targetSize();
    final gap = collapsed.value ? 0.0 : kMikzfixCmEdgeGap;
    var placed = false;
    if (isWindows) {
      placed = await _applyWindows(size, gap);
      // Windows gives the taskbar button back whenever the window is shown again.
      await windowManager.setSkipTaskbar(true);
    }
    if (!placed) {
      // macOS/Linux: window_manager's own alignment (work area of the current display).
      await windowManager.setSizeAlignment(size, Alignment.centerRight);
    }
    await windowManager.setAlwaysOnTop(true);
  }

  /// Windows: the primary display's work area (taskbar excluded), in physical pixels, so the
  /// result does not depend on the DPI of the monitor the window is currently on.
  static Future<bool> _applyWindows(Size size, double gap) async {
    final screens = await window_size.getScreenList();
    if (screens.isEmpty) return false;
    final primary = screens.firstWhere(
        (s) => s.frame.left == 0 && s.frame.top == 0,
        orElse: () => screens.first);
    final scale = primary.scaleFactor > 0 ? primary.scaleFactor : 1.0;
    final area = primary.visibleFrame;
    if (area.width <= 0 || area.height <= 0) return false;
    final w = min((size.width * scale).roundToDouble(), area.width);
    final h = min((size.height * scale).roundToDouble(), area.height);
    final x = area.right - w - (gap * scale).roundToDouble();
    final y = area.top + ((area.height - h) / 2).roundToDouble();
    final physical = Size(w, h);
    // Size, move, size again: moving across monitors with different DPI changes the size
    // (same order as restoreWindowPosition in common.dart).
    await windowManager.setSize(physical, ignoreDevicePixelRatio: true);
    await windowManager.setPosition(Offset(x, y), ignoreDevicePixelRatio: true);
    await windowManager.setSize(physical, ignoreDevicePixelRatio: true);
    return true;
  }
}

/// The app icon on a white rounded tile (header and collapsed tab).
class MikzfixCmLogoTile extends StatelessWidget {
  final double size;
  final double radius;
  final double padding;
  const MikzfixCmLogoTile(
      {Key? key, required this.size, this.radius = 8, this.padding = 3})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: loadIcon(size - padding * 2),
    );
  }
}

/// Green (active), amber (request pending) or grey dot with a soft ring.
class MikzfixCmStatusDot extends StatelessWidget {
  final Color color;
  final double size;
  const MikzfixCmStatusDot({Key? key, required this.color, this.size = 9})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size + 8,
      height: size + 8,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.25),
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }
}

/// The collapsed state: the whole window is the tab, only the app icon. Click expands.
/// The tab only exists during a session, so it carries no status dot (a pending request
/// expands the panel by itself, see MikzfixCmDock.watchAttention).
class MikzfixCmEdgeTab extends StatelessWidget {
  const MikzfixCmEdgeTab({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: translate('mikzfix_cm_expand'),
      child: Material(
        color: MikzfixCmColors.brand,
        child: InkWell(
          onTap: () => MikzfixCmDock.expand(),
          child: const Center(
            child: MikzfixCmLogoTile(size: 26, radius: 6, padding: 2),
          ),
        ),
      ),
    );
  }
}

/// Brand header of the expanded panel: logo, name, collapse button. Drags the window.
class MikzfixCmHeaderBar extends StatelessWidget {
  const MikzfixCmHeaderBar({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 54,
        color: MikzfixCmColors.brand,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const MikzfixCmLogoTile(size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                bind.mainGetAppNameSync(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Semantics(
              button: true,
              label: translate('mikzfix_cm_collapse'),
              child: Material(
                color: Colors.white.withOpacity(0.16),
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => MikzfixCmDock.collapse(),
                  child: const SizedBox(
                    width: 32,
                    height: 32,
                    child: Icon(Icons.chevron_right_rounded,
                        color: Colors.white, size: 22),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
