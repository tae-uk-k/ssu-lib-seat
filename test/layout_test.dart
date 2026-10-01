import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/seat_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('범례의 3자리 약식 색(#eee)을 올바르게 읽는다', () async {
    final layout = (await SeatLayout.load(53))!;
    final disabled = layout.legend.firstWhere((l) => l.disabled);
    expect(disabled.bg, const Color(0xFFEEEEEE));
    expect(disabled.border, const Color(0xFF999999));
    final normal = layout.legend.first;
    expect(normal.bg, const Color(0xFF006794));
  });

  test('이용 가능한 열람실 도면은 좌석 순번이 겹치거나 비지 않는다', () async {
    for (final room in [53, 54]) {
      final layout = (await SeatLayout.load(room))!;
      final idx = layout.seats.map((s) => s.index).toList()..sort();
      expect(idx, List.generate(idx.length, (i) => i), reason: 'room $room');
    }
  });

  test('도면이 없는 열람실은 null', () async {
    expect(await SeatLayout.load(9999), isNull);
  });
}
