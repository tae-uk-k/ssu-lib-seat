import 'dart:async';

import 'package:dio/dio.dart';

import 'api.dart';

// 예약 루프. Flutter 에 의존하지 않는 순수 Dart 라서 가짜 서버로 시험할 수 있다.
//
// 지키는 규칙
//  - 학번/비밀번호가 거절되면 재시도 없이 곧바로 멈춘다 (여러 번 틀리면 계정이 잠긴다).
//  - 네트워크 오류, 서버 5xx, 점검 안내 같은 일시적인 문제는 간격을 늘려 가며 계속 재시도한다.
//    한 번의 이상한 응답으로 예약 전체가 멈추면 안 된다.
//  - 로그인이 풀린 경우에만 다시 로그인한다. 연속으로 몇 번 다시 해 보다가 안 되면 일정 시간에 한 번만 시도한다.
//  - 한 인스턴스는 한 번만 실행된다. 중지는 대기 중에도 즉시 먹는다 (중지 직후 다시 시작해도 겹쳐 돌지 않게).

/// 예약 루프가 끝난 이유.
sealed class RunOutcome {
  const RunOutcome();
}

/// 좌석을 배정받았다.
final class Reserved extends RunOutcome {
  const Reserved(this.seat);
  final Seat seat;
}

/// 사용자가 멈췄다.
final class Stopped extends RunOutcome {
  const Stopped();
}

/// 학번/비밀번호가 거절됐다.
final class LoginRejected extends RunOutcome {
  const LoginRejected(this.message);
  final String message;
}

/// 서버가 오랫동안 응답하지 않거나 계속 거부했다.
final class ServerUnavailable extends RunOutcome {
  const ServerUnavailable(this.downFor, this.lastError);
  final Duration downFor;
  final String lastError;
}

/// 비어 보이는 좌석인데 예약 요청이 연속으로 거절됐다. 이미 좌석을 배정받았거나 이용 제한일 수 있다.
final class ReserveRejected extends RunOutcome {
  const ReserveRejected(this.seat, this.message);
  final Seat seat;
  final String message;
}

/// 백그라운드 서비스가 끝나서 더 이어갈 수 없다.
final class EnvironmentLost extends RunOutcome {
  const EnvironmentLost();
}

/// 예상하지 못한 오류.
final class Crashed extends RunOutcome {
  const Crashed(this.error);
  final Object error;
}

class RunPolicy {
  const RunPolicy({
    required this.interval,
    this.maxBackoff = const Duration(seconds: 30),
    this.giveUpAfter = const Duration(hours: 2),
    this.maxQuickRelogins = 3,
    this.reloginCooldown = const Duration(minutes: 5),
    this.maxReserveFailures = 8,
  });

  /// 정상일 때 확인 간격.
  final Duration interval;

  /// 오류가 계속될 때 간격이 늘어나는 상한.
  final Duration maxBackoff;

  /// 오류만 이만큼 계속되면 포기한다.
  final Duration giveUpAfter;

  /// 조회가 성공하지 못한 채 연속으로 다시 로그인할 수 있는 횟수. 넘으면 [reloginCooldown] 마다 한 번만 시도한다.
  final int maxQuickRelogins;
  final Duration reloginCooldown;

  /// 예약 요청이 연속으로 이만큼 실패하면 멈추고 사유를 알린다.
  final int maxReserveFailures;
}

/// 조회할 때마다 화면에 넘기는 상태.
class RunStatus {
  const RunStatus({
    required this.checks,
    required this.wanted,
    required this.free,
    required this.seats,
    this.soonest,
    this.errorStreak = 0,
    this.lastError = '',
  });

  final int checks;
  final int wanted;

  /// 고른 좌석 중 지금 비어 있는 좌석 수.
  final int free;

  /// 가장 최근에 받은 좌석 목록 (API 순서 그대로).
  final List<Seat> seats;

  /// 고른 좌석 중 사용 중이면서 이용이 가장 먼저 끝나는 좌석.
  final Seat? soonest;

  /// 서버 오류가 연속으로 몇 번째인지 (0 이면 정상).
  final int errorStreak;
  final String lastError;
}

typedef LoginFn = Future<LibraryApi> Function();

/// 고른 좌석 중 사용 중이면서 남은 시간이 가장 짧은 좌석.
Seat? soonestEnding(List<Seat> seats, List<String> wanted) {
  Seat? best;
  for (final s in seats) {
    if (!wanted.contains(s.code) || s.available || s.remainingMinutes == null) continue;
    if (best == null || s.remainingMinutes! < best.remainingMinutes!) best = s;
  }
  return best;
}

class ReservationRunner {
  ReservationRunner({
    required this.roomId,
    required this.wanted,
    required this.policy,
    required this.login,
    required this.onLog,
    required this.onStatus,
    this.api,
    this.isEnvironmentAlive,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int roomId;

  /// 우선순위 순서의 좌석 번호.
  final List<String> wanted;
  final RunPolicy policy;

  /// 새로 로그인한 API 를 돌려준다. 로그인 거절은 [LoginException], 서버 문제는 그 밖의 예외.
  final LoginFn login;
  final void Function(String) onLog;
  final void Function(RunStatus) onStatus;

  /// 이미 로그인된 API (없으면 시작할 때 [login] 을 부른다).
  final LibraryApi? api;

  /// 백그라운드 서비스 같은 실행 환경이 살아 있는지. false 면 [EnvironmentLost] 로 끝낸다.
  final Future<bool> Function()? isEnvironmentAlive;
  final DateTime Function() _now;

  bool _started = false;
  bool _stopped = false;
  void Function()? _wake;
  String _lastLogged = '';
  int _repeat = 0;
  List<Seat> _lastSeats = const [];

  bool get isStopped => _stopped;

  /// 멈추라고 요청한다. 대기 중이면 바로 깨운다. 여러 번 불러도 된다.
  void stop() {
    _stopped = true;
    _wake?.call();
  }

  /// 루프를 돌린다. 끝날 때까지 기다리면 끝난 이유가 나온다. 한 인스턴스에 한 번만 부를 수 있다.
  Future<RunOutcome> run() async {
    if (_started) throw StateError('ReservationRunner 는 한 번만 실행할 수 있어요.');
    _started = true;
    try {
      return await _loop();
    } on LoginException catch (e) {
      return LoginRejected(e.message);
    } catch (e) {
      return Crashed(e);
    }
  }

  Future<RunOutcome> _loop() async {
    if (_stopped) return const Stopped();
    var session = api; // null 이면 아래 루프 안에서 로그인한다 (일시적인 네트워크 오류도 재시도할 수 있게)

    var checks = 0, errorStreak = 0, reloginStreak = 0, reserveFails = 0;
    var announcedLogin = false;
    DateTime? firstErrorAt, lastReloginAt;
    String lastError = '';

    while (!_stopped) {
      if (!await _alive()) return const EnvironmentLost();

      var wait = policy.interval;
      String? failure;
      try {
        if (session == null) {
          if (!announcedLogin && checks == 0) {
            announcedLogin = true;
            onLog('로그인 중…');
          }
          session = await login();
        }
        final seats = await session.seats(roomId);
        _lastSeats = seats;
        if (errorStreak > 0) onLog('서버 연결이 돌아왔어요 ($errorStreak번 실패 후)');
        errorStreak = 0;
        reloginStreak = 0;
        firstErrorAt = null;
        lastError = '';
        checks++;
        onStatus(_status(seats, checks, 0, ''));

        final seat = _pick(seats);
        if (_stopped && seat == null) break;
        if (seat == null) {
          reserveFails = 0;
          _logRepeated('빈 좌석 없음');
        } else if (!_stopped) {
          onLog('${seat.code}번 좌석이 비었어요. 예약 시도');
          final res = await _reserve(session, seat);
          if (res == null) {
            // 요청 중 연결 오류: 서버에서는 이미 처리됐을 수도 있어서 결과를 알 수 없다.
            reserveFails++;
            onLog('예약 요청 중 연결이 끊겼어요. 배정됐는지 알 수 없어요. 홈페이지에서 확인해 주세요');
          } else if (res['success'] == true) {
            onLog('배정 완료! ${seat.code}번 좌석');
            return Reserved(seat);
          } else {
            reserveFails++;
            final msg = '${res['code']} ${res['message']}'.trim();
            onLog('예약 실패: $msg');
            if (reserveFails >= policy.maxReserveFailures) return ReserveRejected(seat, msg);
          }
        }
      } on SessionException catch (e) {
        final canRelogin = reloginStreak < policy.maxQuickRelogins ||
            lastReloginAt == null ||
            _now().difference(lastReloginAt) >= policy.reloginCooldown;
        if (canRelogin) {
          reloginStreak++;
          lastReloginAt = _now();
          onLog('로그인이 풀린 것 같아 다시 로그인합니다 (${e.message})');
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
        if (downFor >= policy.giveUpAfter) return ServerUnavailable(downFor, lastError);
        if (errorStreak == 1 || errorStreak % 10 == 0) {
          onLog('서버 응답 오류 ($errorStreak번째): $failure. 잠시 뒤 다시 시도해요');
        }
        onStatus(_status(_lastSeats, checks, errorStreak, lastError));
        wait = _backoff(errorStreak);
      }
      await _sleep(wait);
    }
    return const Stopped();
  }

  /// 예약 요청. 연결 오류면 null (결과를 알 수 없음).
  Future<Map<String, dynamic>?> _reserve(LibraryApi session, Seat seat) async {
    try {
      return await session.reserve(seat.id);
    } catch (e) {
      if (_isTransient(e)) return null;
      rethrow;
    }
  }

  Seat? _pick(List<Seat> seats) {
    final byCode = {for (final s in seats) s.code: s};
    for (final c in wanted) {
      final s = byCode[c];
      if (s != null && s.available) return s;
    }
    return null;
  }

  RunStatus _status(List<Seat> seats, int checks, int errorStreak, String lastError) => RunStatus(
        checks: checks,
        wanted: wanted.length,
        free: seats.where((s) => wanted.contains(s.code) && s.available).length,
        seats: seats,
        soonest: soonestEnding(seats, wanted),
        errorStreak: errorStreak,
        lastError: lastError,
      );

  Duration _backoff(int streak) {
    var d = policy.interval;
    for (var i = 1; i < streak && d < policy.maxBackoff; i++) {
      d *= 2;
    }
    return d > policy.maxBackoff ? policy.maxBackoff : d;
  }

  /// 기다리면 나아질 수 있는 문제. 응답 모양이 이상한 경우는 [LibApi] 가 이미 [ApiException] 으로 바꿔 준다.
  /// TypeError/FormatException 같은 나머지는 우리 쪽 버그일 가능성이 커서 재시도로 덮지 않고 드러낸다.
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
      return true; // 확인이 실패했다고 예약을 멈추지는 않는다
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
    if (_stopped) return Future.value();
    final done = Completer<void>();
    final timer = Timer(d, () {
      if (!done.isCompleted) done.complete();
    });
    _wake = () {
      timer.cancel();
      if (!done.isCompleted) done.complete();
    };
    return done.future.whenComplete(() => _wake = null);
  }
}
