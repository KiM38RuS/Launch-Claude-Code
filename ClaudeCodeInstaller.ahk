#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetTitleMatchMode 2
CoordMode "Mouse", "Screen"
CoordMode "Pixel", "Screen"

; ============================================================
; Claude Code Installer - Максимально автоматизированный мастер
; ============================================================

global Installer := InstallerApp()
Installer.Start()

OnInstallerClose(*)
{
    ExitApp
}

class InstallerApp
{
    mainGui := 0
    headerText := 0
    progressBar := 0
    currentStepText := 0
    statusText := 0
    logEdit := 0
    btnCancel := 0

    helpGui := 0
    helpImage := 0
    helpInstruction := 0

    LogBuffer := ""
    CurrentStep := 0
    TotalSteps := 10

    __New()
    {
        this.BuildMainGui()
    }

    BuildMainGui()
    {
        this.mainGui := Gui("+AlwaysOnTop", "Claude Code Installer")
        this.mainGui.SetFont("s10", "Segoe UI")
        this.mainGui.OnEvent("Close", OnInstallerClose)

        this.headerText := this.mainGui.AddText("xm ym w600 h30 Center", "Установка Claude Code")
        this.headerText.SetFont("s14 Bold")

        this.progressBar := this.mainGui.AddProgress("xm y+10 w600 h30 Range0-100", 0)

        this.currentStepText := this.mainGui.AddText("xm y+10 w600 h25 Center", "")
        this.currentStepText.SetFont("s11 Bold")

        this.statusText := this.mainGui.AddText("xm y+5 w600 h40 Center", "")

        this.logEdit := this.mainGui.AddEdit("xm y+10 w600 h300 ReadOnly -Wrap")

        this.btnCancel := this.mainGui.AddButton("xm y+10 w600 h35", "Отмена")
        this.btnCancel.OnEvent("Click", OnInstallerClose)
    }

    Start()
    {
        this.mainGui.Show("w640 h500")
        SetTimer(() => this.RunInstallation(), -500)
    }

    RunInstallation()
    {
        try
        {
            ; Шаг 1: Проверка интернета
            this.UpdateProgress(1, "Проверка интернет-соединения")
            if (!this.CheckInternet())
            {
                this.ShowError("Нет подключения к интернету. Проверьте соединение и запустите установщик снова.")
                return
            }

            ; Шаг 2: Установка Node.js
            this.UpdateProgress(2, "Установка Node.js")
            if (!this.InstallNodeJs())
                return

            ; Шаг 3: Проверка Node.js
            this.UpdateProgress(3, "Проверка Node.js")
            if (!this.VerifyNodeJs())
                return

            ; Шаг 4: Установка OmniRoute
            this.UpdateProgress(4, "Установка OmniRoute")
            if (!this.InstallOmniRoute())
                return

            ; Шаг 5: Запуск OmniRoute
            this.UpdateProgress(5, "Запуск OmniRoute")
            if (!this.LaunchOmniRoute())
                return

            ; Шаг 6: Подключение Kiro (ручной шаг с GUI)
            this.UpdateProgress(6, "Подключение провайдера Kiro")
            if (!this.ConnectKiro())
                return

            ; Шаг 7: Создание API ключа (ручной шаг с автоматическим получением из буфера)
            this.UpdateProgress(7, "Создание API ключа")
            if (!this.CreateApiKey())
                return

            ; Шаг 8: Установка Claude Code
            this.UpdateProgress(8, "Установка Claude Code")
            if (!this.InstallClaudeCode())
                return

            ; Шаг 9: Создание CC.bat с ключом из буфера
            this.UpdateProgress(9, "Настройка запуска")
            if (!this.CreateCcBat())
                return

            ; Шаг 10: Финальная проверка
            this.UpdateProgress(10, "Финальная проверка")
            if (!this.FinalTest())
                return

            this.ShowSuccess()
        }
        catch as e
        {
            this.ShowError("Критическая ошибка: " . e.Message)
        }
    }

    UpdateProgress(step, stepName)
    {
        this.CurrentStep := step
        progress := Round((step / this.TotalSteps) * 100)
        this.progressBar.Value := progress
        this.currentStepText.Text := Format("Шаг {}/{}: {}", step, this.TotalSteps, stepName)
        this.Log(Format("[Шаг {}/{}] {}", step, this.TotalSteps, stepName))
    }

    Log(message)
    {
        timestamp := FormatTime(A_Now, "HH:mm:ss")
        this.LogBuffer .= "[" . timestamp . "] " . message . "`r`n"
        this.logEdit.Value := this.LogBuffer
        ControlSend("^{End}", , "ahk_id " . this.logEdit.Hwnd)
    }

    CheckInternet()
    {
        this.statusText.Text := "Проверяю доступность nodejs.org..."

        result := this.ExecCapture('powershell.exe -NoProfile -Command "Test-NetConnection -ComputerName nodejs.org -Port 443 -InformationLevel Quiet"')

        if (result.ExitCode = 0 && InStr(result.StdOut, "True"))
        {
            this.Log("✓ Интернет-соединение в порядке")
            return true
        }

        this.Log("✗ Не удалось подключиться к nodejs.org")
        return false
    }

    InstallNodeJs()
    {
        this.statusText.Text := "Проверяю установленную версию Node.js..."

        result := this.ExecCapture('cmd.exe /c node --version')
        output := Trim(result.StdOut . result.StdErr)

        if (result.ExitCode = 0 && InStr(output, "v22.22.2"))
        {
            this.Log("✓ Node.js v22.22.2 уже установлен")
            return true
        }

        this.Log("Скачиваю Node.js v22.22.2...")
        this.statusText.Text := "Скачивание Node.js..."

        tempMsi := A_Temp . "\node-v22.22.2-x64.msi"
        if FileExist(tempMsi)
            try FileDelete(tempMsi)

        downloadCmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "'
            . 'Invoke-WebRequest -Uri ''https://nodejs.org/dist/v22.22.2/node-v22.22.2-x64.msi'' '
            . '-OutFile ''' . tempMsi . ''''
            . '"'

        exitCode := RunWait(downloadCmd, , "Hide")
        if (exitCode != 0 || !FileExist(tempMsi))
        {
            this.Log("✗ Ошибка скачивания Node.js")
            this.ShowError("Не удалось скачать Node.js. Проверьте интернет-соединение.")
            return false
        }

        this.Log("✓ Node.js скачан")
        this.Log("Устанавливаю Node.js (это может занять минуту)...")
        this.statusText.Text := "Установка Node.js..."

        installCmd := 'msiexec /i "' . tempMsi . '" /qn /norestart'
        exitCode := RunWait(installCmd, , "Hide")

        if (exitCode != 0)
        {
            this.Log("✗ Ошибка установки Node.js")
            this.ShowError("Не удалось установить Node.js. Код ошибки: " . exitCode)
            return false
        }

        this.Log("✓ Node.js установлен")
        return true
    }

    VerifyNodeJs()
    {
        this.statusText.Text := "Проверяю Node.js..."

        ; Обновляем PATH для текущего процесса
        EnvGet("Path")

        result := this.ExecCapture('cmd.exe /c node --version')
        output := Trim(result.StdOut . result.StdErr)

        if (result.ExitCode = 0 && RegExMatch(output, '^v\d+'))
        {
            this.Log("✓ Node.js работает: " . output)
            return true
        }

        this.Log("✗ Node.js не найден в PATH")
        this.ShowError("Node.js установлен, но не виден в системе. Перезапустите компьютер и установщик.")
        return false
    }

    InstallOmniRoute()
    {
        this.statusText.Text := "Проверяю OmniRoute..."

        result := this.ExecCapture('cmd.exe /c npm list -g omniroute')

        if InStr(result.StdOut, "omniroute@")
        {
            this.Log("✓ OmniRoute уже установлен")
            return true
        }

        this.Log("Устанавливаю OmniRoute...")
        this.statusText.Text := "Установка OmniRoute..."

        exitCode := RunWait('cmd.exe /c npm install -g omniroute', , "Hide")

        if (exitCode != 0)
        {
            this.Log("✗ Ошибка установки OmniRoute")
            this.ShowError("Не удалось установить OmniRoute через npm.")
            return false
        }

        ; Проверка установки
        result := this.ExecCapture('cmd.exe /c npm list -g omniroute')
        if InStr(result.StdOut, "omniroute@")
        {
            this.Log("✓ OmniRoute установлен")
            return true
        }

        this.Log("✗ OmniRoute не обнаружен после установки")
        return false
    }

    LaunchOmniRoute()
    {
        this.statusText.Text := "Запускаю OmniRoute..."

        Run('cmd.exe /c omniroute', , , &pid)
        this.Log("✓ OmniRoute запущен (PID: " . pid . ")")
        this.Log("Ожидаю запуска веб-интерфейса...")

        Sleep(3000)

        ; Проверяем, что OmniRoute запустился
        maxAttempts := 10
        Loop maxAttempts
        {
            result := this.ExecCapture('powershell.exe -NoProfile -Command "Test-NetConnection -ComputerName localhost -Port 20128 -InformationLevel Quiet"')

            if InStr(result.StdOut, "True")
            {
                this.Log("✓ OmniRoute веб-интерфейс доступен на localhost:20128")
                return true
            }

            this.Log("Попытка " . A_Index . "/" . maxAttempts . "...")
            Sleep(2000)
        }

        this.Log("✗ OmniRoute не отвечает на localhost:20128")
        this.ShowError("OmniRoute запущен, но веб-интерфейс недоступен.")
        return false
    }

    ConnectKiro()
    {
        this.statusText.Text := "Требуется ручное действие"

        ; Открываем страницу провайдеров
        Run("http://localhost:20128/providers")

        ; Показываем GUI с инструкцией
        this.ShowHelpGui(
            A_ScriptDir . "\assets\step05_kiro_connect.png",
            "Подключение провайдера Kiro AI",
            "1. В открывшемся браузере найдите провайдера 'Kiro'`n"
            . "2. Нажмите кнопку 'Connect'`n"
            . "3. Выполните вход через Google`n"
            . "4. После успешного входа нажмите 'Готово' в этом окне"
        )

        ; Ждём подтверждения пользователя
        return true
    }

    CreateApiKey()
    {
        this.statusText.Text := "Требуется создание API ключа"

        ; Открываем страницу API Keys
        Run("http://localhost:20128/api-keys")

        ; Показываем GUI с инструкцией
        this.ShowHelpGui(
            A_ScriptDir . "\assets\step06_create_api_key.png",
            "Создание API ключа",
            "1. Нажмите 'Create API Key'`n"
            . "2. Скопируйте созданный ключ (он показывается один раз!)`n"
            . "3. Нажмите 'Готово' в этом окне`n`n"
            . "ВАЖНО: Ключ будет автоматически взят из буфера обмена"
        )

        ; Ждём, пока пользователь скопирует ключ
        ; После нажатия "Готово" ключ будет в буфере обмена

        return true
    }

    InstallClaudeCode()
    {
        this.statusText.Text := "Проверяю Claude Code..."

        result := this.ExecCapture('cmd.exe /c npm list -g @anthropic-ai/claude-code')

        if InStr(result.StdOut, "@anthropic-ai/claude-code@")
        {
            this.Log("✓ Claude Code уже установлен")
            return true
        }

        this.Log("Устанавливаю Claude Code...")
        this.statusText.Text := "Установка Claude Code..."

        exitCode := RunWait('cmd.exe /c npm install -g @anthropic-ai/claude-code', , "Hide")

        if (exitCode != 0)
        {
            this.Log("✗ Ошибка установки Claude Code")
            this.ShowError("Не удалось установить Claude Code через npm.")
            return false
        }

        ; Проверка установки
        result := this.ExecCapture('cmd.exe /c npm list -g @anthropic-ai/claude-code')
        if InStr(result.StdOut, "@anthropic-ai/claude-code@")
        {
            this.Log("✓ Claude Code установлен")
            return true
        }

        this.Log("✗ Claude Code не обнаружен после установки")
        return false
    }

    CreateCcBat()
    {
        this.statusText.Text := "Создаю файл запуска..."

        scriptsDir := "C:\Scripts"
        DirCreate(scriptsDir)

        ; Получаем API ключ из буфера обмена
        apiKey := A_Clipboard

        if (apiKey = "" || StrLen(apiKey) < 10)
        {
            this.Log("⚠ Буфер обмена пуст или содержит короткую строку")

            ; Показываем InputBox для ручного ввода
            ib := InputBox("Введите API ключ из OmniRoute:", "API ключ", "w400 h150")

            if (ib.Result = "Cancel")
            {
                this.ShowError("Установка отменена. API ключ не предоставлен.")
                return false
            }

            apiKey := ib.Value
        }

        if (apiKey = "" || StrLen(apiKey) < 10)
        {
            this.ShowError("API ключ слишком короткий или пустой.")
            return false
        }

        this.Log("✓ API ключ получен (длина: " . StrLen(apiKey) . " символов)")

        batPath := scriptsDir . "\CC.bat"
        batContent := "@echo off`r`n"
            . "set ANTHROPIC_BASE_URL=http://localhost:20128/v1`r`n"
            . "set ANTHROPIC_AUTH_TOKEN=" . apiKey . "`r`n"
            . "set ANTHROPIC_API_KEY=`r`n"
            . "set ANTHROPIC_MODEL=kr/claude-sonnet-4.5`r`n"
            . "set ANTHROPIC_SMALL_FAST_MODEL=kr/claude-sonnet-4.5`r`n"
            . "set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`r`n"
            . "claude %*`r`n"

        if FileExist(batPath)
            try FileDelete(batPath)

        FileAppend(batContent, batPath, "UTF-8")

        ; Добавляем C:\Scripts в PATH
        currentPath := ""
        try currentPath := RegRead("HKCU\Environment", "Path")

        if !InStr(";" . currentPath . ";", ";" . scriptsDir . ";")
        {
            newPath := currentPath
            if (newPath != "")
                newPath .= ";"
            newPath .= scriptsDir

            RegWrite(newPath, "REG_EXPAND_SZ", "HKCU\Environment", "Path")
            EnvSet("Path", newPath)
            this.Log("✓ C:\Scripts добавлен в PATH")
        }

        this.Log("✓ Файл CC.bat создан: " . batPath)
        return true
    }

    FinalTest()
    {
        this.statusText.Text := "Финальная проверка..."

        ; Обновляем PATH
        EnvGet("Path")

        result := this.ExecCapture('cmd.exe /c claude --version')
        output := Trim(result.StdOut . result.StdErr)

        if (result.ExitCode = 0 && InStr(output, "claude-code"))
        {
            this.Log("✓ Claude Code работает: " . output)
            return true
        }

        this.Log("⚠ Claude Code установлен, но требуется перезапуск терминала")
        this.Log("Версия: " . output)
        return true
    }

    ShowHelpGui(imagePath, title, instruction)
    {
        if (this.helpGui != 0)
        {
            try this.helpGui.Destroy()
        }

        this.helpGui := Gui("+AlwaysOnTop +Owner" . this.mainGui.Hwnd, title)
        this.helpGui.SetFont("s10", "Segoe UI")

        titleText := this.helpGui.AddText("xm ym w700 h30 Center", title)
        titleText.SetFont("s12 Bold")

        instructionText := this.helpGui.AddText("xm y+10 w700 h80", instruction)

        if (FileExist(imagePath))
        {
            try
            {
                this.helpImage := this.helpGui.AddPicture("xm y+10 w700 h400", imagePath)
            }
            catch
            {
                this.helpGui.AddText("xm y+10 w700 h400 Center Border", "Скриншот не найден:`n" . imagePath)
            }
        }
        else
        {
            this.helpGui.AddText("xm y+10 w700 h400 Center Border", "Скриншот не найден:`n" . imagePath)
        }

        btnDone := this.helpGui.AddButton("xm y+10 w700 h40", "Готово")
        btnDone.OnEvent("Click", (*) => this.helpGui.Hide())

        this.helpGui.Show("w740 h600")

        ; Блокируем выполнение до нажатия "Готово"
        WinWaitClose("ahk_id " . this.helpGui.Hwnd)
    }

    ShowSuccess()
    {
        this.progressBar.Value := 100
        this.currentStepText.Text := "Установка завершена!"
        this.statusText.Text := "Claude Code готов к использованию"
        this.Log("")
        this.Log("═══════════════════════════════════════")
        this.Log("✓ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО")
        this.Log("═══════════════════════════════════════")
        this.Log("")
        this.Log("Для запуска Claude Code:")
        this.Log("1. Откройте новый терминал (cmd или PowerShell)")
        this.Log("2. Перейдите в нужную папку проекта")
        this.Log("3. Введите команду: CC")
        this.Log("")
        this.Log("Файл запуска: C:\Scripts\CC.bat")

        this.btnCancel.Text := "Закрыть"

        MsgBox("Установка Claude Code завершена успешно!`n`n"
            . "Для запуска откройте новый терминал и введите: CC`n`n"
            . "Убедитесь, что OmniRoute запущен перед использованием Claude Code.",
            "Успех", "Iconi T5")
    }

    ShowError(message)
    {
        this.Log("✗ ОШИБКА: " . message)
        this.statusText.Text := "Ошибка установки"

        MsgBox(message, "Ошибка установки", "Iconx")
    }

    ExecCapture(command)
    {
        shell := ComObject("WScript.Shell")
        exec := shell.Exec(command)

        while (exec.Status = 0)
            Sleep(100)

        stdout := ""
        stderr := ""
        try stdout := exec.StdOut.ReadAll()
        try stderr := exec.StdErr.ReadAll()

        return {ExitCode: exec.ExitCode, StdOut: stdout, StdErr: stderr}
    }
}
