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
//  - [ReservationRunner.replaceExisting] 를 켜면, 이미 좌석이 있을 때 원하는 좌석이 비는 순간 내 좌석을 반납(확정 전이면 취소)하고 새로 예약한다.
//    좌석을 잃지 않도록: 반납 전에 내 좌석을 조회해 같거나 더 원하는 좌석이면 바꾸지 않고, 바꾸기 전에 사용자에게 한 번 물어보고
//    ([ReservationRunner.confirmReplace]), 반납한 뒤 새 예약이 거절되면 원래 좌석을 다시 예약해 본다.
//    반납이 성공한 뒤에는 중지를 눌러도 이 교체는 끝까지 마친다.
//  - 확인 간격은 [RunPolicy.pacing] 이 정한다: 고른 좌석이 곧 비면 사용자가 정한 간격으로 자주, 한참 남았으면 뜸하게 확인한다.

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

/// 가장 원하는 좌석을 이미 갖고 있어서 더 바꿀 좌석이 없다.
final class KeepingSeat extends RunOutcome {
  const KeepingSeat(this.held);
  final MyCharge held;
}

/// 좌석을 바꾸려고 기존 좌석을 반납(취소)했지만 새 좌석 예약에 실패했다.
/// [restored] 는 원래 좌석을 다시 예약했는지 (false 면 좌석이 없는 상태일 수 있다).
final class ReplaceFailed extends RunOutcome {
  const ReplaceFailed(this.wanted, this.old, {required this.restored, required this.message});
  final Seat wanted;
  final MyCharge old;
  final bool restored;
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
    this.maxSwapAttempts = 3,
    this.pacing = defaultPacing,
  });

  /// 가장 빠른 확인 간격 (고른 좌석이 곧 빌 때). 사용자가 정한다.
  final Duration interval;

  /// 정상일 때 다음 확인까지 기다릴 시간. 고른 좌석 중 이용이 가장 먼저 끝나는 좌석의 남은 시간(분, 모르면 null)을 받는다.
  /// 시험에서는 이걸 [interval] 그대로로 바꿔 끼운다.
  final Duration Function(Duration interval, int? soonestMinutes) pacing;

  /// 오류가 계속될 때 간격이 늘어나는 상한.
  final Duration maxBackoff;

  /// 오류만 이만큼 계속되면 포기한다.
  final Duration giveUpAfter;

  /// 조회가 성공하지 못한 채 연속으로 다시 로그인할 수 있는 횟수. 넘으면 [reloginCooldown] 마다 한 번만 시도한다.
  final int maxQuickRelogins;
  final Duration reloginCooldown;

  /// 예약 요청이 연속으로 이만큼 실패하면 멈추고 사유를 알린다.
  final int maxReserveFailures;

  /// 좌석 교체(기존 좌석 반납 → 새 좌석 예약)가 이만큼 실패하면 멈춘다. 실패할 때마다 원래 좌석을 다시 예약하느라
  /// 좌석이 계속 반납됐다 잡혔다 하는 일을 막는다.
  final int maxSwapAttempts;
}

/// 곧 빌 좌석이 멀수록 확인 간격을 늘린다 (한참 남았는데 서버를 계속 두드리지 않으려고).
/// [base] 는 사용자가 정한 가장 빠른 간격이라 이보다 짧아지지 않는다. [soonestMinutes] 를 모르면 가장 빠른 간격으로 확인한다.
///
///   3분 이하 → [base] · 10분 이하 → 3초 · 30분 이하 → 6초 · 60분 이하 → 15초 · 그보다 많이 남음 → 30초
///
/// 남은 시간은 "최대"라서 그전에 퇴실해 일찍 비는 좌석은 늦게 발견될 수 있다. 그래서 상한을 30초로 둔다.
Duration defaultPacing(Duration base, int? soonestMinutes) {
  final m = soonestMinutes;
  if (m == null || m <= 3) return base;
  final seconds = m <= 10 ? 3 : (m <= 30 ? 6 : (m <= 60 ? 15 : 30));
  final slow = Duration(seconds: seconds);
  return slow > base ? slow : base;
}

/// 내 좌석을 바꿀지 사용자에게 묻는다. [held] 는 지금 갖고 있는 좌석, [rank] 는 고른 좌석 목록에서 그 좌석의 순서
/// (0 이 가장 먼저 고른 좌석, 목록에 없거나 다른 열람실이면 -1). true 면 바꾼다.
typedef ReplaceConfirm = Future<bool> Function(MyCharge held, int rank);

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

/// 고른 좌석 중 사용 중이면서 남은 시간이 가장 짧은 좌석. [exclude] 는 내가 갖고 있는 좌석 번호 (내 좌석은 비는 게 아니다).
Seat? soonestEnding(List<Seat> seats, List<String> wanted, {String? exclude}) {
  Seat? best;
  for (final s in seats) {
    if (!wanted.contains(s.code) || s.code == exclude || s.available || s.remainingMinutes == null) continue;
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
    this.replaceExisting = false,
    this.confirmReplace,
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

  /// 이미 좌석이 있으면 원하는 좌석이 비는 순간 내 좌석을 반납(확정 전이면 취소)하고 새로 예약한다.
  final bool replaceExisting;

  /// 내 좌석을 반납하기 전에 사용자에게 묻는다. 없으면 묻지 않고 바꾼다. 같은 좌석은 한 번만 묻고, 묻다가 오류가 나면 "아니요"로 본다.
  final ReplaceConfirm? confirmReplace;
  final DateTime Function() _now;

  bool _started = false;
  bool _stopped = false;
  bool _heldChecked = false; // 시작할 때 내 좌석을 한 번 확인했는지 (replaceExisting)
  String? _heldCode; // 이 열람실에서 내가 갖고 있는 좌석 번호 (기다릴 대상에서 뺀다)
  final _decided = <String, bool>{}; // 열람실/좌석 번호 → 바꾸기로 했는지. 반납했다 되찾아 예약 번호가 바뀌어도 다시 묻지 않는다
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

    var checks = 0, errorStreak = 0, reloginStreak = 0, reserveFails = 0, swapFails = 0;
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
        if (replaceExisting && !_heldChecked && !_stopped) {
          // 시작하자마자 내 좌석을 확인해서, 바꾸기 전에 사용자에게 한 번 묻고 (좌석을 갖고 있을 때만), 이미 가장 원하는 좌석이면 바로 끝낸다.
          final end = (await _checkHeld(session, null)).end;
          _heldChecked = true;
          if (end != null) return end;
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
        wait = _pace(seats);

        final seat = _pick(seats);
        if (_stopped && seat == null) break;
        if (seat == null) {
          reserveFails = 0;
          _logRepeated('빈 좌석 없음');
        } else if (!_stopped) {
          MyCharge? old; // 이번에 반납하고 바꿀 내 좌석
          var skip = false;
          if (replaceExisting) {
            final plan = await _checkHeld(session, seat);
            if (plan.end != null) return plan.end!;
            old = plan.old;
            skip = !plan.go;
          }
          if (old != null) {
            final target = old;
            onLog('${target.seatCode}번 좌석을 반납하고 ${seat.code}번으로 바꿔요');
            final c = await _guarded(() => _release(session!, target));
            if (c == null || c['success'] != true) {
              reserveFails++;
              final why = c == null ? '연결이 끊겨 반납됐는지 알 수 없어요' : '${c['code']} ${c['message']}'.trim();
              onLog('기존 좌석 반납 실패: $why');
              if (reserveFails >= policy.maxReserveFailures) {
                return ReserveRejected(seat, '기존 ${target.seatCode}번 좌석을 반납하지 못했어요. $why');
              }
              old = null;
              skip = true; // 반납되지 않았으니 예약하지 않는다. 다음 바퀴에서 내 좌석부터 다시 본다
            }
          }
          if (!skip) {
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
              final msg = '${res['code']} ${res['message']}'.trim();
              onLog('예약 실패: $msg');
              final released = old;
              if (released != null) {
                // 기존 좌석은 이미 반납했다. 원래 좌석을 되찾아 본다.
                swapFails++;
                final back = await _guarded(() => session!.reserve(released.seatId));
                if (back == null || back['success'] != true) {
                  onLog('원래 ${released.seatCode}번 좌석을 다시 예약하지 못했어요');
                  return ReplaceFailed(seat, released, restored: false, message: msg);
                }
                onLog('원래 ${released.seatCode}번 좌석을 다시 예약했어요');
                if (swapFails >= policy.maxSwapAttempts) return ReplaceFailed(seat, released, restored: true, message: msg);
              } else {
                reserveFails++;
                if (reserveFails >= policy.maxReserveFailures) return ReserveRejected(seat, msg);
              }
            }
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
  Future<Map<String, dynamic>?> _reserve(LibraryApi session, Seat seat) => _guarded(() => session.reserve(seat.id));

  /// 상태를 바꾸는 요청(예약, 반납). 연결 오류면 null: 서버에서는 이미 처리됐을 수도 있어 결과를 알 수 없다.
  Future<Map<String, dynamic>?> _guarded(Future<Map<String, dynamic>> Function() call) async {
    try {
      return await call();
    } catch (e) {
      if (_isTransient(e)) return null;
      rethrow;
    }
  }

  /// 내 좌석을 내놓는다. 이미 확정돼 이용 중이면 반납, 아직 확정 전이면 취소 (홈페이지와 같은 구분).
  Future<Map<String, dynamic>> _release(LibraryApi session, MyCharge held) =>
      held.returnable ? session.returnCharge(held.id) : session.cancelCharge(held.id);

  /// 내 좌석을 조회해 바꿔도 되는지 정한다. [candidate] 는 지금 예약하려는 좌석 (시작할 때 점검이면 null).
  ///  - end: 더 할 일이 없거나 사용자가 바꾸지 않겠다고 해서 여기서 끝낸다.
  ///  - go/old: 반납하고 바꿀 내 좌석. old 가 null 이고 go 가 true 면 바꿀 좌석이 없어 그냥 예약하면 된다.
  ///    go 가 false 면 이번에는 예약하지 않는다.
  Future<({bool go, MyCharge? old, RunOutcome? end})> _checkHeld(LibraryApi session, Seat? candidate) async {
    final List<MyCharge> mine;
    try {
      mine = await session.myCharges();
    } on ApiException catch (e) {
      // 내 좌석을 읽지 못해도 예약 자체를 막지 않는다. 좌석을 바꾸지 못할 뿐이다 (이미 좌석이 있으면 서버가 거절한다).
      _logRepeated('내 좌석을 확인하지 못해 바꾸지 않고 예약만 시도해요 (${e.message})');
      return (go: true, old: null, end: null);
    }
    if (mine.isEmpty) {
      _heldCode = null;
      if (candidate == null) onLog('지금 갖고 있는 좌석이 없어요. 원하는 좌석이 나면 그냥 예약해요');
      return (go: true, old: null, end: null);
    }
    final held = mine.first;
    final sameRoom = held.roomId == roomId;
    _heldCode = sameRoom ? held.seatCode : null;
    // 같은 열람실이고 원하는 목록에 든 좌석이면 그 우선순위 (0 이 가장 원하는 좌석), 아니면 -1.
    final heldRank = sameRoom ? wanted.indexOf(held.seatCode) : -1;
    if (heldRank == 0) {
      onLog('가장 원하는 ${held.seatCode}번 좌석을 이미 갖고 있어요');
      return (go: false, old: null, end: KeepingSeat(held));
    }
    if (candidate != null && heldRank > 0 && heldRank < wanted.indexOf(candidate.code)) {
      _logRepeated('이미 더 원하는 ${held.seatCode}번 좌석이 있어서 ${candidate.code}번으로 바꾸지 않아요');
      return (go: false, old: null, end: null);
    }
    // 여기부터는 내 좌석을 내놓게 되니 사용자가 동의했는지 본다 (처음 한 번만 묻는다).
    if (!await _consent(held, heldRank)) {
      if (candidate == null) {
        onLog('좌석 바꾸기를 하지 않기로 해서 예약을 시작하지 않아요');
        return (go: false, old: null, end: const Stopped());
      }
      _logRepeated('바꾸지 않기로 한 ${held.seatCode}번 좌석은 그대로 둬요');
      return (go: false, old: null, end: null);
    }
    if (candidate == null) onLog('지금 ${held.roomName} ${held.seatCode}번 좌석이 있어요. 원하는 좌석이 나면 반납하고 바꿔요');
    return (go: true, old: held, end: null);
  }

  /// 내 좌석을 내놓아도 되는지. 같은 좌석은 한 번만 묻는다. 물을 방법이 없으면(콜백 없음) 허락으로 본다.
  Future<bool> _consent(MyCharge held, int rank) async {
    final key = '${held.roomId}/${held.seatCode}';
    final known = _decided[key];
    if (known != null) return known;
    var ok = true;
    final ask = confirmReplace;
    if (ask != null) {
      try {
        ok = await ask(held, rank);
      } catch (_) {
        ok = false; // 동의를 받지 못했으면 좌석을 건드리지 않는다
      }
    }
    return _decided[key] = ok;
  }

  /// 다음 확인까지 기다릴 시간. 고른 좌석 중 이미 빈 좌석이 있거나 언제 빌지 모르는 좌석이 있으면 가장 빠른 간격으로,
  /// 모두 사용 중이면 가장 먼저 끝나는 좌석의 남은 시간에 맞춰 [RunPolicy.pacing] 이 늘린다.
  Duration _pace(List<Seat> seats) {
    final byCode = {for (final s in seats) s.code: s};
    int? soonest;
    for (final c in wanted) {
      final s = byCode[c];
      if (s == null || !s.active || c == _heldCode) continue; // 없는 좌석, 쓸 수 없는 좌석, 내 좌석은 기다릴 대상이 아니다
      if (s.available) return policy.interval;
      final m = s.remainingMinutes;
      if (m == null) return policy.interval; // 언제 빌지 모른다
      if (soonest == null || m < soonest) soonest = m;
    }
    return policy.pacing(policy.interval, soonest);
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
        soonest: soonestEnding(seats, wanted, exclude: _heldCode),
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
