import 'package:fl_clash/clash/core.dart';
import 'package:fl_clash/clash/interface.dart';
import 'package:flutter_test/flutter_test.dart';

class TestInterface implements ClashHandlerInterface {
  final bool accepted;
  TestInterface(this.accepted);
  @override
  Future<bool> startListener() async => accepted;
  @override
  Future<bool> stopListener() async => accepted;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final result in [true, false]) {
    test('GUI core facade returns actual listener result $result', () async {
      final core = ClashCore.withInterface(TestInterface(result));
      expect(await core.startListener(), result);
      expect(await core.stopListener(), result);
    });
  }
}
