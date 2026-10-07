import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/reservation_runner.dart';

Seat _seat(String code, {bool free = true, int remaining = 0}) => Seat(
      id: int.parse(code) + 100,
      code: code,
      active: true,
      occupied: !free,
      remainingTime: remaining,
      chargeTime: remaining > 0 ? 240 : 0,
    );

/// 순서대로 응답하는 가짜 서버. 대본이 끝나면 마지막 항목을 계속 반복한다.
/// 항목이 예외(Exception, Error)면 던지고, 좌석 목록이면 돌려준다.
class FakeApi implements LibraryApi {
  FakeApi({
    this.seatScript = const [],
    this.reserveScript = const [],
    this.heldScript = const [],
    this.cancelScript = const [],
  });
  final List<Object> seatScript;
  final List<Object> reserveScript;

  /// 내 좌석 조회 대본. 비어 있으면 갖고 있는 좌석이 없다. 항목은 내 좌석 목록(MyCharge 의 List) 또는 예외.
  final List<Object> heldScript;

  /// 취소/반납 응답 대본 (둘이 같이 쓴다). 비어 있으면 항상 성공.
  final List<Object> cancelScript;
  int seatCalls = 0, reserveCalls = 0, heldCalls = 0, cancelCalls = 0;

  /// 상태를 바꾼 요청의 순서 ('cancel:예약번호', 'return:예약번호', 'reserve:좌석id').
  final calls = <String>[];
  Completer<void>? seatGate; // 있으면 seats() 가 여기서 기다린다 (조회 도중 중지 시험용)
  Completer<void>? cancelGate; // 있으면 취소/반납이 여기서 기다린다 (도중에 중지 시험용)

  Object _next(List<Object> script, int i) => script[i < script.length ? i : script.length - 1];

  @override
  Future<List<Seat>> seats(int roomId) async {
    final i = seatCalls++;
    if (seatGate != null) await seatGate!.future;
    final v = _next(seatScript, i);
    if (v is Exception || v is Error) throw v;
    return v as List<Seat>;
  }

  @override
  Future<Map<String, dynamic>> reserve(int seatId) async {
    final i = reserveCalls++;
    calls.add('reserve:$seatId');
    final v = _next(reserveScript, i);
    if (v is Exception || v is Error) throw v;
    return v as Map<String, dynamic>;
  }

  @override
  Future<List<MyCharge>> myCharges() async {
    final i = heldCalls++;
    if (heldScript.isEmpty) return const [];
    final v = _next(heldScript, i);
    if (v is Exception || v is Error) throw v;
    return v as List<MyCharge>;
  }

  Future<Map<String, dynamic>> _release(String kind, int chargeId) async {
    final i = cancelCalls++;
    calls.add('$kind:$chargeId');
    if (cancelGate != null) await cancelGate!.future;
    if (cancelScript.isEmpty) return {'success': true};
    final v = _next(cancelScript, i);
    if (v is Exception || v is Error) throw v;
    return v as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> cancelCharge(int chargeId) => _release('cancel', chargeId);

  @override
  Future<Map<String, dynamic>> returnCharge(int chargeId) => _release('return', chargeId);

  @override
  Future<void> login(String uid, String pw) async {}
  @override
  Future<List<Room>> rooms() async => const [];
}

const _ok = {'success': true};
Map<String, dynamic> _no(String msg) => {'success': false, 'code': 'error.x', 'message': msg};

DioException _net() => DioException.connectionError(requestOptions: RequestOptions(), reason: 'offline');

/// 시험에서 쓰는 아주 짧은 간격.
RunPolicy _fast({
  Duration giveUpAfter = const Duration(seconds: 5),
  int maxQuickRelogins = 3,
  Duration reloginCooldown = const Duration(hours: 1),
  int maxReserveFailures = 8,
  int maxSwapAttempts = 3,
  Duration Function(Duration, int?) pacing = _sameInterval,
}) =>
    RunPolicy(
      interval: const Duration(milliseconds: 2),
      maxBackoff: const Duration(milliseconds: 8),
      giveUpAfter: giveUpAfter,
      maxQuickRelogins: maxQuickRelogins,
      reloginCooldown: reloginCooldown,
      maxReserveFailures: maxReserveFailures,
      maxSwapAttempts: maxSwapAttempts,
      pacing: pacing,
    );

/// 시험에서는 남은 시간과 상관없이 늘 가장 빠른 간격으로 확인한다 (실제 늘리는 규칙은 따로 시험한다).
Duration _sameInterval(Duration base, int? soonestMinutes) => base;

/// 내가 갖고 있는 좌석. 예약 번호는 900, 좌석 id 는 [_seat] 와 같은 규칙(번호 + 100).
MyCharge _held(String code, {bool returnable = false, int? room = 53}) => MyCharge(
      id: 900,
      seatId: int.parse(code) + 100,
      seatCode: code,
      roomId: room,
      roomName: '숭실스퀘어ON(2F)',
      returnable: returnable,
    );

class _Harness {
  _Harness({
    this.api,
    List<Object>? logins,
    RunPolicy? policy,
    List<String> wanted = const ['1'],
    Future<bool> Function()? alive,
    bool replace = false,
    ReplaceConfirm? confirm,
  }) {
    final queue = List<Object>.of(logins ?? const []);
    runner = ReservationRunner(
      roomId: 53,
      wanted: wanted,
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
      isEnvironmentAlive: alive,
      replaceExisting: replace,
      confirmReplace: confirm,
    );
  }

  final FakeApi? api;
  late final ReservationRunner runner;
  final logs = <String>[];
  final statuses = <RunStatus>[];
  int loginCalls = 0;

  Future<RunOutcome> run() => runner.run().timeout(const Duration(seconds: 10));
}

void main() {
  group('정상 동작', () {
    test('우선순위가 높은 빈 좌석을 예약한다', () async {
      final api = FakeApi(seatScript: [
        [_seat('1'), _seat('2'), _seat('3', free: false)],
      ], reserveScript: [_ok]);
      final h = _Harness(api: api, wanted: ['3', '2', '1']);
      final out = await h.run();
      expect(out, isA<Reserved>());
      expect((out as Reserved).seat.code, '2'); // 3번은 사용 중이라 다음 우선순위인 2번
      expect(api.reserveCalls, 1);
    });

    test('자리가 날 때까지 계속 확인하다가 예약한다 (상태/가장 빨리 비는 좌석 포함)', () async {
      final busy = [_seat('1', free: false, remaining: 45), _seat('2', free: false, remaining: 12)];
      final api = FakeApi(seatScript: [busy, busy, [_seat('1'), _seat('2', free: false, remaining: 12)]], reserveScript: [_ok]);
      final h = _Harness(api: api, wanted: ['1', '2']);
      final out = await h.run();
      expect((out as Reserved).seat.code, '1');
      expect(h.statuses.map((s) => s.free), [0, 0, 1]);
      expect(h.statuses.first.soonest!.code, '2'); // 12분 남은 2번이 가장 빨리 빈다
      expect(h.statuses.last.checks, 3);
    });

    test('빈 좌석이 없다는 같은 기록은 계속 쌓이지 않는다', () async {
      final api = FakeApi(seatScript: [
        [_seat('1', free: false)],
      ]);
      late _Harness h;
      h = _Harness(api: api);
      final done = h.runner.run();
      while (h.statuses.length < 100) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      h.runner.stop();
      expect(await done, isA<Stopped>());
      expect(h.logs.where((l) => l.startsWith('빈 좌석 없음')).length, lessThanOrEqualTo(4));
    });
  });

  group('중지', () {
    test('긴 대기 중에도 즉시 멈춘다', () async {
      final api = FakeApi(seatScript: [
        [_seat('1', free: false)],
      ]);
      final runner = ReservationRunner(
        roomId: 53,
        wanted: ['1'],
        policy: const RunPolicy(interval: Duration(seconds: 30)),
        api: api,
        login: () async => api,
        onLog: (_) {},
        onStatus: (_) {},
      );
      final sw = Stopwatch()..start();
      final done = runner.run();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      runner.stop();
      expect(await done.timeout(const Duration(seconds: 2)), isA<Stopped>());
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('시작 전에 멈추면 서버를 건드리지 않는다', () async {
      final api = FakeApi(seatScript: [[_seat('1')]]);
      final h = _Harness(api: api, logins: [api]);
      h.runner.stop();
      expect(await h.run(), isA<Stopped>());
      expect(api.seatCalls, 0);
      expect(h.loginCalls, 0);
    });

    test('조회하는 도중 멈추면 빈 좌석이 보여도 예약하지 않는다', () async {
      final api = FakeApi(seatScript: [[_seat('1')]], reserveScript: [_ok])..seatGate = Completer<void>();
      final h = _Harness(api: api);
      final done = h.runner.run();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      h.runner.stop();
      api.seatGate!.complete();
      expect(await done.timeout(const Duration(seconds: 2)), isA<Stopped>());
      expect(api.reserveCalls, 0);
    });

    test('한 인스턴스는 한 번만 실행할 수 있다 (중복 루프 방지)', () async {
      final api = FakeApi(seatScript: [[_seat('1')]], reserveScript: [_ok]);
      final h = _Harness(api: api);
      await h.run();
      expect(() => h.runner.run(), throwsStateError);
    });
  });

  group('일시적인 서버 오류', () {
    test('네트워크, 서버 오류, 이상한 응답이 섞여도 멈추지 않고 이어간다', () async {
      final api = FakeApi(seatScript: [
        _net(),
        ApiException('서버 오류 (HTTP 502)'),
        ApiException('예상하지 못한 응답 (HTTP 200)'),
        [_seat('1')],
      ], reserveScript: [_ok]);
      final h = _Harness(api: api);
      expect(await h.run(), isA<Reserved>());
      expect(h.logs.any((l) => l.contains('서버 응답 오류')), isTrue);
      expect(h.logs.any((l) => l.contains('서버 연결이 돌아왔어요')), isTrue);
    });

    test('오류 상태가 화면에 전달된다', () async {
      final api = FakeApi(seatScript: [
        ApiException('서버 오류 (HTTP 503)'),
        [_seat('1')],
      ], reserveScript: [_ok]);
      final h = _Harness(api: api);
      await h.run();
      expect(h.statuses.first.errorStreak, 1);
      expect(h.statuses.first.lastError, contains('503'));
      expect(h.statuses.last.errorStreak, 0);
    });

    test('오류만 오래 계속되면 포기하고 사유를 알린다', () async {
      final api = FakeApi(seatScript: [ApiException('서버 오류 (HTTP 500)')]);
      final h = _Harness(api: api, policy: _fast(giveUpAfter: const Duration(milliseconds: 150)));
      final out = await h.run();
      expect(out, isA<ServerUnavailable>());
      expect((out as ServerUnavailable).lastError, contains('500'));
      expect(out.downFor, greaterThanOrEqualTo(const Duration(milliseconds: 150)));
    });

    test('예상 못한 프로그램 오류는 재시도로 덮지 않고 Crashed 로 끝낸다', () async {
      for (final bug in <Object>[StateError('버그'), const FormatException('파싱 버그'), TypeError()]) {
        final api = FakeApi(seatScript: [bug]);
        final out = await _Harness(api: api).run();
        expect(out, isA<Crashed>(), reason: '$bug');
        expect(api.seatCalls, 1, reason: '$bug 는 다시 시도하지 않는다');
      }
    });
  });

  group('로그인', () {
    test('처음 로그인이 거절되면 재시도 없이 멈춘다 (계정 잠금 방지)', () async {
      final h = _Harness(logins: [LoginException('error.authentication 비밀번호 불일치')]);
      final out = await h.run();
      expect(out, isA<LoginRejected>());
      expect((out as LoginRejected).message, contains('비밀번호'));
      expect(h.loginCalls, 1);
    });

    test('처음 로그인 중 네트워크 오류는 재시도해서 이어간다', () async {
      final api = FakeApi(seatScript: [[_seat('1')]], reserveScript: [_ok]);
      final h = _Harness(logins: [_net(), api]);
      expect(await h.run(), isA<Reserved>());
      expect(h.loginCalls, 2);
    });

    test('세션이 풀리면 다시 로그인하고 이어간다', () async {
      final expired = FakeApi(seatScript: [SessionException('error.unauthorized')]);
      final fresh = FakeApi(seatScript: [[_seat('1')]], reserveScript: [_ok]);
      final h = _Harness(api: expired, logins: [fresh]);
      expect(await h.run(), isA<Reserved>());
      expect(h.loginCalls, 1);
    });

    test('다시 로그인했는데 거절되면 곧바로 멈춘다', () async {
      final expired = FakeApi(seatScript: [SessionException('만료')]);
      final h = _Harness(api: expired, logins: [LoginException('거절')]);
      expect(await h.run(), isA<LoginRejected>());
      expect(h.loginCalls, 1);
    });

    test('다시 로그인을 반복해도 안 되면 횟수를 제한하고 서버 문제로 본다', () async {
      final bad = FakeApi(seatScript: [SessionException('계속 거부')]);
      final h = _Harness(
        api: bad,
        logins: [bad],
        policy: _fast(maxQuickRelogins: 3, giveUpAfter: const Duration(milliseconds: 200), reloginCooldown: const Duration(hours: 1)),
      );
      final out = await h.run();
      expect(out, isA<ServerUnavailable>());
      expect(h.loginCalls, 3); // 연속 3번까지만, 그 뒤로는 로그인 시도를 늘리지 않는다
    });

    test('대기 시간이 지나면 다시 한 번 로그인해 본다', () async {
      final bad = FakeApi(seatScript: [SessionException('계속 거부')]);
      final h = _Harness(
        api: bad,
        logins: [bad],
        policy: _fast(maxQuickRelogins: 1, giveUpAfter: const Duration(milliseconds: 300), reloginCooldown: const Duration(milliseconds: 40)),
      );
      await h.run();
      expect(h.loginCalls, greaterThan(2));
      expect(h.loginCalls, lessThan(20)); // 폭주하지 않는다
    });
  });

  group('예약 요청', () {
    test('연속으로 거절되면 사유와 함께 멈춘다', () async {
      final api = FakeApi(seatScript: [[_seat('1')]], reserveScript: [_no('이미 사용 중인 좌석이 있어요')]);
      final h = _Harness(api: api, policy: _fast(maxReserveFailures: 3));
      final out = await h.run();
      expect(out, isA<ReserveRejected>());
      expect((out as ReserveRejected).message, contains('이미 사용 중'));
      expect(api.reserveCalls, 3);
    });

    test('몇 번 거절당해도 그 뒤 성공하면 계속 예약한다', () async {
      final api = FakeApi(seatScript: [[_seat('1')]], reserveScript: [_no('누가 먼저 앉았어요'), _no('누가 먼저 앉았어요'), _ok]);
      final h = _Harness(api: api, policy: _fast(maxReserveFailures: 3));
      expect(await h.run(), isA<Reserved>());
      expect(api.reserveCalls, 3);
    });

    test('빈 좌석이 없던 바퀴가 있으면 거절 횟수는 처음부터 센다', () async {
      final free = [_seat('1')], busy = [_seat('1', free: false)];
      final api = FakeApi(
        seatScript: [free, free, busy, free, free, busy, free],
        reserveScript: [_no('거절'), _no('거절'), _no('거절'), _no('거절'), _ok],
      );
      final h = _Harness(api: api, policy: _fast(maxReserveFailures: 3));
      expect(await h.run(), isA<Reserved>()); // 연속이 아니라서 3번에 걸리지 않는다
    });

    test('예약 요청 중 연결이 끊기면 배정 여부를 홈페이지에서 확인하라고 알리고 이어간다', () async {
      final api = FakeApi(seatScript: [[_seat('1')]], reserveScript: [_net(), _ok]);
      final h = _Harness(api: api);
      expect(await h.run(), isA<Reserved>());
      expect(h.logs.any((l) => l.contains('홈페이지에서 확인')), isTrue);
    });
  });

  group('실행 환경', () {
    test('백그라운드 서비스가 사라지면 EnvironmentLost 로 끝난다', () async {
      final api = FakeApi(seatScript: [[_seat('1', free: false)]]);
      var n = 0;
      final h = _Harness(api: api, alive: () async => ++n < 4);
      expect(await h.run(), isA<EnvironmentLost>());
      expect(api.seatCalls, 3);
    });

    test('환경 확인 자체가 실패해도 예약은 계속한다', () async {
      final api = FakeApi(seatScript: [[_seat('1')]], reserveScript: [_ok]);
      final h = _Harness(api: api, alive: () async => throw StateError('플랫폼 오류'));
      expect(await h.run(), isA<Reserved>());
    });
  });

  group('이미 갖고 있는 좌석 바꾸기 (replaceExisting)', () {
    // 번호 1~3 중 [free] 만 비어 있는 좌석 목록.
    List<Seat> room({Set<String> free = const {}}) => [for (final c in ['1', '2', '3']) _seat(c, free: free.contains(c))];

    /// 사용자가 늘 [answer] 로 답하는 것으로 치고, 물어본 내용을 [asked] 에 쌓는다.
    ReplaceConfirm yes(List<(String, int)> asked, {bool answer = true}) => (held, rank) async {
          asked.add((held.seatCode, rank));
          return answer;
        };

    test('꺼져 있으면 내 좌석을 조회하지도 반납하지도 않는다 (기본값)', () async {
      final api = FakeApi(seatScript: [room(free: {'1'})], reserveScript: [_ok], heldScript: [[_held('7')]]);
      final h = _Harness(api: api);
      expect(await h.run(), isA<Reserved>());
      expect(api.heldCalls, 0);
      expect(api.calls, ['reserve:101']);
    });

    test('갖고 있는 좌석이 없으면 묻지도 반납하지도 않고 그냥 예약한다', () async {
      final asked = <(String, int)>[];
      final api = FakeApi(seatScript: [room(free: {'1'})], reserveScript: [_ok], heldScript: [<MyCharge>[]]);
      final h = _Harness(api: api, replace: true, confirm: yes(asked));
      expect(await h.run(), isA<Reserved>());
      expect(api.calls, ['reserve:101']);
      expect(asked, isEmpty); // "좌석을 잃을 수 있다"는 안내는 좌석이 있을 때만 의미가 있다
      expect(h.logs.any((l) => l.contains('갖고 있는 좌석이 없어요')), isTrue);
    });

    test('시작할 때 한 번 묻고, 허락하면 원하는 좌석이 날 때 내 좌석을 반납한 뒤 예약한다', () async {
      final asked = <(String, int)>[];
      final api = FakeApi(
        seatScript: [room(), room(), room(free: {'1'})],
        reserveScript: [_ok],
        heldScript: [[_held('7')]],
      );
      final h = _Harness(api: api, replace: true, confirm: yes(asked));
      final out = await h.run();
      expect((out as Reserved).seat.code, '1');
      expect(api.calls, ['cancel:900', 'reserve:101']); // 순서가 중요: 반납(확정 전이라 취소) → 예약
      expect(asked, [('7', -1)]); // 선택 목록에 없는 좌석이라 순서는 -1. 좌석이 날 때 다시 묻지 않는다
      expect(h.logs.any((l) => l.contains('7번 좌석을 반납하고 1번으로 바꿔요')), isTrue);
    });

    test('묻는 시점은 좌석을 조회하기 전이다 (거절하면 서버에 아무 것도 하지 않는다)', () async {
      final asked = <(String, int)>[];
      final api = FakeApi(seatScript: [room(free: {'1'})], reserveScript: [_ok], heldScript: [[_held('7')]]);
      final h = _Harness(api: api, replace: true, confirm: yes(asked, answer: false));
      expect(await h.run(), isA<Stopped>());
      expect(api.calls, isEmpty);
      expect(api.seatCalls, 0);
      expect(h.logs.any((l) => l.contains('좌석 바꾸기를 하지 않기로')), isTrue);
    });

    test('묻다가 오류가 나면 거절로 보고 좌석을 건드리지 않는다', () async {
      final api = FakeApi(seatScript: [room(free: {'1'})], reserveScript: [_ok], heldScript: [[_held('7')]]);
      final h = _Harness(api: api, replace: true, confirm: (a, b) async => throw StateError('화면이 없어요'));
      expect(await h.run(), isA<Stopped>());
      expect(api.calls, isEmpty);
    });

    test('물을 방법이 없으면(콜백 없음) 허락으로 본다', () async {
      final api = FakeApi(seatScript: [room(free: {'1'})], reserveScript: [_ok], heldScript: [[_held('7')]]);
      final h = _Harness(api: api, replace: true);
      expect(await h.run(), isA<Reserved>());
      expect(api.calls, ['cancel:900', 'reserve:101']);
    });

    test('선택 목록에 내 좌석이 있으면 그 순서를 알려 주며 묻는다', () async {
      final asked = <(String, int)>[];
      final api = FakeApi(seatScript: [room(free: {'1'})], reserveScript: [_ok], heldScript: [[_held('2')]]);
      final h = _Harness(api: api, replace: true, wanted: ['1', '2', '3'], confirm: yes(asked));
      expect(await h.run(), isA<Reserved>());
      expect(asked, [('2', 1)]); // 2번은 두 번째로 고른 좌석
    });

    test('이미 이용 중(확정)인 좌석도 허락하면 반납하고 바꾼다 (취소가 아니라 반납 요청)', () async {
      final api = FakeApi(seatScript: [room(free: {'1'})], reserveScript: [_ok], heldScript: [[_held('7', returnable: true)]]);
      final h = _Harness(api: api, replace: true, confirm: yes([]));
      expect(await h.run(), isA<Reserved>());
      expect(api.calls, ['return:900', 'reserve:101']);
    });

    test('좌석이 나지 않는 동안에는 내 좌석을 반납하지 않는다', () async {
      final api = FakeApi(seatScript: [room()], heldScript: [[_held('7')]]);
      final h = _Harness(api: api, replace: true, confirm: yes([]));
      final done = h.runner.run();
      while (h.statuses.length < 20) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      h.runner.stop();
      expect(await done, isA<Stopped>());
      expect(api.calls, isEmpty);
      expect(api.heldCalls, 1); // 시작할 때 한 번만 확인한다
    });

    test('이미 더 원하는 좌석이 있으면 덜 원하는 좌석으로는 바꾸지 않고, 더 원하는 좌석이 나면 바꾼다', () async {
      // 우선순위 1 > 2 > 3, 나는 2번을 갖고 있다. 처음엔 3번만 비어 있고(바꾸면 손해), 다음에 1번이 난다.
      final api = FakeApi(
        seatScript: [room(free: {'3'}), room(free: {'3'}), room(free: {'1', '3'})],
        reserveScript: [_ok],
        heldScript: [[_held('2')]],
      );
      final h = _Harness(api: api, replace: true, wanted: ['1', '2', '3']);
      final out = await h.run();
      expect((out as Reserved).seat.code, '1');
      expect(api.calls, ['cancel:900', 'reserve:101']); // 3번 때문에 반납한 적은 없다
      expect(h.logs.any((l) => l.contains('이미 더 원하는 2번 좌석이 있어서 3번으로 바꾸지 않아요')), isTrue);
    });

    test('가장 원하는 좌석을 이미 갖고 있으면 묻지도 건드리지도 않고 끝낸다', () async {
      final asked = <(String, int)>[];
      final api = FakeApi(seatScript: [room(free: {'1', '3'})], heldScript: [[_held('2')]]);
      final h = _Harness(api: api, replace: true, wanted: ['2', '1', '3'], confirm: yes(asked));
      final out = await h.run();
      expect(out, isA<KeepingSeat>());
      expect((out as KeepingSeat).held.seatCode, '2');
      expect(api.calls, isEmpty);
      expect(asked, isEmpty);
    });

    test('다른 열람실의 좌석은 번호가 같아도 우선순위로 치지 않고 바꾼다', () async {
      // 54호 열람실의 1번을 갖고 있고, 지금 보는 53호의 1번이 났다 → 같은 좌석이 아니다.
      final asked = <(String, int)>[];
      final api = FakeApi(seatScript: [room(free: {'1'})], reserveScript: [_ok], heldScript: [[_held('1', room: 54)]]);
      final h = _Harness(api: api, replace: true, confirm: yes(asked));
      expect(await h.run(), isA<Reserved>());
      expect(api.calls, ['cancel:900', 'reserve:101']);
      expect(asked, [('1', -1)]);
    });

    test('실행 도중 새로 생긴 내 좌석은 따로 물어보고, 거절하면 건드리지 않고 계속 지켜본다', () async {
      final asked = <(String, int)>[];
      final api = FakeApi(
        seatScript: [room(free: {'1'})],
        // 시작할 때는 좌석이 없었는데, 도중에 홈페이지에서 직접 7번을 예약한 상황
        heldScript: [<MyCharge>[], [_held('7')]],
      );
      final h = _Harness(api: api, replace: true, confirm: yes(asked, answer: false));
      final done = h.runner.run();
      while (h.statuses.length < 10) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      h.runner.stop();
      expect(await done, isA<Stopped>());
      expect(asked, [('7', -1)]); // 같은 좌석은 한 번만 묻는다
      expect(api.calls, isEmpty);
    });

    test('반납한 뒤 예약이 거절되면 원래 좌석을 다시 예약하고, 다시 시도할 때 또 묻지 않는다', () async {
      final asked = <(String, int)>[];
      final api = FakeApi(
        seatScript: [room(free: {'1'})],
        // 1) 새 좌석 거절 2) 원래 좌석 복구 성공 3) 다음 바퀴의 새 좌석 성공
        reserveScript: [_no('방금 다른 사람이 예약했어요'), _ok, _ok],
        heldScript: [[_held('7')]],
      );
      final h = _Harness(api: api, replace: true, confirm: yes(asked));
      expect(await h.run(), isA<Reserved>());
      expect(api.calls, ['cancel:900', 'reserve:101', 'reserve:107', 'cancel:900', 'reserve:101']);
      expect(h.logs.any((l) => l.contains('원래 7번 좌석을 다시 예약했어요')), isTrue);
      expect(asked, hasLength(1));
    });

    test('교체가 계속 실패하면 원래 좌석을 되찾은 채 멈춘다 (좌석을 계속 반납하지 않는다)', () async {
      final api = FakeApi(
        seatScript: [room(free: {'1'})],
        reserveScript: [_no('a'), _ok, _no('b'), _ok], // 거절, 복구, 거절, 복구
        heldScript: [[_held('7')]],
      );
      final h = _Harness(api: api, replace: true, policy: _fast(maxSwapAttempts: 2));
      final out = await h.run();
      expect(out, isA<ReplaceFailed>());
      expect((out as ReplaceFailed).restored, isTrue);
      expect(out.old.seatCode, '7');
      expect(out.wanted.code, '1');
      expect(api.cancelCalls, 2);
    });

    test('원래 좌석도 되찾지 못하면 곧바로 멈추고 알린다', () async {
      final api = FakeApi(
        seatScript: [room(free: {'1'})],
        reserveScript: [_no('거절'), _no('이미 다른 사람이 예약')],
        heldScript: [[_held('7')]],
      );
      final h = _Harness(api: api, replace: true);
      final out = await h.run();
      expect(out, isA<ReplaceFailed>());
      expect((out as ReplaceFailed).restored, isFalse);
      expect(api.calls, ['cancel:900', 'reserve:101', 'reserve:107']);
    });

    test('반납이 거절되면 예약하지 않고, 계속 거절되면 멈춘다', () async {
      final api = FakeApi(
        seatScript: [room(free: {'1'})],
        cancelScript: [_no('반납할 수 없는 상태')],
        heldScript: [[_held('7', returnable: true)]],
      );
      final h = _Harness(api: api, replace: true, policy: _fast(maxReserveFailures: 3));
      final out = await h.run();
      expect(out, isA<ReserveRejected>());
      expect(api.cancelCalls, 3);
      expect(api.reserveCalls, 0); // 반납이 안 됐는데 예약부터 하지 않는다
      expect(h.logs.any((l) => l.contains('기존 좌석 반납 실패')), isTrue);
    });

    test('반납 중 연결이 끊기면 예약하지 않고 다음 바퀴에서 내 좌석부터 다시 확인한다', () async {
      final api = FakeApi(
        seatScript: [room(free: {'1'})],
        cancelScript: [_net(), _ok],
        reserveScript: [_ok],
        heldScript: [[_held('7')]],
      );
      final h = _Harness(api: api, replace: true);
      expect(await h.run(), isA<Reserved>());
      expect(api.calls, ['cancel:900', 'cancel:900', 'reserve:101']);
    });

    test('반납이 끝난 뒤에는 중지를 눌러도 교체를 끝까지 마친다 (좌석을 잃은 채 멈추지 않는다)', () async {
      final api = FakeApi(seatScript: [room(free: {'1'})], reserveScript: [_ok], heldScript: [[_held('7')]])
        ..cancelGate = Completer<void>();
      final h = _Harness(api: api, replace: true);
      final done = h.runner.run();
      while (api.cancelCalls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      h.runner.stop(); // 반납 요청이 서버에서 처리되는 도중에 중지
      api.cancelGate!.complete();
      final out = await done.timeout(const Duration(seconds: 5));
      expect(out, isA<Reserved>());
      expect(api.calls, ['cancel:900', 'reserve:101']);
    });

    test('내 좌석 조회가 일시적으로 끊기면 반납하지 않고 재시도한다', () async {
      final api = FakeApi(
        seatScript: [room(free: {'1'})],
        reserveScript: [_ok],
        // 시작 점검은 성공, 교체 직전 조회는 한 번 연결이 끊긴 뒤 성공
        heldScript: [
          [_held('7')],
          _net(),
          [_held('7')],
        ],
      );
      final h = _Harness(api: api, replace: true);
      expect(await h.run(), isA<Reserved>());
      expect(api.calls, ['cancel:900', 'reserve:101']);
      expect(api.heldCalls, 3);
    });

    test('내 좌석 응답을 읽지 못해도 예약 자체는 막지 않는다 (바꾸지만 않는다)', () async {
      final api = FakeApi(
        seatScript: [room(free: {'1'})],
        reserveScript: [_ok],
        heldScript: [ApiException('예상하지 못한 응답 모양')],
      );
      final h = _Harness(api: api, replace: true, confirm: yes([]));
      expect(await h.run(), isA<Reserved>());
      expect(api.calls, ['reserve:101']); // 반납 없이 예약만
      expect(h.logs.any((l) => l.contains('내 좌석을 확인하지 못해')), isTrue);
    });
  });

  group('확인 간격 (곧 비는 좌석이 멀수록 뜸하게)', () {
    test('defaultPacing: 남은 시간이 많을수록 늘어나고, 사용자가 정한 간격보다 빨라지지는 않는다', () {
      const base = Duration(milliseconds: 1500);
      expect(defaultPacing(base, null), base); // 언제 빌지 모르면 가장 빠르게
      expect(defaultPacing(base, 0), base);
      expect(defaultPacing(base, 3), base); // 정말 얼마 안 남음
      expect(defaultPacing(base, 4), const Duration(seconds: 3));
      expect(defaultPacing(base, 10), const Duration(seconds: 3));
      expect(defaultPacing(base, 11), const Duration(seconds: 6));
      expect(defaultPacing(base, 30), const Duration(seconds: 6));
      expect(defaultPacing(base, 31), const Duration(seconds: 15));
      expect(defaultPacing(base, 60), const Duration(seconds: 15));
      expect(defaultPacing(base, 61), const Duration(seconds: 30));
      expect(defaultPacing(base, 240), const Duration(seconds: 30)); // 상한
      // 사용자가 간격을 길게 정했으면 그보다 짧아지지 않는다.
      expect(defaultPacing(const Duration(seconds: 20), 5), const Duration(seconds: 20));
      expect(defaultPacing(const Duration(seconds: 60), 120), const Duration(seconds: 60));
    });

    test('고른 좌석 중 가장 먼저 끝나는 좌석의 남은 시간으로 정한다', () async {
      final seen = <int?>[];
      final api = FakeApi(seatScript: [
        [_seat('1', free: false, remaining: 45), _seat('2', free: false, remaining: 12), _seat('3', free: false, remaining: 5)],
      ]);
      final h = _Harness(
        api: api,
        wanted: ['1', '2'], // 3번은 고르지 않았다
        policy: _fast(pacing: (b, m) {
          seen.add(m);
          return b;
        }),
      );
      final done = h.runner.run();
      while (h.statuses.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      h.runner.stop();
      await done;
      expect(seen.toSet(), {12}); // 고르지 않은 3번(5분)은 상관없다
    });

    test('빈 좌석이 있거나 언제 빌지 모르는 좌석이 있으면 가장 빠른 간격으로 확인한다 (늘리지 않는다)', () async {
      final seen = <int?>[];
      Duration track(Duration b, int? m) {
        seen.add(m);
        return b;
      }

      // 1번은 사용 중이지만 남은 시간을 모른다(0) → 늘리면 안 된다.
      final unknown = FakeApi(seatScript: [
        [_seat('1', free: false), _seat('2', free: false, remaining: 100)],
      ]);
      final h = _Harness(api: unknown, wanted: ['1', '2'], policy: _fast(pacing: track));
      final done = h.runner.run();
      while (h.statuses.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      h.runner.stop();
      await done;
      expect(seen, isEmpty); // 늘리는 규칙을 아예 묻지 않았다
    });

    test('고른 좌석이 비어 있는데 예약이 거절되는 동안에는 늘리지 않고 빠르게 다시 시도한다', () async {
      final seen = <int?>[];
      final api = FakeApi(
        seatScript: [
          [_seat('1'), _seat('2', free: false, remaining: 100)],
        ],
        reserveScript: [_no('거절')],
      );
      final h = _Harness(
        api: api,
        wanted: ['1', '2'],
        policy: _fast(maxReserveFailures: 5, pacing: (b, m) {
          seen.add(m);
          return b;
        }),
      );
      expect(await h.run(), isA<ReserveRejected>());
      expect(seen, isEmpty); // 빈 좌석이 있으니 늘리는 규칙을 아예 묻지 않았다
    });

    test('실제로 기다리는 시간이 늘어난다', () async {
      final api = FakeApi(seatScript: [
        [_seat('1', free: false, remaining: 100)],
      ]);
      final h = _Harness(api: api, policy: _fast(pacing: (a, b) => const Duration(milliseconds: 50)));
      final done = h.runner.run();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      h.runner.stop();
      await done;
      // 2ms 간격이었다면 100번이 넘게 확인했을 시간이다.
      expect(h.statuses.length, inInclusiveRange(3, 8));
    });

    test('내가 갖고 있는 좌석은 기다릴 대상이 아니다 (남은 시간이 짧아도 간격을 줄이지 않는다)', () async {
      final seen = <int?>[];
      // 우선순위 2번 > 1번. 내가 1번을 갖고 있고(5분 남음), 2번은 50분 남았다.
      final api = FakeApi(
        seatScript: [
          [_seat('1', free: false, remaining: 5), _seat('2', free: false, remaining: 50)],
        ],
        heldScript: [[_held('1')]],
      );
      final h = _Harness(
        api: api,
        wanted: ['2', '1'],
        replace: true,
        confirm: (a, b) async => true,
        policy: _fast(pacing: (b, m) {
          seen.add(m);
          return b;
        }),
      );
      final done = h.runner.run();
      while (h.statuses.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      h.runner.stop();
      await done;
      expect(seen.toSet(), {50});
      expect(h.statuses.first.soonest!.code, '2'); // 화면의 "가장 빨리 비는 좌석"에도 내 좌석은 나오지 않는다
    });
  });
}
