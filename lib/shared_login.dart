import 'api.dart';

/// 예약 루프와 자동 연장 루프가 같은 로그인을 나눠 쓰게 한다.
///
/// 두 루프가 거의 동시에 "로그인이 풀렸다"고 보고 각자 다시 로그인하면, 서버가 새 로그인이 나올 때 이전 로그인을 끊는 경우
/// 서로를 계속 끊을 수 있다. 그래서 로그인이 진행 중이면 그 결과를, 방금([reuseWithin]) 끝났으면 그 로그인을 그대로 돌려준다.
class SharedLogin {
  SharedLogin(this._create, {DateTime Function()? now, this.reuseWithin = const Duration(seconds: 10)})
      : _now = now ?? DateTime.now;

  /// 실제로 새로 로그인해 API 를 돌려주는 함수. 로그인 거절은 [LoginException] 을 던진다.
  final Future<LibraryApi> Function() _create;
  final DateTime Function() _now;
  final Duration reuseWithin;

  Future<LibraryApi>? _inFlight;
  LibraryApi? _api;
  DateTime? _at;

  /// 로그인한 API 를 돌려준다. 새로 로그인한 횟수를 줄이려고 [reuseWithin] 안의 로그인은 다시 쓴다.
  Future<LibraryApi> call() {
    final running = _inFlight;
    if (running != null) return running;
    final api = _api, at = _at;
    if (api != null && at != null && _now().difference(at) < reuseWithin) return Future.value(api);
    final attempt = _create().then((a) {
      _api = a;
      _at = _now();
      return a;
    }).whenComplete(() => _inFlight = null);
    _inFlight = attempt;
    return attempt;
  }
}
