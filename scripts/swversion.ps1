# Read-only diagnostic script — no writes, no installs, no service changes

Write-Host "=== OS ==="
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
    Write-Host "$($os.Version) $($env:PROCESSOR_ARCHITECTURE)"
    Write-Host $os.Caption
} catch {
    Write-Host "OS query failed: $_"
}

Write-Host "=== Python ==="
$pyCmd = Get-Command python -ErrorAction SilentlyContinue
if ($pyCmd) {
    try {
        $pyVersion = & python --version 2>&1
        Write-Host $pyVersion
        $venvCheck = & python -c "import venv; print('venv ok')" 2>&1
        Write-Host $venvCheck
    } catch {
        Write-Host "python check failed: $_"
    }
} else {
    Write-Host "python: command not found"
}

Write-Host "=== Admin ==="
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { Write-Host "admin ok" } else { Write-Host "not admin" }
} catch {
    Write-Host "Admin check failed: $_"
}

Write-Host "=== Installed Software ==="
try {
    $regPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $regPaths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.DisplayName -ne $null } |
        Select-Object DisplayName, DisplayVersion, Publisher,
            @{N='InstallDate'; E={
                if ($_.InstallDate) {
                    try { [datetime]::ParseExact($_.InstallDate,'yyyyMMdd',$null).ToString('dd-MMM-yy') }
                    catch { $_.InstallDate }
                }
            }} |
        Sort-Object DisplayName |
        Format-Table -AutoSize
} catch {
    Write-Host "Installed software query failed: $_"
}

Write-Host "=== Disk ==="
try {
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -ne "" } |
        Select-Object `
            @{N='Filesystem'; E={ $_.Root }},
            @{N='Size';       E={ "{0:N1}G" -f (($_.Used + $_.Free) / 1GB) }},
            @{N='Used';       E={ "{0:N1}G" -f ($_.Used / 1GB) }},
            @{N='Avail';      E={ "{0:N1}G" -f ($_.Free / 1GB) }},
            @{N='Use%';       E={ if (($_.Used + $_.Free) -gt 0) { "{0:N0}%" -f ($_.Used / ($_.Used + $_.Free) * 100) } else { "N/A" } }},
            @{N='Mounted on'; E={ $_.Root }} |
        Format-Table -AutoSize
} catch {
    Write-Host "Disk query failed: $_"
}

Read-Host "`nDone. Press Enter to exit"
