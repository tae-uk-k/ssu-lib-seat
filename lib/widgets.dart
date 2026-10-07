import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'run_state.dart';

const kGreen = Color(0xFF2E7D32);

/// 앱 바탕색. 카드는 흰색이라 이 연한 회색 위에서 또렷하게 보인다.
const kAppBg = Color(0xFFF4F5F9);

/// 내가 고른 좌석 색. 도면의 구역 색(파랑·금색·청록·연파랑)과 겹치지 않는 분홍 계열.
const kPicked = Color(0xFFD81B60);
const _availBg = Color(0xFFE6F4E8);
const _usedBg = Color(0xFFEDEDED);

/// 한글은 기본적으로 글자 사이 어디서든 줄이 바뀌어 단어가 중간에서 잘려 보인다("사용 중/인 좌석").
/// 공백이 아닌 글자 사이에 줄바꿈 금지 문자(WORD JOINER, 보이지 않음)를 끼워서 띄어쓰기 자리에서만 줄이 바뀌게 한다.
/// 여러 줄로 길게 나오는 안내 문장에 쓴다.
extension KeepWords on String {
  String get keepWords => replaceAllMapped(RegExp(r'(?<=\S)(?=\S)'), (_) => '\u2060');
}

/// 진행 기록 화면. 새 기록이 생기면 이 화면만 갱신된다.
class RunLogPage extends StatelessWidget {
  const RunLogPage({super.key, required this.log});

  final RunLog log;

  /// "12:34:56  내용" 모양의 한 줄을 시각(흐리게)과 내용으로 나눠 그린다.
  static Widget _line(BuildContext context, String line) {
    final dim = Theme.of(context).colorScheme.outline;
    final hasTime = line.length > 10 && line[2] == ':' && line[5] == ':';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text.rich(
        TextSpan(children: [
          if (hasTime) TextSpan(text: '${line.substring(0, 8)}  ', style: TextStyle(color: dim)),
          TextSpan(text: hasTime ? line.substring(10) : line),
        ]),
        style: const TextStyle(fontSize: 12.5, height: 1.35),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('진행 기록')),
        body: ListenableBuilder(
          listenable: log,
          builder: (context, _) => log.length == 0
              ? Center(child: Text('아직 기록이 없어요.', style: TextStyle(color: Theme.of(context).colorScheme.outline)))
              : ListView.builder(
                  // 가장 새 기록이 맨 위에 온다 (기록이 몇 줄 안 될 때도 위에서부터 읽힌다).
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: log.length,
                  itemBuilder: (context, i) => _line(context, log[log.length - 1 - i]),
                ),
        ),
      );
}

/// 화면 위쪽에 띄우는 안내 카드(실행 중, 결과). 왼쪽 아이콘과 오른쪽 내용의 모양을 한 곳에서 맞춘다.
class BannerCard extends StatelessWidget {
  const BannerCard({super.key, required this.color, required this.leading, required this.child, this.trailing});

  final Color color;

  /// 24x24 칸의 가운데에 놓이는 아이콘(또는 진행 표시).
  final Widget leading;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: EdgeInsets.fromLTRB(14, 12, trailing == null ? 14 : 4, 12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 24, height: 24, child: Center(child: leading)),
          const SizedBox(width: 12),
          Expanded(child: child),
          ?trailing,
        ]),
      );
}

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
/// [desktop] 이면 컴퓨터용 앱이라 APK 를 설치하는 대신 내려받는 웹 페이지를 연다.
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
    this.desktop = false,
  });

  final String currentVersion, newVersion, notes;
  final double? progress;
  final bool busy, blocked, desktop;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSecondaryContainer;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(16)),
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
          Text(notes.keepWords, maxLines: 5, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, height: 1.4, color: fg)),
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
              icon: Icon(desktop ? Icons.open_in_browser : Icons.download),
              label: Text(desktop ? '다운로드 페이지 열기' : '업데이트'),
            ),
          ),
          if (desktop)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('새 버전을 내려받아 압축을 풀고, 이 앱을 닫은 뒤 새 파일로 실행해 주세요.'.keepWords,
                  style: TextStyle(fontSize: 12, color: fg)),
            ),
          if (blocked)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('예약을 멈춘 뒤에 업데이트할 수 있어요. 설치하면 앱이 다시 시작돼요.'.keepWords,
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
