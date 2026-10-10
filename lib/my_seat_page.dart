import 'package:flutter/material.dart';

import 'api.dart';
import 'auto_renewer.dart';
import 'widgets.dart';

/// 자동 연장이 지금 어떤 상태인지. 내 좌석 화면과 메인 화면이 같은 말로 보여 주려고 한곳에 모았다.
class RenewView {
  const RenewView({
    required this.enabled,
    required this.active,
    required this.sessionRunning,
    required this.threshold,
    required this.retryAfter,
    this.status,
  });

  /// 스위치 값 (켜 두었는지).
  final bool enabled;

  /// 연장을 지켜보는 루프가 지금 실제로 돌고 있는지. 스위치를 켜 두기만 하고 시작하지 않았으면 false.
  final bool active;

  /// 예약 또는 연장 실행이 도는 중인지.
  final bool sessionRunning;
  final Duration threshold, retryAfter;

  /// 연장 루프가 마지막으로 본 것. [active] 일 때만 의미가 있다.
  final RenewStatus? status;
}

/// 시각을 "14:05" 로. [base] 와 날짜가 다르면 "내일 00:10" 으로 적는다 (자정을 넘는 종료·연장 시각이 오늘인지 헷갈리지 않게).
String clockText(DateTime t, {DateTime? base}) {
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final sameDay = base == null || (t.year == base.year && t.month == base.month && t.day == base.day);
  return sameDay ? hm : '내일 $hm';
}

/// 연장이 언제 시작되는지 한 줄로. 모르면 null.
///  - 이용 시작 전이면 "아직 이용을 시작하기 전이에요"
///  - 남은 시간이 문턱 이하면 "지금 연장할 시간이에요"
///  - 아니면 "연장은 14:10쯤 시작해요" (확인한 시각 + (남은 시간 - 문턱))
String? renewTimingText(MyCharge held, DateTime checkedAt, Duration threshold) {
  if (!held.returnable && held.renewable != true) return '아직 이용을 시작하기 전이에요';
  final rem = held.remainingMinutes;
  if (rem == null) return null;
  final limit = threshold.inMinutes;
  if (rem <= limit) return '지금 연장할 시간이에요';
  return '연장은 ${clockText(checkedAt.add(Duration(minutes: rem - limit)), base: checkedAt)}쯤 시작해요';
}

/// 메뉴의 "내 좌석". 지금 갖고 있는 좌석과 남은 시간, 그리고 자동 연장의 스위치와 동작 상태를 한 화면에 보여 준다.
class MySeatPage extends StatefulWidget {
  const MySeatPage({
    super.key,
    required this.loggedIn,
    required this.load,
    required this.view,
    required this.onToggle,
    required this.onStart,
    required this.onLogin,
    required this.onReturn,
  });

  final bool loggedIn;

  /// 서버에서 내 좌석을 읽어 온다. 실패하면 예외를 던진다.
  final Future<List<MyCharge>> Function() load;
  final RenewView view;

  /// 자동 연장 스위치를 바꿨다.
  final void Function(bool on) onToggle;

  /// 스위치는 켜져 있는데 아직 동작하지 않을 때 "지금 시작" 을 눌렀다.
  final VoidCallback onStart;

  /// 로그인한다 (로그인이 안 돼 있을 때 보이는 버튼).
  final Future<void> Function() onLogin;

  /// 이 좌석을 반납한다 (이용 시작 전이면 배정 취소). 성공하면 null, 실패하면 사용자에게 보일 이유.
  final Future<String?> Function(MyCharge seat) onReturn;

  @override
  State<MySeatPage> createState() => _MySeatPageState();
}

class _MySeatPageState extends State<MySeatPage> {
  List<MyCharge>? _charges;
  DateTime? _at; // _charges 를 확인한 시각
  Object? _error;
  bool _loading = false;
  int? _returningId; // 반납을 요청하고 기다리는 중인 좌석 (예약 번호)
  String? _returnError; // 마지막 반납 시도가 실패한 이유

  @override
  void initState() {
    super.initState();
    if (widget.loggedIn) _refresh();
  }

  @override
  void didUpdateWidget(MySeatPage old) {
    super.didUpdateWidget(old);
    if (!old.loggedIn && widget.loggedIn) _refresh();
    // 연장 루프가 더 최근에 확인한 내용이 있으면 그걸 쓴다 (따로 조회하지 않아도 화면이 최신으로 유지된다).
    final st = widget.view.status;
    if (st != null && (_at == null || st.checkedAt.isAfter(_at!))) {
      _charges = st.held == null ? const [] : [st.held!];
      _at = st.checkedAt;
      _error = null;
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.load();
      if (!mounted) return;
      setState(() {
        _charges = list;
        _at = DateTime.now();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 되돌릴 수 없는 일이라 한 번 더 묻고, 확인하면 반납한다. 성공하면 목록을 다시 읽어 온다.
  Future<void> _confirmReturn(MyCharge c) async {
    final inUse = c.returnable;
    final label = c.roomName.isEmpty ? '${c.seatCode}번 좌석' : '${c.roomName} ${c.seatCode}번 좌석';
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(inUse ? '좌석을 반납할까요?' : '좌석 배정을 취소할까요?'),
        content: Text(
            (inUse
                    ? '$label을 반납하면 더 이상 쓸 수 없고, 다시 앉으려면 새로 예약해야 해요. 자동 연장도 멈춰요.'
                    : '$label 배정을 취소하면 이 좌석은 사라지고, 다시 앉으려면 새로 예약해야 해요. 자동 연장도 멈춰요.')
                .keepWords),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('아니요')),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: Text(inUse ? '반납' : '배정 취소'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _returningId = c.id;
      _returnError = null;
    });
    final why = await widget.onReturn(c);
    if (!mounted) return;
    setState(() {
      _returningId = null;
      _returnError = why;
    });
    if (why == null) await _refresh(); // 반납됐으니 목록을 다시 읽어 "갖고 있는 좌석이 없어요"가 보이게
  }

  String _errorText(Object e) {
    if (e is LoginException) return '로그인에 실패했어요. 학번과 비밀번호를 확인해 주세요.';
    if (e is SessionException) return '로그인이 풀렸어요. 다시 로그인해 주세요.';
    return '내 좌석을 불러오지 못했어요. 잠시 뒤 다시 시도해 주세요.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 좌석'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: widget.loggedIn && !_loading ? _refresh : null,
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                _seatSection(context),
                const SizedBox(height: 12),
                _renewCard(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _box(BuildContext context, {required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: child,
      );

  Widget _seatSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant);
    if (!widget.loggedIn) {
      return _box(
        context,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('로그인하면 내 좌석을 볼 수 있어요.', style: dim),
          const SizedBox(height: 10),
          FilledButton.tonal(onPressed: widget.onLogin, child: const Text('로그인')),
        ]),
      );
    }
    final charges = _charges;
    if (_error != null && charges == null) {
      return _box(
        context,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_errorText(_error!), style: TextStyle(fontSize: 13.5, color: scheme.error)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _loading ? null : _refresh, child: const Text('다시 시도')),
        ]),
      );
    }
    if (charges == null) {
      return _box(context, child: const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())));
    }
    if (charges.isEmpty) {
      return _box(
        context,
        child: Row(children: [
          Icon(Icons.event_seat_outlined, color: scheme.outline),
          const SizedBox(width: 12),
          Expanded(child: Text('지금 갖고 있는 좌석이 없어요.', style: dim)),
        ]),
      );
    }
    return Column(children: [
      for (final c in charges) _seatCard(context, c),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('${_errorText(_error!)} (아래는 마지막으로 확인한 내용이에요)', style: TextStyle(fontSize: 12.5, color: scheme.error)),
        ),
    ]);
  }

  Widget _seatCard(BuildContext context, MyCharge c) {
    final scheme = Theme.of(context).colorScheme;
    final at = _at ?? DateTime.now();
    final rem = c.remainingMinutes;
    final inUse = c.returnable;
    final label = c.roomName.isEmpty ? '${c.seatCode}번' : '${c.roomName} · ${c.seatCode}번';
    Widget row(String name, String value) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            SizedBox(width: 78, child: Text(name, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
            Expanded(child: Text(value, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _box(
        context,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.event_seat, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: inUse ? const Color(0xFFE6F4E8) : const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(inUse ? '이용 중' : '이용 시작 전',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: inUse ? kGreen : const Color(0xFFE65100))),
            ),
          ]),
          const SizedBox(height: 6),
          row('남은 시간', rem == null ? '알 수 없어요' : longRemaining(rem)),
          if (rem != null) row('종료 예정', clockText(at.add(Duration(minutes: rem)), base: at)),
          row('확인한 시각', clockText(at)),
          if (c.renewable == true)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('지금 연장할 수 있어요.', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kGreen)),
            ),
          if (!inUse)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('배정만 된 상태예요. 이용을 시작하면 연장할 수 있어요.'.keepWords,
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _returningId != null || _loading ? null : () => _confirmReturn(c),
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
                side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
              ),
              icon: _returningId == c.id
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.event_busy, size: 18),
              label: Text(_returningId == c.id ? (inUse ? '반납하는 중…' : '취소하는 중…') : (inUse ? '반납하기' : '배정 취소하기')),
            ),
          ),
          if (_returnError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_returnError!.keepWords,
                  style: TextStyle(fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600, color: scheme.error)),
            ),
        ]),
      ),
    );
  }

  Widget _renewCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = widget.view;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(children: [
        SwitchListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
          secondary: Icon(Icons.autorenew, color: scheme.primary),
          title: const Text('자동 연장', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
              '이용 종료 ${v.threshold.inMinutes}분 전부터 연장해요. 안 되면 ${v.retryAfter.inMinutes}분 뒤 다시 시도해요.'.keepWords,
              style: TextStyle(fontSize: 12, height: 1.35, color: scheme.onSurfaceVariant)),
          value: v.enabled,
          onChanged: widget.onToggle,
        ),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.all(16), child: _renewStatus(context)),
      ]),
    );
  }

  /// 자동 연장이 "지금 실제로" 하고 있는 일.
  Widget _renewStatus(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = widget.view;
    final dim = TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant);

    Widget head(IconData icon, Color color, String title) => Row(children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color))),
        ]);

    if (!v.enabled) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        head(Icons.pause_circle_outline, scheme.outline, '꺼져 있어요'),
        const SizedBox(height: 4),
        Text('좌석 이용 시간이 끝나도 연장하지 않아요.', style: dim),
      ]);
    }
    if (!v.active) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        head(Icons.schedule, const Color(0xFFE65100), '켜져 있지만 아직 동작하지 않아요'),
        const SizedBox(height: 4),
        Text(
            (v.sessionRunning
                    ? '예약이 도는 중이에요. 잠시 뒤 함께 동작해요.'
                    : '"지금 시작"을 누르거나, 예약을 시작하면 함께 동작해요. 동작하는 동안에만 연장할 수 있어요.')
                .keepWords,
            style: dim),
        if (!v.sessionRunning) ...[
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: widget.onStart, icon: const Icon(Icons.play_arrow), label: const Text('지금 시작')),
        ],
      ]);
    }

    final st = v.status;
    final held = st?.held;
    final lines = <Widget>[];
    void line(String text, {bool bad = false}) => lines.add(Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(text.keepWords,
              style: TextStyle(fontSize: 13, height: 1.4, color: bad ? scheme.error : scheme.onSurfaceVariant, fontWeight: bad ? FontWeight.w600 : null)),
        ));
    if (st == null) {
      line('내 좌석을 확인하는 중…');
    } else if (held == null) {
      line('연장할 좌석이 아직 없어요. 좌석이 생기면 지켜봐요.');
    } else {
      final timing = renewTimingText(held, st.checkedAt, v.threshold);
      if (timing != null) line(timing);
      line('마지막 확인 ${clockText(st.checkedAt)}');
    }
    if (st != null && st.renewed > 0) line('이번 실행에서 ${st.renewed}번 연장했어요.');
    if (st != null && st.failStreak > 0) {
      line('연장에 실패했어요 (${st.lastFailure}). ${v.retryAfter.inMinutes}분마다 다시 시도해요.', bad: true);
    }
    if (st != null && st.errorStreak > 0) line('서버 응답이 불안정해요 (${st.errorStreak}번째). 자동으로 계속 시도해요.', bad: true);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      head(Icons.autorenew, kGreen, '동작 중'),
      ...lines,
    ]);
  }
}
