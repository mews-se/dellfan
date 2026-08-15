# Dell Optiplex temperature and fan control

[![ShellCheck](https://github.com/mews-se/dellfan/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mews-se/dellfan/actions/workflows/shellcheck.yml)
![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnubash&logoColor=white)
![Platform: Debian based](https://img.shields.io/badge/platform-Debian%20based-A81D33.svg?logo=debian&logoColor=white)
![Hardware: Dell OptiPlex](https://img.shields.io/badge/hardware-Dell%20OptiPlex-007DB8.svg?logo=dell&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Helper: GPL-2.0](https://img.shields.io/badge/helper-GPL--2.0-orange.svg)](helper/dell-bios-fan-control.c)

Fan control on Dell OptiPlex desktops is a mess. Depending on model and kernel version the machine may expose pwm files, only the old ```/proc/i8k``` interface, or nothing at all, and the BIOS keeps overriding whatever you set. dellfan works out what your machine actually supports and sets up the matching method, instead of you guessing your way through the manual recipes at the bottom.

This is a full rebuild of what used to be a couple of manual recipes. The tooling is new, the shell code has been gone through and tested from scratch on real machines, and the old recipes are kept at the bottom for reference.

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
sudo ./dellfan.sh temps      # show the control temperatures; temps 43 57 sets them
sudo ./dellfan.sh uninstall  # remove everything dellfan installed
sudo ./dellfan.sh max        # stop the fan daemon and run the fan at max
sudo ./dellfan.sh auto       # back to automatic control
```

The methods it picks between: if the kernel driver whitelists your model it can really turn the BIOS fan control off, so plain fancontrol is enough. If there are pwm files but no whitelist entry, fancontrol works until the EC re-arms itself, so dellfan adds a systemd drop-in that disables the BIOS control with the bundled SMM helper every time fancontrol starts. If there is only ```/proc/i8k```, it installs tempcontrol.service from this repo. If none of that exists it leaves the EC alone and tells you.

install asks for the control temperatures (fan start and full speed, default 40 and 50 C) and keeps them in ```/etc/dellfan.conf```, where both methods read them. ```temps``` changes them later without a reinstall.

On a machine the driver does not officially support, install offers to configure and load the module itself. It tries ```ignore_dmi=1``` first, which only skips the model list - the EC still has to answer Dell's SMM signature, so it cannot load on the wrong hardware. Only if that fails does it fall back to ```force=1```, which skips the signature check and the BIOS-bug blacklists too and taints the kernel, so dellfan warns loudly and tells you to probe before trusting anything.

The fancontrol drop-in also has a failsafe: anything that stops fancontrol, including a crash, leaves the fan at max instead of at whatever level happened to be set. Better loud than cooked. tempcontrol has the same failsafe built in.

detect also flags leftovers from earlier attempts, like i8kmon crash looping on a desktop (it is a laptop tool that dies looking for a battery), or two fan daemons fighting over the same fan.

install ends by offering a few aliases: ```sen``` (watch sensors every second), ```fanmax``` and ```fanauto``` (the max and auto subcommands above, which do the same thing no matter which method is installed).

## helper/

A vendored copy of [dell-bios-fan-control](https://github.com/mews-se/dell-bios-fan-control), which toggles the BIOS fan control with SMM calls 0x34a3/0x35a3 - the same pair the kernel driver uses for whitelisted desktops. GPL-2.0, unlike the rest of the repo which is MIT; the original copyright headers are kept in the source. SMM code lineage: i8k by Massimo Dal Zotto, dellfan by Carlos Alberto Lopez Perez, dell-bios-fan-control by Tom Freudenberg.

# Manual setup

The recipes dellfan automates. Still valid if you want to do it by hand.

## The i8k route

```
apt install i8kutils lm-sensors
```

i8kutils is built for laptops and enables i8kmon, which just crash loops on a desktop looking for a battery - turn it off:

```
systemctl disable --now i8kmon
```

edit ```/etc/modules``` to contain:
```
coretemp
i8k
dell-smm-hwmon
```

edit ```/etc/modprobe.d/i8k.conf``` to contain:
```
options i8k ignore_dmi=1
```

force=1 also works but skips the SMM signature check and taints the kernel, so save it for when ignore_dmi is not enough. Watch out: i8kutils may ship its own /etc/modprobe.d/dell-smm-hwmon.conf with force=1.

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
- The control temperatures come from ```/etc/dellfan.conf``` (set with ```dellfan temps```); without that file the defaults at the top of ```tempcontrol.sh``` apply. The poll interval is a variable at the top of the script.

Credits: [Tom Freudenberg](https://github.com/TomFreudenberg), [Ronny Svedman](https://github.com/RonnySvedman)

## For some reason you can trick Fancontrol to work on some versions of the Optiplex family

Keep ```/etc/modules``` as above

```
apt install fancontrol
```

Don't use the i8k config but instead add this to /etc/modprobe.d/dell-smm-hwmon.conf (the .conf suffix matters, modprobe ignores the file without it)
```
options dell-smm-hwmon ignore_dmi=1
```

Reboot

Run ```sensors-detect``` and then ```pwmconfig``` and if you're lucky you have a functioning fancontrol. On kernels that expose pwm1 but no pwm1_enable, pwmconfig refuses even though fancontrol itself works fine - dellfan writes the config for you in that case.
