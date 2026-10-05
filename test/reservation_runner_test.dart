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
  FakeApi({this.seatScript = const [], this.reserveScript = const []});
  final List<Object> seatScript;
  final List<Object> reserveScript;
  int seatCalls = 0, reserveCalls = 0;
  Completer<void>? seatGate; // 있으면 seats() 가 여기서 기다린다 (조회 도중 중지 시험용)

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
    final v = _next(reserveScript, i);
    if (v is Exception || v is Error) throw v;
    return v as Map<String, dynamic>;
  }

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
}) =>
    RunPolicy(
      interval: const Duration(milliseconds: 2),
      maxBackoff: const Duration(milliseconds: 8),
      giveUpAfter: giveUpAfter,
      maxQuickRelogins: maxQuickRelogins,
      reloginCooldown: reloginCooldown,
      maxReserveFailures: maxReserveFailures,
    );

class _Harness {
  _Harness({
    this.api,
    List<Object>? logins,
    RunPolicy? policy,
    List<String> wanted = const ['1'],
    Future<bool> Function()? alive,
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
}
