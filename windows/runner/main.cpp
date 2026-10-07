#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // 창을 최소화하거나 다른 창에 가려도 윈도우가 이 프로그램의 속도를 늦추지 않게 한다.
  // (예약은 몇 초마다 서버를 확인하는 일이라, 늦춰지면 빈 좌석을 놓칠 수 있다.)
  PROCESS_POWER_THROTTLING_STATE throttling = {};
  throttling.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
  throttling.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
  throttling.StateMask = 0;  // 0: 속도 제한을 받지 않는다
  ::SetProcessInformation(::GetCurrentProcess(), ProcessPowerThrottling,
                          &throttling, sizeof(throttling));

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // 폰 화면처럼 세로로 긴 창. 제목은 "도서관 좌석 예약" (소스 파일 인코딩과 무관하게 \u 로 적었다).
  Win32Window::Size size(520, 820);
  if (!window.Create(L"도서관 좌석 예약", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
