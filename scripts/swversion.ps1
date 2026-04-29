Write-Host "=== OS ===" -ForegroundColor Cyan
# Gets Kernel/Build version and OS Name
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, OSArchitecture
[System.Runtime.InteropServices.RuntimeInformation]::OSDescription

Write-Host "=== Python ===" -ForegroundColor Cyan
# Checks for python in PATH
try { 
    python --version 
    python -c "print('venv ok')"
} catch { 
    Write-Host "Python not found in PATH" -ForegroundColor Red 
}

Write-Host "=== Sudo (Privilege Check) ===" -ForegroundColor Cyan
# Windows uses 'Run as Administrator' rather than sudo. This checks for Admin rights.
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 
    Write-Host "Running as Administrator (sudo ok)" 
} else { 
    Write-Host "Running as Standard User" 
}

Write-Host "=== Disk ===" -ForegroundColor Cyan
# Equivalent to df -h
Get-Volume | Where-Object DriveLetter -ne $null | Select-Object DriveLetter, @{Name="Size(GB)";Expression={[math]::round($_.Size/1GB,2)}}, @{Name="Free(GB)";Expression={[math]::round($_.SizeRemaining/1GB,2)}}, @{Name="Usage%";Expression={[math]::round((($_.Size - $_.SizeRemaining)/$_.Size)*100,2)}}
