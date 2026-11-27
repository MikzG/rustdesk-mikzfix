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

  /// The system request where macOS has one (Screen Recording: CGRequestScreenCaptureAccess,
  /// Accessibility: AXIsProcessTrustedWithOptions, Input Monitoring: IOHIDRequestAccess), then
  /// the exact Settings pane. Full Disk Access cannot be requested, only the pane opened.
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
        break;
    }
    await Future.delayed(const Duration(milliseconds: 500));
    await launchUrl(Uri.parse(pane));
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
          children: [
            Icon(p.icon, size: 22, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(translate(p.nameKey),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (p.optional) ...[
                      const SizedBox(width: 6),
                      Text('(${translate('mikzfix_perm_optional')})',
                          style: small),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(translate(p.descKey), style: small),
                  const SizedBox(height: 4),
                  Row(children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ok
                            ? const Color(0xFF22A06B)
                            : (p.optional
                                ? const Color(0xFFB0B4BA)
                                : const Color(0xFFD9534F)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                        translate(ok
                            ? 'mikzfix_perm_granted'
                            : 'mikzfix_perm_denied'),
                        style: small),
                  ]),
                ],
              ),
            ),
            if (!ok)
              OutlinedButton(
                onPressed: () {
                  setState(() => _selected = p);
                  p.request();
                },
                child: Text(translate('mikzfix_fda_button')),
              ),
          ],
        ),
      ),
    );
  }

  /// Left side: our simple drawing of the Settings switch for the selected permission, and
  /// the steps.
  Widget _guide(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final name = translate(_selected.nameKey);
    Widget step(int n, Widget child) => Padding(
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
            Expanded(child: child),
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
          // Drawing: a Settings-like list row with our icon and an "on" switch.
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.dividerColor.withOpacity(0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(_selected.icon, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(name,
                        overflow: TextOverflow.ellipsis,
                        style: small?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ]),
                const Divider(height: 14),
                Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: Image.asset('assets/icon.png', width: 22, height: 22),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text('MikzFix Remote', style: small)),
                  Container(
                    width: 30,
                    height: 18,
                    padding: const EdgeInsets.all(2),
                    alignment: Alignment.centerRight,
                    decoration: BoxDecoration(
                      color: const Color(0xFF22A06B),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle),
                    ),
                  ),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 14),
          step(1, Text(translate('mikzfix_perm_step1'), style: small)),
          step(
              2,
              Text.rich(TextSpan(style: small, children: [
                TextSpan(text: '${translate('mikzfix_perm_step2')} '),
                TextSpan(
                    text: name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const TextSpan(text: '.'),
              ]))),
          step(3, Text(translate('mikzfix_perm_step3'), style: small)),
        ],
      ),
    );
  }
}
