import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api.dart';
import 'seat_layout.dart';
import 'seat_map.dart';
import 'update_check.dart';
import 'widgets.dart';

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '도서관 좌석 예약',
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFF4F5F9),
        ),
        home: const WithForegroundTask(child: HomePage()),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _minIntervalSec = 1.0;
  static const _defaultRoomId = 53;

  final _secure = const FlutterSecureStorage();
  final _id = TextEditingController();
  final _pw = TextEditingController();
  final _interval = TextEditingController(text: '1.5');
  final _range = TextEditingController();
  final _logScroll = ScrollController();

  LibApi _api = LibApi();
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

  bool _running = false;
  int _checks = 0;
  String _status = '';
  String _soonest = ''; // 고른 좌석 중 가장 빨리 비는 좌석 안내

  // 앱 안 업데이트
  final _updater = UpdateChecker();
  String _version = ''; // 지금 설치된 버전
  UpdateInfo? _update; // 더 높은 버전이 있으면 그 정보
  bool _checkingUpdate = false;
  bool _updating = false;
  double? _updateProgress;
  final List<String> _logs = [];

  Room? get _room {
    for (final r in _rooms) {
      if (r.id == _roomId) return r;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _initForeground();
    _restore().then((_) {
      _loadLayout();
      _loadRooms();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
  }

  // ---------- 업데이트 ----------

  /// 새 버전이 있는지 확인한다. 앱을 켤 때는 조용히(실패해도 아무 말 없이), 직접 누르면 결과를 알려 준다.
  Future<void> _checkUpdate({bool manual = false}) async {
    if (_checkingUpdate || _updating) return;
    setState(() => _checkingUpdate = true);
    try {
      final current = (await PackageInfo.fromPlatform()).version;
      if (mounted) setState(() => _version = current);
      final latest = await _updater.latest();
      if (!mounted) return;
      if (latest != null && isNewerVersion(current, latest.version)) {
        setState(() => _update = latest);
        if (manual) _toast('새 버전 ${latest.version}이 있어요. 맨 위의 업데이트 버튼을 눌러 주세요.');
      } else if (manual) {
        _toast('최신 버전이에요. ($current)');
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
  Future<void> _installUpdate() async {
    final u = _update;
    if (u == null || _updating) return;
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
      final apk = await _updater.download(u, dir.path, onProgress: (p) {
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
    final layout = id == null ? null : await SeatLayout.load(id);
    if (mounted && id == _roomId) setState(() => _layout = layout);
  }

  void _initForeground() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'lib_seat_service',
        channelName: '좌석 예약 실행 중',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  // ---------- 저장 / 복원 ----------

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final id = await _secure.read(key: 'id');
    final pw = await _secure.read(key: 'pw');
    final roomId = p.getInt('roomId') ?? _defaultRoomId;
    if (!mounted) return;
    setState(() {
      _id.text = id ?? '';
      _pw.text = pw ?? '';
      _savePw = pw != null || id == null;
      _interval.text = p.getString('interval') ?? '1.5';
      _roomId = roomId;
      _selected = p.getStringList('sel_$roomId') ?? [];
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('interval', _interval.text.trim());
    if (_roomId != null) {
      await p.setInt('roomId', _roomId!);
      await p.setStringList('sel_$_roomId', _selected);
    }
    await _secure.write(key: 'id', value: _id.text.trim());
    if (_savePw) {
      await _secure.write(key: 'pw', value: _pw.text);
    } else {
      await _secure.delete(key: 'pw');
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
          Text(body),
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
    final t = DateTime.now().toString().substring(11, 19);
    setState(() {
      _logs.add('$t  $m');
      if (_logs.length > 200) _logs.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
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
      final api = LibApi();
      await api.login(_id.text.trim(), _pw.text);
      _api = api;
      if (!mounted) return;
      setState(() => _loggedIn = true);
      await _save();
      await _loadSeats();
    } on LoginException catch (e) {
      await _loginFailedDialog(e);
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
    await _save(); // 이전 열람실 선택 저장
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
    _save();
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

  void _selectWhere(bool Function(Seat) test) {
    setState(() => _selected = _seats.where((s) => s.active && test(s)).map((s) => s.code).toList());
    _save();
  }

  void _clearAll() {
    setState(() => _selected = []);
    _save();
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
    _save();
    _toast('${picked.length}개 좌석을 선택했어요.');
  }

  // ---------- 4. 예약 ----------

  Future<void> _start() async {
    if (_roomId == null || _room == null) {
      _toast('열람실을 먼저 선택해 주세요.');
      return;
    }
    if (_selected.isEmpty) {
      _toast('예약할 좌석을 하나 이상 선택해 주세요.');
      return;
    }
    if (_id.text.trim().isEmpty || _pw.text.isEmpty) {
      _toast('학번과 비밀번호를 입력해 주세요.');
      return;
    }
    final sec = double.tryParse(_interval.text.trim()) ?? 1.5;
    final interval = Duration(milliseconds: (sec.clamp(_minIntervalSec, 60) * 1000).round());
    await _save();

    await FlutterForegroundTask.requestNotificationPermission();
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: '좌석 예약 실행 중',
      notificationText: '${_room!.name} · ${_selected.length}개 좌석 감시 중',
    );
    await WakelockPlus.enable();
    setState(() {
      _running = true;
      _checks = 0;
      _soonest = '';
      _status = '시작하는 중…';
    });
    unawaited(_run(interval));
  }

  void _stop() => setState(() => _running = false);

  Future<void> _finish() async {
    await FlutterForegroundTask.stopService();
    await WakelockPlus.disable();
    if (mounted) setState(() => _running = false);
  }

  /// 고른 좌석 중 사용 중이면서 이용이 가장 먼저 끝나는 좌석. 없으면 빈 문자열.
  String _soonestNote(List<Seat> seats, List<String> wanted) {
    Seat? best;
    for (final s in seats) {
      if (!wanted.contains(s.code) || s.available || s.remainingMinutes == null) continue;
      if (best == null || s.remainingMinutes! < best.remainingMinutes!) best = s;
    }
    if (best == null) return '';
    return '가장 빨리 비는 좌석: ${best.code}번 (이용 종료까지 ${longRemaining(best.remainingMinutes!)})';
  }

  Seat? _pick(List<Seat> seats, List<String> wanted) {
    final byCode = {for (final s in seats) s.code: s};
    for (final c in wanted) {
      final s = byCode[c];
      if (s != null && s.available) return s;
    }
    return null;
  }

  Future<void> _run(Duration interval) async {
    final uid = _id.text.trim();
    final pw = _pw.text;
    final roomId = _roomId!;
    final roomName = _room?.name ?? '';
    final wanted = List<String>.from(_selected);
    var relogins = 0;
    try {
      if (!_loggedIn) {
        _log('로그인 중…');
        final api = LibApi();
        await api.login(uid, pw);
        _api = api;
        if (mounted) setState(() => _loggedIn = true);
      }
      _log('$roomName · 좌석 ${wanted.join(', ')} 감시 시작');
      while (_running) {
        try {
          final seats = await _api.seats(roomId);
          relogins = 0;
          final free = seats.where((s) => wanted.contains(s.code) && s.available).length;
          if (mounted) {
            setState(() {
              _checks++;
              _status = '선택한 ${wanted.length}개 중 지금 빈 좌석 $free개';
              _soonest = _soonestNote(seats, wanted);
              // 도면과 목록의 좌석 상태·남은 시간도 매 조회마다 새로 고친다.
              _seatsApi = seats;
              _seats = _sorted(seats);
            });
          }
          final seat = _pick(seats, wanted);
          if (seat == null) {
            _log('빈 좌석 없음');
          } else {
            _log('${seat.code}번 좌석이 비었어요. 예약 시도');
            final res = await _api.reserve(seat.id);
            if (res['success'] == true) {
              _log('배정 완료! ${seat.code}번 좌석');
              await FlutterForegroundTask.updateService(
                notificationTitle: '배정 완료',
                notificationText: '$roomName ${seat.code}번 좌석',
              );
              unawaited(_dialog('배정 완료!', '$roomName ${seat.code}번 좌석이 배정됐어요.\n도서관 홈페이지에서 확인해 주세요.'));
              break;
            }
            _log('예약 실패: ${res['code']} ${res['message']}');
          }
        } on SessionException catch (e) {
          // 재로그인을 반복하면 계정이 잠길 수 있으니 연속 2회까지만 시도한다.
          if (++relogins > 2) {
            _log('조회가 계속 거부되어 중단합니다: $e');
            unawaited(_dialog('예약을 중단했어요', '서버가 계속 요청을 거부해요. 잠시 후 다시 시도해 주세요.', detail: e.message));
            break;
          }
          _log('로그인이 만료되어 다시 로그인합니다');
          final api = LibApi();
          await api.login(uid, pw);
          _api = api;
          continue;
        } on DioException catch (e) {
          _log('네트워크 오류, 다시 시도: ${e.message ?? e.type.name}');
        }
        await Future.delayed(interval);
      }
    } on LoginException catch (e) {
      _log('로그인 실패, 계정 잠금 방지를 위해 중단합니다: $e');
      if (mounted) setState(() => _loggedIn = false);
      unawaited(_loginFailedDialog(e));
    } catch (e) {
      _log('오류로 중단: $e');
    } finally {
      _log('종료');
      await _finish();
    }
  }

  @override
  void dispose() {
    _id.dispose();
    _pw.dispose();
    _interval.dispose();
    _range.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('도서관 좌석 예약', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFFF4F5F9),
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
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
                blocked: _running,
                onUpdate: _installUpdate,
              ),
            if (_running) _runningBanner() else _intro(),
            _loginStep(),
            _roomStep(),
            _seatStep(),
            _startStep(),
          ],
        ),
      ),
    );
  }

  Widget _intro() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.event_seat, color: scheme.onPrimaryContainer),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '원하는 좌석을 골라 두면, 그중 한 자리가 비는 순간 자동으로 예약해 줘요. 아래 순서대로 따라 해 보세요.',
            style: TextStyle(color: scheme.onPrimaryContainer, height: 1.4),
          ),
        ),
      ]),
    );
  }

  Widget _runningBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('빈 좌석을 찾는 중이에요', style: TextStyle(fontWeight: FontWeight.bold, color: scheme.onTertiaryContainer)),
            Text('$_status · $_checks회 확인',
                style: TextStyle(fontSize: 12.5, color: scheme.onTertiaryContainer)),
            if (_soonest.isNotEmpty)
              Text(_soonest, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.onTertiaryContainer)),
            Text('앱을 나가도 계속 동작해요. 알림창의 알림은 지우지 마세요.',
                style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer)),
          ]),
        ),
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
          decoration: const InputDecoration(labelText: '학번', prefixIcon: Icon(Icons.person_outline), border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pw,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _login(),
          decoration: const InputDecoration(labelText: '비밀번호', prefixIcon: Icon(Icons.lock_outline), border: OutlineInputBorder()),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: _savePw,
          onChanged: (v) => setState(() => _savePw = v ?? true),
          title: const Text('이 폰에 안전하게 저장 (다음부터 자동 입력)'),
          subtitle: const Text('암호화되어 폰 안에만 보관돼요. 어디로도 전송되지 않아요.', style: TextStyle(fontSize: 11.5)),
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
      subtitle: '예약할 열람실을 눌러 주세요',
      done: _room != null,
      trailing: IconButton(
        tooltip: '새로고침',
        onPressed: _loadingRooms ? null : _loadRooms,
        icon: const Icon(Icons.refresh),
      ),
      child: body,
    );
  }

  Widget _seatStep() {
    final room = _room;
    Widget body;
    if (room == null) {
      body = const Text('먼저 위에서 열람실을 선택해 주세요.');
    } else if (!_loggedIn) {
      body = const Text('로그인하면 이 열람실의 좌석이 나타나요.');
    } else if (_loadingSeats && _seats.isEmpty) {
      body = const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
    } else if (_seats.isEmpty) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('좌석을 아직 불러오지 못했어요.'),
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
        const SizedBox(height: 10),
        Text(
            showMap
                ? '도면을 누르면 크게 열려요. 거기서 좌석을 눌러 고르세요. 사용 중인 좌석도 고를 수 있고, 비는 순간 바로 예약해요.'
                : '눌러서 고르세요. 사용 중인 좌석도 고를 수 있어요. 비는 순간 바로 예약해요.',
            style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text('노란 숫자는 우선순위예요. 먼저 고른 좌석부터 예약해요.',
            style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        if (_seats.any((s) => s.remainingMinutes != null)) ...[
          const SizedBox(height: 4),
          Text(
              '사용 중인 좌석 밑의 시간은 이용 종료까지 남은 시간이에요 (1:40 = 1시간 40분). '
              '${_running ? '예약이 실행되는 동안 자동으로 갱신돼요.' : '새로고침 버튼을 누르면 갱신돼요.'}',
              style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 4, children: [
          ActionChip(
            avatar: const Icon(Icons.done_all, size: 18),
            label: const Text('전체 선택'),
            onPressed: _running ? null : () => _selectWhere((_) => true),
          ),
          ActionChip(
            avatar: const Icon(Icons.event_seat, size: 18),
            label: const Text('지금 빈 좌석만'),
            onPressed: _running ? null : () => _selectWhere((s) => s.available),
          ),
          ActionChip(
            avatar: const Icon(Icons.clear, size: 18),
            label: const Text('모두 해제'),
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
                border: OutlineInputBorder(),
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
        if (_selected.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('선택한 좌석 (우선순위 순)',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(_selected.join(' → '), maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
        ],
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
    return StepCard(
      step: 4,
      title: '예약 시작',
      subtitle: '시작하면 화면이 꺼져도 계속 확인해요',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _running ? _stop : _start,
            style: _running ? FilledButton.styleFrom(backgroundColor: scheme.error) : null,
            icon: Icon(_running ? Icons.stop : Icons.play_arrow),
            label: Text(
              _running ? '중지하기' : (_selected.isEmpty ? '예약 시작' : '선택한 ${_selected.length}개 좌석 예약 시작'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          title: const Text('고급 설정', style: TextStyle(fontSize: 14)),
          children: [
            TextField(
              controller: _interval,
              enabled: !_running,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '확인 간격(초)',
                helperText: '짧을수록 빠르지만 서버에 부담이 가요. 최소 1초',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Text(_version.isEmpty ? '앱 버전' : '앱 버전 $_version',
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              TextButton(
                onPressed: _checkingUpdate || _updating ? null : () => _checkUpdate(manual: true),
                child: Text(_checkingUpdate ? '확인하는 중…' : '업데이트 확인'),
              ),
            ]),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text('진행 기록 (${_logs.length})', style: const TextStyle(fontSize: 14)),
          children: [
            Container(
              height: 180,
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFFF1F1F4), borderRadius: BorderRadius.circular(8)),
              child: _logs.isEmpty
                  ? const Center(child: Text('아직 기록이 없어요.'))
                  : ListView.builder(
                      controller: _logScroll,
                      itemCount: _logs.length,
                      itemBuilder: (_, i) => Text(_logs[i], style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                    ),
            ),
          ],
        ),
      ]),
    );
  }
}
