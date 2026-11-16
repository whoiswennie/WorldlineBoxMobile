import 'dart:async';
import 'dart:math';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

const _paper = Color(0xfffffdfb);
const _edge = Color(0xffc9c6e6);
const _ink = Color(0xff2c2850);
const _muted = Color(0xff625978);
const _accent = Color(0xff6b5394);
const _tint = Color(0xfff1eafa);
const _minPinnedBubbleHeight = 64.0;

class PetCallProgress {
  const PetCallProgress({
    required this.label,
    this.phase,
    this.icon,
    this.step,
    this.startedAt,
    this.summary,
  });

  final String label;
  final String? phase;
  final String? icon;
  final int? step;
  final DateTime? startedAt;
  final String? summary;

  IconData get glyph => switch (icon ??
      switch (phase) {
        'memory-starting' ||
        'memory-verifying' ||
        'memory-indexing' ||
        'recalling-memory' => 'memory',
        'preparing-context' || 'compacting-context' || 'reconciling' => 'tasks',
        'queued' || 'waiting-runtime' || 'waiting-model' => 'clock',
        'using-tool' => 'settings',
        'retrying' => 'replay',
        'waiting-answer' => 'quote',
        _ => 'sparkles',
      }) {
    'memory' => Icons.psychology_alt_outlined,
    'tasks' => Icons.format_list_bulleted_rounded,
    'clock' => Icons.schedule_rounded,
    'settings' => Icons.tune_rounded,
    'replay' => Icons.refresh_rounded,
    'quote' => Icons.chat_bubble_outline_rounded,
    _ => Icons.auto_awesome_outlined,
  };
}

class _CallProgressLine extends StatefulWidget {
  const _CallProgressLine({required this.progress, this.onInterrupt});

  final PetCallProgress progress;
  final VoidCallback? onInterrupt;

  @override
  State<_CallProgressLine> createState() => _CallProgressLineState();
}

class _CallProgressLineState extends State<_CallProgressLine>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.progress.startedAt != null) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _clock.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final elapsed = progress.startedAt == null
        ? null
        : max(0, DateTime.now().difference(progress.startedAt!).inSeconds);
    final meta = [
      if (progress.step case final step?) '第 $step 步',
      if (elapsed case final seconds?) '$seconds 秒',
    ];
    final label = Semantics(
      liveRegion: true,
      child: Text(
        progress.label,
        style: const TextStyle(
          color: _accent,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: _tint,
          foregroundColor: _accent,
          child: Icon(progress.glyph, size: 15),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                children: [
                  if (progress.summary case final detail?
                      when detail.isNotEmpty)
                    Tooltip(message: detail, child: label)
                  else
                    label,
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (_, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 3; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: Transform.translate(
                              offset: Offset(
                                0,
                                -sin((_pulse.value - i * .1) * 2 * pi),
                              ),
                              child: const SizedBox.square(
                                dimension: 3,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: _accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (meta.isNotEmpty)
                Text(
                  meta.join(' · '),
                  style: const TextStyle(fontSize: 10, color: _muted),
                ),
            ],
          ),
        ),
        if (widget.onInterrupt case final stop?) ...[
          const SizedBox(width: 5),
          IconButton(
            tooltip: '打断',
            onPressed: stop,
            icon: const Icon(
              Icons.stop_rounded,
              size: 16,
              color: Color(0xff93354e),
            ),
          ),
        ],
      ],
    );
  }
}

class PetCallStage extends StatelessWidget {
  const PetCallStage({
    super.key,
    required this.figure,
    required this.dock,
    required this.keyboardInset,
    this.headBounds,
    this.bubble,
  });

  final Widget figure;
  final Widget dock;
  final double keyboardInset;
  final Rect? headBounds;
  final Widget? bubble;

  @override
  Widget build(BuildContext context) => CustomMultiChildLayout(
    delegate: _PetCallLayout(headBounds, keyboardInset),
    children: [
      LayoutId(id: #figure, child: figure),
      if (bubble case final child?) ...[
        LayoutId(
          id: #tail,
          child: IgnorePointer(
            child: Transform.rotate(
              angle: pi / 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _paper,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        LayoutId(id: #bubble, child: child),
      ],
      LayoutId(id: #dock, child: dock),
    ],
  );
}

class _PetCallLayout extends MultiChildLayoutDelegate {
  _PetCallLayout(this.bounds, this.keyboardInset);

  final Rect? bounds;
  final double keyboardInset;

  @override
  void performLayout(Size size) {
    layoutChild(#figure, BoxConstraints.tight(size));
    positionChild(#figure, Offset.zero);

    final dockBottom = max(0.0, size.height - keyboardInset);
    final dock = layoutChild(
      #dock,
      BoxConstraints(maxWidth: size.width, maxHeight: dockBottom),
    );
    final dockTop = dockBottom - dock.height;
    positionChild(#dock, Offset(size.width - dock.width, dockTop));
    if (!hasChild(#bubble)) return;

    const gap = 12.0;
    final padding = min(gap, size.width / 4);
    final top = min(gap, dockTop / 4);
    final safe = Rect.fromLTRB(
      padding,
      top,
      size.width - padding,
      max(top, dockTop - gap),
    );
    final portraitSize = min(size.width * .82, size.height * .85);
    final head = bounds == null
        ? Rect.fromCenter(
            center: size.center(Offset.zero),
            width: portraitSize,
            height: portraitSize,
          )
        : Rect.fromLTRB(
            bounds!.left * size.width,
            bounds!.top * size.height,
            bounds!.right * size.width,
            bounds!.bottom * size.height,
          );
    final left = (head.left - gap).clamp(safe.left, safe.right) - safe.left;
    final right = safe.right - (head.right + gap).clamp(safe.left, safe.right);
    final above = (head.top - gap).clamp(safe.top, safe.bottom) - safe.top;
    final below =
        safe.bottom - (head.bottom + gap).clamp(safe.top, safe.bottom);
    final sideRoom = max(left, right);
    final side = sideRoom >= 220 && safe.height >= 70;
    final readableHeight = min(_minPinnedBubbleHeight, safe.height * .4);
    final verticalRoom = max(above, below);

    final bubble = layoutChild(
      #bubble,
      BoxConstraints(
        maxWidth: min(360, side ? sideRoom : safe.width),
        maxHeight: min(
          168,
          side || verticalRoom < readableHeight ? safe.height : verticalRoom,
        ),
      ),
    );
    final x = (head.center.dx - bubble.width / 2).clamp(
      safe.left,
      safe.right - bubble.width,
    );
    final y = (head.center.dy - bubble.height / 2).clamp(
      safe.top,
      safe.bottom - bubble.height,
    );
    final Offset position;
    final Offset tail;
    final onTop =
        above >= bubble.height || (below < bubble.height && above > below);
    final outside = side || (onTop ? above : below) >= bubble.height;
    if (side) {
      final onRight = right >= left;
      position = Offset(
        onRight ? safe.right - right : safe.left + left - bubble.width,
        y,
      );
      tail =
          position +
          Offset(onRight ? -4 : bubble.width - 5, bubble.height / 2 - 4);
    } else {
      position = Offset(
        x,
        (onTop ? safe.top + above - bubble.height : safe.bottom - below).clamp(
          safe.top,
          safe.bottom - bubble.height,
        ),
      );
      tail =
          position +
          Offset(bubble.width / 2 - 4, onTop ? bubble.height - 5 : -4);
    }
    positionChild(#bubble, position);
    final tailSize = outside && bubble.shortestSide >= 20 ? 9.0 : 0.0;
    layoutChild(#tail, BoxConstraints.tight(Size.square(tailSize)));
    positionChild(#tail, tail);
  }

  @override
  bool shouldRelayout(_PetCallLayout oldDelegate) =>
      oldDelegate.bounds != bounds ||
      oldDelegate.keyboardInset != keyboardInset;
}

class PetCallReviewButton extends StatelessWidget {
  const PetCallReviewButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '展开对白',
    child: Material(
      color: _paper,
      elevation: 3,
      shadowColor: const Color(0x3321143b),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(17),
        side: const BorderSide(color: _edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 44,
          height: 38,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 3,
                children: List.filled(
                  3,
                  const SizedBox.square(
                    dimension: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _accent,
                      ),
                    ),
                  ),
                ),
              ),
              const Positioned(
                right: 3,
                top: 2,
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: Color(0xffaf784d),
                  size: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class PetCallInputButton extends StatelessWidget {
  const PetCallInputButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 0, 16, 16),
    child: Tooltip(
      message: '展开会面输入',
      child: Material(
        color: const Color(0xff171f34),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        elevation: 5,
        child: Ink.image(
          image: const AssetImage('assets/worldlinebox-logo.png'),
          fit: BoxFit.cover,
          child: SizedBox.square(
            dimension: 50,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
            ),
          ),
        ),
      ),
    ),
  );
}

class PetCallBubble extends StatelessWidget {
  const PetCallBubble({
    super.key,
    required this.text,
    required this.index,
    required this.count,
    required this.autoplay,
    required this.playing,
    required this.onJump,
    required this.onPause,
    this.notice,
    this.onHistory,
    this.onInterrupt,
    this.onCollapse,
    this.progress,
  });

  final String? text;
  final int index;
  final int count;
  final bool autoplay;
  final bool playing;
  final void Function(int index, bool autoplay) onJump;
  final VoidCallback onPause;
  final String? notice;
  final VoidCallback? onHistory;
  final VoidCallback? onInterrupt;
  final VoidCallback? onCollapse;
  final PetCallProgress? progress;

  @override
  Widget build(BuildContext context) {
    final waiting = progress != null && text == null;
    final padding = waiting
        ? const EdgeInsets.symmetric(horizontal: 10, vertical: 5)
        : const EdgeInsets.fromLTRB(12, 9, 12, 6);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (text case final caption?)
          Text(
            caption,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _ink,
              fontSize: 16,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        if (notice case final message? when index < 0)
          Text(message, style: const TextStyle(color: _muted, fontSize: 11)),
        if (progress case final phase?)
          Padding(
            padding: EdgeInsets.only(top: waiting ? 0 : 4),
            child: _CallProgressLine(progress: phase, onInterrupt: onInterrupt),
          ),
      ],
    );
    return Material(
      color: _paper,
      elevation: 3,
      shadowColor: const Color(0x3321143b),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(23),
        side: const BorderSide(color: _edge),
      ),
      clipBehavior: Clip.antiAlias,
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: _muted,
            minimumSize: const Size.square(30),
            padding: const EdgeInsets.all(5),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (index < 0) {
              return SingleChildScrollView(padding: padding, child: content);
            }
            final controls = _buildPlaybackControls(context);
            if (constraints.maxHeight < _minPinnedBubbleHeight) {
              return SingleChildScrollView(
                padding: padding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [content, controls],
                ),
              );
            }
            return Padding(
              padding: padding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      key: ValueKey(index),
                      child: content,
                    ),
                  ),
                  controls,
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPlaybackControls(BuildContext context) {
    final canPause = autoplay && playing;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xffece7f4))),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onHistory != null)
                  IconButton(
                    tooltip: '完整对话',
                    visualDensity: VisualDensity.compact,
                    onPressed: onHistory,
                    icon: const Icon(Icons.history, size: 18),
                  ),
                IconButton(
                  tooltip: '从头播放',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onJump(0, true),
                  icon: const Icon(Icons.replay, size: 18),
                ),
                IconButton(
                  tooltip: '上一段',
                  visualDensity: VisualDensity.compact,
                  onPressed: index > 0 ? () => onJump(index - 1, false) : null,
                  icon: const Icon(Icons.chevron_left, size: 19),
                ),
                Text(
                  '${index + 1}/$count',
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
                IconButton(
                  tooltip: '下一段',
                  visualDensity: VisualDensity.compact,
                  onPressed: index + 1 < count
                      ? () => onJump(index + 1, false)
                      : null,
                  icon: const Icon(Icons.chevron_right, size: 19),
                ),
                IconButton(
                  tooltip: canPause
                      ? '暂停自动播放'
                      : autoplay
                      ? '自动播放'
                      : '继续自动播放',
                  visualDensity: VisualDensity.compact,
                  onPressed: canPause
                      ? onPause
                      : () => onJump(autoplay ? 0 : index, true),
                  icon: Icon(
                    canPause ? Icons.pause : Icons.play_arrow,
                    size: 18,
                  ),
                ),
                if (progress == null && onInterrupt != null)
                  IconButton(
                    tooltip: '打断',
                    onPressed: onInterrupt,
                    icon: const Icon(
                      Icons.stop_rounded,
                      size: 16,
                      color: Color(0xff93354e),
                    ),
                  ),
                if (notice case final message?)
                  IconButton(
                    tooltip: message,
                    onPressed: () => ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(message))),
                    icon: const Icon(Icons.info_outline_rounded, size: 16),
                  ),
                if (onCollapse case final collapse?)
                  IconButton(
                    tooltip: '收起对白',
                    onPressed: collapse,
                    style: IconButton.styleFrom(
                      backgroundColor: _tint,
                      foregroundColor: _accent,
                    ),
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
