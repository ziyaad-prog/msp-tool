function Show-MspGui {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ToolConfig,

        [Parameter(Mandatory)]
        [hashtable]$PresetConfig,

        [string[]]$ProcedureNames = @(),

        # Tool/procedure output is appended here as well as to the on-screen log
        [string]$LogFile,

        # Combined all-tools report (see Start-MspCombinedReportEntry); empty = none
        [string]$CombinedReport
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $repoRoot = Split-Path -Parent $PSScriptRoot

    $categories = $ToolConfig.Values |
        ForEach-Object { $_.category } |
        Sort-Object -Unique

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MSP Tool" Height="760" Width="1100" MinHeight="600" MinWidth="900"
        WindowStartupLocation="CenterScreen" Background="#1E1E2E">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#45475A"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Margin" Value="0,4"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#45475A"/>
      <Setter Property="Padding" Value="8,6"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="MinWidth" Value="180"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="BorderBrush" Value="#45475A"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="TabBorder" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1,1,1,0"
                    Padding="{TemplateBinding Padding}" Margin="0,0,2,0">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="TabBorder" Property="Background" Value="#181825"/>
                <Setter TargetName="TabBorder" Property="BorderBrush" Value="#89B4FA"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="TabBorder" Property="Background" Value="#45475A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Padding" Value="8,4"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True">
          <Setter Property="Background" Value="#45475A"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#45475A"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="220"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
      <Image x:Name="LogoImage" Height="40" Margin="0,0,12,0" VerticalAlignment="Center"/>
      <TextBlock Text="MSP Tool" FontSize="24" FontWeight="Bold" Foreground="#89B4FA" VerticalAlignment="Center"/>
      <TextBlock x:Name="AdminBadge" Margin="16,0,0,0" VerticalAlignment="Center" FontSize="12"/>
      <TextBlock x:Name="StatusText" Margin="16,0,0,0" VerticalAlignment="Center" FontSize="12" Foreground="#F9E2AF"/>
    </StackPanel>

    <Grid Grid.Row="1" Margin="0,0,0,4">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="SearchBox" Grid.Column="0" Text="" ToolTip="Search tools by name or description"/>
      <ComboBox x:Name="PresetCombo" Grid.Column="1" Margin="8,0,0,0"/>
      <Button x:Name="ApplyPresetBtn" Grid.Column="2" Content="Apply Preset"/>
      <Button x:Name="ClearSearchBtn" Grid.Column="3" Content="Clear Filter"/>
    </Grid>

    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,8" HorizontalAlignment="Right">
      <TextBlock Text="Procedure:" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <ComboBox x:Name="ProcedureCombo" MinWidth="240"/>
      <CheckBox x:Name="AutoOnlyCheck" Content="Automated steps only" VerticalAlignment="Center" Margin="12,0,4,0"/>
      <Button x:Name="RunProcedureBtn" Content="Run Procedure"/>
    </StackPanel>

    <TabControl x:Name="CategoryTabs" Grid.Row="3" Background="#181825" BorderBrush="#45475A">
      <TabItem Header="All Tools" Tag="All"/>
    </TabControl>

    <Border Grid.Row="4" Margin="0,12,0,12" Background="#181825" BorderBrush="#45475A" BorderThickness="1" CornerRadius="4">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Text="Output Log" Margin="8,6" FontWeight="SemiBold" Foreground="#A6E3A1"/>
        <TextBox x:Name="LogBox" Grid.Row="1" Margin="8" IsReadOnly="True" TextWrapping="Wrap" Background="Transparent"
                 VerticalScrollBarVisibility="Auto" BorderThickness="0" Foreground="#FFFFFF" FontFamily="Consolas" FontSize="12"/>
      </Grid>
    </Border>

    <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="SelectAllBtn" Content="Select All"/>
      <Button x:Name="ClearAllBtn" Content="Clear All"/>
      <Button x:Name="StopBtn" Content="Stop" IsEnabled="False"/>
      <Button x:Name="RunBtn" Content="Run Selected" Background="#89B4FA" Foreground="#1E1E2E" FontWeight="Bold"/>
    </StackPanel>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $searchBox = $window.FindName('SearchBox')
    $presetCombo = $window.FindName('PresetCombo')
    $applyPresetBtn = $window.FindName('ApplyPresetBtn')
    $clearSearchBtn = $window.FindName('ClearSearchBtn')
    $procedureCombo = $window.FindName('ProcedureCombo')
    $autoOnlyCheck = $window.FindName('AutoOnlyCheck')
    $runProcedureBtn = $window.FindName('RunProcedureBtn')
    $categoryTabs = $window.FindName('CategoryTabs')
    $logBox = $window.FindName('LogBox')
    $selectAllBtn = $window.FindName('SelectAllBtn')
    $clearAllBtn = $window.FindName('ClearAllBtn')
    $stopBtn = $window.FindName('StopBtn')
    $runBtn = $window.FindName('RunBtn')
    $adminBadge = $window.FindName('AdminBadge')
    $statusText = $window.FindName('StatusText')
    $logoImage = $window.FindName('LogoImage')

    # Load logo from assets folder if present
    $logoPath = Join-Path $repoRoot 'assets\logo.png'
    if (Test-Path $logoPath) {
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.UriSource = [Uri]::new($logoPath)
            $bitmap.EndInit()
            $bitmap.Freeze()
            $logoImage.Source = $bitmap
        }
        catch {
            $logoImage.Visibility = 'Collapsed'
        }
    }
    else {
        $logoImage.Visibility = 'Collapsed'
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        $adminBadge.Text = 'Administrator'
        $adminBadge.Foreground = '#A6E3A1'
    } else {
        $adminBadge.Text = 'Standard User (some tools require Admin)'
        $adminBadge.Foreground = '#F9E2AF'
    }

    $checkboxMap = @{}
    $allCheckboxes = [System.Collections.Generic.List[object]]::new()
    # Search hides a tool's description with its checkbox, and a category header once all its tools are hidden
    $descriptionFor = @{}
    $headerTools = @{}

    function Sync-Checkbox {
        param($Sender, [bool]$Value)
        if (-not $Sender.Tag) { return }
        foreach ($c in $checkboxMap[$Sender.Tag]) {
            if ($c.IsChecked -ne $Value) { $c.IsChecked = $Value }
        }
    }

    function Add-ToolCheckboxes {
        param([System.Windows.Controls.Panel]$Panel, [string]$FilterCategory)

        $Panel.Children.Clear()
        $groups = $ToolConfig.GetEnumerator() |
            Where-Object {
                $item = $_.Value
                if ($FilterCategory -and $FilterCategory -ne 'All' -and $item.category -ne $FilterCategory) { return $false }
                return $true
            } |
            Group-Object { $_.Value.category } |
            Sort-Object Name

        foreach ($group in $groups) {
            $header = New-Object System.Windows.Controls.TextBlock
            $header.Text = $group.Name
            $header.FontWeight = 'Bold'
            $header.FontSize = 14
            $header.Foreground = '#89B4FA'
            $header.Margin = '0,12,0,6'
            [void]$Panel.Children.Add($header)
            $headerTools[$header] = [System.Collections.Generic.List[object]]::new()

            foreach ($entry in ($group.Group | Sort-Object {
                if ($_.Value.PSObject.Properties.Name -contains 'Order') { $_.Value.Order } else { 9999 }
            }, { $_.Value.Content })) {
                $id = $entry.Key
                $tool = $entry.Value

                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.Tag = $id
                $cb.Content = $tool.Content
                $cb.ToolTip = $tool.Description
                if ($tool.RequiresAdmin -and -not $isAdmin) {
                    $cb.Foreground = '#A6ADC8'
                    $cb.ToolTip = "$($tool.Description)`n(Requires Administrator)"
                }

                if (-not $checkboxMap.ContainsKey($id)) {
                    $checkboxMap[$id] = [System.Collections.Generic.List[object]]::new()
                }
                [void]$checkboxMap[$id].Add($cb)
                if ($checkboxMap[$id].Count -gt 1) { $cb.IsChecked = $checkboxMap[$id][0].IsChecked }
                [void]$allCheckboxes.Add($cb)
                [void]$headerTools[$header].Add($cb)

                $cb.Add_Checked({ Sync-Checkbox -Sender $sender -Value $true })
                $cb.Add_Unchecked({ Sync-Checkbox -Sender $sender -Value $false })

                [void]$Panel.Children.Add($cb)

                $desc = New-Object System.Windows.Controls.TextBlock
                $desc.Text = "    $($tool.Description)"
                $desc.Foreground = '#A6ADC8'
                $desc.FontSize = 11
                $desc.TextWrapping = 'Wrap'
                $desc.Margin = '24,0,0,4'
                [void]$Panel.Children.Add($desc)
                $descriptionFor[$cb] = $desc
            }
        }
    }

    function New-ToolPanel {
        $scroll = New-Object System.Windows.Controls.ScrollViewer
        $scroll.VerticalScrollBarVisibility = 'Auto'
        $scroll.HorizontalScrollBarVisibility = 'Disabled'
        $scroll.Margin = '8'

        $stack = New-Object System.Windows.Controls.StackPanel
        $scroll.Content = $stack
        return @{ Scroll = $scroll; Panel = $stack }
    }

    $allPanel = New-ToolPanel
    Add-ToolCheckboxes -Panel $allPanel.Panel -FilterCategory 'All'
    $categoryTabs.Items[0].Content = $allPanel.Scroll

    foreach ($cat in $categories) {
        $tab = New-Object System.Windows.Controls.TabItem
        $tab.Header = $cat
        $tab.Tag = $cat
        $panel = New-ToolPanel
        Add-ToolCheckboxes -Panel $panel.Panel -FilterCategory $cat
        $tab.Content = $panel.Scroll
        [void]$categoryTabs.Items.Add($tab)
    }

    $presetCombo.ItemsSource = @('') + ($PresetConfig.Keys | Sort-Object)
    $presetCombo.SelectedIndex = 0

    $procedureCombo.ItemsSource = @($ProcedureNames)
    if ($ProcedureNames.Count) { $procedureCombo.SelectedIndex = 0 }
    else { $procedureCombo.IsEnabled = $false; $runProcedureBtn.IsEnabled = $false; $autoOnlyCheck.IsEnabled = $false }

    function Write-LogLine {
        param([string]$Message)
        $timestamp = Get-Date -Format 'HH:mm:ss'
        $logBox.AppendText("[$timestamp] $Message`r`n")
        $logBox.ScrollToEnd()
    }

    # ------------------------------------------------------------------
    # Input dialogs: tools run in a background runspace, where Read-Host and
    # Get-Credential are replaced by functions that call these on the UI thread.
    # ------------------------------------------------------------------
    function Show-MspInputDialog {
        # -TimeoutSeconds > 0: pre-fill -Default and auto-accept it when the countdown ends (typing stops the
        # countdown); Cancel then returns $null so the tool can treat it as "skip"
        param([string]$Message, [bool]$Secure, [bool]$Credential, [int]$TimeoutSeconds = 0, [string]$Default = '')

        $dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MSP Tool - Input required" Width="560" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="Manual" Background="#1E1E2E" ShowInTaskbar="False">
  <StackPanel Margin="16">
    <TextBlock x:Name="PromptText" Foreground="#FFFFFF" FontFamily="Segoe UI" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <TextBlock x:Name="UserLabel" Text="User name" Foreground="#A6ADC8" Margin="0,0,0,2"/>
    <TextBox x:Name="UserBox" Background="#313244" Foreground="#FFFFFF" BorderBrush="#45475A" Padding="6,4" Margin="0,0,0,8"/>
    <TextBlock x:Name="PasswordLabel" Text="Password" Foreground="#A6ADC8" Margin="0,0,0,2"/>
    <PasswordBox x:Name="PasswordBox" Background="#313244" Foreground="#FFFFFF" BorderBrush="#45475A" Padding="6,4"/>
    <TextBox x:Name="InputBox" Background="#313244" Foreground="#FFFFFF" BorderBrush="#45475A" Padding="6,4"/>
    <TextBlock x:Name="CountdownText" Foreground="#F9E2AF" FontFamily="Segoe UI" Margin="0,8,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="OkBtn" Content="OK" IsDefault="True" MinWidth="80" Margin="4" Padding="10,4"/>
      <Button x:Name="CancelBtn" Content="Cancel" IsCancel="True" MinWidth="80" Margin="4" Padding="10,4"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
        $dialog = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dialogXaml)))
        $dialog.Owner = $window
        # Sit near the top of the main window so the output log (which usually holds the list being chosen from) stays visible
        $dialog.Left = $window.Left + [math]::Max(0, ($window.ActualWidth - $dialog.Width) / 2)
        $dialog.Top = $window.Top + 90

        $promptText = $dialog.FindName('PromptText')
        $userLabel = $dialog.FindName('UserLabel'); $userBox = $dialog.FindName('UserBox')
        $passwordLabel = $dialog.FindName('PasswordLabel'); $passwordBox = $dialog.FindName('PasswordBox')
        $inputBox = $dialog.FindName('InputBox')
        $promptText.Text = if ($Message) { $Message } else { 'Input required' }

        if (-not $Credential) { $userLabel.Visibility = 'Collapsed'; $userBox.Visibility = 'Collapsed' }
        if ($Credential -or $Secure) { $inputBox.Visibility = 'Collapsed'; if (-not $Credential) { $passwordLabel.Visibility = 'Collapsed' } }
        else { $passwordLabel.Visibility = 'Collapsed'; $passwordBox.Visibility = 'Collapsed' }

        $dialog.FindName('OkBtn').Add_Click({ $dialog.DialogResult = $true })

        $countdown = @{ Left = $TimeoutSeconds; Timer = $null }
        if ($TimeoutSeconds -gt 0 -and -not $Secure -and -not $Credential) {
            $inputBox.Text = $Default
            $inputBox.SelectAll()
            $countdownText = $dialog.FindName('CountdownText')
            $countdownText.Visibility = 'Visible'
            $countdownText.Text = "Continuing with '$Default' in $TimeoutSeconds s - type to change"
            $countdown.Timer = New-Object System.Windows.Threading.DispatcherTimer
            $countdown.Timer.Interval = [TimeSpan]::FromSeconds(1)
            $countdown.Timer.Add_Tick({
                $countdown.Left--
                if ($countdown.Left -le 0) { $countdown.Timer.Stop(); $dialog.DialogResult = $true; return }
                $countdownText.Text = "Continuing with '$Default' in $($countdown.Left) s - type to change"
            })
            # A key press or any change to the text (typing, pasting) means the technician is answering - stop the countdown
            $stopCountdown = { if ($countdown.Timer.IsEnabled) { $countdown.Timer.Stop(); $countdownText.Visibility = 'Collapsed' } }
            $inputBox.Add_PreviewKeyDown($stopCountdown)
            $inputBox.Add_TextChanged($stopCountdown)
            $dialog.Add_ContentRendered({ $countdown.Timer.Start() })
            $dialog.Add_Closed({ $countdown.Timer.Stop() })
        }
        $dialog.Add_ContentRendered({
            if ($Credential) { [void]$userBox.Focus() } elseif ($Secure) { [void]$passwordBox.Focus() } else { [void]$inputBox.Focus() }
        })

        $ok = [bool]$dialog.ShowDialog()
        if ($Credential) {
            if ($ok -and $userBox.Text) { return New-Object System.Management.Automation.PSCredential($userBox.Text, $passwordBox.SecurePassword) }
            return $null
        }
        if ($Secure) {
            if ($ok -and $passwordBox.SecurePassword.Length) { return $passwordBox.SecurePassword }
            return $null
        }
        if ($TimeoutSeconds -gt 0) {
            if (-not $ok) { return $null }
            if ([string]::IsNullOrWhiteSpace($inputBox.Text)) { return $Default }
            return $inputBox.Text
        }
        if ($ok) { return $inputBox.Text }
        return ''
    }

    # Everything the background runspace touches on the UI thread. The delegates are created
    # here, in the UI runspace, so they run in it when the dispatcher invokes them.
    $sync = [hashtable]::Synchronized(@{})
    $sync.Window = $window
    $sync.AppendLog = [Action[object]] { param($m) Write-LogLine "$m" }
    $sync.Prompt = [Func[object, object, object]] { param($msg, $secure) Show-MspInputDialog -Message "$msg" -Secure ([bool]$secure) }
    $sync.Credential = [Func[object, object]] { param($msg) Show-MspInputDialog -Message "$msg" -Credential $true }
    $sync.TimedPrompt = [Func[object, object, object, object]] { param($msg, $seconds, $default) Show-MspInputDialog -Message "$msg" -TimeoutSeconds ([int]$seconds) -Default "$default" }

    $runnerScript = {
        param($sync, $repoRoot, $mode, $target, $autoOnly, $toolConfig, $logFile, $combinedReport)
        $ErrorActionPreference = 'Stop'
        $ScriptRoot = $repoRoot
        $MspCombinedReportPath = $combinedReport
        . (Join-Path $repoRoot 'functions\Invoke-MspTool.ps1')
        . (Join-Path $repoRoot 'functions\Invoke-MspProcedure.ps1')

        # Tools call these by name; route them to GUI dialogs (a runspace has no console to prompt in)
        function global:Read-Host {
            param([Parameter(Position = 0)][object]$Prompt, [switch]$AsSecureString)
            $sync.Window.Dispatcher.Invoke($sync.Prompt, [object[]]@("$Prompt", [bool]$AsSecureString))
        }
        # Same scope as the dot-sourced engine version, so this one wins for tools run from here
        function Read-MspHostWithTimeout {
            param([Parameter(Mandatory)][string]$Prompt, [int]$TimeoutSeconds = 5, [string]$Default = '')
            $sync.Window.Dispatcher.Invoke($sync.TimedPrompt, [object[]]@($Prompt, $TimeoutSeconds, $Default))
        }
        function global:Get-Credential {
            param([Parameter(Position = 0)][object]$UserName, [string]$Message, [string]$Title)
            $text = if ($Message) { $Message } elseif ($Title) { $Title } else { 'Enter credentials' }
            $sync.Window.Dispatcher.Invoke($sync.Credential, [object[]]@($text))
        }

        $onLog = {
            param($m)
            $sync.Window.Dispatcher.Invoke($sync.AppendLog, [object[]]@("$m"))
            if ($logFile) {
                try { Add-Content -Path $logFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch { }
            }
        }

        # Stop is cooperative: checked between tools/steps, never mid-tool, so a tool's cleanup
        # (e.g. restarting services it stopped) always runs to completion
        $shouldStop = { [bool]$sync.StopRequested }

        if ($mode -eq 'Procedure') {
            & $onLog "ACTION: Running procedure '$target'"
            $procedure = Resolve-MspProcedure -Name $target
            Invoke-MspProcedure -Procedure $procedure -ToolConfig $toolConfig -AutoOnly:$autoOnly -OnLog $onLog -ShouldStop $shouldStop
        }
        else {
            & $onLog "ACTION: Running tools ($($target -join ', '))"
            Invoke-MspToolBatch -ToolIds $target -ToolConfig $toolConfig -OnLog $onLog -ShouldStop $shouldStop | Out-Null
        }
    }

    # Current background job - a hashtable so event handlers can update it without scoping issues
    $run = @{ Job = $null; CloseWhenDone = $false }

    function Set-RunningState {
        param([bool]$Running, [string]$Status = '')
        $runBtn.IsEnabled = -not $Running
        $runProcedureBtn.IsEnabled = (-not $Running) -and $ProcedureNames.Count -gt 0
        $applyPresetBtn.IsEnabled = -not $Running
        $stopBtn.IsEnabled = $Running
        $statusText.Text = $Status
    }

    function Start-MspBackgroundRun {
        param([string]$Mode, $Target, [bool]$AutoOnly)

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        $sync.StopRequested = $false
        [void]$ps.AddScript($runnerScript).AddArgument($sync).AddArgument($repoRoot).AddArgument($Mode).AddArgument($Target).AddArgument($AutoOnly).AddArgument($ToolConfig).AddArgument($LogFile).AddArgument($CombinedReport)
        $run.Job = @{ PowerShell = $ps; Runspace = $runspace; Handle = $ps.BeginInvoke() }
        Set-RunningState -Running $true -Status 'Running...'
        $timer.Start()
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        $job = $run.Job
        if (-not $job -or -not $job.Handle.IsCompleted) { return }
        $timer.Stop()
        try { [void]$job.PowerShell.EndInvoke($job.Handle) }
        catch { Write-LogLine "[ERROR] $($_.Exception.InnerException.Message)$($_.Exception.Message)" }
        foreach ($err in $job.PowerShell.Streams.Error) { Write-LogLine "[ERROR] $err" }
        $job.PowerShell.Dispose(); $job.Runspace.Dispose()
        $run.Job = $null
        Set-RunningState -Running $false
        Write-LogLine $(if ($sync.StopRequested) { 'Stopped by user (the tool that was running finished first).' } else { 'Batch complete.' })
        if ($run.CloseWhenDone) { $window.Close() }
    })

    Write-LogLine 'MSP Tool ready. Select tools or apply a preset, then click Run Selected.'

    $applyPresetBtn.Add_Click({
        $presetName = $presetCombo.SelectedItem
        if ([string]::IsNullOrWhiteSpace($presetName)) { return }

        $preset = $PresetConfig[$presetName]
        if (-not $preset) { return }

        foreach ($cb in $allCheckboxes) { $cb.IsChecked = $false }

        foreach ($toolId in $preset.Tools) {
            if ($checkboxMap.ContainsKey($toolId)) {
                foreach ($cb in $checkboxMap[$toolId]) { $cb.IsChecked = $true }
            }
        }

        Write-LogLine "Applied preset: $presetName - $($preset.Description)"
    })

    $selectAllBtn.Add_Click({
        $visible = $allCheckboxes | Where-Object { $_.Visibility -ne 'Collapsed' -and $_.IsVisible }
        foreach ($cb in $visible) { $cb.IsChecked = $true }
    })

    $clearAllBtn.Add_Click({
        foreach ($cb in $allCheckboxes) { $cb.IsChecked = $false }
    })

    $clearSearchBtn.Add_Click({ $searchBox.Text = '' })

    $searchBox.Add_TextChanged({
        $filter = $searchBox.Text.Trim().ToLowerInvariant()
        foreach ($cb in $allCheckboxes) {
            $text = "$($cb.Content)".ToLowerInvariant()
            $desc = "$($cb.ToolTip)".ToLowerInvariant()
            $match = [string]::IsNullOrWhiteSpace($filter) -or $text.Contains($filter) -or $desc.Contains($filter)
            $cb.Visibility = if ($match) { 'Visible' } else { 'Collapsed' }
            if ($descriptionFor.ContainsKey($cb)) { $descriptionFor[$cb].Visibility = $cb.Visibility }
        }
        foreach ($header in $headerTools.Keys) {
            $anyVisible = @($headerTools[$header] | Where-Object { $_.Visibility -ne 'Collapsed' }).Count -gt 0
            $header.Visibility = if ($anyVisible) { 'Visible' } else { 'Collapsed' }
        }
    })

    $runBtn.Add_Click({
        $selected = @($checkboxMap.GetEnumerator() | Where-Object { @($_.Value | Where-Object IsChecked -eq $true).Count -gt 0 } | ForEach-Object { $_.Key })
        if ($selected.Count -eq 0) {
            Write-LogLine 'No tools selected.'
            return
        }
        Write-LogLine "Running $($selected.Count) tool(s)..."
        Start-MspBackgroundRun -Mode 'Tools' -Target $selected -AutoOnly $false
    })

    $runProcedureBtn.Add_Click({
        $name = $procedureCombo.SelectedItem
        if (-not $name) { return }
        Start-MspBackgroundRun -Mode 'Procedure' -Target "$name" -AutoOnly ([bool]$autoOnlyCheck.IsChecked)
    })

    $stopBtn.Add_Click({
        if ($run.Job -and -not $sync.StopRequested) {
            $sync.StopRequested = $true
            Write-LogLine '[STOP] Stop requested - the tool that is running now will finish (including its cleanup), then no further tools run.'
            $statusText.Text = 'Stopping after the current tool...'
            $stopBtn.IsEnabled = $false
        }
    })

    $window.Add_Closing({
        param($s, $e)
        if ($run.Job) {
            # Never tear down a running tool: it may have stopped services it still needs to restart
            $e.Cancel = $true
            if ($run.CloseWhenDone) { return }
            $answer = [System.Windows.MessageBox]::Show($window, "Tools are still running.`n`nStop after the current tool finishes, then close MSP Tool?", 'MSP Tool', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
            $sync.StopRequested = $true
            $run.CloseWhenDone = $true
            $stopBtn.IsEnabled = $false
            $statusText.Text = 'Closing after the current tool finishes...'
            Write-LogLine '[STOP] MSP Tool will close once the current tool has finished.'
        }
    })

    [void]$window.ShowDialog()
}
