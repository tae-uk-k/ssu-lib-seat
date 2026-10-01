// 실제 GitHub 릴리스를 PC 에서 조회/다운로드해 보는 확인용 스크립트 (폰 없이 업데이트 경로를 검증한다).
//
//   dart run tools/check_update_live.dart            # 최신 릴리스 조회
//   dart run tools/check_update_live.dart --download # 내려받아 크기/해시까지 검증
import 'dart:io';

import 'package:lib_seat/update_check.dart';

void say(String s) => stdout.writeln(s);

Future<void> main(List<String> args) async {
  final checker = UpdateChecker();
  final info = await checker.latest();
  if (info == null) {
    say('최신 릴리스가 없어요 (릴리스가 없거나 APK 가 없음).');
    return;
  }
  say('최신 버전 : ${info.version}');
  say('APK       : ${info.apkName} (${info.apkSize} bytes)');
  say('SHA-256   : ${info.sha256 ?? '(GitHub 가 해시를 주지 않음)'}');
  say('변경 내용 : ${info.notes.isEmpty ? '(없음)' : info.notes}');
  for (final cur in ['1.0.0', info.version]) {
    say('현재 $cur 이면 업데이트 안내: ${isNewerVersion(cur, info.version)}');
  }
  if (args.contains('--download')) {
    final dir = Directory.systemTemp.createTempSync('lib_seat_update');
    try {
      var last = -1;
      final f = await checker.download(info, dir.path, onProgress: (p) {
        final pct = (p * 100).floor();
        if (pct != last && pct % 25 == 0) {
          last = pct;
          say('  내려받는 중 $pct%');
        }
      });
      say('내려받아 검증 완료: ${f.path} (${await f.length()} bytes)');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
}
