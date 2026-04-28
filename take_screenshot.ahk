; ============================================
; Screenshot Tool for ClaudeCodeLauncher
; ============================================

#Requires AutoHotkey v2+
#SingleInstance Force

; Ждём 2 секунды для подготовки
Sleep(2000)

; Ищем окно ClaudeCodeLauncher (по началу заголовка)
windowTitlePattern := "Claude Code Launcher"
foundWindow := 0
fullTitle := ""

; Ищем окно по частичному совпадению заголовка
DetectHiddenWindows(false)
foundWindow := WinExist(windowTitlePattern)

if (!foundWindow) {
    TrayTip("Окно '" windowTitlePattern "' не найдено!", "Запустите ClaudeCodeLauncher.exe и повторите попытку.",
        "Icon!")
    Sleep(3000)
    ExitApp()
}

; Получаем полный заголовок окна
fullTitle := WinGetTitle("ahk_id " foundWindow)

; Извлекаем версию из заголовка (например, "Claude Code Launcher v1.3.5" -> "v1.3.5")
version := "unknown"
if RegExMatch(fullTitle, "v[\d.]+", &match) {
    version := match[0]
}

; Имя файла скриншота с версией
screenshotFile := A_ScriptDir "\Assets\Screenshot-" version ".png"

; Активируем окно
WinActivate("ahk_id " foundWindow)
WinWaitActive("ahk_id " foundWindow, , 2)

; Получаем координаты окна
WinGetPos(&x, &y, &width, &height, "ahk_id " foundWindow)

; Корректируем координаты, убирая рамку окна (7 пикселей слева, справа и снизу)
x += 7        ; Смещение слева
width -= 14   ; 7 слева + 7 справа
height -= 7   ; 7 снизу (сверху не трогаем)

; Создаём объект GDI+ для скриншота
pToken := Gdip_Startup()

; Делаем скриншот области окна
pBitmap := Gdip_BitmapFromScreen(x "|" y "|" width "|" height)

; Сохраняем в PNG
Gdip_SaveBitmapToFile(pBitmap, screenshotFile)

; Очищаем ресурсы
Gdip_DisposeImage(pBitmap)
Gdip_Shutdown(pToken)

TrayTip("Скриншот сохранён!", screenshotFile, "Iconi")
Sleep(3000)
ExitApp()

; ============================================
; GDI+ Functions
; ============================================

Gdip_Startup() {
    if !DllCall("GetModuleHandle", "str", "gdiplus", "UPtr")
        DllCall("LoadLibrary", "str", "gdiplus")

    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si)

    DllCall("gdiplus\GdiplusStartup", "UPtr*", &pToken := 0, "UPtr", si.Ptr, "UPtr", 0)
    return pToken
}

Gdip_Shutdown(pToken) {
    DllCall("gdiplus\GdiplusShutdown", "UPtr", pToken)
    if hModule := DllCall("GetModuleHandle", "str", "gdiplus", "UPtr")
        DllCall("FreeLibrary", "UPtr", hModule)
}

Gdip_BitmapFromScreen(screen := 0) {
    if (screen = 0) {
        sysX := DllCall("GetSystemMetrics", "Int", 76)
        sysY := DllCall("GetSystemMetrics", "Int", 77)
        sysW := DllCall("GetSystemMetrics", "Int", 78)
        sysH := DllCall("GetSystemMetrics", "Int", 79)
    } else {
        spos := StrSplit(screen, "|")
        sysX := spos[1], sysY := spos[2], sysW := spos[3], sysH := spos[4]
    }

    hdc := DllCall("GetDC", "UPtr", 0, "UPtr")
    hbm := CreateDIBSection(sysW, sysH)
    hdc2 := DllCall("CreateCompatibleDC", "UPtr", hdc, "UPtr")
    obm := DllCall("SelectObject", "UPtr", hdc2, "UPtr", hbm, "UPtr")

    DllCall("BitBlt", "UPtr", hdc2, "Int", 0, "Int", 0, "Int", sysW, "Int", sysH, "UPtr", hdc, "Int", sysX, "Int", sysY,
        "UInt", 0x00CC0020)

    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "UPtr", hbm, "UPtr", 0, "UPtr*", &pBitmap := 0)

    DllCall("SelectObject", "UPtr", hdc2, "UPtr", obm)
    DllCall("DeleteObject", "UPtr", hbm)
    DllCall("DeleteDC", "UPtr", hdc2)
    DllCall("ReleaseDC", "UPtr", 0, "UPtr", hdc)

    return pBitmap
}

CreateDIBSection(w, h, bpp := 32) {
    hdc := DllCall("GetDC", "UPtr", 0, "UPtr")
    bi := Buffer(40, 0)

    NumPut("UInt", 40, bi, 0)
    NumPut("Int", w, bi, 4)
    NumPut("Int", h, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", bpp, bi, 14)

    hbm := DllCall("CreateDIBSection", "UPtr", hdc, "UPtr", bi.Ptr, "UInt", 0, "UPtr*", &ppvBits := 0, "UPtr", 0,
        "UInt", 0, "UPtr")

    DllCall("ReleaseDC", "UPtr", 0, "UPtr", hdc)
    return hbm
}

Gdip_SaveBitmapToFile(pBitmap, sOutput) {
    _p := 0

    SplitPath(sOutput, , , &extension)
    if (extension = "") {
        extension := "bmp"
        sOutput .= ".bmp"
    }

    extension := "." extension

    DllCall("gdiplus\GdipGetImageEncodersSize", "UInt*", &nCount := 0, "UInt*", &nSize := 0)
    ci := Buffer(nSize)
    DllCall("gdiplus\GdipGetImageEncoders", "UInt", nCount, "UInt", nSize, "UPtr", ci.Ptr)

    loop nCount {
        sString := StrGet(NumGet(ci, (idx := (48 + 7 * A_PtrSize) * (A_Index - 1)) + 32 + 3 * A_PtrSize, "UPtr"),
        "UTF-16")
        if InStr(sString, "*" extension) {
            pCodec := ci.Ptr + idx
            break
        }
    }

    if !pCodec
        return -1

    DllCall("gdiplus\GdipSaveImageToFile", "UPtr", pBitmap, "WStr", sOutput, "UPtr", pCodec, "UInt", _p)
    return 0
}

Gdip_DisposeImage(pBitmap) {
    return DllCall("gdiplus\GdipDisposeImage", "UPtr", pBitmap)
}
