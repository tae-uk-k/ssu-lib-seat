import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/background.dart';

// 백그라운드 서비스 설정은 폰에서만 확인할 수 있어서, 한 번 겪은 함정을 설정 값으로 지킨다.

void main() {
  test('서비스 옵션에 stopWithTask 를 지정하지 않는다 (지정하면 홈 버튼만 눌러도 서비스가 멈춘다)', () {
    final o = AndroidBackgroundService.taskOptions();
    // flutter_foreground_task 10.0.0 은 이 값이 true 면 앱 화면이 하나도 안 보이는 순간(홈 버튼, 화면 꺼짐) 서비스를 멈춘다.
    expect(o.stopWithTask, isNull);
    expect(o.allowAutoRestart, isFalse); // 앱이 사라졌는데 알림만 남는 서비스를 되살리지 않는다
  });

  test('매니페스트의 서비스는 최근 앱에서 밀어 끌 때 같이 끝나고, 시간 제한 없는 타입이다', () {
    final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final service = RegExp(r'<service[^>]*ForegroundService[^>]*>', dotAll: true).firstMatch(xml)!.group(0)!;
    expect(service, contains('android:stopWithTask="true"'));
    expect(service, contains('android:foregroundServiceType="specialUse"'));
  });
}
