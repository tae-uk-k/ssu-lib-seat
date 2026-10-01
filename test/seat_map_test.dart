import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/seat_layout.dart';
import 'package:lib_seat/seat_map.dart';

List<Seat> _seats(int n) => [for (var i = 0; i < n; i++) Seat(id: i, code: '${i + 1}', active: true, occupied: false)];

/// 손가락처럼 이동 이벤트를 나눠 보낸다 (한 번에 보내면 제스처 시작 위치만 바뀌고 이동이 안 잡힌다).
Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final g = await tester.startGesture(from);
  for (var i = 1; i <= 12; i++) {
    await g.moveTo(Offset.lerp(from, to, i / 12)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('미리보기: 누르면 열리고, 위로 밀면 페이지가 스크롤된다', (tester) async {
    phone(tester);
    final layout = (await SeatLayout.load(53))!;
    final scroll = ScrollController();
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(controller: scroll, children: [
          SeatMapPreview(layout: layout, seats: _seats(layout.seats.length), selected: const [], onOpen: () => opened++),
          const SizedBox(height: 1500),
        ]),
      ),
    ));
    await tester.tap(find.byType(SeatMapPreview));
    expect(opened, 1);
    final c = tester.getCenter(find.byType(SeatMapPreview));
    await _drag(tester, c, c - const Offset(0, 200));
    expect(scroll.offset, greaterThan(100));
  });

  testWidgets('전체 화면 도면: 시작 배율, 한 손가락 이동, 좌석 탭, 축소 상태 핀치', (tester) async {
    phone(tester);
    final layout = (await SeatLayout.load(54))!;
    final tapped = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: SeatMapPage(title: '열람실', layout: layout, seats: _seats(layout.seats.length), selected: const [], onTap: (s) => tapped.add(s.code)),
    ));
    final viewer = find.byType(InteractiveViewer);
    Matrix4 m() => tester.widget<InteractiveViewer>(viewer).transformationController!.value;
    final c = tester.getCenter(viewer);

    // z 배율을 1 로 두면 s<1 일 때 getMaxScaleOnAxis() 가 1 을 돌려줘 InteractiveViewer 가 배율을 잘못 읽는다.
    expect(m().getMaxScaleOnAxis(), closeTo(0.9, 0.001));

    // 처음 화면에서 보이는 좌석을 누르면 콜백이 불린다.
    final vp = tester.getRect(viewer).deflate(30);
    String? hit;
    for (var i = 0; i < layout.seats.length && hit == null; i++) {
      final f = find.text('${i + 1}');
      if (f.evaluate().length == 1 && vp.contains(tester.getCenter(f))) {
        hit = '${i + 1}';
        await tester.tapAt(tester.getCenter(f));
      }
    }
    expect(hit, isNotNull);
    expect(tapped, [hit]);

    // 한 손가락으로 가로/세로 이동
    final t0 = m().getTranslation();
    await _drag(tester, c, c + const Offset(-150, 0));
    final t1 = m().getTranslation();
    expect(t1.x, lessThan(t0.x - 50));
    await _drag(tester, c, c + const Offset(0, -120));
    expect(m().getTranslation().y, lessThan(t1.y - 30));

    // 전체 보기(축소) 상태에서 핀치: 손가락 간격 비율(60→220, 약 3.67배)만큼 커져야 한다.
    await tester.tap(find.byTooltip('전체 보기'));
    await tester.pump(const Duration(seconds: 1));
    final fit = m().getMaxScaleOnAxis();
    expect(fit, lessThan(0.5));
    final a = await tester.startGesture(c - const Offset(30, 0), pointer: 11);
    final b = await tester.startGesture(c + const Offset(30, 0), pointer: 12);
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(c - Offset(30.0 + i * 8, 0));
      await b.moveTo(c + Offset(30.0 + i * 8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pump(const Duration(seconds: 1));
    expect(m().getMaxScaleOnAxis() / fit, inInclusiveRange(3.2, 4.2));
  });
}
