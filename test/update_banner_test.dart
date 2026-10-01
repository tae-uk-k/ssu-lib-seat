import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/widgets.dart';

Widget _host(UpdateBanner b) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: b)));

void main() {
  testWidgets('새 버전 안내: 버전과 변경 내용이 보이고 버튼이 동작한다', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(UpdateBanner(
      currentVersion: '1.0.1',
      newVersion: '1.0.2',
      notes: '좌석 밑에 남은 시간 표시',
      onUpdate: () => taps++,
    )));
    expect(find.text('새 버전 1.0.2이 나왔어요'), findsOneWidget);
    expect(find.text('지금 쓰는 버전 1.0.1'), findsOneWidget);
    expect(find.text('좌석 밑에 남은 시간 표시'), findsOneWidget);
    await tester.tap(find.text('업데이트'));
    expect(taps, 1);
  });

  testWidgets('예약이 도는 중에는 업데이트 버튼이 막힌다', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(UpdateBanner(currentVersion: '1.0.1', newVersion: '1.0.2', blocked: true, onUpdate: () => taps++)));
    await tester.tap(find.text('업데이트'), warnIfMissed: false);
    expect(taps, 0);
    expect(find.textContaining('예약을 멈춘 뒤에'), findsOneWidget);
  });

  testWidgets('내려받는 중에는 진행률이 보이고 버튼은 사라진다', (tester) async {
    await tester.pumpWidget(_host(UpdateBanner(currentVersion: '1.0.1', newVersion: '1.0.2', busy: true, progress: 0.37, onUpdate: () {})));
    expect(find.text('내려받는 중 37%'), findsOneWidget);
    expect(find.text('업데이트'), findsNothing);
    await tester.pumpWidget(_host(UpdateBanner(currentVersion: '1.0.1', newVersion: '1.0.2', busy: true, onUpdate: () {})));
    expect(find.text('준비하는 중…'), findsOneWidget);
  });
}
