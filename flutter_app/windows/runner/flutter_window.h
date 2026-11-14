#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// The name of the mutex that the running copy of the program holds, and of the window message
// with which a second start asks the running copy to come to the front (see main.cpp).
constexpr wchar_t kInstanceMutexName[] =
    L"ir.armintransport.armin_transport.instance";
constexpr wchar_t kActivateMessageName[] =
    L"ir.armintransport.armin_transport.activate";

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The window message of a second start of the program (0 when it could not be registered).
  UINT activate_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
