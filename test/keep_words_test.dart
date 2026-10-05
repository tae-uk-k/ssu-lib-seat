import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/widgets.dart';

/// [s] 를 [width] 폭에 그렸을 때, 줄이 바뀌는 위치(글자 번호)들. 마지막 줄 끝은 뺀다.
List<int> _breaks(String s, double width) {
  final p = TextPainter(
    text: TextSpan(text: s, style: const TextStyle(fontSize: 16)),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);
  final out = <int>[];
  var pos = 0;
  while (pos < s.length) {
    final end = p.getLineBoundary(TextPosition(offset: pos)).end;
    if (end >= s.length || end <= pos) break;
    out.add(end);
    pos = end;
  }
  return out;
}

/// 줄바꿈 위치가 띄어쓰기 자리가 아닌(= 단어 중간인) 곳의 개수.
int _midWordBreaks(String s, double width) {
  final clean = s.replaceAll('⁠', '');
  var n = 0;
  for (final b in _breaks(s, width)) {
    // b 번째 글자 앞에서 줄이 바뀐다. 양쪽 글자가 모두 공백이 아니면 단어 중간이다.
    final before = s.substring(0, b).replaceAll('⁠', '').length;
    final prev = before > 0 ? clean[before - 1] : ' ';
    final next = before < clean.length ? clean[before] : ' ';
    if (prev != ' ' && next != ' ') n++;
  }
  return n;
}

void main() {
  const wj = '⁠'; // WORD JOINER

  test('공백이 아닌 글자 사이에만 줄바꿈 금지 문자를 끼운다', () {
    expect('사용 중인'.keepWords, '사$wj용 중$wj인');
    expect('A B'.keepWords, 'A B');
    expect(''.keepWords, '');
    expect('가'.keepWords, '가');
    expect('가  나'.keepWords, '가  나'); // 공백은 그대로 둔다
  });

  test('보이지 않는 문자만 더할 뿐, 지우면 원래 문장 그대로다', () {
    const s = '원하는 좌석을 골라 두면, 그중 한 자리가 비는 순간 자동으로 예약해 줘요.';
    expect(s.keepWords.replaceAll(wj, ''), s);
  });

  test('좁은 폭에서 기본은 단어 중간에서 줄이 바뀌고, keepWords 는 띄어쓰기 자리에서만 바뀐다', () {
    const s = '사용 중인 좌석도 고를 수 있고, 비는 순간 바로 예약해요. 먼저 고른 좌석부터 예약해요.';
    for (final width in [100.0, 130.0, 160.0, 200.0]) {
      expect(_midWordBreaks(s.keepWords, width), 0, reason: '폭 $width 에서 단어가 잘렸어요');
    }
    // 기본 동작은 정말로 단어 중간에서 끊긴다 (그래서 이 기능이 필요하다)
    expect([100.0, 130.0, 160.0, 200.0].map((w) => _midWordBreaks(s, w)).reduce((a, b) => a + b), greaterThan(0));
  });

  test('띄어쓰기가 없는 아주 긴 글자도 화면 밖으로 넘치지 않고 줄이 바뀐다', () {
    final long = 'error.authentication.failed.because.of.something.very.long.without.spaces'.keepWords;
    final p = TextPainter(
      text: TextSpan(text: long, style: const TextStyle(fontSize: 16)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 120);
    expect(p.width, lessThanOrEqualTo(120.5));
    expect(p.computeLineMetrics().length, greaterThan(1));
  });
}
