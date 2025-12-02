# Installing Windows 7 Professional as VM in VirtualBox

- This ReadMe is divided into 2 sections: [Adding Windows 7 ISO in VirtualBox](#adding-windows-7-iso-in-virtualbox) and [Installing Windows Updates](#installing-windows-updates)
- For a bare metal Windows 7 installation, create a bootable USB using Rufus and install as usual. Then skip to [Installing Windows Updates](#installing-windows-updates) to learn how to bypass error code 80072EFE
- The rough idea is to install Windows 7 fully and all its updates, then only install Guest Additions. Adding the Guest Additions before Windows 7 is fully updated will cause the Windows 7 VM in VirtualBox to crash

<details>
  <summary><h2>Adding Windows 7 ISO in VirtualBox</h2></summary>

  1. Open VirtualBox. Click New and add select the Windows 7 ISO file. In the Edition dropdown, select the type you want to use. We will be using Windows 7 Professional in this ReadMe
     <img width="796" height="471" alt="image" src="https://github.com/user-attachments/assets/0ae5825a-75ac-43d3-977a-052272ec9cd7" />

  2. After clicking Next, change the hostname to a name that has no spaces. Most importantly, ensure that the Guest Additions checkbox are unchecked. This is to prevent the installation of Guest Addtions from crashing the VM
     <img width="794" height="470" alt="image" src="https://github.com/user-attachments/assets/de76ecf4-ddc2-4d42-b050-9ec54f548d19" />

  3. Then configure the RAM and Disk Size. 30 GB Disk Size should be more than enough
  4. After completing the steps, Windows 7 VM will automatically startup. We will let it setup and restart few times
     <img width="824" height="619" alt="image" src="https://github.com/user-attachments/assets/fe25741a-f159-48c8-be8c-5ab26e0a2363" />

  
</details>



<details>
  <summary><h2>Installing Windows Updates</h2></summary>

  1. Once Windows 7 initial setup is done and stable, we navigate to Control Panel and attempt to install Windows Updates. You will notice that there is an error code 80072EFE
     <img width="1099" height="623" alt="image" src="https://github.com/user-attachments/assets/e41aedad-2859-4a9d-9907-bcf3af429c0e" />

  2. Using the preinstalled Internet Explorer (IE) browser to directly download patch updates is not an option due to End of Life. IE will not connect to any websites as it is no longer supported
     <img width="808" height="381" alt="image" src="https://github.com/user-attachments/assets/08ad6ac4-766c-4107-82d1-8bd933c050b5" />

  3. To bypass this, enter the following URL in the IE search bar
     ```
     win32subsystem.live
     ```
     Then scroll down to Supermium browser and click on it
     <img width="815" height="575" alt="image" src="https://github.com/user-attachments/assets/fe366d39-eddb-4d29-8286-0e2088c217ff" />
     You will be redirected to Supermium official project's homepage. Download the correct type based on your system (64-bit or 32-bit). Once the download is complete, run the installation. It is recommended to enable Supermium for all users
  4. Open Supermium and enter the URL in the search bar
     ```
     https://catalog.update.microsoft.com
     ```

  5. In the Microsoft Update Catalog (MUC) search bar, the first update we will download is **KB976932** which is an update for Windows 7 Service Pack 1. A pop-up window will appear. Choose the exe and click on it to download. This update can be skipped if your Windows 7 is already running as Service Pack 1. 
     <img width="814" height="619" alt="image" src="https://github.com/user-attachments/assets/6c314087-317f-493a-8e33-e265ea5fb95b" />

  6. The next update we will install is **KB4490628**, which is a Servicing Stack Update. Again, search for the correct type and install it. Make sure to restart Windows 7 after installing each update
  7. Then we will return to MUC and search for **KB4474419**, which is a Security Update. This update is required for SHA2 signin, which is required to get more updates. Download and install the correct type. Restart Windows 7 once this step is completed
  8. Return to MUC on Supermium and search for and download **KB4536952**. This is also another Servicing Stack Update. After installing it, restart Windows 7
  9. The last manual update we will download from MUC is **KB4534310**. This is a Microsoft's Security Monthly Quality Rollup. Repeat the usual installation and restart steps. After Windows 7 restarts, the following screen will appear. Just click on "Don't remind me again"
     <img width="750" height="566" alt="image" src="https://github.com/user-attachments/assets/9dd73b01-dcac-42b0-b345-4ae451534710" />

  10. Now navigate to Windows Update in Control Panel. Then click on "Turn on Automatic Updates", and ensure it is checking for updates. This step will take a while for download and installation
  11. 





  
</details>
