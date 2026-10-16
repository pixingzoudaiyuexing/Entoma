import 'dart:async';
import 'dart:isolate';

import 'package:fl_clash/common/core_service_port.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client {
  final port = ReceivePort();
  late final messages = StreamIterator<dynamic>(port);

  SendPort get sendPort => port.sendPort;

  Future<dynamic> next() async {
    if (!await messages.moveNext().timeout(const Duration(seconds: 2))) {
      throw StateError('Client port closed without the expected message');
    }
    return messages.current;
  }

  Future<void> close() async {
    port.close();
    await messages.cancel();
  }
}

void main() {
  test('initial client gets ready command port and real command reply',
      () async {
    final client = _Client();
    final calls = <dynamic>[];
    final broker = CoreServicePort(handleAction: (message) {
      calls.add(message);
      return 'reply:$message';
    });
    addTearDown(client.close);
    addTearDown(broker.close);
    broker.attach(client.sendPort);
    final ready = await client.next();
    expect(ready, broker.sendPort);
    (ready as SendPort).send('getRunTime');
    expect(await client.next(), 'reply:getRunTime');
    expect(calls, ['getRunTime']);
  });

  test('replacement UI handshakes through the retained service command port',
      () async {
    final original = _Client();
    final replacement = _Client();
    final broker = CoreServicePort(handleAction: (message) => message);
    addTearDown(original.close);
    addTearDown(replacement.close);
    addTearDown(broker.close);
    broker.attach(original.sendPort);
    final retainedPort = await original.next() as SendPort;
    retainedPort.send(replacement.sendPort);
    final ready = await replacement.next();
    expect(ready, retainedPort);
    (ready as SendPort).send('new-ui-request');
    expect(await replacement.next(), 'new-ui-request');
    original.sendPort.send('old-client-marker');
    expect(await original.next(), 'old-client-marker');
  });

  test(
      'old in-flight reply never resolves replacement UI callback with same id',
      () async {
    final original = _Client();
    final replacement = _Client();
    final oldStarted = Completer<void>();
    final oldReply = Completer<Object?>();
    final broker = CoreServicePort(handleAction: (message) {
      final request = message as Map;
      if (request['owner'] == 'old') {
        oldStarted.complete();
        return oldReply.future;
      }
      return {'id': request['id'], 'replyOwner': request['owner']};
    });
    addTearDown(original.close);
    addTearDown(replacement.close);
    addTearDown(broker.close);
    broker.attach(original.sendPort);
    final commands = await original.next() as SendPort;
    commands.send({'id': 1, 'owner': 'old'});
    await oldStarted.future;
    commands.send(replacement.sendPort);
    expect(await replacement.next(), commands);
    commands.send({'id': 1, 'owner': 'new'});
    expect(await replacement.next(), {'id': 1, 'replyOwner': 'new'});
    oldReply.complete({'id': 1, 'replyOwner': 'old'});
    expect(await original.next(), {'id': 1, 'replyOwner': 'old'});
    commands.send({'id': 2, 'owner': 'new-barrier'});
    expect(await replacement.next(), {'id': 2, 'replyOwner': 'new-barrier'});
  });

  test('native message port attaches once and forwards only to current UI',
      () async {
    final original = _Client();
    final replacement = _Client();
    final attachedPorts = <SendPort>[];
    final broker = CoreServicePort(
        handleAction: (message) => message,
        attachMessagePort: attachedPorts.add);
    addTearDown(original.close);
    addTearDown(replacement.close);
    addTearDown(broker.close);
    expect(attachedPorts, [broker.messagePort]);
    broker.attach(original.sendPort);
    await original.next();
    broker.messagePort.send('old-ui-traffic');
    expect(await original.next(), 'old-ui-traffic');
    broker.sendPort.send(replacement.sendPort);
    await replacement.next();
    broker.messagePort.send('new-ui-traffic');
    expect(await replacement.next(), 'new-ui-traffic');
    original.sendPort.send('old-client-marker');
    expect(await original.next(), 'old-client-marker');
    expect(attachedPorts, hasLength(1));
  });

  test('service can attach a UI after starting without a UI client', () async {
    final client = _Client();
    final broker = CoreServicePort(handleAction: (message) => 'reply:$message');
    addTearDown(client.close);
    addTearDown(broker.close);
    broker.sendPort.send(client.sendPort);
    expect(await client.next(), broker.sendPort);
    broker.sendPort.send('getState');
    expect(await client.next(), 'reply:getState');
  });

  test('UI handshake proceeds while core action waits for service readiness',
      () async {
    final client = _Client();
    final replacement = _Client();
    final ready = Completer<void>();
    final waiting = Completer<void>();
    final calls = <dynamic>[];
    final broker = CoreServicePort(waitForReady: () {
      if (!waiting.isCompleted) waiting.complete();
      return ready.future;
    }, handleAction: (message) {
      calls.add(message);
      return 'reply:$message';
    });
    addTearDown(client.close);
    addTearDown(replacement.close);
    addTearDown(broker.close);
    broker.attach(client.sendPort);
    final commands = await client.next() as SendPort;
    commands.send('shutdown-after-quick-start');
    await waiting.future;
    expect(calls, isEmpty);
    commands.send(replacement.sendPort);
    expect(await replacement.next(), commands);
    expect(calls, isEmpty);
    ready.complete();
    expect(await client.next(), 'reply:shutdown-after-quick-start');
    commands.send('replacement-request');
    expect(await replacement.next(), 'reply:replacement-request');
    expect(calls, ['shutdown-after-quick-start', 'replacement-request']);
  });

  test('slow request does not block unrelated command or UI attachment',
      () async {
    final client = _Client();
    final firstStarted = Completer<void>();
    final firstReply = Completer<Object?>();
    final calls = <String>[];
    final broker = CoreServicePort(handleAction: (message) {
      calls.add(message as String);
      if (message == 'first') {
        firstStarted.complete();
        return firstReply.future;
      }
      return 'second-reply';
    });
    addTearDown(client.close);
    addTearDown(broker.close);
    broker.attach(client.sendPort);
    final commands = await client.next() as SendPort;
    commands.send('first');
    await firstStarted.future;
    commands.send(client.sendPort);
    expect(await client.next(), commands);
    expect(calls, ['first']);
    commands.send('second');
    expect(await client.next(), 'second-reply');
    expect(calls, ['first', 'second']);
    firstReply.complete('first-reply');
    expect(await client.next(), 'first-reply');
  });

  test(
      'close is idempotent and drops in-flight replies instead of stale UI use',
      () async {
    final client = _Client();
    final started = Completer<void>();
    final response = Completer<Object?>();
    final broker = CoreServicePort(handleAction: (_) {
      started.complete();
      return response.future;
    });
    addTearDown(client.close);
    addTearDown(broker.close);
    broker.attach(client.sendPort);
    final commands = await client.next() as SendPort;
    commands.send('held-request');
    await started.future;
    broker.close();
    broker.close();
    response.complete('late-reply');
    await Future<void>.delayed(Duration.zero);
    client.sendPort.send('client-marker');
    expect(await client.next(), 'client-marker');
    expect(() => broker.attach(client.sendPort), throwsStateError);
  });
}
