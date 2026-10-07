import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// 기본 브라우저로 주소를 연다. 열었으면 true. 예외는 밖으로 던지지 않는다 (시험에서는 가짜로 바꿔 끼운다).
Future<bool> openInBrowser(String url) async {
  try {
    final uri = Uri.tryParse(url);
    // 서버가 준 주소를 그대로 열기 때문에 웹 주소만 허용한다.
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return false;
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('주소 열기 실패: $e');
    return false;
  }
}
