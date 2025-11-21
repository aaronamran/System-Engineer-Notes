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
- NGINX should not be running as root. To change the configuration, find the file and edit it
  ```
  find / -name "nginx.conf" 2>/dev/null
  nano /etc/nginx/nginx.conf
  ```
  At the top of the file, change the following from root to www-data
  ```
  user www-data; (previously root)
  worker_processes auto;
  ```
  Then test syntax and restart NGINX service
  ```
  sudo nginx -t
  sudo systemctl restart nginx
  ```
- To take down telnet and TFTP, identify using
  ```
  sudo ss -tulpn | grep :23
  OUTPUT: tcp    LISTEN  0       128                 0.0.0.0:23             0.0.0.0:*      users (("inetd",pid=472,fd=7))
  ```
  Then find inetd and edit it
  ```
  find / -name "inetd.conf" 2>/dev/null
  sudo nano /etc/inetd.conf
  ```
  Comment out the telnet and TFTP lines
  ```
  #:STANDARD: These are standard services.
  telnet                stream  tcp     nowait  telnetd /usr/sbin/tcpd  /usr/sbin/in.telnetd
  
  #:BSD: Shell, login, exec and talk are BSD protocols.
  
  #:MAIL: Mail, news and uucp services.
  
  #:INFO: Info services
  
  #:BOOT: TFTP service is provided primarily for booting.  Most sites
  #       run this only on machines acting as "boot servers."
  tftp          dgram   udp     wait    nobody  /usr/sbin/tcpd  /usr/sbin/in.tftpd /srv/tftp
  ```
  Then restart inetd service
  ```
  sudo systemctl restart inetd
  ```
- In terms of weak SSH crpyto, the following algorithms must be disabled:
  - Weak Key Exchange (KEX) Algorithms: diffie-hellman-group1-sha1
  - Weak Encryption Algorithms: 3des-cbc, aes128-cbc, aes256-cbc
  - Weak MAC Algorithms: hmac-md5-96
  Locate and edit the sshd_config file to remove the listed algorithms
  ```
  find / -name "sshd_config" 2>/dev/null
  sudo nano sshd_config
  ```
  Then verify syntax and restart the sshd service
  ```
  sudo sshd -t
  sudo systemctl restart sshd
  ```
- FTP allows users to login anonymously as 'anonymous' or 'ftp'. To disable anonymous FTP logins, locate the config file
  ```
  find / -name "vsftpd.conf" 2>/dev/null
  sudo nano /etc/vsftpd.conf
  ```
  Then edit and replace the permissions
  ```
  # Allow anonymous FTP? (Disabled by default).
  anonymous_enable=NO (Previously YES)
  ```
  Restart the vsftpd service
  ```
  sudo systemctl restart vsftpd
  ```
- As a root user, it is possible to change weak passwords of existing users.
  ```
  sudo passwd username1
  ```
  To remove users and their files, use
  ```
  sudo userdel -r username1
  ```
  To confirm the accounts are deleted, use the following command. It should return no output
  ```
  grep -E 'username1|username2' /etc/passwd
  ```
- To properly modify sudoers file, use visudo
  ```
  sudo visudo
  ```
  To revoke a user which has sudo privileges (`username ALL=(ALL:ALL) ALL`), delete this entire line from the sudoers file
  To allow a user to run a command (example `/usr/bin/ss`) as root, add the following to the end of file: `username ALL=(root) NOPASSWD: /usr/bin/ss`
- Exposed Database ports can be exploited by attackers. To bind the ports to localhost, do the following.
  Locate and edit the MySQL configuration file using
  ```
  find / -name "my.cnf" 2>/dev/null  (sometimes in /etc/mysql/conf.d/)
  sudo nano /etc/mysql/my.cnf
  ```
  Locate the [mysqld] section and find the bind-address directive and set the bind-address to loopback address (127.0.0.1) using
  ```
  sudo grep -R "\[mysqld\]" /etc/mysql/
  OUTPUT: /etc/mysql/mysql.conf.d/mysqld.cnf:[mysqld]
  sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf
  ```
  Then edit the following
  ```
  # Instead of skip-networking the default is now to listen only on
  # localhost which is more compatible and is not less secure.
  bind-address            = 0.0.0.0  (change to 127.0.0.1)
  mysqlx-bind-address     = 127.0.0.1
  ```
  Then restart the MySQL service
  ```
  sudo systemctl restart mysql
  ```
  For Redis Database, edit the configuration file
  ```
  sudo nano /etc/redis/redis.conf
  ```
  Edit the following line
  ```
  # IF YOU ARE SURE YOU WANT YOUR INSTANCE TO LISTEN TO ALL THE INTERFACES
  # JUST COMMENT THE FOLLOWING LINE.
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  bind 0.0.0.0  (change to 127.0.0.1)
  ```
  Then restart the Redis service
  ```
  sudo systemctl restart redis-server
  ```



  
  

  


  



  
