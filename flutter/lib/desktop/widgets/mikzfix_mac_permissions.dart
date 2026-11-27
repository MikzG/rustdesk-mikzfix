// mikzfix: "Permissões do MikzFix Remote" (macOS). One window for every permission the app
// needs, with live status, in place of the loose permission cards. Our own style and drawing.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/mikzfix_access.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_hbb/main.dart';

const kMikzfixBundleId = 'tech.mikzfix.remote';
const _kPane = 'x-apple.systempreferences:com.apple.preference.security?';

enum MikzfixMacPerm { screen, accessibility, input, fullDisk }

extension _PermInfo on MikzfixMacPerm {
  String get nameKey => const {
        MikzfixMacPerm.screen: 'mikzfix_perm_screen',
        MikzfixMacPerm.accessibility: 'mikzfix_perm_acc',
        MikzfixMacPerm.input: 'mikzfix_perm_input',
        MikzfixMacPerm.fullDisk: 'mikzfix_perm_fda',
      }[this]!;
  String get descKey => '${nameKey}_desc';
  bool get optional => this == MikzfixMacPerm.fullDisk;
  String get pane => _kPane +
      const {
        MikzfixMacPerm.screen: 'Privacy_ScreenCapture',
        MikzfixMacPerm.accessibility: 'Privacy_Accessibility',
        MikzfixMacPerm.input: 'Privacy_ListenEvent',
        MikzfixMacPerm.fullDisk: 'Privacy_AllFiles',
      }[this]!;
  IconData get icon => const {
        MikzfixMacPerm.screen: Icons.screen_share_outlined,
        MikzfixMacPerm.accessibility: Icons.mouse_outlined,
        MikzfixMacPerm.input: Icons.keyboard_outlined,
        MikzfixMacPerm.fullDisk: Icons.folder_open_outlined,
      }[this]!;

  /// Status without any prompt.
  bool granted() {
    switch (this) {
      case MikzfixMacPerm.screen:
        return bind.mainIsCanScreenRecording(prompt: false);
      case MikzfixMacPerm.accessibility:
        return bind.mainIsProcessTrusted(prompt: false);
      case MikzfixMacPerm.input:
        return bind.mainIsCanInputMonitoring(prompt: false);
      case MikzfixMacPerm.fullDisk:
        return mikzfixHasFullDiskAccess();
    }
  }

  String get _askedKey => 'mikzfix-perm-asked-$name';

  /// Native request first (src/platform/macos.mm / macos.rs). How each API behaves:
  /// - Screen Recording: CGRequestScreenCaptureAccess shows the system alert only the first
  ///   time for this app (it has its own "Open System Settings" button); later calls show
  ///   nothing and just return false.
  /// - Accessibility: AXIsProcessTrustedWithOptions(prompt) shows the "would like to control
  ///   this computer" alert (with "Open System Settings") and returns at once, not waiting.
  /// - Input Monitoring: IOHIDRequestAccess shows the alert only the first time.
  /// None of them tells us when the alert is answered, so:
  /// - first time: only the native request, then after ~2 s open our Settings pane only if
  ///   still denied AND our window has focus again (while the system alert is up, or after the
  ///   user went to Settings from it, our window is not focused);
  /// - after that (the system will not show its alert again): open the pane directly.
  /// Full Disk Access has no request API: its pane opens directly.
  Future<void> request() async {
    if (this == MikzfixMacPerm.fullDisk) {
      await launchUrl(Uri.parse(pane));
      return;
    }
    final askedBefore = bind.mainGetLocalOption(key: _askedKey) == 'Y';
    switch (this) {
      case MikzfixMacPerm.screen:
        bind.mainIsCanScreenRecording(prompt: true);
        break;
      case MikzfixMacPerm.accessibility:
        bind.mainIsProcessTrusted(prompt: true);
        break;
      case MikzfixMacPerm.input:
        bind.mainIsCanInputMonitoring(prompt: true);
        break;
      case MikzfixMacPerm.fullDisk:
        break;
    }
    if (askedBefore) {
      if (!granted()) await launchUrl(Uri.parse(pane));
      return;
    }
    await bind.mainSetLocalOption(key: _askedKey, value: 'Y');
    await Future.delayed(const Duration(seconds: 2));
    if (granted()) return;
    // The system alert belongs to another process: while it is up (or after the user went to
    // Settings from it) our app is not the active one. This runs in the permissions window's
    // own engine, so use the app lifecycle, not window_manager (main window only).
    final active =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (active) await launchUrl(Uri.parse(pane));
  }
}

bool mikzfixMacRequiredMissing() {
  if (!isMacOS) return false;
  return MikzfixMacPerm.values.any((p) => !p.optional && !p.granted());
}

bool _laterThisRun = false;

/// Main window: true while it is blocked by the permissions window (logged out, a required
/// permission missing). DesktopTabPage draws the blocking overlay from it.
final RxBool mikzfixPermBlocked = false.obs;
Timer? _permWatch;

void _unblockMain() {
  _permWatch?.cancel();
  _permWatch = null;
  mikzfixPermBlocked.value = false;
}

/// Opens the permissions as a SEPARATE window (macOS). Without login, and while a required
/// permission is missing, the main window is blocked until they are granted or the user
/// chooses "Remind me later" (closing the window counts as that; it comes back on the next
/// start). With login it opens without blocking (Settings > Security).
Future<void> mikzfixShowMacPermissions({bool fromSettings = false}) async {
  if (!isMacOS) return;
  if (!fromSettings && (_laterThisRun || !mikzfixMacRequiredMissing())) return;
  final blocking = !mikzfixLoggedIn.value && mikzfixMacRequiredMissing();
  await rustDeskWinManager.openMikzfixPermissions(blocking: blocking);
  if (!blocking) return;
  mikzfixPermBlocked.value = true;
  _permWatch?.cancel();
  _permWatch = Timer.periodic(const Duration(seconds: 1), (_) async {
    if (!mikzfixMacRequiredMissing()) {
      _unblockMain();
      await rustDeskWinManager.closeMikzfixPermissions();
      return;
    }
    if (!await rustDeskWinManager.isMikzfixPermissionsOpen()) {
      // Closed or "Remind me later": unblock until the next start.
      _laterThisRun = true;
      _unblockMain();
    }
  });
}

/// "Mostrar janela" on the blocking overlay.
Future<void> mikzfixBringPermissionsToFront() async {
  await rustDeskWinManager.openMikzfixPermissions(blocking: true);
}

/// Overlay that blocks the main window while the permissions window is required.
class MikzfixPermBlockOverlay extends StatelessWidget {
  const MikzfixPermBlockOverlay({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: Stack(children: [
        const ModalBarrier(dismissible: false, color: Color(0x99000000)),
        Center(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.lock_outline,
                    color: theme.colorScheme.primary, size: 28),
                const SizedBox(height: 10),
                Text(translate('mikzfix_perm_block_msg'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium),
                const SizedBox(height: 14),
                dialogButton(translate('mikzfix_perm_show_window'),
                    onPressed: () => mikzfixBringPermissionsToFront()),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

/// The page of the separate permissions window.
class MikzfixPermissionsWindowPage extends StatelessWidget {
  final bool blocking;
  const MikzfixPermissionsWindowPage({Key? key, required this.blocking})
      : super(key: key);

  Future<void> _closeSelf() async {
    try {
      await WindowController.fromWindowId(kWindowId!).close();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: SafeArea(
        child: _MikzfixMacPermissionsView(
          blocking: blocking,
          onClose: _closeSelf,
          onLater: _closeSelf,
        ),
      ),
    );
  }
}

class _MikzfixMacPermissionsView extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onLater;
  final bool blocking;
  const _MikzfixMacPermissionsView(
      {required this.onClose, required this.onLater, this.blocking = false});

  @override
  State<_MikzfixMacPermissionsView> createState() =>
      _MikzfixMacPermissionsViewState();
}

class _MikzfixMacPermissionsViewState
    extends State<_MikzfixMacPermissionsView> {
  Timer? _timer;
  MikzfixMacPerm _selected = MikzfixMacPerm.screen;
  final Map<MikzfixMacPerm, bool> _state = {};
  bool _closing = false;
  bool _showGuide = false;

  void _refresh() {
    var changed = false;
    for (final p in MikzfixMacPerm.values) {
      final g = p.granted();
      if (_state[p] != g) {
        _state[p] = g;
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  bool get _requiredOk => MikzfixMacPerm.values
      .where((p) => !p.optional)
      .every((p) => _state[p] == true);

  @override
  void initState() {
    super.initState();
    _refresh();
    _selected = MikzfixMacPerm.values.firstWhere((p) => _state[p] != true,
        orElse: () => MikzfixMacPerm.screen);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _resetAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(translate('mikzfix_perm_reset')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(translate('mikzfix_perm_reset_confirm')),
        ),
        actions: [
          dialogButton(translate('Cancel'),
              isOutline: true, onPressed: () => Navigator.of(ctx).pop(false)),
          dialogButton(translate('mikzfix_perm_reset_button'),
              onPressed: () => Navigator.of(ctx).pop(true)),
        ],
      ),
    );
    if (ok != true) return;
    // Only our own bundle id: resets the TCC entries of this app, nothing else.
    try {
      await Process.run('/usr/bin/tccutil', ['reset', 'All', kMikzfixBundleId]);
    } catch (e) {
      debugPrint('tccutil reset failed: $e');
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loggedIn = mikzfixLoggedIn.value;
    final canClose = loggedIn || _requiredOk;
    if (_requiredOk && widget.blocking && !_closing) {
      _closing = true;
      // All required permissions in: move on (service install card, then the consent).
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onClose());
    }
    // Responsive: two columns when there is room, one column (permissions first, the
    // instructions collapsible below) when narrow. The body scrolls; the footer with the
    // action buttons is fixed and always visible. Bounded size on both axes, so the dialog
    // can never collapse into an empty card.
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : 880.0;
      final h = c.maxHeight.isFinite ? c.maxHeight : 620.0;
      final narrow = w < 640;
      final header = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(translate('mikzfix_perm_title'),
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(translate('mikzfix_perm_sub'), style: theme.textTheme.bodySmall),
          const SizedBox(height: 14),
        ],
      );
      final list = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final p in MikzfixMacPerm.values) _row(context, p)],
      );
      final Widget body = narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                list,
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _showGuide = !_showGuide),
                    icon: Icon(
                        _showGuide ? Icons.expand_less : Icons.expand_more,
                        size: 18),
                    label: Text(translate(
                        _showGuide ? 'mikzfix_see_less' : 'mikzfix_see_more')),
                  ),
                ),
                if (_showGuide) _guide(context),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 250, child: _guide(context)),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [header, list],
                  ),
                ),
              ],
            );
      final closeBtn = canClose
          ? dialogButton(translate('Close'), onPressed: widget.onClose)
          : dialogButton(translate('mikzfix_perm_later'),
              isOutline: true, onPressed: widget.onLater);
      final resetBtn = TextButton.icon(
        onPressed: _resetAll,
        icon: const Icon(Icons.restart_alt, size: 18),
        label: Text(translate('mikzfix_perm_reset')),
      );
      final footer = narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [closeBtn, const SizedBox(height: 6), resetBtn],
            )
          : Row(children: [resetBtn, const Spacer(), closeBtn]);
      return SizedBox(
        width: w,
        height: h,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(narrow ? 14 : 20),
                child: body,
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: narrow ? 14 : 20, vertical: 12),
              child: footer,
            ),
          ],
        ),
      );
    });
  }

  Widget _row(BuildContext context, MikzfixMacPerm p) {
    final theme = Theme.of(context);
    final ok = _state[p] == true;
    final selected = p == _selected;
    final small = theme.textTheme.bodySmall;
    const green = Color(0xFF22A06B);
    const red = Color(0xFFD9534F);
    const grey = Color(0xFF9AA0A6);
    final statusColor = ok ? green : (p.optional ? grey : red);
    // Name + status on one line, description below, the button on its own line under the
    // text: nothing can overlap whatever the width.
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _selected = p),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected
                  ? theme.colorScheme.primary.withOpacity(0.6)
                  : theme.dividerColor.withOpacity(0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(p.icon, size: 22, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 2,
                    children: [
                      Text(translate(p.nameKey),
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      if (p.optional)
                        Text('(${translate('mikzfix_perm_optional')})',
                            style: small),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(ok ? Icons.check_circle : Icons.cancel,
                            size: 15, color: statusColor),
                        const SizedBox(width: 4),
                        Text(
                            translate(ok
                                ? 'mikzfix_perm_granted'
                                : 'mikzfix_perm_denied'),
                            style: small?.copyWith(
                                color: statusColor,
                                fontWeight: FontWeight.w600)),
                      ]),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(translate(p.descKey), style: small),
                  if (!ok) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () {
                        setState(() => _selected = p);
                        p.request();
                      },
                      child: Text(translate('mikzfix_fda_button')),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Left side: the path in the user's macOS version (System Settings on 13+, System
  /// Preferences on 12 and older), drawn by us in the macOS style with our icon, following
  /// the app theme and language; then the short steps.
  Widget _guide(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final modern = mikzfixMacMajorVersion() >= 13;
    final perm = translate(_selected.macNameKey);
    final app = translate(modern ? 'mikzfix_mac_sys_settings' : 'mikzfix_mac_sys_prefs');
    final section = translate(
        modern ? 'mikzfix_mac_privacy_security' : 'mikzfix_mac_security_privacy');
    TextSpan b(String s) =>
        TextSpan(text: s, style: const TextStyle(fontWeight: FontWeight.w600));
    Widget step(int n, List<InlineSpan> spans) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: theme.colorScheme.primary, shape: BoxShape.circle),
              child: Text('$n',
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text.rich(TextSpan(style: small, children: spans))),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          MikzfixMacSettingsIllustration(
              modern: modern, perm: _selected, permName: perm),
          const SizedBox(height: 14),
          step(1, [
            TextSpan(text: '${translate('mikzfix_perm_step1')} '),
          ]),
          step(2, [
            TextSpan(text: '${translate('mikzfix_perm_step_path')} '),
            b(app),
            const TextSpan(text: ' › '),
            b(section),
            if (!modern) ...[
              const TextSpan(text: ' › '),
              b(translate('mikzfix_mac_privacy')),
            ],
            const TextSpan(text: ' › '),
            b(perm),
            const TextSpan(text: '.'),
          ]),
          step(3, [TextSpan(text: translate('mikzfix_perm_step_toggle'))]),
          step(4, [TextSpan(text: translate('mikzfix_perm_step3'))]),
        ],
      ),
    );
  }
}

/// macOS major version (e.g. 14), 0 if unknown.
int mikzfixMacMajorVersion() {
  if (!Platform.isMacOS) return 0;
  final m = RegExp(r'(\d+)\.').firstMatch(Platform.operatingSystemVersion) ??
      RegExp(r'(\d+)').firstMatch(Platform.operatingSystemVersion);
  return int.tryParse(m?.group(1) ?? '') ?? 0;
}

extension _MacName on MikzfixMacPerm {
  /// Apple's own name of the Privacy item, in the app language.
  String get macNameKey => const {
        MikzfixMacPerm.screen: 'mikzfix_mac_name_screen',
        MikzfixMacPerm.accessibility: 'mikzfix_mac_name_acc',
        MikzfixMacPerm.input: 'mikzfix_mac_name_input',
        MikzfixMacPerm.fullDisk: 'mikzfix_mac_name_fda',
      }[this]!;
}

/// Our drawing of the macOS Settings window at the right place, light or dark with the app
/// theme. No screenshots: plain shapes, the app icon and translated labels.
class MikzfixMacSettingsIllustration extends StatelessWidget {
  final bool modern;
  final MikzfixMacPerm perm;
  final String permName;
  const MikzfixMacSettingsIllustration(
      {Key? key,
      required this.modern,
      required this.perm,
      required this.permName})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final win = dark ? const Color(0xFF2B2B2E) : const Color(0xFFF5F5F7);
    final side = dark ? const Color(0xFF232326) : const Color(0xFFE9E9EC);
    final fg = dark ? const Color(0xFFE8E8EA) : const Color(0xFF1D1D1F);
    final muted = dark ? const Color(0xFF9A9AA0) : const Color(0xFF6E6E73);
    final line = dark ? const Color(0xFF3A3A3E) : const Color(0xFFD8D8DC);
    const blue = Color(0xFF0A84FF);
    final t = TextStyle(fontSize: 10, color: fg);
    final tm = TextStyle(fontSize: 9, color: muted);

    Widget dots() => Row(children: [
          for (final c in const [
            Color(0xFFFF5F57),
            Color(0xFFFEBC2E),
            Color(0xFF28C840)
          ])
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
        ]);

    Widget appRow() => Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.asset('assets/icon.png', width: 16, height: 16),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text('MikzFix Remote', style: t)),
          if (modern)
            Container(
              width: 24,
              height: 14,
              padding: const EdgeInsets.all(2),
              alignment: Alignment.centerRight,
              decoration: BoxDecoration(
                  color: blue, borderRadius: BorderRadius.circular(7)),
              child: Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                      color: Colors.white, shape: BoxShape.circle)),
            )
          else
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                  color: blue, borderRadius: BorderRadius.circular(3)),
              child: const Icon(Icons.check, size: 10, color: Colors.white),
            ),
        ]);

    final body = modern
        // macOS 13+: sidebar with "Privacy & Security" selected, the permission page right.
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 74,
              color: side,
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(translate('mikzfix_mac_general'), style: tm),
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                    decoration: BoxDecoration(
                        color: blue, borderRadius: BorderRadius.circular(4)),
                    child: Text(translate('mikzfix_mac_privacy_security'),
                        style: const TextStyle(
                            fontSize: 9, color: Colors.white),
                        maxLines: 2),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(permName,
                        style: t.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        border: Border.all(color: line),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: appRow(),
                    ),
                    const SizedBox(height: 4),
                    Text('+  –', style: tm),
                  ],
                ),
              ),
            ),
          ])
        // macOS 12 and older: "Security & Privacy" with the Privacy tab, list on the left.
        : Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: blue, borderRadius: BorderRadius.circular(4)),
                    child: Text(translate('mikzfix_mac_privacy'),
                        style:
                            const TextStyle(fontSize: 9, color: Colors.white)),
                  ),
                ),
                const SizedBox(height: 6),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 70,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                        color: side, borderRadius: BorderRadius.circular(4)),
                    child: Text(permName,
                        style: t.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 2),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        border: Border.all(color: line),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: appRow(),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.lock_open, size: 11, color: muted),
                  const SizedBox(width: 3),
                  Text('+  –', style: tm),
                ]),
              ],
            ),
          );

    return Container(
      decoration: BoxDecoration(
        color: win,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: line))),
            child: Row(children: [
              dots(),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    translate(modern
                        ? 'mikzfix_mac_sys_settings'
                        : 'mikzfix_mac_security_privacy'),
                    style: tm,
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
          body,
        ],
      ),
    );
  }
}
