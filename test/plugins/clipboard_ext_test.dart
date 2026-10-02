import 'package:bett_box/plugins/clipboard_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = 'clipboard_ext';
  const pastedText = 'pasted-from-native-channel';

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          expect(call.arguments, Clipboard.kTextPlain);
          return <String, dynamic>{'text': pastedText};
        }
        return null;
      },
    );
  }

  /// 模拟原生侧（Windows 运行器）在收到 WM_PASTE 后发来的通道调用。
  Future<void> sendNativePaste(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('paste')),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets('原生粘贴写入当前聚焦的输入框', (tester) async {
    clipboardExt.init();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    mockClipboard(tester);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TextFormField(controller: controller))),
    );
    await tester.tap(find.byType(TextFormField));
    await tester.pump();

    await sendNativePaste(tester);

    expect(controller.text, pastedText);
  });

  testWidgets('没有聚焦输入框时原生粘贴不抛异常', (tester) async {
    clipboardExt.init();
    mockClipboard(tester);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('no field here'))),
    );

    await sendNativePaste(tester);
  });
}
