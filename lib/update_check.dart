import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

// 앱 안 업데이트. GitHub 릴리스의 최신 APK 를 확인하고 내려받는다.
// Flutter 에 의존하지 않아서 `dart run tools/check_update_live.dart` 로 PC 에서도 실제 서버로 시험할 수 있다.

/// 릴리스를 올리는 공개 저장소.
const updateRepo = 'tae-uk-k/ssu-lib-seat';

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class UpdateInfo {
  UpdateInfo({
    required this.version,
    required this.apkName,
    required this.apkUrl,
    required this.apkSize,
    required this.sha256,
    required this.notes,
    this.pageUrl = '',
  });

  /// "1.0.3" (태그의 v 는 뗀 값)
  final String version;
  final String apkName;
  final String apkUrl;
  final int apkSize;

  /// GitHub 가 계산해 준 파일 해시(소문자 16진수). 없으면 null.
  final String? sha256;
  final String notes;

  /// 이 릴리스의 웹 페이지 주소. 컴퓨터(Windows/macOS)용 앱은 APK 를 설치할 수 없어서, 이 페이지에서 내려받게 한다.
  final String pageUrl;
}

/// "v1.0.12", "1.0.12+3" → [1, 0, 12]. 숫자가 아닌 조각을 만나면 거기서 멈춘다.
List<int> parseVersion(String v) {
  final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
  final out = <int>[];
  for (final part in core.split('.')) {
    final n = int.tryParse(RegExp(r'^[0-9]+').stringMatch(part) ?? '');
    if (n == null) break;
    out.add(n);
  }
  return out;
}

/// [latest] 가 [current] 보다 높은 버전이면 true. 읽을 수 없는 버전이면 false (잘못된 업데이트 안내를 막는다).
bool isNewerVersion(String current, String latest) {
  final a = parseVersion(current), b = parseVersion(latest);
  if (a.isEmpty || b.isEmpty) return false;
  final len = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (y != x) return y > x;
  }
  return false;
}

/// GitHub `releases/latest` 응답에서 APK 정보를 뽑는다. 초안/시험판이거나 APK 가 없으면 null.
UpdateInfo? parseRelease(Map<String, dynamic> j) {
  if (j['draft'] == true || j['prerelease'] == true) return null;
  final tag = j['tag_name'];
  if (tag is! String || parseVersion(tag).isEmpty) return null;
  for (final a in (j['assets'] as List?) ?? const []) {
    if (a is! Map) continue;
    final name = a['name'], url = a['browser_download_url'];
    if (name is! String || url is! String || !name.toLowerCase().endsWith('.apk')) continue;
    final digest = a['digest'];
    return UpdateInfo(
      version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
      apkName: name,
      apkUrl: url,
      apkSize: (a['size'] as num?)?.toInt() ?? 0,
      sha256: digest is String && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
      notes: ((j['body'] as String?) ?? '').trim(),
      pageUrl: (j['html_url'] as String?) ?? '',
    );
  }
  return null;
}

Future<String> sha256OfFile(File f) async {
  final d = SHA256Digest();
  await for (final chunk in f.openRead()) {
    d.update(Uint8List.fromList(chunk), 0, chunk.length);
  }
  final out = Uint8List(d.digestSize);
  d.doFinal(out, 0);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 내려받은 APK 가 릴리스에 올라간 파일과 같은지 크기와 해시로 확인한다. 다르면 false.
Future<bool> apkMatches(File f, UpdateInfo u) async {
  if (!await f.exists()) return false;
  if (u.apkSize > 0 && await f.length() != u.apkSize) return false;
  final want = u.sha256;
  if (want != null && await sha256OfFile(f) != want) return false;
  return true;
}

class UpdateChecker {
  UpdateChecker({Dio? dio, this.repo = updateRepo})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'ssu-lib-seat-updater'},
            ));

  final Dio _dio;
  final String repo;

  /// 최신 릴리스. 릴리스가 아직 없거나 APK 가 없으면 null.
  Future<UpdateInfo?> latest() async {
    final Response<dynamic> r;
    try {
      r = await _dio.get('https://api.github.com/repos/$repo/releases/latest',
          options: Options(validateStatus: (_) => true));
    } on DioException {
      throw UpdateException('업데이트 서버에 연결하지 못했어요. 인터넷 연결을 확인해 주세요.');
    }
    final code = r.statusCode ?? 0;
    if (code == 404) return null;
    if (code == 403 || code == 429) throw UpdateException('업데이트 확인 요청이 너무 많아요. 잠시 후 다시 시도해 주세요.');
    if (code != 200 || r.data is! Map<String, dynamic>) throw UpdateException('업데이트 정보를 읽지 못했어요. ($code)');
    return parseRelease(r.data as Map<String, dynamic>);
  }

  /// APK 를 [dir] 에 내려받아 검증하고 돌려준다. 이미 받아 둔 같은 파일이 있으면 다시 받지 않는다.
  /// [onProgress] 는 0~1.
  Future<File> download(UpdateInfo u, String dir, {void Function(double)? onProgress}) async {
    final target = File('$dir${Platform.pathSeparator}ssu-lib-seat-${u.version}.apk');
    if (await apkMatches(target, u)) return target;

    // 지난 버전 파일은 정리한다.
    for (final e in Directory(dir).listSync()) {
      final n = e.uri.pathSegments.isEmpty ? '' : e.uri.pathSegments.last;
      if (e is File && n.startsWith('ssu-lib-seat-') && n.endsWith('.apk')) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
    final part = File('${target.path}.part');
    try {
      await _dio.download(
        u.apkUrl,
        part.path,
        onReceiveProgress: (got, total) {
          final t = total > 0 ? total : u.apkSize;
          if (t > 0) onProgress?.call((got / t).clamp(0.0, 1.0));
        },
      );
    } on DioException {
      if (await part.exists()) await part.delete();
      throw UpdateException('내려받는 중 연결이 끊겼어요. 다시 시도해 주세요.');
    }
    await part.rename(target.path);
    if (!await apkMatches(target, u)) {
      await target.delete();
      throw UpdateException('내려받은 파일이 올바르지 않아요. 다시 시도해 주세요.');
    }
    return target;
  }
}
