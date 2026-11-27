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
Future<void> mikzfixMaybeAskConsent() async {
  if (!isDesktop) return;
  // Give the IPC option cache a moment to load the service config.
  await Future.delayed(const Duration(seconds: 3));
  if (!bind.mainIsInstalled()) return;
  if (bind.mainGetOptionSync(key: kOptionMikzfixUnattended).isNotEmpty) return;
  if (mikzfixIsLoggedIn()) {
    await bind.mainSetOption(key: kOptionMikzfixUnattended, value: 'N');
    return;
  }
  gFFI.dialogManager.show((setState, close, context) {
    final note = Theme.of(context).textTheme.bodySmall;
    return CustomAlertDialog(
      title: Text(translate('mikzfix_access_title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(translate('mikzfix_access_text')),
          const SizedBox(height: 12),
          Opacity(
            opacity: 0.7,
            child: Text(translate('mikzfix_access_note'), style: note),
          ),
        ],
      ),
      actions: [
        dialogButton(translate('mikzfix_access_not_now'), isOutline: true,
            onPressed: () async {
          await bind.mainSetOption(key: kOptionMikzfixUnattended, value: 'N');
          close();
        }),
        dialogButton(translate('mikzfix_access_allow'), onPressed: () async {
          await bind.mainSetOption(key: kOptionMikzfixUnattended, value: 'Y');
          close();
        }),
      ],
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
