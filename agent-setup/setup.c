#include <windows.h>
#include <objbase.h>
#include <shellapi.h>
#include <urlmon.h>
#include <wtsapi32.h>
#include <stdio.h>

#define IDC_CODE 101
#define IDC_USER 102
#define IDC_GO 103
#define IDC_STATUS 104

static HWND g_status;
static wchar_t g_code[16];
static wchar_t g_user[160];

static void SetStatus(const wchar_t *text) {
  if (g_status) SetWindowTextW(g_status, text);
}

static int AllowedCode(const wchar_t *text) {
  int n = 0;
  for (; text[n]; n++) {
    wchar_t c = text[n];
    if (!((c >= L'A' && c <= L'Z') || (c >= L'2' && c <= L'9'))) return 0;
  }
  return n == 8;
}

static int SafeUser(const wchar_t *text) {
  int n = 0;
  if (!text[0]) return 0;
  for (; text[n]; n++) {
    wchar_t c = text[n];
    if (c < 32 || wcschr(L"\";&|`$<>", c)) return 0;
  }
  return n >= 2 && n < 120;
}

static void Trim(wchar_t *text) {
  wchar_t *start = text;
  wchar_t *end;
  while (*start == L' ' || *start == L'\t' || *start == L'\r' || *start == L'\n') start++;
  if (start != text) memmove(text, start, (wcslen(start) + 1) * sizeof(wchar_t));
  end = text + wcslen(text);
  while (end > text && (end[-1] == L' ' || end[-1] == L'\t' || end[-1] == L'\r' || end[-1] == L'\n')) {
    end--;
    *end = 0;
  }
}

static void ReadCodeFile(wchar_t *buf, int cch) {
  wchar_t path[MAX_PATH];
  wchar_t *slash;
  HANDLE file;
  char raw[64];
  DWORD got = 0;
  int i;
  buf[0] = 0;
  if (!GetModuleFileNameW(NULL, path, MAX_PATH)) return;
  slash = wcsrchr(path, L'\\');
  if (!slash) return;
  wcscpy(slash + 1, L"code.txt");
  file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE) return;
  if (!ReadFile(file, raw, sizeof(raw) - 1, &got, NULL)) got = 0;
  CloseHandle(file);
  raw[got] = 0;
  for (i = 0; raw[i] && i < cch - 1; i++) {
    if (raw[i] == '\r' || raw[i] == '\n') break;
    buf[i] = (wchar_t)(unsigned char)raw[i];
  }
  buf[i] = 0;
  Trim(buf);
  if (!AllowedCode(buf)) buf[0] = 0;
}

static void ConsoleUser(wchar_t *buf, int cch) {
  DWORD session;
  LPWSTR name = NULL;
  LPWSTR domain = NULL;
  DWORD bytes = 0;
  buf[0] = 0;
  session = WTSGetActiveConsoleSessionId();
  if (session == 0xFFFFFFFF) return;
  if (!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, session, WTSDomainName, &domain, &bytes)) domain = NULL;
  bytes = 0;
  if (!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, session, WTSUserName, &name, &bytes)) name = NULL;
  if (name && name[0] && domain && domain[0]) _snwprintf(buf, cch, L"%s\\%s", domain, name);
  else if (name && name[0]) _snwprintf(buf, cch, L"%s", name);
  buf[cch - 1] = 0;
  if (name) WTSFreeMemory(name);
  if (domain) WTSFreeMemory(domain);
}

static DWORD WINAPI InstallThread(LPVOID unused) {
  wchar_t script[MAX_PATH];
  wchar_t command[1200];
  wchar_t powershell[MAX_PATH];
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  DWORD code = 1;
  HRESULT hr;
  (void)unused;
  GetTempPathW(MAX_PATH, script);
  wcscat(script, L"MulkAgent-install.ps1");
  SetStatus(L"Downloading Mulk Agent…");
  hr = URLDownloadToFileW(NULL, L"https://mulk-asset-manager.vercel.app/agent/install.ps1", script, 0, NULL);
  if (hr != S_OK) {
    SetStatus(L"The setup could not be downloaded.");
    MessageBoxW(NULL, L"The setup could not be downloaded. Check the network and try again.", L"Mulk Agent setup", MB_ICONERROR);
    EnableWindow(GetDlgItem(GetParent(g_status), IDC_GO), TRUE);
    return 1;
  }
  GetSystemDirectoryW(powershell, MAX_PATH);
  wcscat(powershell, L"\\WindowsPowerShell\\v1.0\\powershell.exe");
  _snwprintf(command, 1200, L"\"%s\" -NoProfile -ExecutionPolicy Bypass -File \"%s\" -Code \"%s\" -WindowsUser \"%s\"", powershell, script, g_code, g_user);
  command[1199] = 0;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  ZeroMemory(&pi, sizeof(pi));
  SetStatus(L"Installing…");
  if (!CreateProcessW(powershell, command, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
    SetStatus(L"Windows could not start the installer.");
    MessageBoxW(NULL, L"Windows could not start the installer.", L"Mulk Agent setup", MB_ICONERROR);
    EnableWindow(GetDlgItem(GetParent(g_status), IDC_GO), TRUE);
    return 1;
  }
  WaitForSingleObject(pi.hProcess, INFINITE);
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  DeleteFileW(script);
  if (code == 0) {
    SetStatus(L"Mulk Agent is installed.");
    MessageBoxW(NULL, L"Mulk Agent is installed. Leave its window available.", L"Mulk Agent setup", MB_ICONINFORMATION);
    PostQuitMessage(0);
  } else {
    SetStatus(L"Setup did not finish.");
    MessageBoxW(NULL, L"Setup did not finish. Check the code and the Windows account, then try again.", L"Mulk Agent setup", MB_ICONERROR);
  }
  EnableWindow(GetDlgItem(GetParent(g_status), IDC_GO), TRUE);
  return 0;
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  switch (msg) {
  case WM_COMMAND:
    if (LOWORD(wparam) == IDC_GO) {
      GetWindowTextW(GetDlgItem(hwnd, IDC_CODE), g_code, 16);
      GetWindowTextW(GetDlgItem(hwnd, IDC_USER), g_user, 160);
      Trim(g_code);
      Trim(g_user);
      CharUpperW(g_code);
      if (!AllowedCode(g_code)) {
        MessageBoxW(hwnd, L"Enter the 8 character code from Control.", L"Mulk Agent setup", MB_ICONWARNING);
        return 0;
      }
      if (!SafeUser(g_user)) {
        MessageBoxW(hwnd, L"Enter the Windows account of the person who uses this computer.", L"Mulk Agent setup", MB_ICONWARNING);
        return 0;
      }
      EnableWindow(GetDlgItem(hwnd, IDC_GO), FALSE);
      CreateThread(NULL, 0, InstallThread, NULL, 0, NULL);
    }
    return 0;
  case WM_DESTROY:
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE prev, LPWSTR cmdline, int show) {
  WNDCLASSW wc;
  HWND hwnd, code, user;
  MSG msg;
  wchar_t saved[16];
  wchar_t account[160];
  (void)prev;
  (void)cmdline;
  (void)show;
  CoInitialize(NULL);
  ZeroMemory(&wc, sizeof(wc));
  wc.lpfnWndProc = WndProc;
  wc.hInstance = instance;
  wc.hCursor = LoadCursor(NULL, IDC_ARROW);
  wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
  wc.lpszClassName = L"MulkAgentSetup";
  RegisterClassW(&wc);
  hwnd = CreateWindowExW(0, L"MulkAgentSetup", L"Mulk Agent setup",
    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, 460, 250,
    NULL, NULL, instance, NULL);
  CreateWindowExW(0, L"STATIC", L"Code from Control", WS_CHILD | WS_VISIBLE, 24, 20, 400, 20, hwnd, NULL, instance, NULL);
  code = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_UPPERCASE, 24, 42, 400, 26, hwnd, (HMENU)IDC_CODE, instance, NULL);
  CreateWindowExW(0, L"STATIC", L"Windows account for this computer", WS_CHILD | WS_VISIBLE, 24, 80, 400, 20, hwnd, NULL, instance, NULL);
  user = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP, 24, 102, 400, 26, hwnd, (HMENU)IDC_USER, instance, NULL);
  CreateWindowExW(0, L"BUTTON", L"Install", WS_CHILD | WS_VISIBLE | WS_TABSTOP, 24, 146, 120, 32, hwnd, (HMENU)IDC_GO, instance, NULL);
  g_status = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE, 156, 152, 270, 24, hwnd, (HMENU)IDC_STATUS, instance, NULL);
  ReadCodeFile(saved, 16);
  if (saved[0]) SetWindowTextW(code, saved);
  ConsoleUser(account, 160);
  if (account[0]) SetWindowTextW(user, account);
  SendMessageW(code, EM_LIMITTEXT, 8, 0);
  ShowWindow(hwnd, SW_SHOW);
  UpdateWindow(hwnd);
  while (GetMessageW(&msg, NULL, 0, 0)) {
    if (!IsDialogMessageW(hwnd, &msg)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }
  CoUninitialize();
  return 0;
}
