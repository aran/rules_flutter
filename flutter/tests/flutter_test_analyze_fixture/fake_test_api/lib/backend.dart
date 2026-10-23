/// Stands in for `package:test_api`, which the root workspace has no pub hub
/// to supply.
///
/// Implements the minimal `RemoteListener.start` MultiChannel wire protocol
/// expected by `flutter_test`'s generated bootstrap and `flutter_test_runner`,
/// so `flutter_test` targets in `//flutter/tests` can both analyze and execute
/// under `flutter_tester`.
library;

import 'dart:async';

/// Present so existing callers referencing `backendPlaceholder` continue to
/// resolve.
const String backendPlaceholder = 'test_api';

final List<({String name, FutureOr<void> Function() body})> _registeredTests =
    <({String name, FutureOr<void> Function() body})>[];

/// Registers a test case when a suite uses `test(...)` instead of asserting
/// directly in `main()`.
void test(String name, FutureOr<void> Function() body) {
  _registeredTests.add((name: name, body: body));
}

/// Minimal bidirectional channel matching the `stream` / `sink` surface the
/// generated `flutter_test` bootstrap pipes over the harness WebSocket.
class FakeTestChannel {
  FakeTestChannel(this.stream, this.sink);

  final Stream<dynamic> stream;
  final StreamSink<dynamic> sink;
}

/// Minimal `RemoteListener` speaking `flutter_test_runner`'s MultiChannel JSON
/// framing (`[channelId, message]`).
class RemoteListener {
  RemoteListener._();

  static FakeTestChannel start(
    Future<void> Function() Function() getMain, {
    bool hidePrints = true,
  }) {
    final incoming = StreamController<dynamic>();
    final outgoing = StreamController<dynamic>();
    final handlers = <int, Future<void> Function(Map<String, dynamic>)>{};

    incoming.stream.listen((dynamic raw) async {
      if (raw is! List || raw.length < 2) return;
      final channelId = (raw[0] as num).toInt();
      final payload = raw[1];
      if (payload is! Map) return;
      final msg = payload.cast<String, dynamic>();

      if (channelId == 0) {
        final type = msg['type'] as String?;
        if (type == 'initial') {
          _registeredTests.clear();
          Object? mainError;
          StackTrace? mainStack;
          try {
            final runMain = getMain();
            await runMain();
          } on Object catch (e, st) {
            mainError = e;
            mainStack = st;
          }

          final entries = <Map<String, dynamic>>[];
          if (_registeredTests.isEmpty) {
            const testChannelId = 2;
            handlers[testChannelId + 1] = (Map<String, dynamic> cmd) async {
              if (cmd['command'] != 'run') return;
              final replyId = (cmd['channel'] as num).toInt() + 1;
              if (mainError != null) {
                outgoing.add(<dynamic>[
                  replyId,
                  <String, dynamic>{
                    'type': 'error',
                    'error': <String, dynamic>{
                      'message': mainError.toString(),
                      'type': mainError.runtimeType.toString(),
                      'stackChain': (mainStack ?? StackTrace.empty).toString(),
                    },
                  },
                ]);
              }
              outgoing.add(<dynamic>[
                replyId,
                <String, dynamic>{'type': 'complete'},
              ]);
            };
            entries.add(<String, dynamic>{
              'type': 'test',
              'name': 'main',
              'channel': testChannelId,
              'metadata': <String, dynamic>{'skip': false},
            });
          } else {
            var nextChannelId = 2;
            for (final registered
                in List<({String name, FutureOr<void> Function() body})>.of(
                  _registeredTests,
                )) {
              final testChannelId = nextChannelId;
              nextChannelId += 2;
              handlers[testChannelId + 1] = (Map<String, dynamic> cmd) async {
                if (cmd['command'] != 'run') return;
                final replyId = (cmd['channel'] as num).toInt() + 1;
                try {
                  await registered.body();
                } on Object catch (e, st) {
                  outgoing.add(<dynamic>[
                    replyId,
                    <String, dynamic>{
                      'type': 'error',
                      'error': <String, dynamic>{
                        'message': e.toString(),
                        'type': e.runtimeType.toString(),
                        'stackChain': st.toString(),
                      },
                    },
                  ]);
                }
                outgoing.add(<dynamic>[
                  replyId,
                  <String, dynamic>{'type': 'complete'},
                ]);
              };
              entries.add(<String, dynamic>{
                'type': 'test',
                'name': registered.name,
                'channel': testChannelId,
                'metadata': <String, dynamic>{'skip': false},
              });
            }
          }

          outgoing.add(<dynamic>[
            0,
            <String, dynamic>{
              'type': 'success',
              'root': <String, dynamic>{
                'type': 'group',
                'name': '',
                'metadata': <String, dynamic>{'skip': false},
                'entries': entries,
              },
            },
          ]);
        } else if (type == 'close') {
          await outgoing.close();
        }
        return;
      }

      final handler = handlers[channelId];
      if (handler != null) {
        await handler(msg);
      }
    });

    return FakeTestChannel(outgoing.stream, incoming.sink);
  }
}
