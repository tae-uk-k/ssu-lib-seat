import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/auto_renewer.dart';
import 'package:lib_seat/my_seat_page.dart';

MyCharge _charge({int? remaining = 100, bool inUse = true, bool? renewable}) => MyCharge(
      id: 900,
      seatId: 105,
      seatCode: '5',
      roomId: 53,
      roomName: '숭실스퀘어ON(2F)',
      returnable: inUse,
      remainingMinutes: remaining,
      renewable: renewable,
    );

void main() {
  group('clockText', () {
    test('시각을 두 자리씩 적는다', () {
      expect(clockText(DateTime(2026, 10, 9, 7, 5)), '07:05');
    });

    test('기준과 날짜가 다르면 "내일"을 붙인다 (자정을 넘는 시각)', () {
      final base = DateTime(2026, 10, 9, 23, 0);
      expect(clockText(DateTime(2026, 10, 10, 0, 10), base: base), '내일 00:10');
      expect(clockText(DateTime(2026, 10, 9, 23, 40), base: base), '23:40');
    });
  });

  group('renewTimingText', () {
    const threshold = Duration(minutes: 30);
    final at = DateTime(2026, 10, 9, 14, 0);

    test('남은 시간이 문턱보다 많으면 연장이 시작될 시각을 알려 준다', () {
      expect(renewTimingText(_charge(remaining: 100), at, threshold), '연장은 15:10쯤 시작해요'); // 14:00 + (100 - 30)분
    });

    test('자정을 넘으면 내일로 적는다', () {
      expect(renewTimingText(_charge(remaining: 100), DateTime(2026, 10, 9, 23, 0), threshold), '연장은 내일 00:10쯤 시작해요');
    });

    test('문턱 이하면 지금 연장할 시간이라고 한다 (경계 포함)', () {
      expect(renewTimingText(_charge(remaining: 30), at, threshold), '지금 연장할 시간이에요');
      expect(renewTimingText(_charge(remaining: 5), at, threshold), '지금 연장할 시간이에요');
    });

    test('이용 시작 전이면 그렇게 말하고, 서버가 연장 가능이라고 하면 시간으로 본다', () {
      expect(renewTimingText(_charge(inUse: false, renewable: false), at, threshold), '아직 이용을 시작하기 전이에요');
      expect(renewTimingText(_charge(inUse: false, renewable: true, remaining: 10), at, threshold), '지금 연장할 시간이에요');
    });

    test('남은 시간을 모르면 null', () {
      expect(renewTimingText(_charge(remaining: null), at, threshold), isNull);
    });
  });

  group('MySeatPage', () {
    RenewView view({bool enabled = true, bool active = false, bool running = false, RenewStatus? status}) => RenewView(
          enabled: enabled,
          active: active,
          sessionRunning: running,
          threshold: const Duration(minutes: 30),
          retryAfter: const Duration(minutes: 5),
          status: status,
        );

    Future<void> pump(
      WidgetTester tester, {
      bool loggedIn = true,
      required Future<List<MyCharge>> Function() load,
      required RenewView v,
      void Function(bool)? onToggle,
      VoidCallback? onStart,
    }) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: MySeatPage(
          loggedIn: loggedIn,
          load: load,
          view: v,
          onToggle: onToggle ?? (_) {},
          onStart: onStart ?? () {},
          onLogin: () async {},
        ),
      ));
      await tester.pump();
    }

    testWidgets('자동 연장 상태 세 가지: 꺼짐, 켜졌지만 시작 전, 동작 중이 서로 다르게 보인다', (tester) async {
      await pump(tester, load: () async => [], v: view(enabled: false));
      expect(find.text('꺼져 있어요'), findsOneWidget);

      await pump(tester, load: () async => [], v: view());
      expect(find.text('켜져 있지만 아직 동작하지 않아요'), findsOneWidget);
      expect(find.text('지금 시작'), findsOneWidget);

      await pump(tester, load: () async => [], v: view(active: true, running: true));
      expect(find.text('동작 중'), findsOneWidget);
      expect(find.text('지금 시작'), findsNothing);
    });

    testWidgets('예약이 도는 중이고 연장은 아직 안 붙었으면 지금 시작 버튼 대신 안내만 보인다', (tester) async {
      await pump(tester, load: () async => [], v: view(running: true));
      expect(find.text('켜져 있지만 아직 동작하지 않아요'), findsOneWidget);
      expect(find.text('지금 시작'), findsNothing);
    });

    testWidgets('스위치를 누르면 바뀐 값이 전달되고, 지금 시작을 누르면 시작이 요청된다', (tester) async {
      bool? toggled;
      var started = 0;
      await pump(tester, load: () async => [], v: view(), onToggle: (v) => toggled = v, onStart: () => started++);
      await tester.tap(find.byType(Switch));
      expect(toggled, isFalse); // 켜져 있었으니 끄는 요청
      await tester.tap(find.text('지금 시작'));
      expect(started, 1);
    });

    testWidgets('연장 루프가 더 최근에 확인한 좌석이 있으면 그 내용으로 바뀐다 (따로 조회하지 않아도)', (tester) async {
      var loads = 0;
      Future<List<MyCharge>> load() async {
        loads++;
        return [_charge(remaining: 100)];
      }

      await pump(tester, load: load, v: view());
      expect(loads, 1);
      expect(find.text('1시간 40분'), findsOneWidget);

      final st = RenewStatus(held: _charge(remaining: 40), renewed: 0, checkedAt: DateTime.now().add(const Duration(minutes: 1)));
      await pump(tester, load: load, v: view(active: true, running: true, status: st));
      expect(find.text('40분'), findsOneWidget);
      expect(loads, 1, reason: '연장 루프의 최근 확인을 쓰므로 서버에 다시 묻지 않는다');
    });
  });
}
