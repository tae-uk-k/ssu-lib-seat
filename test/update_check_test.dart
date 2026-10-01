import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/update_check.dart';

/// 실제 GitHub `releases/latest` 응답과 같은 모양 (필요한 필드만).
Map<String, dynamic> _release({
  String tag = 'v1.0.3',
  bool draft = false,
  bool prerelease = false,
  String body = '좌석 밑 남은 시간 표시',
  List<Map<String, dynamic>>? assets,
}) =>
    {
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'body': body,
      'assets': assets ??
          [
            {
              'name': 'ssu-lib-seat-1.0.3.apk',
              'browser_download_url': 'https://github.com/tae-uk-k/ssu-lib-seat/releases/download/v1.0.3/ssu-lib-seat-1.0.3.apk',
              'size': 3,
              'digest': 'sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', // "abc"
            },
          ],
    };

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int code = 200]) =>
    ResponseBody.fromString(jsonEncode(body), code, headers: {Headers.contentTypeHeader: ['application/json']});

UpdateChecker _checker(_FakeAdapter a) => UpdateChecker(dio: Dio()..httpClientAdapter = a);

void main() {
  group('버전 비교', () {
    test('숫자로 비교한다 (1.0.10 > 1.0.9)', () {
      expect(isNewerVersion('1.0.9', '1.0.10'), isTrue);
      expect(isNewerVersion('1.0.0', '1.0.1'), isTrue);
      expect(isNewerVersion('1.0.9', '1.1.0'), isTrue);
      expect(isNewerVersion('1.9.9', '2.0.0'), isTrue);
    });
    test('같거나 낮으면 false', () {
      expect(isNewerVersion('1.0.1', '1.0.1'), isFalse);
      expect(isNewerVersion('1.0.2', '1.0.1'), isFalse);
      expect(isNewerVersion('1.0.1', '1.0'), isFalse);
    });
    test('v 접두사와 +빌드번호는 무시한다', () {
      expect(isNewerVersion('1.0.1+3', 'v1.0.1'), isFalse);
      expect(isNewerVersion('1.0.1+9', 'v1.0.2'), isTrue);
      expect(parseVersion('v1.0.12+4'), [1, 0, 12]);
    });
    test('읽을 수 없는 버전이면 업데이트를 안내하지 않는다', () {
      expect(isNewerVersion('1.0.1', 'latest'), isFalse);
      expect(isNewerVersion('', '1.0.2'), isFalse);
    });
  });

  group('릴리스 해석', () {
    test('APK 정보를 뽑는다', () {
      final u = parseRelease(_release())!;
      expect(u.version, '1.0.3');
      expect(u.apkName, 'ssu-lib-seat-1.0.3.apk');
      expect(u.apkSize, 3);
      expect(u.sha256, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(u.notes, '좌석 밑 남은 시간 표시');
    });
    test('초안, 시험판, APK 없음은 null', () {
      expect(parseRelease(_release(draft: true)), isNull);
      expect(parseRelease(_release(prerelease: true)), isNull);
      expect(parseRelease(_release(assets: [])), isNull);
      expect(parseRelease(_release(assets: [{'name': 'notes.txt', 'browser_download_url': 'https://x/y.txt'}])), isNull);
      expect(parseRelease(_release(tag: 'nightly')), isNull);
    });
    test('해시가 없어도 읽는다', () {
      final j = _release(assets: [{'name': 'a.APK', 'browser_download_url': 'https://x/a.APK', 'size': 10}]);
      expect(parseRelease(j)!.sha256, isNull);
    });
  });

  group('파일 검증', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('upd_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('크기와 해시가 맞으면 true, 틀리면 false', () async {
      final f = File('${dir.path}/a.apk')..writeAsBytesSync(utf8.encode('abc'));
      final u = parseRelease(_release())!;
      expect(await sha256OfFile(f), u.sha256);
      expect(await apkMatches(f, u), isTrue);
      f.writeAsBytesSync(utf8.encode('abd'));
      expect(await apkMatches(f, u), isFalse); // 같은 크기, 다른 내용
      f.writeAsBytesSync(utf8.encode('abcd'));
      expect(await apkMatches(f, u), isFalse); // 크기가 다름
      expect(await apkMatches(File('${dir.path}/none.apk'), u), isFalse);
    });
  });

  group('조회와 다운로드', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('upd_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('latest: 정상 / 릴리스 없음(404) / 요청 제한(403) / 연결 실패', () async {
      expect((await _checker(_FakeAdapter((_) => _json(_release()))).latest())!.version, '1.0.3');
      expect(await _checker(_FakeAdapter((_) => _json({'message': 'Not Found'}, 404))).latest(), isNull);
      await expectLater(_checker(_FakeAdapter((_) => _json({'message': 'rate limit'}, 403))).latest(), throwsA(isA<UpdateException>()));
      await expectLater(
        _checker(_FakeAdapter((o) => throw DioException.connectionError(requestOptions: o, reason: 'offline'))).latest(),
        throwsA(isA<UpdateException>()),
      );
    });

    test('download: 받아서 검증하고, 진행률이 1.0 까지 가고, 같은 파일은 다시 받지 않는다', () async {
      final adapter = _FakeAdapter((_) => ResponseBody.fromBytes(utf8.encode('abc'), 200, headers: {
            Headers.contentLengthHeader: ['3'],
          }));
      final c = _checker(adapter);
      final u = parseRelease(_release())!;
      final progress = <double>[];
      final f = await c.download(u, dir.path, onProgress: progress.add);
      expect(await f.readAsString(), 'abc');
      expect(progress.last, 1.0);
      expect(adapter.calls, 1);

      final again = await c.download(u, dir.path);
      expect(again.path, f.path);
      expect(adapter.calls, 1); // 이미 검증된 파일이라 네트워크를 쓰지 않는다
    });

    test('download: 내용이 다르면 실패하고 파일을 남기지 않는다', () async {
      final c = _checker(_FakeAdapter((_) => ResponseBody.fromBytes(utf8.encode('xyz'), 200)));
      await expectLater(c.download(parseRelease(_release())!, dir.path), throwsA(isA<UpdateException>()));
      expect(dir.listSync(), isEmpty);
    });

    test('download: 지난 버전 APK 는 정리한다', () async {
      final old = File('${dir.path}/ssu-lib-seat-1.0.1.apk')..writeAsStringSync('old');
      final c = _checker(_FakeAdapter((_) => ResponseBody.fromBytes(utf8.encode('abc'), 200)));
      await c.download(parseRelease(_release())!, dir.path);
      expect(old.existsSync(), isFalse);
    });
  });
}
