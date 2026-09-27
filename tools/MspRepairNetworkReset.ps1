Write-Host 'Resetting network stack...'
netsh winsock reset
netsh int ip reset
Write-Host 'Network stack reset. A reboot is recommended.'
