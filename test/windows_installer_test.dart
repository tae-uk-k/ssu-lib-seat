import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/update_check.dart';
import 'package:lib_seat/windows_installer.dart';

/// 정해 둔 주소에 정해 둔 파일을 내려 주는 가짜 서버.
class _Files implements HttpClientAdapter {
  _Files(this.files);
  final Map<String, List<int>> files;

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async {
    final data = files[o.uri.toString()];
    if (data == null) return ResponseBody.fromString('not found', 404);
    return ResponseBody.fromBytes(data, 200, headers: {
      Headers.contentLengthHeader: ['${data.length}'],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// 릴리스 압축 파일을 흉내 낸다: `SSU-LibSeat/` 한 겹 안에 앱 파일들이 있다.
List<int> _zip({bool withExe = true, bool withData = true, List<String> extraNames = const []}) {
  const root = 'SSU-LibSeat';
  final a = Archive();
  if (withExe) a.addFile(ArchiveFile.bytes('$root/ssu_lib_seat.exe', utf8.encode('NEW-EXE')));
  a.addFile(ArchiveFile.bytes('$root/flutter_windows.dll', utf8.encode('ENGINE-NEW')));
  if (withData) a.addFile(ArchiveFile.bytes('$root/data/app.so', utf8.encode('DATA-NEW')));
  a.addFile(ArchiveFile.bytes('$root/읽어주세요.txt', utf8.encode('새 설명')));
  for (final n in extraNames) {
    a.addFile(ArchiveFile.bytes(n, utf8.encode('x')));
  }
  return ZipEncoder().encodeBytes(a);
}

UpdateInfo _info(List<int> zip, {String? sha, bool windows = true}) => UpdateInfo(
      version: '9.9.9',
      apkName: 'ssu-lib-seat-9.9.9.apk',
      apkUrl: 'https://x/a.apk',
      apkSize: 3,
      sha256: null,
      notes: '',
      windowsName: windows ? 'ssu-lib-seat-9.9.9-windows.zip' : '',
      windowsUrl: windows ? 'https://x/w.zip' : '',
      windowsSize: windows ? zip.length : 0,
      windowsSha256: sha,
    );

Future<String> _shaOf(List<int> bytes) async {
  final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}sha_${DateTime.now().microsecondsSinceEpoch}')..writeAsBytesSync(bytes);
  try {
    return await sha256OfFile(f);
  } finally {
    f.deleteSync();
  }
}

void main() {
  late Directory root;
  late Directory app; // 지금 쓰는 앱이 들어 있는 폴더
  late Directory temp;
  late File log;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ssu_installer_test');
    app = Directory('${root.path}/app')..createSync();
    temp = Directory('${root.path}/tmp')..createSync();
    log = File('${root.path}/run_log.txt');
    File('${app.path}/ssu_lib_seat.exe').writeAsStringSync('OLD-EXE');
    File('${app.path}/flutter_windows.dll').writeAsStringSync('ENGINE-OLD');
    Directory('${app.path}/data').createSync();
    File('${app.path}/data/app.so').writeAsStringSync('DATA-OLD');
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  WindowsInstaller installer(UpdateChecker checker, {List<List<String>>? spawned, bool windows = true, Directory? appDir}) => WindowsInstaller(
        checker: checker,
        tempDir: () async => temp,
        logFile: () async => log,
        appDir: appDir ?? app,
        appPid: 4242,
        isWindows: windows,
        spawn: (exe, args) async => spawned?.add([exe, ...args]),
      );

  UpdateChecker serving(List<int> zip) => UpdateChecker(dio: Dio()..httpClientAdapter = _Files({'https://x/w.zip': zip}));

  group('canInstall', () {
    test('Windows 이고 릴리스에 Windows 파일이 있고 앱 폴더에 쓸 수 있으면 true', () async {
      final z = _zip();
      expect(await installer(serving(z)).canInstall(_info(z)), isTrue);
      expect(File('${app.path}/.update_write_test').existsSync(), isFalse, reason: '확인용 파일은 남기지 않는다');
    });

    test('릴리스에 Windows 파일이 없으면 false', () async {
      final z = _zip();
      expect(await installer(serving(z)).canInstall(_info(z, windows: false)), isFalse);
    });

    test('Windows 가 아니면 false (맥은 다운로드 페이지를 연다)', () async {
      final z = _zip();
      expect(await installer(serving(z), windows: false).canInstall(_info(z)), isFalse);
    });

    test('앱 폴더에 쓸 수 없으면 false', () async {
      final z = _zip();
      final missing = Directory('${root.path}/없는폴더');
      expect(await installer(serving(z), appDir: missing).canInstall(_info(z)), isFalse);
    });
  });

  group('installAndRestart: 내려받기, 풀기, 확인', () {
    test('내려받아 풀고, 도우미를 올바른 인자로 띄운다', () async {
      final z = _zip();
      final spawned = <List<String>>[];
      final progress = <double>[];
      await installer(serving(z), spawned: spawned)
          .installAndRestart(_info(z, sha: await _shaOf(z)), oldVersion: '1.0.7', onProgress: progress.add);

      expect(spawned, hasLength(1));
      final args = spawned.single;
      expect(args.first, 'powershell.exe');
      String arg(String name) => args[args.indexOf(name) + 1];
      expect(arg('-ProcId'), '4242');
      expect(arg('-Dst'), app.path);
      expect(arg('-Exe'), 'ssu_lib_seat.exe');
      expect(arg('-Log'), log.path);
      expect(arg('-Version'), '9.9.9');
      expect(arg('-Old'), '1.0.7');
      expect(args, containsAll(['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden']));
      // 새 파일은 임시 폴더에 풀려 있고 (한글 이름 포함), 지금 앱 폴더는 아직 그대로다
      final src = Directory(arg('-Src'));
      expect(File('${src.path}/ssu_lib_seat.exe').readAsStringSync(), 'NEW-EXE');
      expect(File('${src.path}/data/app.so').readAsStringSync(), 'DATA-NEW');
      expect(File('${src.path}/읽어주세요.txt').readAsStringSync(), '새 설명');
      expect(File('${app.path}/ssu_lib_seat.exe').readAsStringSync(), 'OLD-EXE');
      // 스크립트는 한글이 깨지지 않게 BOM 이 붙어 있다
      final script = File(arg('-File')).readAsBytesSync();
      expect(script.take(3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(script.skip(3).toList()), contains('앱을 새 버전으로 바꿨어요'));
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
    });

    test('해시가 다르면 거부하고, 임시 파일을 남기지 않고, 도우미도 띄우지 않는다', () async {
      final z = _zip();
      final spawned = <List<String>>[];
      await expectLater(
        installer(serving(z), spawned: spawned).installAndRestart(_info(z, sha: 'a' * 64), oldVersion: '1.0.7'),
        throwsA(isA<UpdateException>().having((e) => e.message, '메시지', contains('올바르지 않아요'))),
      );
      expect(spawned, isEmpty);
      expect(Directory('${temp.path}/ssu_lib_seat_update').existsSync(), isFalse);
    });

    test('앱 실행 파일이 없는 압축 파일은 거부한다', () async {
      final z = _zip(withExe: false);
      final spawned = <List<String>>[];
      await expectLater(
        installer(serving(z), spawned: spawned).installAndRestart(_info(z, sha: await _shaOf(z)), oldVersion: '1.0.7'),
        throwsA(isA<UpdateException>().having((e) => e.message, '메시지', contains('제대로 들어 있지 않아요'))),
      );
      expect(spawned, isEmpty);
    });

    test('data 폴더가 없는 압축 파일도 거부한다 (반쪽짜리 앱으로 덮어쓰지 않게)', () async {
      final z = _zip(withData: false);
      await expectLater(
        installer(serving(z)).installAndRestart(_info(z, sha: await _shaOf(z)), oldVersion: '1.0.7'),
        throwsA(isA<UpdateException>()),
      );
    });

    test('폴더 밖으로 나가는 경로가 든 압축 파일은 풀지 않는다', () async {
      final z = _zip(extraNames: ['../escape.txt']);
      await expectLater(
        installer(serving(z)).installAndRestart(_info(z, sha: await _shaOf(z)), oldVersion: '1.0.7'),
        throwsA(isA<UpdateException>().having((e) => e.message, '메시지', contains('경로가 이상해서'))),
      );
      expect(File('${temp.path}/escape.txt').existsSync(), isFalse);
      expect(File('${root.path}/escape.txt').existsSync(), isFalse);
    });

    test('압축 파일이 아니면 거부한다', () async {
      final z = utf8.encode('이건 zip 이 아니에요');
      await expectLater(
        installer(serving(z)).installAndRestart(_info(z, sha: await _shaOf(z)), oldVersion: '1.0.7'),
        throwsA(isA<UpdateException>().having((e) => e.message, '메시지', contains('열지 못했어요'))),
      );
    });

    test('압축 파일 안에 한 겹 폴더가 없어도(바로 앱 파일) 찾는다', () async {
      final a = Archive()
        ..addFile(ArchiveFile.bytes('ssu_lib_seat.exe', utf8.encode('NEW-EXE')))
        ..addFile(ArchiveFile.bytes('flutter_windows.dll', utf8.encode('E')))
        ..addFile(ArchiveFile.bytes('data/app.so', utf8.encode('D')));
      final flat = ZipEncoder().encodeBytes(a);
      final spawned = <List<String>>[];
      await installer(serving(flat), spawned: spawned).installAndRestart(_info(flat, sha: await _shaOf(flat)), oldVersion: '1.0.7');
      expect(spawned, hasLength(1));
    });

    test('릴리스에 Windows 파일이 없으면 UpdateException', () async {
      final z = _zip();
      await expectLater(
        installer(serving(z)).installAndRestart(_info(z, windows: false), oldVersion: '1.0.7'),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  group('교체 도우미 (실제 PowerShell 로 실행)', () {
    final onWindows = Platform.isWindows;

    // "다시 켰는지"는 앱 실행 파일 대신 "켜지면 표시 파일을 만드는" 작은 스크립트를 켜게 해서 확인한다.
    String restartScript(String who) => '@echo off\r\necho $who> "%~dp0restarted.txt"\r\n';

    Directory newFiles() {
      final src = Directory('${root.path}/src')..createSync();
      File('${src.path}/flutter_windows.dll').writeAsStringSync('ENGINE-NEW');
      Directory('${src.path}/data').createSync();
      File('${src.path}/data/app.so').writeAsStringSync('DATA-NEW');
      File('${src.path}/읽어주세요.txt').writeAsStringSync('새 설명');
      File('${src.path}/restart.cmd').writeAsStringSync(restartScript('new'));
      return src;
    }

    /// 실제로 도우미를 돌린다. 앱 프로세스를 흉내 내는 짧은 프로세스(ping 몇 번)가 끝나야 파일을 바꾸기 시작한다.
    Future<void> runHelper(Directory src, {int retries = 10}) async {
      final work = Directory('${root.path}/work')..createSync(recursive: true);
      final script = File('${work.path}/apply_update.ps1')..writeAsStringSync('﻿$updateScript');
      final fakeApp = await Process.start('ping', ['-n', '4', '127.0.0.1']); // 3초쯤 뒤 끝난다
      final helper = await Process.start('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path,
        '-ProcId', '${fakeApp.pid}', '-Src', src.path, '-Dst', app.path, '-Exe', 'restart.cmd', '-Log', log.path,
        '-Version', '9.9.9', '-Old', '1.0.7', '-Work', work.path, '-Retries', '$retries',
      ]);
      // 도우미는 앱이 끝나기 전에는 아무것도 바꾸지 않아야 한다.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(File('${app.path}/flutter_windows.dll').readAsStringSync(), 'ENGINE-OLD', reason: '앱이 끝나기 전에는 파일을 바꾸지 않는다');
      await fakeApp.exitCode;
      expect(await helper.exitCode.timeout(const Duration(seconds: 60)), 0);
    }

    /// 다시 켠 스크립트가 표시 파일을 만들 때까지 기다렸다가 내용을 돌려준다.
    Future<String> restartedBy() async {
      final marker = File('${app.path}/restarted.txt');
      for (var i = 0; i < 50 && !marker.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return marker.existsSync() ? marker.readAsStringSync().trim() : '(다시 켜지지 않았어요)';
    }

    setUp(() => File('${app.path}/restart.cmd').writeAsStringSync(restartScript('old')));

    test('앱이 끝나면 파일을 새 것으로 바꾸고, 새 앱을 다시 켜고, 결과를 진행 기록에 남기고, 임시 폴더를 정리한다', () async {
      await runHelper(newFiles());

      expect(File('${app.path}/flutter_windows.dll').readAsStringSync(), 'ENGINE-NEW');
      expect(File('${app.path}/data/app.so').readAsStringSync(), 'DATA-NEW');
      expect(File('${app.path}/읽어주세요.txt').readAsStringSync(), '새 설명');
      expect(await restartedBy(), 'new'); // 새 버전이 켜졌다
      expect(Directory('${root.path}/work').existsSync(), isFalse);
      final lines = log.readAsLinesSync();
      expect(lines, hasLength(1));
      expect(lines.single, matches(RegExp(r'^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}  앱을 새 버전으로 바꿨어요 \(1\.0\.7 -> 9\.9\.9\)$')));
    }, skip: onWindows ? false : 'Windows 에서만 시험할 수 있어요');

    test('덮어쓰다 중간에 실패하면 이미 바뀐 파일까지 백업으로 되돌리고, 이전 앱을 다시 켜고, 실패를 기록에 남긴다', () async {
      // 이름순으로 뒤에 오는 zz_locked.dll 을 다른 프로세스가 쓰지 못하게 잡아 둔다 (읽기만 허용) -> 그 파일에서 덮어쓰기가 실패한다.
      // 그보다 앞선 flutter_windows.dll 과 restart.cmd 는 이미 새 것으로 바뀐 뒤라서, 되돌리기가 제대로 되는지 볼 수 있다.
      final src = newFiles();
      File('${src.path}/zz_locked.dll').writeAsStringSync('LOCKED-NEW');
      final locked = File('${app.path}/zz_locked.dll')..writeAsStringSync('LOCKED-OLD');
      final holder = await Process.start('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-Command',
        "\$f = [IO.File]::Open('${locked.path}', 'Open', 'Read', 'Read'); Write-Output 'locked'; Start-Sleep -Seconds 120",
      ]);
      addTearDown(holder.kill);
      await holder.stdout.transform(utf8.decoder).firstWhere((t) => t.contains('locked')).timeout(const Duration(seconds: 20));

      await runHelper(src, retries: 2);

      expect(File('${app.path}/flutter_windows.dll').readAsStringSync(), 'ENGINE-OLD', reason: '이미 바뀐 파일도 되돌려진다');
      expect(File('${app.path}/data/app.so').readAsStringSync(), 'DATA-OLD');
      expect(locked.readAsStringSync(), 'LOCKED-OLD');
      expect(await restartedBy(), 'old'); // 이전 버전이 다시 켜졌다
      expect(log.readAsStringSync(), contains('앱 업데이트에 실패해서 이전 버전으로 되돌렸어요'));
      expect(log.readAsStringSync(), isNot(contains('새 버전으로 바꿨어요')));
      expect(Directory('${root.path}/work').existsSync(), isFalse);
    }, skip: onWindows ? false : 'Windows 에서만 시험할 수 있어요');

    test('앱이 끝나지 않으면(60초) 아무것도 바꾸지 않는다는 보장은 시간이 너무 길어 시험하지 않고, 스크립트에 있는지만 본다', () {
      expect(updateScript, contains('AddSeconds(60)'));
      expect(updateScript, contains('앱이 끝나지 않았어요'));
    });
  });
}
