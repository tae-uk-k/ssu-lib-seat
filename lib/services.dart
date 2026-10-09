import 'dart:io' show File, Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'auto_renewer.dart';
import 'background.dart';
import 'open_url.dart';
import 'reservation_runner.dart';
import 'run_state.dart';
import 'seat_layout.dart';
import 'update_check.dart';

/// 계정 정보를 기기 안에 암호화해서 보관하는 곳.
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecureStore implements SecureStore {
  // macOS: 서명하지 않은 앱은 "데이터 보호 키체인"(기본값)을 쓸 수 없어서, 기존 로그인 키체인을 쓴다.
  final _s = const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  // 보안 저장소를 못 쓰는 환경이어도 앱은 돌아야 한다. 이때는 이번 실행 동안만 기억하고 디스크에는 남기지 않는다.
  final _memory = <String, String>{};

  @override
  Future<String?> read(String key) async {
    try {
      return await _s.read(key: key) ?? _memory[key];
    } catch (e) {
      debugPrint('보안 저장소 읽기 실패: $e');
      return _memory[key];
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
      _memory.remove(key);
    } catch (e) {
      debugPrint('보안 저장소 쓰기 실패: $e');
      _memory[key] = value;
    }
  }

  @override
  Future<void> delete(String key) async {
    _memory.remove(key);
    try {
      await _s.delete(key: key);
    } catch (e) {
      debugPrint('보안 저장소 지우기 실패: $e');
    }
  }
}

/// 컴퓨터(Windows/macOS/Linux)에서 도는지. 시험에서는 이 값을 [AppServices.desktop] 으로 직접 정한다.
bool get runsOnDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 화면이 기대는 바깥 세계(서버, 백그라운드 서비스, 알림, 저장소)를 한곳에 모은 것.
/// 실제 앱은 [AppServices.real], 시험에서는 가짜를 끼운다.
class AppServices {
  AppServices({
    required this.newApi,
    required this.background,
    required this.notifier,
    required this.secure,
    required this.updater,
    this.layoutFor = _defaultLayout,
    this.policyFor = _defaultPolicy,
    this.renewPolicy = const RenewPolicy(),
    this.logStore = const NoLogStore(),
    this.wrapRoot = _identity,
    this.desktop = false,
    this.openUrl = openInBrowser,
  });

  factory AppServices.real() {
    final desktop = runsOnDesktop;
    return AppServices(
      newApi: LibApi.new,
      background: desktop ? DesktopBackgroundService() : AndroidBackgroundService(),
      notifier: LocalResultNotifier(),
      secure: DeviceSecureStore(),
      updater: UpdateChecker(),
      // 진행 기록은 앱 전용 폴더의 파일에 저장해서, 앱을 껐다 켜도 지난 기록을 볼 수 있다.
      logStore: FileLogStore(() async => File('${(await getApplicationSupportDirectory()).path}/run_log.txt')),
      // 뒤로 가기로 앱을 내리는 플러그인 위젯은 안드로이드 전용이다.
      wrapRoot: desktop ? _identity : (child) => WithForegroundTask(child: child),
      desktop: desktop,
    );
  }

  /// 로그인 안 된 새 API 를 만든다 (다시 로그인할 때마다 새로 만든다).
  final LibraryApi Function() newApi;
  final BackgroundService background;
  final ResultNotifier notifier;
  final SecureStore secure;
  final UpdateChecker updater;

  /// 열람실의 홈페이지 도면. 도면이 없는 열람실은 null.
  final Future<SeatLayout?> Function(int room) layoutFor;

  /// 사용자가 정한 확인 간격으로 예약 정책을 만든다.
  final RunPolicy Function(Duration interval) policyFor;

  /// 자동 연장 시간표 (종료 30분 전부터, 실패하면 5분 뒤 재시도). 시험에서는 아주 짧게 바꿔 끼운다.
  final RenewPolicy renewPolicy;

  /// 진행 기록을 보관하는 곳. 시험에서는 저장하지 않는다.
  final LogStore logStore;

  /// 맨 위 위젯을 감싼다. 실제 앱에서는 뒤로 가기 때 앱을 닫지 않고 내려 주는 플러그인 위젯을 씌운다.
  final Widget Function(Widget child) wrapRoot;

  /// 컴퓨터(Windows/macOS)에서 도는 중인지. 컴퓨터에서는 배터리 안내가 없고, 결과를 늘 시스템 알림으로 알리며,
  /// 업데이트는 APK 설치 대신 내려받는 웹 페이지를 연다.
  final bool desktop;

  /// 웹 주소를 기본 브라우저로 연다 (컴퓨터용 업데이트 안내). 열었으면 true.
  final Future<bool> Function(String url) openUrl;

  static Future<SeatLayout?> _defaultLayout(int room) => SeatLayout.load(room);
  static RunPolicy _defaultPolicy(Duration interval) => RunPolicy(interval: interval);
  static Widget _identity(Widget child) => child;
}
