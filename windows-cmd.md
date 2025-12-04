# Windows Command Prompt

- To verify if a specific port (example 6789) is active, use
  ```
  netstat -ano | find ":6789"
  ```
  It should show LISTENING
- To change IPv4 address for a specific network adapter, use
  ```
  netsh interface ipv4 show interfaces
  ```
  The output would be something like
  ```
  Idx  Met   MTU  State     Name
  ---  ----  ---- --------- -------------------
   11   25   1500 connected Local Area Connection
  ```
  Then assign the static IPv4 address to the adapter
  ```
  netsh interface ipv4 set address name="<adapter>" static <IP> <MASK> <GATEWAY> <METRIC(optional)>

  netsh interface ipv4 set address name="Local Area Connection" static 192.168.128.50 255.255.255.0 192.168.128.1
  ```
  To set primary DNS server, use
  ```
  netsh interface ipv4 set dns name="<adapter>" static <DNS-IP>

  netsh interface ipv4 set dns name="Local Area Connection" static 8.8.8.8
  ```
  And to set secondary DNS server, use
  ```
  netsh interface ipv4 add dns name="<adapter>" <DNS-IP> index=2

  netsh interface ipv4 add dns name="Local Area Connection" 8.8.4.4 index=2
  ```
  
  

# Windows Sysadmin CMD Reference

## 🖥️ System Information & Diagnostics
| Command | Description |
|--------|-------------|
| `systeminfo` | Display full system info |
| `wmic cpu get loadpercentage` | CPU usage |
| `wmic os get freephysicalmemory` | Free RAM |
| `driverquery /v` | List drivers with details |
| `sfc /scannow` | Scan & repair system files |
| `DISM /Online /Cleanup-Image /RestoreHealth` | Repair Windows image |
| `tasklist` | List running processes |
| `taskkill /PID <pid> /F` | Kill process by PID |
| `powercfg /batteryreport` | Generate battery report |
| `chkdsk /f /r` | Check & repair disk |

---

## 🌐 Networking & Connectivity
| Command | Description |
|--------|-------------|
| `ipconfig /all` | Full network config |
| `ipconfig /flushdns` | Clear DNS cache |
| `ipconfig /release` / `renew` | Reset DHCP lease |
| `arp -a` | Show ARP table |
| `route print` | Show routing table |
| `route add <net> mask <mask> <gw>` | Add static route |
| `netstat -ano` | Show ports + PIDs |
| `nslookup <domain>` | DNS lookup |
| `ping <host>` | Test connectivity |
| `tracert <host>` | Trace route |
| `pathping <host>` | Advanced traceroute + loss |
| `netsh interface ipv4 show interfaces` | List NICs |
| `netsh advfirewall firewall add rule …` | Add firewall rule |

---

## 🧩 User, Group & Security
| Command | Description |
|--------|-------------|
| `net user` | List local users |
| `net user <user> /add` | Create user |
| `net localgroup administrators <user> /add` | Add user to admins |
| `whoami /groups` | Show user group memberships |
| `gpupdate /force` | Force apply GPO |
| `secedit /export` | Export security policy |
| `cipher /w:C` | Secure wipe free space |
| `fsutil` | NTFS advanced operations |

---

## 📁 File System & Permissions
| Command | Description |
|--------|-------------|
| `robocopy <src> <dst> /MIR /Z /R:2` | Robust file/folder copy |
| `xcopy <src> <dst> /E /I` | Copy folders & files |
| `icacls <folder>` | View/modify permissions |
| `takeown /F <path>` | Take file/folder ownership |
| `dir /a` | List files with attributes |
| `attrib +h +s <file>` | Set file attributes |

---

## 🧪 Windows Updates & Packages
| Command | Description |
|--------|-------------|
| `wuauclt /detectnow` | Force update check (Win7/8) |
| `usoclient startscan` | Force update scan (Win10/11) |
| `dism /online /get-packages` | List installed updates |
| `winget install <package>` | Install software |

---

## 🔄 Services & Startup
| Command | Description |
|--------|-------------|
| `services.msc` | Open Services GUI |
| `sc query` | List services |
| `sc config <svc> start= auto` | Set service startup |
| `sc stop <svc>` / `sc start <svc>` | Manage service state |
| `msconfig` | System boot config |

---

## 🪟 Windows Images, Boot & Recovery
| Command | Description |
|--------|-------------|
| `bcdedit` | Edit boot configuration |
| `reagentc /info` | Windows recovery info |
| `wbadmin start backup ...` | Perform system backup |
| `dism /apply-image` | Deploy a WIM |
| `dism /capture-image` | Capture a WIM |

---

## 🖧 Domain & Active Directory (RSAT Required)
| Command | Description |
|--------|-------------|
| `whoami /fqdn` | Show full domain DN |
| `nltest /dsgetdc:<domain>` | Locate domain controller |
| `nltest /server:<pc> /status` | Check DC status |
| `gpresult /r` | Show applied GPOs |
| `netdom query /domain:<domain> workstation` | List domain PCs |
| `dsquery user -name <pattern>` | Search AD users |
| `dsmod user` | Modify AD user |

---

## 🔁 Remote Management & Power Control
| Command | Description |
|--------|-------------|
| `shutdown /r /t 0` | Restart system immediately |
| `shutdown /i` | Remote shutdown GUI |
| `psexec \\host cmd` | Run remote CMD (Sysinternals) |
| `query session` | View RDP sessions |
| `logoff <sessionID>` | Log off user session |

---

## 📜 Automation & Scripting
| Command | Description |
|--------|-------------|
| `for /f "tokens=*" %i in ('dir /b') do echo %i` | Loop over files |
| `set var=value` | Set environment variable |
| `if`, `goto`, `call` | Batch scripting logic |
| `schtasks /create ...` | Create scheduled task |

---

## ⭐ Useful Sysadmin Tools (GUI)
| Tool | Description |
|------|-------------|
| `eventvwr` | Event Viewer |
| `perfmon` | Performance Monitor |
| `resmon` | Resource Monitor |
| `devmgmt.msc` | Device Manager |
| `compmgmt.msc` | Computer Management |
| `gpedit.msc` | Local Group Policy Editor |
| `regedit` | Registry Editor |



