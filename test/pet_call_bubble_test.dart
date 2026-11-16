// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/pet_call_bubble.dart';

void main() {
  const stageKey = ValueKey('stage');
  const figureKey = ValueKey('figure');
  const dockKey = ValueKey('dock');
  const longCaption = '这是一句需要完整保留的台词。';

  testWidgets('reopens the same caption from the compact dialogue marker', (
    tester,
  ) async {
    var collapsed = false;
    var jumps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, update) => collapsed
                  ? PetCallReviewButton(
                      onPressed: () => update(() => collapsed = false),
                    )
                  : PetCallBubble(
                      text: '窗外在下雨。',
                      index: 1,
                      count: 2,
                      autoplay: true,
                      playing: false,
                      onJump: (_, _) => jumps++,
                      onPause: () {},
                      onCollapse: () => update(() => collapsed = true),
                    ),
            ),
          ),
        ),
      ),
    );
    final caption = find.text('窗外在下雨。');
    final hide = find.byTooltip('收起对白');
    final show = find.byTooltip('展开对白');
    for (var i = 0; i < 2; i++) {
      expect(caption, findsOneWidget);
      await tester.tap(hide);
      await tester.pump();
      expect(caption, findsNothing);
      expect(find.byIcon(Icons.auto_awesome_rounded), findsOneWidget);
      await tester.tap(show);
      await tester.pump();
      expect(find.text('2/2'), findsOneWidget);
    }
    expect(jumps, 0);
  });

  testWidgets(
    'shows live phases and a usable interrupt inside the speech surface',
    (tester) async {
      final start = DateTime.now().subtract(const Duration(seconds: 5));
      var interrupted = false;
      Future<void> show(PetCallProgress progress, {String? caption}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 255),
                    child: PetCallBubble(
                      text: caption,
                      index: -1,
                      count: 0,
                      autoplay: true,
                      playing: false,
                      progress: progress,
                      onInterrupt: () => interrupted = true,
                      onJump: (_, _) {},
                      onPause: () {},
                    ),
                  ),
                ),
              ),
            ),
          );

      await show(
        PetCallProgress(
          label: '正在检索记忆',
          phase: 'recalling-memory',
          step: 4,
          startedAt: start,
        ),
      );
      expect(
        find.descendant(
          of: find.byType(PetCallBubble),
          matching: find.text('正在检索记忆'),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.psychology_alt_outlined), findsOneWidget);
      expect(find.textContaining(RegExp(r'第 4 步 · \d+ 秒')), findsOneWidget);
      expect(tester.getSize(find.byType(PetCallBubble)).height, lessThan(60));

      await show(
        PetCallProgress(label: '等待模型响应', icon: 'clock', startedAt: start),
        caption: '欢迎来到暮色书房。',
      );
      expect(find.text('正在检索记忆'), findsNothing);
      expect(find.text('等待模型响应'), findsOneWidget);
      expect(find.text('欢迎来到暮色书房。'), findsOneWidget);
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
      await tester.tap(find.byTooltip('打断'));
      expect(interrupted, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the first caption and live progress fit with playback controls',
    (tester) async {
      const stageSize = Size(390, 610);
      const head = Rect.fromLTWH(.16, .18, .66, .28);
      const caption = '大笨鱼来大笨鱼去，你是不是就记着这一个词了';
      var paused = false;
      var interrupted = false;
      Future<void> show({required bool hasCaption}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox.fromSize(
                size: stageSize,
                child: PetCallStage(
                  figure: const ColoredBox(key: figureKey, color: Colors.blue),
                  headBounds: hasCaption ? head : null,
                  keyboardInset: 0,
                  dock: const SizedBox(key: dockKey, width: 50, height: 66),
                  bubble: PetCallBubble(
                    text: hasCaption ? caption : null,
                    index: hasCaption ? 0 : -1,
                    count: hasCaption ? 2 : 0,
                    autoplay: true,
                    playing: hasCaption,
                    progress: const PetCallProgress(
                      label: '等待模型响应',
                      icon: 'clock',
                      step: 1,
                    ),
                    onJump: (_, _) {},
                    onPause: () => paused = true,
                    onCollapse: () {},
                    onInterrupt: () => interrupted = true,
                    onHistory: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await show(hasCaption: false);
      final figure = tester.getRect(find.byKey(figureKey));
      expect(find.byTooltip('打断').hitTestable(), findsOneWidget);
      await show(hasCaption: true);
      expect(tester.getRect(find.byKey(figureKey)), figure);
      final bubble = tester.getRect(find.byType(PetCallBubble));
      expect(bubble.top, greaterThan(figure.top + head.bottom * figure.height));
      expect(
        bubble.bottom,
        lessThan(tester.getTopLeft(find.byKey(dockKey)).dy),
      );
      for (final label in ['暂停自动播放', '下一段', '收起对白', '打断']) {
        expect(find.byTooltip(label).hitTestable(), findsOneWidget);
      }
      expect(
        bubble.contains(tester.getBottomRight(find.text(caption))),
        isTrue,
      );
      await tester.tap(find.byTooltip('暂停自动播放'));
      await tester.tap(find.byTooltip('打断'));
      expect(paused && interrupted, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [280.0, 780.0]) {
    testWidgets(
      'positions the bubble without changing the stage at width $width',
      (tester) async {
        final stage = Size(width, 340);
        final figure = width < 300
            ? const Rect.fromLTWH(.04, .27, .92, .71)
            : const Rect.fromLTWH(.35, .08, .30, .90);
        (int, bool)? selected;

        Future<void> show({bool caption = false, bool composer = false}) =>
            tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: Center(
                    child: SizedBox.fromSize(
                      key: stageKey,
                      size: stage,
                      child: PetCallStage(
                        figure: const ColoredBox(
                          key: figureKey,
                          color: Colors.blue,
                        ),
                        headBounds: figure,
                        keyboardInset: composer ? 80 : 0,
                        bubble: caption
                            ? PetCallBubble(
                                text: List.filled(18, longCaption).join(),
                                index: 1,
                                count: 3,
                                autoplay: false,
                                playing: false,
                                onJump: (index, autoplay) =>
                                    selected = (index, autoplay),
                                onPause: () {},
                              )
                            : null,
                        dock: composer
                            ? SizedBox(key: dockKey, width: width, height: 55)
                            : PetCallInputButton(
                                key: dockKey,
                                onPressed: () {},
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            );

        await show();
        final original = tester.getRect(find.byKey(figureKey));
        expect(original, tester.getRect(find.byKey(stageKey)));
        expect(find.byTooltip('展开会面输入'), findsOneWidget);
        expect(
          tester.getSize(
            find.descendant(
              of: find.byType(PetCallInputButton),
              matching: find.byType(Ink),
            ),
          ),
          const Size.square(50),
        );

        await show(caption: true, composer: true);
        expect(tester.getRect(find.byKey(figureKey)), original);
        final bubble = tester.getRect(find.byType(PetCallBubble));
        expect(bubble.left, greaterThan(original.left));
        expect(bubble.right, lessThan(original.right));
        expect(bubble.top, greaterThan(original.top));
        expect(
          bubble.bottom,
          lessThan(tester.getTopLeft(find.byKey(dockKey)).dy),
        );
        if (width < 300) {
          expect(
            bubble.bottom,
            lessThan(original.top + stage.height * figure.top),
          );
        } else {
          expect(
            bubble.left,
            greaterThan(original.left + stage.width * figure.right),
          );
        }

        final previous = find.byTooltip('上一段');
        expect(previous.hitTestable(), findsOneWidget);
        await tester.tap(previous);
        expect(selected, (0, false));
        await tester.tap(find.byTooltip('从头播放'));
        expect(selected, (0, true));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
