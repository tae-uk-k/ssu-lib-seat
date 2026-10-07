import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// 안드로이드 쪽 기능(포그라운드 서비스, 알림)을 감싼다. 어떤 호출도 예외를 밖으로 던지지 않는다:
// 이 기능들이 실패해도 예약 자체는 계속 돌아야 하고, 시험에서는 가짜로 바꿔 끼울 수 있다.

/// 화면이 꺼져도 예약이 이어지게 하는 포그라운드 서비스.
abstract class BackgroundService {
  /// 앱을 켤 때 한 번.
  Future<void> init();

  /// 알림 권한을 요청한다 (이미 허용돼 있으면 아무 일도 없다).
  Future<void> requestPermission();

  /// 서비스를 시작한다. 이미 떠 있으면 문구만 바꾸고 true. 시작하지 못하면 false.
  Future<bool> start({required String title, required String text});

  /// 알림 문구를 바꾼다.
  Future<void> update({required String title, required String text});
  Future<void> stop();

  /// 서비스가 아직 떠 있는지. 확인에 실패하면 true (살아 있다고 보고 계속한다).
  Future<bool> isAlive();

  /// 배터리 최적화에서 제외돼 있는지. 확인에 실패하면 true (괜한 안내를 띄우지 않는다).
  Future<bool> isBatteryUnrestricted();

  /// "항상 백그라운드에서 실행을 허용할까요?" 시스템 확인 창을 띄우고, 끝난 뒤 제외됐는지를 돌려준다.
  /// 이 창을 못 띄우는 폰이면 배터리 최적화 목록 화면으로 대신 안내한다.
  Future<bool> requestBatteryUnrestricted();
}

/// 예약 결과나 중단을 알리는 알림. 소리/진동이 있는 별도 채널을 쓴다.
abstract class ResultNotifier {
  Future<void> init();
  Future<void> show({required String title, required String body});
}

class AndroidBackgroundService implements BackgroundService {
  // 매니페스트 <application> 의 meta-data 이름. 상태바에는 흰 단색 아이콘이 필요하다.
  static const _icon = NotificationIcon(metaDataName: 'kr.ssu.libseat.NOTIFICATION_ICON');

  /// 서비스 옵션. 시험에서 설정이 슬며시 바뀌지 않았는지 확인하려고 따로 뺐다.
  @visibleForTesting
  static ForegroundTaskOptions taskOptions() => ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        // 예약 루프는 앱 안에서 돈다. 앱이 사라졌는데 서비스만 되살아나 "실행 중" 알림만 남으면 안 된다.
        allowAutoRestart: false,
        // stopWithTask 는 일부러 지정하지 않는다! 여기서 true 로 주면 이 플러그인은 "앱 화면이 하나도 안 보이는 순간"
        // (홈 버튼, 화면 꺼짐, 다른 앱으로 전환) 서비스를 멈춘다 (v1.0.2~1.0.3 에서 홈 버튼만 눌러도 예약이 끝났던 원인).
        // 지정하지 않으면 매니페스트의 android:stopWithTask="true" 를 따라, 최근 앱에서 밀어서 끌 때만 서비스가 같이 끝난다.
      );

  @override
  Future<void> init() async {
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'lib_seat_service',
          channelName: '좌석 예약 실행 중',
          channelDescription: '예약이 실행되는 동안 보이는 알림이에요.',
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: taskOptions(),
      );
    } catch (e) {
      debugPrint('BackgroundService.init 실패: $e');
    }
  }

  @override
  Future<void> requestPermission() async {
    try {
      await FlutterForegroundTask.requestNotificationPermission();
    } catch (e) {
      debugPrint('알림 권한 요청 실패: $e');
    }
  }

  @override
  Future<bool> start({required String title, required String text}) async {
    try {
      final r = await FlutterForegroundTask.startService(
        // 시간 제한이 없는 타입. dataSync 는 안드로이드 15 부터 6시간 뒤에 시스템이 끊는다.
        serviceTypes: [ForegroundServiceTypes.specialUse],
        notificationTitle: title,
        notificationText: text,
        notificationIcon: _icon,
      );
      if (r is ServiceRequestFailure) {
        if (r.error is ServiceAlreadyStartedException) {
          await update(title: title, text: text);
        } else {
          debugPrint('서비스 시작 실패: ${r.error}');
          return false;
        }
      }
      await WakelockPlus.enable();
      return true;
    } catch (e) {
      debugPrint('서비스 시작 중 오류: $e');
      return false;
    }
  }

  @override
  Future<void> update({required String title, required String text}) async {
    try {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
    } catch (e) {
      debugPrint('알림 갱신 실패: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('서비스 종료 실패: $e');
    }
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('wakelock 해제 실패: $e');
    }
  }

  @override
  Future<bool> isAlive() async {
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<bool> isBatteryUnrestricted() async {
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (e) {
      debugPrint('배터리 제한 확인 실패: $e');
      return true;
    }
  }

  @override
  Future<bool> requestBatteryUnrestricted() async {
    try {
      return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (e) {
      debugPrint('배터리 제한 해제 요청 실패: $e');
    }
    try {
      // 목록 화면은 처음에 "최적화 안 함" 앱만 보여 줘서 이 앱이 안 보일 수 있다. 시스템 창이 안 될 때만 쓴다.
      return await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
    } catch (e) {
      debugPrint('배터리 설정 열기 실패: $e');
      return false;
    }
  }
}

class LocalResultNotifier implements ResultNotifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  @override
  Future<void> init() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_notify')),
      );
      _ready = true;
    } catch (e) {
      debugPrint('알림 초기화 실패: $e');
    }
  }

  @override
  Future<void> show({required String title, required String body}) async {
    try {
      if (!_ready) await init();
      await _plugin.show(
        id: 1001, // 고정: 새 결과가 오면 이전 결과 알림을 대체한다
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'lib_seat_result',
            '예약 결과',
            channelDescription: '좌석 배정 결과와 예약이 멈췄다는 알림이에요.',
            importance: Importance.max,
            priority: Priority.high,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
      );
    } catch (e) {
      debugPrint('결과 알림 실패: $e');
    }
  }
}
