# PowerShell Commands

- To view adapters on current device, use
  ```
  Get-NetAdapter
  ```
  Output is shown below:
  ```
  Name                      InterfaceDescription                    ifIndex Status       MacAddress             LinkSpeed
  ----                      --------------------                    ------- ------       ----------             ---------
  Ethernet                  Realtek Gaming GbE Family Controller         24 Up           C0-18-03-86-C8-26       100 Mbps
  VMware Network Adapte...8 VMware Virtual Ethernet Adapter for ...      21 Up           00-50-56-C0-00-08       100 Mbps
  Wi-Fi                     Intel(R) Wi-Fi 6 AX201 160MHz                20 Up           D4-54-8B-D6-C2-52       574 Mbps
  Local Area Connection     TAP-Windows Adapter V9                       10 Disconnected 00-FF-50-83-BD-A0         1 Gbps
  ```

- To set Ethernet adapter to certain IP address, use
  ```
  Get-NetIPAddress -InterfaceAlias "Ethernet" -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false
  ```
  and
  ```
  New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "172.23.12.10" -PrefixLength 24
  ```
  Note that IP address ending with .10 is commonly used in forensic/manual network access, because it is not likely the same as the device, not a default gateway, not a broadcast or reserved address and easy to remember
  
- 
