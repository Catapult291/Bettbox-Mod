import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

Future<void> showProfileShareDialog({
  required BuildContext context,
  required Profile profile,
}) {
  return globalState.showCommonDialog(
    child: ProfileShareDialog(profile: profile),
  );
}

class ProfileShareDialog extends StatefulWidget {
  final Profile profile;

  const ProfileShareDialog({super.key, required this.profile});

  @override
  State<ProfileShareDialog> createState() => _ProfileShareDialogState();
}

class _ProfileShareDialogState extends State<ProfileShareDialog> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleCopyLink() async {
    await Clipboard.setData(ClipboardData(text: widget.profile.url));
    if (!mounted) return;
    context.showNotifier(appLocalizations.copySuccess);
    setState(() {
      _copied = true;
    });
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _copied = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final url = widget.profile.url;
    final label = widget.profile.label ?? widget.profile.id;

    return CommonDialog(
      title: appLocalizations.share,
      maxWidth: 340,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(appLocalizations.confirm),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: QrImageView(
                data: url,
                version: QrVersions.auto,
                size: 190,
                gapless: true,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.textTheme.titleSmall,
          ),
          const SizedBox(height: 16),
          Text(
            appLocalizations.airportLink,
            style: context.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          InkWell(
            onTap: _handleCopyLink,
            borderRadius: BorderRadius.circular(12),
            child: Ink(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.link_rounded,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodySmall?.copyWith(
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _copied ? Icons.check_rounded : Icons.copy_rounded,
                    size: 18,
                    color: _copied
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
