import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'background.dart';
import 'reservation_runner.dart';
import 'seat_layout.dart';
import 'update_check.dart';

/// 계정 정보를 기기 안에 암호화해서 보관하는 곳.
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecureStore implements SecureStore {
  final _s = const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

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
    this.wrapRoot = _identity,
  });

  factory AppServices.real() => AppServices(
        newApi: LibApi.new,
        background: AndroidBackgroundService(),
        notifier: LocalResultNotifier(),
        secure: DeviceSecureStore(),
        updater: UpdateChecker(),
        wrapRoot: (child) => WithForegroundTask(child: child),
      );

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

  /// 맨 위 위젯을 감싼다. 실제 앱에서는 뒤로 가기 때 앱을 닫지 않고 내려 주는 플러그인 위젯을 씌운다.
  final Widget Function(Widget child) wrapRoot;

  static Future<SeatLayout?> _defaultLayout(int room) => SeatLayout.load(room);
  static RunPolicy _defaultPolicy(Duration interval) => RunPolicy(interval: interval);
  static Widget _identity(Widget child) => child;
}
