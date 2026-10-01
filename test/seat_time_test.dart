import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/seat_layout.dart';
import 'package:lib_seat/seat_map.dart';
import 'package:lib_seat/widgets.dart';

/// 서버가 실제로 준 좌석 응답(room 53, 빈 좌석)과 같은 모양에 사용 중 값만 바꾼 것.
Map<String, dynamic> _json({bool occupied = false, int remaining = 0, int charge = 0, bool reservable = false}) => {
      'id': 864,
      'room': {'id': 53, 'name': '숭실스퀘어ON(2F)'},
      'code': '1',
      'isActive': true,
      'isReservable': reservable,
      'isOccupied': occupied,
      'seatChargeState': null,
      'remainingTime': remaining,
      'chargeTime': charge,
      'timeLine': null,
      'seatType': {'id': 2, 'name': '일반용'},
    };

/// "45분", "1:40" 같은 남은 시간 글자.
final timeTexts = find.byWidgetPredicate((w) => w is Text && RegExp(r'^[0-9]+분$|^[0-9]+:[0-9]{2}$').hasMatch(w.data ?? ''));

void main() {
  group('Seat 남은 시간', () {
    test('빈 좌석(0/0)은 남은 시간이 없다', () {
      final s = Seat.fromJson(_json());
      expect(s.available, isTrue);
      expect(s.remainingMinutes, isNull);
    });

    test('사용 중인 좌석: 남은 분', () {
      final s = Seat.fromJson(_json(occupied: true, remaining: 45, charge: 240));
      expect(s.remainingMinutes, 45);
    });

    test('총 이용 시간이 하루(1440)를 넘으면 초 단위로 본다', () {
      final s = Seat.fromJson(_json(occupied: true, remaining: 2700, charge: 14400));
      expect(s.remainingMinutes, 45);
    });

    test('예약제 좌석은 홈페이지처럼 남은 시간을 쓰지 않는다', () {
      final s = Seat.fromJson(_json(occupied: true, remaining: 45, charge: 240, reservable: true));
      expect(s.remainingMinutes, isNull);
    });

    test('필드가 없거나 null 이어도 죽지 않는다', () {
      final j = _json()..remove('remainingTime')..['chargeTime'] = null;
      expect(Seat.fromJson(j).remainingMinutes, isNull);
    });
  });

  test('시간 표기', () {
    expect(compactRemaining(5), '5분');
    expect(compactRemaining(59), '59분');
    expect(compactRemaining(60), '1:00');
    expect(compactRemaining(100), '1:40');
    expect(compactRemaining(125), '2:05');
    expect(longRemaining(45), '45분');
    expect(longRemaining(100), '1시간 40분');
    expect(longRemaining(120), '2시간');
  });

  testWidgets('도면 타일과 목록 타일에 남은 시간이 보인다', (tester) async {
    final layout = (await SeatLayout.load(53))!;
    final seats = [
      for (var i = 0; i < layout.seats.length; i++)
        Seat(
          id: i,
          code: '${i + 1}',
          active: true,
          occupied: i == 2 || i == 3,
          remainingTime: i == 2 ? 45 : (i == 3 ? 100 : 0),
          chargeTime: i == 2 || i == 3 ? 240 : 0,
        ),
    ];
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: SeatCanvas(layout: layout, seats: seats, selected: const []))),
    ));
    expect(find.text('45분'), findsOneWidget);
    expect(find.text('1:40'), findsOneWidget);
    // 시간 글자는 사용 중인 좌석 2개에만 붙는다 (빈 좌석, 구역 이름 "분리형" 등에는 없다).
    expect(timeTexts, findsNWidgets(2));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: SeatGrid(seats: seats, selected: const [], onTap: (_) {}))),
    ));
    expect(find.text('45분'), findsOneWidget);
    expect(find.text('1:40'), findsOneWidget);
    expect(timeTexts, findsNWidgets(2));
  });
}
