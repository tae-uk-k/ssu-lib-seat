import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/background.dart';
import 'package:lib_seat/main.dart';
import 'package:lib_seat/reservation_runner.dart';
import 'package:lib_seat/run_state.dart';
import 'package:lib_seat/seat_layout.dart';
import 'package:lib_seat/services.dart';
import 'package:lib_seat/update_check.dart';
import 'package:lib_seat/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------- 가짜들 ----------

SeatLayout? _layout53;

class FakeLibrary implements LibraryApi {
  FakeLibrary({
    List<List<Seat>>? script,
    this.loginError,
    this.reserveResult = const {'success': true},
    this.held = const [],
  }) : script = script ?? [_seats()];

  /// 조회할 때마다 차례로 돌려준다 (끝나면 마지막 것을 반복).
  final List<List<Seat>> script;
  final Exception? loginError;
  final Map<String, dynamic> reserveResult;

  /// 내가 이미 갖고 있는 좌석 (비어 있으면 없음). 취소하면 사라진다.
  final List<MyCharge> held;
  int logins = 0, seatCalls = 0, reserveCalls = 0, heldCalls = 0;
  final reservedIds = <int>[];

  /// 상태를 바꾼 요청의 순서 ('cancel:예약번호', 'return:예약번호', 'reserve:좌석id').
  final calls = <String>[];

  @override
  Future<void> login(String uid, String pw) async {
    logins++;
    if (loginError != null) throw loginError!;
  }

  @override
  Future<List<Room>> rooms() async => [
        Room(id: 53, name: '숭실스퀘어ON(2F)', floor: 2, chargeable: true, message: null, total: 12, available: 2, occupied: 10),
      ];

  @override
  Future<List<Seat>> seats(int roomId) async => script[seatCalls++ < script.length ? seatCalls - 1 : script.length - 1];

  @override
  Future<Map<String, dynamic>> reserve(int seatId) async {
    reserveCalls++;
    reservedIds.add(seatId);
    calls.add('reserve:$seatId');
    return reserveResult;
  }

  @override
  Future<List<MyCharge>> myCharges() async {
    heldCalls++;
    return List.of(held);
  }

  @override
  Future<Map<String, dynamic>> cancelCharge(int chargeId) async {
    calls.add('cancel:$chargeId');
    held.removeWhere((c) => c.id == chargeId);
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> returnCharge(int chargeId) async {
    calls.add('return:$chargeId');
    held.removeWhere((c) => c.id == chargeId);
    return {'success': true};
  }
}

/// 12개 좌석(번호 1~12). [free] 에 든 번호만 비어 있다. 사용 중인 좌석은 남은 시간이 있다.
List<Seat> _seats({Set<int> free = const {}}) => [
      for (var i = 1; i <= 12; i++)
        Seat(
          id: 100 + i,
          code: '$i',
          active: true,
          occupied: !free.contains(i),
          remainingTime: free.contains(i) ? 0 : 30 + i,
          chargeTime: free.contains(i) ? 0 : 240,
        ),
    ];

class FakeBackground implements BackgroundService {
  int inits = 0, starts = 0, stops = 0, updates = 0, batteryRequests = 0;
  bool startOk = true, alive = true;

  /// 배터리 최적화에서 제외돼 있는지. 기본은 true 라서 대부분의 시험에는 안내 팝업이 뜨지 않는다.
  bool batteryOk = true;

  /// 시스템 허용 창에서 사용자가 "허용"을 누른 것으로 칠지.
  bool batteryGrant = true;

  /// 있으면 stop() 이 이 Completer 가 끝날 때까지 기다린다 ("멈추는 중" 상태를 눈으로 확인하려고).
  Completer<void>? stopGate;

  @override
  Future<void> init() async => inits++;
  @override
  Future<void> requestPermission() async {}
  @override
  Future<bool> start({required String title, required String text}) async {
    starts++;
    return startOk;
  }

  @override
  Future<void> update({required String title, required String text}) async => updates++;
  @override
  Future<void> stop() async {
    stops++;
    final g = stopGate;
    if (g != null) await g.future;
  }

  @override
  Future<bool> isAlive() async => alive;
  @override
  Future<bool> isBatteryUnrestricted() async => batteryOk;
  @override
  Future<bool> requestBatteryUnrestricted() async {
    batteryRequests++;
    if (batteryGrant) batteryOk = true;
    return batteryOk;
  }
}

class FakeNotifier implements ResultNotifier {
  final shown = <String>[];
  @override
  Future<void> init() async {}
  @override
  Future<void> show({required String title, required String body}) async => shown.add('$title | $body');
}

class MemoryStore implements SecureStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// 업데이트 서버: 릴리스가 아직 없다고(404) 답한다.
class _NoRelease implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async =>
      ResponseBody.fromString(jsonEncode({'message': 'Not Found'}), 404, headers: {
        Headers.contentTypeHeader: ['application/json'],
      });
  @override
  void close({bool force = false}) {}
}

Duration _sameInterval(Duration base, int? soonestMinutes) => base;

class Rig {
  Rig({FakeLibrary? api, FakeBackground? bg, FakeNotifier? notifier})
      : api = api ?? FakeLibrary(),
        bg = bg ?? FakeBackground(),
        notifier = notifier ?? FakeNotifier();

  final FakeLibrary api;
  final FakeBackground bg;
  final FakeNotifier notifier;
  final store = MemoryStore();

  AppServices get services => AppServices(
        newApi: () => api,
        background: bg,
        notifier: notifier,
        secure: store,
        updater: UpdateChecker(dio: Dio()..httpClientAdapter = _NoRelease()),
        layoutFor: (room) async => room == 53 ? _layout53 : null,
        // 확인 간격을 시험용으로 아주 짧게
        policyFor: (_) => const RunPolicy(
          interval: Duration(milliseconds: 20),
          maxBackoff: Duration(milliseconds: 40),
          giveUpAfter: Duration(milliseconds: 400),
          maxReserveFailures: 3,
          pacing: _sameInterval, // 남은 시간이 있어도 시험에서는 늘 짧은 간격
        ),
      );
}

Future<void> _pumpApp(WidgetTester tester, Rig rig) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(App(services: rig.services));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 잠깐씩 시간을 흘려 보낸다 (가짜 시계 위에서 타이머와 Future 가 진행되게).
Future<void> _settle(WidgetTester tester, {int ms = 200}) async {
  for (var i = 0; i < ms ~/ 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 팝업, 펼침 같은 애니메이션이 끝날 때까지 기다린다 (예약이 도는 중에는 진행 표시가 계속 돌아서 쓰지 않는다).
Future<void> _settleAnim(WidgetTester tester) => tester.pumpAndSettle(const Duration(milliseconds: 50));

Future<void> _login(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextField, '학번'), '20240001');
  await tester.enterText(find.widgetWithText(TextField, '비밀번호'), 'pw1234');
  await tester.tap(find.widgetWithText(FilledButton, '로그인'));
  await _settle(tester);
}

Future<void> _pickList(WidgetTester tester, List<String> codes) async {
  // 목록으로 보기로 바꿔 좌석 카드를 직접 누른다 (도면 미리보기는 누르면 전체 화면이 열려서).
  await tester.tap(find.text('목록으로 보기'));
  await tester.pump();
  for (final c in codes) {
    await tester.tap(find.text(c).first);
    await tester.pump();
  }
}

void main() {
  // 도면은 Flutter 에셋 대신 파일에서 직접 읽어 둔다. 에셋 읽기는 시험이 끝나는 순간 진행 중이면 이후 시험까지 막아 버린다.
  setUpAll(() {
    _layout53 = SeatLayout.fromJson(jsonDecode(File('assets/layouts/r53.json').readAsStringSync()) as Map<String, dynamic>);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'lib_seat',
      packageName: 'kr.ssu.libseat.lib_seat',
      version: '1.0.1',
      buildNumber: '2',
      buildSignature: '',
    );
  });

  testWidgets('앱이 뜨고, 열람실 목록이 보이고, 서비스가 초기화된다', (tester) async {
    final rig = Rig();
    await _pumpApp(tester, rig);
    expect(find.text('도서관 좌석 예약'), findsOneWidget);
    expect(find.text('숭실스퀘어ON(2F)'), findsWidgets);
    expect(rig.bg.inits, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('로그인 → 좌석 선택 → 예약 시작 → 좌석이 나면 배정 완료 (앱이 보일 때는 팝업)', (tester) async {
    final api = FakeLibrary(
      script: [_seats(), _seats(), _seats(free: {5}), _seats(free: {5})],
    );
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5', '8']);

    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 400);

    expect(rig.bg.starts, 1);
    expect(api.reservedIds, [105]); // 5번 좌석(id 105)
    expect(find.text('배정 완료!'), findsWidgets); // 팝업
    expect(rig.notifier.shown, isEmpty); // 앱이 보이는 중이라 시스템 알림은 없다
    expect(rig.bg.stops, 1); // 끝나면 서비스도 정리
    expect(await RunMarker.readInterrupted(), isNull);

    await tester.tap(find.widgetWithText(TextButton, '확인'));
    await _settleAnim(tester); // 팝업이 닫히는 애니메이션
    expect(find.byType(AlertDialog), findsNothing); // 팝업은 닫혔고
    expect(find.textContaining('5번 좌석이 배정됐어요'.keepWords), findsOneWidget); // 화면 위 결과 카드에 남아 있다
  });

  testWidgets('앱이 백그라운드에 있을 때 배정되면 시스템 알림으로 알린다', (tester) async {
    final api = FakeLibrary(script: [_seats(), _seats(free: {5})]);
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);

    // 시작한 뒤 홈 화면으로 나간 상태. (예약이 몇십 ms 안에 끝나므로 시작 전에 맞춰 둔다. inactive 는 화면 갱신은 계속된다)
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 400);

    expect(rig.notifier.shown, hasLength(1));
    expect(rig.notifier.shown.single, contains('배정 완료'));
    expect(rig.notifier.shown.single, contains('5번'));
    expect(find.byType(AlertDialog), findsNothing); // 팝업은 띄우지 않는다
  });

  testWidgets('시작 버튼을 연달아 눌러도 서비스와 예약 루프는 한 번만 시작된다', (tester) async {
    final api = FakeLibrary(script: [_seats()]); // 계속 빈자리 없음
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);

    final start = find.textContaining('좌석 예약 시작');
    await tester.tap(start);
    await tester.tap(start, warnIfMissed: false);
    await tester.tap(start, warnIfMissed: false);
    await _settle(tester, ms: 200);

    expect(rig.bg.starts, 1);
    expect(find.text('중지하기'), findsOneWidget);

    // 멈춤
    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
    expect(find.textContaining('좌석 예약 시작'), findsOneWidget);
    expect(rig.bg.stops, 1);
  });

  testWidgets('멈추는 중에는 다시 시작할 수 없고, 끝난 뒤 다시 시작해도 루프는 하나만 돈다', (tester) async {
    final gate = Completer<void>();
    final bg = FakeBackground()..stopGate = gate; // 서비스 종료가 끝나기 전까지 "멈추는 중"에 머문다
    final api = FakeLibrary(script: [_seats()]);
    final rig = Rig(api: api, bg: bg);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);

    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 100);
    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 100);

    expect(find.text('멈추는 중…'), findsOneWidget);
    expect(find.textContaining('좌석 예약 시작'), findsNothing); // 멈추는 중에는 시작 버튼이 없다 -> 겹쳐 시작할 수 없다
    expect(bg.starts, 1);

    gate.complete(); // 서비스 종료 끝
    await _settle(tester, ms: 100);
    expect(find.textContaining('좌석 예약 시작'), findsOneWidget);

    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 100);
    expect(bg.starts, 2);

    // 조회 속도는 루프 "하나"의 속도여야 한다 (20ms 간격이면 200ms 동안 많아야 십여 번. 두 개가 돌면 두 배가 된다)
    final before = api.seatCalls;
    await _settle(tester, ms: 200);
    expect(api.seatCalls - before, lessThanOrEqualTo(14));
    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 100);
  });

  testWidgets('로그인이 거절되면 재시도 없이 멈추고 안내한다', (tester) async {
    final api = FakeLibrary(loginError: LoginException('error.authentication'));
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester); // 첫 로그인 시도 1번
    expect(find.text('로그인에 실패했어요'), findsOneWidget);
    expect(api.logins, 1);
  });

  testWidgets('백그라운드 서비스를 못 띄워도 예약은 돌고, 사용자에게 알린다', (tester) async {
    final rig = Rig(bg: FakeBackground()..startOk = false, api: FakeLibrary(script: [_seats()]));
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 100);
    expect(find.text('중지하기'), findsOneWidget); // 돌고 있다
    expect(find.textContaining('백그라운드 실행을 시작하지 못했어요'), findsWidgets);
    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 100);
  });

  testWidgets('서비스가 시스템에 의해 끝나면 예약을 멈추고 알린다', (tester) async {
    final bg = FakeBackground();
    final rig = Rig(bg: bg, api: FakeLibrary(script: [_seats()]));
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 100);
    expect(find.text('중지하기'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    bg.alive = false; // 시스템이 서비스를 종료
    await _settle(tester, ms: 200);

    expect(rig.notifier.shown.single, contains('백그라운드 실행이 끝나'));
    expect(find.textContaining('좌석 예약 시작'), findsOneWidget); // 멈춘 상태로 돌아왔다
  });

  testWidgets('지난 예약이 중간에 멈췄다면 앱을 켤 때 안내한다 (그리고 안내는 한 번만)', (tester) async {
    SharedPreferences.setMockInitialValues({
      'run_active': true,
      'run_room': '숭실스퀘어ON(2F)',
      'run_count': 3,
      'run_since': DateTime(2026, 10, 3, 1, 0).toIso8601String(),
      'run_last': DateTime(2026, 10, 3, 3, 27).toIso8601String(),
    });
    final rig = Rig();
    await _pumpApp(tester, rig);
    await _settle(tester, ms: 100);

    expect(find.text('지난 예약이 중간에 멈췄어요'), findsOneWidget);
    expect(find.textContaining('03:27'.keepWords), findsOneWidget);
    expect(await RunMarker.readInterrupted(), isNull); // 표시는 지워졌다 -> 다음에 켜도 또 뜨지 않는다

    await tester.tap(find.byTooltip('닫기'));
    await tester.pump();
    expect(find.text('지난 예약이 중간에 멈췄어요'), findsNothing);
  });

  testWidgets('처음 실행하고 배터리 제한이 켜져 있으면 안내 후 시스템 허용 창을 띄운다 (한 번만)', (tester) async {
    final rig = Rig(bg: FakeBackground()..batteryOk = false);
    await _pumpApp(tester, rig);
    await _settleAnim(tester);
    expect(find.text('배터리 제한을 풀어 주세요'), findsOneWidget);
    expect(rig.bg.batteryRequests, 0); // 설명을 읽기 전에는 시스템 창을 띄우지 않는다

    await tester.tap(find.text('확인'));
    await _settleAnim(tester);
    expect(rig.bg.batteryRequests, 1);
    expect(find.text('배터리 제한을 풀었어요.'), findsOneWidget);

    // 같은 기기에서 앱을 다시 켜면 (제한이 다시 켜져 있어도) 또 묻지 않는다.
    await tester.pumpWidget(const SizedBox()); // 앱을 완전히 내렸다가 새로 띄운다 (같은 화면 상태를 재사용하지 않도록)
    final again = Rig(bg: FakeBackground()..batteryOk = false);
    await _pumpApp(tester, again);
    await _settleAnim(tester);
    expect(find.text('배터리 제한을 풀어 주세요'), findsNothing);
    expect(again.bg.batteryRequests, 0);
  });

  testWidgets('안내에서 "나중에"를 누르면 시스템 창을 띄우지 않고, 고급 설정에서 다시 풀 수 있다', (tester) async {
    final rig = Rig(bg: FakeBackground()..batteryOk = false);
    await _pumpApp(tester, rig);
    await _settleAnim(tester);
    await tester.tap(find.text('나중에'));
    await _settleAnim(tester);
    expect(rig.bg.batteryRequests, 0);

    await tester.tap(find.text('고급 설정'));
    await _settleAnim(tester);
    expect(find.textContaining('배터리 제한이 켜져 있으면'.keepWords), findsOneWidget);
    await tester.tap(find.text('제한 풀기'));
    await _settleAnim(tester);
    expect(rig.bg.batteryRequests, 1);
    expect(find.text('제한 풀기'), findsNothing); // 풀렸으니 버튼이 사라진다
    expect(find.textContaining('배터리 제한이 풀려 있어요'.keepWords), findsOneWidget);
  });

  testWidgets('배터리 제한이 이미 풀려 있으면 안내를 띄우지 않는다', (tester) async {
    final rig = Rig();
    await _pumpApp(tester, rig);
    await _settleAnim(tester);
    expect(find.text('배터리 제한을 풀어 주세요'), findsNothing);
    expect(rig.bg.batteryRequests, 0);
    await tester.tap(find.text('고급 설정'));
    await _settleAnim(tester);
    expect(find.textContaining('배터리 제한이 풀려 있어요'.keepWords), findsOneWidget);
    expect(find.text('제한 풀기'), findsNothing);
  });

  // ---------- 좌석 바꾸기 ----------

  MyCharge heldSeat({bool returnable = false}) => MyCharge(
        id: 900,
        seatId: 107,
        seatCode: '7',
        roomId: 53,
        roomName: '숭실스퀘어ON(2F)',
        returnable: returnable,
      );

  Future<void> startAndWait(WidgetTester tester, {int ms = 400}) async {
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: ms);
  }

  testWidgets('좌석을 갖고 있으면 시작할 때 한 번 묻고, 바꾸기를 누르면 반납한 뒤 예약한다', (tester) async {
    final api = FakeLibrary(script: [_seats(), _seats(), _seats(free: {5})], held: [heldSeat()]);
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);

    await startAndWait(tester, ms: 100);
    expect(find.text('7번 좌석을 반납하고 바꿀까요?'), findsOneWidget);
    expect(find.textContaining('바꾸다 실패하면 좌석을 잃을 수 있어요'.keepWords), findsOneWidget); // 이 경고는 좌석이 있을 때만 나온다
    expect(api.calls, isEmpty); // 대답하기 전에는 아무것도 건드리지 않는다

    await tester.tap(find.text('바꾸기'));
    await _settle(tester, ms: 400);

    expect(api.calls, ['cancel:900', 'reserve:105']); // 내 7번을 내놓고(확정 전이라 취소) → 5번 예약
    expect(find.text('배정 완료!'), findsWidgets);
  });

  testWidgets('"아니요"를 누르면 아무것도 하지 않고 예약도 시작하지 않는다', (tester) async {
    final api = FakeLibrary(script: [_seats(free: {5})], held: [heldSeat()]);
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);

    await startAndWait(tester, ms: 100);
    await tester.tap(find.text('아니요'));
    await _settle(tester, ms: 300);

    expect(api.calls, isEmpty);
    expect(find.text('중지하기'), findsNothing); // 도는 중이 아니다
    expect(rig.bg.stops, 1); // 시작해 둔 백그라운드 서비스도 정리됐다
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('좌석이 없으면 묻지 않고, "좌석을 잃을 수 있어요" 경고도 어디에도 나오지 않는다', (tester) async {
    final api = FakeLibrary(script: [_seats(), _seats(free: {5})]); // 갖고 있는 좌석 없음
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    expect(find.textContaining('잃을 수'), findsNothing); // 시작 전 화면에 없다
    await _login(tester);
    await _pickList(tester, ['5']);

    await startAndWait(tester);

    expect(find.textContaining('반납하고 바꿀까요'), findsNothing); // 물어볼 일이 없다
    expect(api.calls, ['reserve:105']); // 반납 없이 예약만
    expect(find.textContaining('잃을 수'), findsNothing);
    expect(find.text('배정 완료!'), findsWidgets);
  });

  testWidgets('선택 목록에 내 좌석이 있으면 그 사실과 바꾸는 기준을 알려 주며 묻는다', (tester) async {
    final api = FakeLibrary(script: [_seats()], held: [heldSeat()]); // 나는 7번, 선택은 5번 → 7번
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5', '7']);

    await startAndWait(tester, ms: 100);
    expect(find.textContaining('이 좌석은 선택한 목록에도 있어요'.keepWords), findsOneWidget);
    expect(find.textContaining('7번보다 먼저 고른 좌석이 나면'.keepWords), findsOneWidget);

    await tester.tap(find.text('아니요'));
    await _settle(tester, ms: 200);
  });

  testWidgets('이미 이용 중(확정)인 좌석은 "이용 중인"이라고 알리고, 허락하면 반납 요청을 보낸다', (tester) async {
    final api = FakeLibrary(script: [_seats(), _seats(free: {5})], held: [heldSeat(returnable: true)]);
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);

    await startAndWait(tester, ms: 100);
    expect(find.textContaining('지금 이용 중인'.keepWords), findsOneWidget);
    await tester.tap(find.text('바꾸기'));
    await _settle(tester, ms: 400);

    expect(api.calls, ['return:900', 'reserve:105']);
  });

  testWidgets('바꾸다 실패해 원래 좌석도 못 되찾으면 홈페이지에서 확인하라고 알린다', (tester) async {
    final api = FakeLibrary(
      script: [_seats(free: {5})],
      held: [heldSeat()],
      reserveResult: {'success': false, 'code': 'error.x', 'message': '이미 예약됨'},
    );
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);

    await startAndWait(tester, ms: 100);
    await tester.tap(find.text('바꾸기'));
    await _settle(tester, ms: 400);

    expect(api.calls, ['cancel:900', 'reserve:105', 'reserve:107']);
    expect(find.text('좌석을 바꾸다 실패했어요'), findsWidgets);
    expect(find.textContaining('홈페이지에서 좌석을 확인해 주세요'.keepWords), findsWidgets);
  });

  testWidgets('저장된 오류 기록이 있으면 고급 설정에 보이고 지울 수 있다', (tester) async {
    await CrashLog.record(StateError('시험용 오류'), null);
    final rig = Rig();
    await _pumpApp(tester, rig);
    await _settle(tester, ms: 100);

    await tester.tap(find.text('고급 설정'));
    await _settleAnim(tester);
    expect(find.text('오류 기록 1건'), findsOneWidget);
    await tester.tap(find.text('보기'));
    await _settleAnim(tester);
    expect(find.textContaining('시험용 오류'), findsOneWidget);
    await tester.tap(find.text('지우기'));
    await _settleAnim(tester);
    expect(find.text('오류 기록 1건'), findsNothing);
    expect(await CrashLog.read(), isEmpty);
  });
}
