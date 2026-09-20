import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/pages/editor.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class EditProfileView extends StatefulWidget {
  final Profile profile;
  final BuildContext context;
  final bool isNew;

  const EditProfileView({
    super.key,
    required this.context,
    required this.profile,
    this.isNew = false,
  });

  @override
  State<EditProfileView> createState() => EditProfileViewState();
}

class EditProfileViewState extends State<EditProfileView> {
  static const double _listGapHeight = 24;

  late TextEditingController labelController;
  late TextEditingController urlController;
  late TextEditingController autoUpdateDurationController;
  late bool autoUpdate;
  late bool followUpdate;
  late TextEditingController ageSecretKeyController;
  FocusNode? urlFocusNode;
  bool _obscureAgeSecretKey = true;
  bool _updateTipVisible = false;
  bool _updateTipSuccess = true;
  String? _updateTipReason;
  Timer? _updateTipTimer;
  String? rawText;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final fileInfoNotifier = ValueNotifier<FileInfo?>(null);
  Uint8List? fileData;

  Profile get profile => widget.profile;

  @override
  void initState() {
    super.initState();
    labelController = TextEditingController(text: widget.profile.label);
    urlController = TextEditingController(text: widget.profile.url);
    autoUpdate = widget.isNew ? false : widget.profile.autoUpdate;
    followUpdate = widget.isNew ? true : widget.profile.followUpdate;
    autoUpdateDurationController = TextEditingController(
      text: widget.profile.autoUpdateDuration.inMinutes.toString(),
    );
    ageSecretKeyController = TextEditingController(
      text: widget.profile.ageSecretKey,
    );
    if (widget.isNew) {
      urlFocusNode = FocusNode();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            urlFocusNode?.requestFocus();
          }
        });
      });
    }
    appPath.getProfilePath(widget.profile.id).then((path) async {
      fileInfoNotifier.value = await _getFileInfo(path);
    });
  }

  @override
  void dispose() {
    labelController.dispose();
    urlController.dispose();
    autoUpdateDurationController.dispose();
    ageSecretKeyController.dispose();
    urlFocusNode?.dispose();
    _updateTipTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleConfirm() async {
    if (!_formKey.currentState!.validate()) return;
    final appController = globalState.appController;
    Profile profile = _buildProfileFromForm();
    if (widget.isNew) {
      final ref = appController.ref;
      ref.read(loadingProvider.notifier).value = true;
      try {
        final updatedProfile = await profile.update();
        await appController.addProfile(updatedProfile);
      } on Object catch (e) {
        if (mounted) {
          await globalState.showMessage(
            title: appLocalizations.tip,
            message: TextSpan(text: e.formatError),
            cancelable: false,
          );
        }
        return;
      } finally {
        ref.read(loadingProvider.notifier).value = false;
      }
    } else {
      final hasUpdate = widget.profile.url != profile.url;
      if (fileData != null) {
        if (profile.type == ProfileType.url && autoUpdate) {
          final res = await globalState.showMessage(
            title: appLocalizations.tip,
            message: TextSpan(text: appLocalizations.profileHasUpdate),
          );
          if (res == true) {
            profile = profile.copyWith(autoUpdate: false);
          }
        }
        try {
          final updatedProfile = await profile.saveFile(fileData!);
          appController.setProfileAndAutoApply(updatedProfile);
        } catch (e) {
          if (mounted) {
            await globalState.showMessage(
              title: appLocalizations.tip,
              message: TextSpan(text: e.toString()),
              cancelable: false,
            );
          }
          return;
        }
      } else if (!hasUpdate) {
        appController.setProfileAndAutoApply(profile);
      } else {
        try {
          await Future.delayed(commonDuration);
          await appController.updateProfile(profile);
        } on Object catch (e) {
          await globalState.showMessage(
            title: appLocalizations.tip,
            message: TextSpan(
              text: '${profile.label ?? profile.id}: ${e.formatError}',
            ),
            cancelable: false,
          );
        }
      }
    }
    if (mounted) {
      Navigator.of(context).pop();
      if (widget.isNew && widget.context.mounted) {
        Navigator.of(widget.context).pop();
      }
    }
  }

  Profile _buildProfileFromForm() {
    return profile.copyWith(
      url: urlController.text,
      label: labelController.text.trim().isEmpty
          ? null
          : labelController.text.trim(),
      ageSecretKey: ageSecretKeyController.text.trim().isEmpty
          ? null
          : ageSecretKeyController.text.trim(),
      autoUpdate: autoUpdate,
      followUpdate: followUpdate,
      autoUpdateDuration: Duration(
        minutes:
            int.tryParse(autoUpdateDurationController.text) ??
            profile.autoUpdateDuration.inMinutes,
      ),
    );
  }

  /// 手动更新当前配置：仅更新这一个配置，不受「跟随更新」开关影响。
  /// 失败只弹「更新失败」提示，不弹全局错误弹框（原始错误写进日志）。
  Future<void> updateFromUrl() async {
    if (!_formKey.currentState!.validate()) return;
    final appController = globalState.appController;
    final loading = appController.ref.read(loadingProvider.notifier);
    loading.value = true;
    bool updated = false;
    try {
      updated = await appController.updateProfile(_buildProfileFromForm());
      if (updated) {
        fileInfoNotifier.value = await _getFileInfo(
          await appPath.getProfilePath(widget.profile.id),
        );
      }
    } on Object catch (e) {
      commonPrint.log(e.formatErrorLog);
      _showUpdateTip(success: false, reason: _updateErrorReason(e));
      return;
    } finally {
      loading.value = false;
    }
    // updated 为 false 表示同一配置已有更新在途，静默跳过。
    if (updated) {
      _showUpdateTip();
    }
  }

  /// 失败提示里的简短原因：HTTP 错误只报状态码，其它错误压成一行。
  String _updateErrorReason(Object e) {
    final statusCode = RegExp(
      r'status code of (\d+)',
    ).firstMatch(e.toString())?.group(1);
    if (statusCode != null) {
      return 'HTTP $statusCode';
    }
    return e.formatError.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void _showUpdateTip({bool success = true, String? reason}) {
    if (!mounted) return;
    _updateTipTimer?.cancel();
    setState(() {
      _updateTipSuccess = success;
      _updateTipReason = success ? null : reason;
      _updateTipVisible = true;
    });
    _updateTipTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() {
        _updateTipVisible = false;
      });
    });
  }

  Widget _buildUpdateTip(BuildContext context, {required bool success}) {
    final colorScheme = context.colorScheme;
    final reason = success ? null : _updateTipReason;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: success ? colorScheme.primary : colorScheme.error,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.2),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            success
                ? appLocalizations.updateSuccess
                : appLocalizations.updateFailed,
            style: context.textTheme.bodyMedium?.copyWith(
              color: success ? colorScheme.onPrimary : colorScheme.onError,
              height: 1.0,
            ),
          ),
          if (reason != null) ...[
            const SizedBox(height: 4),
            Text(
              reason,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodySmall?.copyWith(
                color: colorScheme.onError.withValues(alpha: 0.9),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 更新提示占位（成功/失败共用）：与列表分隔同高，提示本身溢出该槽位、
  /// 纵向居中于「跟随更新」与「配置」两行之间的留白带，出现与消失都不推动列表。
  Widget _buildUpdateTipSlot(BuildContext context) {
    return SizedBox(
      height: _listGapHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return IgnorePointer(
            child: AnimatedOpacity(
              opacity: _updateTipVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: OverflowBox(
                minWidth: 0,
                maxWidth: constraints.maxWidth * 0.86,
                minHeight: 0,
                maxHeight: double.infinity,
                child: _buildUpdateTip(context, success: _updateTipSuccess),
              ),
            ),
          );
        },
      ),
    );
  }

  void _setAutoUpdate(bool value) {
    if (autoUpdate == value) return;
    setState(() {
      autoUpdate = value;
    });
  }

  void _setFollowUpdate(bool value) {
    if (followUpdate == value) return;
    setState(() {
      followUpdate = value;
    });
  }

  Future<FileInfo?> _getFileInfo(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    final lastModified = await file.lastModified();
    final size = await file.length();
    return FileInfo(size: size, lastModified: lastModified);
  }

  Future<void> _handleSaveEdit(BuildContext context, String data) async {
    final message = await globalState.appController.safeRun<String>(() async {
      final originalMessage = await clashCore.validateConfig(
        data,
        ageSecretKey: ageSecretKeyController.text.trim(),
      );
      if (originalMessage.isEmpty) return '';
      final patched = utils.patchValidateConfig(data);
      if (patched == data) return originalMessage;
      final patchedMessage = await clashCore.validateConfig(
        patched,
        ageSecretKey: ageSecretKeyController.text.trim(),
      );
      return patchedMessage.isEmpty ? '' : originalMessage;
    }, silence: false);
    if (message?.isNotEmpty == true) {
      globalState.showMessage(
        title: appLocalizations.tip,
        message: TextSpan(text: message),
        cancelable: false,
      );
      return;
    }
    if (context.mounted) {
      Navigator.of(context).pop(utils.patchValidateConfig(data));
    }
  }

  Future<void> _editProfileFile() async {
    if (rawText == null) {
      final profilePath = await appPath.getProfilePath(widget.profile.id);
      final file = File(profilePath);
      if (await file.exists()) {
        rawText = await file.readAsString();
      }
    }
    if (!mounted) return;
    final title = widget.profile.label ?? widget.profile.id;
    final editorPage = EditorPage(
      title: title,
      content: rawText!,
      onSave: (context, _, content) {
        _handleSaveEdit(context, content);
      },
      onPop: (context, _, content) async {
        if (content == rawText) {
          return true;
        }
        final res = await globalState.showMessage(
          title: title,
          message: TextSpan(text: appLocalizations.hasCacheChange),
        );
        if (res == true && context.mounted) {
          _handleSaveEdit(context, content);
        } else {
          return true;
        }
        return false;
      },
    );
    final data = await BaseNavigator.push<String>(context, editorPage);
    if (data == null) {
      return;
    }
    rawText = data;
    fileData = Uint8List.fromList(utf8.encode(data));
    fileInfoNotifier.value = fileInfoNotifier.value?.copyWith(
      size: fileData?.length ?? 0,
      lastModified: DateTime.now(),
    );
  }

  Future<void> _uploadProfileFile() async {
    final platformFile = await globalState.appController.safeRun(
      picker.pickerFile,
    );
    if (platformFile?.bytes == null) return;
    fileData = platformFile?.bytes;
    fileInfoNotifier.value = fileInfoNotifier.value?.copyWith(
      size: fileData?.length ?? 0,
      lastModified: DateTime.now(),
    );
  }

  Future<void> _handleBack() async {
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.fileIsUpdate),
    );
    if (res == true) {
      _handleConfirm();
    } else {
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  void showAgeKeyGenerator() {
    globalState.showCommonDialog(child: const _AgeKeyGeneratorDialog());
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      ListItem(
        title: TextFormField(
          textInputAction: TextInputAction.next,
          controller: labelController,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: appLocalizations.name,
            hintText: widget.isNew ? appLocalizations.autoGetNameTip : null,
          ),
          validator: (String? value) {
            if (!widget.isNew && (value == null || value.isEmpty)) {
              return appLocalizations.profileNameNullValidationDesc;
            }
            return null;
          },
        ),
      ),
      if (widget.profile.type == ProfileType.url || widget.isNew) ...[
        ListItem(
          title: TextFormField(
            focusNode: urlFocusNode,
            textInputAction: TextInputAction.next,
            keyboardType: TextInputType.url,
            controller: urlController,
            maxLines: 5,
            minLines: 1,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: appLocalizations.url,
            ),
            onEditingComplete: widget.isNew
                ? () => FocusManager.instance.primaryFocus?.unfocus()
                : null,
            validator: (String? value) {
              if (value == null || value.isEmpty) {
                return appLocalizations.profileUrlNullValidationDesc;
              }
              if (!value.isUrl) {
                return appLocalizations.profileUrlInvalidValidationDesc;
              }
              return null;
            },
          ),
        ),
        ListItem(
          title: TextFormField(
            textInputAction: TextInputAction.next,
            controller: ageSecretKeyController,
            obscureText: _obscureAgeSecretKey,
            maxLines: 1,
            minLines: 1,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: appLocalizations.ageSecretKeyOptional,
              hintText: 'AGE-SECRET-KEY-...',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureAgeSecretKey
                      ? Icons.visibility
                      : Icons.visibility_off,
                ),
                onPressed: () {
                  setState(() {
                    _obscureAgeSecretKey = !_obscureAgeSecretKey;
                  });
                },
              ),
            ),
            validator: (String? value) {
              if (value != null && value.isNotEmpty) {
                if (!value.startsWith('AGE-SECRET-KEY-')) {
                  return appLocalizations.ageSecretKeyInvalidValidationDesc;
                }
              }
              return null;
            },
          ),
        ),
        ListItem.switchItem(
          title: Text(appLocalizations.autoUpdate),
          delegate: SwitchDelegate<bool>(
            value: autoUpdate,
            onChanged: _setAutoUpdate,
          ),
        ),
        if (autoUpdate)
          ListItem(
            title: TextFormField(
              textInputAction: TextInputAction.next,
              controller: autoUpdateDurationController,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: appLocalizations.autoUpdateInterval,
              ),
              validator: (String? value) {
                if (value == null || value.isEmpty) {
                  return appLocalizations
                      .profileAutoUpdateIntervalNullValidationDesc;
                }
                try {
                  int.parse(value);
                } catch (_) {
                  return appLocalizations
                      .profileAutoUpdateIntervalInvalidValidationDesc;
                }
                return null;
              },
            ),
          ),
        ListItem.switchItem(
          title: Text(appLocalizations.followUpdate),
          delegate: SwitchDelegate<bool>(
            value: followUpdate,
            onChanged: _setFollowUpdate,
          ),
        ),
      ],
      if (!widget.isNew)
        ValueListenableBuilder<FileInfo?>(
          valueListenable: fileInfoNotifier,
          builder: (_, fileInfo, _) {
            return FadeThroughBox(
              child: fileInfo == null
                  ? Container()
                  : ListItem(
                      title: Text(appLocalizations.profile),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          Text(fileInfo.desc),
                          const SizedBox(height: 8),
                          Wrap(
                            runSpacing: 6,
                            spacing: 12,
                            children: [
                              CommonChip(
                                avatar: const Icon(Icons.edit),
                                label: appLocalizations.edit,
                                onPressed: _editProfileFile,
                              ),
                              CommonChip(
                                avatar: const Icon(Icons.upload),
                                label: appLocalizations.upload,
                                onPressed: _uploadProfileFile,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
            );
          },
        ),
    ];
    // 更新成功提示放在「跟随更新」与「配置」之间（仅这两行相邻时存在该槽位）。
    final tipGapIndex = widget.isNew ? -1 : items.length - 2;
    final children = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      children.add(items[i]);
      if (i == items.length - 1) {
        break;
      }
      children.add(
        i == tipGapIndex
            ? _buildUpdateTipSlot(context)
            : const SizedBox(height: _listGapHeight),
      );
    }
    return CommonPopScope(
      onPop: () {
        if (dismissTvInputFocus()) {
          return false;
        }
        if (fileData == null) {
          return true;
        }
        _handleBack();
        return false;
      },
      child: FloatLayout(
        floatingWidget: FloatWrapper(
          child: FloatingActionButton.extended(
            heroTag: null,
            onPressed: _handleConfirm,
            label: Text(appLocalizations.save),
            icon: const Icon(Icons.save),
          ),
        ),
        child: Form(
          key: _formKey,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: ListView.builder(
              padding: kMaterialListPadding.copyWith(bottom: 72),
              itemBuilder: (_, index) {
                return children[index];
              },
              itemCount: children.length,
            ),
          ),
        ),
      ),
    );
  }
}

class _AgeKeyGeneratorDialog extends StatefulWidget {
  const _AgeKeyGeneratorDialog();

  @override
  State<_AgeKeyGeneratorDialog> createState() => _AgeKeyGeneratorDialogState();
}

class _AgeKeyGeneratorDialogState extends State<_AgeKeyGeneratorDialog> {
  late TextEditingController _privateKeyController;
  late TextEditingController _publicKeyController;
  bool _generateFromPrivateKey = false;
  String? _helperText;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _privateKeyController = TextEditingController();
    _publicKeyController = TextEditingController();
  }

  @override
  void dispose() {
    _privateKeyController.dispose();
    _publicKeyController.dispose();
    super.dispose();
  }

  Future<void> _handleGenerate() async {
    setState(() {
      _helperText = null;
    });

    final privateKey = _privateKeyController.text.trim();

    if (_generateFromPrivateKey) {
      if (privateKey.isEmpty || !privateKey.startsWith('AGE-SECRET-KEY-')) {
        setState(() {
          _helperText = appLocalizations.agePrivateKeyRequired;
        });
        return;
      }

      setState(() {
        _isGenerating = true;
      });

      try {
        final result = await clashCore.convertAgeSecretKeyToPublicKey(
          privateKey,
        );
        if (result.isSuccess &&
            result.data != null &&
            result.data!.isNotEmpty) {
          setState(() {
            _publicKeyController.text = result.data!;
            _helperText = null;
          });
        } else {
          setState(() {
            _helperText = appLocalizations.agePrivateKeyRequired;
          });
        }
      } catch (e) {
        setState(() {
          _helperText = appLocalizations.agePrivateKeyRequired;
        });
      } finally {
        setState(() {
          _isGenerating = false;
        });
      }
    } else {
      setState(() {
        _isGenerating = true;
      });

      try {
        final keyPair = await clashCore.generateAgeKeyPair();
        final secKey = keyPair['secret-key'] ?? '';
        final pubKey = keyPair['public-key'] ?? '';

        if (secKey.isNotEmpty && pubKey.isNotEmpty) {
          setState(() {
            _privateKeyController.text = secKey;
            _publicKeyController.text = pubKey;
            _helperText = appLocalizations.ageKeyPairGeneratedSuccess;
          });
        }
      } catch (e) {
        setState(() {
          _helperText = e.toString();
        });
      } finally {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _copyToClipboard(String text) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      context.showNotifier(appLocalizations.copySuccess);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonDialog(
      title: appLocalizations.ageKeyGenerateTitle,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(appLocalizations.cancel),
        ),
        TextButton(
          onPressed: _isGenerating ? null : _handleGenerate,
          child: Text(appLocalizations.generateSecret),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          TextField(
            controller: _privateKeyController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              floatingLabelBehavior: FloatingLabelBehavior.always,
              labelText: appLocalizations.agePrivateKeyLabel,
              suffixIcon: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () => _copyToClipboard(_privateKeyController.text),
              ),
            ),
            onChanged: (_) {
              if (_helperText != null) {
                setState(() {
                  _helperText = null;
                });
              }
            },
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _publicKeyController,
            readOnly: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              floatingLabelBehavior: FloatingLabelBehavior.always,
              labelText: appLocalizations.agePublicKeyLabel,
              helperText: _helperText,
              helperMaxLines: 2,
              helperStyle: _helperText == appLocalizations.agePrivateKeyRequired
                  ? TextStyle(color: context.colorScheme.error)
                  : (_helperText == appLocalizations.ageKeyPairGeneratedSuccess
                        ? TextStyle(color: context.colorScheme.primary)
                        : null),
              suffixIcon: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () => _copyToClipboard(_publicKeyController.text),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(appLocalizations.generateFromPrivateKey),
              Switch(
                value: _generateFromPrivateKey,
                onChanged: (value) {
                  setState(() {
                    _generateFromPrivateKey = value;
                    _helperText = null;
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
