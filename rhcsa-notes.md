# RHCSA Notes

---

## 👤 User & Group Administration
| Command | Description |
|--------|-------------|
| `useradd <user>` | Create user |
| `passwd <user>` | Set user password |
| `usermod -aG <group> <user>` | Add user to group |
| `groupadd <group>` | Create group |
| `id <user>` | Show UID/GID/groups |
| `chage -l <user>` | View password aging |
| `chage -M 90 <user>` | Set max password age |
| `userdel -r <user>` | Remove user + home directory |
| `gpasswd -a <user> wheel` | Add sudo-capable user |

---

## 📁 File Permissions & Ownership
| Command | Description |
|--------|-------------|
| `chmod 755 <file>` | Change permissions |
| `chmod g+w <file>` | Add group write |
| `chown user:group <file>` | Change ownership |
| `setfacl -m u:<user>:rw file` | Add ACL |
| `getfacl file` | View ACLs |
| `umask` | View default mask |
| `umask 027` | Set default umask |

---

## 💼 File System Management
| Command | Description |
|--------|-------------|
| `mkfs.ext4 /dev/sdX1` | Create EXT4 FS |
| `mkfs.xfs /dev/sdX1` | Create XFS FS |
| `mount /dev/sdX1 /mnt` | Mount filesystem |
| `umount /mnt` | Unmount |
| `blkid` | Identify UUID |
| `lsblk` | Show block devices |
| `nano /etc/fstab` | Persist mounts |
| `mount -a` | Test fstab |
| `xfs_growfs /mountpoint` | Grow XFS |
| `resize2fs /dev/sdX1` | Grow EXT4 |

---

## 🔧 LVM & VDO Storage
| Command | Description |
|--------|-------------|
| `pvcreate /dev/sdX` | Create PV |
| `vgcreate vgname /dev/sdX` | Create VG |
| `lvcreate -L 5G -n lvname vgname` | Create LV |
| `lvextend -L +2G /dev/vg/lv` | Extend LV |
| `lvextend -r -L +2G /dev/vg/lv` | Extend LV + FS |
| `pvs`, `vgs`, `lvs` | Display LVM structures |
| `vdo create --name=vdo1 --device=/dev/sdX --vdoLogicalSize=50G` | Create VDO |
| `vdostats --human-readable` | Check VDO usage |

---

## 🌐 Networking (nmcli)
| Command | Description |
|--------|-------------|
| `nmcli device status` | Show NICs |
| `nmcli connection show` | Show connections |
| `nmcli con add con-name ens33 ifname ens33 type ethernet ip4 192.168.1.50/24 gw4 192.168.1.1` | Create static connection |
| `nmcli con mod ens33 ipv4.dns "8.8.8.8 1.1.1.1"` | Set DNS |
| `nmcli con up ens33` | Activate connection |
| `hostnamectl set-hostname server1` | Set hostname |
| `ip a`, `ip r`, `ss -tulnp` | Network diagnostics |

---

## 🔥 Firewalld
| Command | Description |
|--------|-------------|
| `systemctl enable --now firewalld` | Enable firewall |
| `firewall-cmd --list-all` | Show active rules |
| `firewall-cmd --add-service=http --permanent` | Allow service |
| `firewall-cmd --reload` | Reload |
| `firewall-cmd --add-port=8080/tcp --permanent` | Open port |

---

## 🧱 SELinux Management
| Command | Description |
|--------|-------------|
| `sestatus` | Check SELinux status |
| `setenforce 0` | Permissive mode |
| `setenforce 1` | Enforcing mode |
| `semanage fcontext -a -t httpd_sys_content_t "/web(/.*)?"` | Label directories |
| `restorecon -Rv /web` | Apply SELinux labels |
| `getsebool -a` | List boolean options |
| `setsebool -P httpd_can_network_connect on` | Enable boolean |

---

## 🔄 Systemd, Services & Boot Targets
| Command | Description |
|--------|-------------|
| `systemctl enable <svc>` | Enable service |
| `systemctl disable <svc>` | Disable service |
| `systemctl start <svc>` | Start |
| `systemctl stop <svc>` | Stop |
| `systemctl status <svc>` | Service info |
| `systemctl list-units --type service` | All services |
| `systemctl set-default multi-user.target` | Switch boot target |
| `systemctl isolate graphical.target` | Switch current target |
| `journalctl -xe` | View logs |

---

## 🍱 Archiving & Compression
| Command | Description |
|--------|-------------|
| `tar -cvf archive.tar dir` | Create TAR |
| `tar -xvf archive.tar` | Extract TAR |
| `tar -czvf archive.tar.gz dir` | Create TGZ |
| `gzip file` / `gunzip file.gz` | Compress/decompress |
| `rsync -av /src /dest` | Sync directories |

---

## 🖥️ Processes, Memory & Performance
| Command | Description |
|--------|-------------|
| `ps aux` | List processes |
| `top`, `htop` | Monitor usage |
| `systemctl reboot` | Reboot |
| `kill -9 <pid>` | Force kill |
| `free -h` | Memory usage |
| `df -h` | Disk usage |
| `du -sh <dir>` | Directory size |

---

## 📜 Bash Scripting Essentials
| Command | Description |
|--------|-------------|
| `#!/bin/bash` | Script shebang |
| `chmod +x script.sh` | Make executable |
| `for i in $(seq 1 5); do echo $i; done` | Loop |
| `read var` | User input |
| `if [ ]; then ... fi` | Conditions |
| `case $var in` | Case switch |
| `echo $PATH` | View env vars |

---

## ⏰ Cron & Systemd Timers
| Command | Description |
|--------|-------------|
| `crontab -e` | Edit user cron |
| `crontab -l` | List cron jobs |
| `/etc/crontab` | Global cron |
| `systemctl list-timers` | Show timers |
| `systemctl enable --now myjob.timer` | Enable timer |

---

## 🐳 Podman / Containers (RHCSA 9)
| Command | Description |
|--------|-------------|
| `podman pull <image>` | Pull image |
| `podman run -d --name web -p 80:80 nginx` | Run container |
| `podman ps -a` | List containers |
| `podman images` | List images |
| `podman rm <container>` | Remove container |
| `podman build -t myimg .` | Build container image |
| `podman generate systemd --name web > /etc/systemd/system/web.service` | Persist container with systemd |
| `systemctl enable --now web` | Auto-start container |

---

## 🧵 Bootloaders & Rescue Mode
| Command | Description |
|--------|-------------|
| `grub2-mkconfig -o /boot/grub2/grub.cfg` | Rebuild GRUB |
| `chroot /mnt/sysroot` | Enter rescue shell |
| `passwd` | Reset root password |
| `mount -o remount,rw /` | Enable write mode |

---

## 🔍 Essential Troubleshooting Commands
| Command | Description |
|--------|-------------|
| `journalctl -b` | Logs for this boot |
| `nmcli device status` | NIC issues |
| `getenforce` | SELinux mode |
| `dmesg` | Kernel messages |
| `tail -f /var/log/messages` | Live logs |
| `ss -tulnp` | Open ports |

