// mikzfix: "MikzFix access" (unattended access, enrolment protocol v1, section 11).
//
// The UI only writes the `mikzfix-unattended` option ("Y" / "N"); the service sees it over the
// usual IPC and does the work (generate the password, enrol, revoke, delete the password).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

const kOptionMikzfixUnattended = 'mikzfix-unattended';

bool mikzfixIsLoggedIn() {
  try {
    return bind.mainGetLocalOption(key: 'access_token').isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Shows the first-run consent once, on an installed desktop app, when nobody is logged in.
/// A logged-in machine (Miguel's) is never asked and stays "N".
/// "Installed" for unattended access: the app is installed AND, on macOS, the LaunchDaemon /
/// LaunchAgent pair is installed (being in /Applications is not enough: without the daemon
/// the GUI itself is the server and the enrolment loop never runs).
bool mikzfixServiceReady() {
  if (!bind.mainIsInstalled()) return false;
  if (isMacOS && !bind.mainIsInstalledDaemon(prompt: false)) return false;
  return true;
}

Future<void> mikzfixMaybeAskConsent() async {
  if (!isDesktop) return;
  // Give the IPC option cache a moment to load the service config.
  await Future.delayed(const Duration(seconds: 3));
  // On macOS the service can be installed from the home card while the app is open, so keep
  // checking (local calls only) until it is ready or the question was already answered.
  while (!mikzfixServiceReady()) {
    if (!bind.mainIsInstalled()) return;
    if (bind.mainGetOptionSync(key: kOptionMikzfixUnattended).isNotEmpty) return;
    await Future.delayed(const Duration(seconds: 5));
  }
  if (bind.mainGetOptionSync(key: kOptionMikzfixUnattended).isNotEmpty) return;
  if (mikzfixIsLoggedIn()) {
    await bind.mainSetOption(key: kOptionMikzfixUnattended, value: 'N');
    return;
  }
  var expanded = false;
  gFFI.dialogManager.show((setState, close, context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    Future<void> answer(String v) async {
      await bind.mainSetOption(key: kOptionMikzfixUnattended, value: v);
      close();
    }

    // Our own buttons, equal width, primary on the right; stacked with spacing when the
    // window is too narrow for two side by side.
    final notNow = dialogButton(translate('mikzfix_access_not_now'),
        isOutline: true, onPressed: () => answer('N'));
    final allow =
        dialogButton(translate('mikzfix_access_allow'), onPressed: () => answer('Y'));
    // (No LayoutBuilder: AlertDialog sizes its content with IntrinsicWidth.)
    final narrow = MediaQuery.of(context).size.width < 360;
    final Widget buttons = narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [allow, const SizedBox(height: 10), notNow],
          )
        : Row(children: [
            Expanded(child: notNow),
            const SizedBox(width: 10),
            Expanded(child: allow),
          ]);

    return CustomAlertDialog(
      title: Text(translate('mikzfix_access_question'),
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
      contentBoxConstraints: const BoxConstraints(maxWidth: 340),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => expanded = !expanded),
              child: Text(
                translate(expanded ? 'mikzfix_see_less' : 'mikzfix_see_more'),
                style: small?.copyWith(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline),
              ),
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 8),
            Text(translate('mikzfix_access_text'), style: small),
            const SizedBox(height: 8),
            Opacity(
              opacity: 0.7,
              child: Text(translate('mikzfix_access_note'), style: small),
            ),
          ],
          const SizedBox(height: 16),
          buttons,
        ],
      ),
    );
  }, clickMaskDismiss: false, backDismiss: false, tag: 'mikzfix-consent');
}

Future<bool> mikzfixConfirmTurnOff() async {
  final res = await gFFI.dialogManager.show<bool>((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate('mikzfix_access_title')),
      content: Text(translate('mikzfix_access_off_confirm')),
      actions: [
        dialogButton(translate('Cancel'), isOutline: true,
            onPressed: () => close(false)),
        dialogButton(translate('mikzfix_access_off_button'),
            onPressed: () => close(true)),
      ],
      onCancel: () => close(false),
    );
  }, clickMaskDismiss: false, backDismiss: true, tag: 'mikzfix-off');
  return res == true;
}

/// Card with our own switch (Material Switch with the theme colours).
class MikzfixAccessCard extends StatefulWidget {
  /// `true` in the left pane (compact card), `false` in Settings > Security.
  final bool compact;
  const MikzfixAccessCard({Key? key, this.compact = true}) : super(key: key);

  @override
  State<MikzfixAccessCard> createState() => _MikzfixAccessCardState();
}

class _MikzfixAccessCardState extends State<MikzfixAccessCard> {
  Timer? _timer;
  bool _on = false;

  bool _read() => bind.mainGetOptionSync(key: kOptionMikzfixUnattended) == 'Y';

  @override
  void initState() {
    super.initState();
    _on = _read();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      final v = _read();
      if (v != _on && mounted) setState(() => _on = v);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _toggle(bool v) async {
    if (v) {
      await bind.mainSetOption(key: kOptionMikzfixUnattended, value: 'Y');
    } else {
      if (!await mikzfixConfirmTurnOff()) return;
      await bind.mainSetOption(key: kOptionMikzfixUnattended, value: 'N');
    }
    if (mounted) setState(() => _on = v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(translate('mikzfix_access_title'),
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Opacity(
          opacity: 0.7,
          child: Text(
              translate(_on ? 'mikzfix_access_on' : 'mikzfix_access_off'),
              style: small),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(translate('mikzfix_access_switch'), style: small),
            ),
            Switch(
              value: _on,
              activeColor: theme.colorScheme.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) => _toggle(v),
            ),
          ],
        ),
      ],
    );
    if (!widget.compact) return body;
    return Container(
      margin: const EdgeInsets.only(left: 20, right: 11, top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor.withOpacity(0.4)),
      ),
      child: body,
    );
  }
}
