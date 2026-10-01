import 'dart:convert';

import 'package:flutter/services.dart';

// tools/gen_layouts.py 가 만든 도서관 홈페이지 좌석 도면(assets/layouts/rNN.json).

Color? _color(String? aarrggbb) => aarrggbb == null ? null : Color(int.parse(aarrggbb, radix: 16));

double _d(Object? v) => (v as num).toDouble();

class LayoutSeat {
  LayoutSeat({
    required this.index,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.bg,
    required this.bc,
    required this.fg,
    required this.radius,
  });

  /// API 좌석 목록에서의 순번. 도면은 코드가 아니라 이 순번으로 좌석을 배치한다.
  final int index;
  final double x, y, w, h, radius;
  final Color? bg, bc, fg;

  factory LayoutSeat.fromJson(Map<String, dynamic> j) => LayoutSeat(
        index: j['i'] as int,
        x: _d(j['x']),
        y: _d(j['y']),
        w: _d(j['w']),
        h: _d(j['h']),
        bg: _color(j['bg'] as String?),
        bc: _color(j['bc'] as String?),
        fg: _color(j['fg'] as String?),
        radius: _d(j['r'] ?? 4),
      );
}

class LayoutBox {
  LayoutBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.bg,
    required this.borderWidth,
    required this.borderColor,
    required this.radii,
  });

  final double x, y, w, h, borderWidth;
  final Color? bg, borderColor;
  final List<double> radii; // 좌상, 우상, 우하, 좌하

  factory LayoutBox.fromJson(Map<String, dynamic> j) => LayoutBox(
        x: _d(j['x']),
        y: _d(j['y']),
        w: _d(j['w']),
        h: _d(j['h']),
        bg: _color(j['bg'] as String?),
        borderWidth: _d(j['bw'] ?? 0),
        borderColor: _color(j['bc'] as String?),
        radii: ((j['r'] as List?) ?? const [0, 0, 0, 0]).map(_d).toList(),
      );
}

class LayoutText {
  LayoutText({
    required this.x,
    required this.y,
    required this.text,
    required this.fontSize,
    required this.color,
    required this.bold,
  });

  final double x, y, fontSize;
  final String text;
  final Color color;
  final bool bold;

  factory LayoutText.fromJson(Map<String, dynamic> j) => LayoutText(
        x: _d(j['x']),
        y: _d(j['y']),
        text: j['t'] as String,
        fontSize: _d(j['fs'] ?? 14),
        color: _color(j['fg'] as String?) ?? const Color(0xFF333333),
        bold: (int.tryParse('${j['fw']}') ?? 400) >= 600 || j['fw'] == 'bold',
      );
}

class LegendItem {
  LegendItem({required this.label, required this.bg, required this.border, required this.disabled});

  final String label;
  final Color bg, border;
  final bool disabled;

  /// "#006794" 와 "#eee" 같은 3자리 약식 색을 모두 읽는다.
  static Color _css(String s) {
    var h = s.replaceFirst('#', '');
    if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
    return Color(0xFF000000 | int.parse(h, radix: 16));
  }

  factory LegendItem.fromJson(Map<String, dynamic> j) => LegendItem(
        label: j['label'] as String,
        bg: _css(j['bg'] as String),
        border: _css(j['bc'] as String),
        disabled: j['disabled'] == true,
      );
}

class SeatLayout {
  SeatLayout({
    required this.room,
    required this.width,
    required this.height,
    required this.seats,
    required this.boxes,
    required this.texts,
    required this.legend,
    required this.disabledBg,
    required this.disabledBorder,
    required this.disabledFg,
  });

  final int room;
  final double width, height;
  final List<LayoutSeat> seats;
  final List<LayoutBox> boxes;
  final List<LayoutText> texts;
  final List<LegendItem> legend;
  final Color disabledBg, disabledBorder, disabledFg;

  factory SeatLayout.fromJson(Map<String, dynamic> j) {
    final dis = (j['disabled'] as Map?) ?? const {};
    return SeatLayout(
      room: j['room'] as int,
      width: _d(j['w']),
      height: _d(j['h']),
      seats: (j['seats'] as List).map((e) => LayoutSeat.fromJson(e as Map<String, dynamic>)).toList(),
      boxes: (j['boxes'] as List).map((e) => LayoutBox.fromJson(e as Map<String, dynamic>)).toList(),
      texts: (j['texts'] as List).map((e) => LayoutText.fromJson(e as Map<String, dynamic>)).toList(),
      legend: ((j['legend'] as List?) ?? const []).map((e) => LegendItem.fromJson(e as Map<String, dynamic>)).toList(),
      disabledBg: _color(dis['bg'] as String?) ?? const Color(0xFFEEEEEE),
      disabledBorder: _color(dis['bc'] as String?) ?? const Color(0xFFEEEEEE),
      disabledFg: const Color(0xFF9E9E9E),
    );
  }

  /// 홈페이지에 도면이 있는 열람실이면 불러오고, 없으면 null (목록 보기만 가능).
  static Future<SeatLayout?> load(int room, {AssetBundle? bundle}) async {
    try {
      final text = await (bundle ?? rootBundle).loadString('assets/layouts/r$room.json');
      return SeatLayout.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
