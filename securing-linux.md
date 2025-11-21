# Securing Linux

- If Redis Server has no password, find redis.conf and set a password using requirepass
  ```
  find / -name "redis.conf" 2>/dev/null
  ```
- SNMP has 2 monitoring modes: READ (PUBLIC) and WRITE (PRIVATE). Guessing PUBLIC community string allows attackers to read SNMP data. Guessing PRIVATE community string allows attackers to modfiy information.
  ```
  find / -name "snmpd.conf" 2>/dev/null
  ```
  Then modify or comment out the following
  ```
  # Read-only access to everyone to the systemonly view
  rocommunity  public default -V systemonly
  rocommunity6 public default -V systemonly
  ```
- NGINX should not be running as root. To change the configuration, use
  ```
  find / -name "nginx.conf" 2>/dev/null
  ```
  then edit the configuration file
  ```
  nano /etc/nginx/nginx.conf
  ```
  At the top of the file, change the following from root to www-data
  ```
  user www-data; (previously root)
  worker_processes auto;
  ```
- 



  
