#include <Windows.h>
#include <WinBase.h>
#include <tchar.h>
#include <stdlib.h>

#define bool  int
#define false 0
#define true  1

bool SetCurrentDirectoryToExeDir() {
    TCHAR szCurrentDir[MAX_PATH];
    TCHAR szModulePath[MAX_PATH];
    TCHAR szModuleDir[MAX_PATH];
    DWORD dwResult;

    // 获取当前工作目录
    dwResult = GetCurrentDirectory(MAX_PATH, szCurrentDir);
    if (dwResult == 0 || dwResult >= MAX_PATH) {
        return false; // 获取失败
    }

    // 获取程序可执行文件的完整路径
    dwResult = GetModuleFileName(NULL, szModulePath, MAX_PATH);
    if (dwResult == 0 || dwResult >= MAX_PATH) {
        return false; // 获取失败
    }

    // 从完整路径中提取目录部分
    TCHAR* pLastSlash = _tcsrchr(szModulePath, _T('\\'));
    if (pLastSlash == NULL) {
        // 处理根目录情况，例如 C:
        TCHAR* pColon = _tcschr(szModulePath, _T(':'));
        if (pColon != NULL && *(pColon + 1) == _T('\0')) {
            _tcscpy(szModuleDir, szModulePath);
            _tcscat(szModuleDir, _T("\\"));
        } else {
            return false; // 无法解析路径
        }
    } else {
        size_t dirLength = (pLastSlash - szModulePath) + 1;
        if (dirLength >= MAX_PATH) {
            return false; // 路径过长
        }
        _tcsncpy(szModuleDir, szModulePath, dirLength);
        szModuleDir[dirLength] = _T('\0');
    }

    // 比较当前目录和程序所在目录（不区分大小写）
    if (_tcsicmp(szCurrentDir, szModuleDir) == 0) {
        return true; // 目录已正确，无需更改
    }

    // 尝试更改目录
    if (SetCurrentDirectory(szModuleDir)) {
        return true; // 更改成功
    }

    // 更改失败
    return false;
}

int WINAPI WinMain(
    HINSTANCE hInstance,
    HINSTANCE hPrevInstance,
    LPSTR lpCmdLine,
    int nShowCmd
)
{
    SetCurrentDirectoryToExeDir();
    SHELLEXECUTEINFO sei = { sizeof(SHELLEXECUTEINFO) };
    sei.lpVerb = TEXT("runas");
    sei.lpFile = TEXT(".\\bin\\BiliDownloader.exe");
    sei.nShow = SW_SHOWNORMAL;
    ShellExecuteEx(&sei);
    return 0;
}
