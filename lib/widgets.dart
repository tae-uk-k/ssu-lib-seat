import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';

const kGreen = Color(0xFF2E7D32);

/// 내가 고른 좌석 색. 도면의 구역 색(파랑·금색·청록·연파랑)과 겹치지 않는 분홍 계열.
const kPicked = Color(0xFFD81B60);
const _availBg = Color(0xFFE6F4E8);
const _usedBg = Color(0xFFEDEDED);

/// 좌석 타일 안에 쓰는 짧은 남은 시간. 1시간 미만은 "45분", 이상은 "1:40"(1시간 40분).
String compactRemaining(int minutes) {
  if (minutes < 60) return '$minutes분';
  final m = (minutes % 60).toString().padLeft(2, '0');
  return '${minutes ~/ 60}:$m';
}

/// 문장 안에 쓰는 남은 시간. "45분", "1시간 40분", "2시간".
String longRemaining(int minutes) {
  if (minutes < 60) return '$minutes분';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h시간' : '$h시간 $m분';
}

/// 새 버전 안내 카드. [progress] 가 있으면 내려받는 중, [blocked] 이면 예약이 도는 중이라 업데이트를 막는다.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    super.key,
    required this.currentVersion,
    required this.newVersion,
    required this.onUpdate,
    this.notes = '',
    this.progress,
    this.busy = false,
    this.blocked = false,
  });

  final String currentVersion, newVersion, notes;
  final double? progress;
  final bool busy, blocked;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSecondaryContainer;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.system_update, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('새 버전 $newVersion이 나왔어요', style: TextStyle(fontWeight: FontWeight.bold, color: fg)),
              Text('지금 쓰는 버전 $currentVersion', style: TextStyle(fontSize: 12, color: fg)),
            ]),
          ),
        ]),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(notes, maxLines: 5, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, height: 1.4, color: fg)),
        ],
        const SizedBox(height: 10),
        if (busy) ...[
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 4),
          Text(progress == null ? '준비하는 중…' : '내려받는 중 ${(progress! * 100).round()}%',
              style: TextStyle(fontSize: 12, color: fg)),
        ] else ...[
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: blocked ? null : onUpdate,
              icon: const Icon(Icons.download),
              label: const Text('업데이트'),
            ),
          ),
          if (blocked)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('예약을 멈춘 뒤에 업데이트할 수 있어요. 설치하면 앱이 다시 시작돼요.',
                  style: TextStyle(fontSize: 12, color: fg)),
            ),
        ],
      ]),
    );
  }
}

/// 번호가 붙은 단계 카드.
class StepCard extends StatelessWidget {
  const StepCard({
    super.key,
    required this.step,
    required this.title,
    required this.child,
    this.subtitle,
    this.done = false,
    this.trailing,
  });

  final int step;
  final String title;
  final String? subtitle;
  final bool done;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: done ? kGreen : scheme.primary,
              child: done
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : Text('$step', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                if (subtitle != null)
                  Text(subtitle!, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ]),
            ),
            ?trailing,
          ]),
          const SizedBox(height: 14),
          child,
        ]),
      ),
    );
  }
}

/// 도서관 홈페이지처럼 열람실을 원형 게이지로 보여 준다.
/// 가운데 큰 숫자는 지금 이용 가능한 좌석 수, 아래 작은 숫자는 "사용 중 / 전체" 이다.
class RoomGauge extends StatelessWidget {
  const RoomGauge({super.key, required this.room, required this.selected, required this.onTap});

  final Room room;
  final bool selected;
  final VoidCallback onTap;

  static const _teal = Color(0xFF1B87A9);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = room.chargeable;
    final accent = ok ? _teal : const Color(0xFFB0B0B0);
    final frac = (ok && room.total > 0) ? room.available / room.total : 0.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 92,
            height: 92,
            child: CustomPaint(
              painter: _RingPainter(
                fraction: frac,
                color: _teal,
                selectedColor: selected ? scheme.primary : null,
              ),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${room.available}',
                      style: TextStyle(fontSize: 24, height: 1.1, color: accent, fontWeight: FontWeight.w500)),
                  Text('${room.occupied} / ${room.total}',
                      style: TextStyle(fontSize: 11.5, height: 1.2, color: scheme.onSurfaceVariant)),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            room.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.25,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? scheme.primary : null,
            ),
          ),
          if (!ok)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('이용 불가', style: TextStyle(fontSize: 11, color: scheme.error, fontWeight: FontWeight.bold)),
            )
          else if (selected)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('선택됨', style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.bold)),
            ),
        ]),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.fraction, required this.color, this.selectedColor});

  final double fraction;
  final Color color;
  final Color? selectedColor;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = size.width / 2 - 5;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..color = const Color(0xFFF0F0F0);
    canvas.drawCircle(c, radius, track);
    final rect = Rect.fromCircle(center: c, radius: radius);
    if (fraction > 0) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.butt
        ..color = color;
      // 12시 방향에서 시작해 반시계 방향으로 채운다.
      canvas.drawArc(rect, -math.pi / 2, -2 * math.pi * fraction, false, arc);
    }
    // 안쪽 얇은 원 (선택되면 강조색)
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = selectedColor != null ? 3 : 1
      ..color = selectedColor ?? color.withValues(alpha: 0.9);
    canvas.drawCircle(c, radius - 9, inner);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.color != color || old.selectedColor != selectedColor;
}

/// 좌석 상태 범례.
class SeatLegend extends StatelessWidget {
  const SeatLegend({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String t, {Color? border}) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(3),
              border: border == null ? null : Border.all(color: border),
            ),
          ),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 12)),
        ]);
    return Wrap(spacing: 12, runSpacing: 4, children: [
      item(kPicked, '선택'),
      item(_availBg, '비어 있음', border: kGreen),
      item(_usedBg, '사용 중'),
      item(Colors.white, '사용 불가', border: const Color(0xFFD0D0D0)),
    ]);
  }
}

/// 홈페이지처럼 좌석 번호 카드를 나열한다. 선택한 좌석에는 우선순위 숫자가 붙는다.
class SeatGrid extends StatelessWidget {
  const SeatGrid({super.key, required this.seats, required this.selected, required this.onTap});

  final List<Seat> seats;
  final List<String> selected;
  final void Function(Seat) onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in seats)
          _SeatTile(seat: s, order: selected.indexOf(s.code), onTap: () => onTap(s)),
      ],
    );
  }
}

class _SeatTile extends StatelessWidget {
  const _SeatTile({required this.seat, required this.order, required this.onTap});

  final Seat seat;
  final int order; // -1 이면 선택 안 됨
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final picked = order >= 0;
    Color bg;
    Color fg;
    Color border;
    if (picked) {
      bg = kPicked;
      fg = Colors.white;
      border = kPicked;
    } else if (!seat.active) {
      bg = Colors.white;
      fg = const Color(0xFFBDBDBD);
      border = const Color(0xFFD0D0D0);
    } else if (seat.occupied) {
      bg = _usedBg;
      fg = const Color(0xFF757575);
      border = _usedBg;
    } else {
      bg = _availBg;
      fg = const Color(0xFF1B5E20);
      border = kGreen;
    }
    final remain = seat.remainingMinutes;
    return SizedBox(
      width: 58,
      height: 54,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          child: Material(
            color: bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: border),
            ),
            child: InkWell(
              onTap: seat.active ? onTap : null,
              borderRadius: BorderRadius.circular(10),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(
                  seat.code,
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.1,
                    fontWeight: FontWeight.bold,
                    color: fg,
                    decoration: seat.active ? null : TextDecoration.lineThrough,
                  ),
                ),
                if (remain != null)
                  Text(compactRemaining(remain), style: TextStyle(fontSize: 11, height: 1.1, color: fg)),
              ]),
            ),
          ),
        ),
        if (picked)
          Positioned(
            right: -4,
            top: -6,
            child: Container(
              constraints: const BoxConstraints(minWidth: 20),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.amber.shade700,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Text('${order + 1}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ),
      ]),
    );
  }
}
