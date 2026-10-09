import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/run_state.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('run_log_test');
    file = File('${dir.path}/run_log.txt');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  FileLogStore store({int keep = 1500}) => FileLogStore(() async => file, keep: keep);

  group('FileLogStore', () {
    test('한 줄씩 덧붙여 저장하고, 새로 열어도 순서대로 읽힌다 (한글 포함)', () async {
      final s = store();
      s.append('10-09 09:00:00  첫째 줄');
      s.append('10-09 09:00:01  둘째 줄');
      await s.flush();
      expect(await store().load(), ['10-09 09:00:00  첫째 줄', '10-09 09:00:01  둘째 줄']);
    });

    test('파일이 없으면 빈 목록이다', () async {
      expect(await store().load(), isEmpty);
    });

    test('너무 길면 최근 것만 돌려주고, 한참 넘쳤을 때만 파일을 줄여 쓴다', () async {
      file.writeAsStringSync('${List.generate(20, (i) => '줄$i').join('\n')}\n');
      final tail = await store(keep: 5).load();
      expect(tail, ['줄15', '줄16', '줄17', '줄18', '줄19']);
      // 20줄은 keep(5)의 1.5배(7)를 넘어서 파일도 최근 것만 남는다
      expect(file.readAsLinesSync(), ['줄15', '줄16', '줄17', '줄18', '줄19']);

      // 조금 넘친 정도(6줄, 7 이하)는 읽기만 하고 파일은 그대로 둔다
      file.writeAsStringSync('${List.generate(6, (i) => '줄$i').join('\n')}\n');
      expect(await store(keep: 5).load(), ['줄1', '줄2', '줄3', '줄4', '줄5']);
      expect(file.readAsLinesSync(), hasLength(6));
    });

    test('지우면 비어 있다', () async {
      final s = store();
      s.append('지울 기록');
      await s.flush();
      await s.clear();
      expect(await store().load(), isEmpty);
    });

    test('저장할 수 없는 곳이어도 예외를 던지지 않는다 (기록 때문에 앱이 멈추면 안 된다)', () async {
      final bad = FileLogStore(() async => File('${dir.path}/없는폴더/아래/run_log.txt'));
      bad.append('저장 안 됨');
      await bad.flush();
      expect(await bad.load(), isEmpty);
      await bad.clear();
    });
  });

  group('RunLog', () {
    test('저장소가 없으면 메모리에만 쌓이고 최대 줄 수를 넘으면 오래된 것부터 버린다', () {
      final log = RunLog();
      for (var i = 0; i < RunLog.maxLines + 5; i++) {
        log.add('줄$i');
      }
      expect(log.length, RunLog.maxLines);
      expect(log[0], '줄5');
      expect(log[log.length - 1], '줄${RunLog.maxLines + 4}');
    });

    test('줄바꿈이 든 기록은 한 줄로 저장된다', () async {
      final s = store();
      final log = RunLog(store: s);
      await log.restore();
      log.add('첫 줄\n  둘째 줄\r\n셋째');
      await s.flush();
      expect(log[0], '첫 줄 / 둘째 줄 / 셋째');
      expect(file.readAsLinesSync(), ['첫 줄 / 둘째 줄 / 셋째']);
    });

    test('지난 기록은 앞에 붙고, 불러오기 전에 쌓인 새 기록은 뒤에 그대로 있으며 중복 저장되지 않는다', () async {
      file.writeAsStringSync('어제1\n어제2\n');
      final s = store();
      final log = RunLog(store: s);
      log.add('켜자마자1'); // 아직 불러오기 전
      log.add('켜자마자2');
      await log.restore();
      log.add('그 뒤');
      await s.flush();
      expect([for (var i = 0; i < log.length; i++) log[i]], ['어제1', '어제2', '켜자마자1', '켜자마자2', '그 뒤']);
      expect(file.readAsLinesSync(), ['어제1', '어제2', '켜자마자1', '켜자마자2', '그 뒤']); // 새 기록이 한 번씩만 저장됐다
    });

    test('복사용 글은 오래된 것부터 줄바꿈으로 이어진다', () async {
      final log = RunLog();
      log.add('a');
      log.add('b');
      expect(log.text, 'a\nb');
    });

    test('지우면 화면과 저장소가 모두 비고, 변화를 알린다', () async {
      final s = store();
      final log = RunLog(store: s);
      await log.restore();
      log.add('x');
      var notified = 0;
      log.addListener(() => notified++);
      await log.clear();
      expect(log.length, 0);
      expect(notified, greaterThan(0));
      expect(await store().load(), isEmpty);
    });

    test('기록이 쌓일 때마다 구독자에게 알린다', () {
      final log = RunLog();
      var n = 0;
      log.addListener(() => n++);
      log.add('a');
      log.add('b');
      expect(n, 2);
    });
  });
}
