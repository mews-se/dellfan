# Dell Optiplex temperature and fan control

[![ShellCheck](https://github.com/mews-se/dell-optiplex-temp-control/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mews-se/dell-optiplex-temp-control/actions/workflows/shellcheck.yml)
Many of Dell Optiplex has no way of controlling fan speed in certain distros of Linux. This is a good enough work around.
Fancontrol and/or i8kmon isn't a sure way of making sure that the fans aren't dead or at full blast. This is a crude solve.

How-to:

```
apt install i8kutils lm-sensors acpi
```

edit ```/etc/modules``` to contain:
```
coretemp
i8k
dell-smm-hwmon
```

edit ```/etc/modprobe.d/i8k.conf``` to contain:
```
options i8k force=1
```

reboot

Move tempcontrol.sh to ```/usr/local/bin/``` and make sure it's executable (chmod +x)
Move tempcontrol.service to ```/etc/systemd/system/```

```
systemctl enable tempcontrol.service
systemctl start tempcontrol.service
```

Check status with ```systemctl status tempcontrol.service```
Check sensors to make sure that fan speed and temperature is showing correctly

Notes:
- The script finds the ```coretemp``` hwmon device by name, so there is no sensor path to edit.
- As a failsafe, both fans are set to max whenever the script exits (including ```systemctl stop```), so the machine is never left without cooling.
- Thresholds and poll interval are variables at the top of ```tempcontrol.sh```.

OPTIONAL: To also disable Dell's bios fan control use [this](https://github.com/mews-se/dell-bios-fan-control)

Credits: [Tom Freudenberg](https://github.com/TomFreudenberg), [Ronny Svedman](https://github.com/RonnySvedman)


# For some reason you can trick Fancontrol to work on some versions of the Optiplex family

Keep ```/etc/modules``` as above

Don't use the i8k config but instead add this to /etc/modprobe.d/dell-smm-hwmon
```
options dell-smm-hwmon ignore_dmi=1
```

Run ```sensors-detect``` and then ```pwmconfig``` and if you're lucky you have a functioning fancontrol

Reboot
