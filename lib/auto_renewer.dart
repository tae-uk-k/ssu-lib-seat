import 'dart:async';

import 'package:dio/dio.dart';

import 'api.dart';
import 'reservation_runner.dart' show LoginFn;

// 자동 연장 루프. 예약 루프와 따로 돌면서 내 좌석의 남은 시간을 지켜보다가, 종료 30분 전이 되면 연장을 요청한다.
// Flutter 에 의존하지 않는 순수 Dart 라서 가짜 서버로 시험할 수 있다.
//
// 지키는 규칙
//  - 홈페이지와 같은 순서로 연장한다: (도서관에 와 있는지 확인) → 연장 요청. 확인 방법에 GATE 가 있으면 서버에 확인하고,
//    AUTO 거나 이 앱이 못 하는 방법(GPS, 비콘, NFC)뿐이면 확인 없이 연장을 요청해서 서버가 판단하게 둔다.
//  - 연장이 실패하면(도서관 밖, 서버 거절, 연결 오류 모두) [RenewPolicy.retryAfter] 뒤에 다시 시도한다. 남은 시간이 있는 동안 계속.
//  - 방금 연장한 좌석은 서버 값이 바뀔 때까지 [RenewPolicy.afterRenew] 동안 다시 연장하지 않는다 (연장 횟수는 제한이 있다).
//  - 학번/비밀번호가 거절되면 재시도 없이 멈춘다. 로그인이 풀린 경우에만 다시 로그인한다 (예약 루프와 같은 규칙).
//  - 갖고 있는 좌석이 없으면: 예약 루프가 아직 좌석을 노리는 중이면 기다리고, 아니면 끝낸다 ([SeatRenewer.waitForSeat]).
//  - 한 인스턴스는 한 번만 실행된다. 중지는 대기 중에도 즉시 먹는다.

/// 자동 연장 시간표.
class RenewPolicy {
  const RenewPolicy({
    this.threshold = const Duration(minutes: 30),
    this.retryAfter = const Duration(minutes: 5),
    this.maxPoll = const Duration(minutes: 15),
    this.minPoll = const Duration(seconds: 30),
    this.seatWait = const Duration(minutes: 5),
    this.confirmGap = const Duration(seconds: 5),
    this.afterRenew = const Duration(minutes: 10),
    this.errorBackoff = const Duration(seconds: 15),
    this.maxErrorBackoff = const Duration(minutes: 1),
    this.giveUpAfter = const Duration(hours: 2),
    this.maxQuickRelogins = 3,
    this.reloginCooldown = const Duration(minutes: 5),
  });

  /// 남은 시간이 이 이하가 되면 연장한다 (분 단위로 비교).
  final Duration threshold;

  /// 연장이 실패했을 때 다시 시도하기까지 기다리는 시간.
  final Duration retryAfter;

  /// 아직 때가 아닐 때 내 좌석을 다시 조회하기까지의 최대/최소 간격. 남은 시간은 서버가 알려 주는 값이라 문턱까지는 멀리 쉬고,
  /// 문턱이 가까워지면 그 시각에 맞춰 깨어난다 (한 번 갈 때마다 서버를 두드리는 일을 줄인다).
  final Duration maxPoll;
  final Duration minPoll;

  /// 좌석이 없고 예약 루프가 좌석을 노리는 중일 때 다시 조회하는 간격. 예약 루프가 좌석을 받으면 [SeatRenewer.nudge] 로 바로 깨우므로 길어도 된다.
  final Duration seatWait;

  /// 좌석이 없다고 나온 뒤 정말 없는지 한 번 더 확인하기까지의 간격 (방금 예약한 좌석이 목록에 늦게 뜰 수 있다).
  final Duration confirmGap;

  /// 연장에 성공한 뒤 같은 좌석을 다시 연장하지 않는 시간.
  final Duration afterRenew;

  /// 서버 조회 오류가 이어질 때 간격(2배씩 늘어 상한까지)과, 오류만 이만큼 계속되면 포기하는 시간.
  final Duration errorBackoff;
  final Duration maxErrorBackoff;
  final Duration giveUpAfter;

  /// 다시 로그인을 연달아 해 볼 수 있는 횟수. 넘으면 [reloginCooldown] 마다 한 번만 시도한다.
  final int maxQuickRelogins;
  final Duration reloginCooldown;
}

/// 자동 연장이 끝난 이유.
enum RenewEndReason {
  /// 사용자가 멈췄다.
  stopped,

  /// 학번/비밀번호가 거절됐다.
  loginRejected,

  /// 서버가 오랫동안 응답하지 않았다.
  serverUnavailable,

  /// 시작했는데 갖고 있는 좌석이 없다 (좌석을 노리는 예약 루프도 없을 때).
  noSeat,

  /// 좌석 이용이 끝났다 (반납, 시간 종료).
  seatEnded,

  /// 백그라운드 서비스가 끝났다.
  environmentLost,

  /// 예상하지 못한 오류.
  crashed,
}

class RenewOutcome {
  const RenewOutcome(
    this.reason, {
    this.message = '',
    this.renewed = 0,
    this.lastSeat,
    this.failing = false,
    this.downFor,
    this.error,
  });

  final RenewEndReason reason;

  /// 사유 설명 (로그인 거절 메시지, 마지막 서버 오류, 마지막 연장 실패 이유 등).
  final String message;

  /// 이번 실행에서 연장에 성공한 횟수.
  final int renewed;

  /// 마지막으로 본 내 좌석.
  final MyCharge? lastSeat;

  /// 끝날 때 연장이 실패하던 중이었는지 (연장하지 못한 채 좌석이 끝났을 수 있다).
  final bool failing;
  final Duration? downFor;
  final Object? error;
}

enum RenewEventKind { renewed, failed }

/// 사용자에게 알릴 만한 일. 연장에 성공했을 때, 연장에 실패했을 때(실패가 이어질 때마다 불린다).
class RenewEvent {
  const RenewEvent(this.kind, this.seat, this.message, {this.count = 0, this.failStreak = 0, this.retryIn});

  final RenewEventKind kind;
  final MyCharge seat;
  final String message;

  /// 이번 실행에서 성공한 연장 횟수.
  final int count;

  /// 연장 실패가 연속으로 몇 번째인지 (성공이면 0).
  final int failStreak;
  final Duration? retryIn;
}

/// 조회할 때마다 화면에 넘기는 상태.
class RenewStatus {
  const RenewStatus({
    required this.held,
    required this.renewed,
    required this.checkedAt,
    this.failStreak = 0,
    this.lastFailure = '',
    this.errorStreak = 0,
    this.lastError = '',
  });

  /// 지금 갖고 있는 좌석 (없으면 null).
  final MyCharge? held;
  final int renewed;
  final DateTime checkedAt;
  final int failStreak;
  final String lastFailure;

  /// 서버 조회 오류가 연속으로 몇 번째인지 (0 이면 정상).
  final int errorStreak;
  final String lastError;
}

class SeatRenewer {
  SeatRenewer({
    required this.policy,
    required this.login,
    required this.onLog,
    required this.onStatus,
    required this.onEvent,
    this.api,
    this.isEnvironmentAlive,
    this.waitForSeat,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final RenewPolicy policy;

  /// 새로 로그인한 API 를 돌려준다. 로그인 거절은 [LoginException], 서버 문제는 그 밖의 예외.
  final LoginFn login;
  final void Function(String) onLog;
  final void Function(RenewStatus) onStatus;
  final void Function(RenewEvent) onEvent;

  /// 이미 로그인된 API (없으면 시작할 때 [login] 을 부른다).
  final LibraryApi? api;

  /// 백그라운드 서비스 같은 실행 환경이 살아 있는지. false 면 [RenewEndReason.environmentLost] 로 끝낸다.
  final Future<bool> Function()? isEnvironmentAlive;

  /// 갖고 있는 좌석이 없을 때 끝내지 않고 기다려야 하는지 (예약 루프가 좌석을 노리는 중이면 true). 없으면 기다리지 않는다.
  final bool Function()? waitForSeat;
  final DateTime Function() _now;

  bool _started = false;
  bool _stopped = false;
  bool _nudged = false;
  void Function()? _wake;
  bool _everHeld = false;
  int _emptyPolls = 0;
  int _renewed = 0;
  int _failStreak = 0;
  String _lastFailure = '';
  MyCharge? _last;
  DateTime? _lastRenewedAt;
  String _lastLogged = '';
  String _lastCheck = '';
  int _repeat = 0;

  bool get isStopped => _stopped;

  /// 멈추라고 요청한다. 대기 중이면 바로 깨운다. 여러 번 불러도 된다.
  void stop() {
    _stopped = true;
    _wake?.call();
  }

  /// 기다리는 중이면 바로 깨워서 내 좌석을 다시 조회하게 한다 (예약 루프가 좌석을 받았을 때). 조회 도중에 불러도 놓치지 않는다.
  void nudge() {
    _nudged = true;
    _wake?.call();
  }

  /// 루프를 돌린다. 끝날 때까지 기다리면 끝난 이유가 나온다. 한 인스턴스에 한 번만 부를 수 있다.
  Future<RenewOutcome> run() async {
    if (_started) throw StateError('SeatRenewer 는 한 번만 실행할 수 있어요.');
    _started = true;
    try {
      return await _loop();
    } on LoginException catch (e) {
      return _end(RenewEndReason.loginRejected, message: e.message);
    } catch (e) {
      return _end(RenewEndReason.crashed, message: '$e', error: e);
    }
  }

  RenewOutcome _end(RenewEndReason reason, {String message = '', Duration? downFor, Object? error}) => RenewOutcome(
        reason,
        message: message.isNotEmpty ? message : _lastFailure,
        renewed: _renewed,
        lastSeat: _last,
        failing: _failStreak > 0,
        downFor: downFor,
        error: error,
      );

  Future<RenewOutcome> _loop() async {
    if (_stopped) return _end(RenewEndReason.stopped);
    var session = api; // null 이면 아래 루프 안에서 로그인한다 (일시적인 네트워크 오류도 재시도할 수 있게)

    var errorStreak = 0, reloginStreak = 0;
    DateTime? firstErrorAt, lastReloginAt;
    var lastError = '';

    while (!_stopped) {
      if (!await _alive()) return _end(RenewEndReason.environmentLost);

      var wait = policy.seatWait;
      String? failure;
      try {
        session ??= await login();
        final mine = await session.myCharges();
        if (errorStreak > 0) onLog('서버 연결이 돌아왔어요 (자동 연장, $errorStreak번 실패 후)');
        errorStreak = 0;
        firstErrorAt = null;
        lastError = '';
        if (mine.isEmpty) {
          final end = _noSeat();
          if (end != null) return end;
          wait = _emptyPolls > 0 ? policy.confirmGap : policy.seatWait;
        } else {
          _emptyPolls = 0;
          wait = await _tend(session, mine.first);
        }
        reloginStreak = 0; // 조회부터 연장까지 한 바퀴가 로그인 문제 없이 끝났을 때만 (연장이 거부되면 연달아 다시 로그인하지 않게)
      } on SessionException catch (e) {
        final canRelogin = reloginStreak < policy.maxQuickRelogins ||
            lastReloginAt == null ||
            _now().difference(lastReloginAt) >= policy.reloginCooldown;
        if (canRelogin) {
          reloginStreak++;
          lastReloginAt = _now();
          onLog('로그인이 풀린 것 같아 다시 로그인합니다 (자동 연장: ${e.message})');
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
        firstErrorAt ??= _now();
        lastError = failure;
        final downFor = _now().difference(firstErrorAt);
        if (downFor >= policy.giveUpAfter) {
          return _end(RenewEndReason.serverUnavailable, message: lastError, downFor: downFor);
        }
        if (errorStreak == 1 || errorStreak % 10 == 0) {
          onLog('서버 응답 오류 (자동 연장, $errorStreak번째): $failure. 잠시 뒤 다시 시도해요');
        }
        onStatus(_status(_last, errorStreak: errorStreak, lastError: lastError));
        wait = _backoff(errorStreak);
      }
      await _sleep(wait);
    }
    return _end(RenewEndReason.stopped);
  }

  /// 갖고 있는 좌석이 없을 때. 예약 루프가 아직 좌석을 노리는 중이면 기다리고, 아니면 (한 번 더 확인한 뒤) 끝낸다.
  RenewOutcome? _noSeat() {
    onStatus(_status(null));
    if (waitForSeat?.call() ?? false) {
      _emptyPolls = 0;
      _logRepeated('연장할 좌석이 아직 없어요. 좌석이 생기면 자동으로 지켜봐요');
      return null;
    }
    if (++_emptyPolls < 2) return null; // 방금 예약한 좌석이 목록에 늦게 뜰 수 있어서 한 번 더 본다
    return _end(_everHeld ? RenewEndReason.seatEnded : RenewEndReason.noSeat);
  }

  /// 내 좌석을 보고 연장할지 정한다. 다음 조회까지 기다릴 시간을 돌려준다.
  Future<Duration> _tend(LibraryApi session, MyCharge held) async {
    _everHeld = true;
    _last = held;
    onStatus(_status(held));
    final rem = held.remainingMinutes;
    final limit = policy.threshold.inMinutes;
    _noteCheck(held, rem);

    final renewedAt = _lastRenewedAt;
    if (renewedAt != null) {
      final since = _now().difference(renewedAt);
      if (since < policy.afterRenew) return _clamp(policy.afterRenew - since); // 방금 연장했다. 서버 값이 바뀔 때까지 기다린다
    }

    // 아직 이용이 시작되지 않은 좌석(배정만 되고 확정 전)은 연장할 수 없다. 서버가 연장 가능이라고 하지 않는 한 기다린다.
    if (!held.returnable && held.renewable != true) {
      _logRepeated('${held.seatCode}번 좌석은 아직 이용을 시작하기 전이라 연장하지 않아요');
      return policy.seatWait;
    }

    // 남은 시간을 알면 그걸로, 모르면 서버가 "연장 가능"이라고 한 때를 때로 본다.
    final due = rem != null ? rem <= limit : held.renewable == true;
    if (!due) {
      if (rem == null) return policy.maxPoll;
      return _clamp(Duration(minutes: rem - limit)); // 문턱이 가까우면 그 시각에 맞춰 깨어난다
    }
    if (held.renewable == false) {
      _logRepeated('${held.seatCode}번 좌석이 ${rem ?? '?'}분 남았지만 서버가 아직 연장할 수 없다고 해요. ${_fmt(policy.retryAfter)} 뒤 다시 확인해요');
      return policy.retryAfter;
    }

    onLog('${held.seatCode}번 좌석 이용이 ${rem ?? '?'}분 남아 연장을 시도해요');
    String? why;
    try {
      why = await _renew(session, held);
    } on SessionException {
      rethrow; // 로그인이 풀렸으면 다시 로그인해서 이어간다
    } catch (e) {
      if (!_isTransient(e)) rethrow;
      why = '연결이 불안정해요 (${_describe(e)})'; // 도서관 밖에서 와이파이가 끊긴 경우도 여기로 온다
    }

    if (why == null) {
      _renewed++;
      _failStreak = 0;
      _lastFailure = '';
      _lastRenewedAt = _now();
      onLog('${held.seatCode}번 좌석을 연장했어요 (이번 실행 $_renewed번째)');
      onEvent(RenewEvent(RenewEventKind.renewed, held, '${held.seatCode}번 좌석을 연장했어요.', count: _renewed));
      onStatus(_status(held));
      return policy.minPoll; // 곧 다시 조회해서 늘어난 시간을 보여 준다
    }
    _failStreak++;
    _lastFailure = why;
    onLog('연장 실패: $why. ${_fmt(policy.retryAfter)} 뒤에 다시 시도해요 (연속 $_failStreak번째)');
    onEvent(RenewEvent(RenewEventKind.failed, held, why, count: _renewed, failStreak: _failStreak, retryIn: policy.retryAfter));
    onStatus(_status(held));
    return policy.retryAfter;
  }

  /// 내 좌석을 확인할 때마다 한 줄 남긴다 (연장이 지금 돌고 있는지 진행 기록에서 보이게). 직전과 같은 내용이면 건너뛴다.
  void _noteCheck(MyCharge held, int? rem) {
    final line = '내 좌석 확인: ${held.seatCode}번 · ${rem == null ? '남은 시간을 몰라요' : '남은 $rem분'}${held.returnable ? '' : ' (이용 시작 전)'}';
    if (line == _lastCheck) return;
    _lastCheck = line;
    onLog(line);
  }

  /// 연장 요청. 성공하면 null, 실패하면 이유.
  Future<String?> _renew(LibraryApi session, MyCharge held) async {
    final roomId = held.roomId;
    final methods = held.arrivalMethods;
    if (roomId != null && !methods.contains('AUTO') && methods.contains('GATE')) {
      if (!await session.checkArrival(roomId, 'GATE')) return '도서관 안에 있는 것이 확인되지 않아요';
    }
    final res = await session.renewCharge(held.id);
    if (res['success'] == true) return null;
    final msg = '${res['code'] ?? ''} ${res['message'] ?? ''}'.trim();
    return msg.isEmpty ? '서버가 연장을 거절했어요' : msg;
  }

  RenewStatus _status(MyCharge? held, {int errorStreak = 0, String lastError = ''}) => RenewStatus(
        held: held,
        renewed: _renewed,
        checkedAt: _now(),
        failStreak: _failStreak,
        lastFailure: _lastFailure,
        errorStreak: errorStreak,
        lastError: lastError,
      );

  Duration _clamp(Duration d) => d < policy.minPoll ? policy.minPoll : (d > policy.maxPoll ? policy.maxPoll : d);

  Duration _backoff(int streak) {
    var d = policy.errorBackoff;
    for (var i = 1; i < streak && d < policy.maxErrorBackoff; i++) {
      d *= 2;
    }
    return d > policy.maxErrorBackoff ? policy.maxErrorBackoff : d;
  }

  static String _fmt(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes}분' : '${d.inSeconds}초';

  /// 기다리면 나아질 수 있는 문제 (예약 루프와 같은 기준).
  bool _isTransient(Object e) => e is DioException || e is ApiException || e is TimeoutException;

  String _describe(Object e) {
    if (e is DioException) return e.message ?? e.type.name;
    return '$e';
  }

  Future<bool> _alive() async {
    final check = isEnvironmentAlive;
    if (check == null) return true;
    try {
      return await check();
    } catch (_) {
      return true; // 확인이 실패했다고 연장을 멈추지는 않는다
    }
  }

  /// 같은 문구가 계속 반복되면 기록이 한 가지 줄로 가득 차므로, 바뀔 때와 40번에 한 번만 남긴다.
  void _logRepeated(String msg) {
    if (msg != _lastLogged) {
      _lastLogged = msg;
      _repeat = 1;
      onLog(msg);
      return;
    }
    _repeat++;
    if (_repeat % 40 == 0) onLog('$msg (연속 $_repeat번)');
  }

  Future<void> _sleep(Duration d) {
    if (_stopped || _nudged) {
      _nudged = false;
      return Future.value();
    }
    final done = Completer<void>();
    final timer = Timer(d, () {
      if (!done.isCompleted) done.complete();
    });
    _wake = () {
      timer.cancel();
      if (!done.isCompleted) done.complete();
    };
    return done.future.whenComplete(() {
      _wake = null;
      _nudged = false;
    });
  }
}
