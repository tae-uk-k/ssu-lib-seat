import 'package:flutter_test/flutter_test.dart';
import 'package:lib_seat/api.dart';

void main() {
  // LIB_http.py 의 encrypt_password 출력과 동일해야 한다.
  test('encryptPassword matches python reference', () {
    expect(encryptPassword('test1234'), '9ap9Es/bXgxt+zYBZknfEA==');
    expect(encryptPassword('Abc!@#\$%^&*()한글'),
        'aztSVmLnNuASMOmdthmEYGGrX/X9jldALgwCdRTbVns=');
    expect(encryptPassword('a' * 40),
        '1iV+PaHMj5o9R6x0wo5pYCPmLhhiba89ZX+Ct/RPk6tu866aZCybOJgtLhxSXQDZ');
  });
}
