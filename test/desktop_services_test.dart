import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/background.dart';
import 'package:lib_seat/open_url.dart';
import 'package:lib_seat/services.dart';

// 컴퓨터(Windows/macOS)용으로 갈라진 부분. 플러그인이 없는 시험 환경에서도 예외 없이 동작해야 한다.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopBackgroundService', () {
    test('시작하면 true, 항상 살아 있고, 배터리 제한은 없다', () async {
      final s = DesktopBackgroundService();
      await s.init();
      await s.requestPermission();
      // 잠자기 방지 플러그인이 없어도(시험 환경) 예외 없이 시작은 성공한다.
      expect(await s.start(title: '좌석 예약 실행 중', text: '시작'), isTrue);
      await s.update(title: 'a', text: 'b');
      expect(await s.isAlive(), isTrue);
      expect(await s.isBatteryUnrestricted(), isTrue);
      expect(await s.requestBatteryUnrestricted(), isTrue);
      await s.stop(); // 예외 없이 끝난다
    });
  });

  group('DeviceSecureStore (보안 저장소를 못 쓰는 환경)', () {
    // 시험 환경에는 보안 저장소 플러그인이 없어 모든 호출이 실패한다 → 이번 실행 동안만 기억하는 쪽으로 물러선다.
    test('쓰고 읽고 지울 수 있다 (디스크에는 남기지 않는다)', () async {
      final s = DeviceSecureStore();
      expect(await s.read('id'), isNull);
      await s.write('id', '20240001');
      expect(await s.read('id'), '20240001');
      await s.write('id', '20240002');
      expect(await s.read('id'), '20240002');
      await s.delete('id');
      expect(await s.read('id'), isNull);
    });
  });

  group('openInBrowser', () {
    test('웹 주소가 아니면 열지 않는다 (서버가 준 주소를 그대로 열기 때문에)', () async {
      expect(await openInBrowser('file:///C:/Windows/System32/calc.exe'), isFalse);
      expect(await openInBrowser('javascript:alert(1)'), isFalse);
      expect(await openInBrowser('ms-settings:developers'), isFalse);
      expect(await openInBrowser('이상한 주소'), isFalse);
      expect(await openInBrowser(''), isFalse);
    });
  });
}
