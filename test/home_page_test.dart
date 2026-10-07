import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/auto_renewer.dart';
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

  /// 예약이 성공하면 내 좌석이 이 좌석으로 생긴다 (없으면 생기지 않는다).
  MyCharge? grantOnReserve;

  /// 연장 요청에 대한 서버 응답과, 도서관 안에 있다고 확인되는지.
  Map<String, dynamic> renewResult = const {'success': true};
  bool arrived = true;

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
    if (reserveResult['success'] == true && grantOnReserve != null) held.add(grantOnReserve!);
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

  @override
  Future<Map<String, dynamic>> renewCharge(int chargeId) async {
    calls.add('renew:$chargeId');
    return renewResult;
  }

  @override
  Future<bool> checkArrival(int roomId, String method) async {
    calls.add('arrival:$method');
    return arrived;
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

/// 업데이트 서버: 지금보다 높은 버전(1.0.9)의 릴리스가 있다고 답한다.
class _NewRelease implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async =>
      ResponseBody.fromString(
          jsonEncode({
            'tag_name': 'v1.0.9',
            'html_url': 'https://github.com/tae-uk-k/ssu-lib-seat/releases/tag/v1.0.9',
            'draft': false,
            'prerelease': false,
            'body': '시험용 릴리스',
            'assets': [
              {'name': 'ssu-lib-seat-1.0.9.apk', 'browser_download_url': 'https://x/a.apk', 'size': 3},
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          });
  @override
  void close({bool force = false}) {}
}

Duration _sameInterval(Duration base, int? soonestMinutes) => base;

class Rig {
  Rig({FakeLibrary? api, FakeBackground? bg, FakeNotifier? notifier, this.desktop = false, this.newRelease = false})
      : api = api ?? FakeLibrary(),
        bg = bg ?? FakeBackground(),
        notifier = notifier ?? FakeNotifier();

  final FakeLibrary api;
  final FakeBackground bg;
  final FakeNotifier notifier;
  final store = MemoryStore();

  /// 컴퓨터(Windows/macOS)용 동작으로 시험한다.
  final bool desktop;

  /// 새 버전이 나와 있다고 답하는 업데이트 서버를 쓴다.
  final bool newRelease;

  /// 컴퓨터용 업데이트 안내가 연 웹 주소들.
  final openedUrls = <String>[];

  AppServices get services => AppServices(
        newApi: () => api,
        background: bg,
        notifier: notifier,
        secure: store,
        updater: UpdateChecker(dio: Dio()..httpClientAdapter = newRelease ? _NewRelease() : _NoRelease()),
        desktop: desktop,
        openUrl: (url) async {
          openedUrls.add(url);
          return true;
        },
        layoutFor: (room) async => room == 53 ? _layout53 : null,
        // 자동 연장 시간표도 시험용으로 아주 짧게 (문턱 30분은 그대로)
        renewPolicy: const RenewPolicy(
          retryAfter: Duration(milliseconds: 60),
          maxPoll: Duration(milliseconds: 20),
          minPoll: Duration(milliseconds: 5),
          seatWait: Duration(milliseconds: 20),
          confirmGap: Duration(milliseconds: 5),
          afterRenew: Duration(seconds: 5), // 실제 시계로 재므로, 시험 동안 같은 좌석을 두 번 연장하지 않게 길게
          errorBackoff: Duration(milliseconds: 5),
          maxErrorBackoff: Duration(milliseconds: 20),
        ),
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

/// 왼쪽 위 메뉴(서랍)를 연다.
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('메뉴'));
  await _settleAnim(tester);
}

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
    SharedPreferences.setMockInitialValues({'autoRenew': false}); // 자동 연장은 시험 대부분에서 끄고, 필요한 시험에서만 켠다
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
      'autoRenew': false,
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

  testWidgets('안내에서 "나중에"를 누르면 시스템 창을 띄우지 않고, 메뉴에서 다시 풀 수 있다', (tester) async {
    final rig = Rig(bg: FakeBackground()..batteryOk = false);
    await _pumpApp(tester, rig);
    await _settleAnim(tester);
    await tester.tap(find.text('나중에'));
    await _settleAnim(tester);
    expect(rig.bg.batteryRequests, 0);

    await _openMenu(tester);
    expect(find.textContaining('켜져 있으면 화면을 끈 채'.keepWords), findsOneWidget);
    await tester.tap(find.text('제한 풀기'));
    await _settleAnim(tester);
    expect(rig.bg.batteryRequests, 1);
    expect(find.text('제한 풀기'), findsNothing); // 풀렸으니 버튼이 사라진다
    expect(find.textContaining('풀려 있어요'.keepWords), findsOneWidget);
  });

  testWidgets('배터리 제한이 이미 풀려 있으면 안내를 띄우지 않는다', (tester) async {
    final rig = Rig();
    await _pumpApp(tester, rig);
    await _settleAnim(tester);
    expect(find.text('배터리 제한을 풀어 주세요'), findsNothing);
    expect(rig.bg.batteryRequests, 0);
    await _openMenu(tester);
    expect(find.textContaining('풀려 있어요'.keepWords), findsOneWidget);
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

  // ---------- 컴퓨터(Windows/macOS)용 ----------

  testWidgets('컴퓨터용: 예약이 끝나면 앱이 보이는 중에도 시스템 알림을 띄운다 (팝업과 함께)', (tester) async {
    final api = FakeLibrary(script: [_seats(), _seats(free: {5})]);
    final rig = Rig(api: api, desktop: true);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);

    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 400);

    expect(rig.notifier.shown, hasLength(1));
    expect(rig.notifier.shown.single, contains('배정 완료'));
    expect(rig.notifier.shown.single, contains('5번'));
    expect(find.text('배정 완료!'), findsWidgets); // 창이 보이는 중이라 팝업도 뜬다
  });

  testWidgets('컴퓨터용: 예약이 중간에 멈춰도(서비스 종료) 알림으로 알린다', (tester) async {
    final bg = FakeBackground();
    final rig = Rig(bg: bg, api: FakeLibrary(script: [_seats()]), desktop: true);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 100);
    bg.alive = false; // 실행 환경이 사라졌다
    await _settle(tester, ms: 300);

    expect(rig.notifier.shown, hasLength(1));
    expect(rig.notifier.shown.single, contains('백그라운드 실행이 끝나 예약을 멈췄어요'));
  });

  testWidgets('컴퓨터용: 배터리 안내와 메뉴의 배터리 줄이 없다', (tester) async {
    final rig = Rig(bg: FakeBackground()..batteryOk = false, desktop: true); // 폰이라면 안내가 뜰 상태
    await _pumpApp(tester, rig);
    await _settleAnim(tester);
    expect(find.text('배터리 제한을 풀어 주세요'), findsNothing);
    expect(rig.bg.batteryRequests, 0);

    await _openMenu(tester);
    expect(find.text('진행 기록'), findsOneWidget); // 메뉴는 열렸는데
    expect(find.textContaining('배터리'), findsNothing);
    expect(find.text('제한 풀기'), findsNothing);
  });

  testWidgets('컴퓨터용: 화면 어디에도 폰 기준 문구가 없다 (로그인 칸, 실행 중 안내)', (tester) async {
    final rig = Rig(api: FakeLibrary(script: [_seats()]), desktop: true);
    await _pumpApp(tester, rig);
    expect(find.textContaining('폰'), findsNothing);
    expect(find.textContaining('이 컴퓨터에 안전하게 저장'), findsOneWidget);
    expect(find.textContaining('컴퓨터 안에만 보관'), findsOneWidget);

    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 200);
    expect(find.textContaining('폰'), findsNothing);
    expect(find.textContaining('최근 앱'), findsNothing);
    expect(find.textContaining('창을 닫으면 예약도 멈춰요'.keepWords), findsOneWidget);

    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
  });

  testWidgets('컴퓨터용: 지난 예약이 중간에 멈췄다는 안내도 창 기준으로 적는다', (tester) async {
    SharedPreferences.setMockInitialValues({
      'autoRenew': false,
      'run_active': true,
      'run_room': '숭실스퀘어ON(2F)',
      'run_count': 3,
      'run_since': DateTime(2026, 10, 3, 1, 0).toIso8601String(),
      'run_last': DateTime(2026, 10, 3, 3, 27).toIso8601String(),
    });
    final rig = Rig(desktop: true);
    await _pumpApp(tester, rig);
    await _settle(tester, ms: 100);
    expect(find.text('지난 예약이 중간에 멈췄어요'), findsOneWidget);
    expect(find.textContaining('창을 닫거나 앱이 종료되면'.keepWords), findsOneWidget);
    expect(find.textContaining('최근 앱'), findsNothing);
  });

  testWidgets('폰용: 배터리 안내가 뜨고, 메뉴에도 배터리 줄이 있다', (tester) async {
    final rig = Rig(bg: FakeBackground()..batteryOk = false);
    await _pumpApp(tester, rig);
    await _settleAnim(tester);
    expect(find.text('배터리 제한을 풀어 주세요'), findsOneWidget);
    await tester.tap(find.text('나중에'));
    await _settleAnim(tester);
    await _openMenu(tester);
    expect(find.text('배터리 제한'), findsOneWidget);
  });

  testWidgets('컴퓨터용: 새 버전이 있으면 다운로드 페이지를 열고, 예약이 도는 중에도 누를 수 있다', (tester) async {
    final api = FakeLibrary(script: [_seats()]); // 계속 빈자리 없음
    final rig = Rig(api: api, desktop: true, newRelease: true);
    await _pumpApp(tester, rig);
    await _settle(tester, ms: 100);
    expect(find.text('새 버전 1.0.9이 나왔어요'), findsOneWidget);
    expect(find.text('업데이트'), findsNothing); // 폰용 버튼은 없다

    await tester.tap(find.text('다운로드 페이지 열기'));
    await tester.pump();
    expect(rig.openedUrls, ['https://github.com/tae-uk-k/ssu-lib-seat/releases/tag/v1.0.9']);

    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 200);
    expect(find.text('중지하기'), findsOneWidget);

    // 예약이 도는 중에도 웹 페이지는 열 수 있다 (앱을 건드리지 않으니 막을 이유가 없다).
    await tester.tap(find.text('다운로드 페이지 열기'));
    await tester.pump();
    expect(rig.openedUrls, hasLength(2));
    expect(find.textContaining('예약을 멈춘 뒤에'.keepWords), findsNothing);

    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
  });

  testWidgets('폰용: 새 버전이 있어도 예약이 도는 중에는 업데이트를 막는다 (기존 동작)', (tester) async {
    final api = FakeLibrary(script: [_seats()]);
    final rig = Rig(api: api, newRelease: true);
    await _pumpApp(tester, rig);
    await _settle(tester, ms: 100);
    expect(find.text('업데이트'), findsOneWidget);
    expect(find.text('다운로드 페이지 열기'), findsNothing);

    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 200);
    expect(find.textContaining('예약을 멈춘 뒤에'.keepWords), findsOneWidget);
    expect(rig.openedUrls, isEmpty);

    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
  });

  testWidgets('넓은 창에서도 내용은 폭 640 안에 가운데로 모인다', (tester) async {
    final rig = Rig(desktop: true);
    await _pumpApp(tester, rig); // 시험 창 폭은 800
    final box = tester.getRect(find.byType(ListView));
    expect(box.width, lessThanOrEqualTo(640));
    expect(box.center.dx, closeTo(400, 1)); // 가운데
  });

  testWidgets('저장된 오류 기록이 있으면 메뉴에 보이고 지울 수 있다', (tester) async {
    await CrashLog.record(StateError('시험용 오류'), null);
    final rig = Rig();
    await _pumpApp(tester, rig);
    await _settle(tester, ms: 100);

    await _openMenu(tester);
    expect(find.text('오류 기록 1건'), findsOneWidget);
    await tester.tap(find.text('오류 기록 1건'));
    await _settleAnim(tester);
    expect(find.textContaining('시험용 오류'), findsOneWidget);
    await tester.tap(find.text('지우기'));
    await _settleAnim(tester);
    await _openMenu(tester);
    expect(find.text('오류 기록 1건'), findsNothing);
    expect(await CrashLog.read(), isEmpty);
  });

  // ---------- 메뉴와 정리된 화면 ----------

  testWidgets('메인 화면에는 설명 글과 설정이 없고, 메뉴에 모여 있다', (tester) async {
    final rig = Rig(api: FakeLibrary(script: [_seats()]));
    await _pumpApp(tester, rig);
    await _login(tester);
    // 지운 것들
    for (final gone in ['지금 빈 좌석만', '고급 설정', '선택한 좌석 (우선순위 순)', '노란 숫자는 우선순위', '도면을 누르면 크게 열려요', '사용 중인 좌석도 고를 수 있', '아래 순서대로 따라 해 보세요', '진행 기록']) {
      expect(find.textContaining(gone), findsNothing, reason: gone);
    }
    // 남은 것들
    expect(find.text('전체 선택'), findsOneWidget);
    expect(find.text('모두 해제'), findsOneWidget);
    expect(find.text('자동 연장'), findsOneWidget);

    await _openMenu(tester);
    for (final item in ['진행 기록', '확인 간격', '업데이트 확인', '배터리 제한']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    expect(find.textContaining('버전 1.0.1'), findsWidgets);
  });

  testWidgets('좌석을 고르고 시작하면 메뉴의 진행 기록에 쌓인다', (tester) async {
    final rig = Rig(api: FakeLibrary(script: [_seats()]));
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 200);

    await tester.tap(find.byTooltip('메뉴'));
    await _settle(tester, ms: 400); // 예약이 도는 중이라 pumpAndSettle 은 쓰지 않는다
    await tester.tap(find.text('진행 기록'));
    await _settle(tester, ms: 800);
    expect(find.textContaining('감시 시작'), findsOneWidget);
    await tester.pageBack();
    await _settle(tester, ms: 400);
    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
  });

  testWidgets('메뉴에서 확인 간격을 바꾸면 저장된다 (잘못 입력하면 그대로)', (tester) async {
    final rig = Rig();
    await _pumpApp(tester, rig);
    await _openMenu(tester);
    expect(find.text('1.5초'), findsOneWidget);

    await tester.tap(find.text('확인 간격'));
    await _settleAnim(tester);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '3');
    await tester.tap(find.widgetWithText(TextButton, '확인'));
    await _settleAnim(tester);
    expect((await SharedPreferences.getInstance()).getString('interval'), '3');
    await _openMenu(tester);
    expect(find.text('3초'), findsOneWidget);

    await tester.tap(find.text('확인 간격'));
    await _settleAnim(tester);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'abc');
    await tester.tap(find.widgetWithText(TextButton, '확인'));
    await _settleAnim(tester);
    expect((await SharedPreferences.getInstance()).getString('interval'), '3'); // 그대로
    await _openMenu(tester);
    expect(find.text('3초'), findsOneWidget);
  });

  testWidgets('예약이 도는 동안에는 확인 간격을 바꿀 수 없다고 알려 준다', (tester) async {
    final rig = Rig(api: FakeLibrary(script: [_seats()]));
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 200);
    await tester.tap(find.byTooltip('메뉴'));
    await _settle(tester, ms: 400);
    await tester.tap(find.text('확인 간격'));
    await _settle(tester, ms: 400);
    expect(find.textContaining('예약이 도는 동안에는 바꿀 수 없어요'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
  });

  testWidgets('앱을 켤 때 업데이트 확인은 최근에 "새 버전 없음"이었다면 건너뛴다 (직접 누르면 항상 확인)', (tester) async {
    SharedPreferences.setMockInitialValues({
      'autoRenew': false,
      'updateCheckedAt': DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    });
    final rig = Rig(newRelease: true); // 서버에는 새 버전이 있지만
    await _pumpApp(tester, rig);
    await _settle(tester, ms: 100);
    expect(find.text('새 버전 1.0.9이 나왔어요'), findsNothing); // 켤 때는 묻지 않았다

    await _openMenu(tester);
    await tester.tap(find.text('업데이트 확인'));
    await _settle(tester, ms: 200);
    expect(find.text('새 버전 1.0.9이 나왔어요'), findsOneWidget); // 직접 누르면 확인한다
  });

  testWidgets('새 버전이 있다고 나온 동안에는 켤 때마다 확인해서 안내를 보여 준다', (tester) async {
    SharedPreferences.setMockInitialValues({'autoRenew': false}); // 확인 기록 없음
    final rig = Rig(newRelease: true);
    await _pumpApp(tester, rig);
    await _settle(tester, ms: 100);
    expect(find.text('새 버전 1.0.9이 나왔어요'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getInt('updateCheckedAt'), isNull); // 새 버전이 있으니 기록하지 않는다
  });

  // ---------- 자동 연장 ----------

  MyCharge mine({int remaining = 20, String code = '5', bool? renewable = true, List<String> methods = const []}) => MyCharge(
        id: 900,
        seatId: 105,
        seatCode: code,
        roomId: 53,
        roomName: '숭실스퀘어ON(2F)',
        returnable: true,
        remainingMinutes: remaining,
        renewable: renewable,
        arrivalMethods: methods,
      );

  testWidgets('자동 연장은 기본으로 켜져 있고, 끄면 저장되고 시작 버튼 글자가 바뀐다', (tester) async {
    SharedPreferences.setMockInitialValues({}); // 저장된 값 없음 = 기본값
    final rig = Rig();
    await _pumpApp(tester, rig);
    final sw = find.byType(Switch);
    expect(tester.widget<Switch>(sw).value, isTrue);
    expect(find.text('자동 연장만 시작'), findsOneWidget); // 좌석을 안 골랐고 자동 연장이 켜져 있으면

    await tester.tap(sw);
    await _settleAnim(tester);
    expect(tester.widget<Switch>(sw).value, isFalse);
    expect(find.text('예약 시작'), findsWidgets);
    expect((await SharedPreferences.getInstance()).getBool('autoRenew'), isFalse);
  });

  testWidgets('좌석을 안 골랐고 자동 연장도 껐으면 시작할 수 없다', (tester) async {
    final rig = Rig(); // autoRenew: false
    await _pumpApp(tester, rig);
    await _login(tester);
    await tester.tap(find.text('예약 시작').last);
    await _settle(tester, ms: 100);
    expect(find.textContaining('예약할 좌석을 하나 이상 선택해 주세요'), findsOneWidget);
    expect(rig.bg.starts, 0);
  });

  testWidgets('자동 연장만 시작: 남은 시간이 30분 이하인 내 좌석을 연장하고 계속 지켜본다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeLibrary(held: [mine(remaining: 20, methods: ['GATE'])]);
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);

    await tester.tap(find.text('자동 연장만 시작'));
    await _settle(tester, ms: 300);

    expect(api.calls, ['arrival:GATE', 'renew:900']); // 도서관 안 확인 → 연장, 서버 값이 바로 안 바뀌어도 한 번만
    expect(rig.bg.starts, 1);
    expect(find.text('중지하기'), findsOneWidget); // 계속 지켜본다
    expect(find.text('자동 연장을 지켜보는 중이에요'), findsOneWidget);
    expect(find.textContaining('이번 실행에서 1번 연장했어요'), findsOneWidget);
    expect(find.textContaining('5번 좌석을 연장했어요'), findsOneWidget); // 앱이 보이는 중이라 알림 대신 안내

    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
    expect(find.text('자동 연장만 시작'), findsOneWidget);
    expect(rig.bg.stops, 1);
    expect(await RunMarker.readInterrupted(), isNull);
  });

  testWidgets('연장이 실패하면 안내하고 다시 시도하다가, 되면 성공으로 알린다 (백그라운드면 시스템 알림)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeLibrary(held: [mine(remaining: 20)])
      ..renewResult = {'success': false, 'code': 'error.outside', 'message': '도서관 밖입니다'};
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); // 폰이 백그라운드에 있다
    await tester.tap(find.text('자동 연장만 시작'));
    await _settle(tester, ms: 300);

    expect(api.calls.where((c) => c == 'renew:900').length, greaterThanOrEqualTo(2)); // 계속 다시 시도한다
    expect(find.textContaining('연장에 실패했어요'.keepWords), findsOneWidget);
    expect(find.textContaining('도서관 밖입니다'.keepWords), findsWidgets);
    final failures = rig.notifier.shown.where((n) => n.startsWith('연장하지 못했어요')).toList();
    expect(failures, hasLength(1), reason: '실패가 이어져도 알림은 처음 한 번만');
    expect(failures.single, contains('도서관 밖입니다'));

    api.renewResult = const {'success': true}; // 도서관에 들어왔다
    await _settle(tester, ms: 300);
    expect(find.textContaining('연장에 실패했어요'.keepWords), findsNothing);
    expect(rig.notifier.shown.last, startsWith('연장했어요'));

    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
  });

  testWidgets('연장할 좌석이 없으면 알려 주고 끝낸다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeLibrary(); // 갖고 있는 좌석 없음
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await tester.tap(find.text('자동 연장만 시작'));
    await _settle(tester, ms: 300);
    expect(find.text('연장할 좌석이 없어요'), findsWidgets);
    expect(find.text('자동 연장만 시작'), findsOneWidget); // 끝나서 다시 시작할 수 있다
    expect(rig.bg.stops, 1);
    expect(api.calls, isEmpty);
  });

  testWidgets('이미 가장 원하는 좌석이 있으면 예약은 마치고 자동 연장만 이어 간다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeLibrary(script: [_seats()], held: [mine(remaining: 100)]); // 5번을 이미 갖고 있고 아직 시간이 많다
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 300);

    expect(find.text('이미 가장 원하는 좌석이에요'), findsWidgets); // 팝업
    expect(find.textContaining('자동 연장만 계속해요'.keepWords), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '확인'));
    await _settleAnimRunning(tester);
    expect(find.text('중지하기'), findsOneWidget); // 끝나지 않고 연장을 지켜본다
    expect(find.text('자동 연장을 지켜보는 중이에요'), findsOneWidget);
    expect(find.textContaining('이용 종료까지 1시간 40분'.keepWords), findsOneWidget);
    expect(api.calls, isEmpty); // 아직 때가 아니라 연장하지 않았다
    expect(rig.bg.stops, 0);

    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
    expect(rig.bg.stops, 1);
  });

  testWidgets('좌석 바꾸기를 "아니요" 해도 갖고 있는 좌석의 자동 연장은 이어 간다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeLibrary(script: [_seats()], held: [mine(remaining: 20, code: '5')]); // 8번을 노리는데 5번을 갖고 있다
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['8']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 200);
    expect(find.text('5번 좌석을 반납하고 바꿀까요?'), findsOneWidget); // 바꿀지 묻는다
    await tester.tap(find.text('아니요'));
    await _settle(tester, ms: 400);

    expect(find.text('중지하기'), findsOneWidget); // 끝나지 않고
    expect(find.text('자동 연장을 지켜보는 중이에요'), findsOneWidget); // 연장을 이어 간다
    expect(api.calls, contains('renew:900')); // 남은 시간이 20분이라 연장했다
    expect(api.calls.where((c) => c.startsWith('cancel') || c.startsWith('return')), isEmpty); // 좌석은 건드리지 않았다
    expect(rig.bg.stops, 0);

    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
    expect(rig.bg.stops, 1);
  });

  testWidgets('좌석 바꾸기를 "아니요" 하고 자동 연장도 꺼 두면 예전처럼 멈춘다', (tester) async {
    final api = FakeLibrary(script: [_seats()], held: [mine(remaining: 20, code: '5')]);
    final rig = Rig(api: api); // autoRenew: false
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['8']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 200);
    await tester.tap(find.text('아니요'));
    await _settle(tester, ms: 300);
    expect(find.text('중지하기'), findsNothing);
    expect(rig.bg.stops, 1);
    expect(api.calls, isEmpty);
  });

  testWidgets('자동 연장을 끄면 예전처럼 좌석을 받는 즉시 끝난다', (tester) async {
    final api = FakeLibrary(script: [_seats(), _seats(free: {8})]);
    final rig = Rig(api: api); // autoRenew: false
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['8']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 300);
    expect(api.reservedIds, [108]);
    expect(find.text('중지하기'), findsNothing);
    expect(rig.bg.stops, 1);
    expect(api.heldCalls, 2, reason: '내 좌석 조회는 예약 루프가 시작할 때와 빈 좌석을 찾았을 때뿐이다 (자동 연장 루프가 따로 조회하지 않는다)');
  });

  testWidgets('좌석을 받으면 팝업으로 알리고 자동 연장으로 이어서, 받은 좌석을 지켜본다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeLibrary(script: [_seats(), _seats(free: {5})], held: [])..grantOnReserve = mine(remaining: 100);
    final rig = Rig(api: api);
    await _pumpApp(tester, rig);
    await _login(tester);
    await _pickList(tester, ['5']);
    await tester.tap(find.textContaining('좌석 예약 시작'));
    await _settle(tester, ms: 400);

    expect(api.reservedIds, [105]);
    expect(find.text('배정 완료!'), findsWidgets);
    expect(find.textContaining('이용 종료 30분 전에 연장해요'.keepWords), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '확인'));
    await _settleAnimRunning(tester);
    expect(find.text('자동 연장을 지켜보는 중이에요'), findsOneWidget);
    expect(find.textContaining('5번 좌석'.keepWords), findsWidgets);
    expect(find.textContaining('이용 종료까지 1시간 40분'.keepWords), findsOneWidget);
    expect(rig.bg.stops, 0);

    await tester.tap(find.text('중지하기'));
    await _settle(tester, ms: 200);
    expect(rig.bg.stops, 1);
  });

  testWidgets('새 버전이 없다고 나오면 확인한 시각을 기록해 둔다', (tester) async {
    final rig = Rig(); // 릴리스 없음
    await _pumpApp(tester, rig);
    await _settle(tester, ms: 100);
    expect((await SharedPreferences.getInstance()).getInt('updateCheckedAt'), isNotNull);
  });
}

/// 예약이 도는 동안 팝업이 닫히는 시간을 기다린다 (진행 표시가 계속 돌아 pumpAndSettle 은 쓸 수 없다).
Future<void> _settleAnimRunning(WidgetTester tester) => _settle(tester, ms: 400);
