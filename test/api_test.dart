import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';

class _Fake implements HttpClientAdapter {
  _Fake(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async => respond(o);
  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int code = 200]) =>
    ResponseBody.fromString(jsonEncode(body), code, headers: {Headers.contentTypeHeader: ['application/json']});

ResponseBody _html([int code = 200]) =>
    ResponseBody.fromString('<html><body>점검 중입니다</body></html>', code, headers: {Headers.contentTypeHeader: ['text/html']});

LibApi _api(ResponseBody Function(RequestOptions) respond) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test/pyxis-api', validateStatus: (_) => true))
    ..httpClientAdapter = _Fake(respond);
  return LibApi(dio: dio);
}

void main() {
  group('로그인', () {
    test('성공하면 토큰을 저장하고 이후 요청에 붙인다', () async {
      String? tokenSeen;
      final api = _api((o) {
        if (o.path.endsWith('/api/login')) return _json({'success': true, 'data': {'accessToken': 'T0KEN'}});
        tokenSeen = o.headers['Pyxis-Auth-Token'] as String?;
        return _json({'success': true, 'data': {'list': []}});
      });
      await api.login('20240001', 'pw');
      await api.seats(53);
      expect(tokenSeen, 'T0KEN');
    });

    test('서버가 JSON 으로 명확히 거절하면 LoginException', () async {
      final api = _api((_) => _json({'success': false, 'code': 'error.authentication', 'message': '비밀번호 불일치'}, 200));
      await expectLater(api.login('1', 'x'), throwsA(isA<LoginException>()));
    });

    test('서버 오류(5xx)는 로그인 실패가 아니라 일시적인 ApiException', () async {
      // 5xx 일 때 JSON 으로 success:false 를 줘도 "비밀번호가 틀렸다"고 하면 안 된다.
      await expectLater(_api((_) => _json({'success': false}, 503)).login('1', 'x'), throwsA(isA<ApiException>()));
      await expectLater(_api((_) => _html(502)).login('1', 'x'), throwsA(isA<ApiException>()));
    });

    test('점검 안내 같은 HTML 응답도 ApiException', () async {
      await expectLater(_api((_) => _html()).login('1', 'x'), throwsA(isA<ApiException>()));
    });
  });

  group('좌석 조회', () {
    test('정상 응답을 읽는다', () async {
      final api = _api((_) => _json({
            'success': true,
            'data': {
              'list': [
                {'id': 1, 'code': '1', 'isActive': true, 'isOccupied': true, 'remainingTime': 45, 'chargeTime': 240},
                {'id': 2, 'code': '2', 'isActive': true, 'isOccupied': false},
              ]
            }
          }));
      final seats = await api.seats(53);
      expect(seats.map((s) => s.code), ['1', '2']);
      expect(seats.first.remainingMinutes, 45);
    });

    test('success:false 는 세션 문제(SessionException)', () async {
      final api = _api((_) => _json({'success': false, 'code': 'error.unauthorized', 'message': '로그인이 필요합니다'}));
      await expectLater(api.seats(53), throwsA(isA<SessionException>()));
    });

    test('서버 오류와 HTML 은 ApiException (세션 만료로 착각하지 않는다)', () async {
      await expectLater(_api((_) => _json({'success': false}, 500)).seats(53), throwsA(isA<ApiException>()));
      await expectLater(_api((_) => _html()).seats(53), throwsA(isA<ApiException>()));
    });

    test('응답 모양이 예상과 다르면 ApiException 하나로 모은다', () async {
      await expectLater(_api((_) => _json({'success': true, 'data': {'list': 'nope'}})).seats(53), throwsA(isA<ApiException>()));
      await expectLater(_api((_) => _json({'success': true, 'data': null})).seats(53), throwsA(isA<ApiException>()));
      await expectLater(
          _api((_) => _json({'success': true, 'data': {'list': [{'code': '1'}]}})).seats(53), throwsA(isA<ApiException>())); // id 없음
    });
  });

  group('열람실 목록', () {
    test('이용 가능한 열람실을 앞에 둔다', () async {
      final api = _api((_) => _json({
            'success': true,
            'data': {
              'list': [
                {'id': 57, 'name': '마루열람실', 'isChargeable': false, 'seats': {'total': 10}},
                {'id': 53, 'name': '숭실스퀘어ON', 'isChargeable': true, 'seats': {'total': 112, 'available': 20, 'occupied': 92}},
              ]
            }
          }));
      final rooms = await api.rooms();
      expect(rooms.map((r) => r.id), [53, 57]);
    });

    test('모양이 이상하면 ApiException', () async {
      await expectLater(_api((_) => _json({'success': true, 'data': {'list': [1, 2]}})).rooms(), throwsA(isA<ApiException>()));
    });
  });

  group('내 좌석', () {
    // 홈페이지 "내 좌석" 목록이 쓰는 필드: id, seat.id/code, room.id/name, isReturnable.
    Map<String, dynamic> charge({int id = 900, bool returnable = false}) => {
          'id': id,
          'seat': {'id': 107, 'code': '7'},
          'room': {'id': 53, 'name': '숭실스퀘어ON(2F)'},
          'state': {'code': 'RESERVED', 'name': '배정'},
          'isReturnable': returnable,
          'isCheckinable': true,
        };

    test('목록을 읽는다 (예약 번호와 좌석 번호는 다르다)', () async {
      String? path;
      final api = _api((o) {
        path = o.path;
        return _json({'success': true, 'data': {'list': [charge()]}});
      });
      final mine = await api.myCharges();
      expect(path, endsWith('/1/api/seat-charges'));
      expect(mine, hasLength(1));
      expect(mine.first.id, 900);
      expect(mine.first.seatId, 107);
      expect(mine.first.seatCode, '7');
      expect(mine.first.roomId, 53);
      expect(mine.first.roomName, '숭실스퀘어ON(2F)');
      expect(mine.first.returnable, isFalse);
    });

    test('isReturnable 이 true 면 이용 중으로 본다', () async {
      final api = _api((_) => _json({'success': true, 'data': {'list': [charge(returnable: true)]}}));
      expect((await api.myCharges()).first.returnable, isTrue);
    });

    test('기록이 없으면 빈 목록 (success.noRecord, data 없음도 포함)', () async {
      expect(await _api((_) => _json({'success': true, 'code': 'success.noRecord'})).myCharges(), isEmpty);
      expect(await _api((_) => _json({'success': false, 'code': 'success.noRecord'})).myCharges(), isEmpty);
      expect(await _api((_) => _json({'success': true, 'data': {'list': []}})).myCharges(), isEmpty);
    });

    test('로그인이 풀리면 SessionException, 서버 오류와 이상한 모양은 ApiException', () async {
      await expectLater(
          _api((_) => _json({'success': false, 'code': 'error.unauthorized', 'message': '로그인 필요'})).myCharges(),
          throwsA(isA<SessionException>()));
      await expectLater(_api((_) => _json({'success': false}, 500)).myCharges(), throwsA(isA<ApiException>()));
      await expectLater(_api((_) => _html()).myCharges(), throwsA(isA<ApiException>()));
      await expectLater(
          _api((_) => _json({'success': true, 'data': {'list': [{'id': 1}]}})).myCharges(), throwsA(isA<ApiException>()));
    });

    test('취소는 홈페이지와 같은 주소로 DELETE 하고 응답을 그대로 돌려준다', () async {
      RequestOptions? seen;
      final api = _api((o) {
        seen = o;
        return _json({'success': true});
      });
      final res = await api.cancelCharge(900);
      expect(seen!.method, 'DELETE');
      expect(seen!.path, endsWith('/1/api/seat-charges/900'));
      expect(seen!.queryParameters['smufMethodCode'], 'PC');
      expect(res['success'], isTrue);
      final no = await _api((_) => _json({'success': false, 'code': 'error.x', 'message': '취소할 수 없습니다'})).cancelCharge(900);
      expect(no['message'], '취소할 수 없습니다');
    });

    test('반납은 홈페이지와 같은 주소로 예약 번호를 POST 한다 (이용 중인 좌석용)', () async {
      RequestOptions? seen;
      final api = _api((o) {
        seen = o;
        return _json({'success': true});
      });
      final res = await api.returnCharge(900);
      expect(seen!.method, 'POST');
      expect(seen!.path, endsWith('/1/api/seat-discharges'));
      expect(seen!.data, {'seatCharge': 900, 'smufMethodCode': 'PC'});
      expect(res['success'], isTrue);
      final no = await _api((_) => _json({'success': false, 'code': 'error.x', 'message': '반납할 수 없습니다'})).returnCharge(900);
      expect(no['message'], '반납할 수 없습니다');
    });
  });

  test('예약 요청 응답은 그대로 돌려준다 (성공/실패 판단은 호출한 쪽)', () async {
    final ok = await _api((_) => _json({'success': true, 'data': {'id': 9}})).reserve(5);
    expect(ok['success'], isTrue);
    final no = await _api((_) => _json({'success': false, 'code': 'error.x', 'message': '이미 배정'})).reserve(5);
    expect(no['message'], '이미 배정');
  });
}
