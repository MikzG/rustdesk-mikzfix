// mikzfix: "Permissões do MikzFix Remote" (macOS). One window for every permission the app
// needs, with live status, in place of the loose permission cards. Our own style and drawing.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/mikzfix_access.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:url_launcher/url_launcher.dart';

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

  /// First the native request (src/platform/macos.mm / macos.rs):
  /// Screen Recording: CGPreflightScreenCaptureAccess + CGRequestScreenCaptureAccess;
  /// Accessibility: AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt;
  /// Input Monitoring: IOHIDCheckAccess + IOHIDRequestAccess(kIOHIDRequestTypeListenEvent).
  /// Only if it is still denied ~1 s later, the exact Settings pane opens. Full Disk Access
  /// has no request API, so its pane opens directly.
  Future<void> request() async {
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
        await launchUrl(Uri.parse(pane));
        return;
    }
    await Future.delayed(const Duration(seconds: 1));
    if (!granted()) {
      await launchUrl(Uri.parse(pane));
    }
  }
}

bool mikzfixMacRequiredMissing() {
  if (!isMacOS) return false;
  return MikzfixMacPerm.values.any((p) => !p.optional && !p.granted());
}

bool _laterThisRun = false;

/// Shows the window if a required permission is missing (macOS). Without login it cannot be
/// closed while one is missing; "Lembrar mais tarde" hides it until the next start.
Future<void> mikzfixShowMacPermissions({bool fromSettings = false}) async {
  if (!isMacOS) return;
  if (!fromSettings && (_laterThisRun || !mikzfixMacRequiredMissing())) return;
  await gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      contentBoxConstraints: const BoxConstraints(maxWidth: 760),
      content: _MikzfixMacPermissionsView(
        onClose: () => close(),
        onLater: () {
          _laterThisRun = true;
          close();
        },
      ),
    );
  }, clickMaskDismiss: false, backDismiss: false, tag: 'mikzfix-mac-permissions');
}

class _MikzfixMacPermissionsView extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onLater;
  const _MikzfixMacPermissionsView(
      {required this.onClose, required this.onLater});

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
    final ok = await gFFI.dialogManager.show<bool>((setState, close, context) {
      return CustomAlertDialog(
        title: Text(translate('mikzfix_perm_reset')),
        content: Text(translate('mikzfix_perm_reset_confirm')),
        actions: [
          dialogButton(translate('Cancel'),
              isOutline: true, onPressed: () => close(false)),
          dialogButton(translate('mikzfix_perm_reset_button'),
              onPressed: () => close(true)),
        ],
        onCancel: () => close(false),
      );
    }, tag: 'mikzfix-perm-reset');
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
    if (_requiredOk && !loggedIn && !_closing) {
      _closing = true;
      // All required permissions in: move on (service install card, then the consent).
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onClose());
    }
    return SizedBox(
      width: 720,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 250, child: _guide(context)),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(translate('mikzfix_perm_title'),
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(translate('mikzfix_perm_sub'),
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 14),
                for (final p in MikzfixMacPerm.values) _row(context, p),
                const SizedBox(height: 14),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _resetAll,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: Text(translate('mikzfix_perm_reset')),
                    ),
                    const Spacer(),
                    if (canClose)
                      dialogButton(translate('Close'), onPressed: widget.onClose)
                    else
                      dialogButton(translate('mikzfix_perm_later'),
                          isOutline: true, onPressed: widget.onLater),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
