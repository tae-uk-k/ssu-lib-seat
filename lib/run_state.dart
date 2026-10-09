import 'dart:io';

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

/// 진행 기록을 보관하는 곳. 앱을 껐다 켜거나 시스템이 앱을 종료해도 "그동안 무슨 일이 있었는지" 볼 수 있게 한다.
/// 어떤 호출도 예외를 밖으로 던지지 않는다 (기록을 못 남겨도 앱은 계속 돌아야 한다).
abstract class LogStore {
  /// 저장된 기록 (오래된 것부터). 읽지 못하면 빈 목록.
  Future<List<String>> load();

  /// 한 줄을 덧붙인다.
  void append(String line);

  Future<void> clear();
}

/// 저장하지 않는다 (시험, 저장 위치를 못 찾았을 때).
class NoLogStore implements LogStore {
  const NoLogStore();
  @override
  Future<List<String>> load() async => const [];
  @override
  void append(String line) {}
  @override
  Future<void> clear() async {}
}

/// 한 줄에 기록 하나씩 파일에 덧붙여 저장한다. 파일이 너무 길어지면 앱을 켤 때 최근 것만 남긴다.
class FileLogStore implements LogStore {
  /// [file] 은 파일 위치를 알려 주는 함수다 (앱 폴더를 찾는 일이 비동기라서).
  FileLogStore(this._file, {this.keep = RunLog.maxLines});

  final Future<File> Function() _file;
  final int keep;

  /// 쓰기를 한 줄씩 차례로 하려고 이어 붙인다.
  Future<void> _chain = Future.value();

  @override
  Future<List<String>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const [];
      final lines = (await f.readAsString()).split('\n').where((l) => l.isNotEmpty).toList();
      final tail = lines.length > keep ? lines.sublist(lines.length - keep) : lines;
      // 최근 것만으로 줄여 쓰는 건 파일이 한참 넘쳤을 때만 한다 (켤 때마다 다시 쓰지 않으려고).
      if (lines.length > keep + keep ~/ 2) await f.writeAsString('${tail.join('\n')}\n');
      return tail;
    } catch (e) {
      debugPrint('진행 기록을 읽지 못했어요: $e');
      return const [];
    }
  }

  @override
  void append(String line) {
    _chain = _chain.then((_) async {
      final f = await _file();
      await f.writeAsString('$line\n', mode: FileMode.append);
    }).catchError((Object e) {
      debugPrint('진행 기록을 저장하지 못했어요: $e');
    });
  }

  /// 지금까지 요청한 저장이 모두 끝날 때까지 기다린다.
  Future<void> flush() => _chain;

  @override
  Future<void> clear() {
    _chain = _chain.then((_) async {
      final f = await _file();
      if (await f.exists()) await f.writeAsString('');
    }).catchError((Object e) {
      debugPrint('진행 기록을 지우지 못했어요: $e');
    });
    return _chain;
  }
}

/// 진행 기록. 줄이 늘어도 메인 화면은 다시 그리지 않고, 기록 화면만 [ChangeNotifier] 로 갱신한다.
/// [store] 가 있으면 앱을 켤 때 지난 기록을 불러오고([restore]), 새 기록은 곧바로 저장한다.
class RunLog extends ChangeNotifier {
  RunLog({this.store}) : _restored = store == null;

  static const maxLines = 1500;
  final LogStore? store;
  final _lines = <String>[];
  bool _restored;

  /// 지난 기록을 불러오기 전에 들어온 줄. 불러온 뒤 순서대로 이어 붙인다.
  final _early = <String>[];

  int get length => _lines.length;
  String operator [](int i) => _lines[i];

  /// 복사해서 보낼 수 있는 전체 글 (오래된 것부터).
  String get text => _lines.join('\n');

  void add(String line) {
    final one = line.replaceAll(RegExp(r'\s*\n\s*'), ' / '); // 한 줄에 하나씩 저장하므로 줄바꿈은 없앤다
    if (_restored) {
      _push(one);
      store?.append(one);
    } else {
      _early.add(one); // 아직 지난 기록을 읽는 중이다
      _push(one);
    }
    notifyListeners();
  }

  void _push(String line) {
    _lines.add(line);
    if (_lines.length > maxLines) _lines.removeAt(0);
  }

  /// 앱을 켤 때 한 번: 저장된 지난 기록을 앞에 붙인다. 그동안 쌓인 새 기록은 그 뒤에 그대로 둔다.
  Future<void> restore() async {
    final s = store;
    if (s == null || _restored) return;
    final old = await s.load();
    final early = List<String>.of(_early);
    _early.clear();
    _restored = true;
    _lines.insertAll(0, old);
    if (_lines.length > maxLines) _lines.removeRange(0, _lines.length - maxLines);
    for (final l in early) {
      s.append(l);
    }
    notifyListeners();
  }

  Future<void> clear() async {
    _lines.clear();
    _early.clear();
    notifyListeners();
    await store?.clear();
  }
}

/// 잡히지 않은 오류의 최근 기록. 폰에서 문제가 생겼을 때 사용자가 복사해서 보내 줄 수 있게 한다.
class CrashLog {
  /// 오류가 기록될 때마다 한 줄 요약을 받는다 (화면이 진행 기록에도 남기려고 쓴다).
  static void Function(String summary)? listener;

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
      listener?.call('$error');
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
