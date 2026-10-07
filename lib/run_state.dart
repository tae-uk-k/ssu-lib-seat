import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 앱이 말없이 사라지는 경우를 다음 실행 때 알아채기 위한 기록.
// 예약이 도는 동안 "실행 중" 표시와 마지막 확인 시각을 남겨 두고, 정상적으로 끝나면 지운다.
// 표시가 남은 채로 앱이 다시 켜졌다면 (최근 앱에서 밀어 끔, 시스템 종료, 크래시) 예약이 중간에 멈춘 것이다.

class InterruptedRun {
  const InterruptedRun({required this.room, required this.seatCount, required this.since, required this.lastCheck});
  final String room;
  final int seatCount;
  final DateTime since;

  /// 마지막으로 살아 있던 시각 (가장 최근 확인 또는 시작 시각).
  final DateTime lastCheck;
}

class RunMarker {
  static const _active = 'run_active';
  static const _room = 'run_room';
  static const _count = 'run_count';
  static const _since = 'run_since';
  static const _last = 'run_last';

  static Future<void> begin(String room, int seatCount, {DateTime? at}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final now = (at ?? DateTime.now()).toIso8601String();
      await p.setBool(_active, true);
      await p.setString(_room, room);
      await p.setInt(_count, seatCount);
      await p.setString(_since, now);
      await p.setString(_last, now);
    } catch (e) {
      debugPrint('RunMarker.begin 실패: $e');
    }
  }

  /// 마지막으로 살아 있던 시각을 갱신한다. 자주 부르지 말 것 (호출하는 쪽에서 몇 초에 한 번으로 줄인다).
  static Future<void> beat({DateTime? at}) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_active) != true) return;
      await p.setString(_last, (at ?? DateTime.now()).toIso8601String());
    } catch (e) {
      debugPrint('RunMarker.beat 실패: $e');
    }
  }

  /// 정상적으로 끝났다 (사용자가 멈췄거나 결과가 났다).
  static Future<void> end() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in [_active, _room, _count, _since, _last]) {
        await p.remove(k);
      }
    } catch (e) {
      debugPrint('RunMarker.end 실패: $e');
    }
  }

  /// 표시가 남아 있으면 중간에 멈춘 예약의 정보를 돌려준다 (읽기만 하고 지우지는 않는다).
  static Future<InterruptedRun?> readInterrupted() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_active) != true) return null;
      final since = DateTime.tryParse(p.getString(_since) ?? '');
      final last = DateTime.tryParse(p.getString(_last) ?? '') ?? since;
      if (since == null || last == null) return null;
      return InterruptedRun(
        room: p.getString(_room) ?? '',
        seatCount: p.getInt(_count) ?? 0,
        since: since,
        lastCheck: last,
      );
    } catch (e) {
      debugPrint('RunMarker.readInterrupted 실패: $e');
      return null;
    }
  }
}

/// 진행 기록. 줄이 늘어도 메인 화면은 다시 그리지 않고, 기록 화면만 [ChangeNotifier] 로 갱신한다.
class RunLog extends ChangeNotifier {
  static const maxLines = 200;
  final _lines = <String>[];

  int get length => _lines.length;
  String operator [](int i) => _lines[i];

  void add(String line) {
    _lines.add(line);
    if (_lines.length > maxLines) _lines.removeAt(0);
    notifyListeners();
  }
}

/// 잡히지 않은 오류의 최근 기록. 폰에서 문제가 생겼을 때 사용자가 복사해서 보내 줄 수 있게 한다.
class CrashLog {
  static const _key = 'crash_log';
  static const maxEntries = 5;
  static const _maxLen = 900;

  static Future<void> record(Object error, StackTrace? stack, {DateTime? at}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final when = (at ?? DateTime.now()).toIso8601String().substring(0, 19).replaceFirst('T', ' ');
      var text = '$when  $error';
      if (stack != null) text += '\n${stack.toString().split('\n').take(6).join('\n')}';
      if (text.length > _maxLen) text = '${text.substring(0, _maxLen)}…';
      final list = [text, ...(p.getStringList(_key) ?? const <String>[])].take(maxEntries).toList();
      await p.setStringList(_key, list);
    } catch (_) {
      // 오류 기록 중의 오류는 삼킨다 (무한 반복 방지)
    }
  }

  /// 최신순.
  static Future<List<String>> read() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getStringList(_key) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> clear() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_key);
    } catch (_) {}
  }
}
