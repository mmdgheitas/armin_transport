#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Only one copy of the program runs for a Windows user. Two copies would share the stored login
  // and renew its token against each other, which the server takes for a stolen token and answers
  // by ending the session. A second start brings the running window to the front and ends.
  HANDLE instance_mutex = ::CreateMutexW(nullptr, FALSE, kInstanceMutexName);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // Windows lets a window come to the front only when the program in front agrees.
    ::AllowSetForegroundWindow(ASFW_ANY);
    ::PostMessageW(HWND_BROADCAST, ::RegisterWindowMessageW(kActivateMessageName), 0, 0);
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // The Persian window title (the name of the app, as in lib/routing.dart), written with escapes so that
  // this file stays pure ASCII and does not depend on the source encoding the compiler assumes.
  if (!window.Create(L"\u062D\u0645\u0644\u200C\u0648\u0646\u0642\u0644", origin, size)) {
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
