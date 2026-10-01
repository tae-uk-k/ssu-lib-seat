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

class LibApi {
  LibApi()
      : _dio = Dio(BaseOptions(
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

  Map<String, dynamic> _json(Response r) {
    final d = r.data;
    if (d is Map<String, dynamic>) return d;
    if (d is String) return jsonDecode(d) as Map<String, dynamic>;
    throw const FormatException('예상하지 못한 응답');
  }

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
    final token = (j['data'] as Map?)?['accessToken'];
    if (token != null) _dio.options.headers['Pyxis-Auth-Token'] = token;
  }

  /// 열람실 목록. 로그인 없이 조회된다.
  Future<List<Room>> rooms() async {
    final r = await _dio.get('/$_homepageId/seat-rooms',
        queryParameters: {'smufMethodCode': 'PC', 'branchGroupId': 1});
    final j = _json(r);
    if (j['success'] != true) throw ApiException('${j['code']} ${j['message']}');
    final list = ((j['data'] as Map?)?['list'] as List?) ?? const [];
    final rooms = list.map((e) => Room.fromJson(e as Map<String, dynamic>)).toList();
    // 이용 가능한 열람실을 앞에 둔다 (각 그룹 안의 순서는 서버 순서 유지).
    return [...rooms.where((r) => r.chargeable), ...rooms.where((r) => !r.chargeable)];
  }

  Future<List<Seat>> seats(int roomId) async {
    final r = await _dio.get('/$_homepageId/api/rooms/$roomId/seats');
    final j = _json(r);
    if (j['success'] != true) throw SessionException('${j['code']} ${j['message']}');
    final list = (j['data'] as Map)['list'] as List;
    return list.map((e) => Seat.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Map<String, dynamic>> reserve(int seatId) async {
    final r = await _dio.post('/$_homepageId/api/seat-charges', data: {
      'seatId': seatId,
      'smufMethodCode': 'PC',
    });
    return _json(r);
  }
}
