import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/mobile_api.dart';
import 'package:worldlinebox_mobile/mobile_speech.dart';

class _SpeechApi implements MobileApi {
  final pcm = StreamController<List<int>>();
  (String?, int?)? requestedCue;

  @override
  Stream<List<int>> speech(
    String room,
    String message, {
    String? part,
    int? pageIndex,
    Future<void>? cancel,
  }) {
    requestedCue = (part, pageIndex);
    return pcm.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final samples = <int>[];
  late Completer<void> start;

  setUp(() {
    calls.clear();
    samples.clear();
    start = Completer<void>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MobileSpeech.channel,
      (call) async {
        calls.add(call);
        if (call.method == 'start') start.complete();
        if (call.method == 'pcm') {
          final bytes = call.arguments['bytes'] as Uint8List;
          expect(bytes.length.isEven, isTrue);
          samples.addAll(bytes);
        }
        return null;
      },
    );
  });

  test('buffers across network gaps and preserves split PCM samples', () async {
    final api = _SpeechApi();
    final done = MobileSpeech().play(api, 'room', 'message', stage: 7);
    final first = Uint8List(23999);
    final second = Uint8List(24002)..last = 65;
    api.pcm.add(first);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, isEmpty);
    api.pcm.add(second);
    await start.future;
    api.pcm.add([66, 67, 68]);
    await api.pcm.close();
    await done;
    expect(calls.first.arguments['stage'], 7);
    expect(samples, [...first, ...second, 66, 67, 68]);
    expect(
      calls.map((call) => call.method).toList().sublist(calls.length - 2),
      ['drain', 'stop'],
    );
  });

  test('plays a short segment when the response ends', () async {
    final api = _SpeechApi();
    final done = MobileSpeech().play(
      api,
      'room',
      'message',
      part: 'cue',
      pageIndex: 1,
    );
    api.pcm.add([1, 2, 3, 4]);
    await api.pcm.close();
    await done;
    expect(api.requestedCue, ('cue', 1));
    expect(calls.map((call) => call.method), ['start', 'pcm', 'drain', 'stop']);
    expect(samples, [1, 2, 3, 4]);
  });

  test('cancels while buffering without starting playback', () async {
    final api = _SpeechApi();
    final speech = MobileSpeech();
    final done = speech.play(api, 'room', 'message');
    api.pcm.add([1, 2]);
    await Future<void>.delayed(Duration.zero);
    await speech.stop();
    await api.pcm.close();
    await done;
    expect(calls.map((call) => call.method), ['stop']);
  });
}
