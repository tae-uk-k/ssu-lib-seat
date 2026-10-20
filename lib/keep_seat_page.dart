import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'my_seat_page.dart' show clockText;
import 'seat_keeper.dart';
import 'seat_layout.dart';
import 'seat_map.dart';
import 'widgets.dart';

/// 종료 시각을 어떻게 정하는지.
enum KeepEndMode {
  /// 정하지 않는다 (내가 멈출 때까지).
  none,

  /// 시작하고 나서 이만큼 뒤.
  after,

  /// 하루 중 정한 시각 (이미 지났으면 내일).
  clock,
}

/// 좌석 유지 설정. 껐다 켜도 남는다.
class KeepSettings {
  const KeepSettings({
    this.roomId,
    this.seats = const [],
    this.endMode = KeepEndMode.none,
    this.endMinutes = 120,
    this.endHour = 22,
    this.endMinute = 0,
    this.cancelAtEnd = true,
  });

  final int? roomId;

  /// 우선순위 순서의 좌석 번호.
  final List<String> seats;
  final KeepEndMode endMode;
  final int endMinutes;
  final int endHour, endMinute;

  /// 종료 시각이 돼서 마칠 때 배정만 된 좌석이면 취소한다.
  final bool cancelAtEnd;

  KeepSettings copyWith({
    int? roomId,
    List<String>? seats,
    KeepEndMode? endMode,
    int? endMinutes,
    int? endHour,
    int? endMinute,
    bool? cancelAtEnd,
  }) =>
      KeepSettings(
        roomId: roomId ?? this.roomId,
        seats: seats ?? this.seats,
        endMode: endMode ?? this.endMode,
        endMinutes: endMinutes ?? this.endMinutes,
        endHour: endHour ?? this.endHour,
        endMinute: endMinute ?? this.endMinute,
        cancelAtEnd: cancelAtEnd ?? this.cancelAtEnd,
      );

  /// [now] 에 시작한다면 언제 끝나는지. 정하지 않았으면 null.
  DateTime? endAtFrom(DateTime now) {
    switch (endMode) {
      case KeepEndMode.none:
        return null;
      case KeepEndMode.after:
        return now.add(Duration(minutes: endMinutes));
      case KeepEndMode.clock:
        final today = DateTime(now.year, now.month, now.day, endHour, endMinute);
        return today.isAfter(now.add(const Duration(minutes: 1))) ? today : today.add(const Duration(days: 1));
    }
  }

  static const _room = 'keep_room';
  static const _mode = 'keep_endMode';
  static const _after = 'keep_endAfter';
  static const _clock = 'keep_endClock';
  static const _cancel = 'keep_cancelAtEnd';
  static String _sel(int room) => 'keep_sel_$room';

  static Future<KeepSettings> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final room = p.getInt(_room);
      final clock = (p.getString(_clock) ?? '22:00').split(':');
      return KeepSettings(
        roomId: room,
        seats: room == null ? const [] : (p.getStringList(_sel(room)) ?? const []),
        endMode: KeepEndMode.values.firstWhere((m) => m.name == p.getString(_mode), orElse: () => KeepEndMode.none),
        endMinutes: p.getInt(_after) ?? 120,
        endHour: int.tryParse(clock.first) ?? 22,
        endMinute: clock.length > 1 ? (int.tryParse(clock[1]) ?? 0) : 0,
        cancelAtEnd: p.getBool(_cancel) ?? true,
      );
    } catch (_) {
      return const KeepSettings();
    }
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      final room = roomId;
      if (room != null) {
        await p.setInt(_room, room);
        await p.setStringList(_sel(room), seats);
      }
      await p.setString(_mode, endMode.name);
      await p.setInt(_after, endMinutes);
      await p.setString(_clock, '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}');
      await p.setBool(_cancel, cancelAtEnd);
    } catch (_) {}
  }

  /// 저장된 열람실별 좌석 선택을 읽는다 (열람실을 바꿀 때).
  static Future<List<String>> savedSeats(int room) async {
    try {
      return (await SharedPreferences.getInstance()).getStringList(_sel(room)) ?? const [];
    } catch (_) {
      return const [];
    }
  }
}

/// 메뉴의 "좌석 유지". 고른 좌석을 내가 멈출 때까지 계속 갖고 있게 한다. 배정이 풀리거나 취소돼도, 도서관 밖에서도 다시 예약한다.
class KeepSeatPage extends StatefulWidget {
  const KeepSeatPage({
    super.key,
    required this.loggedIn,
    required this.rooms,
    required this.status,
    required this.running,
    required this.initial,
    required this.loadSeats,
    required this.loadLayout,
    required this.loadMine,
    required this.onStart,
    required this.onStop,
    required this.onLogin,
    required this.onSave,
    this.blockedReason,
    this.autoRenewOn = false,
    this.lastResult,
  });

  final bool loggedIn;

  /// 고를 수 있는 열람실 (즉시 배정되는 열람실).
  final List<Room> rooms;

  /// 도는 중일 때의 지금 상태. 도는 중이 아니면 null.
  final ValueListenable<KeepStatus?> status;

  /// 좌석 유지가 시작됐거나 도는 중인지.
  final bool running;
  final KeepSettings initial;

  /// 열람실의 좌석을 API 순서 그대로 읽어 온다. 실패하면 예외를 던진다.
  final Future<List<Seat>> Function(int roomId) loadSeats;

  /// 열람실의 도면 (없으면 null).
  final Future<SeatLayout?> Function(int roomId) loadLayout;

  /// 지금 내가 예약해 갖고 있는 좌석들을 서버에서 읽어 온다 ("내 좌석 선택" 버튼). 실패하면 예외를 던진다.
  final Future<List<MyCharge>> Function() loadMine;
  final Future<void> Function(KeepSettings settings) onStart;
  final VoidCallback onStop;
  final Future<void> Function() onLogin;
  final void Function(KeepSettings settings) onSave;

  /// 지금은 시작할 수 없는 이유 (다른 실행이 도는 중이면). 있으면 시작 버튼이 막힌다.
  final String? blockedReason;

  /// 자동 연장이 켜져 있는지 (이용 중인 좌석을 끝나기 전에 연장한다는 안내용).
  final bool autoRenewOn;

  /// 가장 최근에 끝난 좌석 유지의 결과 한 줄 (도는 중이 아닐 때 보여 준다).
  final String? lastResult;

  @override
  State<KeepSeatPage> createState() => _KeepSeatPageState();
}

class _KeepSeatPageState extends State<KeepSeatPage> {
  late KeepSettings _s = widget.initial;
  List<Seat>? _seats; // 고른 열람실의 좌석 (API 순서)
  SeatLayout? _layout;
  bool _loadingSeats = false;
  String? _seatsError;
  bool _loadingMine = false; // "내 좌석 선택" 으로 서버에서 읽어 오는 중
  String? _mineNote; // 마지막 "내 좌석 선택" 결과 한 줄
  bool _mineNoteBad = false;

  @override
  void initState() {
    super.initState();
    if (widget.loggedIn && _s.roomId != null) _loadRoom(_s.roomId!);
  }

  @override
  void didUpdateWidget(KeepSeatPage old) {
    super.didUpdateWidget(old);
    if (!old.loggedIn && widget.loggedIn && _s.roomId != null && _seats == null) _loadRoom(_s.roomId!);
  }

  void _change(KeepSettings next) {
    setState(() => _s = next);
    widget.onSave(next);
  }

  Future<void> _loadRoom(int roomId) async {
    if (_loadingSeats) return;
    setState(() {
      _loadingSeats = true;
      _seatsError = null;
    });
    try {
      final layout = await widget.loadLayout(roomId);
      final seats = await widget.loadSeats(roomId);
      if (!mounted || _s.roomId != roomId) return;
      final codes = seats.map((s) => s.code).toSet();
      setState(() {
        _layout = layout;
        _seats = seats;
        _s = _s.copyWith(seats: _s.seats.where(codes.contains).toList());
      });
    } catch (e) {
      if (mounted && _s.roomId == roomId) setState(() => _seatsError = '좌석을 불러오지 못했어요. 잠시 뒤 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => _loadingSeats = false);
    }
  }

  /// 지금 내가 예약해 갖고 있는 좌석을 1순위로 고른다. 그 좌석이 다른 열람실에 있으면 열람실도 그 방으로 바꾸고 이 좌석만 고른다.
  Future<void> _pickMine() async {
    if (_loadingMine) return;
    setState(() {
      _loadingMine = true;
      _mineNote = null;
    });
    String note;
    var bad = false;
    try {
      final list = await widget.loadMine();
      if (!mounted) return;
      if (list.isEmpty) {
        note = '지금 갖고 있는 좌석이 없어요.';
        bad = true;
      } else {
        final c = list.first;
        final roomId = c.roomId;
        final label = '${c.roomName.isEmpty ? '' : '${c.roomName} '}${c.seatCode}번 좌석';
        if (roomId == null || !widget.rooms.any((r) => r.id == roomId)) {
          note = '$label은 여기서 고를 수 없는 열람실이에요.';
          bad = true;
        } else if (roomId != _s.roomId) {
          // 다른 열람실의 좌석이다: 그 열람실로 바꾸고 이 좌석만 고른다 (이전 열람실의 선택은 그 열람실에 저장돼 있다).
          setState(() {
            _seats = null;
            _layout = null;
            _seatsError = null;
          });
          _change(_s.copyWith(roomId: roomId, seats: [c.seatCode]));
          unawaited(_loadRoom(roomId));
          note = '${c.roomName.isEmpty ? '열람실' : c.roomName}으로 바꾸고 ${c.seatCode}번 좌석을 골랐어요.';
        } else {
          final next = [c.seatCode, ..._s.seats.where((x) => x != c.seatCode)];
          _change(_s.copyWith(seats: next));
          note = '${c.seatCode}번 좌석을 1순위로 골랐어요.';
        }
      }
    } on LoginException {
      note = '로그인에 실패했어요. 학번과 비밀번호를 확인해 주세요.';
      bad = true;
    } on SessionException {
      note = '로그인이 풀렸어요. 다시 로그인해 주세요.';
      bad = true;
    } catch (_) {
      note = '내 좌석을 불러오지 못했어요. 잠시 뒤 다시 시도해 주세요.';
      bad = true;
    }
    if (!mounted) return;
    setState(() {
      _loadingMine = false;
      _mineNote = note;
      _mineNoteBad = bad;
    });
  }

  Future<void> _pickRoom(Room r) async {
    if (r.id == _s.roomId) return;
    final saved = await KeepSettings.savedSeats(r.id);
    if (!mounted) return;
    setState(() {
      _seats = null;
      _layout = null;
      _seatsError = null;
    });
    _change(_s.copyWith(roomId: r.id, seats: saved));
    if (widget.loggedIn) await _loadRoom(r.id);
  }

  void _toggleSeat(Seat s, [void Function()? refresh]) {
    final next = List<String>.of(_s.seats);
    if (!next.remove(s.code)) next.add(s.code);
    _change(_s.copyWith(seats: next));
    refresh?.call();
  }

  Future<void> _pickSeats() async {
    final seats = _seats;
    final room = _s.roomId;
    if (seats == null || room == null) return;
    final title = widget.rooms.where((r) => r.id == room).map((r) => r.name).firstOrNull ?? '좌석 고르기';
    final layout = _layout;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StatefulBuilder(
        builder: (context, setInner) => layout != null
            ? SeatMapPage(
                title: title,
                layout: layout,
                seats: seats,
                selected: _s.seats,
                onTap: (s) => _toggleSeat(s, () => setInner(() {})),
                onClear: () {
                  _change(_s.copyWith(seats: const []));
                  setInner(() {});
                },
              )
            : _SeatGridPage(
                title: title,
                seats: seats,
                selected: _s.seats,
                onTap: (s) => _toggleSeat(s, () => setInner(() {})),
                onClear: () {
                  _change(_s.copyWith(seats: const []));
                  setInner(() {});
                },
              ),
      ),
    ));
  }

  Future<void> _pickClock() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: _s.endHour, minute: _s.endMinute));
    if (t == null || !mounted) return;
    _change(_s.copyWith(endMode: KeepEndMode.clock, endHour: t.hour, endMinute: t.minute));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('좌석 유지')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (!widget.loggedIn) _loginBox(context) else if (widget.running) _runningCard(context) else ..._settings(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _box(BuildContext context, {required Widget child, EdgeInsetsGeometry? margin}) => Container(
        margin: margin ?? const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: child,
      );

  Widget _loginBox(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _box(
      context,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('로그인하면 좌석 유지를 쓸 수 있어요.', style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 10),
        FilledButton.tonal(onPressed: widget.onLogin, child: const Text('로그인')),
      ]),
    );
  }

  // ---------- 설정 (멈춰 있을 때) ----------

  List<Widget> _settings(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = TextStyle(fontSize: 12.5, height: 1.4, color: scheme.onSurfaceVariant);
    final now = DateTime.now();
    final end = _s.endAtFrom(now);
    final canStart = _s.roomId != null && _s.seats.isNotEmpty && widget.blockedReason == null;
    return [
      _box(
        context,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.push_pin_outlined, color: scheme.primary),
            const SizedBox(width: 10),
            const Text('좌석을 계속 갖고 있어요', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 8),
          Text(
              '고른 좌석을 예약해 두고, 취소되거나 배정이 풀려도 도서관 밖에서도 다시 예약해요. 내가 중지하거나 정한 종료 시각이 될 때까지 계속해요.'
                  .keepWords,
              style: dim),
          if (widget.lastResult != null) ...[
            const SizedBox(height: 8),
            Text(widget.lastResult!.keepWords, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          ],
        ]),
      ),
      _box(
        context,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('열람실', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (widget.rooms.isEmpty)
            Text('열람실 목록을 아직 불러오지 못했어요.', style: dim)
          else
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final r in widget.rooms)
                ChoiceChip(label: Text(r.name), selected: r.id == _s.roomId, onSelected: (_) => _pickRoom(r)),
            ]),
          const SizedBox(height: 16),
          const Text('좌석', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('여러 개를 고르면 앞에 고른 좌석부터 잡아요.', style: dim),
          const SizedBox(height: 8),
          if (_s.roomId == null)
            Text('먼저 열람실을 골라 주세요. 지금 예약한 좌석이 있으면 아래 "내 좌석 선택"으로 바로 고를 수 있어요.'.keepWords, style: dim)
          else if (_loadingSeats && _seats == null)
            const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)))
          else if (_seatsError != null)
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_seatsError!, style: TextStyle(fontSize: 12.5, color: scheme.error)),
              TextButton(onPressed: () => _loadRoom(_s.roomId!), child: const Text('다시 불러오기')),
            ])
          else
            Text(
                _s.seats.isEmpty
                    ? '고른 좌석이 없어요.'
                    : [for (var i = 0; i < _s.seats.length; i++) '${i + 1}순위 ${_s.seats[i]}번'].join(' · '),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            if (_s.roomId != null && _seats != null)
              OutlinedButton.icon(
                onPressed: _pickSeats,
                icon: const Icon(Icons.event_seat_outlined, size: 18),
                label: Text(_s.seats.isEmpty ? '좌석 고르기' : '좌석 바꾸기'),
              ),
            // 지금 내가 예약해 갖고 있는 좌석을 바로 고른다 (열람실이 다르면 열람실도 바꾼다)
            OutlinedButton.icon(
              onPressed: _loadingMine ? null : _pickMine,
              icon: _loadingMine
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.person_pin_circle_outlined, size: 18),
              label: Text(_loadingMine ? '확인하는 중…' : '내 좌석 선택'),
            ),
          ]),
          if (_mineNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_mineNote!.keepWords,
                  style: TextStyle(fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600, color: _mineNoteBad ? scheme.error : kGreen)),
            ),
        ]),
      ),
      _box(
        context,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('끝나는 시간', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            ChoiceChip(
              label: const Text('정하지 않음'),
              selected: _s.endMode == KeepEndMode.none,
              onSelected: (_) => _change(_s.copyWith(endMode: KeepEndMode.none)),
            ),
            for (final m in const [60, 120, 240])
              ChoiceChip(
                label: Text('${m ~/ 60}시간 뒤'),
                selected: _s.endMode == KeepEndMode.after && _s.endMinutes == m,
                onSelected: (_) => _change(_s.copyWith(endMode: KeepEndMode.after, endMinutes: m)),
              ),
            ChoiceChip(
              label: Text(_s.endMode == KeepEndMode.clock
                  ? '${_s.endHour.toString().padLeft(2, '0')}:${_s.endMinute.toString().padLeft(2, '0')}에 끝내기'
                  : '시각 정하기'),
              selected: _s.endMode == KeepEndMode.clock,
              onSelected: (_) => _pickClock(),
            ),
          ]),
          const SizedBox(height: 8),
          Text(end == null ? '내가 중지할 때까지 계속해요.' : '${clockText(end, base: now)}에 끝나요.', style: dim),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('끝나면 배정만 된 좌석은 취소', style: TextStyle(fontSize: 14)),
            subtitle: Text('이용 중인 좌석은 그대로 둬요. 끄면 배정만 된 좌석도 그대로 둬요(시간이 지나면 풀려요).'.keepWords, style: dim),
            value: _s.cancelAtEnd,
            onChanged: (v) => _change(_s.copyWith(cancelAtEnd: v)),
          ),
        ]),
      ),
      if (widget.blockedReason != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(widget.blockedReason!.keepWords, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.error)),
        ),
      SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: canStart ? () => widget.onStart(_s) : null,
          icon: const Icon(Icons.push_pin, size: 20),
          label: const Text('좌석 유지 시작', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
      ),
      const SizedBox(height: 10),
      Text(
          '참고: 도서관 안에서 배정확정을 하지 않으면 배정은 정해진 시간 뒤에 풀리고, 그때마다 다시 예약해요. 다른 학생이 쓰지 못하는 좌석이 될 수 있고, '
                  '도서관 규정에 따라 이용 제한이 걸릴 수도 있으니 필요할 때만 켜 주세요.'
              .keepWords,
          style: dim),
    ];
  }

  // ---------- 도는 중 ----------

  Widget _runningCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<KeepStatus?>(
      valueListenable: widget.status,
      builder: (context, s, _) {
        final dim = TextStyle(fontSize: 12.5, height: 1.4, color: scheme.onSurfaceVariant);
        final held = s?.held;
        final (IconData icon, Color color, String title) = switch (s?.phase) {
          KeepPhase.holding => (Icons.check_circle, kGreen, '좌석 유지 중'),
          KeepPhase.troubled => (Icons.warning_amber_rounded, scheme.error, '다시 시도하는 중이에요'),
          KeepPhase.acquiring => (Icons.sync, scheme.primary, '좌석을 다시 예약하는 중이에요'),
          null => (Icons.sync, scheme.primary, '시작하는 중이에요'),
        };
        final now = DateTime.now();
        Widget row(String name, String value) => Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 84, child: Text(name, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
                Expanded(child: Text(value, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))),
              ]),
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _box(
            context,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, color: color),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: color))),
              ]),
              const SizedBox(height: 4),
              row('지금 좌석', held == null ? '없어요' : _heldText(held)),
              if (held != null && !held.returnable && held.checkinExpiry != null)
                row('확정 기한', clockText(held.checkinExpiry!, base: now)),
              if (held != null && held.returnable && held.remainingMinutes != null)
                row('남은 시간', longRemaining(held.remainingMinutes!)),
              row('다시 예약', '이번 실행에서 ${s?.reserved ?? 0}번 (좌석이 사라진 것 ${s?.lost ?? 0}번)'),
              row('끝나는 때', s?.endAt == null ? '내가 중지할 때까지' : clockText(s!.endAt!, base: now)),
              if (s?.hunt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('고른 ${s!.hunt!.wanted}개 중 지금 빈 좌석 ${s.hunt!.free}개 · ${s.hunt!.checks}회 확인', style: dim),
                ),
              if (s != null && s.trouble.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${s.trouble} 계속 다시 시도해요.'.keepWords,
                      style: TextStyle(fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600, color: scheme.error)),
                ),
            ]),
          ),
          if (s != null && s.recent.isNotEmpty)
            _box(
              context,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('최근에 한 일', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                for (final line in s.recent) Padding(padding: const EdgeInsets.only(top: 3), child: Text(line, style: dim)),
              ]),
            ),
          Text(
              '${held != null && !held.returnable ? '배정만 된 상태예요. 도서관 안에서 배정확정을 하지 않으면 기한이 지나 풀리고, 그러면 바로 다시 예약해요. ' : ''}'
              '앱을 끄거나 최근 앱 목록에서 밀어서 끄면 멈춰요. 멈추려면 아래 버튼을 눌러 주세요.'
              '${widget.autoRenewOn ? ' 이용 중인 좌석은 끝나기 전에 자동으로 연장해요.' : ''}',
              style: dim),
          const SizedBox(height: 12),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: widget.onStop,
              style: FilledButton.styleFrom(backgroundColor: scheme.error),
              icon: const Icon(Icons.stop),
              label: const Text('좌석 유지 중지', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ]);
      },
    );
  }

  String _heldText(MyCharge c) {
    final where = c.roomName.isEmpty ? '${c.seatCode}번' : '${c.roomName} · ${c.seatCode}번';
    return '$where (${c.returnable ? '이용 중' : '배정만 된 상태'})';
  }
}

/// 도면이 없는 열람실에서 번호 카드로 좌석을 고르는 화면.
class _SeatGridPage extends StatelessWidget {
  const _SeatGridPage({required this.title, required this.seats, required this.selected, required this.onTap, required this.onClear});

  final String title;
  final List<Seat> seats;
  final List<String> selected;
  final void Function(Seat) onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final sorted = List<Seat>.of(seats)
      ..sort((a, b) {
        final x = int.tryParse(a.code), y = int.tryParse(b.code);
        return x != null && y != null ? x.compareTo(y) : a.code.compareTo(b.code);
      });
    return Scaffold(
      appBar: AppBar(
        title: Text('${selected.length}개 선택 · $title'),
        actions: [
          TextButton(onPressed: selected.isEmpty ? null : onClear, child: const Text('모두 해제')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('완료')),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SeatLegend(),
            const SizedBox(height: 12),
            SeatGrid(seats: sorted, selected: selected, onTap: onTap),
          ]),
        ),
      ),
    );
  }
}
