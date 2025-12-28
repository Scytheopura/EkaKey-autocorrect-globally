#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <iostream> 
#include "flutter_window.h"
#include "utils.h"


// Global variables
HHOOK hKeyboardHook = NULL;
HHOOK hMouseHook = NULL;  // NEW: Mouse hook handle
flutter::MethodChannel<flutter::EncodableValue>* keyChannel = nullptr;

// Keyboard callback function
LRESULT CALLBACK LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode == HC_ACTION) {
        KBDLLHOOKSTRUCT* pKey = (KBDLLHOOKSTRUCT*)lParam;
        
        bool isKeyDown = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
        bool isKeyUp = (wParam == WM_KEYUP || wParam == WM_SYSKEYUP);
        
        if (isKeyDown || isKeyUp) {
            std::string eventType = isKeyDown ? "DOWN" : "UP";
            // std::cout << "Key " << eventType << ": " << pKey->vkCode << std::endl;
            
            if (keyChannel != nullptr) {
                flutter::EncodableMap args = {
                    {flutter::EncodableValue("type"), flutter::EncodableValue("keyboard")},
                    {flutter::EncodableValue("vkCode"), flutter::EncodableValue(static_cast<int>(pKey->vkCode))},
                    {flutter::EncodableValue("eventType"), flutter::EncodableValue(eventType)}
                };
                keyChannel->InvokeMethod("onKeyPressed", 
                    std::make_unique<flutter::EncodableValue>(args));
            }
        }
    }
    return CallNextHookEx(hKeyboardHook, nCode, wParam, lParam);
}

// NEW: Mouse callback function
LRESULT CALLBACK LowLevelMouseProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode == HC_ACTION) {
        // MSLLHOOKSTRUCT* pMouse = (MSLLHOOKSTRUCT*)lParam;
        
        // Check for left mouse button events
        if (wParam == WM_LBUTTONDOWN || wParam == WM_LBUTTONUP) {
            std::string eventType = (wParam == WM_LBUTTONDOWN) ? "DOWN" : "UP";
            // std::cout << "Left Mouse " << eventType << " at (" 
            //           << pMouse->pt.x << ", " << pMouse->pt.y << ")" << std::endl;
            
            if (keyChannel != nullptr) {
                flutter::EncodableMap args = {
                    {flutter::EncodableValue("type"), flutter::EncodableValue("mouse")},
                    {flutter::EncodableValue("button"), flutter::EncodableValue("left")},
                    {flutter::EncodableValue("eventType"), flutter::EncodableValue(eventType)}
                };
                keyChannel->InvokeMethod("onKeyPressed", 
                    std::make_unique<flutter::EncodableValue>(args));
            }
        }
    }
    return CallNextHookEx(hMouseHook, nCode, wParam, lParam);
}

// Function to start both hooks
void StartKeyboardHook(HINSTANCE instance) {
    if (hKeyboardHook == NULL) {
        hKeyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, LowLevelKeyboardProc, instance, 0);
        if (hKeyboardHook != NULL) {
            std::cout << "Keyboard hook started!" << std::endl;
        } else {
            std::cout << "Failed to start keyboard hook!" << std::endl;
        }
    }
    
    // NEW: Start mouse hook too
    if (hMouseHook == NULL) {
        hMouseHook = SetWindowsHookEx(WH_MOUSE_LL, LowLevelMouseProc, instance, 0);
        if (hMouseHook != NULL) {
            std::cout << "Mouse hook started!" << std::endl;
        } else {
            std::cout << "Failed to start mouse hook!" << std::endl;
        }
    }
}

// Function to stop both hooks
void StopKeyboardHook() {
    if (hKeyboardHook != NULL) {
        UnhookWindowsHookEx(hKeyboardHook);
        hKeyboardHook = NULL;
        std::cout << "Keyboard hook stopped!" << std::endl;
    }
    
    // NEW: Stop mouse hook too
    if (hMouseHook != NULL) {
        UnhookWindowsHookEx(hMouseHook);
        hMouseHook = NULL;
        std::cout << "Mouse hook stopped!" << std::endl;
    }
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  flutter::DartProject project(L"data");
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ekakey", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  flutter::FlutterEngine* engine = window.GetEngine();
  if (engine != nullptr) {
    keyChannel = new flutter::MethodChannel<flutter::EncodableValue>(
        engine->messenger(), "ekakey/keyboard",
        &flutter::StandardMethodCodec::GetInstance());
    
    keyChannel->SetMethodCallHandler(
      [instance](const flutter::MethodCall<flutter::EncodableValue>& call,
                 std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "startHook") {
          StartKeyboardHook(instance);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "stopHook") {
          StopKeyboardHook();
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
  }



  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  StopKeyboardHook();
  delete keyChannel;

  ::CoUninitialize();
  return EXIT_SUCCESS;
}