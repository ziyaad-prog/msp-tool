#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end GUI test for MSP Tool, driven through Windows UI Automation.

.DESCRIPTION
    Opens the real WPF GUI (via gui-test-host.ps1) with harmless fake tools and checks: live output,
    a responsive window while tools run, Read-Host / Read-Host -AsSecureString / Get-Credential shown as
    dialogs, Stop, confirm-on-close, logging to the .log file, and search filtering.
    Uses UI Automation only (no simulated keystrokes or mouse). A window appears for ~30 seconds.
    Exits with the number of failed checks.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MspGui.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace MspTest -Name Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);'
$logFile = Join-Path ([IO.Path]::GetTempPath()) "msptool-gui-test-$PID.log"
$combinedFile = Join-Path ([IO.Path]::GetTempPath()) "msptool-gui-combined-$PID.txt"
Remove-Item $logFile -ErrorAction SilentlyContinue
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$results = [System.Collections.Generic.List[string]]::new()
function Check([bool]$ok, [string]$name) { $results.Add($(if ($ok) { "[PASS] $name" } else { "[FAIL] $name" })) }

function Find-First($root, $property, $value, [int]$timeoutMs = 8000) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($property, $value)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do { $el = $root.FindFirst($TS::Descendants, $cond); if ($el) { return $el }; Start-Sleep -Milliseconds 150 } while ($sw.ElapsedMilliseconds -lt $timeoutMs)
    return $null
}
function Find-ById($root, [string]$id, [int]$timeoutMs = 8000) { Find-First $root $AE::AutomationIdProperty $id $timeoutMs }
function Find-ByName($root, [string]$name, [int]$timeoutMs = 8000) { Find-First $root $AE::NameProperty $name $timeoutMs }
function Find-Window([string]$title, [int]$procId, [int]$timeoutMs = 15000) {
    $cond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $title)),
        (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $procId)))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do { $w = $AE::RootElement.FindFirst($TS::Descendants, $cond); if ($w) { return $w }; Start-Sleep -Milliseconds 200 } while ($sw.ElapsedMilliseconds -lt $timeoutMs)
    return $null
}
function Invoke-El($el) { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Toggle-El($el) { $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle() }
function Set-Value($el, [string]$v) { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($v) }
function Get-Value($el) { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
function Get-Log { Get-Value (Find-ById $main 'LogBox') }
function Get-Count([string]$text) { ([regex]::Matches((Get-Log), [regex]::Escape($text))).Count }
# Wait until $text appears more than $after times in the on-screen log
function Wait-Log([string]$text, [int]$after = 0, [int]$timeoutMs = 20000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do { if ((Get-Count $text) -gt $after) { return $true }; Start-Sleep -Milliseconds 200 } while ($sw.ElapsedMilliseconds -lt $timeoutMs)
    return $false
}
function Set-Tool([string]$name, [bool]$checked) {
    $el = Find-ByName $main $name
    $state = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
    if (($state -eq 'On') -ne $checked) { Toggle-El $el }
}
function Test-AnyOnScreen([string]$name) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)
    @($main.FindAll($TS::Descendants, $cond) | Where-Object { -not $_.Current.IsOffscreen }).Count -gt 0
}
function Answer-Dialog([string]$Text, [string]$User, [string]$Password) {
    $dlg = Find-Window 'MSP Tool - Input required' $proc.Id 10000
    if (-not $dlg) { return 'no dialog' }
    $prompt = (Find-ById $dlg 'PromptText').Current.Name
    if ($User) { Set-Value (Find-ById $dlg 'UserBox') $User }
    if ($Password) { Set-Value (Find-ById $dlg 'PasswordBox') $Password }
    if ($PSBoundParameters.ContainsKey('Text')) { Set-Value (Find-ById $dlg 'InputBox') $Text }
    Invoke-El (Find-ById $dlg 'OkBtn')
    return $prompt
}

$proc = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\gui-test-host.ps1`"", '-LogFile', "`"$logFile`"", '-CombinedReport', "`"$combinedFile`"") -PassThru
try {
    $main = Find-Window 'MSP Tool' $proc.Id
    Check ($null -ne $main) 'GUI window opened'
    if (-not $main) { throw 'GUI did not open' }

    # --- 1. Slow tool alone: live output + responsive window ---
    Set-Tool 'Test Slow Tool' $true
    $done = Get-Count 'Batch complete.'
    Invoke-El (Find-ById $main 'RunBtn')
    Check (Wait-Log 'slow start' 0 5000) 'tool output appears in the log while the tool is still running'
    Check ((-not (Find-ById $main 'RunBtn').Current.IsEnabled) -and (Find-ById $main 'StopBtn').Current.IsEnabled) 'Run disabled / Stop enabled while running'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Set-Value (Find-ById $main 'SearchBox') 'zzz'
    $ms = $sw.ElapsedMilliseconds
    Set-Value (Find-ById $main 'SearchBox') ''
    Check ($ms -lt 1500 -and (Get-Count 'slow end') -eq 0) "window responsive while a tool runs (search box answered in $ms ms, tool still sleeping)"
    Check (Wait-Log 'Batch complete.' $done) 'batch completes'
    Check ((Find-ById $main 'RunBtn').Current.IsEnabled -and -not (Find-ById $main 'StopBtn').Current.IsEnabled) 'Run re-enabled / Stop disabled after completion'

    # --- 2. Prompt tool: Read-Host, Read-Host -AsSecureString, Get-Credential become dialogs ---
    Set-Tool 'Test Slow Tool' $false; Set-Tool 'Test Prompt Tool' $true
    $done = Get-Count 'Batch complete.'
    Invoke-El (Find-ById $main 'RunBtn')
    Check (Wait-Log '[2] Beta' 0 5000) "a tool's menu is visible in the log before its prompt"
    $p1 = Answer-Dialog -Text '2'
    Check ($p1 -eq 'Pick a number') "Read-Host shows a GUI dialog with the tool's prompt (got '$p1')"
    $p2 = Answer-Dialog -Password 'abc'
    Check ($p2 -eq 'Enter a secret') "Read-Host -AsSecureString shows a password dialog (got '$p2')"
    $p3 = Answer-Dialog -User 'CORP\tech' -Password 'pw12'
    Check ($p3 -eq 'Credentials please') "Get-Credential shows a credential dialog (got '$p3')"
    [void](Wait-Log 'Batch complete.' $done)
    $log = Get-Log
    Check ($log -match 'picked=2') 'typed answer reaches the tool'
    Check ($log -match 'secretLen=3') 'secure answer reaches the tool as a SecureString'
    Check ($log -match 'user=CORP\\tech pwLen=4') 'credential reaches the tool as a PSCredential'
    Check ($log -notmatch 'abc|pw12') 'secret and password never appear in the log'

    # --- 3. Stop is cooperative: the running tool finishes (cleanup included), the rest are skipped ---
    Set-Tool 'Test Prompt Tool' $false; Set-Tool 'Test Slow Tool' $true; Set-Tool 'Test Slow Tool 2' $true
    $startsBefore = Get-Count '[START] Test Slow Tool'
    $endsBefore = (Get-Count 'slow end') + (Get-Count 'slow2 end')
    Invoke-El (Find-ById $main 'RunBtn')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-Count '[START] Test Slow Tool') -eq $startsBefore -and $sw.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 150 }
    Invoke-El (Find-ById $main 'StopBtn')
    Check (Wait-Log 'Stopped by user' 0 12000) 'Stop ends the run'
    Check (((Get-Count 'slow end') + (Get-Count 'slow2 end')) -eq $endsBefore + 1) 'the tool that was running finished (its cleanup was not cut off)'
    Check ((Get-Count '[START] Test Slow Tool') -eq $startsBefore + 1 -and (Get-Count 'remaining tools were not run') -ge 1) 'tools after it were not started'
    Check ((Find-ById $main 'RunBtn').Current.IsEnabled) 'Run re-enabled after Stop'
    Set-Tool 'Test Slow Tool 2' $false

    # --- 4. Closing while running asks first; No keeps the window open ---
    $done = Get-Count 'Batch complete.'
    $starts = Get-Count 'slow start'
    Invoke-El (Find-ById $main 'RunBtn')
    [void](Wait-Log 'slow start' $starts 5000)
    $main.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $noBtn = Find-ByName $main 'No' 5000
    Check ($null -ne $noBtn) 'closing while running asks for confirmation'
    if ($noBtn) {
        # Win11 message-box buttons expose no UIA actions: send IDNO to that dialog window directly
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $dlg = $walker.GetParent($noBtn)
        while ($dlg -and $dlg.Current.NativeWindowHandle -eq 0) { $dlg = $walker.GetParent($dlg) }
        [void][MspTest.Win32]::PostMessage([IntPtr]$dlg.Current.NativeWindowHandle, 0x0111, [IntPtr]7, [IntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 700
    Check ((-not $proc.HasExited) -and $null -eq (Find-ByName $main 'No' 500)) 'answering No keeps MSP Tool open'
    Check (Wait-Log 'Batch complete.' $done) 'the running tool carries on after answering No'

    # --- 5. Log file gets GUI activity ---
    $fileText = if (Test-Path $logFile) { Get-Content $logFile -Raw } else { '' }
    Check ($fileText -match 'ACTION: Running tools' -and $fileText -match 'picked=2' -and $fileText -match 'slow end') 'GUI tool output is written to the .log file'
    $combinedText = if (Test-Path $combinedFile) { Get-Content $combinedFile -Raw } else { '' }
    Check ($combinedText -match 'Test Prompt Tool \(TestPrompt\)' -and $combinedText -match 'picked=2' -and $combinedText -match 'slow end') 'GUI tool runs are appended to the combined all-tools report'

    # --- 6. Search hides tools, their descriptions, and empty category headers ---
    Check ((Test-AnyOnScreen 'Test Slow Tool') -and (Test-AnyOnScreen '    Sleeps five seconds')) 'before searching, the slow tool and its description are shown'
    Set-Value (Find-ById $main 'SearchBox') 'Asks questions'
    Start-Sleep -Milliseconds 400
    Check (-not (Test-AnyOnScreen 'Test Slow Tool')) 'search hides non-matching tools'
    Check (-not (Test-AnyOnScreen '    Sleeps five seconds')) "search hides a hidden tool's description too"
    Check (Test-AnyOnScreen 'Test Prompt Tool') 'search keeps matching tools'
    Set-Value (Find-ById $main 'SearchBox') 'no-such-tool'
    Start-Sleep -Milliseconds 400
    $headers = @($main.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Test'))) | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Text' -and -not $_.Current.IsOffscreen -and [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($_).Current.ControlType.ProgrammaticName -ne 'ControlType.TabItem' })
    Check ($headers.Count -eq 0) 'category header is hidden when none of its tools match'

    Set-Value (Find-ById $main 'SearchBox') ''

    # --- 6b. Timed prompts (Read-MspHostWithTimeout): countdown dialog ---
    Set-Tool 'Test Slow Tool' $false; Set-Tool 'Test Timed Prompt Tool' $true
    $done = Get-Count 'Batch complete.'
    Invoke-El (Find-ById $main 'RunBtn')
    $dlg = Find-Window 'MSP Tool - Input required' $proc.Id 8000
    $cd = if ($dlg) { Find-ById $dlg 'CountdownText' 2000 } else { $null }
    Check ($null -ne $cd -and $cd.Current.Name -match "Continuing with 'dflt' in \d s") "timed prompt shows a countdown (got '$(if ($cd) { $cd.Current.Name })')"
    Check ($dlg -and (Get-Value (Find-ById $dlg 'InputBox')) -eq 'dflt') 'timed prompt is pre-filled with the default'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $auto = Wait-Log 'timed1=dflt' 0 8000
    Check ($auto -and $sw.Elapsed.TotalSeconds -ge 1.5) "left alone, it continues with the default by itself (after $([math]::Round($sw.Elapsed.TotalSeconds,1)) s)"
    $dlg = Find-Window 'MSP Tool - Input required' $proc.Id 8000
    Set-Value (Find-ById $dlg 'InputBox') 'typed'
    Start-Sleep -Seconds 4   # longer than the 3 s countdown
    Check ($null -ne (Find-Window 'MSP Tool - Input required' $proc.Id 500) -and (Get-Count 'timed2=') -eq 0) 'typing stops the countdown (dialog still waiting after the timeout)'
    Invoke-El (Find-ById $dlg 'OkBtn')
    Check (Wait-Log 'timed2=typed' 0 5000) 'the typed answer is returned'
    $dlg = Find-Window 'MSP Tool - Input required' $proc.Id 8000
    Invoke-El (Find-ById $dlg 'CancelBtn')
    Check (Wait-Log 'timed3=[] isnull=True' 0 5000) 'Cancel returns $null (tool treats it as skip)'
    [void](Wait-Log 'Batch complete.' $done 8000)
    Set-Tool 'Test Timed Prompt Tool' $false; Set-Tool 'Test Slow Tool' $true

    # --- 7. Closing while running + Yes: waits for the running tool to finish, then closes ---
    $fileEndsBefore = ([regex]::Matches((Get-Content $logFile -Raw), 'slow end')).Count
    $starts = Get-Count 'slow start'
    Invoke-El (Find-ById $main 'RunBtn')
    [void](Wait-Log 'slow start' $starts 5000)
    $main.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $yesBtn = Find-ByName $main 'Yes' 5000
    if ($yesBtn) {
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $dlg = $walker.GetParent($yesBtn)
        while ($dlg -and $dlg.Current.NativeWindowHandle -eq 0) { $dlg = $walker.GetParent($dlg) }
        [void][MspTest.Win32]::PostMessage([IntPtr]$dlg.Current.NativeWindowHandle, 0x0111, [IntPtr]6, [IntPtr]::Zero)   # IDYES
    }
    Start-Sleep -Milliseconds 800
    Check ($null -ne $yesBtn -and -not $proc.HasExited) 'answering Yes does not kill the running tool - window stays until it finishes'
    Check ($proc.WaitForExit(12000)) 'MSP Tool closes by itself once the tool has finished'
    $fileEndsAfter = ([regex]::Matches((Get-Content $logFile -Raw), 'slow end')).Count
    Check ($fileEndsAfter -eq $fileEndsBefore + 1) 'the interrupted-by-close tool ran to completion (logged its end)'
}
catch { $results.Add("[FAIL] driver error: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))") }
finally { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force } }
$results
"{0} passed, {1} failed" -f @($results | Where-Object { $_ -like '`[PASS*' }).Count, @($results | Where-Object { $_ -like '`[FAIL*' }).Count
Remove-Item -LiteralPath $logFile, $combinedFile -ErrorAction SilentlyContinue
exit @($results | Where-Object { $_ -like '`[FAIL*' }).Count
