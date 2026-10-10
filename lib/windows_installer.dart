import 'dart:async' show unawaited;
import 'dart:io';

import 'package:archive/archive.dart';

import 'update_check.dart';

// 컴퓨터용(Windows) 앱 안 업데이트.
//
// 실행 중인 프로그램은 자기 파일을 직접 바꿀 수 없어서 이렇게 한다:
//   1) 릴리스의 Windows 압축 파일을 내려받아 크기·해시를 확인하고 임시 폴더에 푼다.
//   2) 풀린 폴더에 앱 실행 파일(ssu_lib_seat.exe)이 제대로 있는지 확인한다.
//   3) "교체 도우미"(PowerShell 스크립트)를 따로 띄우고 앱은 종료한다.
//   4) 도우미가 앱이 끝나길 기다렸다가, 지금 파일을 백업하고, 새 파일로 덮어쓰고, 앱을 다시 켠다.
//      덮어쓰다 실패하면 백업으로 되돌리고 이전 버전을 다시 켠다. 결과는 진행 기록 파일에 한 줄 남긴다.
// 학번·비밀번호와 설정, 진행 기록은 앱 폴더가 아니라 사용자 데이터 폴더에 있어서 바뀌지 않는다.

/// 앱이 스스로 새 버전으로 바뀌는 일. 시험에서는 가짜로 바꿔 끼운다.
abstract class AppInstaller {
  /// 이 앱이 스스로 업데이트할 수 있는지 (Windows 이고, 릴리스에 Windows 파일이 있고, 앱 폴더에 쓸 수 있을 때).
  Future<bool> canInstall(UpdateInfo u);

  /// 새 버전을 내려받아 확인한 뒤, 앱이 끝나면 파일을 바꾸고 다시 켜 줄 도우미를 띄운다. 실패하면 [UpdateException].
  /// 이 함수가 끝나면 호출한 쪽이 **곧바로 앱을 종료**해야 한다 (도우미가 앱의 종료를 기다린다).
  Future<void> installAndRestart(UpdateInfo u, {required String oldVersion, void Function(double)? onProgress});
}

class WindowsInstaller implements AppInstaller {
  WindowsInstaller({
    required this.checker,
    required this.tempDir,
    required this.logFile,
    Directory? appDir,
    int? appPid,
    Future<void> Function(String exe, List<String> args)? spawn,
    bool? isWindows,
  })  : appDir = appDir ?? File(Platform.resolvedExecutable).parent,
        appPid = appPid ?? pid,
        _spawn = spawn ?? _spawnDetached,
        _isWindows = isWindows ?? Platform.isWindows;

  /// 앱 실행 파일 이름 (압축 파일 안에서도 같은 이름이다).
  static const exeName = 'ssu_lib_seat.exe';

  final UpdateChecker checker;

  /// 내려받은 파일과 풀어 놓은 파일을 둘 임시 폴더를 알려 준다.
  final Future<Directory> Function() tempDir;

  /// 진행 기록 파일. 도우미가 결과를 한 줄 덧붙인다.
  final Future<File> Function() logFile;

  /// 지금 실행 중인 앱이 들어 있는 폴더 (여기에 새 파일을 덮어쓴다).
  final Directory appDir;

  /// 도우미가 끝나길 기다릴 앱의 프로세스 번호.
  final int appPid;
  final Future<void> Function(String exe, List<String> args) _spawn;
  final bool _isWindows;

  /// 도우미를 띄운다. 이 앱이 종료돼도 도우미는 계속 돈다.
  /// 주의: `ProcessStartMode.detached`(콘솔 없이 띄우는 방식)로 띄우면 PowerShell 이 아무 일도 하지 않고 끝나 버린다 (이 PC 에서 시험으로 확인함).
  /// 일반 방식으로 띄우면 부모가 끝나도 자식은 계속 돈다. 부모가 살아 있는 동안 출력 통로가 막히지 않게 비워 둔다.
  static Future<void> _spawnDetached(String exe, List<String> args) async {
    final p = await Process.start(exe, args);
    unawaited(p.stdout.drain<void>());
    unawaited(p.stderr.drain<void>());
  }

  static final _sep = Platform.pathSeparator;

  @override
  Future<bool> canInstall(UpdateInfo u) async {
    if (!_isWindows || !u.hasWindowsZip) return false;
    // C:\Program Files 처럼 쓸 수 없는 폴더에 풀어 두었다면 덮어쓸 수 없다.
    try {
      final probe = File('${appDir.path}$_sep.update_write_test');
      await probe.writeAsString('x');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> installAndRestart(UpdateInfo u, {required String oldVersion, void Function(double)? onProgress}) async {
    final tmp = await tempDir();
    final work = Directory('${tmp.path}${_sep}ssu_lib_seat_update');
    try {
      if (await work.exists()) await work.delete(recursive: true);
      await work.create(recursive: true);

      final zip = await checker.downloadWindows(u, work.path, onProgress: onProgress);
      final stage = Directory('${work.path}${_sep}stage');
      await _extract(zip, stage);
      final src = _appRoot(stage);
      if (src == null) throw UpdateException('내려받은 파일에 앱이 제대로 들어 있지 않아요. 다시 시도해 주세요.');

      final script = File('${work.path}${_sep}apply_update.ps1');
      // 한글이 깨지지 않게 BOM 을 붙여 저장한다 (PowerShell 5 는 BOM 이 없으면 한글을 다른 글자로 읽는다).
      await script.writeAsString('\uFEFF$updateScript');
      final log = await logFile();
      await _spawn('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-ProcId',
        '$appPid',
        '-Src',
        src.path,
        '-Dst',
        appDir.path,
        '-Exe',
        exeName,
        '-Log',
        log.path,
        '-Version',
        u.version,
        '-Old',
        oldVersion,
        '-Work',
        work.path,
      ]);
    } on UpdateException {
      await _cleanup(work);
      rethrow;
    } catch (e) {
      await _cleanup(work);
      throw UpdateException('업데이트를 준비하지 못했어요. ($e)');
    }
  }

  Future<void> _cleanup(Directory work) async {
    try {
      if (await work.exists()) await work.delete(recursive: true);
    } catch (_) {}
  }

  /// 압축 파일을 [dest] 에 푼다. 폴더 밖으로 나가는 경로(.., 드라이브, 절대 경로)가 있으면 풀지 않고 거부한다.
  Future<void> _extract(File zip, Directory dest) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    } catch (_) {
      throw UpdateException('내려받은 압축 파일을 열지 못했어요. 다시 시도해 주세요.');
    }
    // 압축 파일이 아닌 글을 줘도 오류 없이 빈 목록이 나올 수 있다.
    if (archive.files.isEmpty) throw UpdateException('내려받은 압축 파일을 열지 못했어요. 다시 시도해 주세요.');
    final root = dest.absolute.path;
    for (final f in archive.files) {
      final name = f.name.replaceAll('\\', '/');
      if (name.startsWith('/') || name.contains(':') || name.split('/').contains('..')) {
        throw UpdateException('압축 파일 안의 경로가 이상해서 풀지 않았어요.');
      }
      final target = '$root$_sep${name.replaceAll('/', _sep)}';
      if (f.isFile) {
        final file = File(target);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(f.content);
      } else {
        await Directory(target).create(recursive: true);
      }
    }
  }

  /// 풀린 곳에서 앱 폴더(실행 파일, 엔진 DLL, data 폴더가 모두 있는 곳)를 찾는다. 압축 파일은 `SSU-LibSeat/` 한 겹 안에 들어 있다.
  static Directory? _appRoot(Directory stage) {
    bool isApp(Directory d) =>
        File('${d.path}$_sep$exeName').existsSync() &&
        File('${d.path}${_sep}flutter_windows.dll').existsSync() &&
        Directory('${d.path}${_sep}data').existsSync();
    if (!stage.existsSync()) return null;
    if (isApp(stage)) return stage;
    for (final e in stage.listSync()) {
      if (e is Directory && isApp(e)) return e;
    }
    return null;
  }
}

/// 교체 도우미 스크립트 (PowerShell). 앱이 끝나길 기다렸다가 현재 파일을 백업하고, 새 파일로 덮어쓰고, 앱을 다시 켠다.
/// 실패하면 백업으로 되돌린 뒤 이전 버전을 다시 켠다. 결과는 진행 기록 파일에 "MM-dd HH:mm:ss  내용" 한 줄로 덧붙인다.
const updateScript = r'''
param(
  [int]$ProcId,
  [string]$Src,
  [string]$Dst,
  [string]$Exe,
  [string]$Log,
  [string]$Version,
  [string]$Old,
  [string]$Work,
  [int]$Retries = 10
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Log([string]$m) {
  try {
    $t = Get-Date -Format 'MM-dd HH:mm:ss'
    [IO.File]::AppendAllText($Log, "$t  $m`n", (New-Object Text.UTF8Encoding($false)))
  } catch {}
}

$backup = Join-Path $Work 'backup'
$swapped = $false
try {
  # 1) 앱이 끝나길 기다린다 (최대 60초). 끝나기 전에 파일을 바꾸면 안 된다.
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Process -Id $ProcId -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
    Start-Sleep -Milliseconds 300
  }
  if (Get-Process -Id $ProcId -ErrorAction SilentlyContinue) { throw '앱이 끝나지 않았어요' }

  # 2) 지금 파일을 백업해 둔다 (바꾸다 실패하면 되돌리려고).
  New-Item -ItemType Directory -Force -Path $backup | Out-Null
  Copy-Item -Path (Join-Path $Dst '*') -Destination $backup -Recurse -Force

  # 3) 새 파일로 덮어쓴다. 방금 끝난 앱의 파일이 잠시 잠겨 있을 수 있어서 몇 번 다시 시도한다.
  $last = ''
  for ($i = 1; ($i -le $Retries) -and (-not $swapped); $i++) {
    try {
      Copy-Item -Path (Join-Path $Src '*') -Destination $Dst -Recurse -Force
      $swapped = $true
    } catch {
      $last = $_.Exception.Message
      Start-Sleep -Seconds 1
    }
  }
  if (-not $swapped) { throw $last }
  Write-Log "앱을 새 버전으로 바꿨어요 ($Old -> $Version)"
} catch {
  $why = $_.Exception.Message
  try {
    if (Test-Path $backup) { Copy-Item -Path (Join-Path $backup '*') -Destination $Dst -Recurse -Force }
  } catch {}
  Write-Log "앱 업데이트에 실패해서 이전 버전으로 되돌렸어요 ($why)"
}

# 4) 앱을 다시 켠다 (새 버전이든, 되돌린 이전 버전이든).
try {
  Start-Process -FilePath (Join-Path $Dst $Exe) -WorkingDirectory $Dst
} catch {
  Write-Log "앱을 다시 켜지 못했어요 ($($_.Exception.Message))"
}
try { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
''';
