import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'auto_renewer.dart';
import 'reservation_runner.dart';
import 'run_state.dart';
import 'seat_layout.dart';
import 'seat_map.dart';
import 'services.dart';
import 'shared_login.dart';
import 'update_check.dart';
import 'widgets.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    // 잡히지 않은 오류를 기록해 둔다. 폰에서 문제가 생기면 "메뉴 > 오류 기록"에서 복사해 보낼 수 있다.
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      CrashLog.record(details.exception, details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      CrashLog.record(error, stack);
      return true;
    };
    runApp(App(services: AppServices.real()));
  }, (error, stack) => CrashLog.record(error, stack));
}

class App extends StatelessWidget {
  const App({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '도서관 좌석 예약',
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          useMaterial3: true,
          fontFamily: 'Pretendard',
          scaffoldBackgroundColor: kAppBg,
          appBarTheme: const AppBarTheme(
            backgroundColor: kAppBg,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            centerTitle: false,
            titleTextStyle: TextStyle(fontFamily: 'Pretendard', fontSize: 19, fontWeight: FontWeight.bold, color: Color(0xFF1B1B1F)),
          ),
          inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
          dialogTheme: DialogThemeData(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        home: services.wrapRoot(HomePage(services: services)),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.services});

  final AppServices services;

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 예약의 진행 단계. 시작/멈추는 중에는 버튼을 막아서 두 번 눌러도 루프가 겹쳐 돌지 않게 한다.
enum _Phase { idle, starting, running, stopping }

/// 화면 맨 위에 남겨 두는 마지막 결과 안내 (배정 완료, 중단 사유, 중간에 멈춤 등).
class _Notice {
  const _Notice({required this.title, required this.body, this.good = false});
  final String title;
  final String body;
  final bool good;
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const _minIntervalSec = 1.0;
  static const _defaultRoomId = 53;

  final _id = TextEditingController();
  final _pw = TextEditingController();
  final _interval = TextEditingController(text: '1.5');
  final _range = TextEditingController();

  late LibraryApi _api = widget.services.newApi();
  bool _loggedIn = false;
  bool _loggingIn = false;
  bool _savePw = true;

  List<Room> _rooms = [];
  bool _loadingRooms = false;
  String? _roomsError;
  int? _roomId = _defaultRoomId;

  List<Seat> _seatsApi = []; // API 순서 그대로 (도면은 순번으로 좌석을 찾는다)
  List<Seat> _seats = []; // 번호순 (목록 보기, 번호 범위 선택용)
  SeatLayout? _layout; // 홈페이지 도면이 있는 열람실만
  bool _mapView = true;
  bool _loadingSeats = false;
  List<String> _selected = []; // 선택한 순서 = 우선순위

  _Phase _phase = _Phase.idle;

  /// 시작 중, 도는 중, 멈추는 중 모두 true. 설정을 바꾸는 컨트롤을 잠그는 데 쓴다.
  bool get _running => _phase != _Phase.idle;
  ReservationRunner? _runner; // 좌석을 노리는 중일 때만 있다 (좌석을 받으면 끝난다)
  SeatRenewer? _renewer; // 자동 연장이 켜져 있으면 예약이 시작될 때부터 끝날 때까지 같이 돈다
  // 조회마다 바뀌는 값은 화면 전체가 아니라 실행 배너만 다시 그리도록 따로 둔다.
  final _runStatus = ValueNotifier<RunStatus?>(null);
  final _renewStatus = ValueNotifier<RenewStatus?>(null);
  _Notice? _lastResult;
  DateTime? _lastBeat;
  DateTime? _lastNotif;
  String? _lastServiceText;

  /// 이용 종료 전에 내 좌석을 자동으로 연장할지. 기본으로 켜져 있다.
  bool _autoRenew = true;
  List<String> _crashes = [];

  /// 배터리 최적화에서 제외돼 있는지. 아니면 화면을 꺼 둘 때 폰이 앱을 멈출 수 있다.
  bool _batteryOk = true;

  // 앱 안 업데이트
  String _version = ''; // 지금 설치된 버전
  UpdateInfo? _update; // 더 높은 버전이 있으면 그 정보
  bool _checkingUpdate = false;
  bool _updating = false;
  double? _updateProgress;
  final _runLog = RunLog(); // 진행 기록 (메뉴에서 연다)

  Room? get _room {
    for (final r in _rooms) {
      if (r.id == _roomId) return r;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
  }

  Future<void> _init() async {
    await widget.services.background.init();
    await widget.services.notifier.init();
    await _restore();
    unawaited(_loadLayout());
    unawaited(_loadRooms());
    unawaited(_checkInterruptedRun());
    final crashes = await CrashLog.read();
    if (mounted) setState(() => _crashes = crashes);
    await _refreshBattery();
    await _offerBatteryOnce();
  }

  Future<void> _refreshBattery() async {
    final ok = await widget.services.background.isBatteryUnrestricted();
    if (mounted) setState(() => _batteryOk = ok);
  }

  /// 처음 실행할 때 한 번만, 배터리 제한을 풀어야 하는 이유를 알리고 시스템 허용 창을 띄운다.
  /// 거절해도 다시 묻지 않는다 (메뉴에서 언제든 다시 할 수 있다).
  Future<void> _offerBatteryOnce() async {
    if (_batteryOk || widget.services.desktop || !mounted) return; // 배터리 제한은 폰에만 있다
    final p = await SharedPreferences.getInstance();
    if (p.getBool('batteryAsked') == true || !mounted) return;
    await p.setBool('batteryAsked', true);
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('배터리 제한을 풀어 주세요'),
        content: Text('화면을 꺼 두면 폰이 앱을 멈춰서 예약이 중간에 끊길 수 있어요. 다음 창에서 "허용"을 눌러 주세요.'.keepWords),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('나중에')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('확인')),
        ],
      ),
    );
    if (go == true) await _requestBattery();
  }

  Future<void> _requestBattery() async {
    final ok = await widget.services.background.requestBatteryUnrestricted();
    if (!mounted) return;
    setState(() => _batteryOk = ok);
    _toast(ok ? '배터리 제한을 풀었어요.' : '배터리 제한이 그대로예요. 화면을 오래 꺼 두면 예약이 멈출 수 있어요.');
  }

  /// 지난번 예약이 정상적으로 끝나지 않고 앱이 사라졌는지 알아본다 (최근 앱에서 밀어 끔, 시스템 종료, 크래시).
  Future<void> _checkInterruptedRun() async {
    final r = await RunMarker.readInterrupted();
    if (r == null || !mounted) return;
    await RunMarker.end();
    final what = r.room.isEmpty ? '' : '${r.room} · ${r.seatCount}개 좌석 ';
    if (!mounted) return;
    setState(() => _lastResult = _Notice(
          title: '지난 예약이 중간에 멈췄어요',
          body: '$what감시가 ${_hm(r.lastCheck)}에 마지막으로 확인된 뒤 멈췄어요. '
              '${widget.services.desktop ? '창을 닫거나 앱이 종료되면' : '앱을 최근 앱 목록에서 밀어서 끄거나 시스템이 앱을 종료하면'} 예약도 함께 멈춰요. '
              '다시 하려면 아래에서 예약을 시작해 주세요.',
        ));
  }

  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // ---------- 업데이트 ----------

  static const _updateCheckEvery = Duration(hours: 6);

  /// 최근에 확인했고 그때 새 버전이 없었는지. 앱을 켤 때마다 서버에 묻지 않으려고 쓴다.
  Future<bool> _checkedRecently() async {
    try {
      final p = await SharedPreferences.getInstance();
      final at = p.getInt('updateCheckedAt');
      if (at == null) return false;
      final age = DateTime.now().millisecondsSinceEpoch - at;
      return age >= 0 && age < _updateCheckEvery.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markUpdateChecked() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('updateCheckedAt', DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// 새 버전이 있는지 확인한다. 앱을 켤 때는 조용히(실패해도 아무 말 없이), 직접 누르면 결과를 알려 준다.
  /// 켤 때는 최근에 "새 버전 없음"으로 확인했다면 서버에 다시 묻지 않는다 (새 버전이 있다고 나온 동안은 매번 확인해 안내를 보여 준다).
  Future<void> _checkUpdate({bool manual = false}) async {
    if (_checkingUpdate || _updating) return;
    setState(() => _checkingUpdate = true);
    try {
      final current = (await PackageInfo.fromPlatform()).version;
      if (mounted) setState(() => _version = current);
      if (!manual && await _checkedRecently()) return;
      final latest = await widget.services.updater.latest();
      if (!mounted) return;
      if (latest != null && isNewerVersion(current, latest.version)) {
        setState(() => _update = latest);
        if (manual) _toast('새 버전 ${latest.version}이 있어요. 맨 위의 업데이트 버튼을 눌러 주세요.');
      } else {
        unawaited(_markUpdateChecked());
        if (manual) _toast('최신 버전이에요. ($current)');
      }
    } on UpdateException catch (e) {
      if (manual) _toast(e.message);
    } catch (_) {
      if (manual) _toast('업데이트를 확인하지 못했어요.');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  /// 새 APK 를 내려받아 안드로이드 설치 창을 연다. 설치하면 앱이 꺼졌다 다시 켜지므로 예약이 도는 중에는 막는다.
  /// 컴퓨터용 앱은 APK 를 설치할 수 없어서, 새 버전을 내려받는 릴리스 웹 페이지를 열어 준다 (예약은 계속 돌아도 된다).
  Future<void> _installUpdate() async {
    final u = _update;
    if (u == null || _updating) return;
    if (widget.services.desktop) {
      final url = u.pageUrl.isNotEmpty ? u.pageUrl : 'https://github.com/$updateRepo/releases/latest';
      final ok = await widget.services.openUrl(url);
      if (!ok) _toast('브라우저를 열지 못했어요. 주소를 직접 열어 주세요: $url');
      return;
    }
    if (_running) {
      _toast('예약을 멈춘 뒤에 업데이트해 주세요.');
      return;
    }
    setState(() {
      _updating = true;
      _updateProgress = null;
    });
    try {
      final dir = await getTemporaryDirectory();
      final apk = await widget.services.updater.download(u, dir.path, onProgress: (p) {
        if (mounted) setState(() => _updateProgress = p);
      });
      final res = await OpenFilex.open(apk.path, type: 'application/vnd.android.package-archive');
      if (res.type != ResultType.done) {
        _toast('설치 창을 열지 못했어요. (${res.message})');
      } else {
        _toast('설치 창에서 "설치"를 눌러 주세요. 처음이면 "이 출처 허용"을 켠 뒤 다시 업데이트 버튼을 눌러 주세요.');
      }
    } on UpdateException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('업데이트에 실패했어요. 잠시 후 다시 시도해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _updating = false;
          _updateProgress = null;
        });
      }
    }
  }

  Future<void> _loadLayout() async {
    final id = _roomId;
    final layout = id == null ? null : await widget.services.layoutFor(id);
    if (mounted && id == _roomId) setState(() => _layout = layout);
  }

  // ---------- 저장 / 복원 ----------

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final id = await widget.services.secure.read('id');
    final pw = await widget.services.secure.read('pw');
    final roomId = p.getInt('roomId') ?? _defaultRoomId;
    if (!mounted) return;
    setState(() {
      _id.text = id ?? '';
      _pw.text = pw ?? '';
      _savePw = pw != null || id == null;
      _interval.text = p.getString('interval') ?? '1.5';
      _autoRenew = p.getBool('autoRenew') ?? true;
      _roomId = roomId;
      _selected = p.getStringList('sel_$roomId') ?? [];
    });
  }

  /// 이미 좌석을 갖고 있을 때만 불린다 (예약 루프가 시작할 때 내 좌석을 확인하고 부른다).
  /// 좌석을 잃을 수 있다는 경고는 이때만 보여 준다. 앱이 보이지 않으면 물을 수 없으니 바꾸지 않는다.
  Future<bool> _askReplace(MyCharge held, int rank) async {
    if (!mounted || !_inForeground) return false;
    final where = held.roomName.isEmpty ? '${held.seatCode}번' : '${held.roomName} ${held.seatCode}번';
    final what = held.returnable ? '이용 중인' : '예약한';
    final inList = rank > 0
        ? '이 좌석은 선택한 목록에도 있어요. ${held.seatCode}번보다 먼저 고른 좌석이 나면 반납하고 바꾸고, 그보다 뒤에 고른 좌석으로는 바꾸지 않아요.'
        : '선택한 좌석이 나면 ${held.seatCode}번을 반납하고 바꿔요.';
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: Text('${held.seatCode}번 좌석을 반납하고 바꿀까요?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('지금 $what $where 좌석이 있어요. $inList'.keepWords),
          const SizedBox(height: 12),
          Text('바꾸다 실패하면 좌석을 잃을 수 있어요.'.keepWords,
              style: TextStyle(fontSize: 12.5, color: Theme.of(c).colorScheme.error)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('아니요')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('바꾸기')),
        ],
      ),
    );
    return ok == true;
  }

  /// 열람실과 고른 좌석만 저장한다 (좌석을 누를 때마다 불리므로 가볍게 유지한다).
  Future<void> _saveSelection() async {
    final p = await SharedPreferences.getInstance();
    if (_roomId != null) {
      await p.setInt('roomId', _roomId!);
      await p.setStringList('sel_$_roomId', _selected);
    }
  }

  Future<void> _setAutoRenew(bool on) async {
    if (_running) return;
    setState(() => _autoRenew = on);
    final p = await SharedPreferences.getInstance();
    await p.setBool('autoRenew', on);
  }

  /// 계정과 확인 간격. 계정은 기기 암호화 저장소에 쓰므로 좌석을 누를 때마다 쓰지 않는다.
  Future<void> _saveAccount() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('interval', _interval.text.trim());
    final store = widget.services.secure;
    await store.write('id', _id.text.trim());
    if (_savePw) {
      await store.write('pw', _pw.text);
    } else {
      await store.delete('pw');
    }
  }

  // ---------- 알림 ----------

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _dialog(String title, String body, {String? detail}) {
    if (!mounted) return Future.value();
    return showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(body.keepWords),
          if (detail != null) ...[
            const SizedBox(height: 12),
            Text(detail, style: TextStyle(fontSize: 12, color: Theme.of(c).colorScheme.outline)),
          ],
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('확인'))],
      ),
    );
  }

  void _log(String m) {
    if (!mounted) return;
    _runLog.add('${DateTime.now().toString().substring(11, 19)}  $m'); // 기록 화면만 다시 그려진다
  }

  Future<void> _loginFailedDialog(LoginException e) => _dialog(
        '로그인에 실패했어요',
        '학번 또는 비밀번호가 올바르지 않아요.\n여러 번 틀리면 5분간 로그인이 막히니, 도서관 홈페이지에서 먼저 로그인해 보고 다시 시도해 주세요.',
        detail: e.message,
      );

  // ---------- 1. 로그인 ----------

  Future<void> _login() async {
    if (_loggingIn || _running) return;
    if (_id.text.trim().isEmpty || _pw.text.isEmpty) {
      _toast('학번과 비밀번호를 입력해 주세요.');
      return;
    }
    setState(() => _loggingIn = true);
    try {
      final api = widget.services.newApi();
      await api.login(_id.text.trim(), _pw.text);
      _api = api;
      if (!mounted) return;
      setState(() => _loggedIn = true);
      await _saveAccount();
      await _saveSelection();
      await _loadSeats();
    } on LoginException catch (e) {
      await _loginFailedDialog(e);
    } on ApiException catch (e) {
      _toast('도서관 서버가 지금 제대로 응답하지 않아요. 잠시 뒤 다시 시도해 주세요. (${e.message})');
    } catch (_) {
      _toast('네트워크 오류가 발생했어요. 인터넷 연결을 확인해 주세요.');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  // ---------- 2. 열람실 ----------

  Future<void> _loadRooms() async {
    if (_loadingRooms) return;
    setState(() {
      _loadingRooms = true;
      _roomsError = null;
    });
    try {
      final rooms = await _api.rooms();
      if (!mounted) return;
      setState(() => _rooms = rooms);
    } catch (_) {
      if (mounted) setState(() => _roomsError = '열람실 목록을 불러오지 못했어요.');
    } finally {
      if (mounted) setState(() => _loadingRooms = false);
    }
  }

  Future<void> _selectRoom(Room r) async {
    if (_running) return;
    if (!r.chargeable) {
      await _dialog('지금은 이용할 수 없어요', r.message ?? '이 열람실은 현재 예약할 수 없어요.');
      return;
    }
    if (r.id == _roomId) return;
    await _saveSelection(); // 이전 열람실 선택 저장
    final p = await SharedPreferences.getInstance();
    setState(() {
      _roomId = r.id;
      _seats = [];
      _seatsApi = [];
      _layout = null;
      _selected = p.getStringList('sel_${r.id}') ?? [];
    });
    await p.setInt('roomId', r.id);
    unawaited(_loadLayout());
    await _loadSeats();
  }

  // ---------- 3. 좌석 ----------

  /// 좌석 번호순 (목록 보기, 번호 범위 선택용). 도면용 API 순서 목록은 건드리지 않는다.
  List<Seat> _sorted(List<Seat> apiOrder) => List<Seat>.of(apiOrder)
    ..sort((a, b) {
      final x = int.tryParse(a.code), y = int.tryParse(b.code);
      if (x != null && y != null) return x.compareTo(y);
      return a.code.compareTo(b.code);
    });

  Future<void> _loadSeats() async {
    final id = _roomId;
    if (id == null || !_loggedIn || _loadingSeats) return;
    setState(() => _loadingSeats = true);
    try {
      final apiOrder = await _api.seats(id);
      final seats = _sorted(apiOrder);
      final codes = seats.map((s) => s.code).toSet();
      if (!mounted) return;
      setState(() {
        _seatsApi = apiOrder;
        _seats = seats;
        _selected = _selected.where(codes.contains).toList();
      });
      if (seats.isEmpty) _toast('이 열람실에는 좌석이 없어요.');
    } on SessionException catch (e) {
      _toast('좌석을 불러오지 못했어요. 다시 로그인해 보세요. (${e.message})');
    } catch (_) {
      _toast('좌석을 불러오지 못했어요. 인터넷 연결을 확인해 주세요.');
    } finally {
      if (mounted) setState(() => _loadingSeats = false);
    }
  }

  void _toggle(Seat s) {
    if (_running) return;
    setState(() {
      if (!_selected.remove(s.code)) _selected.add(s.code);
    });
    _saveSelection();
  }

  /// 도면을 화면 가득 크게 연다. 여기서 고른 좌석도 같은 선택 목록에 반영된다.
  void _openBigMap() {
    final layout = _layout;
    if (layout == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StatefulBuilder(
        builder: (context, setInner) => SeatMapPage(
          title: _room?.name ?? '좌석 도면',
          layout: layout,
          seats: _seatsApi,
          selected: _selected,
          onTap: (s) {
            _toggle(s);
            setInner(() {});
          },
        ),
      ),
    ));
  }

  void _selectAll() {
    setState(() => _selected = _seats.where((s) => s.active).map((s) => s.code).toList());
    _saveSelection();
  }

  void _clearAll() {
    setState(() => _selected = []);
    _saveSelection();
  }

  /// "25-40", "1, 3, 10~12" 같은 입력을 좌석 번호로 바꿔 선택한다.
  void _applyRange() {
    final wanted = <int>[];
    for (final tok in _range.text.split(RegExp(r'[,\s]+'))) {
      if (tok.isEmpty) continue;
      final m = RegExp(r'^(\d+)\s*[-~]\s*(\d+)$').firstMatch(tok);
      if (m != null) {
        final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
        for (var n = a <= b ? a : b; n <= (a <= b ? b : a); n++) {
          wanted.add(n);
        }
      } else if (int.tryParse(tok) != null) {
        wanted.add(int.parse(tok));
      } else {
        _toast('"$tok"는 올바른 형식이 아니에요. 예: 25-40');
        return;
      }
    }
    final byNum = {for (final s in _seats) if (s.active && int.tryParse(s.code) != null) int.parse(s.code): s.code};
    final picked = <String>[];
    for (final n in wanted) {
      final c = byNum[n];
      if (c != null && !picked.contains(c)) picked.add(c);
    }
    if (picked.isEmpty) {
      _toast('해당하는 좌석이 없어요.');
      return;
    }
    setState(() => _selected = picked);
    _saveSelection();
    _toast('${picked.length}개 좌석을 선택했어요.');
  }

  // ---------- 4. 예약 ----------

  /// 지금 앱이 화면에 보이는 중인지. 보이지 않을 때만 시스템 알림으로 결과를 알린다.
  bool get _inForeground =>
      (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱으로 돌아오면 그동안 쌓인 결과 안내가 보이도록 다시 그린다.
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {});
      unawaited(_refreshBattery()); // 설정에서 바꾸고 돌아왔을 수 있다
    }
  }

  Future<void> _start() async {
    if (_phase != _Phase.idle) return; // 연타하거나 멈추는 중에 눌러도 한 번만 시작한다
    // 좌석을 골랐으면 예약 루프를 돌린다. 안 골랐어도 자동 연장이 켜져 있으면 "이미 갖고 있는 좌석의 연장"만 한다.
    final hunt = _selected.isNotEmpty;
    if ((hunt || !_autoRenew) && (_roomId == null || _room == null)) {
      _toast('열람실을 먼저 선택해 주세요.');
      return;
    }
    if (!hunt && !_autoRenew) {
      _toast('예약할 좌석을 하나 이상 선택해 주세요.');
      return;
    }
    if (_id.text.trim().isEmpty || _pw.text.isEmpty) {
      _toast('학번과 비밀번호를 입력해 주세요.');
      return;
    }
    final uid = _id.text.trim();
    final pw = _pw.text;
    final roomId = _roomId;
    final roomName = hunt ? _room!.name : '';
    final wanted = List<String>.of(_selected);
    final sec = double.tryParse(_interval.text.trim()) ?? 1.5;
    final interval = Duration(milliseconds: (sec.clamp(_minIntervalSec, 60) * 1000).round());
    final renewPolicy = widget.services.renewPolicy;

    _runStatus.value = null;
    _renewStatus.value = null;
    setState(() {
      _phase = _Phase.starting;
      _lastResult = null;
      _lastBeat = null;
      _lastNotif = null;
      _lastServiceText = null;
    });
    final bg = widget.services.background;
    RunOutcome? huntOutcome; // 예약 루프가 끝난 이유
    RenewOutcome? renewOutcome; // 자동 연장이 끝난 이유
    var huntAnnounced = false; // 예약 결과(배정 완료)를 이미 알리고 연장을 이어 갔는지
    var renewAnnounced = false; // 연장이 오류로 끝난 것을 이미 알렸는지
    ReservationRunner? runner; // 예외가 나도 finally 에서 둘 다 멈출 수 있게 밖에 둔다
    SeatRenewer? renewer;
    Object? setupError;
    try {
      await _saveAccount();
      await _saveSelection();
      await bg.requestPermission();
      final serviceUp = await bg.start(
        title: hunt ? '좌석 예약 실행 중' : '자동 연장 실행 중',
        text: hunt ? '$roomName · ${wanted.length}개 좌석 감시 중' : '내 좌석을 지켜보는 중',
      );
      if (!serviceUp) {
        _log('백그라운드 실행을 시작하지 못했어요. 앱을 켜 둔 동안에만 확실히 동작해요.');
        _toast('백그라운드 실행을 시작하지 못했어요. 앱을 켜 둔 채로 사용해 주세요.');
      }
      await RunMarker.begin(roomName, hunt ? wanted.length : 0);
      if (hunt) _log('$roomName · 좌석 ${wanted.join(', ')} 감시 시작');
      if (_autoRenew) {
        _log('자동 연장 켜짐: 이용 종료 ${renewPolicy.threshold.inMinutes}분 전부터 연장하고, 안 되면 ${renewPolicy.retryAfter.inMinutes}분 뒤 다시 시도해요');
      }
      if (!_batteryOk) _log('배터리 제한이 켜져 있어요. 화면을 오래 끄면 멈출 수 있으니 메뉴에서 풀어 주세요.');
      // 예약 루프와 연장 루프가 같은 로그인을 나눠 쓴다 (서로의 로그인을 끊지 않게).
      final shared = SharedLogin(() async {
        final api = widget.services.newApi();
        await api.login(uid, pw);
        _api = api;
        if (mounted) setState(() => _loggedIn = true);
        return api;
      });
      runner = !hunt
          ? null
          : ReservationRunner(
              roomId: roomId!,
              wanted: wanted,
              policy: widget.services.policyFor(interval),
              api: _loggedIn ? _api : null,
              login: shared.call,
              onLog: _log,
              onStatus: (s) => _onRunStatus(s, roomName),
              isEnvironmentAlive: serviceUp ? bg.isAlive : null,
              replaceExisting: true,
              confirmReplace: _askReplace,
            );
      renewer = !_autoRenew
          ? null
          : SeatRenewer(
              policy: renewPolicy,
              api: _loggedIn ? _api : null,
              login: shared.call,
              onLog: _log,
              onStatus: _onRenewStatus,
              onEvent: _onRenewEvent,
              isEnvironmentAlive: serviceUp ? bg.isAlive : null,
              waitForSeat: () => _runner != null, // 좌석을 노리는 예약 루프가 아직 돌면 좌석이 없어도 기다린다
            );
      final hunter = runner, watcher = renewer; // 아래 비동기 함수 안에서 null 이 아님을 쓰려고 한 번 더 받는다
      _runner = hunter;
      _renewer = watcher;
      if (!mounted) {
        hunter?.stop();
        watcher?.stop();
      }
      if (mounted) setState(() => _phase = _Phase.running);
      // 두 루프는 서로 독립이다. 어느 한쪽에서 예외가 나도 다른 쪽이 멈추지 않은 채 남지 않도록, 각자 오류를 결과로 바꿔 둔다.
      await Future.wait([
        if (hunter != null)
          () async {
            try {
              final o = await hunter.run();
              huntOutcome = o;
              _runner = null;
              if (mounted) setState(() {}); // 실행 배너가 "연장만 지켜보는 중"으로 바뀌도록
              // 좌석을 갖게 됐거나 (좌석 바꾸기를 "아니요" 해서) 갖고 있는 좌석을 그대로 두기로 했으면, 자동 연장이 켜져 있는 한 끝내지 않고
              // 연장을 이어 간다. 사용자가 직접 멈췄거나 실패한 경우는 연장도 같이 끝낸다.
              final declined = o is Stopped && !hunter.isStopped;
              if (watcher != null && (o is Reserved || o is KeepingSeat || declined)) {
                huntAnnounced = true;
                watcher.nudge(); // 좌석이 있으니 기다리지 말고 바로 확인한다
                if (!declined && mounted) unawaited(_announceHunt(o, roomName));
              } else {
                watcher?.stop();
              }
            } catch (e) {
              huntOutcome ??= Crashed(e);
              _runner = null;
              watcher?.stop();
            }
          }(),
        if (watcher != null)
          () async {
            try {
              final o = await watcher.run();
              renewOutcome = o;
              _renewer = null;
              // 연장이 오류로 먼저 끝나도 예약 루프는 계속 돈다. 그럴 때는 바로 알린다 (그 밖의 이유는 예약 루프가 같이 알린다).
              if (o.reason == RenewEndReason.crashed && _runner != null && mounted) {
                renewAnnounced = true;
                unawaited(_announceRenewEnd(o));
              }
            } catch (e) {
              renewOutcome ??= RenewOutcome(RenewEndReason.crashed, message: '$e', error: e);
              _renewer = null;
            }
          }(),
      ]);
    } catch (e) {
      setupError = e;
    } finally {
      runner?.stop(); // 이미 끝났으면 아무 일도 없다
      renewer?.stop();
      _runner = null;
      _renewer = null;
      await RunMarker.end();
      await bg.stop();
    }
    if (!mounted) return;
    final hunted = huntOutcome ?? (hunt || setupError != null ? Crashed(setupError ?? '예약을 시작하지 못했어요') : null);
    await _finishRun(hunted, renewOutcome, roomName, huntAnnounced: huntAnnounced, renewAnnounced: renewAnnounced);
  }

  void _stop() {
    if (_phase != _Phase.running) return;
    setState(() => _phase = _Phase.stopping);
    _runner?.stop();
    _renewer?.stop();
  }

  /// "살아 있음" 기록을 남기는 간격과, 알림 문구를 고치는 최소 간격. 조회는 1~2초마다 오지만 이 정도면 충분하다.
  static const _beatEvery = Duration(seconds: 60);

  /// 좌석 상태가 그대로인지 (id, 사용 여부, 남은 시간). 그대로면 도면과 목록을 다시 만들지 않는다.
  static bool _sameSeats(List<Seat> a, List<Seat> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.id != y.id || x.occupied != y.occupied || x.active != y.active || x.remainingTime != y.remainingTime) return false;
    }
    return true;
  }

  void _beat(DateTime now) {
    if (_lastBeat != null && now.difference(_lastBeat!) < _beatEvery) return;
    _lastBeat = now;
    RunMarker.beat(at: now);
  }

  /// 포그라운드 서비스 알림 문구를 고친다. 문구가 바뀌었을 때만, [_beatEvery] 에 한 번 이하로 고친다.
  void _setServiceText(String title, String text, DateTime now) {
    if (_lastNotif != null && now.difference(_lastNotif!) < _beatEvery) return;
    final key = '$title|$text';
    if (key == _lastServiceText) return;
    _lastNotif = now;
    _lastServiceText = key;
    widget.services.background.update(title: title, text: text);
  }

  /// 조회할 때마다 불린다. 실행 배너만 갱신하고, 도면과 목록은 좌석 상태가 바뀐 때만 다시 그린다.
  void _onRunStatus(RunStatus s, String roomName) {
    if (!mounted) return;
    _runStatus.value = s;
    if (s.seats.isNotEmpty && !_sameSeats(_seatsApi, s.seats)) {
      setState(() {
        _seatsApi = s.seats;
        _seats = _sorted(s.seats);
      });
    }
    final now = DateTime.now();
    _beat(now);
    final shaky = s.errorStreak > 0 ? ' · 서버 응답 불안정' : '';
    final renew = _renewer != null ? ' · 자동 연장 켜짐' : '';
    _setServiceText('좌석 예약 실행 중', '$roomName · 빈 좌석 ${s.free}개 (${_hm(now)})$shaky$renew', now);
  }

  /// 자동 연장이 내 좌석을 확인할 때마다 불린다.
  void _onRenewStatus(RenewStatus s) {
    if (!mounted) return;
    _renewStatus.value = s;
    final now = DateTime.now();
    _beat(now);
    // 예약 루프가 도는 동안은 거기서 알림 문구를 정한다. 연장만 지켜보는 중일 때만 여기서 정한다.
    if (_runner != null) return;
    final held = s.held;
    final rem = held?.remainingMinutes;
    final shaky = s.errorStreak > 0 ? ' · 서버 응답 불안정' : '';
    _setServiceText(
      '자동 연장 실행 중',
      held == null
          ? '좌석을 기다리는 중 (${_hm(now)})$shaky'
          : '${held.seatCode}번 좌석${rem == null ? '' : ' · 남은 ${longRemaining(rem)}'} · 연장 ${s.renewed}번 (${_hm(now)})$shaky',
      now,
    );
  }

  /// 연장에 성공하거나 실패했을 때 알린다. 앱이 보이면 잠깐 뜨는 안내, 안 보이면 시스템 알림이다 (팝업으로 가로막지 않는다).
  void _onRenewEvent(RenewEvent e) {
    if (!mounted) return;
    final where = e.seat.roomName.isEmpty ? '' : '${e.seat.roomName} ';
    final String title, body;
    if (e.kind == RenewEventKind.renewed) {
      title = '연장했어요';
      body = '$where${e.seat.seatCode}번 좌석을 연장했어요. (이번 실행 ${e.count}번째)';
    } else {
      if (e.failStreak != 1) return; // 실패가 이어져도 처음 한 번만 알린다 (다시 시도하는 건 기록에 남는다)
      final retry = e.retryIn?.inMinutes ?? 5;
      title = '연장하지 못했어요';
      body = '$where${e.seat.seatCode}번 좌석: ${e.message}. $retry분 뒤에 다시 시도해요. 도서관 밖이라면 안으로 들어와 주세요.';
    }
    if (widget.services.desktop || !_inForeground) {
      unawaited(widget.services.notifier.show(title: title, body: body));
    } else {
      _toast('$title $body');
    }
  }

  /// 예약 루프가 끝난 이유를 알릴 문구. [watching] 이면 좌석을 받은 뒤 자동 연장을 이어 가는 중이다.
  _Notice? _huntNotice(RunOutcome outcome, String roomName, {bool watching = false}) {
    final minutes = widget.services.renewPolicy.threshold.inMinutes;
    return switch (outcome) {
      Reserved(:final seat) => _Notice(
          good: true,
          title: '배정 완료!',
          body: '$roomName ${seat.code}번 좌석이 배정됐어요. 도서관 홈페이지에서 확인해 주세요.'
              '${watching ? ' 자동 연장이 켜져 있어서, 이 좌석을 계속 지켜보다가 이용 종료 $minutes분 전에 연장해요. 앱을 끄지만 않으면 돼요.' : ''}',
        ),
      Stopped() => null,
      LoginRejected() => const _Notice(
          title: '로그인에 실패해 예약을 멈췄어요',
          body: '학번 또는 비밀번호가 올바르지 않아요. 여러 번 틀리면 5분간 로그인이 막히니, 도서관 홈페이지에서 먼저 로그인해 보고 다시 시도해 주세요.',
        ),
      ServerUnavailable(:final downFor, :final lastError) => _Notice(
          title: '서버가 응답하지 않아 예약을 멈췄어요',
          body: '${downFor.inMinutes}분 넘게 도서관 서버에 연결되지 않았어요. ($lastError) 잠시 뒤 다시 시작해 주세요.',
        ),
      ReserveRejected(:final seat, :final message) => _Notice(
          title: '${seat.code}번 좌석 예약이 계속 거절돼 멈췄어요',
          body: '$message\n이미 좌석을 배정받았거나 이용 제한 중일 수 있어요. 도서관 홈페이지에서 확인해 주세요.',
        ),
      KeepingSeat(:final held) => _Notice(
          good: true,
          title: '이미 가장 원하는 좌석이에요',
          body: watching
              ? '${held.roomName} ${held.seatCode}번 좌석을 이미 갖고 있어요. 더 바꿀 좌석이 없어서 예약은 마치고, 자동 연장만 계속해요.'
              : '${held.roomName} ${held.seatCode}번 좌석을 이미 갖고 있어요. 더 바꿀 좌석이 없어서 멈췄어요.',
        ),
      ReplaceFailed(:final wanted, :final old, :final restored, :final message) => _Notice(
          title: restored ? '${wanted.code}번으로 바꾸지 못했어요' : '좌석을 바꾸다 실패했어요',
          body: restored
              ? '${wanted.code}번 예약이 거절돼($message) 원래 ${old.seatCode}번 좌석을 다시 예약했어요. '
                  '${old.returnable ? '이용 시간은 새로 시작되고, 도착 확인(배정 확정)도 다시 해야 할 수 있어요. ' : ''}'
                  '다른 사람이 먼저 예약한 것 같아요. 다시 하려면 아래에서 시작해 주세요.'
              : '${old.seatCode}번 좌석을 반납했는데 ${wanted.code}번 예약이 거절됐고($message) '
                  '${old.seatCode}번도 다시 예약하지 못했어요. 지금 도서관 홈페이지에서 좌석을 확인해 주세요.',
        ),
      EnvironmentLost() => const _Notice(
          title: '백그라운드 실행이 끝나 예약을 멈췄어요',
          body: '시스템이 예약 서비스를 종료했어요. 앱을 열고 다시 시작해 주세요.',
        ),
      Crashed(:final error) => _Notice(title: '오류로 예약이 멈췄어요', body: '$error'),
    };
  }

  /// 자동 연장이 끝난 이유를 알릴 문구. 사용자가 멈춘 것이면 null.
  _Notice? _renewNotice(RenewOutcome o) {
    final seat = o.lastSeat?.seatCode;
    return switch (o.reason) {
      RenewEndReason.stopped => null,
      RenewEndReason.seatEnded => o.failing
          ? _Notice(
              title: '연장하지 못한 채 이용이 끝났어요',
              body: '${seat ?? ''}번 좌석을 연장하지 못했어요. (${o.message}) 도서관 안에서 홈페이지로 직접 연장해 보거나, 좌석을 다시 예약해 주세요.',
            )
          : _Notice(
              good: true,
              title: '좌석 이용이 끝났어요',
              body: '${seat ?? ''}번 좌석 이용이 끝나 자동 연장을 멈췄어요.${o.renewed > 0 ? ' 이번에 ${o.renewed}번 연장했어요.' : ''}',
            ),
      RenewEndReason.noSeat => const _Notice(
          title: '연장할 좌석이 없어요',
          body: '지금 갖고 있는 좌석이 없어서 자동 연장을 시작하지 않았어요. 좌석을 잡은 뒤 다시 시작해 주세요.',
        ),
      RenewEndReason.loginRejected => const _Notice(
          title: '로그인에 실패해 자동 연장을 멈췄어요',
          body: '학번 또는 비밀번호가 올바르지 않아요. 여러 번 틀리면 5분간 로그인이 막히니, 도서관 홈페이지에서 먼저 로그인해 보고 다시 시도해 주세요.',
        ),
      RenewEndReason.serverUnavailable => _Notice(
          title: '서버가 응답하지 않아 자동 연장을 멈췄어요',
          body: '${o.downFor?.inMinutes ?? 0}분 넘게 도서관 서버에 연결되지 않았어요. (${o.message}) 잠시 뒤 다시 시작해 주세요.',
        ),
      RenewEndReason.environmentLost => const _Notice(
          title: '백그라운드 실행이 끝나 자동 연장을 멈췄어요',
          body: '시스템이 서비스를 종료했어요. 앱을 열고 다시 시작해 주세요.',
        ),
      RenewEndReason.crashed => _Notice(title: '오류로 자동 연장이 멈췄어요', body: o.message),
    };
  }

  /// 안내를 알린다. 컴퓨터에서는 창이 떠 있어도 다른 창에 가려 있거나 다른 일을 하는 중일 수 있어서 늘 시스템 알림으로 알린다.
  /// 폰에서는 앱이 보일 때만 팝업, 안 보이면 알림이다. [loginRejectedMessage] 가 있으면 로그인 실패 전용 팝업을 쓴다.
  Future<void> _tell(_Notice notice, {String? loginRejectedMessage}) async {
    if (widget.services.desktop || !_inForeground) {
      await widget.services.notifier.show(title: notice.title, body: notice.body);
    }
    if (_inForeground) {
      if (loginRejectedMessage != null) {
        await _loginFailedDialog(LoginException(loginRejectedMessage));
      } else {
        await _dialog(notice.title, notice.body);
      }
    }
  }

  /// 좌석을 받았는데 자동 연장이 켜져 있어 세션을 끝내지 않을 때, 예약 결과만 먼저 알린다.
  Future<void> _announceHunt(RunOutcome outcome, String roomName) async {
    final notice = _huntNotice(outcome, roomName, watching: true);
    if (notice == null) return;
    _log(notice.title);
    try {
      await _tell(notice);
    } catch (e) {
      debugPrint('안내를 알리지 못했어요: $e');
    }
  }

  /// 예약 루프는 계속 도는데 자동 연장만 오류로 끝났을 때 바로 알린다.
  Future<void> _announceRenewEnd(RenewOutcome o) async {
    final notice = _renewNotice(o);
    if (notice == null) return;
    unawaited(CrashLog.record(o.error ?? o.message, null));
    _log(notice.title);
    try {
      await _tell(notice);
    } catch (e) {
      debugPrint('안내를 알리지 못했어요: $e');
    }
  }

  /// 끝난 이유를 사용자에게 알린다. 앱이 보이면 팝업, 안 보이면 시스템 알림, 어느 쪽이든 화면 위에 안내를 남긴다.
  /// 좌석을 받은 뒤 연장을 이어 가다 끝난 경우([huntAnnounced])에는 연장이 끝난 이유를, 그 밖에는 예약 루프의 결과를 알린다.
  Future<void> _finishRun(
    RunOutcome? hunt,
    RenewOutcome? renew,
    String roomName, {
    bool huntAnnounced = false,
    bool renewAnnounced = false,
  }) async {
    _Notice? notice;
    String? loginRejected; // 로그인이 거절돼 끝났으면 그 메시지
    Object? crash; // 오류로 끝났으면 그 오류
    if (hunt != null && !huntAnnounced) {
      notice = _huntNotice(hunt, roomName);
      if (hunt is LoginRejected) loginRejected = hunt.message;
      if (hunt is Crashed) crash = hunt.error;
    } else if (renew != null && !renewAnnounced) {
      notice = _renewNotice(renew);
      if (renew.reason == RenewEndReason.loginRejected) loginRejected = renew.message;
      if (renew.reason == RenewEndReason.crashed) crash = renew.error ?? renew.message;
    }
    if (crash != null) unawaited(CrashLog.record(crash, null));
    _log(notice?.title ?? (hunt == null || huntAnnounced ? '자동 연장을 멈췄어요' : '예약을 멈췄어요'));
    setState(() {
      _phase = _Phase.idle;
      _lastResult = notice;
      if (loginRejected != null) _loggedIn = false; // 다시 로그인하도록
    });
    if (notice == null) return;
    await _tell(notice, loginRejectedMessage: loginRejected);
  }

  Future<void> _showCrashLog() async {
    final list = await CrashLog.read();
    if (!mounted) return;
    final text = list.join('\n\n');
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('오류 기록'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontSize: 11.5))),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (c.mounted) Navigator.pop(c);
              _toast('복사했어요. 개발자에게 붙여 넣어 보내 주세요.');
            },
            child: const Text('복사'),
          ),
          TextButton(
            onPressed: () async {
              await CrashLog.clear();
              if (c.mounted) Navigator.pop(c);
              if (mounted) setState(() => _crashes = []);
            },
            child: const Text('지우기'),
          ),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('닫기')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runner?.stop();
    _renewer?.stop();
    _id.dispose();
    _pw.dispose();
    _interval.dispose();
    _range.dispose();
    _runStatus.dispose();
    _renewStatus.dispose();
    _runLog.dispose();
    super.dispose();
  }

  // ---------- 메뉴 ----------

  /// 확인 간격을 고치는 창. 예약이 도는 동안에는 바꿀 수 없다.
  Future<void> _editInterval() async {
    Navigator.pop(context); // 메뉴를 닫는다
    if (_running) {
      _toast('예약이 도는 동안에는 바꿀 수 없어요. 멈춘 뒤에 바꿔 주세요.');
      return;
    }
    final before = _interval.text;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('확인 간격(초)'),
        content: TextField(
          controller: _interval,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            helperText: '곧 비는 좌석이 있을 때의 간격이에요. 멀면 자동으로 늦춰요. 최소 ${_minIntervalSec.toInt()}초'.keepWords,
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('확인')),
        ],
      ),
    );
    if (!mounted) return;
    final value = double.tryParse(_interval.text.trim());
    if (ok != true || value == null) {
      if (ok == true) _toast('숫자로 입력해 주세요. 예: 1.5');
      setState(() => _interval.text = before);
      return;
    }
    setState(() => _interval.text = '${value.clamp(_minIntervalSec, 60)}'.replaceAll(RegExp(r'\.0$'), ''));
    final p = await SharedPreferences.getInstance();
    await p.setString('interval', _interval.text);
  }

  void _openLog() {
    Navigator.pop(context); // 메뉴를 닫는다
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RunLogPage(log: _runLog)));
  }

  /// 메인 화면에 둘 필요가 없는 것들 (기록, 설정, 업데이트, 배터리, 오류 기록).
  Widget _menu() {
    final scheme = Theme.of(context).colorScheme;
    return Drawer(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              child: Row(children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: scheme.primary,
                  child: const Icon(Icons.event_seat, size: 20, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('도서관 좌석 예약', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                    if (_version.isNotEmpty)
                      Text('버전 $_version', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ]),
                ),
              ]),
            ),
            const Divider(height: 1),
            const SizedBox(height: 4),
            ListTile(leading: const Icon(Icons.history), title: const Text('진행 기록'), onTap: _openLog),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('확인 간격'),
              subtitle: Text('${_interval.text.trim()}초'),
              onTap: _editInterval,
            ),
            const Divider(height: 16, indent: 16, endIndent: 16),
            if (!widget.services.desktop) // 배터리 제한은 폰에만 있다
              ListTile(
                leading: Icon(_batteryOk ? Icons.battery_charging_full : Icons.battery_alert),
                title: const Text('배터리 제한'),
                isThreeLine: !_batteryOk,
                subtitle: Text(
                    (_batteryOk ? '풀려 있어요' : '켜져 있으면 화면을 끈 채 오래 두었을 때 예약이 멈출 수 있어요').keepWords),
                trailing: _batteryOk ? null : TextButton(onPressed: _requestBattery, child: const Text('제한 풀기')),
              ),
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: Text(_checkingUpdate ? '확인하는 중…' : '업데이트 확인'),
              subtitle: Text(_version.isEmpty ? '앱 버전' : '앱 버전 $_version'),
              onTap: _checkingUpdate || _updating
                  ? null
                  : () {
                      Navigator.pop(context);
                      _checkUpdate(manual: true);
                    },
            ),
            if (_crashes.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.bug_report_outlined),
                title: Text('오류 기록 ${_crashes.length}건'),
                onTap: () {
                  Navigator.pop(context);
                  _showCrashLog();
                },
              ),
          ],
        ),
      ),
    );
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (c) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: '메뉴',
            onPressed: () => Scaffold.of(c).openDrawer(),
          ),
        ),
        title: const Text('도서관 좌석 예약'),
      ),
      drawer: _menu(),
      body: SafeArea(
        // 컴퓨터의 넓은 창에서도 폰 화면처럼 한 줄로 보이게 폭을 제한하고 가운데에 둔다.
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (_update != null)
                  UpdateBanner(
                    currentVersion: _version,
                    newVersion: _update!.version,
                    notes: _update!.notes,
                    progress: _updateProgress,
                    busy: _updating,
                    blocked: _running && !widget.services.desktop,
                    desktop: widget.services.desktop,
                    onUpdate: _installUpdate,
                  ),
                if (_lastResult != null && !_running) _resultCard(_lastResult!),
                if (_running) _runningBanner(),
                _loginStep(),
                _roomStep(),
                _seatStep(),
                _startStep(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _runningBanner() {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onPrimaryContainer;
    return BannerCard(
      color: scheme.primaryContainer,
      leading: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: fg)),
      // 조회마다 바뀌는 값은 여기만 다시 그린다 (화면 전체를 다시 그리지 않는다).
      child: ListenableBuilder(
        listenable: Listenable.merge([_runStatus, _renewStatus]),
        builder: (context, _) {
              final s = _runStatus.value;
              final soonest = s?.soonest;
              // 좌석을 받은 뒤 자동 연장만 이어 가는 중이면 예약 루프는 없다.
              final watching = _runner == null && _renewer != null && _phase == _Phase.running;
              final title = switch (_phase) {
                _Phase.starting => '예약을 시작하는 중이에요',
                _Phase.stopping => '멈추는 중이에요',
                _ => watching ? '자동 연장을 지켜보는 중이에요' : '빈 좌석을 찾는 중이에요',
              };
              return Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 3, children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: fg)),
                if (!watching)
                  Text(
                    s == null ? '첫 확인을 기다리는 중…' : '선택한 ${s.wanted}개 중 지금 빈 좌석 ${s.free}개 · ${s.checks}회 확인',
                    style: TextStyle(fontSize: 12.5, color: fg),
                  ),
                if (!watching && s != null && s.errorStreak > 0)
                  Text('서버 응답이 불안정해요 (${s.errorStreak}번째 재시도). 자동으로 계속 시도해요.',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.error)),
                if (!watching && soonest != null)
                  Text('가장 빨리 비는 좌석: ${soonest.code}번 (이용 종료까지 ${longRemaining(soonest.remainingMinutes!)})',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: fg)),
                ..._renewLines(fg, scheme),
                Text(
                    (widget.services.desktop
                            ? '창을 최소화하거나 가려도 계속 동작해요. 창을 닫으면 예약도 멈춰요.'
                            : '홈 화면으로 나가도 계속 동작해요. 최근 앱 목록에서 밀어서 끄면 예약도 멈춰요.')
                        .keepWords,
                    style: TextStyle(fontSize: 12, height: 1.35, color: fg.withValues(alpha: 0.8))),
              ]);
        },
      ),
    );
  }

  /// 실행 배너에 붙는 자동 연장 상태 (자동 연장이 켜져 있을 때만).
  List<Widget> _renewLines(Color fg, ColorScheme scheme) {
    if (_renewer == null) return const [];
    final p = widget.services.renewPolicy;
    final r = _renewStatus.value;
    final held = r?.held;
    final rem = held?.remainingMinutes;
    final style = TextStyle(fontSize: 12.5, color: fg);
    final String line;
    if (r == null) {
      line = '자동 연장: 내 좌석을 확인하는 중…';
    } else if (held == null) {
      line = '자동 연장: 연장할 좌석이 아직 없어요. 좌석이 생기면 지켜봐요.';
    } else {
      line = '자동 연장: ${held.seatCode}번 좌석${rem == null ? '' : ' · 이용 종료까지 ${longRemaining(rem)}'}'
          ' (${_hm(r.checkedAt)} 확인). 종료 ${p.threshold.inMinutes}분 전부터 연장해요.';
    }
    return [
      Text(line.keepWords, style: style),
      if (r != null && r.renewed > 0) Text('이번 실행에서 ${r.renewed}번 연장했어요.', style: style),
      if (r != null && r.failStreak > 0)
        Text('연장에 실패했어요 (${r.lastFailure}). ${p.retryAfter.inMinutes}분마다 다시 시도해요.'.keepWords,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.error)),
      if (r != null && r.errorStreak > 0)
        Text('서버 응답이 불안정해요 (${r.errorStreak}번째). 자동으로 계속 시도해요.',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.error)),
    ];
  }

  /// 마지막 결과 안내 (배정 완료, 중단 사유, 중간에 멈춤). 닫을 수 있다.
  Widget _resultCard(_Notice n) {
    final scheme = Theme.of(context).colorScheme;
    final bg = n.good ? const Color(0xFFE6F4E8) : scheme.errorContainer;
    final fg = n.good ? const Color(0xFF1B5E20) : scheme.onErrorContainer;
    return BannerCard(
      color: bg,
      leading: Icon(n.good ? Icons.check_circle : Icons.warning_amber_rounded, color: fg),
      trailing: IconButton(
        tooltip: '닫기',
        visualDensity: VisualDensity.compact,
        onPressed: () => setState(() => _lastResult = null),
        icon: Icon(Icons.close, size: 20, color: fg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 3, children: [
        Text(n.title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: fg)),
        Text(n.body.keepWords, style: TextStyle(fontSize: 12.5, height: 1.4, color: fg)),
      ]),
    );
  }

  Widget _loginStep() {
    if (_loggedIn) {
      return StepCard(
        step: 1,
        title: '로그인',
        subtitle: '${_id.text.trim()} 님으로 로그인됨',
        done: true,
        trailing: TextButton(
          onPressed: _running ? null : () => setState(() => _loggedIn = false),
          child: const Text('변경'),
        ),
        child: const SizedBox.shrink(),
      );
    }
    return StepCard(
      step: 1,
      title: '로그인',
      subtitle: '도서관 홈페이지(oasis.ssu.ac.kr)와 같은 학번/비밀번호예요',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _id,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.username],
          decoration: const InputDecoration(labelText: '학번', prefixIcon: Icon(Icons.person_outline)),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pw,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _login(),
          decoration: const InputDecoration(labelText: '비밀번호', prefixIcon: Icon(Icons.lock_outline)),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: _savePw,
          onChanged: (v) => setState(() => _savePw = v ?? true),
          title: Text(widget.services.desktop ? '이 컴퓨터에 안전하게 저장 (다음부터 자동 입력)' : '이 폰에 안전하게 저장 (다음부터 자동 입력)'),
          subtitle: Text(widget.services.desktop ? '암호화되어 컴퓨터 안에만 보관돼요. 어디로도 전송되지 않아요.' : '암호화되어 폰 안에만 보관돼요. 어디로도 전송되지 않아요.',
              style: const TextStyle(fontSize: 11.5)),
        ),
        const SizedBox(height: 4),
        FilledButton(
          onPressed: _loggingIn ? null : _login,
          child: _loggingIn
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('로그인'),
        ),
      ]),
    );
  }

  Widget _roomStep() {
    Widget body;
    if (_loadingRooms && _rooms.isEmpty) {
      body = const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
    } else if (_roomsError != null && _rooms.isEmpty) {
      body = Column(children: [
        Text(_roomsError!),
        TextButton(onPressed: _loadRooms, child: const Text('다시 시도')),
      ]);
    } else {
      body = LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth / 3 - 0.01; // 한 줄에 3개
        return Wrap(children: [
          for (final r in _rooms)
            SizedBox(
              width: w,
              child: RoomGauge(room: r, selected: r.id == _roomId, onTap: () => _selectRoom(r)),
            ),
        ]);
      });
    }
    return StepCard(
      step: 2,
      title: '열람실 선택',
      done: _room != null,
      trailing: IconButton(
        tooltip: '새로고침',
        onPressed: _loadingRooms ? null : _loadRooms,
        icon: const Icon(Icons.refresh),
      ),
      child: body,
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: TextStyle(fontSize: 13.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  Widget _seatStep() {
    final room = _room;
    Widget body;
    if (room == null) {
      body = _hint('먼저 위에서 열람실을 선택해 주세요.');
    } else if (!_loggedIn) {
      body = _hint('로그인하면 이 열람실의 좌석이 나타나요.');
    } else if (_loadingSeats && _seats.isEmpty) {
      body = const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
    } else if (_seats.isEmpty) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _hint('좌석을 아직 불러오지 못했어요.'),
        TextButton.icon(onPressed: _loadSeats, icon: const Icon(Icons.refresh), label: const Text('다시 불러오기')),
      ]);
    } else {
      final layout = _layout;
      final showMap = layout != null && _mapView;
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (layout != null) ...[
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, icon: Icon(Icons.map_outlined), label: Text('도면으로 보기')),
                ButtonSegment(value: false, icon: Icon(Icons.grid_view), label: Text('목록으로 보기')),
              ],
              selected: {_mapView},
              onSelectionChanged: (v) => setState(() => _mapView = v.first),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (showMap) SeatMapLegend(layout: layout) else const SeatLegend(),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 4, children: [
          ActionChip(
            avatar: const Icon(Icons.done_all, size: 18),
            label: const Text('전체 선택'),
            visualDensity: VisualDensity.compact,
            onPressed: _running ? null : _selectAll,
          ),
          ActionChip(
            avatar: const Icon(Icons.clear, size: 18),
            label: const Text('모두 해제'),
            visualDensity: VisualDensity.compact,
            onPressed: _running ? null : _clearAll,
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _range,
              enabled: !_running,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '번호로 한 번에 선택',
                hintText: '예: 25-40, 52',
              ),
              onSubmitted: (_) => _applyRange(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(onPressed: _running ? null : _applyRange, child: const Text('적용')),
        ]),
        const SizedBox(height: 14),
        if (showMap) ...[
          SeatMapPreview(layout: layout, seats: _seatsApi, selected: _selected, onOpen: _openBigMap),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _openBigMap,
            icon: const Icon(Icons.open_in_full, size: 18),
            label: Text(_running ? '도면 크게 보기' : '도면에서 좌석 고르기'),
          ),
        ] else
          SeatGrid(seats: _seats, selected: _selected, onTap: _toggle),
      ]);
    }
    return StepCard(
      step: 3,
      title: '좌석 선택',
      subtitle: room == null ? null : '${room.name} · ${_selected.length}개 선택됨',
      done: _selected.isNotEmpty,
      trailing: (room != null && _loggedIn)
          ? IconButton(
              tooltip: '좌석 새로고침',
              onPressed: _loadingSeats || _running ? null : _loadSeats,
              icon: _loadingSeats
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            )
          : null,
      child: body,
    );
  }

  Widget _startStep() {
    final scheme = Theme.of(context).colorScheme;
    final renew = widget.services.renewPolicy;
    return StepCard(
      step: 4,
      title: '예약 시작',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          tileColor: kAppBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          secondary: Icon(Icons.autorenew, color: scheme.primary),
          value: _autoRenew,
          onChanged: _running ? null : _setAutoRenew,
          title: const Text('자동 연장', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('이용 종료 ${renew.threshold.inMinutes}분 전부터 연장해요. 안 되면 ${renew.retryAfter.inMinutes}분 뒤 다시 시도해요.'.keepWords,
              style: TextStyle(fontSize: 12, height: 1.35, color: scheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: switch (_phase) {
              _Phase.idle => _start,
              _Phase.running => _stop,
              _ => null, // 시작하는 중, 멈추는 중에는 누를 수 없다
            },
            style: _phase == _Phase.running ? FilledButton.styleFrom(backgroundColor: scheme.error) : null,
            icon: switch (_phase) {
              _Phase.idle => const Icon(Icons.play_arrow),
              _Phase.running => const Icon(Icons.stop),
              _ => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            },
            label: Text(
              switch (_phase) {
                _Phase.starting => '시작하는 중…',
                _Phase.stopping => '멈추는 중…',
                _Phase.running => '중지하기',
                _Phase.idle => _selected.isEmpty ? (_autoRenew ? '자동 연장만 시작' : '예약 시작') : '선택한 ${_selected.length}개 좌석 예약 시작',
              },
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ]),
    );
  }
}
