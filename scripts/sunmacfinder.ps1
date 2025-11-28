# =========================================
# Sun Storage Auto-Discovery Tool (Ethernet Only)
# With MAC Vendor Highlighting for Sun Storage
# =========================================

$LogFile = "SunDiscovery.log"
$SunPrefix = "00-A0-B8"   # Known Sun Storage MAC OUI

Write-Host "`n=== Sun Storage Auto Discovery Tool (Ethernet Only) ===`n"
"=== Sun Storage Discovery Run $(Get-Date) ===`n" | Out-File $LogFile -Force

# Detect Ethernet adapter
$Ethernet = Get-NetAdapter | Where-Object { $_.Name -match "Ethernet" } | Select-Object -First 1

if (!$Ethernet) {
    Write-Host "ERROR: No Ethernet interface found. Connect cable and retry." -ForegroundColor Red
    exit
}

$InterfaceAlias = $Ethernet.Name

Write-Host "Using Adapter: $InterfaceAlias"
"Using Interface: $InterfaceAlias`n" | Out-File -Append $LogFile

# Known Sun / Storage subnets
$Subnets = @(
    "172.23.12",
    "172.25.97",
    "172.25.14",
    "172.25.6",
    "172.25.5",
    "172.25.10",
    "172.25.12",
    "172.25.13",
    "172.25.14",
    "172.25.15",
    "172.25.40",
    "192.168.128",
    "10.17.103",
    "10.17.102",
    "192.168.1",
    "192.168.100",
    "192.168.0",
    "10.0.0",
    "172.16.0",
    "172.16.10",
    "169.254.0"
)

foreach ($Subnet in $Subnets) {

    Write-Host "`nConfiguring $InterfaceAlias to $Subnet.10 ..."
    "Testing subnet $Subnet.0/24" | Out-File -Append $LogFile

    # Remove old IP
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    # Assign new IP
    New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress "$Subnet.10" -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null

    Start-Sleep -Seconds 2

    Write-Host "`nScanning $Subnet.0/24..."

    for ($i = 1; $i -le 254; $i++) {
        $IP = "$Subnet.$i"

        if (Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            
            ping $IP -n 1 > $null
            $Entry = arp -a | Select-String $IP

            if ($Entry) {

                # Normalize spacing and extract fields
                $Match = $Entry.ToString() -replace "\s+", " "
                $Fields = $Match.Split(" ")

                # Validate ARP format (must contain IP + MAC)
                if ($Fields.Count -lt 3) {
                    continue
                }

                $FoundIP  = $Fields[1]
                $FoundMAC = $Fields[2].ToUpper()

                # Skip broadcast and invalid MACs
                if ($FoundMAC -notmatch "([0-9A-F]{2}-){5}[0-9A-F]{2}") {
                    continue
                }

                $Output = "{0,-18} {1,-20}" -f $FoundIP, $FoundMAC

                if ($FoundMAC.StartsWith($SunPrefix)) {
                    Write-Host "SUN DEVICE FOUND ->  $Output" -ForegroundColor Cyan
                    "SUN DEVICE: $Output" | Out-File -Append $LogFile
                } else {
                    Write-Host "FOUND ->  $Output" -ForegroundColor Yellow
                    "FOUND: $Output" | Out-File -Append $LogFile
                }
            }
        }
    }
}

Write-Host "`nRestoring DHCP on Ethernet ..."
Set-NetIPInterface -InterfaceAlias $InterfaceAlias -Dhcp Enabled -ErrorAction SilentlyContinue

Write-Host "`nScan Complete. Results saved to $LogFile.`n"
