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
  
  






