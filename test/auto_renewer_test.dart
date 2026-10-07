import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/auto_renewer.dart';

/// 내 좌석. 예약 번호 900, 좌석 18번. 남은 시간(분)과 서버가 알려 주는 값을 바꿔 가며 쓴다.
MyCharge _mine({
  int? remaining = 20,
  bool? renewable = true,
  List<String> methods = const [],
  int? room = 53,
  bool inUse = true,
}) =>
    MyCharge(
      id: 900,
      seatId: 118,
      seatCode: '18',
      roomId: room,
      roomName: '숭실스퀘어ON(2F)',
      returnable: inUse,
      remainingMinutes: remaining,
      renewable: renewable,
      arrivalMethods: methods,
    );

/// 순서대로 응답하는 가짜 서버. 대본이 끝나면 마지막 항목을 계속 반복한다.
/// 내 좌석 대본의 항목은 좌석 목록(`List<MyCharge>`) 또는 예외, 연장 대본의 항목은 응답(`Map`) 또는 예외.
class _Api implements LibraryApi {
  _Api({this.held = const [], this.renew = const [], this.arrival = const [true]});

  final List<Object> held;
  final List<Object> renew;
  final List<bool> arrival;
  int heldCalls = 0, renewCalls = 0, arrivalCalls = 0;
  final arrivalMethodsAsked = <String>[];

  Object _next(List<Object> script, int i) => script[i < script.length ? i : script.length - 1];

  @override
  Future<List<MyCharge>> myCharges() async {
    final i = heldCalls++;
    if (held.isEmpty) return const [];
    final v = _next(held, i);
    if (v is Exception || v is Error) throw v;
    return v as List<MyCharge>;
  }

  @override
  Future<Map<String, dynamic>> renewCharge(int chargeId) async {
    final i = renewCalls++;
    if (renew.isEmpty) return _ok;
    final v = _next(renew, i);
    if (v is Exception || v is Error) throw v;
    return v as Map<String, dynamic>;
  }

  @override
  Future<bool> checkArrival(int roomId, String method) async {
    final i = arrivalCalls++;
    arrivalMethodsAsked.add(method);
    return arrival[i < arrival.length ? i : arrival.length - 1];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _ok = {'success': true};
Map<String, dynamic> _no(String msg) => {'success': false, 'code': 'error.x', 'message': msg};
DioException _net() => DioException.connectionError(requestOptions: RequestOptions(), reason: 'offline');

/// 시험에서 쓰는 아주 짧은 시간표 (문턱 30분은 그대로, 대기 시간만 밀리초로).
RenewPolicy _fast({
  Duration retryAfter = const Duration(milliseconds: 30),
  Duration afterRenew = const Duration(milliseconds: 80),
  Duration giveUpAfter = const Duration(seconds: 1),
  Duration seatWait = const Duration(milliseconds: 10),
}) =>
    RenewPolicy(
      retryAfter: retryAfter,
      maxPoll: const Duration(milliseconds: 10),
      minPoll: const Duration(milliseconds: 2),
      seatWait: seatWait,
      confirmGap: const Duration(milliseconds: 2),
      afterRenew: afterRenew,
      errorBackoff: const Duration(milliseconds: 2),
      maxErrorBackoff: const Duration(milliseconds: 8),
      giveUpAfter: giveUpAfter,
      reloginCooldown: const Duration(hours: 1),
    );

class _Harness {
  _Harness({
    this.api,
    RenewPolicy? policy,
    List<Object>? logins,
    this.stopOn = RenewEventKind.renewed,
    this.stopAfterEvents,
    bool Function()? waitForSeat,
    Future<bool> Function()? alive,
  }) {
    final queue = List<Object>.of(logins ?? const []);
    renewer = SeatRenewer(
      policy: policy ?? _fast(),
      api: api,
      login: () async {
        loginCalls++;
        if (queue.isEmpty) throw StateError('로그인 대본이 비었어요');
        final v = queue.length > 1 ? queue.removeAt(0) : queue.first;
        if (v is Exception) throw v;
        return v as LibraryApi;
      },
      onLog: logs.add,
      onStatus: statuses.add,
      onEvent: (e) {
        events.add(e);
        final n = stopAfterEvents;
        if (n != null ? events.length >= n : e.kind == stopOn) renewer.stop();
      },
      isEnvironmentAlive: alive,
      waitForSeat: waitForSeat,
    );
  }

  final _Api? api;

  /// 이 종류의 일이 생기면 멈춘다 (또는 [stopAfterEvents] 번째 일이 생기면).
  final RenewEventKind stopOn;
  final int? stopAfterEvents;
  late final SeatRenewer renewer;
  final logs = <String>[];
  final statuses = <RenewStatus>[];
  final events = <RenewEvent>[];
  int loginCalls = 0;

  Future<RenewOutcome> run() => renewer.run().timeout(const Duration(seconds: 10));
}

void main() {
  group('연장 시점', () {
    test('남은 시간이 30분 넘으면 기다리다가, 30분 이하가 되면 연장한다', () async {
      final api = _Api(held: [
        [_mine(remaining: 95)],
        [_mine(remaining: 31)],
        [_mine(remaining: 30)], // 30분이면 연장한다
        [_mine(remaining: 240)],
      ]);
      final h = _Harness(api: api);
      final out = await h.run();
      expect(out.reason, RenewEndReason.stopped);
      expect(out.renewed, 1);
      expect(api.renewCalls, 1);
      expect(api.heldCalls, 3, reason: '95분, 31분일 때는 연장하지 않고 다시 조회만 한다');
      expect(h.events.single.kind, RenewEventKind.renewed);
      expect(h.events.single.count, 1);
    });

    test('남은 시간을 모르면 서버가 연장 가능이라고 할 때 연장한다', () async {
      final api = _Api(held: [
        [_mine(remaining: null, renewable: false)],
        [_mine(remaining: null, renewable: true)],
      ]);
      final h = _Harness(api: api);
      await h.run();
      expect(api.renewCalls, 1);
      expect(api.heldCalls, 2);
    });

    test('서버가 아직 연장할 수 없다고 하면 요청하지 않고 기다렸다가 다시 본다', () async {
      final api = _Api(held: [
        [_mine(remaining: 20, renewable: false)],
        [_mine(remaining: 19, renewable: false)],
        [_mine(remaining: 18, renewable: true)],
      ]);
      final h = _Harness(api: api);
      await h.run();
      expect(api.renewCalls, 1);
      expect(api.heldCalls, 3);
      expect(h.logs.where((l) => l.contains('연장할 수 없다고')), isNotEmpty);
    });

    test('방금 연장한 좌석은 서버 값이 그대로여도 곧바로 다시 연장하지 않는다', () async {
      final api = _Api(held: [
        [_mine(remaining: 20)], // 연장 후에도 서버가 같은 값을 돌려주는 상황
      ]);
      final h = _Harness(api: api, policy: _fast(afterRenew: const Duration(seconds: 5)), stopOn: RenewEventKind.failed);
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      h.renewer.stop();
      final out = await run;
      expect(api.renewCalls, 1);
      expect(out.renewed, 1);
      expect(api.heldCalls, greaterThan(2), reason: '그동안에도 조회는 계속한다');
    });

    test('시간이 지나도 여전히 30분 이하면 다시 연장한다 (연장 횟수가 남은 동안)', () async {
      final api = _Api(held: [
        [_mine(remaining: 20)],
      ]);
      final h = _Harness(api: api, stopAfterEvents: 2, policy: _fast(afterRenew: const Duration(milliseconds: 20)));
      final out = await h.run();
      expect(out.renewed, 2);
      expect(api.renewCalls, 2);
    });
  });

  group('아직 이용을 시작하지 않은 좌석', () {
    test('배정만 되고 확정 전이면 남은 시간이 적어도 연장하지 않는다 (헛된 실패 알림을 막는다)', () async {
      final api = _Api(held: [
        [_mine(remaining: 10, renewable: false, inUse: false)],
      ]);
      final h = _Harness(api: api, stopOn: RenewEventKind.failed);
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      h.renewer.stop();
      await run;
      expect(api.renewCalls, 0);
      expect(h.events, isEmpty);
      expect(h.logs.where((l) => l.contains('아직 이용을 시작하기 전')), hasLength(1), reason: '같은 안내는 한 번만 남긴다');
    });

    test('확정되면(이용 중이 되면) 그때부터 연장한다', () async {
      final api = _Api(held: [
        [_mine(remaining: 10, renewable: null, inUse: false)],
        [_mine(remaining: 9, inUse: true)],
      ]);
      final h = _Harness(api: api, policy: _fast(seatWait: const Duration(milliseconds: 10)));
      final out = await h.run();
      expect(out.renewed, 1);
      expect(api.heldCalls, 2);
    });

    test('서버가 연장 가능이라고 하면 이용 중 표시가 없어도 연장한다', () async {
      final api = _Api(held: [
        [_mine(remaining: 10, renewable: true, inUse: false)],
      ]);
      final out = await _Harness(api: api).run();
      expect(out.renewed, 1);
    });
  });

  group('연장 실패와 재시도', () {
    test('실패하면 재시도 간격 뒤에 다시 시도하고, 성공하면 성공으로 알린다', () async {
      final api = _Api(held: [
        [_mine()],
      ], renew: [_no('도서관 밖입니다'), _no('도서관 밖입니다'), _ok]);
      final h = _Harness(api: api);
      final sw = Stopwatch()..start();
      final out = await h.run();
      expect(api.renewCalls, 3);
      expect(out.renewed, 1);
      expect(out.failing, isFalse, reason: '성공했으니 실패 중이 아니다');
      expect(h.events.map((e) => e.kind), [RenewEventKind.failed, RenewEventKind.failed, RenewEventKind.renewed]);
      expect(h.events.map((e) => e.failStreak), [1, 2, 0]);
      expect(h.events.first.message, contains('도서관 밖입니다'));
      expect(h.events.first.retryIn, const Duration(milliseconds: 30));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(55), reason: '실패할 때마다 재시도 간격만큼 기다린다');
    });

    test('연결 오류도 실패로 보고 재시도한다 (도서관 밖에서 와이파이가 끊긴 경우)', () async {
      final api = _Api(held: [
        [_mine()],
      ], renew: [_net(), _ok]);
      final h = _Harness(api: api);
      await h.run();
      expect(api.renewCalls, 2);
      expect(h.events.first.kind, RenewEventKind.failed);
      expect(h.events.last.kind, RenewEventKind.renewed);
    });

    test('실패한 채 좌석이 끝나면 "실패 중이었음"을 알려 준다', () async {
      final api = _Api(held: [
        [_mine()],
        [_mine()],
        <MyCharge>[],
      ], renew: [_no('도서관 밖입니다')]);
      final h = _Harness(api: api, stopOn: RenewEventKind.renewed);
      final out = await h.run();
      expect(out.reason, RenewEndReason.seatEnded);
      expect(out.failing, isTrue);
      expect(out.message, contains('도서관 밖입니다'));
      expect(out.lastSeat?.seatCode, '18');
    });

    test('서버 응답에 이유가 없어도 알아볼 수 있는 문구를 남긴다', () async {
      final api = _Api(held: [
        [_mine()],
      ], renew: [const {'success': false}, _ok]);
      final h = _Harness(api: api);
      await h.run();
      expect(h.events.first.message, isNotEmpty);
      expect(h.events.first.message, isNot(contains('null')));
    });
  });

  group('도서관 안 확인', () {
    test('GATE 확인이 안 되면 연장 요청을 보내지 않고 실패로 본다', () async {
      final api = _Api(held: [
        [_mine(methods: ['GATE'])],
      ], arrival: [false, true]);
      final h = _Harness(api: api);
      await h.run();
      expect(api.arrivalMethodsAsked, ['GATE', 'GATE']);
      expect(api.renewCalls, 1, reason: '첫 시도는 확인에서 막혀 연장 요청이 가지 않았다');
      expect(h.events.first.kind, RenewEventKind.failed);
      expect(h.events.first.message, contains('도서관 안'));
      expect(h.events.last.kind, RenewEventKind.renewed);
    });

    test('AUTO 이면 확인 없이 연장한다', () async {
      final api = _Api(held: [
        [_mine(methods: ['AUTO', 'GATE'])],
      ]);
      await _Harness(api: api).run();
      expect(api.arrivalCalls, 0);
      expect(api.renewCalls, 1);
    });

    test('이 앱이 못 하는 방법(GPS 등)뿐이거나 정보가 없으면 확인 없이 연장을 요청해 서버가 판단하게 한다', () async {
      final gps = _Api(held: [
        [_mine(methods: ['GPS', 'BEACON'])],
      ]);
      await _Harness(api: gps).run();
      expect(gps.arrivalCalls, 0);
      expect(gps.renewCalls, 1);

      final none = _Api(held: [
        [_mine()],
      ]);
      await _Harness(api: none).run();
      expect(none.arrivalCalls, 0);
      expect(none.renewCalls, 1);
    });
  });

  group('좌석이 없을 때', () {
    test('시작할 때 좌석이 없으면 (예약 루프도 없으면) 한 번 더 확인하고 끝낸다', () async {
      final api = _Api();
      final h = _Harness(api: api);
      final out = await h.run();
      expect(out.reason, RenewEndReason.noSeat);
      expect(api.heldCalls, 2);
      expect(api.renewCalls, 0);
    });

    test('좌석을 갖고 있다가 없어지면 이용이 끝난 것으로 본다', () async {
      final api = _Api(held: [
        [_mine(remaining: 100)],
        <MyCharge>[],
      ]);
      final out = await _Harness(api: api).run();
      expect(out.reason, RenewEndReason.seatEnded);
      expect(out.failing, isFalse);
      expect(out.lastSeat?.seatCode, '18');
    });

    test('예약 루프가 좌석을 노리는 동안은 좌석이 없어도 끝내지 않고, 좌석이 생기면 이어서 지켜본다', () async {
      final api = _Api(held: [
        <MyCharge>[],
        <MyCharge>[],
        [_mine()],
      ]);
      final h = _Harness(api: api, waitForSeat: () => true, stopOn: RenewEventKind.failed);
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(h.renewer.isStopped, isFalse, reason: '좌석이 없는 동안에도 끝나지 않았다');
      expect(api.renewCalls, 1, reason: '좌석이 생기자마자 연장 시점이라 연장했다');
      h.renewer.stop();
      final out = await run;
      expect(out.reason, RenewEndReason.stopped);
    });

    test('nudge 하면 긴 대기 중이어도 바로 다시 조회한다', () async {
      final api = _Api(held: [
        <MyCharge>[],
        [_mine()],
      ]);
      final h = _Harness(api: api, waitForSeat: () => true, policy: _fast(seatWait: const Duration(seconds: 30)));
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(api.heldCalls, 1, reason: '30초를 기다리는 중이라 아직 한 번만 조회했다');
      h.renewer.nudge();
      final out = await run;
      expect(out.renewed, 1);
      expect(api.heldCalls, 2);
    });

    test('조회하는 도중에 nudge 해도 놓치지 않는다', () async {
      final gate = Completer<void>();
      final api = _GatedApi(gate, held: [
        <MyCharge>[],
        [_mine()],
      ]);
      final h = _Harness(api: api, waitForSeat: () => true, policy: _fast(seatWait: const Duration(seconds: 30)));
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 20)); // 첫 조회가 gate 에서 멈춰 있다
      h.renewer.nudge();
      gate.complete();
      final out = await run;
      expect(out.renewed, 1);
    });
  });

  group('로그인과 서버 오류', () {
    test('로그인이 풀리면 다시 로그인해서 이어 간다', () async {
      final fresh = _Api(held: [
        [_mine()],
      ]);
      final stale = _Api(held: [SessionException('로그인이 필요합니다')]);
      final h = _Harness(api: stale, logins: [fresh]);
      final out = await h.run();
      expect(h.loginCalls, 1);
      expect(fresh.renewCalls, 1);
      expect(out.renewed, 1);
    });

    test('연장 요청이 로그인 만료로 거절돼도 다시 로그인해서 연장한다', () async {
      final fresh = _Api(held: [
        [_mine()],
      ]);
      final stale = _Api(held: [
        [_mine()],
      ], renew: [SessionException('로그인이 필요합니다')]);
      final h = _Harness(api: stale, logins: [fresh]);
      await h.run();
      expect(stale.renewCalls, 1);
      expect(fresh.renewCalls, 1);
    });

    test('연장만 계속 로그인 만료로 거절돼도 로그인을 끝없이 반복하지 않는다', () async {
      final api = _Api(held: [
        [_mine()],
      ], renew: [SessionException('로그인이 필요합니다')]);
      final h = _Harness(api: api, logins: [api]);
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      h.renewer.stop();
      await run;
      expect(h.loginCalls, lessThanOrEqualTo(3), reason: '연달아 다시 로그인하는 횟수에 상한이 있다');
    });

    test('학번/비밀번호가 거절되면 재시도 없이 끝낸다', () async {
      final stale = _Api(held: [SessionException('만료')]);
      final h = _Harness(api: stale, logins: [LoginException('틀림')]);
      final out = await h.run();
      expect(out.reason, RenewEndReason.loginRejected);
      expect(out.message, '틀림');
      expect(h.loginCalls, 1);
    });

    test('서버가 잠깐 이상해도 계속 시도하고, 오래 안 돌아오면 포기한다', () async {
      final flaky = _Api(held: [_net(), _net(), [_mine()]]);
      final ok = await _Harness(api: flaky).run();
      expect(ok.renewed, 1);

      final down = _Api(held: [_net()]);
      final h = _Harness(api: down, policy: _fast(giveUpAfter: const Duration(milliseconds: 100)));
      final out = await h.run();
      expect(out.reason, RenewEndReason.serverUnavailable);
      expect(out.downFor!.inMilliseconds, greaterThanOrEqualTo(100));
    });

    test('백그라운드 서비스가 끝났으면 멈춘다', () async {
      final api = _Api(held: [
        [_mine(remaining: 100)],
      ]);
      var alive = true;
      final h = _Harness(api: api, alive: () async => alive);
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      alive = false;
      expect((await run).reason, RenewEndReason.environmentLost);
    });

    test('예상하지 못한 오류는 재시도로 덮지 않고 드러낸다', () async {
      final api = _Api(held: [StateError('버그')]);
      final out = await _Harness(api: api).run();
      expect(out.reason, RenewEndReason.crashed);
      expect(out.error, isA<StateError>());
    });
  });

  group('멈춤', () {
    test('대기 중에 멈추면 바로 끝난다', () async {
      final api = _Api(held: [
        [_mine(remaining: 100)],
      ]);
      final h = _Harness(api: api, policy: _fast().copyForTest(maxPoll: const Duration(seconds: 30)));
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final sw = Stopwatch()..start();
      h.renewer.stop();
      final out = await run;
      expect(out.reason, RenewEndReason.stopped);
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('한 인스턴스는 두 번 실행할 수 없다', () async {
      final api = _Api(held: [
        [_mine(remaining: 100)],
      ]);
      final h = _Harness(api: api);
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(() => h.renewer.run(), throwsStateError);
      h.renewer.stop();
      await run;
    });

    test('상태를 조회할 때마다 알려 준다', () async {
      final api = _Api(held: [
        [_mine(remaining: 80)],
        [_mine(remaining: 25)],
      ]);
      final h = _Harness(api: api);
      await h.run();
      expect(h.statuses.first.held?.remainingMinutes, 80);
      expect(h.statuses.last.renewed, 1);
    });
  });
}

/// 내 좌석 조회가 [gate] 가 열릴 때까지 멈춰 있는 가짜 서버.
class _GatedApi extends _Api {
  _GatedApi(this.gate, {required super.held});
  final Completer<void> gate;
  var _first = true;

  @override
  Future<List<MyCharge>> myCharges() async {
    if (_first) {
      _first = false;
      await gate.future;
    }
    return super.myCharges();
  }
}

extension on RenewPolicy {
  RenewPolicy copyForTest({Duration? maxPoll}) => RenewPolicy(
        retryAfter: retryAfter,
        maxPoll: maxPoll ?? this.maxPoll,
        minPoll: minPoll,
        seatWait: seatWait,
        confirmGap: confirmGap,
        afterRenew: afterRenew,
        errorBackoff: errorBackoff,
        maxErrorBackoff: maxErrorBackoff,
        giveUpAfter: giveUpAfter,
        reloginCooldown: reloginCooldown,
      );
}
