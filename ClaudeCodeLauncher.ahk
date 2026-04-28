; ============================================
; Claude Code Launcher with Omniroute
; ============================================

#Requires AutoHotkey v2+
#SingleInstance Force
#NoTrayIcon

;@Ahk2Exe-SetName Claude Code Launcher
;@Ahk2Exe-SetDescription Лаунчер для Claude Code через Omniroute
;@Ahk2Exe-SetVersion 1.3.5
;@Ahk2Exe-SetMainIcon Assets\LCC.ico

; === ВЕРСИЯ ===
SCRIPT_VERSION := "v1.3.5"

;@Ahk2Exe-IgnoreBegin
try {
    TraySetIcon(A_ScriptDir "\Assets\LCC.ico")
}
;@Ahk2Exe-IgnoreEnd

; === ОБРАБОТЧИК ОШИБОК ===
OnError(LogErrorToFile)

LogErrorToFile(exception, mode) {
    errorLog := A_ScriptDir "\ahk_error.log"
    timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")

    errorText := "[" timestamp "]`n"
    errorText .= "Error: " exception.Message "`n"
    errorText .= "What: " exception.What "`n"
    errorText .= "Extra: " exception.Extra "`n"
    errorText .= "File: " exception.File "`n"
    errorText .= "Line: " exception.Line "`n"
    errorText .= "Stack:`n" exception.Stack "`n`n"

    try {
        FileAppend(errorText, errorLog, "UTF-8")
    }

    return 0  ; Показать стандартное окно ошибки
}

; === ГОРЯЧИЕ КЛАВИШИ ===
#HotIf WinActive("ahk_id " mainGui.Hwnd)
F5:: Reload
#HotIf

; === НАСТРОЙКИ ===
MAX_HISTORY := 10  ; Максимальное количество папок в истории
TIMEOUT_SECONDS := 30  ; Таймаут ожидания запуска Omniroute (в секундах)
CONFIG_FILE := A_ScriptDir "\cc_launcher.ini"  ; Единый файл конфигурации
CLAUDE_SESSIONS_DIR := EnvGet("USERPROFILE") "\.claude\sessions"  ; Папка с сессиями Claude Code
USE_NEW_TAB := IniRead(CONFIG_FILE, "Settings", "UseNewTab", "1") = "1"  ; Запускать в новой вкладке Windows Terminal (Windows 11)
ENABLE_LOGGING := true  ; Включить логирование (true/false)
LOG_FILE := A_ScriptDir "\cc_launcher.log"  ; Файл лога

; === ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ===
global selectedFolder := ""
global historyList := []
global activeSessions := Map()  ; Карта активных сессий: путь -> {pid, sessionId}
global mainGui := ""
global sessionsContainer := ""
global sessionBtnCounter := 0  ; Счётчик для уникальных имён кнопок
global wmiSink := ""  ; WMI Event Sink для отслеживания процессов
global sessionSearchTimers := Map()  ; Таймеры поиска session ID: путь -> {timer, knownFiles}
global resetBtn := ""  ; Кнопка сброса сессии
global folderInputDebounceTimer := ""  ; Таймер для debounce ввода папки

; === ОСНОВНАЯ ЛОГИКА ===
Main()

; === ФУНКЦИЯ ЛОГИРОВАНИЯ ===
Log(message, level := "INFO") {
    global ENABLE_LOGGING, LOG_FILE

    if (!ENABLE_LOGGING) {
        return
    }

    timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    logEntry := "[" timestamp "] [" level "] " message "`n"

    try {
        FileAppend(logEntry, LOG_FILE)
    } catch {
        ; Если не удалось записать в лог, игнорируем ошибку
    }
}

Main() {
    Log("=== Запуск лаунчера ===")

    ; Загружаем историю папок
    LoadHistory()

    ; Восстанавливаем активные сессии
    RestoreActiveSessions()

    ; Инициализируем WMI мониторинг процессов
    InitProcessMonitoring()

    ; Показываем GUI для выбора папки
    ShowFolderSelectionGUI()
}

; === ЗАГРУЗКА ИСТОРИИ ===
LoadHistory() {
    global historyList, CONFIG_FILE
    historyList := []

    ; Миграция из старого формата (cc_history.txt)
    oldHistoryFile := A_ScriptDir "\cc_history.txt"
    if FileExist(oldHistoryFile) {
        Log("Миграция истории из cc_history.txt")
        content := FileRead(oldHistoryFile)
        loop parse, content, "`n", "`r" {
            if (A_LoopField != "" && DirExist(A_LoopField)) {
                historyList.Push(A_LoopField)
            }
        }
        ; Сохраняем в новый формат
        if (historyList.Length > 0) {
            SaveHistory(historyList[1])  ; Сохранит весь список
        }
        ; Удаляем старый файл
        try {
            FileDelete(oldHistoryFile)
            Log("Старый файл cc_history.txt удалён")
        }
        return
    }

    ; Миграция позиции окна из старого файла
    oldPositionFile := A_ScriptDir "\cc_position.ini"
    if FileExist(oldPositionFile) {
        Log("Миграция позиции окна из cc_position.ini")
        oldX := IniRead(oldPositionFile, "Window", "X", "")
        oldY := IniRead(oldPositionFile, "Window", "Y", "")
        if (oldX != "" && oldY != "") {
            IniWrite(oldX, CONFIG_FILE, "Window", "X")
            IniWrite(oldY, CONFIG_FILE, "Window", "Y")
            Log("Позиция окна мигрирована: X=" oldX ", Y=" oldY)
        }
        ; Удаляем старый файл
        try {
            FileDelete(oldPositionFile)
            Log("Старый файл cc_position.ini удалён")
        }
    }

    ; Читаем историю из INI файла
    loop 10 {
        folder := IniRead(CONFIG_FILE, "History", "Folder" A_Index, "")
        if (folder != "" && DirExist(folder)) {
            historyList.Push(folder)
        }
    }
}

; === ВОССТАНОВЛЕНИЕ АКТИВНЫХ СЕССИЙ ===
RestoreActiveSessions() {
    global activeSessions, CLAUDE_SESSIONS_DIR

    Log("=== Восстановление активных сессий ===")

    ; Шаг 1: Читаем все JSON файлы сессий
    loop files, CLAUDE_SESSIONS_DIR "\*.json" {
        try {
            content := FileRead(A_LoopFileFullPath, "UTF-8")

            ; Извлекаем pid, cwd и sessionId из JSON
            if RegExMatch(content, '"pid"\s*:\s*(\d+)', &pidMatch) {
                pid := Integer(pidMatch[1])

                if RegExMatch(content, '"cwd"\s*:\s*"([^"]+)"', &cwdMatch) {
                    folderPath := StrReplace(cwdMatch[1], "\\", "\")

                    if RegExMatch(content, '"sessionId"\s*:\s*"([^"]+)"', &sessionMatch) {
                        sessionId := sessionMatch[1]

                        ; Проверяем, существует ли процесс с этим PID
                        if ProcessExist(pid) {
                            ; Находим соответствующий cmd.exe процесс
                            cmdPid := FindCmdProcessByNodePid(pid)
                            if (cmdPid > 0) {
                                activeSessions[folderPath] := { pid: cmdPid, sessionId: sessionId }
                                Log("Восстановлена сессия из JSON: Папка=" folderPath ", NodePID=" pid ", CmdPID=" cmdPid ", SessionID=" sessionId
                                )
                            } else {
                                Log("Не найден cmd.exe для node.exe PID=" pid)
                            }
                        } else {
                            Log("Процесс не существует для сессии: PID=" pid ", Папка=" folderPath ", SessionID=" sessionId
                            )
                        }
                    }
                }
            }
        } catch as err {
            Log("Ошибка чтения файла " A_LoopFileFullPath ": " err.Message, "ERROR")
        }
    }

    ; Шаг 2: Ищем запущенные процессы Claude Code без JSON файлов
    try {
        result := ComObjGet("winmgmts:").ExecQuery(
            "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='node.exe'")
        for process in result {
            cmdLine := process.CommandLine

            ; Проверяем, что это процесс Claude Code
            if (InStr(cmdLine, "claude-code") && InStr(cmdLine, "--name")) {
                pid := process.ProcessId

                ; Извлекаем имя сессии из командной строки
                if RegExMatch(cmdLine, '--name\s+"([^"]+)"', &nameMatch) {
                    sessionName := nameMatch[1]

                    ; Пытаемся найти папку по имени сессии через окно Windows Terminal
                    folderPath := FindFolderBySessionName(sessionName, pid)

                    if (folderPath != "" && !activeSessions.Has(folderPath)) {
                        ; Добавляем сессию без sessionId (он будет найден позже)
                        activeSessions[folderPath] := { pid: pid, sessionId: "" }
                        Log("Восстановлена сессия из процесса: Папка=" folderPath ", PID=" pid ", Имя=" sessionName)

                        ; Запускаем поиск session ID
                        StartSessionIdSearch(folderPath)
                    }
                }
            }
        }
    } catch as err {
        Log("Ошибка поиска процессов Claude Code: " err.Message, "ERROR")
    }

    Log("Восстановлено сессий: " activeSessions.Count)
}

; === ПОИСК CMD.EXE ПО PID NODE.EXE ===
FindCmdProcessByNodePid(nodePid) {
    try {
        ; Получаем родительский процесс node.exe (это должен быть cmd.exe)
        result := ComObjGet("winmgmts:").ExecQuery("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" nodePid
        )
        for process in result {
            parentPid := process.ParentProcessId

            ; Проверяем, что родитель - это cmd.exe
            parentResult := ComObjGet("winmgmts:").ExecQuery("SELECT Name FROM Win32_Process WHERE ProcessId=" parentPid
            )
            for parentProc in parentResult {
                if (parentProc.Name = "cmd.exe") {
                    Log("Найден cmd.exe (PID=" parentPid ") для node.exe (PID=" nodePid ")")
                    return parentPid
                }
            }
        }
    } catch as err {
        Log("Ошибка поиска cmd.exe для node.exe PID=" nodePid ": " err.Message, "ERROR")
    }

    return 0
}

; === ПОИСК ПАПКИ ПО ИМЕНИ СЕССИИ ===
FindFolderBySessionName(sessionName, pid) {
    global historyList

    ; Стратегия 1: Проверяем историю папок
    for folderPath in historyList {
        folderNameFromPath := GetFolderName(folderPath)
        if (folderNameFromPath = sessionName) {
            Log("Найдена папка в истории: " folderPath)
            return folderPath
        }
    }

    ; Стратегия 2: Пытаемся получить cwd из родительского процесса cmd.exe
    try {
        result := ComObjGet("winmgmts:").ExecQuery("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" pid)
        for process in result {
            parentPid := process.ParentProcessId

            ; Получаем информацию о родительском процессе
            parentResult := ComObjGet("winmgmts:").ExecQuery("SELECT CommandLine FROM Win32_Process WHERE ProcessId=" parentPid
            )
            for parentProcess in parentResult {
                cmdLine := parentProcess.CommandLine

                ; Ищем путь в командной строке cmd.exe
                if RegExMatch(cmdLine, 'cd /d "([^"]+)"', &pathMatch) {
                    folderPath := pathMatch[1]
                    Log("Найдена папка из командной строки родителя: " folderPath)
                    return folderPath
                }

                ; Для Windows Terminal ищем параметр -d
                if RegExMatch(cmdLine, '-d "([^"]+)"', &pathMatch) {
                    folderPath := pathMatch[1]
                    Log("Найдена папка из параметра -d: " folderPath)
                    return folderPath
                }
            }
        }
    }

    Log("Не удалось найти папку для сессии: " sessionName, "WARN")
    return ""
}

; === СОХРАНЕНИЕ ИСТОРИИ ===
SaveHistory(newFolder) {
    global historyList, MAX_HISTORY, CONFIG_FILE

    ; Удаляем папку из списка, если она уже есть
    for index, folder in historyList {
        if (folder = newFolder) {
            historyList.RemoveAt(index)
            break
        }
    }

    ; Добавляем папку в начало списка
    historyList.InsertAt(1, newFolder)

    ; Ограничиваем размер истории
    while (historyList.Length > MAX_HISTORY) {
        historyList.Pop()
    }

    ; Сохраняем в INI файл
    loop MAX_HISTORY {
        if (A_Index <= historyList.Length) {
            IniWrite(historyList[A_Index], CONFIG_FILE, "History", "Folder" A_Index)
        } else {
            IniDelete(CONFIG_FILE, "History", "Folder" A_Index)
        }
    }
}

; === GUI ДЛЯ ВЫБОРА ПАПКИ ===
ShowFolderSelectionGUI() {
    global selectedFolder, historyList, mainGui, sessionsContainer, resetBtn, statusText

    mainGui := Gui(, "Claude Code Launcher " SCRIPT_VERSION)
    mainGui.SetFont("s10")

    ; === СЕКЦИЯ 1: ВЫБОР ПАПКИ ===
    ; Текст
    mainGui.Add("Text", "ym+5", "Выберите папку для запуска Claude Code:")

    ; ComboBox с историей
    folderCombo := mainGui.Add("ComboBox", "xs y+m w382 vFolderPath")
    if (historyList.Length > 0) {
        for folder in historyList {
            folderCombo.Add([folder])
        }
        folderCombo.Choose(1)
    }

    ; Обработчик изменения текста в ComboBox (с debounce)
    folderCombo.OnEvent("Change", (*) => OnFolderPathChange(folderCombo))

    ; Кнопка "Обзор"
    browseBtn := mainGui.Add("Button", "x+5 y35 h26", "Обзор...")
    browseBtn.OnEvent("Click", (*) => BrowseFolder(mainGui, folderCombo))

    ; Разделитель 1
    ; mainGui.Add("Text", "x15 y75 w520 h1 0x10")

    ; === СЕКЦИЯ 2: НАСТРОЙКИ ===
    ; GroupBox для настроек
    mainGui.Add("GroupBox", "xs y+m w360 r4 Section", "Настройки запуска")

    ; Чекбокс для запуска в Windows Terminal (Windows 10)
    isWin11 := IsWindows11()
    useTerminalCheckbox := mainGui.Add("Checkbox", "xp+10 yp+23 vUseTerminal",
        "Запускать сессию в Терминале (для Windows 10)")
    useTerminalCheckbox.Value := IniRead(CONFIG_FILE, "Settings", "UseTerminal", "0") = "1"
    useTerminalCheckbox.OnEvent("Click", (*) => OnUseTerminalClick(useTerminalCheckbox, useNewTabCheckbox, statusText))

    ; Делаем чекбокс неактивным в Windows 11
    if (isWin11) {
        useTerminalCheckbox.Enabled := false
    }

    ; Чекбокс для выбора режима запуска в новой вкладке
    useNewTabCheckbox := mainGui.Add("Checkbox", "xp y+5 vUseNewTab", "Запускать в новой вкладке (только в Терминале)")
    useNewTabCheckbox.Value := USE_NEW_TAB
    useNewTabCheckbox.OnEvent("Click", (*) => IniWrite(useNewTabCheckbox.Value ? "1" : "0", CONFIG_FILE, "Settings",
        "UseNewTab"))

    ; Делаем чекбокс неактивным если не Windows 11 и не включен Windows Terminal
    if (!isWin11 && useTerminalCheckbox.Value = 0) {
        useNewTabCheckbox.Enabled := false
    }

    ; Чекбокс для загрузки прошлой сессии
    loadSessionCheckbox := mainGui.Add("Checkbox", "xp y+5 vLoadSession", "Загружать прошлую сессию")
    loadSessionCheckbox.Value := IniRead(CONFIG_FILE, "Settings", "LoadSession", "1") = "1"
    loadSessionCheckbox.OnEvent("Click", (*) => IniWrite(loadSessionCheckbox.Value ? "1" : "0", CONFIG_FILE, "Settings",
        "LoadSession"))

    ; Чекбокс для режима пропуска разрешений
    skipPermissionsCheckbox := mainGui.Add("Checkbox", "xp y+5 vSkipPermissions",
        "Запустить в режиме пропуска разрешений")
    skipPermissionsCheckbox.Value := IniRead(CONFIG_FILE, "Settings", "SkipPermissions", "0") = "1"
    skipPermissionsCheckbox.OnEvent("Click", (*) => OnSkipPermissionsClick(skipPermissionsCheckbox, mainGui))

    ; Кнопка "Сброс"
    resetBtn := mainGui.Add("Button", "xp+359 yp-44 w86 h30", "Сброс")
    resetBtn.OnEvent("Click", (*) => ResetSession(folderCombo, statusText))

    ; Кнопки Запустить и Закрыть
    launchBtn := mainGui.Add("Button", "xp y+m h30 Default", "Запустить")
    launchBtn.OnEvent("Click", (*) => OnLaunchClick(mainGui, folderCombo, launchBtn, cancelBtn, statusText))

    cancelBtn := mainGui.Add("Button", "xp+0 yp+0 w0 h30", "Закрыть")
    cancelBtn.OnEvent("Click", (*) => ExitApp())

    ; Разделитель 2
    mainGui.Add("Text", "xm y+7 w457 h1 0x10")

    ; === СЕКЦИЯ 3: СТАТУС ===
    ; Текстовое поле для статуса (увеличенная высота)
    statusText := mainGui.Add("Text", "xm y+15 w455 h30 +Center", "")
    statusText.SetFont("s10 bold")

    ; === СЕКЦИЯ 5: АКТИВНЫЕ СЕССИИ ===
    ; Разделитель 4
    mainGui.Add("Text", "xm y+0 w457 h1 0x10")
    mainGui.Add("Text", "xm y+0", "Активные сессии:")
    sessionsContainer := mainGui.Add("Text", "xm w455 h34 -Center 0x200", "")

    ; Загружаем сохранённую позицию окна
    savedX := IniRead(CONFIG_FILE, "Window", "X", "")
    savedY := IniRead(CONFIG_FILE, "Window", "Y", "")

    if (savedX != "" && savedY != "" && IsInteger(savedX) && IsInteger(savedY)) {
        ; Валидируем координаты перед показом окна
        defaultWidth := 478
        defaultHeight := 400  ; Примерная начальная высота
        validatedCoords := ValidateWindowPosition(Integer(savedX), Integer(savedY), defaultWidth, defaultHeight)

        mainGui.Show("x" validatedCoords.x " y" validatedCoords.y " w478")
        Log("Окно показано в сохранённой позиции: X=" validatedCoords.x ", Y=" validatedCoords.y)
    } else {
        mainGui.Show("w478")
        Log("Окно показано в позиции по умолчанию")
    }

    ; Сохраняем позицию при закрытии окна
    mainGui.OnEvent("Close", (*) => (SaveWindowPosition(), ExitApp()))

    ; Отслеживаем завершение перемещения окна через WM_EXITSIZEMOVE
    OnMessage(0x0232, WM_EXITSIZEMOVE)

    ; Отслеживание наведения мыши для tooltip
    OnMessage(0x0200, OnMouseMove)
    OnMessage(0x0006, OnWindowDeactivate)

    ; Проверяем состояние кнопки "Сброс" при запуске
    UpdateResetButtonState(folderCombo)

    ; Обновляем отображение восстановленных сессий
    UpdateSessionsDisplay()
}

; === ОБРАБОТЧИК СООБЩЕНИЯ WM_EXITSIZEMOVE ===
WM_EXITSIZEMOVE(wParam, lParam, msg, hwnd) {
    global mainGui

    ; Проверяем, что это наше окно
    if (hwnd = mainGui.Hwnd) {
        SaveWindowPosition()
    }
}

; === ПРОВЕРКА НА ЦЕЛОЕ ЧИСЛО ===
IsInteger(value) {
    if (value = "") {
        return false
    }
    return (value ~= "^-?\d+$")
}

; === ВАЛИДАЦИЯ ПОЗИЦИИ ОКНА ===
ValidateWindowPosition(x, y, width, height) {
    ; Получаем размеры всех мониторов
    MonitorGetWorkArea(, &workLeft, &workTop, &workRight, &workBottom)

    ; Минимальная видимая часть окна (в пикселях)
    minVisibleWidth := 100
    minVisibleHeight := 50

    ; Проверяем, что окно не полностью за пределами экрана
    ; Левая граница
    if (x + width < minVisibleWidth) {
        x := 0
        Log("Координата X скорректирована: окно было за левой границей экрана")
    }

    ; Правая граница
    if (x > workRight - minVisibleWidth) {
        x := workRight - width
        if (x < 0) {
            x := 0
        }
        Log("Координата X скорректирована: окно было за правой границей экрана")
    }

    ; Верхняя граница
    if (y + height < minVisibleHeight) {
        y := 0
        Log("Координата Y скорректирована: окно было за верхней границей экрана")
    }

    ; Нижняя граница
    if (y > workBottom - minVisibleHeight) {
        y := workBottom - height
        if (y < 0) {
            y := 0
        }
        Log("Координата Y скорректирована: окно было за нижней границей экрана")
    }

    return { x: x, y: y }
}

; === СОХРАНЕНИЕ ПОЗИЦИИ ОКНА ===
SaveWindowPosition() {
    global mainGui, CONFIG_FILE

    try {
        mainGui.GetPos(&x, &y, &width, &height)

        ; Валидация координат перед сохранением
        validatedCoords := ValidateWindowPosition(x, y, width, height)

        IniWrite(validatedCoords.x, CONFIG_FILE, "Window", "X")
        IniWrite(validatedCoords.y, CONFIG_FILE, "Window", "Y")
        Log("Позиция окна сохранена: X=" validatedCoords.x ", Y=" validatedCoords.y)
    } catch as err {
        Log("Ошибка сохранения позиции окна: " err.Message, "ERROR")
    }
}

; === ОБРАБОТЧИК ЧЕКБОКСА WINDOWS TERMINAL (WINDOWS 10) ===
OnUseTerminalClick(useTerminalCheckbox, useNewTabCheckbox, statusText) {
    global CONFIG_FILE

    ; Если чекбокс включается
    if (useTerminalCheckbox.Value) {
        ; Проверяем, установлен ли Windows Terminal
        if (!IsWindowsTerminalInstalled()) {
            Log("Windows Terminal не установлен, начинаем установку")
            statusText.Value := "Установка Терминала..."
            statusText.SetFont("cBlue")

            ; Запускаем установку
            try {
                RunWait('cmd.exe /c winget install --id Microsoft.WindowsTerminal -e', , "Hide")

                ; Проверяем успешность установки
                if (IsWindowsTerminalInstalled()) {
                    Log("Windows Terminal успешно установлен")
                    statusText.Value := "Терминал установлен"
                    statusText.SetFont("cGreen")

                    ; Сохраняем состояние чекбокса
                    IniWrite("1", CONFIG_FILE, "Settings", "UseTerminal")

                    ; Активируем чекбокс новой вкладки
                    useNewTabCheckbox.Enabled := true

                    ; Очищаем сообщение через 3 секунды
                    SetTimer(() => (statusText.Value := "", statusText.SetFont("cBlack")), -3000)
                } else {
                    Log("Не удалось установить Windows Terminal", "ERROR")
                    statusText.Value := "Ошибка установки Терминала"
                    statusText.SetFont("cRed")
                    useTerminalCheckbox.Value := false

                    ; Очищаем сообщение через 3 секунды
                    SetTimer(() => (statusText.Value := "", statusText.SetFont("cBlack")), -3000)
                }
            } catch as err {
                Log("Ошибка при установке Windows Terminal: " err.Message, "ERROR")
                statusText.Value := "Ошибка установки Терминала"
                statusText.SetFont("cRed")
                useTerminalCheckbox.Value := false

                ; Очищаем сообщение через 3 секунды
                SetTimer(() => (statusText.Value := "", statusText.SetFont("cBlack")), -3000)
            }
        } else {
            ; Terminal уже установлен
            IniWrite("1", CONFIG_FILE, "Settings", "UseTerminal")
            useNewTabCheckbox.Enabled := true
        }
    } else {
        ; Отключаем использование Terminal
        IniWrite("0", CONFIG_FILE, "Settings", "UseTerminal")
        useNewTabCheckbox.Enabled := false
        useNewTabCheckbox.Value := false
        IniWrite("0", CONFIG_FILE, "Settings", "UseNewTab")
    }
}

; === ПРОВЕРКА УСТАНОВКИ WINDOWS TERMINAL ===
IsWindowsTerminalInstalled() {
    ; Способ 1: Проверяем через winget list
    try {
        shell := ComObject("WScript.Shell")
        result := shell.Exec("cmd.exe /c winget list --id Microsoft.WindowsTerminal 2>nul")
        output := result.StdOut.ReadAll()
        if (InStr(output, "Microsoft.WindowsTerminal")) {
            Log("Windows Terminal найден через winget list")
            return true
        }
    }

    ; Способ 2: Проверяем наличие wt.exe в PATH
    try {
        shell := ComObject("WScript.Shell")
        result := shell.Exec("cmd.exe /c where wt.exe 2>nul")
        output := result.StdOut.ReadAll()
        if (output != "") {
            Log("Windows Terminal найден через where wt.exe")
            return true
        }
    }

    ; Способ 3: Проверяем стандартные пути установки
    possiblePaths := [
        EnvGet("LOCALAPPDATA") "\Microsoft\WindowsApps\wt.exe",
        "C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_*\wt.exe"
    ]

    for path in possiblePaths {
        if FileExist(path) {
            Log("Windows Terminal найден по пути: " path)
            return true
        }
    }

    Log("Windows Terminal не найден")
    return false
}

; === ОБРАБОТЧИК ЧЕКБОКСА ПРОПУСКА РАЗРЕШЕНИЙ ===
OnSkipPermissionsClick(checkbox, parentGui) {
    global CONFIG_FILE

    ; Если чекбокс включается
    if (checkbox.Value) {
        ; Проверяем настройку "Больше не спрашивать"
        dontAskAgain := IniRead(CONFIG_FILE, "Settings", "SkipPermissionsDontAsk", "0")

        if (dontAskAgain != "1") {
            ; Создаём диалоговое окно с предупреждением
            confirmGui := Gui("+Owner" parentGui.Hwnd " +ToolWindow", "Предупреждение")
            confirmGui.SetFont("s10")
            confirmGui.Add("Text", "x10 y10 w300", "Вы уверены?`nВключайте этот режим на свой страх и риск!")

            dontAskCB := confirmGui.Add("Checkbox", "x10 y+10", "Больше не спрашивать")

            okBtn := confirmGui.Add("Button", "x10 y+20 w145 h30 Default", "ОК")
            cancelBtn := confirmGui.Add("Button", "x+10 yp w145 h30", "Отмена")

            result := ""
            dontAskValue := false
            okBtn.OnEvent("Click", (*) => (result := "OK", dontAskValue := dontAskCB.Value, confirmGui.Destroy()))
            cancelBtn.OnEvent("Click", (*) => (result := "Cancel", confirmGui.Destroy()))
            confirmGui.OnEvent("Close", (*) => (result := "Cancel", confirmGui.Destroy()))
            confirmGui.OnEvent("Escape", (*) => (result := "Cancel", confirmGui.Destroy()))

            parentGui.Opt("+Disabled")
            confirmGui.Show()

            ; Ждём закрытия окна
            WinWaitClose("ahk_id " confirmGui.Hwnd)
            parentGui.Opt("-Disabled")

            if (result = "Cancel") {
                ; Отменяем включение чекбокса
                checkbox.Value := false
                return
            }

            ; Сохраняем настройку "Больше не спрашивать"
            if (dontAskValue) {
                IniWrite("1", CONFIG_FILE, "Settings", "SkipPermissionsDontAsk")
            }
        }

        ; Сохраняем состояние чекбокса
        IniWrite("1", CONFIG_FILE, "Settings", "SkipPermissions")
    } else {
        ; Сохраняем отключённое состояние
        IniWrite("0", CONFIG_FILE, "Settings", "SkipPermissions")
    }
}

; === СБРОС СЕССИИ ===
ResetSession(folderCombo, statusText) {
    global CLAUDE_SESSIONS_DIR, mainGui

    folderPath := folderCombo.Text
    if (folderPath = "") {
        MsgBox("Введите путь к папке", "Ошибка", "Icon!")
        return
    }

    ; Нормализуем путь
    normalizedPath := StrLower(StrReplace(folderPath, "/", "\"))
    Log("Сброс сессии для папки: " normalizedPath)

    ; Ищем JSON файл для этой папки
    foundFile := ""
    loop files, CLAUDE_SESSIONS_DIR "\*.json" {
        try {
            content := FileRead(A_LoopFileFullPath, "UTF-8")
            if RegExMatch(content, '"cwd"\s*:\s*"([^"]+)"', &cwdMatch) {
                fileCwd := StrLower(StrReplace(cwdMatch[1], "\\", "\"))
                if (fileCwd = normalizedPath) {
                    foundFile := A_LoopFileFullPath
                    break
                }
            }
        }
    }

    if (foundFile = "") {
        MsgBox("Сессия для этой папки не найдена", "Информация", "Iconi")
        Log("JSON файл сессии не найден для папки: " normalizedPath)
        return
    }

    ; Проверяем настройку "Больше не спрашивать"
    dontAskAgain := IniRead(CONFIG_FILE, "Settings", "ResetDontAsk", "0")

    if (dontAskAgain != "1") {
        ; Создаём диалоговое окно с чекбоксом
        confirmGui := Gui("+Owner" mainGui.Hwnd " +ToolWindow", "Подтверждение")
        confirmGui.SetFont("s10")
        confirmGui.Add("Text", "x10 y10 w300",
            "Удалить сохранённую сессию для этой папки?`n`nПри следующем запуске откроется чистая сессия.")

        dontAskCB := confirmGui.Add("Checkbox", "x10 y+10", "Больше не спрашивать")

        yesBtn := confirmGui.Add("Button", "x10 y+20 w145 h30 Default", "Да")
        noBtn := confirmGui.Add("Button", "x+10 yp w145 h30", "Нет")

        result := ""
        dontAskValue := 0

        yesBtn.OnEvent("Click", (*) => (result := "Yes", dontAskValue := dontAskCB.Value, confirmGui.Destroy()))
        noBtn.OnEvent("Click", (*) => (result := "No", confirmGui.Destroy()))
        confirmGui.OnEvent("Close", (*) => (result := "No", confirmGui.Destroy()))
        confirmGui.OnEvent("Escape", (*) => (result := "No", confirmGui.Destroy()))

        mainGui.Opt("+Disabled")
        confirmGui.Show()

        ; Ждём закрытия окна
        WinWaitClose("ahk_id " confirmGui.Hwnd)
        mainGui.Opt("-Disabled")

        if (result = "No") {
            return
        }

        ; Сохраняем настройку "Больше не спрашивать"
        if (dontAskValue) {
            IniWrite("1", CONFIG_FILE, "Settings", "ResetDontAsk")
        }
    }

    ; Удаляем файл
    try {
        FileDelete(foundFile)
        statusText.Value := "Сессия успешно сброшена!"
        statusText.SetFont("cGreen")
        Log("JSON файл сессии удалён: " foundFile)

        ; Очищаем сообщение через 3 секунды
        SetTimer(() => (statusText.Value := "", statusText.SetFont("cBlack")), -3000)
    } catch as err {
        statusText.Value := "Ошибка удаления файла сессии"
        statusText.SetFont("cRed")
        Log("Ошибка удаления файла: " err.Message, "ERROR")

        ; Очищаем сообщение через 3 секунды
        SetTimer(() => (statusText.Value := "", statusText.SetFont("cBlack")), -3000)
    }
}

; === ОБРАБОТЧИК КНОПКИ "ОБЗОР" ===
BrowseFolder(guiObj, folderCombo) {
    startPath := (folderCombo.Text != "" ? folderCombo.Text : "")

    ; Блокируем главное окно перед открытием диалога
    guiObj.Opt("+Disabled")

    selectedPath := DirSelect("*" startPath, 3, "Выберите папку для Claude Code")

    ; Разблокируем главное окно после закрытия диалога
    guiObj.Opt("-Disabled")

    ; Активируем окно лаунчера
    WinActivate("ahk_id " guiObj.Hwnd)

    if (selectedPath != "") {
        folderCombo.Text := selectedPath
        UpdateResetButtonState(folderCombo)
    }
}

; === ОБРАБОТЧИК ИЗМЕНЕНИЯ ПУТИ К ПАПКЕ (С DEBOUNCE) ===
OnFolderPathChange(folderCombo) {
    global folderInputDebounceTimer

    ; Останавливаем предыдущий таймер
    if (folderInputDebounceTimer != "") {
        SetTimer(folderInputDebounceTimer, 0)
    }

    ; Создаём новый таймер с задержкой 500 мс
    folderInputDebounceTimer := () => UpdateResetButtonState(folderCombo)
    SetTimer(folderInputDebounceTimer, -500)
}

; === ОБНОВЛЕНИЕ СОСТОЯНИЯ КНОПКИ "СБРОС" ===
UpdateResetButtonState(folderCombo) {
    global resetBtn, CLAUDE_SESSIONS_DIR

    folderPath := folderCombo.Text

    ; Если путь пустой, отключаем кнопку
    if (folderPath = "") {
        resetBtn.Enabled := false
        return
    }

    ; Нормализуем путь
    normalizedPath := StrLower(StrReplace(folderPath, "/", "\"))

    ; Ищем JSON файл для этой папки
    foundFile := false
    loop files, CLAUDE_SESSIONS_DIR "\*.json" {
        try {
            content := FileRead(A_LoopFileFullPath, "UTF-8")
            if RegExMatch(content, '"cwd"\s*:\s*"([^"]+)"', &cwdMatch) {
                fileCwd := StrLower(StrReplace(cwdMatch[1], "\\", "\"))
                if (fileCwd = normalizedPath) {
                    foundFile := true
                    break
                }
            }
        }
    }

    ; Включаем или отключаем кнопку в зависимости от результата
    resetBtn.Enabled := foundFile
}

; === ПРОВЕРКА ВЕРСИИ WINDOWS ===
IsWindows11() {
    ; Windows 11 имеет build number >= 22000
    buildNumber := VerCompare(A_OSVersion, "10.0.22000")
    return (buildNumber >= 0)
}

; === ОБРАБОТЧИК КНОПКИ "ЗАПУСТИТЬ" ===
OnLaunchClick(guiObj, folderCombo, launchBtn, cancelBtn, statusText) {
    global selectedFolder

    selectedFolder := folderCombo.Text
    Log("Попытка запуска для папки: " selectedFolder)

    if (selectedFolder = "") {
        Log("Ошибка: папка не выбрана", "ERROR")
        MsgBox("Пожалуйста, выберите папку!", "Ошибка", "Icon!")
        return
    }

    if (!DirExist(selectedFolder)) {
        Log("Ошибка: папка не существует - " selectedFolder, "ERROR")
        MsgBox("Выбранная папка не существует!", "Ошибка", "Icon!")
        return
    }

    ; Сохраняем в историю
    SaveHistory(selectedFolder)

    ; Отключаем только кнопку Запустить во время выполнения
    launchBtn.Enabled := false

    ; Запускаем процесс с передачей statusText и кнопок
    LaunchProcess(statusText, guiObj, launchBtn, cancelBtn)
}

; === ЗАПУСК ПРОЦЕССА ===
LaunchProcess(statusText, guiObj, launchBtn, cancelBtn) {
    global selectedFolder, TIMEOUT_SECONDS

    ; Проверяем, не запущен ли уже Omniroute
    statusText.Value := "Проверка Omniroute..."
    statusText.SetFont("cBlue")
    Log("Проверка запущен ли Omniroute")

    if (IsOmnirouteRunning()) {
        Log("Omniroute уже запущен")
        statusText.Value := "Omniroute уже запущен"
        statusText.SetFont("cGreen")
        Sleep(500)
        LaunchClaudeCode(statusText, guiObj, cancelBtn, launchBtn)
        return
    }

    ; Запускаем Omniroute
    statusText.Value := "Запуск Omniroute..."
    statusText.SetFont("cBlue")
    Log("Запуск Omniroute")

    try {
        Run("powershell.exe -ExecutionPolicy Bypass -NoExit -Command omniroute", , , &omniPID)
        Log("Omniroute запущен с PID: " omniPID)
    } catch as err {
        Log("Ошибка запуска Omniroute: " err.Message, "ERROR")
        statusText.Value := "Ошибка запуска Omniroute!"
        statusText.SetFont("cRed")
        MsgBox("Ошибка запуска Omniroute: " err.Message, "Ошибка", "Icon!")
        launchBtn.Enabled := true
        return
    }

    ; Ждём появления строки в окне PowerShell
    startTime := A_TickCount
    found := false

    loop {
        ; Проверяем таймаут
        if ((A_TickCount - startTime) > (TIMEOUT_SECONDS * 1000)) {
            Log("Таймаут ожидания Omniroute (" TIMEOUT_SECONDS " сек)", "ERROR")
            statusText.Value := "Таймаут ожидания Omniroute!"
            statusText.SetFont("cRed")
            MsgBox("Таймаут ожидания запуска Omniroute (" TIMEOUT_SECONDS " сек).`nПроверьте, что Omniroute установлен и работает корректно.",
                "Ошибка", "Icon!")
            launchBtn.Enabled := true
            return
        }

        ; Используем функцию IsOmnirouteRunning для проверки
        if (IsOmnirouteRunning()) {
            found := true
            break
        }

        Sleep(500)  ; Проверяем каждые 500 мс
    }

    if (found) {
        Log("Omniroute успешно запущен")
        statusText.Value := "Omniroute запущен успешно"
        statusText.SetFont("cGreen")

        ; Небольшая пауза для стабильности
        Sleep(1000)

        ; Запускаем Claude Code
        LaunchClaudeCode(statusText, guiObj, cancelBtn, launchBtn)
    }
}

; === ПРОВЕРКА, ЗАПУЩЕН ЛИ OMNIROUTE ===
IsOmnirouteRunning() {
    ; Проверяем процессы node.exe на наличие omniroute в командной строке
    try {
        result := ComObjGet("winmgmts:").ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='node.exe'")
        for process in result {
            if (InStr(process.CommandLine, "omniroute")) {
                ; Нашли процесс, но HTTP не ответил - возможно, ещё запускается
                return true
            }
        }
    }

    return false
}

; === ЗАПУСК CLAUDE CODE ===
LaunchClaudeCode(statusText, guiObj, cancelBtn, launchBtn) {
    global selectedFolder, activeSessions, USE_NEW_TAB

    statusText.Value := "Запуск Claude Code..."
    statusText.SetFont("cBlue")
    Log("Запуск Claude Code для папки: " selectedFolder)

    ; Проверяем, не запущена ли уже сессия в этой папке
    if activeSessions.Has(selectedFolder) {
        sessionInfo := activeSessions[selectedFolder]
        if ProcessExist(sessionInfo.pid) {
            Log("Сессия уже запущена, активируем окно")
            statusText.Value := "Сессия уже запущена"
            statusText.SetFont("cGreen")
            launchBtn.Enabled := true

            ; Активируем окно существующей сессии
            try {
                WinActivate("ahk_pid " sessionInfo.pid)
            } catch {
                Log("Не удалось активировать окно сессии", "WARN")
            }
            return
        } else {
            ; Процесс завершён, но запись осталась - удаляем
            activeSessions.Delete(selectedFolder)
            UpdateSessionsDisplay()
        }
    }

    ; Ищем существующую сессию в JSON-файлах для восстановления
    ; Получаем значение чекбокса загрузки сессии
    loadSession := true
    try {
        loadSession := guiObj["LoadSession"].Value
    } catch {
        loadSession := true
    }

    existingSessionId := FindExistingSession(selectedFolder)
    resumeCmd := ""

    if (loadSession && existingSessionId != "") {
        resumeCmd := " claude --resume " existingSessionId
        Log("Найдена существующая сессия для восстановления: " existingSessionId)
        Log("Команда восстановления: cc" resumeCmd)
    } else {
        if (!loadSession) {
            Log("Загрузка прошлой сессии отключена, запуск новой")
        } else {
            Log("Существующая сессия не найдена, запуск новой")
        }
    }

    ; Определяем режим запуска
    isWin11 := IsWindows11()
    useTerminal := false
    useNewTab := false

    if (isWin11) {
        ; Windows 11 - всегда используем Terminal, проверяем только новую вкладку
        useTerminal := true
        try {
            useNewTab := guiObj["UseNewTab"].Value
        } catch {
            useNewTab := USE_NEW_TAB
        }
    } else {
        ; Windows 10 - проверяем чекбокс UseTerminal
        try {
            useTerminal := guiObj["UseTerminal"].Value
        } catch {
            useTerminal := false
        }

        ; Если Terminal включен, проверяем чекбокс новой вкладки
        if (useTerminal) {
            try {
                useNewTab := guiObj["UseNewTab"].Value
            } catch {
                useNewTab := false
            }
        }
    }

    ; Получаем значение чекбокса пропуска разрешений
    skipPermissions := false
    try {
        skipPermissions := guiObj["SkipPermissions"].Value
    } catch {
        skipPermissions := false
    }

    ; Добавляем флаг пропуска разрешений, если чекбокс активен
    permissionsFlag := ""
    if (skipPermissions) {
        permissionsFlag := " --dangerously-skip-permissions"
        Log("Режим пропуска разрешений активирован")
    }

    Log("Режим запуска: " (useTerminal ? (useNewTab ? "новая вкладка Windows Terminal" : "новое окно Windows Terminal") :
        "новое окно cmd"))

    ; Получаем имя папки для заголовка окна
    folderName := GetFolderName(selectedFolder)

    try {
        if (useTerminal && useNewTab) {
            Run('wt.exe -w 0 nt -d "' selectedFolder '" cmd /k "cc --name \"' folderName '\"' resumeCmd permissionsFlag '"', , , &
                wtPID)
        } else if (useTerminal) {
            Run('wt.exe -d "' selectedFolder '" cmd /k "cc --name \"' folderName '\"' resumeCmd permissionsFlag '"', , , &
                wtPID)
        } else {
            Run('cmd.exe /k "cd /d ^"' selectedFolder '^" && cc --name ^"' folderName '^"' resumeCmd permissionsFlag '"', , , &
                wtPID)
        }

        Log("Процесс запущен с PID: " wtPID)

        ; Для Windows Terminal нужно найти дочерний процесс cmd.exe
        actualPID := 0
        if (useTerminal) {
            Log("Поиск процесса cmd.exe с именем сессии: " folderName)

            ; Запоминаем существующие процессы cmd.exe перед запуском
            existingPIDs := Map()
            try {
                result := ComObjGet("winmgmts:").ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name='cmd.exe'")
                for process in result {
                    existingPIDs[process.ProcessId] := true
                }
            }

            ; Ждём появления НОВОГО процесса cmd.exe с нужным именем в командной строке (до 5 секунд)
            loop 50 {
                Sleep(100)
                try {
                    ; Ищем cmd.exe с нашим именем сессии в командной строке
                    result := ComObjGet("winmgmts:").ExecQuery(
                        "SELECT ProcessId, CommandLine, CreationDate FROM Win32_Process WHERE Name='cmd.exe'")
                    newestPID := 0
                    newestTime := ""

                    for process in result {
                        cmdLine := process.CommandLine
                        processPID := process.ProcessId

                        ; Пропускаем существующие процессы
                        if (existingPIDs.Has(processPID)) {
                            continue
                        }

                        ; Проверяем, что это наш процесс (содержит имя папки и cc)
                        if (InStr(cmdLine, folderName) && InStr(cmdLine, "cc")) {
                            creationDate := process.CreationDate

                            ; Выбираем самый новый процесс
                            if (newestTime = "" || creationDate > newestTime) {
                                newestPID := processPID
                                newestTime := creationDate
                            }
                        }
                    }

                    if (newestPID > 0) {
                        actualPID := newestPID
                        Log("Найден новый процесс cmd.exe с PID: " actualPID)
                        break
                    }
                }
            }

            if (actualPID = 0) {
                Log("Процесс cmd.exe не найден за 5 секунд", "ERROR")
                statusText.Value := "Ошибка: не найден процесс cmd.exe"
                statusText.SetFont("cRed")
                launchBtn.Enabled := true
                return
            }
        } else {
            actualPID := wtPID
        }

        Log("Claude Code запущен с PID: " actualPID)

        ; Регистрируем сессию с пустым sessionId (будет найден позже)
        activeSessions[selectedFolder] := { pid: actualPID, sessionId: "" }
        Log("Сессия зарегистрирована: PID=" actualPID)

        ; Запускаем таймер поиска session ID
        StartSessionIdSearch(selectedFolder)

        statusText.Value := "Готово!"
        statusText.SetFont("cGreen")
        launchBtn.Enabled := true

        UpdateSessionsDisplay()
    } catch as err {
        Log("Ошибка запуска Claude Code: " err.Message, "ERROR")
        statusText.Value := "Ошибка запуска Claude Code!"
        statusText.SetFont("cRed")
        MsgBox("Ошибка запуска Claude Code: " err.Message, "Ошибка", "Icon!")
        launchBtn.Enabled := true
        return
    }
}

; === ПОИСК СУЩЕСТВУЮЩЕЙ СЕССИИ В JSON-ФАЙЛАХ ===
FindExistingSession(folderPath) {
    global CLAUDE_SESSIONS_DIR

    ; Нормализуем путь: заменяем / на \, приводим к нижнему регистру
    normalizedPath := StrLower(StrReplace(folderPath, "/", "\"))
    Log("Поиск существующей сессии для: " normalizedPath)

    loop files, CLAUDE_SESSIONS_DIR "\*.json" {
        try {
            ; Читаем файл в UTF-8 кодировке
            content := FileRead(A_LoopFileFullPath, "UTF-8")
            Log("Чтение файла: " A_LoopFileName)

            if RegExMatch(content, '"cwd"\s*:\s*"([^"]+)"', &cwdMatch) {
                fileCwd := cwdMatch[1]
                Log("Найден cwd в файле (до замены): " fileCwd)
                ; Заменяем экранированные слеши из JSON (\\) на обычные (\)
                fileCwd := StrReplace(fileCwd, "\\", "\")
                ; Приводим к нижнему регистру для сравнения
                fileCwd := StrLower(fileCwd)
                Log("Найден cwd в файле (после замены): " fileCwd)
                Log("Сравнение: [" normalizedPath "] == [" fileCwd "]")

                if (fileCwd = normalizedPath) {
                    Log("Пути совпадают!")
                    if RegExMatch(content, '"sessionId"\s*:\s*"([^"]+)"', &sessionMatch) {
                        sessionId := sessionMatch[1]
                        Log("Найдена существующая сессия: " sessionId)
                        return sessionId
                    }
                } else {
                    Log("Пути не совпадают")
                }
            }
        } catch as err {
            Log("Ошибка чтения файла " A_LoopFileFullPath ": " err.Message, "ERROR")
        }
    }

    return ""
}

; === ИНИЦИАЛИЗАЦИЯ WMI МОНИТОРИНГА ===
InitProcessMonitoring() {
    global wmiSink

    ; Всегда запускаем таймер для надёжности
    SetTimer(CheckActiveSessions, 2000)

    try {
        ; Создаём WMI Event Sink для отслеживания завершения процессов
        wmi := ComObjGet("winmgmts:\\.\root\CIMV2")

        ; Создаём объект-приёмник событий
        wmiSink := ComObject("WbemScripting.SWbemSink")
        ComObjConnect(wmiSink, "ProcessEvent_")

        ; Подписываемся на события завершения процессов
        wmi.ExecNotificationQueryAsync(wmiSink,
            "SELECT * FROM __InstanceDeletionEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Process'")
    } catch {
        ; WMI не работает, но таймер уже запущен
    }
}

; === ОБРАБОТЧИК WMI СОБЫТИЯ ЗАВЕРШЕНИЯ ПРОЦЕССА ===
ProcessEvent_OnObjectReady(objWbemObject, *) {
    global activeSessions

    try {
        ; Получаем PID завершённого процесса
        targetInstance := objWbemObject.TargetInstance
        terminatedPID := targetInstance.ProcessId

        ; Проверяем, есть ли этот PID в наших сессиях
        for folderPath, sessionInfo in activeSessions {
            if (sessionInfo.pid = terminatedPID) {
                ; Удаляем сессию из списка
                activeSessions.Delete(folderPath)

                ; Обновляем GUI
                UpdateSessionsDisplay()
                break
            }
        }
    }
}

; === ПРОВЕРКА АКТИВНЫХ СЕССИЙ (FALLBACK) ===
CheckActiveSessions() {
    global activeSessions

    initialCount := activeSessions.Count

    ; Проверяем каждую сессию
    for folderPath, sessionInfo in activeSessions {
        ; Проверяем, существует ли процесс
        if !ProcessExist(sessionInfo.pid) {
            Log("Процесс завершён: PID=" sessionInfo.pid ", Папка=" folderPath, "INFO")
            ; Процесс завершён, удаляем из списка
            activeSessions.Delete(folderPath)
        }
    }

    ; Обновляем отображение только если количество сессий изменилось
    if (activeSessions.Count != initialCount) {
        Log("Количество сессий изменилось: " initialCount " -> " activeSessions.Count)
        UpdateSessionsDisplay()
    }
}

; === ОБНОВЛЕНИЕ ОТОБРАЖЕНИЯ СЕССИЙ ===
UpdateSessionsDisplay() {
    global activeSessions, mainGui, sessionsContainer, sessionBtnCounter

    Log("UpdateSessionsDisplay вызвана, активных сессий: " activeSessions.Count)

    if !IsObject(mainGui) {
        Log("mainGui не является объектом", "ERROR")
        return
    }

    ; Скрываем старые кнопки сессий
    hiddenCount := 0
    try {
        for ctrl in mainGui {
            if InStr(ctrl.Name, "SessionBtn_") || InStr(ctrl.Name, "CloseBtn_") {
                ctrl.Visible := false
                hiddenCount++
            }
        }
        Log("Скрыто кнопок: " hiddenCount)
    } catch as err {
        Log("Ошибка при скрытии кнопок: " err.Message, "ERROR")
    }

    ; Если нет активных сессий
    if activeSessions.Count = 0 {
        Log("Нет активных сессий, обновление текста")
        sessionsContainer.Value := "Нет активных сессий"
        ; Не изменяем размер окна - оставляем как есть
        return
    }

    sessionsContainer.Value := ""

    ; Создаём кнопки для каждой сессии
    ; Извлекаем координаты
    sessionsContainer.GetPos(, &y)

    ; Присваиваем значение вашей переменной
    yPos := y

    for folderPath, sessionInfo in activeSessions {
        sessionBtnCounter++
        folderName := GetFolderName(folderPath)
        Log("Создание кнопки для: " folderName " (PID: " sessionInfo.pid ")")

        ; Создаём замыкание для сохранения значений
        CreateSessionButtons(folderPath, sessionInfo.pid, folderName, yPos, sessionBtnCounter)

        yPos += 35
    }

    ; Получаем текущую позицию и размер окна
    mainGui.GetPos(&currentX, &currentY, &currentWidth, &currentHeight)

    ; Получаем размер невидимой рамки окна
    WinGetPos(&winX, &winY, &winW, &winH, "ahk_id " mainGui.Hwnd)
    rect := Buffer(16)
    DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", mainGui.Hwnd, "UInt", 9, "Ptr", rect, "UInt", 16)
    frameHeight := NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int") - winH

    ; Вычисляем новую высоту
    newHeight := yPos + 35 + 10

    ; Получаем размер рабочей области экрана (без панели задач)
    MonitorGetWorkArea(, , , , &workAreaBottom)

    ; Проверяем, было ли окно вплотную к панели задач (с учётом рамки и допуском 10 пикселей)
    currentBottomEdge := currentY + currentHeight + frameHeight
    wasAtBottom := Abs(workAreaBottom - currentBottomEdge) <= 10

    Log("Расчёт позиции: currentY=" currentY ", currentHeight=" currentHeight ", newHeight=" newHeight)
    Log("Рамка окна: frameHeight=" frameHeight)
    Log("workAreaBottom=" workAreaBottom ", currentBottomEdge=" currentBottomEdge ", wasAtBottom=" wasAtBottom)

    ; Если окно было вплотную к панели задач, позиционируем его вплотную после изменения
    if (wasAtBottom) {
        newY := workAreaBottom - newHeight - frameHeight
        ; Проверяем, чтобы окно не вышло за верхнюю границу экрана
        if (newY < 0) {
            newY := 0
        }
        Log("Окно было вплотную к панели задач, позиционирование: Y " currentY " -> " newY)
        mainGui.Move(currentX, newY, 493, newHeight)
    } else {
        ; Вычисляем, где будет нижний край окна после изменения размера
        newBottomEdge := currentY + newHeight + frameHeight

        ; Если окно выходит за пределы рабочей области, сдвигаем его вверх
        if (newBottomEdge > workAreaBottom) {
            newY := workAreaBottom - newHeight - frameHeight
            ; Проверяем, чтобы окно не вышло за верхнюю границу экрана
            if (newY < 0) {
                newY := 0
            }
            Log("Окно выходит за пределы экрана, сдвиг вверх: Y " currentY " -> " newY)
            mainGui.Move(currentX, newY, 493, newHeight)
        } else {
            Log("Изменение размера окна на высоту: " newHeight " (сдвиг не требуется)")
            mainGui.Move(, , 493, newHeight)
        }
    }
}

; === ПОЛУЧЕНИЕ ИМЕНИ ПАПКИ ===
GetFolderName(fullPath) {
    SplitPath(fullPath, &folderName)
    return folderName
}

; === СОЗДАНИЕ КНОПОК СЕССИИ ===
CreateSessionButtons(folderPath, pid, folderName, yPos, counter) {
    global mainGui

    ; Кнопка сессии
    sessionBtn := mainGui.Add("Button", "x10 y" yPos " w428 h30 vSessionBtn_" counter, folderName)

    ; Создаём локальные копии для замыкания
    localPath := folderPath
    localPid := pid

    sessionBtn.OnEvent("Click", (*) => ActivateSession(localPath, localPid))

    ; Добавляем обработчик правой кнопки мыши для открытия папки
    sessionBtn.OnEvent("ContextMenu", (*) => OpenFolder(localPath))

    ; Кнопка закрытия
    closeBtn := mainGui.Add("Button", "x+0 yp w30 h30 vCloseBtn_" counter, "✖")
    closeBtn.OnEvent("Click", (*) => CloseSession(localPath, localPid))
}

; === ОТКРЫТИЕ ПАПКИ ПРОЕКТА ===
OpenFolder(folderPath) {
    Log("Открытие папки: " folderPath)
    try {
        Run('explorer.exe "' folderPath '"')
    } catch as err {
        Log("Ошибка открытия папки: " err.Message, "ERROR")
        MsgBox("Не удалось открыть папку: " err.Message, "Ошибка", "Icon!")
    }
}

; === АКТИВАЦИЯ СЕССИИ ===
ActivateSession(folderPath, pid) {
    global activeSessions

    Log("Попытка переключения на сессию: PID=" pid ", Папка=" folderPath)

    ; Получаем имя папки для поиска в заголовке окна
    folderName := GetFolderName(folderPath)
    Log("Поиск окна с именем папки: " folderName)

    ; Стратегия 1: Для Windows Terminal - активируем окно и переключаем вкладку
    wtHwnd := WinExist("ahk_exe WindowsTerminal.exe ahk_class CASCADIA_HOSTING_WINDOW_CLASS")
    if (wtHwnd) {
        Log("Найдено окно Windows Terminal: HWND=" wtHwnd)

        ; Активируем окно Windows Terminal
        WinActivate("ahk_id " wtHwnd)
        Sleep(100)

        ; Получаем текущий заголовок
        currentTitle := WinGetTitle("ahk_id " wtHwnd)
        Log("Текущий заголовок: " currentTitle)

        ; Если нужная вкладка уже активна, просто возвращаемся
        if InStr(currentTitle, folderName) {
            Log("Нужная вкладка уже активна")
            return
        }

        ; Подсчитываем количество вкладок с Claude Code
        try {
            result := ComObjGet("winmgmts:").ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name='cmd.exe'")
            tabCount := 0
            for process in result {
                cmdLine := ""
                try {
                    cmdResult := ComObjGet("winmgmts:").ExecQuery(
                        "SELECT CommandLine FROM Win32_Process WHERE ProcessId=" process.ProcessId)
                    for cmd in cmdResult {
                        cmdLine := cmd.CommandLine
                        break
                    }
                }
                if (InStr(cmdLine, "cc") && InStr(cmdLine, "--name")) {
                    tabCount++
                }
            }
            Log("Количество вкладок с Claude Code: " tabCount)

            ; Перебираем вкладки через Ctrl+Tab, пока не найдём нужную
            loop tabCount {
                Send("^{Tab}")
                Sleep(150)

                newTitle := WinGetTitle("ahk_id " wtHwnd)
                Log("Проверка вкладки " A_Index ": " newTitle)

                if InStr(newTitle, folderName) {
                    Log("Найдена нужная вкладка на позиции " A_Index)
                    return
                }
            }

            Log("Вкладка не найдена после перебора всех вкладок", "WARN")
        }

        return
    }

    ; Стратегия 2: Ищем окно CMD по заголовку
    cmdHwnd := 0
    loop {
        cmdHwnd := WinExist("ahk_class ConsoleWindowClass" (cmdHwnd ? " ahk_id " cmdHwnd : ""))
        if (!cmdHwnd)
            break

        title := WinGetTitle("ahk_id " cmdHwnd)
        if InStr(title, folderName) {
            Log("Найдено окно CMD по заголовку: " title)
            try {
                WinActivate("ahk_id " cmdHwnd)
                Log("Успешно переключено на окно CMD")
                return
            }
        }

        ; Переходим к следующему окну CMD
        cmdHwnd := WinExist("ahk_class ConsoleWindowClass ahk_id " cmdHwnd)
    }

    ; Стратегия 3: Ищем по PID процесса cmd.exe
    hwnd := WinExist("ahk_pid " pid)
    if (hwnd) {
        Log("Найдено окно по PID cmd.exe: " pid)
        try {
            WinActivate("ahk_id " hwnd)
            Log("Успешно переключено на окно сессии")
            return
        }
    }

    ; Стратегия 4: Ищем родительский процесс (Windows Terminal)
    try {
        result := ComObjGet("winmgmts:").ExecQuery("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" pid)
        for process in result {
            parentPid := process.ParentProcessId

            ; Проверяем, это Windows Terminal или conhost
            parentResult := ComObjGet("winmgmts:").ExecQuery("SELECT Name FROM Win32_Process WHERE ProcessId=" parentPid
            )
            for parentProc in parentResult {
                parentName := parentProc.Name
                Log("Родительский процесс: " parentName " (PID=" parentPid ")")

                ; Если родитель - conhost, ищем его родителя (Windows Terminal)
                if (parentName = "conhost.exe") {
                    grandParentResult := ComObjGet("winmgmts:").ExecQuery(
                        "SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" parentPid)
                    for grandParent in grandParentResult {
                        grandParentPid := grandParent.ParentProcessId
                        hwnd := WinExist("ahk_pid " grandParentPid)
                        if (hwnd) {
                            Log("Найдено окно Windows Terminal через conhost: PID=" grandParentPid)
                            try {
                                WinActivate("ahk_id " hwnd)
                                Log("Успешно переключено на окно Windows Terminal")
                                return
                            }
                        }
                    }
                }
            }

            hwnd := WinExist("ahk_pid " parentPid)
            if (hwnd) {
                Log("Найдено родительское окно: ParentPID=" parentPid)
                try {
                    WinActivate("ahk_id " hwnd)
                    Log("Успешно переключено на окно сессии")
                    return
                }
            }
        }
    }

    Log("Окно сессии не найдено", "WARN")
    MsgBox("Не удалось найти окно сессии", "Ошибка", "Icon!")
}

; === ПРОВЕРКА, ЯВЛЯЕТСЯ ЛИ ПРОЦЕСС ПОТОМКОМ ===
IsChildProcess(childPid, parentPid) {
    try {
        currentPid := childPid
        loop 10 {  ; Максимум 10 уровней вложенности
            result := ComObjGet("winmgmts:").ExecQuery("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" currentPid
            )
            for process in result {
                currentParentPid := process.ParentProcessId
                if (currentParentPid = parentPid) {
                    return true
                }
                currentPid := currentParentPid
                break
            }
        }
    }
    return false
}

; === ПЕРЕКЛЮЧЕНИЕ НА ВКЛАДКУ WINDOWS TERMINAL ===
SwitchToTerminalTab(terminalHwnd, targetFolderName, maxAttempts := 10) {
    Log("Поиск вкладки: " targetFolderName)

    currentTitle := WinGetTitle("ahk_id " terminalHwnd)
    startTitle := currentTitle

    ; Если уже на нужной вкладке
    if InStr(currentTitle, targetFolderName) {
        Log("Вкладка уже активна")
        return true
    }

    ; Перебираем вкладки
    loop maxAttempts {
        Send("^{Tab}")
        Sleep(250)

        newTitle := WinGetTitle("ahk_id " terminalHwnd)
        Log("Проверка вкладки " A_Index ": " newTitle)

        if InStr(newTitle, targetFolderName) {
            Log("Найдена нужная вкладка на попытке " A_Index)
            return true
        }

        ; Если вернулись к начальной вкладке, значит прошли полный круг
        if (newTitle = startTitle && A_Index > 1) {
            Log("Прошли все вкладки, целевая не найдена")
            return false
        }
    }

    Log("Не удалось найти вкладку за " maxAttempts " попыток")
    return false
}

; === ЗАКРЫТИЕ СЕССИИ ===
CloseSession(folderPath, pid) {
    global activeSessions, sessionSearchTimers

    Log("Запрос на закрытие сессии: PID=" pid ", Папка=" folderPath)

    ; Останавливаем таймер поиска session ID, если он ещё работает
    if sessionSearchTimers.Has(folderPath) {
        searchInfo := sessionSearchTimers[folderPath]
        SetTimer(searchInfo.timer, 0)
        sessionSearchTimers.Delete(folderPath)
        Log("Остановлен таймер поиска session ID")
    }

    ; Проверяем, существует ли сессия с таким folderPath
    if !activeSessions.Has(folderPath) {
        Log("Сессия не найдена в списке активных", "WARN")
        return
    }

    ; Проверяем, что PID совпадает (защита от race condition)
    sessionInfo := activeSessions[folderPath]
    if (sessionInfo.pid != pid) {
        Log("PID не совпадает: ожидался " sessionInfo.pid ", получен " pid, "WARN")
        return
    }

    ; Вызываем SessionEnd хук, если он настроен
    CallSessionEndHook(folderPath, sessionInfo.sessionId)

    ; Закрываем окно терминала
    try {
        ; Определяем, это Windows Terminal или CMD
        isWindowsTerminal := false
        terminalHwnd := 0

        ; Ищем окно Windows Terminal
        wtHwnd := WinExist("ahk_exe WindowsTerminal.exe")
        if (wtHwnd) {
            isWindowsTerminal := true
            terminalHwnd := wtHwnd
            Log("Найдено окно Windows Terminal: HWND=" terminalHwnd)
        }

        ; Если не Windows Terminal, ищем CMD
        if (!terminalHwnd) {
            ; Сначала пробуем найти окно по PID (это сработает для cmd.exe)
            terminalHwnd := WinExist("ahk_pid " pid)

            if (!terminalHwnd) {
                ; Если не найдено, ищем родительский процесс (cmd.exe)
                try {
                    result := ComObjGet("winmgmts:").ExecQuery(
                        "SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" pid)
                    for process in result {
                        parentPid := process.ParentProcessId
                        Log("Найден родительский процесс: PID=" parentPid)

                        ; Проверяем, это cmd.exe или conhost.exe
                        terminalHwnd := WinExist("ahk_pid " parentPid)
                        if (terminalHwnd) {
                            Log("Найдено окно терминала по родительскому PID: " parentPid)
                            break
                        }
                    }
                }
            }
        }

        if (terminalHwnd) {
            Log("Закрытие " (isWindowsTerminal ? "вкладки Windows Terminal" : "окна терминала") ": HWND=" terminalHwnd)

            ; Для Windows Terminal закрываем вкладку через Ctrl+Shift+W
            if (isWindowsTerminal) {
                Log("Закрытие вкладки Windows Terminal: PID=" pid)

                ; Активируем окно Windows Terminal
                WinActivate("ahk_id " terminalHwnd)
                Sleep(200)

                ; Получаем имя папки для поиска вкладки
                folderName := GetFolderName(folderPath)
                currentTitle := WinGetTitle("ahk_id " terminalHwnd)
                Log("Текущий заголовок: " currentTitle)

                ; Проверяем, активна ли нужная вкладка
                isTargetTabActive := InStr(currentTitle, folderName)

                if (!isTargetTabActive) {
                    Log("Переключение на вкладку: " folderName)

                    ; Используем новую функцию для переключения
                    switchSuccess := SwitchToTerminalTab(terminalHwnd, folderName, 10)

                    if (!switchSuccess) {
                        Log("Не удалось переключиться на вкладку, используем принудительное завершение", "WARN")
                        ; Завершаем процесс напрямую
                        try {
                            RunWait('taskkill /PID ' pid ' /T /F', , "Hide")
                            Log("Процесс завершён через taskkill")
                        } catch as err {
                            Log("Ошибка taskkill: " err.Message, "ERROR")
                        }
                        goto CleanupSession
                    }
                }

                ; Отправляем Ctrl+C для завершения процесса
                Log("Отправка Ctrl+C для завершения процесса")
                Send("^c")
                Sleep(500)

                ; Проверяем, завершился ли процесс
                processTerminated := false
                loop 10 {
                    if !ProcessExist(pid) {
                        Log("Процесс завершён после Ctrl+C")
                        processTerminated := true
                        break
                    }
                    Sleep(100)
                }

                ; Если процесс не завершился, используем taskkill
                if (!processTerminated) {
                    Log("Процесс не завершился, используем taskkill", "WARN")
                    try {
                        RunWait('taskkill /PID ' pid ' /T /F', , "Hide")
                        Sleep(300)
                        Log("Процесс завершён через taskkill")
                    } catch as err {
                        Log("Ошибка taskkill: " err.Message, "ERROR")
                    }
                }

                ; Закрываем вкладку через Ctrl+D (работает для вкладок с сообщением об ошибке)
                Log("Отправка Ctrl+D для закрытия вкладки")
                Send("^d")
                Sleep(200)
            } else {
                ; Для CMD используем старый метод
                ; Активируем окно
                WinActivate("ahk_id " terminalHwnd)
                Sleep(100)

                ; Отправляем Ctrl+C для прерывания Claude Code
                Send("^c")
                Log("Отправлен Ctrl+C для прерывания Claude Code")

                ; Ждём завершения процесса Claude Code (до 3 секунд)
                processTerminated := false
                loop 30 {
                    if !ProcessExist(pid) {
                        processTerminated := true
                        Log("Процесс cmd.exe завершён после Ctrl+C")
                        break
                    }
                    Sleep(100)
                }

                ; Для CMD отправляем exit
                Send("exit{Enter}")
                Sleep(500)

                ; Если окно всё ещё существует, закрываем принудительно
                if WinExist("ahk_id " terminalHwnd) {
                    Log("Окно не закрылось, принудительное закрытие")
                    WinClose("ahk_id " terminalHwnd)
                    Sleep(300)
                }
            }
        } else {
            Log("Окно терминала не найдено, закрытие процесса напрямую")
            ProcessClose(pid)
            Sleep(500)
        }

        ; Ждём завершения процесса
        loop 10 {
            if !ProcessExist(pid) {
                Log("Процесс успешно завершён")
                break
            }
            Sleep(100)
        }

        ; Если процесс всё ещё существует, убиваем принудительно
        if ProcessExist(pid) {
            Log("Принудительное завершение процесса", "WARN")
            ProcessClose(pid)
            Sleep(200)
        }
    } catch as err {
        Log("Ошибка при закрытии сессии: " err.Message, "ERROR")
    }

CleanupSession:
    ; Удаляем из списка (проверяем существование)
    if activeSessions.Has(folderPath) {
        activeSessions.Delete(folderPath)
        Log("Сессия удалена из списка активных")
    } else {
        Log("Сессия уже была удалена из списка", "WARN")
    }

    ; Обновляем отображение
    UpdateSessionsDisplay()
}

; === ЗАПУСК ПОИСКА SESSION ID С ТАЙМЕРОМ ===
StartSessionIdSearch(folderPath) {
    global sessionSearchTimers, CLAUDE_SESSIONS_DIR

    Log("Запуск поиска session ID для: " folderPath)

    ; Получаем список существующих файлов (чтобы не читать их повторно)
    knownFiles := Map()
    loop files, CLAUDE_SESSIONS_DIR "\*.json" {
        knownFiles[A_LoopFileName] := true
    }

    ; Создаём таймер
    timerFunc := () => SearchSessionIdTimer(folderPath)
    sessionSearchTimers[folderPath] := { timer: timerFunc, knownFiles: knownFiles, attempts: 0 }

    SetTimer(timerFunc, 1000)
}

; === ТАЙМЕР ПОИСКА SESSION ID ===
SearchSessionIdTimer(folderPath) {
    global sessionSearchTimers, activeSessions, CLAUDE_SESSIONS_DIR

    if !sessionSearchTimers.Has(folderPath) {
        return
    }

    searchInfo := sessionSearchTimers[folderPath]
    searchInfo.attempts++

    Log("Поиск session ID, попытка " searchInfo.attempts " для: " folderPath)

    ; Нормализуем путь для сравнения
    normalizedPath := StrReplace(folderPath, "/", "\")

    ; Проверяем новые файлы
    loop files, CLAUDE_SESSIONS_DIR "\*.json" {
        fileName := A_LoopFileName

        ; Пропускаем уже известные файлы
        if searchInfo.knownFiles.Has(fileName) {
            continue
        }

        ; Новый файл - читаем его
        Log("Найден новый файл сессии: " fileName)
        try {
            content := FileRead(A_LoopFileFullPath)

            ; Парсим JSON вручную (ищем cwd)
            if RegExMatch(content, '"cwd"\s*:\s*"([^"]+)"', &cwdMatch) {
                fileCwd := cwdMatch[1]

                ; Сравниваем пути
                if (fileCwd = normalizedPath) {
                    Log("Найден файл сессии для нужной папки!")

                    ; Извлекаем sessionId
                    if RegExMatch(content, '"sessionId"\s*:\s*"([^"]+)"', &sessionMatch) {
                        sessionId := sessionMatch[1]
                        Log("Session ID найден: " sessionId)

                        ; Обновляем информацию о сессии
                        if activeSessions.Has(folderPath) {
                            sessionInfo := activeSessions[folderPath]
                            sessionInfo.sessionId := sessionId
                            activeSessions[folderPath] := sessionInfo
                            Log("Session ID сохранён в activeSessions")
                        }

                        ; Останавливаем таймер
                        SetTimer(searchInfo.timer, 0)
                        sessionSearchTimers.Delete(folderPath)
                        Log("Поиск session ID завершён успешно")
                        return
                    }
                }
            }

            ; Добавляем файл в список известных
            searchInfo.knownFiles[fileName] := true
        } catch as err {
            Log("Ошибка чтения файла " fileName ": " err.Message, "ERROR")
        }
    }

    ; Проверяем таймаут (30 секунд = 30 попыток)
    if (searchInfo.attempts >= 30) {
        Log("Таймаут поиска session ID для: " folderPath, "WARN")
        SetTimer(searchInfo.timer, 0)
        sessionSearchTimers.Delete(folderPath)
    }
}

; === ВЫЗОВ SESSIONEND ХУКА ===
CallSessionEndHook(folderPath, sessionId) {
    global CLAUDE_SESSIONS_DIR

    ; Проверяем, есть ли sessionId
    if (sessionId = "") {
        Log("SessionEnd хук не вызван: sessionId не найден")
        return
    }

    ; Ищем JSON файл сессии
    sessionFile := ""
    loop files, CLAUDE_SESSIONS_DIR "\*.json" {
        try {
            content := FileRead(A_LoopFileFullPath, "UTF-8")
            if InStr(content, sessionId) {
                sessionFile := A_LoopFileFullPath
                break
            }
        }
    }

    if (sessionFile = "") {
        Log("SessionEnd хук не вызван: JSON файл сессии не найден")
        return
    }

    ; Проверяем, существует ли хук SessionEnd
    hookPath := A_ScriptDir "\..\.claude\settings.json"
    if !FileExist(hookPath) {
        Log("SessionEnd хук не настроен (нет settings.json)")
        return
    }

    try {
        ; Читаем настройки хука
        settingsContent := FileRead(hookPath, "UTF-8")
        if !InStr(settingsContent, "SessionEnd") {
            Log("SessionEnd хук не настроен в settings.json")
            return
        }

        ; Извлекаем команду хука
        if RegExMatch(settingsContent, '"SessionEnd"\s*:\s*"([^"]+)"', &hookMatch) {
            hookCommand := hookMatch[1]
            Log("Вызов SessionEnd хука: " hookCommand)

            ; Формируем JSON для передачи хуку
            hookInput := '{"transcriptPath":"' StrReplace(sessionFile, "\", "\\") '","sessionId":"' sessionId '"}'

            ; Вызываем хук в фоновом режиме
            Run('cmd /c echo ' hookInput ' | ' hookCommand, , "Hide")
            Log("SessionEnd хук вызван успешно")
        }
    } catch as err {
        Log("Ошибка вызова SessionEnd хука: " err.Message, "ERROR")
    }
}

; === ОБРАБОТЧИКИ TOOLTIP ===
OnMouseMove(wParam, lParam, msg, hwnd) {
    static PrevHwnd := 0

    ; Проверяем, активно ли окно
    try {
        ctrl := GuiCtrlFromHwnd(hwnd)
        if (ctrl && ctrl.Gui.Hwnd != WinExist("A")) {
            ToolTip()
            PrevHwnd := 0
            return
        }
    }

    if (hwnd == PrevHwnd)
        return
    PrevHwnd := hwnd

    try ctrl := GuiCtrlFromHwnd(hwnd)
    catch {
        ToolTip()
        return
    }

    if (!ctrl) {
        ToolTip()
        return
    }

    text := ""

    ; Определяем текст подсказки по типу и тексту контрола
    if (ctrl.Type = "Button") {
        if (ctrl.Text = "Сброс") {
            text :=
                "Удаляет сохранённую сессию для выбранной папки.`nПри следующем запуске откроется чистая сессия.`nИспользуйте для исправления ошибки 'No conversation found'."
        }
    } else if (ctrl.Type = "CheckBox") {
        if (InStr(ctrl.Text, "Загружать прошлую сессию")) {
            text := "Если выдаст ошибку, нажми кнопку 'Сброс'"
        }
    }

    if (text != "") {
        ToolTip(text)
    } else {
        ToolTip()
    }
}

OnWindowDeactivate(wParam, lParam, msg, hwnd) {
    ; Если окно потеряло активность, скрываем tooltip
    if ((wParam & 0xFFFF) = 0) {
        ToolTip()
    }
}
