import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/pages/scan.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'edit_profile.dart';

class AddProfileView extends StatelessWidget {
  final BuildContext context;

  const AddProfileView({super.key, required this.context});

  Future<void> _handleAddProfileFormFile() async {
    globalState.appController.addProfileFormFile();
  }

  Future<void> _handleAddProfileFormURL(
    String url, {
    String? ageSecretKey,
    BuildContext? replaceContext,
  }) async {
    final editKey = GlobalKey<EditProfileViewState>();
    final profile = Profile.normal(
      url: url,
      ageSecretKey: ageSecretKey,
    );
    Widget builder(BuildContext builderContext, SheetType type) {
      return AdaptiveSheetScaffold(
        type: type,
        actions: [
          IconButton(
            icon: const Icon(Icons.security),
            tooltip: appLocalizations.ageKeyGenerateTitle,
            onPressed: () {
              editKey.currentState?.showAgeKeyGenerator();
            },
          ),
        ],
        body: EditProfileView(
          key: editKey,
          profile: profile,
          context: context,
          isNew: true,
        ),
        title: appLocalizations.importFromURL,
      );
    }
    if (replaceContext != null) {
      showExtend(replaceContext, builder: builder, replace: true);
    } else {
      showExtend(context, builder: builder);
    }
  }

  Future<void> _handleAddProfileFromClipboard() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboardData?.text?.trim();

      if (text == null || text.isEmpty) {
        if (context.mounted) {
          context.showSnackBar(
            appLocalizations.emptyTip(appLocalizations.clipboard),
          );
        }
        return;
      }

      if (!text.isUrl) {
        if (context.mounted) {
          context.showSnackBar(
            appLocalizations.urlTip(appLocalizations.clipboard),
          );
        }
        return;
      }

      _handleAddProfileFormURL(text);
    } catch (e) {
      if (context.mounted) {
        context.showSnackBar(e.toString());
      }
    }
  }

  Future<void> _toScan() async {
    if (system.isDesktop) {
      globalState.appController.addProfileFormQrCode();
      return;
    }
    await BaseNavigator.push(context, ScanPage(onRecognized: _toImportAfterScan));
  }

  /// 扫码识别成功：直接换成「从 URL 导入」页，不先退回本页。
  /// 横屏 / 宽窗口下导入页是侧边 sheet（没有可替换的整页），这时先关掉扫码页。
  void _toImportAfterScan(BuildContext scanContext, String url) {
    if (globalState.appState.viewMode == ViewMode.mobile) {
      _handleAddProfileFormURL(url, replaceContext: scanContext);
      return;
    }
    Navigator.of(scanContext).pop();
    _handleAddProfileFormURL(url);
  }

  Future<void> _toAdd() async {
    _handleAddProfileFormURL('');
  }

  @override
  Widget build(context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        CommonCard(
          type: CommonCardType.filled,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListItem(
                leading: const Icon(Icons.qr_code_sharp),
                title: Text(appLocalizations.qrcode),
                subtitle: Text(appLocalizations.qrcodeDesc),
                onTap: _toScan,
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: context.colorScheme.outlineVariant.withValues(
                  alpha: context.colorScheme.brightness == Brightness.light ? 0.6 : 0.45,
                ),
                indent: 16,
                endIndent: 16,
              ),
              ListItem(
                leading: const Icon(Icons.content_paste),
                title: Text(appLocalizations.clipboard),
                subtitle: Text(appLocalizations.clipboardDesc),
                onTap: _handleAddProfileFromClipboard,
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: context.colorScheme.outlineVariant.withValues(
                  alpha: context.colorScheme.brightness == Brightness.light ? 0.6 : 0.45,
                ),
                indent: 16,
                endIndent: 16,
              ),
              ListItem(
                leading: const Icon(Icons.upload_file_sharp),
                title: Text(appLocalizations.file),
                subtitle: Text(appLocalizations.fileDesc),
                onTap: _handleAddProfileFormFile,
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: context.colorScheme.outlineVariant.withValues(
                  alpha: context.colorScheme.brightness == Brightness.light ? 0.6 : 0.45,
                ),
                indent: 16,
                endIndent: 16,
              ),
              ListItem(
                leading: const Icon(Icons.cloud_download_sharp),
                title: Text(appLocalizations.url),
                subtitle: Text(appLocalizations.urlDesc),
                onTap: _toAdd,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
