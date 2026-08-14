# Dell Optiplex temperature and fan control

[![ShellCheck](https://github.com/mews-se/dell-optiplex-temp-control/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mews-se/dell-optiplex-temp-control/actions/workflows/shellcheck.yml)

Fan control on Dell OptiPlex desktops is a mess. Depending on model and kernel version the machine may expose pwm files, only the old ```/proc/i8k``` interface, or nothing at all, and the BIOS keeps overriding whatever you set. dellfan works out what your machine actually supports and sets up the matching method, instead of you guessing your way through the manual recipes at the bottom.

## dellfan

Run it as root from the repo directory:

```
sudo ./dellfan.sh
```

Without arguments it opens a menu. The subcommands:

```
sudo ./dellfan.sh detect     # read-only report: model, driver state, which method will work
sudo ./dellfan.sh probe      # optional write test: confirms the fan really answers, restores everything
sudo ./dellfan.sh install    # set up the recommended method
sudo ./dellfan.sh status     # what is installed and running
sudo ./dellfan.sh uninstall  # remove everything dellfan installed
sudo ./dellfan.sh max        # stop the fan daemon and run the fan at max
sudo ./dellfan.sh auto       # back to automatic control
```

The methods it picks between: if the kernel driver whitelists your model it can really turn the BIOS fan control off, so plain fancontrol is enough. If there are pwm files but no whitelist entry, fancontrol works until the EC re-arms itself, so dellfan adds a systemd drop-in that disables the BIOS control with the bundled SMM helper every time fancontrol starts. If there is only ```/proc/i8k```, it installs tempcontrol.service from this repo. If none of that exists it leaves the EC alone and tells you.

The fancontrol drop-in also has a failsafe: anything that stops fancontrol, including a crash, leaves the fan at max instead of at whatever level happened to be set. Better loud than cooked. tempcontrol has the same failsafe built in.

detect also flags leftovers from earlier attempts, like i8kmon crash looping on a desktop (it is a laptop tool that dies looking for a battery), or two fan daemons fighting over the same fan.

install ends by offering a few aliases: ```sen``` (watch sensors every second), ```fanmax``` and ```fanauto``` (the max and auto subcommands above, which do the same thing no matter which method is installed).

## helper/

A vendored copy of [dell-bios-fan-control](https://github.com/mews-se/dell-bios-fan-control), which toggles the BIOS fan control with SMM calls 0x34a3/0x35a3 - the same pair the kernel driver uses for whitelisted desktops. GPL-2.0, unlike the rest of the repo which is MIT; the original copyright headers are kept in the source. SMM code lineage: i8k by Massimo Dal Zotto, dellfan by Carlos Alberto Lopez Perez, dell-bios-fan-control by Tom Freudenberg.

# Manual setup

The recipes dellfan automates. Still valid if you want to do it by hand.

## The i8k route

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

Credits: [Tom Freudenberg](https://github.com/TomFreudenberg), [Ronny Svedman](https://github.com/RonnySvedman)

## For some reason you can trick Fancontrol to work on some versions of the Optiplex family

Keep ```/etc/modules``` as above

Don't use the i8k config but instead add this to /etc/modprobe.d/dell-smm-hwmon
```
options dell-smm-hwmon ignore_dmi=1
```

Run ```sensors-detect``` and then ```pwmconfig``` and if you're lucky you have a functioning fancontrol

Reboot
