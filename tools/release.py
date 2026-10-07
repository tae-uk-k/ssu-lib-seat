"""새 버전을 한 번에 릴리스한다.

    python tools/release.py "이번 변경 내용 한 줄"     # 실제 릴리스 (GitHub 에 올라간다)
    python tools/release.py --dry-run                  # 버전/업로드는 건드리지 않고 빌드와 서명 확인까지만

순서: 버전 올리기(1.0.N+N) -> flutter analyze/test -> 릴리스 APK 빌드 -> 서명 키 확인
      -> pubspec 반영, 커밋, 태그, 푸시 -> GitHub 릴리스에 APK 업로드

폰의 앱은 시작할 때 이 릴리스를 확인하고 '업데이트' 버튼을 보여 준다.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
PUBSPEC = os.path.join(ROOT, 'pubspec.yaml')
PIN = os.path.join(ROOT, 'tools', 'signing_cert.sha256')
BS = chr(92)


def die(msg):
    print('\n[중단] ' + msg)
    sys.exit(1)


def run(cmd, capture=False, check=True):
    """셸 명령 실행. flutter 는 flutter.bat 이라 shell=True 로 부른다."""
    line = subprocess.list2cmdline(cmd) if isinstance(cmd, list) else cmd
    print('\n$ ' + line)
    r = subprocess.run(line, shell=True, cwd=ROOT, text=True, encoding='utf-8', errors='replace',
                       capture_output=capture)
    if check and r.returncode != 0:
        if capture:
            print((r.stdout or '') + (r.stderr or ''))
        die('명령이 실패했어요: ' + line)
    return r


def read_version():
    text = open(PUBSPEC, encoding='utf-8').read()
    m = re.search(r'(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$', text)
    if not m:
        die('pubspec.yaml 의 version 줄이 "1.0.N+N" 형식이 아니에요.')
    return text, tuple(int(x) for x in m.groups())


def sdk_dir():
    props = os.path.join(ROOT, 'android', 'local.properties')
    for line in open(props, encoding='utf-8'):
        if line.startswith('sdk.dir='):
            v = line.split('=', 1)[1].strip()
            return v.replace(BS + BS, BS).replace(BS + ':', ':')
    die('android/local.properties 에서 sdk.dir 를 찾지 못했어요.')


def apksigner():
    bt = os.path.join(sdk_dir(), 'build-tools')
    vers = sorted(os.listdir(bt), key=lambda s: [int(x) if x.isdigit() else 0 for x in re.split(r'[.-]', s)])
    for v in reversed(vers):
        p = os.path.join(bt, v, 'apksigner.bat')
        if os.path.exists(p):
            return p
    die('Android SDK build-tools 에서 apksigner 를 찾지 못했어요.')


def cert_sha256(apk):
    """APK 를 서명한 인증서의 SHA-256 지문 (apksigner 가 서명 검증도 함께 한다)."""
    r = run([apksigner(), 'verify', '--print-certs', apk], capture=True)
    m = re.search(r'SHA-256 digest:\s*([0-9a-fA-F]{64})', r.stdout)
    if not m:
        die('서명 정보를 읽지 못했어요:\n' + r.stdout)
    return m.group(1).lower()


WINDOWS_README = """도서관 좌석 예약 (Windows)

처음 쓰는 방법
1. 이 압축 파일을 원하는 폴더에 풀어 주세요. (압축 파일 안에서 바로 실행하면 안 돼요.)
2. ssu_lib_seat.exe 를 실행하세요.
3. "Windows의 PC 보호" 창이 뜨면 "추가 정보" 를 누르고 "실행" 을 눌러 주세요.
   (서명하지 않은 프로그램이라 처음 한 번 나오는 안내예요.)
4. 학번과 비밀번호는 이 컴퓨터 안에 암호화해서 저장돼요. 어디로도 전송되지 않아요.

알아둘 점
- 예약이 도는 동안 창을 닫으면 예약도 멈춰요. 최소화는 괜찮아요.
- 예약하는 동안에는 컴퓨터가 잠자기에 들어가지 않아요.
- 예약이 끝나면 Windows 알림으로 알려 줘요. 알림이 안 보이면
  설정 > 시스템 > 알림 에서 "도서관 좌석 예약" 이 켜져 있는지 확인해 주세요.
- 새 버전이 나오면 앱 맨 위에 안내가 떠요. 다운로드 페이지에서 새 압축 파일을 받아 같은 방법으로 풀어 주세요.
"""

# Windows 에서 Flutter 프로그램이 돌려면 필요한 시스템 파일. 깨끗한 PC 에는 없을 수 있어서 프로그램 옆에 같이 넣는다.
VC_RUNTIME_DLLS = ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll']


def package_windows(version):
    """flutter build windows 결과를 압축 파일(zip)로 묶는다. 만든 zip 경로를 돌려준다."""
    src = os.path.join(ROOT, 'build', 'windows', 'x64', 'runner', 'Release')
    exe = os.path.join(src, 'ssu_lib_seat.exe')
    if not os.path.exists(exe):
        die('Windows 프로그램이 만들어지지 않았어요: ' + exe)
    name = 'ssu-lib-seat-%s-windows' % version
    stage_root = os.path.join(ROOT, 'build', name)
    shutil.rmtree(stage_root, ignore_errors=True)
    stage = os.path.join(stage_root, 'SSU-LibSeat')  # 압축을 풀면 이 폴더가 나온다
    shutil.copytree(src, stage)
    sysdir = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')
    missing = []
    for dll in VC_RUNTIME_DLLS:
        p = os.path.join(sysdir, dll)
        if os.path.exists(p):
            shutil.copyfile(p, os.path.join(stage, dll))
        else:
            missing.append(dll)
    if missing:
        print('[주의] 시스템 파일을 찾지 못해 넣지 못했어요: ' + ', '.join(missing))
    open(os.path.join(stage, '읽어주세요.txt'), 'w', encoding='utf-8-sig', newline='\r\n').write(WINDOWS_README)
    zip_path = os.path.join(ROOT, 'build', name + '.zip')
    if os.path.exists(zip_path):
        os.remove(zip_path)
    shutil.make_archive(os.path.join(ROOT, 'build', name), 'zip', root_dir=stage_root)
    print('Windows 압축 파일: %s (%.1f MB)' % (zip_path, os.path.getsize(zip_path) / 1048576))
    return zip_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('notes', nargs='?', default='', help='릴리스 설명 (앱의 업데이트 안내에 그대로 보인다)')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--no-windows', action='store_true', help='Windows 프로그램은 만들지 않는다 (APK 만 릴리스)')
    ap.add_argument('--trailer', default='', help='커밋 메시지 맨 끝에만 붙는 줄 (예: Co-Authored-By: ...). 릴리스 설명에는 안 들어간다')
    args = ap.parse_args()

    if not os.path.exists(os.path.join(ROOT, 'android', 'key.properties')):
        die('android/key.properties 가 없어요. 이 PC 에는 릴리스 서명 키가 없으니 릴리스할 수 없어요.\n'
            '       (임시 키로 만든 APK 를 올리면 폰의 앱이 업데이트를 거부해요.) 키 백업본을 복원하세요.')
    if not args.dry_run:
        if shutil.which('gh') is None:
            die('GitHub CLI(gh)가 필요해요.')
        run(['gh', 'auth', 'status'])
        if run(['git', 'remote', 'get-url', 'origin'], capture=True, check=False).returncode != 0:
            die('git remote(origin)가 없어요. 저장소가 설정되지 않았어요.')

    text, (maj, mnr, pat, build) = read_version()
    new, new_build = '%d.%d.%d' % (maj, mnr, pat + 1), build + 1
    tag = 'v' + new
    print('버전 %d.%d.%d+%d  ->  %s+%d  (태그 %s)' % (maj, mnr, pat, build, new, new_build, tag))

    if not args.dry_run and run(['git', 'tag', '-l', tag], capture=True).stdout.strip():
        die('태그 %s 가 이미 있어요.' % tag)

    notes = args.notes.strip()
    if not notes and not args.dry_run:
        last = run(['git', 'describe', '--tags', '--abbrev=0'], capture=True, check=False)
        rng = (last.stdout.strip() + '..HEAD') if last.returncode == 0 else 'HEAD'
        log = run(['git', 'log', rng, '--pretty=- %s'], capture=True, check=False).stdout.strip()
        notes = log or '개선 사항이 있어요.'

    run(['flutter', 'analyze'])
    run(['flutter', 'test'])
    run(['flutter', 'build', 'apk', '--release', '--build-name', new, '--build-number', str(new_build)])

    built = os.path.join(ROOT, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk')
    if not os.path.exists(built):
        die('APK 가 만들어지지 않았어요: ' + built)

    cert = cert_sha256(built)
    print('\n서명 인증서 SHA-256: ' + cert)
    pinned = open(PIN, encoding='utf-8').read().strip().lower() if os.path.exists(PIN) else None
    if pinned and pinned != cert:
        die('이 APK 는 기존 릴리스와 다른 키로 서명됐어요. 이대로 올리면 폰에서 업데이트가 거부돼요.\n'
            '       기존 지문: %s\n       이번 지문: %s' % (pinned, cert))
    print('서명 확인: ' + ('기존 릴리스와 같은 키예요.' if pinned else '첫 릴리스라 이 지문을 기준으로 저장해요.'))

    win_zip = None
    if not args.no_windows:
        r = run(['flutter', 'build', 'windows', '--release', '--build-name', new, '--build-number', str(new_build)],
                check=False)
        if r.returncode != 0:
            # Windows 때문에 폰 업데이트까지 못 내보내는 일이 없도록, 건너뛰는 방법을 알려 주고 멈춘다 (아직 아무것도 올리지 않았다).
            die('Windows 프로그램 빌드에 실패했어요. 아직 버전, git, GitHub 는 바뀌지 않았어요.\n'
                '       폰 앱(APK)만 올리려면 --no-windows 를 붙여 다시 실행하세요.\n'
                '       (Windows 빌드에는 Visual Studio 와 Windows 개발자 모드가 필요해요.)')
        win_zip = package_windows(new)

    if args.dry_run:
        print('\n[dry-run] 여기까지만 했어요. 버전, git, GitHub 는 바뀌지 않았어요.\nAPK: ' + built)
        if win_zip:
            print('Windows: ' + win_zip)
        return

    apk = os.path.join(ROOT, 'build', 'ssu-lib-seat-%s.apk' % new)
    shutil.copyfile(built, apk)
    if not pinned:
        open(PIN, 'w', encoding='utf-8', newline='\n').write(cert + '\n')
    open(PUBSPEC, 'w', encoding='utf-8', newline='\n').write(
        re.sub(r'(?m)^version:.*$', 'version: %s+%d' % (new, new_build), text, count=1))

    # 여러 줄 메시지를 명령줄로 넘기면 Windows cmd 가 첫 줄에서 끊으므로 파일로 넘긴다.
    notes_file = os.path.join(ROOT, 'build', 'release_notes.txt')
    msg_file = os.path.join(ROOT, 'build', 'commit_message.txt')
    open(notes_file, 'w', encoding='utf-8', newline='\n').write(notes + '\n')
    msg = 'Release %s\n\n%s\n' % (tag, notes)
    if args.trailer.strip():
        msg += '\n' + args.trailer.strip() + '\n'
    open(msg_file, 'w', encoding='utf-8', newline='\n').write(msg)

    run(['git', 'add', '-A'])
    run(['git', 'commit', '-F', msg_file])
    run(['git', 'tag', tag])
    run(['git', 'push', 'origin', 'HEAD'])
    run(['git', 'push', 'origin', tag])
    files = [apk] + ([win_zip] if win_zip else [])
    run(['gh', 'release', 'create', tag] + files + ['--title', tag, '--notes-file', notes_file, '--latest'])
    print('\n완료! 폰의 앱을 켜면 %s 업데이트 버튼이 나타나요.' % new)
    print('macOS 앱은 GitHub 가 자동으로 만들어 몇 분 뒤 이 릴리스에 올려 줘요 (Actions 탭에서 진행 상황을 볼 수 있어요).')


if __name__ == '__main__':
    main()
