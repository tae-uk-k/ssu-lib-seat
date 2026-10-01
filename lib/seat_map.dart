import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'seat_layout.dart';
import 'widgets.dart';

/// 도면 그림 한 장. 좌표는 홈페이지 도면 그대로이고, [onTap] 이 null 이면 눌러도 반응하지 않는다.
class SeatCanvas extends StatelessWidget {
  const SeatCanvas({
    super.key,
    required this.layout,
    required this.seats,
    required this.selected,
    this.onTap,
  });

  final SeatLayout layout;

  /// API 가 준 순서 그대로의 좌석 목록 (도면은 이 순번으로 좌석을 찾는다).
  final List<Seat> seats;
  final List<String> selected;
  final void Function(Seat)? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: layout.width,
      height: layout.height,
      child: Stack(clipBehavior: Clip.none, children: [
        for (final b in layout.boxes) _box(b),
        for (final t in layout.texts)
          Positioned(
            left: t.x,
            top: t.y,
            child: Text(
              t.text,
              softWrap: false,
              style: TextStyle(
                fontSize: t.fontSize,
                height: 1.1,
                color: t.color,
                fontWeight: t.bold ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        for (final s in layout.seats) _tile(s),
      ]),
    );
  }

  Widget _box(LayoutBox b) {
    final r = b.radii.length == 4 ? b.radii : const [0.0, 0.0, 0.0, 0.0];
    return Positioned(
      left: b.x,
      top: b.y,
      width: b.w,
      height: b.h,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: b.bg,
            border: b.borderWidth > 0 && b.borderColor != null
                ? Border.all(color: b.borderColor!, width: b.borderWidth)
                : null,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(r[0]),
              topRight: Radius.circular(r[1]),
              bottomRight: Radius.circular(r[2]),
              bottomLeft: Radius.circular(r[3]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(LayoutSeat ls) {
    final seat = ls.index < seats.length ? seats[ls.index] : null;
    final order = seat == null ? -1 : selected.indexOf(seat.code);
    final remain = seat?.remainingMinutes;
    Color bg, bc, fg;
    if (order >= 0) {
      bg = seat!.occupied ? kPicked.withValues(alpha: 0.78) : kPicked;
      bc = kPicked;
      fg = Colors.white;
    } else if (seat != null && seat.available) {
      bg = ls.bg ?? const Color(0xFF006794);
      bc = ls.bc ?? bg;
      fg = ls.fg ?? Colors.white;
    } else {
      bg = layout.disabledBg;
      bc = layout.disabledBorder;
      fg = layout.disabledFg;
    }
    final tap = onTap;
    return Positioned(
      left: ls.x,
      top: ls.y,
      width: ls.w,
      height: ls.h,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tap != null && seat != null && seat.active ? () => tap(seat) : null,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bg,
                border: Border.all(color: bc),
                borderRadius: BorderRadius.circular(ls.radius),
              ),
              child: remain == null
                  ? Center(child: Text(seat?.code ?? '', style: TextStyle(fontSize: 14, color: fg, height: 1)))
                  // 위치를 고정해서 글꼴 높이가 달라도 넘치지 않게 한다 (타일 높이는 32~36).
                  : Stack(children: [
                      Positioned(
                        top: 4,
                        left: 0,
                        right: 0,
                        child: Text(seat!.code, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: fg, height: 1)),
                      ),
                      // 사용 중인 좌석의 남은 시간. 회색 타일 위에서도 읽히게 코드 번호보다 진하게 쓴다.
                      Positioned(
                        top: 18,
                        left: 0,
                        right: 0,
                        child: Text(compactRemaining(remain),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 10, color: order >= 0 ? Colors.white : const Color(0xFF616161), height: 1)),
                      ),
                    ]),
            ),
          ),
          if (order >= 0)
            Positioned(
              right: -5,
              top: -7,
              child: Container(
                constraints: const BoxConstraints(minWidth: 18),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.amber.shade700,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Text('${order + 1}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, height: 1.2)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// 메인 화면용 도면 미리보기. 도면 전체를 한눈에 보여 주고, 누르면 [onOpen] 으로 크게 연다.
/// 스크롤되는 화면 안에서 쓰므로 일부러 확대/이동은 넣지 않았다 (페이지 스크롤과 겹치기 때문).
class SeatMapPreview extends StatelessWidget {
  const SeatMapPreview({
    super.key,
    required this.layout,
    required this.seats,
    required this.selected,
    required this.onOpen,
  });

  final SeatLayout layout;
  final List<Seat> seats;
  final List<String> selected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '좌석 도면. 눌러서 크게 보기',
      child: GestureDetector(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(8),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: AspectRatio(
            aspectRatio: layout.width / layout.height,
            child: FittedBox(
              fit: BoxFit.contain,
              child: IgnorePointer(child: SeatCanvas(layout: layout, seats: seats, selected: selected)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 확대/이동이 되는 도면. 두 손가락으로 확대/축소, 한 손가락으로 이동한다.
/// 위아래로 스크롤되는 화면 안에 넣으면 세로 이동이 페이지 스크롤에 먹히니, 전체 화면([SeatMapPage])에서만 쓴다.
class SeatMapView extends StatefulWidget {
  const SeatMapView({
    super.key,
    required this.layout,
    required this.seats,
    required this.selected,
    required this.onTap,
    this.initialScale = 0.9,
  });

  final SeatLayout layout;
  final List<Seat> seats;
  final List<String> selected;
  final void Function(Seat) onTap;

  /// 처음 확대 배율. 좌석을 누르기 쉬운 크기로 시작한다 (도면이 더 작게 맞으면 그 크기).
  final double initialScale;

  @override
  State<SeatMapView> createState() => _SeatMapViewState();
}

class _SeatMapViewState extends State<SeatMapView> {
  static const _minScale = 0.2;
  static const _maxScale = 3.0;
  static const _pad = 12.0;

  final _ctrl = TransformationController();
  Size _viewport = Size.zero;
  bool _placed = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 좌석이 놓인 영역. 도면 가장자리에 빈 공간이 많은 열람실도 좌석 쪽부터 보여 주려는 용도.
  Rect get _bounds {
    final l = widget.layout;
    if (l.seats.isEmpty) return Rect.fromLTWH(0, 0, l.width, l.height);
    return l.seats
        .map((s) => Rect.fromLTWH(s.x, s.y, s.w, s.h))
        .reduce((a, b) => a.expandToInclude(b));
  }

  // 주의: z 배율도 s 로 맞춘다. 1 로 두면 getMaxScaleOnAxis() 가 s<1 일 때 1 을 돌려줘
  // InteractiveViewer 가 현재 배율을 잘못 읽는다.

  /// 좌석이 있는 곳의 왼쪽 위 모서리부터 보여 준다.
  void _place(Size v) {
    final b = _bounds;
    final fit = ((v.width - 2 * _pad) / b.width).clamp(_minScale, _maxScale);
    final s = fit < widget.initialScale ? widget.initialScale : fit;
    _ctrl.value = Matrix4.translationValues(-(b.left - _pad) * s, -(b.top - _pad) * s, 0) *
        Matrix4.diagonal3Values(s, s, s);
  }

  /// 좌석 영역 전체가 한눈에 들어오게 맞춘다.
  void _fit() {
    final b = _bounds;
    final v = _viewport;
    final s = math.min((v.width - 2 * _pad) / b.width, (v.height - 2 * _pad) / b.height).clamp(_minScale, _maxScale);
    final dx = (v.width - b.width * s) / 2 - b.left * s;
    final dy = (v.height - b.height * s) / 2 - b.top * s;
    _ctrl.value = Matrix4.translationValues(dx, dy, 0) * Matrix4.diagonal3Values(s, s, s);
  }

  void _zoom(double factor) {
    final cur = _ctrl.value.getMaxScaleOnAxis();
    final target = (cur * factor).clamp(_minScale, _maxScale);
    final k = target / cur;
    final cx = _viewport.width / 2, cy = _viewport.height / 2;
    final around = Matrix4.translationValues(cx, cy, 0) *
        Matrix4.diagonal3Values(k, k, k) *
        Matrix4.translationValues(-cx, -cy, 0);
    _ctrl.value = around * _ctrl.value;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      _viewport = size;
      if (!_placed) {
        _placed = true;
        _place(size);
      }
      return Stack(children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: Colors.white,
              child: InteractiveViewer(
                transformationController: _ctrl,
                constrained: false,
                minScale: _minScale,
                maxScale: _maxScale,
                boundaryMargin: const EdgeInsets.all(60),
                child: SeatCanvas(
                  layout: widget.layout,
                  seats: widget.seats,
                  selected: widget.selected,
                  onTap: widget.onTap,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Column(children: [
            _zoomButton(Icons.add, '확대', () => _zoom(1.3)),
            const SizedBox(height: 6),
            _zoomButton(Icons.remove, '축소', () => _zoom(1 / 1.3)),
            const SizedBox(height: 6),
            _zoomButton(Icons.fit_screen, '전체 보기', _fit),
          ]),
        ),
      ]);
    });
  }

  Widget _zoomButton(IconData icon, String tip, VoidCallback onPressed) => Material(
        color: Colors.white,
        shape: const CircleBorder(side: BorderSide(color: Color(0xFFCFCFD6))),
        child: IconButton(
          tooltip: tip,
          iconSize: 20,
          constraints: const BoxConstraints.tightFor(width: 38, height: 38),
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      );
}

/// 도면 범례. 홈페이지에서 읽은 구역 색에 "선택" 표시를 더한다.
class SeatMapLegend extends StatelessWidget {
  const SeatMapLegend({super.key, required this.layout});

  final SeatLayout layout;

  @override
  Widget build(BuildContext context) {
    Widget item(Color bg, Color border, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 12.5)),
        ]);
    return Wrap(spacing: 14, runSpacing: 6, children: [
      for (final l in layout.legend) item(l.bg, l.border, l.label),
      item(kPicked, kPicked, '내가 고른 좌석'),
    ]);
  }
}

/// 도면을 화면 가득 크게 보여 주는 페이지.
class SeatMapPage extends StatelessWidget {
  const SeatMapPage({
    super.key,
    required this.title,
    required this.layout,
    required this.seats,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final SeatLayout layout;
  final List<Seat> seats;
  final List<String> selected;
  final void Function(Seat) onTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('$title · ${selected.length}개 선택', style: const TextStyle(fontSize: 16)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('완료'))],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SeatMapLegend(layout: layout),
            const SizedBox(height: 4),
            Text('한 손가락으로 이동, 두 손가락으로 확대/축소해요. 좌석을 눌러 고르면 숫자(우선순위)가 붙어요.\n'
                '사용 중인 좌석 밑의 시간은 이용 종료까지 남은 시간이에요 (1:40 = 1시간 40분).',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 8),
            Expanded(child: SeatMapView(layout: layout, seats: seats, selected: selected, onTap: onTap)),
          ]),
        ),
      ),
    );
  }
}
