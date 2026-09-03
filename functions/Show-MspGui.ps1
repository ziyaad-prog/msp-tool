function Show-MspGui {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ToolConfig,

        [Parameter(Mandatory)]
        [hashtable]$PresetConfig,

        [string[]]$ProcedureNames = @(),

        [scriptblock]$OnRun,

        [scriptblock]$OnProcedure
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $categories = $ToolConfig.Values |
        ForEach-Object { $_.category } |
        Sort-Object -Unique

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MSP Tool" Height="720" Width="1100" MinHeight="600" MinWidth="900"
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
      <RowDefinition Height="*"/>
      <RowDefinition Height="200"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
      <Image x:Name="LogoImage" Height="40" Margin="0,0,12,0" VerticalAlignment="Center"/>
      <TextBlock Text="MSP Tool" FontSize="24" FontWeight="Bold" Foreground="#89B4FA" VerticalAlignment="Center"/>
      <TextBlock x:Name="AdminBadge" Margin="16,0,0,0" VerticalAlignment="Center" FontSize="12"/>
    </StackPanel>

    <Grid Grid.Row="1" Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="SearchBox" Grid.Column="0" Text="" Tag="Search tools..."/>
      <ComboBox x:Name="PresetCombo" Grid.Column="1" Margin="8,0,0,0"/>
      <Button x:Name="ApplyPresetBtn" Grid.Column="2" Content="Apply Preset"/>
      <Button x:Name="ClearSearchBtn" Grid.Column="3" Content="Clear Filter"/>
    </Grid>

    <TabControl x:Name="CategoryTabs" Grid.Row="2" Background="#181825" BorderBrush="#45475A">
      <TabItem Header="All Tools" Tag="All"/>
    </TabControl>

    <Border Grid.Row="3" Margin="0,12,0,12" Background="#181825" BorderBrush="#45475A" BorderThickness="1" CornerRadius="4">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Text="Output Log" Margin="8,6" FontWeight="SemiBold" Foreground="#A6E3A1"/>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="8">
          <TextBox x:Name="LogBox" IsReadOnly="True" TextWrapping="Wrap" Background="Transparent"
                   BorderThickness="0" Foreground="#FFFFFF" FontFamily="Consolas" FontSize="12"/>
        </ScrollViewer>
      </Grid>
    </Border>

    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="SelectAllBtn" Content="Select All"/>
      <Button x:Name="ClearAllBtn" Content="Clear All"/>
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
    $categoryTabs = $window.FindName('CategoryTabs')
    $logBox = $window.FindName('LogBox')
    $selectAllBtn = $window.FindName('SelectAllBtn')
    $clearAllBtn = $window.FindName('ClearAllBtn')
    $runBtn = $window.FindName('RunBtn')
    $adminBadge = $window.FindName('AdminBadge')
    $logoImage = $window.FindName('LogoImage')

    # Load logo from assets folder if present
    $logoPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\logo.png'
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

            foreach ($entry in ($group.Group | Sort-Object { $_.Value.Content })) {
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
                    $checkboxMap[$id] = $cb
                    [void]$allCheckboxes.Add($cb)
                } else {
                    $cb.IsChecked = $checkboxMap[$id].IsChecked
                    $checkboxMap[$id] = $cb
                }

                [void]$Panel.Children.Add($cb)

                $desc = New-Object System.Windows.Controls.TextBlock
                $desc.Text = "    $($tool.Description)"
                $desc.Foreground = '#A6ADC8'
                $desc.FontSize = 11
                $desc.TextWrapping = 'Wrap'
                $desc.Margin = '24,0,0,4'
                [void]$Panel.Children.Add($desc)
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

    function Write-LogLine {
        param([string]$Message)
        $timestamp = Get-Date -Format 'HH:mm:ss'
        $logBox.AppendText("[$timestamp] $Message`r`n")
        $logBox.ScrollToEnd()
    }

    Write-LogLine 'MSP Tool ready. Select tools or apply a preset, then click Run Selected.'

    $applyPresetBtn.Add_Click({
        $presetName = $presetCombo.SelectedItem
        if ([string]::IsNullOrWhiteSpace($presetName)) { return }

        $preset = $PresetConfig[$presetName]
        if (-not $preset) { return }

        foreach ($cb in $allCheckboxes) { $cb.IsChecked = $false }

        foreach ($toolId in $preset.Tools) {
            if ($checkboxMap.ContainsKey($toolId)) {
                $checkboxMap[$toolId].IsChecked = $true
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
        }
    })

    $runBtn.Add_Click({
        $selected = @($checkboxMap.GetEnumerator() | Where-Object { $_.Value.IsChecked -eq $true } | ForEach-Object { $_.Key })
        if ($selected.Count -eq 0) {
            Write-LogLine 'No tools selected.'
            return
        }

        $runBtn.IsEnabled = $false
        Write-LogLine "Running $($selected.Count) tool(s)..."

        try {
            & $OnRun $selected { param($m) Write-LogLine $m }
            Write-LogLine 'Batch complete.'
        }
        finally {
            $runBtn.IsEnabled = $true
        }
    })

    [void]$window.ShowDialog()
}
