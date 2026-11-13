import 'package:flutter_test/flutter_test.dart';
import 'package:p2pc_core/p2pc_core.dart';

void main() {
  test('the v2 core is built into the app and its self-test passes', () {
    final report = coreSelfTest();
    expect(report['ok'], isTrue, reason: '${report['steps']}');
    expect(report['ciphersuite'], contains('0x0003'));
  });
}
