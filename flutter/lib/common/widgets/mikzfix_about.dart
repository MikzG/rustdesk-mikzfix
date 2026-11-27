// mikzfix: "About MikzFix Remote" (desktop Settings > About and the Android About dialog).
// Theme colours only; no coloured block, no native controls.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:url_launcher/url_launcher.dart';

const kMikzfixSourceUrl = 'https://github.com/MikzG/rustdesk-mikzfix';

class MikzfixAboutView extends StatelessWidget {
  final String version;
  final String buildDate;
  final String id;
  final String fingerprint;

  const MikzfixAboutView({
    Key? key,
    required this.version,
    this.buildDate = '',
    this.id = '',
    this.fingerprint = '',
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color?.withOpacity(0.7);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header: app icon, name, version
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/icon.png',
                  width: 64, height: 64, filterQuality: FilterQuality.medium),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('MikzFix Remote',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('${translate('Version')} $version',
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Details card
        Container(
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.dividerColor.withOpacity(0.5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(
            children: [
              _row(context, translate('Version'), version),
              if (buildDate.isNotEmpty)
                _row(context, translate('Build Date'), buildDate),
              if (id.isNotEmpty) _row(context, translate('ID'), id, copy: true),
              if (fingerprint.isNotEmpty)
                _row(context, translate('Fingerprint'), fingerprint,
                    copy: true, last: true),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // Links, outline buttons, labels in the app language
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _link(translate('Website'), 'https://mikzfix.tech/'),
            _link(translate('mikzfix_privacy'), 'https://mikzfix.tech/privacy'),
            _link(translate('mikzfix_terms'), 'https://mikzfix.tech/terms'),
            _link(translate('mikzfix_source'), kMikzfixSourceUrl),
          ],
        ),
        const SizedBox(height: 16),
        Text(translate('mikzfix_about_license'),
            style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        const SizedBox(height: 18),
        const Center(child: MikzBotsCredit()),
      ],
    );
  }

  Widget _row(BuildContext context, String label, String value,
      {bool copy = false, bool last = false}) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(
                bottom: BorderSide(
                    color: theme.dividerColor.withOpacity(0.3), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.textTheme.bodyMedium?.color?.withOpacity(0.7))),
          ),
          Expanded(
            child: SelectableText(value,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w500)),
          ),
          if (copy)
            IconButton(
              icon: const Icon(Icons.copy_rounded, size: 16),
              splashRadius: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                showToast(translate('Copied'));
              },
            ),
        ],
      ),
    );
  }

  Widget _link(String label, String url) {
    return OutlinedButton(
      onPressed: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 32),
      ),
      child: Text(label),
    );
  }
}
