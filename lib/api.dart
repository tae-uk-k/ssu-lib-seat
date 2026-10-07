import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

const _base = 'https://oasis.ssu.ac.kr/pyxis-api';
const _homepageId = 1;

// 사이트 JS(main.*.js)의 로그인 암호화 상수
const _aesEncryptKey = 'M2M2YjcyMmU2OTZlNjU2YjJlNjM2OTcwNjU3MjNl';
const _sso = ['b', 'c', '25', 'e', 't', 'y', 'u', '13', '23', 'n', 'a', 'q', 'p', '30', 'o', 'v', 'k', 'r', 'z', '6', '.', 'a', '2', ';', '>', 's', '12', 't', 'e', 'l', '15', '.', 'r', 'k', 'e', '26', 'w', '+', '6', '1', 'p', 'i', ',', 'k', '33', 'r', '\$', '4', '!', 't', 'b', '29', 'l', 'f', 'h', '3', '^', 'b', 't', '21', 'q', 'j', 'i'];
const _sso2 = ['!', 'd', 'g', '13', 'q', 't', 'y', '21', 'r', 'l', 'a', '31', 's', '\$', 'e', '17', '41', 't', '[', 'z', 'd', 'k', ':', '22', ']', 'e', 'y', '11', 'k', 'n', 'v', '21', 'i', 'o', '32', '|', '30', '\$', 'l', '{', 's', '45', 'r', ':', '7', 'm', '23', 'o', '[', 'r', 'b', '43', 'm', '.', '1', '_', 'i', 'n', 'e', 'i', '18', 'o', 'c'];

bool _isDigits(String s) => RegExp(r'^[0-9]+$').hasMatch(s);

String _getSso(List<String> arr) {
  final chars = arr.where((x) => !_isDigits(x)).toList();
  final idxs = arr.where(_isDigits).map(int.parse);
  return idxs.map((i) => chars[i]).join();
}

String encryptPassword(String pw) {
  final salt = Uint8List.fromList(utf8.encode(_getSso(_sso)));
  final iv = Uint8List.fromList(utf8.encode(_getSso(_sso2)));
  final kdf = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))
    ..init(Pbkdf2Parameters(salt, 5000, 16));
  final key = kdf.process(Uint8List.fromList(utf8.encode(_aesEncryptKey)));
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(true, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
  return base64.encode(cipher.process(Uint8List.fromList(utf8.encode(pw))));
}

/// 학번/비밀번호가 틀린 경우. 재시도하면 계정이 잠기므로 호출 측은 즉시 중단해야 한다.
class LoginException implements Exception {
  LoginException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 세션 만료 등으로 조회/예약이 거부된 경우.
class SessionException implements Exception {
  SessionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 열람실 목록 조회 등 일반 API 오류.
class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Room {
  Room({
    required this.id,
    required this.name,
    required this.floor,
    required this.chargeable,
    required this.message,
    required this.total,
    required this.available,
    required this.occupied,
  });
  final int id;
  final String name;
  final int? floor;
  final bool chargeable;
  final String? message; // 이용 불가 사유
  final int total;
  final int available;
  final int occupied;

  factory Room.fromJson(Map<String, dynamic> j) {
    final s = (j['seats'] as Map?) ?? const {};
    final msg = (j['unableMessage'] as String?)
        ?.replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .trim();
    return Room(
      id: j['id'] as int,
      name: '${j['name']}',
      floor: j['floor'] as int?,
      chargeable: j['isChargeable'] == true,
      message: (msg == null || msg.isEmpty) ? null : msg,
      total: (s['total'] as int?) ?? 0,
      available: (s['available'] as int?) ?? 0,
      occupied: (s['occupied'] as int?) ?? 0,
    );
  }
}

class Seat {
  Seat({
    required this.id,
    required this.code,
    required this.active,
    required this.occupied,
    this.reservable = false,
    this.remainingTime = 0,
    this.chargeTime = 0,
  });
  final int id;
  final String code;
  final bool active;
  final bool occupied;

  /// 예약제 열람실의 좌석이면 true. 이 경우 홈페이지는 남은 시간 대신 시간표를 보여 준다.
  final bool reservable;

  /// 서버가 주는 "남은 이용 시간"과 "총 이용 시간". 사용 중인 좌석에만 값이 있고 빈 좌석은 0 이다.
  final int remainingTime;
  final int chargeTime;

  bool get available => active && !occupied;

  /// 서버가 쓰는 시간 단위는 로그인 없이는 확인할 수 없었다. 분으로 보고,
  /// 총 이용 시간이 하루(1440)를 넘으면 초 단위로 보고 분으로 바꾼다 (도서관 이용 시간이 24분 미만일 리 없다).
  bool get _inSeconds => chargeTime > 1440;

  /// 사용 중인 좌석의 남은 시간(분). 홈페이지가 좌석 밑에 시간을 보여 주는 조건(예약제가 아니고 남은 시간이 있을 때)과 같다.
  int? get remainingMinutes {
    if (reservable || remainingTime <= 0) return null;
    return _inSeconds ? (remainingTime / 60).ceil() : remainingTime;
  }

  factory Seat.fromJson(Map<String, dynamic> j) => Seat(
        id: j['id'] as int,
        code: '${j['code']}',
        active: j['isActive'] == true,
        occupied: j['isOccupied'] == true,
        reservable: j['isReservable'] == true,
        remainingTime: (j['remainingTime'] as num?)?.toInt() ?? 0,
        chargeTime: (j['chargeTime'] as num?)?.toInt() ?? 0,
      );
}

/// 내가 지금 갖고 있는 좌석 (배정을 받았거나 이용 중). 홈페이지 "내 좌석" 목록의 한 줄이다.
class MyCharge {
  MyCharge({
    required this.id,
    required this.seatId,
    required this.seatCode,
    required this.roomId,
    required this.roomName,
    required this.returnable,
  });

  /// 예약(배정) 번호. 취소할 때 쓴다. 좌석 번호가 아니다.
  final int id;
  final int seatId;
  final String seatCode;
  final int? roomId;
  final String roomName;

  /// true 면 이미 확정돼 이용 중이라 "취소"가 아니라 "반납"으로 내놓아야 한다 (홈페이지도 이때 취소 버튼을 숨기고 반납 버튼을 보여 준다).
  final bool returnable;

  factory MyCharge.fromJson(Map<String, dynamic> j) {
    final seat = j['seat'] as Map<String, dynamic>;
    final room = (j['room'] as Map?) ?? const {};
    return MyCharge(
      id: j['id'] as int,
      seatId: seat['id'] as int,
      seatCode: '${seat['code']}',
      roomId: room['id'] as int?,
      roomName: '${room['name'] ?? ''}',
      returnable: j['isReturnable'] == true,
    );
  }
}

/// 도서관 서버에 하는 요청. 예약 루프와 화면은 이 인터페이스만 쓰므로 시험에서 가짜로 바꿀 수 있다.
abstract interface class LibraryApi {
  /// 로그인한다. 학번/비밀번호가 거절되면 [LoginException], 서버가 일시적으로 이상하면 [ApiException].
  Future<void> login(String uid, String pw);
  Future<List<Room>> rooms();

  /// 로그인이 풀렸거나 서버가 거부하면 [SessionException].
  Future<List<Seat>> seats(int roomId);
  Future<Map<String, dynamic>> reserve(int seatId);

  /// 내가 지금 갖고 있는 좌석. 없으면 빈 목록. 로그인이 풀렸으면 [SessionException].
  Future<List<MyCharge>> myCharges();

  /// 배정만 받고 아직 확정 전인 좌석을 취소한다 ([MyCharge.id]). 서버 응답 그대로 돌려준다 (`success` 가 true 여야 취소된 것).
  Future<Map<String, dynamic>> cancelCharge(int chargeId);

  /// 이미 확정돼 이용 중인 좌석을 반납한다 ([MyCharge.id], [MyCharge.returnable] 이 true 인 좌석). 응답은 [cancelCharge] 와 같다.
  Future<Map<String, dynamic>> returnCharge(int chargeId);
}

class LibApi implements LibraryApi {
  /// [dio] 는 시험에서 가짜 서버를 끼우려고 열어 둔 것이다.
  LibApi({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: _base,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              validateStatus: (_) => true,
              headers: {
                'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
                'Accept': 'application/json, text/plain, */*',
              },
            ));

  final Dio _dio;

  /// 응답을 JSON 으로 읽는다. 서버 오류(5xx)나 JSON 이 아닌 응답(점검 안내 HTML 등)은 일시적인 문제로 보고
  /// [ApiException] 을 던진다. 이걸 로그인 실패나 세션 만료로 착각하면 안 된다.
  Map<String, dynamic> _json(Response r) {
    final code = r.statusCode ?? 0;
    if (code >= 500) throw ApiException('서버 오류 (HTTP $code)');
    final d = r.data;
    try {
      if (d is Map<String, dynamic>) return d;
      if (d is String) {
        final j = jsonDecode(d);
        if (j is Map<String, dynamic>) return j;
      }
    } on FormatException {
      // 아래에서 같이 처리
    }
    throw ApiException('예상하지 못한 응답 (HTTP $code)');
  }

  /// JSON 모양이 예상과 다를 때(필드 누락, 타입 불일치)도 [ApiException] 하나로 모은다.
  T _shape<T>(T Function() read) {
    try {
      return read();
    } on TypeError {
      throw ApiException('예상하지 못한 응답 모양');
    }
  }

  @override
  Future<void> login(String uid, String pw) async {
    final r = await _dio.post('/api/login', data: {
      'loginId': uid,
      'password': encryptPassword(pw),
      'isFamilyLogin': false,
      'isMobile': false,
    });
    final j = _json(r);
    if (j['success'] != true) {
      throw LoginException('${j['code']} ${j['message']}');
    }
    final data = j['data'];
    final token = data is Map ? data['accessToken'] : null;
    if (token != null) _dio.options.headers['Pyxis-Auth-Token'] = token;
  }

  /// 열람실 목록. 로그인 없이 조회된다.
  @override
  Future<List<Room>> rooms() async {
    final r = await _dio.get('/$_homepageId/seat-rooms',
        queryParameters: {'smufMethodCode': 'PC', 'branchGroupId': 1});
    final j = _json(r);
    if (j['success'] != true) throw ApiException('${j['code']} ${j['message']}');
    final rooms = _shape(() {
      final list = ((j['data'] as Map?)?['list'] as List?) ?? const [];
      return list.map((e) => Room.fromJson(e as Map<String, dynamic>)).toList();
    });
    // 이용 가능한 열람실을 앞에 둔다 (각 그룹 안의 순서는 서버 순서 유지).
    return [...rooms.where((r) => r.chargeable), ...rooms.where((r) => !r.chargeable)];
  }

  @override
  Future<List<Seat>> seats(int roomId) async {
    final r = await _dio.get('/$_homepageId/api/rooms/$roomId/seats');
    final j = _json(r);
    if (j['success'] != true) throw SessionException('${j['code']} ${j['message']}');
    return _shape(() {
      final list = (j['data'] as Map)['list'] as List;
      return list.map((e) => Seat.fromJson(e as Map<String, dynamic>)).toList();
    });
  }

  @override
  Future<Map<String, dynamic>> reserve(int seatId) async {
    final r = await _dio.post('/$_homepageId/api/seat-charges', data: {
      'seatId': seatId,
      'smufMethodCode': 'PC',
    });
    return _json(r);
  }

  @override
  Future<List<MyCharge>> myCharges() async {
    final r = await _dio.get('/$_homepageId/api/seat-charges');
    final j = _json(r);
    // 홈페이지도 "기록 없음"을 빈 목록으로 본다.
    if (j['code'] == 'success.noRecord') return const [];
    if (j['success'] != true) throw SessionException('${j['code']} ${j['message']}');
    return _shape(() {
      final list = ((j['data'] as Map?)?['list'] as List?) ?? const [];
      return list.map((e) => MyCharge.fromJson(e as Map<String, dynamic>)).toList();
    });
  }

  @override
  Future<Map<String, dynamic>> cancelCharge(int chargeId) async {
    final r = await _dio.delete('/$_homepageId/api/seat-charges/$chargeId', queryParameters: {'smufMethodCode': 'PC'});
    return _json(r);
  }

  @override
  Future<Map<String, dynamic>> returnCharge(int chargeId) async {
    final r = await _dio.post('/$_homepageId/api/seat-discharges', data: {
      'seatCharge': chargeId,
      'smufMethodCode': 'PC',
    });
    return _json(r);
  }
}
