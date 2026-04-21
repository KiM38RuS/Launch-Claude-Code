; ============================================
; Claude Code Launcher with Omniroute
; ============================================

#Requires AutoHotkey v2+
#SingleInstance Force
#NoTrayIcon

;@Ahk2Exe-SetName Claude Code Launcher
;@Ahk2Exe-SetDescription Лаунчер для Claude Code через Omniroute
;@Ahk2Exe-SetVersion 1.3.2

;@Ahk2Exe-IgnoreBegin
TraySetIcon(A_ScriptDir "\Assets\LCC.ico")
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
F5::Reload
#HotIf

; === ВЕРСИЯ ===
SCRIPT_VERSION := "v1.3.2"

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
global isShuttingDown := false
global sessionBtnCounter := 0  ; Счётчик для уникальных имён кнопок
global wmiSink := ""  ; WMI Event Sink для отслеживания процессов
global lastSessionsCount := 0  ; Последнее количество сессий для отслеживания изменений
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

    ; Регистрируем обработчик завершения работы
    OnExit(OnShutdown)

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
        Loop Parse, content, "`n", "`r" {
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
    Loop 10 {
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

    ; Читаем все JSON файлы сессий
    Loop Files, CLAUDE_SESSIONS_DIR "\*.json" {
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
                            activeSessions[folderPath] := {pid: pid, sessionId: sessionId}
                            Log("Восстановлена сессия: Папка=" folderPath ", PID=" pid ", SessionID=" sessionId)
                        } else {
                            Log("Процесс не существует для сессии: PID=" pid ", Папка=" folderPath ", SessionID=" sessionId)
                        }
                    }
                }
            }
        } catch as err {
            Log("Ошибка чтения файла " A_LoopFileFullPath ": " err.Message, "ERROR")
        }
    }

    Log("Восстановлено сессий: " activeSessions.Count)
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
    Loop MAX_HISTORY {
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

    mainGui := Gui("", "Claude Code Launcher " SCRIPT_VERSION)
    mainGui.SetFont("s10")

    ; Текст
    mainGui.Add("Text", "x10 y10", "Выберите папку для запуска Claude Code:")

    ; ComboBox с историей
    folderCombo := mainGui.Add("ComboBox", "x10 y35 w400 vFolderPath")
    if (historyList.Length > 0) {
        for folder in historyList {
            folderCombo.Add([folder])
        }
        folderCombo.Choose(1)
    }

    ; Обработчик изменения текста в ComboBox (с debounce)
    folderCombo.OnEvent("Change", (*) => OnFolderPathChange(folderCombo))

    ; Кнопка "Обзор"
    browseBtn := mainGui.Add("Button", "x+m yp-1 w80 h26", "Обзор...")
    browseBtn.OnEvent("Click", (*) => BrowseFolder(mainGui, folderCombo))

    ; Текстовое поле для статуса
    statusText := mainGui.Add("Text", "x10 y70 w490 h20 +Center", "")
    statusText.SetFont("s9 bold")

    ; Текстовое поле для статуса
    statusText := mainGui.Add("Text", "x10 y70 w490 h20 +Center", "")
    statusText.SetFont("s9 bold")

    ; Чекбокс для выбора режима запуска
    isWin11 := IsWindows11()
    useNewTabCheckbox := mainGui.Add("Checkbox", "x10 y100 vUseNewTab", "Запускать в новой вкладке (для Windows 11)")
    useNewTabCheckbox.Value := USE_NEW_TAB
    useNewTabCheckbox.OnEvent("Click", (*) => IniWrite(useNewTabCheckbox.Value ? "1" : "0", CONFIG_FILE, "Settings", "UseNewTab"))

    ; Делаем чекбокс неактивным в Windows 10
    if (!isWin11) {
        useNewTabCheckbox.Enabled := false
    }

    ; Чекбокс для загрузки прошлой сессии
    loadSessionCheckbox := mainGui.Add("Checkbox", "x10 y120 vLoadSession", "Загружать прошлую сессию")
    loadSessionCheckbox.Value := IniRead(CONFIG_FILE, "Settings", "LoadSession", "1") = "1"
    loadSessionCheckbox.OnEvent("Click", (*) => IniWrite(loadSessionCheckbox.Value ? "1" : "0", CONFIG_FILE, "Settings", "LoadSession"))

    ; Чекбокс для режима пропуска разрешений
    skipPermissionsCheckbox := mainGui.Add("Checkbox", "x10 y140 vSkipPermissions", "Запустить в режиме пропуска разрешений")
    ; Загружаем сохранённое состояние
    skipPermissionsCheckbox.Value := IniRead(CONFIG_FILE, "Settings", "SkipPermissions", "0") = "1"
    skipPermissionsCheckbox.OnEvent("Click", (*) => OnSkipPermissionsClick(skipPermissionsCheckbox, mainGui))

    ; Кнопки Сброс, Запустить и Закрыть
    resetBtn := mainGui.Add("Button", "x10 y170 w80 h30", "Сброс")
    resetBtn.OnEvent("Click", (*) => ResetSession(folderCombo, statusText))

    launchBtn := mainGui.Add("Button", "x330 y170 w80 h30 Default", "Запустить")
    launchBtn.OnEvent("Click", (*) => OnLaunchClick(mainGui, folderCombo, launchBtn, cancelBtn, statusText))

    cancelBtn := mainGui.Add("Button", "x+m y170 w80 h30", "Закрыть")
    cancelBtn.OnEvent("Click", (*) => ExitApp())

    ; Контейнер для активных сессий
    mainGui.Add("Text", "x10 y210 w490 h1 0x10")  ; Разделитель
    mainGui.Add("Text", "x10 y221", "Активные сессии:")
    sessionsContainer := mainGui.Add("Text", "x10 y226 w490 h20", "")

    ; Загружаем сохранённую позицию окна
    savedX := IniRead(CONFIG_FILE, "Window", "X", "")
    savedY := IniRead(CONFIG_FILE, "Window", "Y", "")

    if (savedX != "" && savedY != "" && IsInteger(savedX) && IsInteger(savedY)) {
        mainGui.Show("x" savedX " y" savedY " w510 h250")
        Log("Окно показано в сохранённой позиции: X=" savedX ", Y=" savedY)
    } else {
        mainGui.Show("w510 h250")
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

; === СОХРАНЕНИЕ ПОЗИЦИИ ОКНА ===
SaveWindowPosition() {
    global mainGui, CONFIG_FILE

    try {
        mainGui.GetPos(&x, &y)
        IniWrite(x, CONFIG_FILE, "Window", "X")
        IniWrite(y, CONFIG_FILE, "Window", "Y")
        Log("Позиция окна сохранена: X=" x ", Y=" y)
    } catch as err {
        Log("Ошибка сохранения позиции окна: " err.Message, "ERROR")
    }
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
    Loop Files, CLAUDE_SESSIONS_DIR "\*.json" {
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
        confirmGui.Add("Text", "x10 y10 w300", "Удалить сохранённую сессию для этой папки?`n`nПри следующем запуске откроется чистая сессия.")

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
    selectedPath := DirSelect("*" startPath, 3, "Выберите папку для Claude Code")
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
    Loop Files, CLAUDE_SESSIONS_DIR "\*.json" {
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

    Loop {
        ; Проверяем таймаут
        if ((A_TickCount - startTime) > (TIMEOUT_SECONDS * 1000)) {
            Log("Таймаут ожидания Omniroute (" TIMEOUT_SECONDS " сек)", "ERROR")
            statusText.Value := "Таймаут ожидания Omniroute!"
            statusText.SetFont("cRed")
            MsgBox("Таймаут ожидания запуска Omniroute (" TIMEOUT_SECONDS " сек).`nПроверьте, что Omniroute установлен и работает корректно.", "Ошибка", "Icon!")
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
    ; Метод 1: Реальная проверка доступности сервера через HTTP-запрос
    /* try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.SetTimeouts(1000, 1000, 2000, 2000)  ; Короткие таймауты
        http.Open("GET", "http://localhost:20128/health", false)
        http.Send()

        ; Если получили ответ (любой код), сервер работает
        if (http.Status >= 200 && http.Status < 600) {
            return true
        }
    } catch {
        ; Если запрос не прошёл, пробуем другие методы
    } */

    ; Метод 2: Проверяем процессы node.exe на наличие omniroute в командной строке
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

    ; Получаем значение чекбокса из GUI (если он существует)
    useNewTab := USE_NEW_TAB
    try {
        useNewTab := guiObj["UseNewTab"].Value
    } catch {
        useNewTab := false
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

    Log("Режим запуска: " (useNewTab ? "новая вкладка Windows Terminal" : "новое окно cmd"))

    try {
        if (useNewTab) {
            Run('wt.exe -w 0 nt -d "' selectedFolder '" cmd /k "cc' resumeCmd permissionsFlag '"', , , &cmdPID)
        } else {
            Run('cmd.exe /k "cd /d "' selectedFolder '" && cc' resumeCmd permissionsFlag '"', , , &cmdPID)
        }

        Log("Claude Code запущен с PID: " cmdPID)

        ; Регистрируем сессию с пустым sessionId (будет найден позже)
        activeSessions[selectedFolder] := {pid: cmdPID, sessionId: ""}
        Log("Сессия зарегистрирована: PID=" cmdPID)

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

    Loop Files, CLAUDE_SESSIONS_DIR "\*.json" {
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
        wmi.ExecNotificationQueryAsync(wmiSink, "SELECT * FROM __InstanceDeletionEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Process'")
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
    global activeSessions, lastSessionsCount

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
    yPos := 216

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
    frameY := winY - NumGet(rect, 4, "Int")
    frameHeight := NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int") - winH

    ; Вычисляем новую высоту
    newHeight := 246 + (activeSessions.Count * 35) + 10
    heightDiff := newHeight - currentHeight

    ; Получаем размер рабочей области экрана (без панели задач)
    MonitorGetWorkArea(, , , , &workAreaBottom)

    ; Проверяем, было ли окно вплотную к панели задач (с учётом рамки и допуском 10 пикселей)
    currentBottomEdge := currentY + currentHeight + frameHeight
    wasAtBottom := Abs(workAreaBottom - currentBottomEdge) <= 10

    Log("Расчёт позиции: currentY=" currentY ", currentHeight=" currentHeight ", newHeight=" newHeight)
    Log("Рамка окна: frameY=" frameY ", frameHeight=" frameHeight)
    Log("workAreaBottom=" workAreaBottom ", currentBottomEdge=" currentBottomEdge ", wasAtBottom=" wasAtBottom)

    ; Если окно было вплотную к панели задач, позиционируем его вплотную после изменения
    if (wasAtBottom) {
        newY := workAreaBottom - newHeight - frameHeight
        ; Проверяем, чтобы окно не вышло за верхнюю границу экрана
        if (newY < 0) {
            newY := 0
        }
        Log("Окно было вплотную к панели задач, позиционирование: Y " currentY " -> " newY)
        mainGui.Move(currentX, newY, 530, newHeight)
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
            mainGui.Move(currentX, newY, 530, newHeight)
        } else {
            Log("Изменение размера окна на высоту: " newHeight " (сдвиг не требуется)")
            mainGui.Move(, , 530, newHeight)
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
    sessionBtn := mainGui.Add("Button", "x10 y" yPos " w400 h30 vSessionBtn_" counter, folderName)

    ; Создаём локальные копии для замыкания
    localPath := folderPath
    localPid := pid

    sessionBtn.OnEvent("Click", (*) => ActivateSession(localPath, localPid))

    ; Добавляем обработчик правой кнопки мыши для открытия папки
    sessionBtn.OnEvent("ContextMenu", (*) => OpenFolder(localPath))

    ; Кнопка закрытия
    closeBtn := mainGui.Add("Button", "x+m yp w30 h30 vCloseBtn_" counter, "✖")
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
    Log("Попытка переключения на сессию: PID=" pid ", Папка=" folderPath)

    ; Сначала пробуем найти окно по PID (для CMD процессов)
    hwnd := WinExist("ahk_pid " pid)

    if (!hwnd) {
        ; Если не найдено, ищем родительское окно CMD
        ; (для случаев, когда PID - это node.exe)
        try {
            result := ComObjGet("winmgmts:").ExecQuery("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" pid)
            for process in result {
                parentPid := process.ParentProcessId
                hwnd := WinExist("ahk_pid " parentPid)
                if (hwnd) {
                    Log("Найдено родительское окно: ParentPID=" parentPid)
                    break
                }
            }
        }
    }

    if (hwnd) {
        try {
            WinActivate("ahk_id " hwnd)
            Log("Успешно переключено на окно сессии")
        } catch as err {
            Log("Ошибка активации окна: " err.Message, "ERROR")
            MsgBox("Не удалось переключиться на окно сессии", "Ошибка", "Icon!")
        }
    } else {
        Log("Окно сессии не найдено", "WARN")
        MsgBox("Не удалось найти окно сессии", "Ошибка", "Icon!")
    }
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

    ; Закрываем окно (просто закрываем, без Ctrl+C, чтобы JSON-файл остался)
    try {
        ; Сначала пробуем найти окно по PID (для CMD процессов)
        hwnd := WinExist("ahk_pid " pid)

        if (!hwnd) {
            ; Если не найдено, ищем родительское окно CMD
            ; (для случаев, когда PID - это node.exe)
            try {
                result := ComObjGet("winmgmts:").ExecQuery("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" pid)
                for process in result {
                    parentPid := process.ParentProcessId
                    hwnd := WinExist("ahk_pid " parentPid)
                    if (hwnd) {
                        Log("Найдено родительское окно для закрытия: ParentPID=" parentPid)
                        break
                    }
                }
            }
        }

        if hwnd {
            Log("Закрытие окна сессии")
            WinClose("ahk_id " hwnd)
            Sleep(500)
        } else {
            Log("Окно не найдено, закрытие процесса")
            ProcessClose(pid)
            Sleep(500)
        }

        ; Ждём завершения процесса
        Loop 10 {
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
    Loop Files, CLAUDE_SESSIONS_DIR "\*.json" {
        knownFiles[A_LoopFileName] := true
    }

    ; Создаём таймер
    timerFunc := () => SearchSessionIdTimer(folderPath)
    sessionSearchTimers[folderPath] := {timer: timerFunc, knownFiles: knownFiles, attempts: 0}

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
    Loop Files, CLAUDE_SESSIONS_DIR "\*.json" {
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
    Loop Files, CLAUDE_SESSIONS_DIR "\*.json" {
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

; === ОБРАБОТЧИК ЗАВЕРШЕНИЯ РАБОТЫ ===
OnShutdown(ExitReason, ExitCode) {
    ; Обработчик больше не нужен, так как сессии сохраняются автоматически в Claude
    return
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
            text := "Удаляет сохранённую сессию для выбранной папки.`nПри следующем запуске откроется чистая сессия.`nИспользуйте для исправления ошибки 'No conversation found'."
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
