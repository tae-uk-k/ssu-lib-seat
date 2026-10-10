import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/auto_renewer.dart';
import 'package:lib_seat/my_seat_page.dart';
import 'package:lib_seat/widgets.dart';

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
      Future<String?> Function(MyCharge)? onReturn,
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
          onReturn: onReturn ?? (_) async => null,
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

    group('반납', () {
      testWidgets('이용 중인 좌석에는 "반납하기", 이용 시작 전 좌석에는 "배정 취소하기" 버튼이 있다', (tester) async {
        await pump(tester, load: () async => [_charge()], v: view());
        expect(find.text('반납하기'), findsOneWidget);
        expect(find.text('배정 취소하기'), findsNothing);

        await tester.pumpWidget(const SizedBox()); // 화면을 새로 열어야 목록을 다시 읽는다
        await pump(tester, load: () async => [_charge(inUse: false)], v: view());
        expect(find.text('배정 취소하기'), findsOneWidget);
        expect(find.text('반납하기'), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await pump(tester, load: () async => [], v: view()); // 좌석이 없으면 버튼도 없다
        expect(find.text('반납하기'), findsNothing);
        expect(find.text('배정 취소하기'), findsNothing);
      });

      testWidgets('누르면 한 번 더 묻고, "아니요"면 반납하지 않는다', (tester) async {
        final asked = <MyCharge>[];
        await pump(tester, load: () async => [_charge()], v: view(), onReturn: (c) async {
          asked.add(c);
          return null;
        });
        await tester.tap(find.text('반납하기'));
        await tester.pumpAndSettle();
        expect(find.text('좌석을 반납할까요?'), findsOneWidget);
        expect(find.textContaining('다시 앉으려면 새로 예약해야 해요'.keepWords), findsOneWidget);
        await tester.tap(find.text('아니요'));
        await tester.pumpAndSettle();
        expect(find.text('좌석을 반납할까요?'), findsNothing);
        expect(asked, isEmpty);
        expect(find.text('반납하기'), findsOneWidget); // 그대로
      });

      testWidgets('이용 시작 전 좌석은 "배정 취소"로 묻는다', (tester) async {
        await pump(tester, load: () async => [_charge(inUse: false)], v: view());
        await tester.tap(find.text('배정 취소하기'));
        await tester.pumpAndSettle();
        expect(find.text('좌석 배정을 취소할까요?'), findsOneWidget);
        expect(find.widgetWithText(TextButton, '배정 취소'), findsOneWidget);
      });

      testWidgets('확인하면 그 좌석으로 반납을 요청하고, 성공하면 목록을 다시 읽어 좌석이 없다고 보여 준다', (tester) async {
        final asked = <MyCharge>[];
        var returned = false;
        var loads = 0;
        Future<List<MyCharge>> load() async {
          loads++;
          return returned ? [] : [_charge()];
        }

        await pump(tester, load: load, v: view(), onReturn: (c) async {
          asked.add(c);
          returned = true;
          return null;
        });
        expect(loads, 1);
        await tester.tap(find.text('반납하기'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '반납'));
        await tester.pumpAndSettle();

        expect(asked.single.id, 900);
        expect(asked.single.returnable, isTrue);
        expect(loads, 2, reason: '반납한 뒤 목록을 다시 읽는다');
        expect(find.text('지금 갖고 있는 좌석이 없어요.'), findsOneWidget);
        expect(find.text('반납하기'), findsNothing);
      });

      testWidgets('실패하면 이유를 보여 주고 좌석은 그대로 두며, 다시 시도할 수 있다', (tester) async {
        var loads = 0;
        var tries = 0;
        await pump(tester, load: () async {
          loads++;
          return [_charge()];
        }, v: view(), onReturn: (c) async {
          tries++;
          return '반납하지 못했어요. error.x 이용 중인 좌석이 아니에요';
        });
        await tester.tap(find.text('반납하기'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '반납'));
        await tester.pumpAndSettle();

        expect(find.textContaining('이용 중인 좌석이 아니에요'.keepWords), findsOneWidget);
        expect(find.text('반납하기'), findsOneWidget); // 다시 누를 수 있다
        expect(loads, 1, reason: '실패했으면 목록을 다시 읽지 않는다');

        await tester.tap(find.text('반납하기'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '반납'));
        await tester.pumpAndSettle();
        expect(tries, 2);
      });

      testWidgets('요청하는 동안에는 "반납하는 중…"으로 바뀌고 다시 누를 수 없다', (tester) async {
        final gate = Completer<String?>();
        await pump(tester, load: () async => [_charge()], v: view(), onReturn: (c) => gate.future);
        await tester.tap(find.text('반납하기'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '반납'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('반납하는 중…'), findsOneWidget);
        final button = find.ancestor(of: find.text('반납하는 중…'), matching: find.bySubtype<OutlinedButton>());
        expect(tester.widget<OutlinedButton>(button).onPressed, isNull);

        gate.complete('반납하지 못했어요.');
        await tester.pumpAndSettle();
        expect(find.text('반납하기'), findsOneWidget);
      });
    });
  });
}
