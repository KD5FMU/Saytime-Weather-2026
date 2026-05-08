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
