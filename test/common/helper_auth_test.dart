import 'package:bett_box/common/helper_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('helper 请求签名', () {
    // 与 services/helper/src/rpc.rs 的 `signature_matches_the_shared_fixed_vector`
    // 用同一个向量：两侧消息格式（`timestamp:nonce:body`）漂移时这里会先红。
    test('消息格式与 helper 侧钉在同一个固定向量上', () {
      final headers = HelperAuthManager.buildAuthHeaders(
        keyHex: '0123456789abcdef0123456789abcdef',
        body: '2:helper.ping:',
        timestamp: 1700000000,
        nonce: '00112233445566778899aabbccddeeff',
      );

      expect(headers['X-Timestamp'], '1700000000');
      expect(headers['X-Nonce'], '00112233445566778899aabbccddeeff');
      expect(
        headers['X-Signature'],
        'f280c7b7888c7455b6a15f6733be2ce25baa45a901c17686769fa73738428f3e',
      );
    });

    test('nonce 参与签名：只换 nonce 签名也会变', () {
      Map<String, String> sign(String nonce) =>
          HelperAuthManager.buildAuthHeaders(
            keyHex: '0123456789abcdef0123456789abcdef',
            body: '2:helper.ping:',
            timestamp: 1700000000,
            nonce: nonce,
          );

      expect(
        sign('aa')['X-Signature'],
        isNot(sign('bb')['X-Signature']),
      );
    });
  });
}
