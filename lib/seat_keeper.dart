import 'dart:async';

import 'package:dio/dio.dart';

import 'api.dart';
import 'reservation_runner.dart';

// 좌석 유지 루프. 사용자가 멈출 때까지(또는 정한 종료 시각까지) 좌석을 하나 계속 갖고 있으려고 한다.
// Flutter 에 의존하지 않는 순수 Dart 라서 가짜 서버로 시험할 수 있다.
//
// 하는 일
//  - 내 좌석을 조회해서 없으면 [ReservationRunner] 로 고른 좌석 중 비어 있는 좌석을 예약한다 (우선순위 순).
//    예약이 취소됐거나, 도서관에 들어가지 않아 배정이 풀렸거나, 이용 시간이 끝나서 좌석이 없어졌을 때도 똑같이 다시 예약한다.
//  - 좌석이 있으면 필요할 때만 다시 본다:
//      · 이용 중(확정)인 좌석은 끝날 때쯤 한 번 (그 전의 연장은 자동 연장 [SeatRenewer] 가 맡는다)
//      · 배정만 된 좌석은 [KeepPolicy.unconfirmedPoll] 마다, 배정확정 기한 앞뒤로는 [KeepPolicy.edgePoll] 마다 본다.
//        기한이 지나 배정이 풀리는 순간 바로 다시 잡으려는 것이다 (그 사이에 다른 사람이 앉지 않게).
//  - 종료 시각([SeatKeeper.endAt])이 되면 멈춘다. [SeatKeeper.cancelAtEnd] 이면 배정만 된 좌석은 취소하고 마친다 (이용 중인 좌석은 그대로 둔다).
//  - 학번/비밀번호가 거절되면 재시도 없이 멈춘다 (여러 번 틀리면 계정이 잠긴다). 서버 오류나 예약 거절은 포기하지 않고 계속 다시 시도한다.
//  - 한 인스턴스는 한 번만 실행된다. 중지는 대기 중에도 즉시 먹는다.

/// 좌석 유지 시간표.
class KeepPolicy {
  const KeepPolicy({
    this.unconfirmedPoll = const Duration(minutes: 1),
    this.edgeLead = const Duration(seconds: 10),
    this.edgePoll = const Duration(seconds: 2),
    this.edgeGrace = const Duration(minutes: 3),
    this.assumedCheckinWindow = const Duration(minutes: 30),
    this.confirmedPoll = const Duration(minutes: 5),
    this.afterEnd = const Duration(seconds: 5),
    this.afterReserve = const Duration(seconds: 2),
    this.minuteLength = const Duration(minutes: 1),
    this.minWait = const Duration(milliseconds: 500),
    this.rejectedWait = const Duration(minutes: 1),
    this.errorBackoff = const Duration(seconds: 15),
    this.maxErrorBackoff = const Duration(minutes: 1),
    this.aliveEvery = const Duration(minutes: 15),
    this.troubleAfter = const Duration(minutes: 1),
    this.maxQuickRelogins = 3,
    this.reloginCooldown = const Duration(minutes: 5),
  });

  /// 배정만 된 좌석을 다시 보는 간격 (배정확정 기한이 아직 멀 때).
  final Duration unconfirmedPoll;

  /// 배정확정 기한 [edgeLead] 전부터 [edgeGrace] 뒤까지는 [edgePoll] 마다 본다 (배정이 풀리는 순간을 놓치지 않으려고).
  final Duration edgeLead, edgePoll, edgeGrace;

  /// 서버가 기한을 알려 주지 않을 때, 이 좌석을 처음 본 시각에 이만큼을 더한 때를 기한으로 본다.
  final Duration assumedCheckinWindow;

  /// 이용 중인 좌석의 남은 시간을 모를 때 다시 보는 간격.
  final Duration confirmedPoll;

  /// 이용 중인 좌석은 끝나는 시각 + 이만큼 뒤에 다시 본다.
  final Duration afterEnd;

  /// 예약에 성공한 뒤 내 좌석을 다시 읽기까지 (방금 예약한 좌석이 목록에 늦게 뜰 수 있다).
  final Duration afterReserve;

  /// 서버가 말하는 "남은 시간 1분"의 실제 길이. 실제 앱은 1분이고 시험에서만 줄인다.
  final Duration minuteLength;

  /// 어떤 대기도 이보다 짧지는 않다 (서버를 연달아 두드리지 않게).
  final Duration minWait;

  /// 예약이 계속 거절된 뒤 다시 시도하기까지.
  final Duration rejectedWait;

  /// 서버 조회 오류가 이어질 때 간격(2배씩 늘어 상한까지).
  final Duration errorBackoff, maxErrorBackoff;

  /// 오래 쉬는 동안 백그라운드 서비스가 살아 있는지 기기에서 확인하는 간격.
  final Duration aliveEvery;

  /// 좌석이 없는 채로 이만큼 지나면 "다시 잡지 못하고 있다"고 알린다.
  final Duration troubleAfter;

  /// 다시 로그인을 연달아 해 볼 수 있는 횟수. 넘으면 [reloginCooldown] 마다 한 번만 시도한다.
  final int maxQuickRelogins;
  final Duration reloginCooldown;
}

/// 좌석 유지가 끝난 이유.
enum KeepEndReason {
  /// 사용자가 멈췄다.
  stopped,

  /// 정한 종료 시각이 됐다.
  timeUp,

  /// 학번/비밀번호가 거절됐다.
  loginRejected,

  /// 백그라운드 서비스가 끝났다.
  environmentLost,

  /// 예상하지 못한 오류.
  crashed,
}

class KeepOutcome {
  const KeepOutcome(
    this.reason, {
    this.message = '',
    this.reserved = 0,
    this.lost = 0,
    this.cancelledAtEnd = false,
    this.error,
  });

  final KeepEndReason reason;
  final String message;

  /// 이번 실행에서 예약에 성공한 횟수와, 좌석이 사라진 횟수.
  final int reserved, lost;

  /// 종료 시각이 돼서 배정만 된 좌석을 취소하고 마쳤는지.
  final bool cancelledAtEnd;
  final Object? error;
}

enum KeepPhase {
  /// 좌석이 있고 지켜보는 중.
  holding,

  /// 좌석이 없어서 다시 예약하려는 중.
  acquiring,

  /// 서버 오류나 예약 거절이 이어지는 중 (계속 다시 시도한다).
  troubled,
}

/// 화면에 넘기는 지금 상태.
class KeepStatus {
  const KeepStatus({
    required this.phase,
    required this.checkedAt,
    this.held,
    this.reserved = 0,
    this.lost = 0,
    this.endAt,
    this.hunt,
    this.trouble = '',
    this.recent = const [],
  });

  final KeepPhase phase;
  final DateTime checkedAt;

  /// 지금 갖고 있는 좌석 (없으면 null).
  final MyCharge? held;
  final int reserved, lost;
  final DateTime? endAt;

  /// 좌석을 다시 예약하는 중일 때 마지막 조회 상태.
  final RunStatus? hunt;

  /// 지금 겪는 문제 (예약 거절 이유, 서버 오류). 없으면 빈 문자열.
  final String trouble;

  /// 최근에 한 일 (최신이 앞, 시각 포함).
  final List<String> recent;
}

enum KeepEventKind {
  /// 좌석을 (다시) 예약했다.
  reserved,

  /// 갖고 있던 좌석이 사라졌다.
  lost,

  /// 좌석을 다시 잡지 못하고 있다 (오래 없거나 예약이 계속 거절된다). 한 번 알린 뒤 좌석을 다시 잡으면 또 알릴 수 있다.
  trouble,
}

class KeepEvent {
  const KeepEvent(this.kind, this.message, {this.seatCode = '', this.count = 0});

  final KeepEventKind kind;
  final String message;
  final String seatCode;

  /// 이번 실행에서 예약에 성공한 횟수.
  final int count;
}

class SeatKeeper {
  SeatKeeper({
    required this.roomId,
    required this.wanted,
    required this.runPolicy,
    required this.login,
    required this.onLog,
    required this.onStatus,
    required this.onEvent,
    this.policy = const KeepPolicy(),
    this.api,
    this.endAt,
    this.cancelAtEnd = true,
    this.isEnvironmentAlive,
    this.onSeatChanged,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int roomId;

  /// 우선순위 순서의 좌석 번호.
  final List<String> wanted;

  /// 좌석을 다시 예약할 때 쓰는 예약 루프의 확인 간격 정책.
  final RunPolicy runPolicy;
  final KeepPolicy policy;

  /// 새로 로그인한 API 를 돌려준다. 로그인 거절은 [LoginException], 서버 문제는 그 밖의 예외.
  final LoginFn login;
  final void Function(String) onLog;
  final void Function(KeepStatus) onStatus;
  final void Function(KeepEvent) onEvent;

  /// 이미 로그인된 API (없으면 시작할 때 [login] 을 부른다).
  final LibraryApi? api;

  /// 이 시각이 되면 멈춘다. null 이면 사용자가 멈출 때까지.
  final DateTime? endAt;

  /// 종료 시각이 돼서 마칠 때 배정만 된(이용 시작 전) 좌석이면 취소한다. 이용 중인 좌석은 그대로 둔다.
  final bool cancelAtEnd;

  /// 백그라운드 서비스 같은 실행 환경이 살아 있는지. false 면 [KeepEndReason.environmentLost] 로 끝낸다.
  final Future<bool> Function()? isEnvironmentAlive;

  /// 새 좌석을 예약했을 때 불린다 (자동 연장이 새 좌석을 바로 보게 깨우려는 용도).
  final void Function()? onSeatChanged;
  final DateTime Function() _now;

  bool _started = false;
  bool _stopped = false;
  bool _timeUp = false;
  void Function()? _wake;
  Timer? _endTimer;
  ReservationRunner? _hunter;

  var _reserved = 0, _lost = 0;
  bool _hadSeat = false; // 이번 실행에서 좌석을 본 적이 있는지 (사라졌는지 알아내려고)
  DateTime? _lostAt;
  bool _troubleNotified = false;
  String _trouble = '';
  MyCharge? _held;
  RunStatus? _hunt;
  final _recent = <String>[];
  final _firstSeen = <int, DateTime>{}; // 예약 번호 → 이 좌석을 처음 본 시각 (기한을 모를 때 짐작에 쓴다)

  bool get isStopped => _stopped;

  /// 멈추라고 요청한다. 대기 중이면 바로 깨운다. 여러 번 불러도 된다.
  void stop() {
    _stopped = true;
    _hunter?.stop();
    _wake?.call();
  }

  /// 루프를 돌린다. 끝날 때까지 기다리면 끝난 이유가 나온다. 한 인스턴스에 한 번만 부를 수 있다.
  Future<KeepOutcome> run() async {
    if (_started) throw StateError('SeatKeeper 는 한 번만 실행할 수 있어요.');
    _started = true;
    final end = endAt;
    if (end != null) {
      final left = end.difference(_now());
      _endTimer = Timer(left.isNegative ? Duration.zero : left, () {
        _timeUp = true;
        _hunter?.stop();
        _wake?.call();
      });
    }
    try {
      return await _loop();
    } on LoginException catch (e) {
      return _end(KeepEndReason.loginRejected, message: e.message);
    } catch (e) {
      return _end(KeepEndReason.crashed, message: '$e', error: e);
    } finally {
      _endTimer?.cancel();
    }
  }

  KeepOutcome _end(KeepEndReason reason, {String message = '', bool cancelled = false, Object? error}) => KeepOutcome(
        reason,
        message: message,
        reserved: _reserved,
        lost: _lost,
        cancelledAtEnd: cancelled,
        error: error,
      );

  bool get _passedEnd => endAt != null && !_now().isBefore(endAt!);

  Future<KeepOutcome> _loop() async {
    var session = api; // null 이면 아래 루프 안에서 로그인한다 (일시적인 네트워크 오류도 재시도할 수 있게)
    var errorStreak = 0, reloginStreak = 0;
    DateTime? lastReloginAt;
    onLog('좌석 유지를 시작해요: 좌석 ${wanted.join(', ')}${endAt == null ? '' : ' · ${_clock(endAt!)}까지'}');

    while (true) {
      if (_stopped) return _end(KeepEndReason.stopped);
      if (_timeUp || _passedEnd) return await _finishTimeUp(session);
      if (!await _alive()) return _end(KeepEndReason.environmentLost);

      var wait = policy.unconfirmedPoll;
      String? failure;
      try {
        session ??= await login();
        final mine = await session.myCharges();
        if (errorStreak > 0) onLog('서버 연결이 돌아왔어요 (좌석 유지, $errorStreak번 실패 후)');
        errorStreak = 0;
        if (mine.isEmpty) {
          _noteLost();
          final r = await _acquire(session);
          if (r.end != null) return r.end!;
          wait = r.wait;
        } else {
          wait = _hold(mine.first);
        }
        reloginStreak = 0;
      } on SessionException catch (e) {
        final canRelogin = reloginStreak < policy.maxQuickRelogins ||
            lastReloginAt == null ||
            _now().difference(lastReloginAt) >= policy.reloginCooldown;
        if (canRelogin) {
          reloginStreak++;
          lastReloginAt = _now();
          onLog('로그인이 풀린 것 같아 다시 로그인합니다 (좌석 유지: ${e.message})');
          session = null; // 다음 바퀴 맨 앞에서 로그인한다. 거절(LoginException)이면 곧바로 멈춘다
          continue;
        }
        failure = e.message; // 다시 로그인해도 소용없는 상태: 서버 문제로 보고 기다린다
      } on LoginException {
        rethrow;
      } catch (e) {
        if (!_isTransient(e)) rethrow;
        failure = _describe(e);
      }

      if (failure != null) {
        errorStreak++;
        if (errorStreak == 1 || errorStreak % 10 == 0) {
          onLog('서버 응답 오류 (좌석 유지, $errorStreak번째): $failure. 잠시 뒤 다시 시도해요');
        }
        _trouble = '서버 응답이 불안정해요 ($failure)';
        _publish(KeepPhase.troubled);
        wait = _backoff(errorStreak);
      }
      if (!await _sleepLong(wait)) return _end(KeepEndReason.environmentLost);
    }
  }

  /// 종료 시각이 됐다. 배정만 된 좌석은 취소하고(설정에 따라) 마친다.
  Future<KeepOutcome> _finishTimeUp(LibraryApi? session) async {
    var cancelled = false;
    if (cancelAtEnd && session != null) {
      try {
        final mine = await session.myCharges();
        final held = mine.isEmpty ? null : mine.first;
        if (held != null && !held.returnable) {
          final res = await session.cancelCharge(held.id);
          cancelled = res['success'] == true;
          onLog(cancelled
              ? '종료 시각이라 배정만 된 ${held.seatCode}번 좌석을 취소했어요'
              : '종료 시각에 ${held.seatCode}번 좌석 취소가 거절됐어요: ${res['code'] ?? ''} ${res['message'] ?? ''}'.trim());
        }
      } catch (e) {
        onLog('종료 시각에 좌석을 정리하지 못했어요: ${_describe(e)}');
      }
    }
    return _end(KeepEndReason.timeUp, cancelled: cancelled);
  }

  /// 좌석이 없다. 있던 좌석이 사라진 것이면 기록한다.
  void _noteLost() {
    _held = null;
    if (_hadSeat) {
      _hadSeat = false;
      _lost++;
      _lostAt = _now();
      _addRecent('좌석이 사라졌어요. 다시 예약해요');
      onLog('좌석이 사라졌어요 (이번 실행 $_lost번째). 다시 예약해요');
      onEvent(KeepEvent(KeepEventKind.lost, '갖고 있던 좌석이 사라졌어요. 다시 예약하는 중이에요.', count: _reserved));
    }
    _lostAt ??= _now();
  }

  /// 좌석을 갖고 있다. 다음에 다시 볼 때까지 기다릴 시간을 돌려준다.
  Duration _hold(MyCharge held) {
    _hadSeat = true;
    _lostAt = null;
    _troubleNotified = false;
    _trouble = '';
    _held = held;
    final now = _now();
    _firstSeen.putIfAbsent(held.id, () => now);
    if (_firstSeen.length > 20) _firstSeen.remove(_firstSeen.keys.first);
    _publish(KeepPhase.holding);

    if (held.returnable) {
      // 이용 중이다. 연장은 자동 연장이 하고, 우리는 이 좌석이 끝날 때쯤 한 번 다시 본다.
      final rem = held.remainingMinutes;
      if (rem == null) return _atLeast(policy.confirmedPoll);
      return _atLeast(policy.minuteLength * rem + policy.afterEnd);
    }

    // 배정만 된 좌석: 기한이 지나면 서버가 풀어 버린다. 기한 앞뒤로는 자주 보고 풀리는 순간 바로 다시 잡는다.
    final deadline = held.checkinExpiry ?? _firstSeen[held.id]!.add(policy.assumedCheckinWindow);
    final fastFrom = deadline.subtract(policy.edgeLead);
    final fastUntil = deadline.add(policy.edgeGrace);
    if (now.isBefore(fastFrom)) {
      final untilEdge = fastFrom.difference(now);
      return _atLeast(untilEdge < policy.unconfirmedPoll ? untilEdge : policy.unconfirmedPoll);
    }
    if (now.isBefore(fastUntil)) return _atLeast(policy.edgePoll);
    return _atLeast(policy.unconfirmedPoll);
  }

  /// 좌석이 없을 때: 예약 루프로 고른 좌석 중 비는 좌석을 잡는다. 끝낼 결과(없으면 null)와 다음에 내 좌석을 다시 읽을 때까지의 대기를 돌려준다.
  Future<({KeepOutcome? end, Duration wait})> _acquire(LibraryApi session) async {
    _hunt = null;
    _publish(KeepPhase.acquiring);
    final hunter = ReservationRunner(
      roomId: roomId,
      wanted: wanted,
      policy: runPolicy,
      api: session,
      login: login,
      onLog: onLog,
      onStatus: (s) {
        _hunt = s;
        _publish(_trouble.isEmpty ? KeepPhase.acquiring : KeepPhase.troubled);
        _checkTrouble();
      },
      isEnvironmentAlive: isEnvironmentAlive,
      // 좌석이 도중에 생기면(응답을 놓친 예약, 다른 곳에서 잡은 좌석) 바꾸지 않고 끝내 내 좌석 조회로 돌아간다.
      replaceExisting: true,
      confirmReplace: (_, _) async => false,
    );
    _hunter = hunter;
    if (_stopped || _timeUp) hunter.stop();
    final RunOutcome out;
    try {
      out = await hunter.run();
    } finally {
      _hunter = null;
    }
    _hunt = null;

    switch (out) {
      case Reserved(:final seat):
        _reserved++;
        _hadSeat = true; // 방금 예약했으니 갖고 있다 (내 좌석 조회에 아직 안 보여도, 곧 사라지면 사라진 것으로 센다)
        _lostAt = null;
        _troubleNotified = false;
        _trouble = '';
        _addRecent('${seat.code}번 좌석을 예약했어요');
        onLog('${seat.code}번 좌석을 예약했어요 (이번 실행 $_reserved번째)');
        onEvent(KeepEvent(KeepEventKind.reserved, '${seat.code}번 좌석을 예약했어요.', seatCode: seat.code, count: _reserved));
        onSeatChanged?.call();
        return (end: null, wait: policy.afterReserve);
      case KeepingSeat():
        return (end: null, wait: policy.minWait); // 좌석이 이미 있다. 내 좌석을 다시 읽어 지켜본다
      case Stopped():
        // 멈추라고 했거나 종료 시각이 된 것은 루프 맨 앞에서 처리한다. 그 밖이면(도중에 생긴 좌석을 두기로 함) 다시 읽는다.
        return (end: null, wait: policy.minWait);
      case ReserveRejected(:final message):
        _trouble = '예약이 계속 거절돼요: $message';
        onLog('예약이 계속 거절돼요 ($message). ${_fmt(policy.rejectedWait)} 뒤 다시 시도해요');
        _publish(KeepPhase.troubled);
        _notifyTrouble('예약이 계속 거절돼요: $message');
        return (end: null, wait: policy.rejectedWait);
      case ServerUnavailable(:final lastError):
        _trouble = '서버가 오래 응답하지 않아요 ($lastError)';
        onLog('서버가 오래 응답하지 않아요 ($lastError). 계속 다시 시도해요');
        _publish(KeepPhase.troubled);
        _notifyTrouble('서버가 오래 응답하지 않아요. 계속 다시 시도해요.');
        return (end: null, wait: policy.maxErrorBackoff);
      case ReplaceFailed():
        return (end: null, wait: policy.minWait);
      case LoginRejected(:final message):
        return (end: _end(KeepEndReason.loginRejected, message: message), wait: Duration.zero);
      case EnvironmentLost():
        return (end: _end(KeepEndReason.environmentLost), wait: Duration.zero);
      case Crashed(:final error):
        return (end: _end(KeepEndReason.crashed, message: '$error', error: error), wait: Duration.zero);
    }
  }

  /// 좌석이 없는 채로 오래 지났으면 한 번 알린다.
  void _checkTrouble() {
    final at = _lostAt;
    if (at == null || _troubleNotified) return;
    if (_now().difference(at) >= policy.troubleAfter) {
      _notifyTrouble('좌석을 ${_fmt(policy.troubleAfter)} 넘게 다시 잡지 못하고 있어요. 계속 시도해요.');
    }
  }

  void _notifyTrouble(String message) {
    if (_troubleNotified) return;
    _troubleNotified = true;
    onEvent(KeepEvent(KeepEventKind.trouble, message, count: _reserved));
  }

  void _publish(KeepPhase phase) {
    onStatus(KeepStatus(
      phase: phase,
      checkedAt: _now(),
      held: _held,
      reserved: _reserved,
      lost: _lost,
      endAt: endAt,
      hunt: _hunt,
      trouble: _trouble,
      recent: List.unmodifiable(_recent),
    ));
  }

  void _addRecent(String text) {
    _recent.insert(0, '${_clock(_now())}  $text');
    if (_recent.length > 6) _recent.removeLast();
  }

  Duration _atLeast(Duration d) => d < policy.minWait ? policy.minWait : d;

  Duration _backoff(int streak) {
    var d = policy.errorBackoff;
    for (var i = 1; i < streak && d < policy.maxErrorBackoff; i++) {
      d *= 2;
    }
    return d > policy.maxErrorBackoff ? policy.maxErrorBackoff : d;
  }

  /// 기다리면 나아질 수 있는 문제 (예약 루프와 같은 기준).
  bool _isTransient(Object e) => e is DioException || e is ApiException || e is TimeoutException;

  String _describe(Object e) {
    if (e is DioException) return e.message ?? e.type.name;
    return '$e';
  }

  static String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  static String _fmt(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes}분' : '${d.inSeconds}초';

  Future<bool> _alive() async {
    final check = isEnvironmentAlive;
    if (check == null) return true;
    try {
      return await check();
    } catch (_) {
      return true; // 확인이 실패했다고 좌석 유지를 멈추지는 않는다
    }
  }

  /// 쉰다. 시간이 다 돼서 깨면 false, 멈추라고 하거나 종료 시각이 돼서 깨우면 true.
  Future<bool> _sleep(Duration d) {
    if (_stopped || _timeUp) return Future.value(true);
    final done = Completer<bool>();
    final timer = Timer(d, () {
      if (!done.isCompleted) done.complete(false);
    });
    _wake = () {
      timer.cancel();
      if (!done.isCompleted) done.complete(true);
    };
    return done.future.whenComplete(() => _wake = null);
  }

  /// 오래 쉰다. 쉬는 동안 서버에는 묻지 않고, 백그라운드 서비스가 살아 있는지만 [KeepPolicy.aliveEvery] 마다 본다.
  /// 멈추라고 하거나 종료 시각이 되면 바로 돌아온다. 서비스가 끝났으면 false.
  Future<bool> _sleepLong(Duration total) async {
    var left = total;
    while (left > Duration.zero) {
      final step = left > policy.aliveEvery ? policy.aliveEvery : left;
      if (await _sleep(step)) return true;
      left -= step;
      if (left > Duration.zero && !await _alive()) return false;
    }
    return true;
  }
}
