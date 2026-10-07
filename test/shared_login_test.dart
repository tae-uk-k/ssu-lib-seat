import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';
import 'package:lib_seat/shared_login.dart';

class _Api implements LibraryApi {
  _Api(this.n);
  final int n;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('두 루프가 동시에 다시 로그인하려 해도 실제 로그인은 한 번만 하고 같은 결과를 나눠 쓴다', () async {
    var logins = 0;
    final gate = Completer<void>();
    final shared = SharedLogin(() async {
      final n = ++logins;
      await gate.future;
      return _Api(n);
    });
    final a = shared();
    final b = shared(); // 첫 로그인이 아직 끝나지 않았다
    gate.complete();
    final (x, y) = (await a, await b);
    expect(logins, 1);
    expect(identical(x, y), isTrue);
  });

  test('방금 끝난 로그인은 잠깐 동안 그대로 다시 쓴다 (서로의 로그인을 끊지 않게)', () async {
    var logins = 0;
    var t = DateTime(2026, 10, 7, 12);
    final shared = SharedLogin(() async => _Api(++logins), now: () => t);
    final first = await shared();
    t = t.add(const Duration(seconds: 5));
    expect(identical(await shared(), first), isTrue);
    expect(logins, 1);
  });

  test('시간이 지나면 새로 로그인한다', () async {
    var logins = 0;
    var t = DateTime(2026, 10, 7, 12);
    final shared = SharedLogin(() async => _Api(++logins), now: () => t);
    final first = await shared();
    t = t.add(const Duration(seconds: 11));
    final second = await shared();
    expect(identical(first, second), isFalse);
    expect(logins, 2);
  });

  test('로그인이 거절되면 모두가 같은 오류를 받고, 다음에는 다시 시도할 수 있다', () async {
    var logins = 0;
    final shared = SharedLogin(() async {
      logins++;
      if (logins == 1) throw LoginException('틀림');
      return _Api(logins);
    });
    final a = shared();
    final b = shared();
    await expectLater(a, throwsA(isA<LoginException>()));
    await expectLater(b, throwsA(isA<LoginException>()));
    expect(logins, 1);
    expect(await shared(), isA<_Api>()); // 거절됐다고 영영 막히지는 않는다
    expect(logins, 2);
  });
}
