import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/reservation_runner.dart';
import 'package:lib_seat/seat_keeper.dart';

/// 도서관 서버를 흉내 낸다: 좌석 12개(번호 1~12), 내 좌석은 하나, 배정만 된 좌석은 기한이 지나면 서버가 풀어 버린다.
class _Sim implements LibraryApi {
  _Sim({
    this.window = const Duration(milliseconds: 150),
    this.confirmed = false,
    this.confirmedMinutes = 240,
    Set<String>? busy,
    this.held,
  }) : busy = busy ?? {};

  /// 예약하면 이 시간 안에 도서관에 들어가 확정해야 한다 (시험에서는 밀리초).
  final Duration window;

  /// 새로 예약한 좌석이 바로 이용 중(확정)인지.
  final bool confirmed;
  final int confirmedMinutes;

  /// 다른 사람이 쓰는 좌석 번호.
  final Set<String> busy;
  MyCharge? held;
  var nextId = 900;
  int heldCalls = 0, reserveCalls = 0, cancelCalls = 0;

  /// 앞으로 이만큼의 예약 요청은 거절한다.
  int rejectNext = 0;

  /// 예약은 처리하되 응답이 끊기는 횟수.
  int dropResponseNext = 0;

  /// 앞으로 이만큼의 내 좌석 조회는 연결 오류.
  int failHeld = 0;
  final reservedAt = <DateTime>[];
  final expiredAt = <DateTime>[];

  void _expire() {
    final h = held;
    if (h != null && !h.returnable && h.checkinExpiry != null && !DateTime.now().isBefore(h.checkinExpiry!)) {
      held = null;
      expiredAt.add(h.checkinExpiry!); // 서버가 좌석을 푼 실제 시각 (이 좌석을 조회하는 쪽이 알아챈 시각이 아니다)
    }
  }

  @override
  Future<List<Seat>> seats(int roomId) async {
    _expire();
    return [
      for (var i = 1; i <= 12; i++)
        Seat(
          id: 100 + i,
          code: '$i',
          active: true,
          occupied: busy.contains('$i') || held?.seatCode == '$i',
          remainingTime: busy.contains('$i') ? 120 : 0,
          chargeTime: busy.contains('$i') ? 240 : 0,
        ),
    ];
  }

  @override
  Future<Map<String, dynamic>> reserve(int seatId) async {
    _expire();
    reserveCalls++;
    final code = '${seatId - 100}';
    if (rejectNext > 0) {
      rejectNext--;
      return {'success': false, 'code': 'error.x', 'message': '지금은 예약할 수 없어요'};
    }
    if (held != null || busy.contains(code)) return {'success': false, 'code': 'error.taken', 'message': '이미 사용 중이에요'};
    held = MyCharge(
      id: ++nextId,
      seatId: seatId,
      seatCode: code,
      roomId: 53,
      roomName: '숭실스퀘어ON(2F)',
      returnable: confirmed,
      remainingMinutes: confirmed ? confirmedMinutes : 240,
      checkinExpiry: confirmed ? null : DateTime.now().add(window),
    );
    reservedAt.add(DateTime.now());
    if (dropResponseNext > 0) {
      dropResponseNext--;
      throw DioException.connectionTimeout(timeout: const Duration(seconds: 10), requestOptions: RequestOptions());
    }
    return {'success': true};
  }

  @override
  Future<List<MyCharge>> myCharges() async {
    heldCalls++;
    if (failHeld > 0) {
      failHeld--;
      throw DioException.connectionError(requestOptions: RequestOptions(), reason: 'offline');
    }
    _expire();
    return held == null ? const [] : [held!];
  }

  @override
  Future<Map<String, dynamic>> cancelCharge(int chargeId) async {
    cancelCalls++;
    if (held?.id == chargeId) held = null;
    return {'success': true};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MyCharge _seat(String code, {bool confirmed = false, Duration? expiresIn, int? remaining}) => MyCharge(
      id: 700 + int.parse(code),
      seatId: 100 + int.parse(code),
      seatCode: code,
      roomId: 53,
      roomName: '숭실스퀘어ON(2F)',
      returnable: confirmed,
      remainingMinutes: remaining ?? 240,
      checkinExpiry: expiresIn == null ? null : DateTime.now().add(expiresIn),
    );

Duration _same(Duration base, int? soonest) => base;

/// 시험에서 쓰는 아주 짧은 시간표.
KeepPolicy _fast({
  Duration unconfirmedPoll = const Duration(milliseconds: 40),
  Duration edgeLead = const Duration(milliseconds: 20),
  Duration edgePoll = const Duration(milliseconds: 5),
  Duration edgeGrace = const Duration(milliseconds: 60),
  Duration confirmedPoll = const Duration(milliseconds: 40),
  Duration rejectedWait = const Duration(milliseconds: 30),
  Duration troubleAfter = const Duration(seconds: 30),
  Duration assumed = const Duration(milliseconds: 100),
}) =>
    KeepPolicy(
      unconfirmedPoll: unconfirmedPoll,
      edgeLead: edgeLead,
      edgePoll: edgePoll,
      edgeGrace: edgeGrace,
      assumedCheckinWindow: assumed,
      confirmedPoll: confirmedPoll,
      afterEnd: const Duration(milliseconds: 2),
      afterReserve: const Duration(milliseconds: 2),
      minuteLength: const Duration(milliseconds: 10),
      minWait: const Duration(milliseconds: 2),
      rejectedWait: rejectedWait,
      errorBackoff: const Duration(milliseconds: 3),
      maxErrorBackoff: const Duration(milliseconds: 10),
      aliveEvery: const Duration(milliseconds: 15),
      troubleAfter: troubleAfter,
      reloginCooldown: const Duration(hours: 1),
    );

class _Harness {
  _Harness(
    this.api, {
    List<String> wanted = const ['1'],
    KeepPolicy? policy,
    DateTime? endAt,
    bool cancelAtEnd = true,
    Future<bool> Function()? alive,
    List<Object>? logins,
    int maxReserveFailures = 3,
    LibraryApi? initialApi,
  }) {
    final queue = List<Object>.of(logins ?? const []);
    keeper = SeatKeeper(
      roomId: 53,
      wanted: wanted,
      runPolicy: RunPolicy(
        interval: const Duration(milliseconds: 2),
        maxBackoff: const Duration(milliseconds: 8),
        giveUpAfter: const Duration(seconds: 5),
        maxReserveFailures: maxReserveFailures,
        pacing: _same,
      ),
      policy: policy ?? _fast(),
      api: initialApi ?? (queue.isEmpty ? api : null),
      login: () async {
        loginCalls++;
        if (queue.isEmpty) return api;
        final v = queue.length > 1 ? queue.removeAt(0) : queue.first;
        if (v is Exception) throw v;
        return v as LibraryApi;
      },
      onLog: logs.add,
      onStatus: statuses.add,
      onEvent: events.add,
      endAt: endAt,
      cancelAtEnd: cancelAtEnd,
      isEnvironmentAlive: alive,
      onSeatChanged: () => seatChanges++,
    );
  }

  final _Sim api;
  late final SeatKeeper keeper;
  final logs = <String>[];
  final statuses = <KeepStatus>[];
  final events = <KeepEvent>[];
  int loginCalls = 0, seatChanges = 0;

  Future<KeepOutcome> run() => keeper.run().timeout(const Duration(seconds: 10));
}

Future<void> _until(bool Function() test, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('시간 안에 조건이 이뤄지지 않았어요');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  group('좌석 잡기와 다시 잡기', () {
    test('좌석이 없으면 우선순위가 높은 빈 좌석을 예약하고, 좌석이 사라지면 다시 예약한다', () async {
      final api = _Sim(window: const Duration(seconds: 30), busy: {'3'});
      final h = _Harness(api, wanted: ['3', '2', '1']);
      final run = h.run();
      await _until(() => api.reserveCalls == 1);
      await _until(() => api.held != null);
      expect(api.held!.seatCode, '2'); // 3번은 사용 중이라 다음 우선순위인 2번

      api.held = null; // 도서관이 취소했다 (또는 다른 이유로 사라졌다)
      await _until(() => api.reserveCalls == 2 && api.held != null);
      expect(api.held!.seatCode, '2');

      h.keeper.stop();
      final out = await run;
      expect(out.reason, KeepEndReason.stopped);
      expect(out.reserved, 2);
      expect(out.lost, 1);
      expect(h.seatChanges, 2); // 자동 연장이 새 좌석을 보도록 알렸다
      expect(h.events.map((e) => e.kind), containsAllInOrder([KeepEventKind.reserved, KeepEventKind.lost, KeepEventKind.reserved]));
      expect(api.cancelCalls, 0); // 사용자가 멈춰도 좌석은 건드리지 않는다
    });

    test('도서관에 들어가지 않아 배정이 풀려도, 풀리는 순간(기한 앞뒤로 자주 보다가) 바로 다시 예약한다', () async {
      // 배정 기한 150ms. 평소에는 200ms 마다 보지만 기한 40ms 전부터는 5ms 마다 본다.
      final api = _Sim(window: const Duration(milliseconds: 150));
      final h = _Harness(api, policy: _fast(unconfirmedPoll: const Duration(milliseconds: 200), edgeLead: const Duration(milliseconds: 40)));
      final run = h.run();
      await _until(() => api.reservedAt.length >= 4, ms: 4000);
      h.keeper.stop();
      final out = await run;

      expect(out.reserved, greaterThanOrEqualTo(4));
      expect(out.lost, greaterThanOrEqualTo(3));
      // 풀린 시각과 다시 예약한 시각의 차이가 평소 간격(200ms)보다 한참 짧아야 한다 (그 사이에 다른 사람이 앉지 못하게)
      for (var i = 0; i < 3; i++) {
        final gap = api.reservedAt[i + 1].difference(api.expiredAt[i]);
        expect(gap, lessThan(const Duration(milliseconds: 100)), reason: '${i + 1}번째 재예약이 늦었어요: $gap');
      }
    });

    test('서버가 기한을 알려 주지 않아도 좌석을 처음 본 때부터 짐작한 기한에 맞춰 다시 예약한다', () async {
      final api = _Sim(window: const Duration(milliseconds: 100));
      // 이 서버는 기한을 알려 주지 않는다 (checkinExpiry 없음). 대신 100ms 뒤에 좌석이 풀린다.
      final noExpiry = _NoExpirySim(api);
      final h = _Harness(api, initialApi: noExpiry, policy: _fast(unconfirmedPoll: const Duration(milliseconds: 200), assumed: const Duration(milliseconds: 100)));
      final run = h.run();
      await _until(() => api.reservedAt.length >= 3, ms: 4000);
      h.keeper.stop();
      await run;
      final gap = api.reservedAt[1].difference(api.expiredAt[0]);
      expect(gap, lessThan(const Duration(milliseconds: 100)), reason: '짐작한 기한 앞뒤로 자주 보지 않았어요: $gap');
    });

    test('이용 중(확정)인 좌석은 끝날 때쯤까지 다시 조회하지 않고, 끝나면 다시 예약한다', () async {
      // 남은 30분 (시험에서 1분=10ms 라서 300ms). 그동안 내 좌석을 다시 조회하지 않는다.
      final api = _Sim(held: _seat('5', confirmed: true, remaining: 30), window: const Duration(seconds: 30), confirmed: true, confirmedMinutes: 600);
      final h = _Harness(api, wanted: ['5']);
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(api.heldCalls, 1, reason: '끝나기 전에는 다시 조회하지 않는다');
      expect(api.reserveCalls, 0);

      api.held = null; // 이용 시간이 끝났다
      await _until(() => api.reserveCalls == 1, ms: 2000); // 끝날 시각(300ms)이 되면 알아채고 다시 예약한다
      h.keeper.stop();
      final out = await run;
      expect(out.reserved, 1);
      expect(out.lost, 1);
    });

    test('이미 좌석을 갖고 시작하면 예약하지 않고 그 좌석을 지켜본다', () async {
      final api = _Sim(held: _seat('7', expiresIn: const Duration(seconds: 30)), window: const Duration(seconds: 30));
      final h = _Harness(api, wanted: ['1']);
      final run = h.run();
      await _until(() => h.statuses.any((s) => s.phase == KeepPhase.holding));
      expect(api.reserveCalls, 0);
      expect(h.statuses.last.held!.seatCode, '7');
      h.keeper.stop();
      expect((await run).reason, KeepEndReason.stopped);
    });
  });

  group('끝내기', () {
    test('종료 시각이 되면 멈추고, 배정만 된 좌석은 취소한다', () async {
      final api = _Sim(window: const Duration(seconds: 30));
      final h = _Harness(api, endAt: DateTime.now().add(const Duration(milliseconds: 150)));
      final out = await h.run();
      expect(out.reason, KeepEndReason.timeUp);
      expect(out.cancelledAtEnd, isTrue);
      expect(api.cancelCalls, 1);
      expect(api.held, isNull);
      expect(out.reserved, 1);
    });

    test('종료 시각에 이용 중인 좌석은 취소하지 않는다', () async {
      final api = _Sim(window: const Duration(seconds: 30), confirmed: true, confirmedMinutes: 600);
      final h = _Harness(api, endAt: DateTime.now().add(const Duration(milliseconds: 120)));
      final out = await h.run();
      expect(out.reason, KeepEndReason.timeUp);
      expect(out.cancelledAtEnd, isFalse);
      expect(api.cancelCalls, 0);
      expect(api.held, isNotNull);
    });

    test('"끝나면 취소" 를 끄면 배정만 된 좌석도 그대로 둔다', () async {
      final api = _Sim(window: const Duration(seconds: 30));
      final h = _Harness(api, endAt: DateTime.now().add(const Duration(milliseconds: 120)), cancelAtEnd: false);
      final out = await h.run();
      expect(out.reason, KeepEndReason.timeUp);
      expect(api.cancelCalls, 0);
      expect(api.held, isNotNull);
    });

    test('빈 좌석이 하나도 없어서 기다리는 중이어도 종료 시각에 끝난다', () async {
      final api = _Sim(busy: {'1'});
      final h = _Harness(api, endAt: DateTime.now().add(const Duration(milliseconds: 100)));
      final out = await h.run();
      expect(out.reason, KeepEndReason.timeUp);
      expect(api.reserveCalls, 0);
    });

    test('이미 지난 종료 시각이면 예약하지 않고 바로 끝난다', () async {
      final api = _Sim();
      final h = _Harness(api, endAt: DateTime.now().subtract(const Duration(seconds: 1)));
      final out = await h.run();
      expect(out.reason, KeepEndReason.timeUp);
      expect(api.reserveCalls, 0);
    });

    test('멈추면 빈 좌석을 기다리는 중이어도 바로 끝난다', () async {
      final api = _Sim(busy: {'1'});
      final h = _Harness(api);
      final run = h.run();
      await _until(() => h.statuses.any((s) => s.phase == KeepPhase.acquiring));
      h.keeper.stop();
      expect((await run).reason, KeepEndReason.stopped);
    });

    test('한 인스턴스는 한 번만 실행할 수 있다', () async {
      final api = _Sim();
      final h = _Harness(api, endAt: DateTime.now().subtract(const Duration(seconds: 1)));
      await h.run();
      expect(() => h.keeper.run(), throwsStateError);
    });

    test('백그라운드 서비스가 끝났으면 멈춘다 (쉬는 동안에도 확인한다)', () async {
      final api = _Sim(held: _seat('5', confirmed: true, remaining: 3000), confirmed: true);
      var checks = 0;
      final h = _Harness(api, wanted: ['5'], alive: () async => ++checks <= 3);
      final out = await h.run();
      expect(out.reason, KeepEndReason.environmentLost);
      expect(api.heldCalls, 1); // 서버에는 묻지 않고 기기에서 알아냈다
    });
  });

  group('끈질기게 계속하기', () {
    test('예약이 계속 거절돼도 포기하지 않고, 한 번 알린 뒤 다시 시도해 잡는다', () async {
      final api = _Sim(window: const Duration(seconds: 30))..rejectNext = 5;
      final h = _Harness(api, maxReserveFailures: 3);
      final run = h.run();
      await _until(() => api.held != null);
      h.keeper.stop();
      final out = await run;
      expect(out.reserved, 1);
      expect(api.reserveCalls, 6); // 거절 5번 뒤 성공
      expect(h.events.where((e) => e.kind == KeepEventKind.trouble), hasLength(1)); // 문제는 한 번만 알린다
      expect(h.logs.any((l) => l.contains('예약이 계속 거절돼요')), isTrue);
    });

    test('서버 오류가 이어져도 포기하지 않고 돌아오면 이어서 한다', () async {
      final api = _Sim(window: const Duration(seconds: 30))..failHeld = 12;
      final h = _Harness(api);
      final run = h.run();
      await _until(() => api.held != null);
      h.keeper.stop();
      final out = await run;
      expect(out.reserved, 1);
      expect(h.statuses.any((s) => s.phase == KeepPhase.troubled && s.trouble.contains('서버 응답')), isTrue);
      expect(h.logs.any((l) => l.contains('서버 연결이 돌아왔어요')), isTrue);
    });

    test('예약 응답만 끊기고 실제로는 배정됐으면, 또 예약하지 않고 그 좌석을 지켜본다', () async {
      final api = _Sim(window: const Duration(seconds: 30))..dropResponseNext = 1;
      final h = _Harness(api);
      final run = h.run();
      await _until(() => h.statuses.any((s) => s.phase == KeepPhase.holding));
      expect(api.reserveCalls, 1);
      h.keeper.stop();
      expect((await run).reserved, 1);
    });

    test('좌석을 오래 다시 잡지 못하면 한 번 알린다', () async {
      final api = _Sim(busy: {'1'});
      final h = _Harness(api, policy: _fast(troubleAfter: const Duration(milliseconds: 40)));
      final run = h.run();
      await _until(() => h.events.any((e) => e.kind == KeepEventKind.trouble));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      h.keeper.stop();
      await run;
      expect(h.events.where((e) => e.kind == KeepEventKind.trouble), hasLength(1));
    });

    test('다른 사람이 앉아 있다가 비면 그때 잡는다', () async {
      final api = _Sim(window: const Duration(seconds: 30), busy: {'1'});
      final h = _Harness(api);
      final run = h.run();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(api.reserveCalls, 0);
      api.busy.clear(); // 1번이 비었다
      await _until(() => api.held?.seatCode == '1');
      h.keeper.stop();
      expect((await run).reserved, 1);
    });
  });

  group('로그인', () {
    test('학번/비밀번호가 거절되면 재시도 없이 멈춘다 (계정 잠금 방지)', () async {
      final api = _Sim();
      final h = _Harness(api, logins: [LoginException('error.bad 비밀번호가 틀려요')]);
      final out = await h.run();
      expect(out.reason, KeepEndReason.loginRejected);
      expect(out.message, contains('비밀번호'));
      expect(h.loginCalls, 1);
    });

    test('세션이 풀리면 다시 로그인하고 이어서 한다', () async {
      final api = _Sim(window: const Duration(seconds: 30));
      final h = _Harness(api, logins: [api], initialApi: _ExpiresOnce(api));
      final run = h.run();
      await _until(() => api.held != null);
      h.keeper.stop();
      await run;
      expect(h.loginCalls, greaterThanOrEqualTo(1));
    });
  });

  test('상태에 지금 좌석, 예약 횟수, 최근 한 일이 실린다', () async {
    final api = _Sim(window: const Duration(seconds: 30));
    final h = _Harness(api, endAt: DateTime.now().add(const Duration(seconds: 5)));
    final run = h.run();
    await _until(() => h.statuses.any((s) => s.phase == KeepPhase.holding));
    final s = h.statuses.lastWhere((s) => s.phase == KeepPhase.holding);
    expect(s.held!.seatCode, '1');
    expect(s.reserved, 1);
    expect(s.endAt, isNotNull);
    expect(s.recent.first, contains('1번 좌석을 예약했어요'));
    h.keeper.stop();
    await run;
  });
}

/// 좌석을 알려 주면서 기한은 알려 주지 않는 서버.
class _NoExpirySim implements LibraryApi {
  _NoExpirySim(this.inner);
  final _Sim inner;

  @override
  Future<List<MyCharge>> myCharges() async {
    final list = await inner.myCharges();
    return [
      for (final c in list)
        MyCharge(
          id: c.id,
          seatId: c.seatId,
          seatCode: c.seatCode,
          roomId: c.roomId,
          roomName: c.roomName,
          returnable: c.returnable,
          remainingMinutes: c.remainingMinutes,
        ),
    ];
  }

  @override
  Future<List<Seat>> seats(int roomId) => inner.seats(roomId);

  @override
  Future<Map<String, dynamic>> reserve(int seatId) => inner.reserve(seatId);

  @override
  Future<Map<String, dynamic>> cancelCharge(int chargeId) => inner.cancelCharge(chargeId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 처음 한 번은 "로그인이 풀렸다"고 답하는 서버.
class _ExpiresOnce implements LibraryApi {
  _ExpiresOnce(this.inner);
  final _Sim inner;
  var _first = true;

  @override
  Future<List<MyCharge>> myCharges() async {
    if (_first) {
      _first = false;
      throw SessionException('error.authentication.needLogin');
    }
    return inner.myCharges();
  }

  @override
  Future<List<Seat>> seats(int roomId) => inner.seats(roomId);

  @override
  Future<Map<String, dynamic>> reserve(int seatId) => inner.reserve(seatId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
