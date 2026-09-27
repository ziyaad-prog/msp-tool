$cmds = @('/scanhealth','/checkhealth','/restorehealth')
foreach ($arg in $cmds) {
  Write-Host "=== DISM /Online /Cleanup-Image $arg ==="
  $proc = Start-Process -FilePath DISM.exe -ArgumentList "/Online /Cleanup-Image $arg" -Wait -PassThru -NoNewWindow
  Write-Host "Exit code: $($proc.ExitCode)"
  Write-Host ''
}
Write-Host 'DISM sequence complete. Run SFC next.'
