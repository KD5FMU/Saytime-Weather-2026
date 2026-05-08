# Saytime-Weather-2026
Top of the Hour Spoken Time and Weather Conditions announcement. UNDER CONSTRUCTION


First we download the installer script file
```
wget https://raw.githubusercontent.com/KD5FMU/Saytime-Weather-2026/refs/heads/main/install_asl3_weatherapi_v2.sh
```
Then make it executable
```
sudo chmod +x install_asl3_weatherapi_v2.sh
```
Then we can execute the script
```
sudo ./install_asl3_weatherapi_v2.sh
```

Once the installer is finished you will have to update the config file to get the correct weather data
```
sudo nano /etc/asterisk/local/weatherapi.ini
```

You can test the script by running the saytime script foloowed by the zip code and your node number ex:
```
sudo /usr/local/sbin/saytime.pl YOUR_ZIP YOUR_NODE_NUMBER
```
<br>
If you have not installed the legacy version of Saytime/Weather then you may need to add an entry in your crontab
```
sudo crontab -e
```
Then add this line
```
# Hourly Time and Weather Announcement
00 00-23 * * * (/usr/bin/nice -19 /usr/bin/perl /usr/local/sbin/saytime.pl YOUR_ZIP_CODE YOUR_NODE_NUMBER >/dev/null)
```
<br>

I hope this helps
73!
