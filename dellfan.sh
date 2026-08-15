#!/bin/bash

# dellfan - work out which fan control method a Dell desktop actually
# supports and set it up, instead of guessing through the README recipes.
# Tracks: whitelisted kernel driver -> plain fancontrol, pwm files without
# whitelist -> fancontrol plus the SMM helper, /proc/i8k only -> tempcontrol.

set -u

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SRC_DIR/$(basename "$0")"
HELPER_SRC="$SRC_DIR/helper/dell-bios-fan-control.c"
HELPER_BIN=/usr/local/bin/dell-bios-fan-control
FC_DROPIN=/etc/systemd/system/fancontrol.service.d/dellfan.conf
TC_DROPIN=/etc/systemd/system/tempcontrol.service.d/dellfan.conf
TC_SCRIPT=/usr/local/bin/tempcontrol.sh
TC_UNIT=/etc/systemd/system/tempcontrol.service
ALIAS_FILE=/etc/profile.d/dellfan-aliases.sh
CONF_FILE=/etc/dellfan.conf
WL_MSG="Enabling support for setting automatic/manual fan control"

RESTART=""
TMP_HELPER=""
HELPER_USE=""

die() { echo "$*" >&2; exit 1; }

confirm() {
    local a
    read -r -p "$1 [y/N] " a < /dev/tty
    [ "$a" = y ] || [ "$a" = Y ]
}

smm_dir() {
    local d
    for d in /sys/class/hwmon/hwmon*; do
        if [ -r "$d/name" ] && [ "$(cat "$d/name")" = dell_smm ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

rpm_now() {
    [ -n "$HW" ] && cat "$HW/fan1_input" 2>/dev/null
}

fancontrol_temp() {
    sed -n -E "s|^$1=[^=]+=([0-9]+)\$|\1|p" /etc/fancontrol 2>/dev/null | head -1
}

# the conf file wins, an existing /etc/fancontrol seeds it, defaults last
load_temps() {
    LOW=40
    HIGH=50
    if [ -r "$CONF_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CONF_FILE"
    elif [ -f /etc/fancontrol ]; then
        local lo hi
        lo=$(fancontrol_temp MINTEMP)
        hi=$(fancontrol_temp MAXTEMP)
        [ -n "$lo" ] && LOW=$lo
        [ -n "$hi" ] && HIGH=$hi
    fi
}

write_temps_conf() {
    cat > "$CONF_FILE" <<EOF
# written by dellfan - the fan starts at LOW C and runs full from HIGH C
LOW=$LOW
HIGH=$HIGH
EOF
}

valid_temps() {
    case "$1$2" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 20 ] && [ "$2" -le 90 ] && [ "$1" -lt "$2" ]
}

apply_temps_fancontrol() {
    [ -f /etc/fancontrol ] || return 0
    sed -i -E "s|^(MINTEMP=[^=]+=)[0-9]+\$|\1$LOW|; s|^(MAXTEMP=[^=]+=)[0-9]+\$|\1$HIGH|" /etc/fancontrol
}

gather() {
    MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
    KERNEL=$(uname -r)
    HW=$(smm_dir) || HW=""
    PWM=""
    PWM_ENABLE=""
    if [ -n "$HW" ]; then
        [ -e "$HW/pwm1" ] && PWM="$HW/pwm1"
        [ -e "$HW/pwm1_enable" ] && PWM_ENABLE="$HW/pwm1_enable"
    fi
    WHITELISTED=""
    if dmesg 2>/dev/null | grep -q "$WL_MSG"; then
        WHITELISTED=1
    elif journalctl -q -k -b --no-pager 2>/dev/null | grep -q "$WL_MSG"; then
        WHITELISTED=1
    fi
    I8K=""
    [ -e /proc/i8k ] && I8K=1
    I8KFAN=$(command -v i8kfan || true)
    FC=$(systemctl is-active fancontrol 2>/dev/null)
    TC=$(systemctl is-active tempcontrol 2>/dev/null)
    I8KMON=$(systemctl is-active i8kmon 2>/dev/null)
    TRACK=none
    if [ -n "$WHITELISTED" ] && [ -n "$PWM" ]; then
        TRACK=fancontrol
    elif [ -n "$PWM" ]; then
        TRACK=fancontrol-helper
    elif [ -n "$I8K" ] && [ -n "$I8KFAN" ]; then
        TRACK=tempcontrol
    fi
    # a working tempcontrol beats switching tracks - pwmconfig refuses some
    # of these machines anyway
    if [ "$TC" = active ] && [ -n "$I8K" ] && [ -n "$I8KFAN" ]; then
        TRACK=tempcontrol
    fi
}

cmd_detect() {
    gather
    echo "model:       $MODEL"
    echo "kernel:      $KERNEL"
    if [ -n "$HW" ]; then
        echo "dell_smm:    $HW, fan at $(rpm_now || echo '?') rpm"
    else
        echo "dell_smm:    no hwmon device - install can configure the module"
    fi
    echo "pwm1:        ${PWM:-none}"
    echo "pwm1_enable: ${PWM_ENABLE:-none}"
    if [ -n "$WHITELISTED" ]; then
        echo "whitelisted: yes - the kernel can really toggle the BIOS fan control"
    else
        echo "whitelisted: no fan control line in the boot log"
    fi
    if [ -n "$I8K" ]; then
        echo "/proc/i8k:   yes, i8kfan: ${I8KFAN:-not installed}"
    else
        echo "/proc/i8k:   no, i8kfan: ${I8KFAN:-not installed}"
    fi
    echo "services:    fancontrol=$FC tempcontrol=$TC i8kmon=$I8KMON"

    if [ "$I8KMON" = activating ] || [ "$I8KMON" = failed ]; then
        echo "note: i8kmon is crash looping - it is a laptop tool, disable it:"
        echo "      systemctl disable --now i8kmon"
    elif [ "$I8KMON" = active ]; then
        echo "note: i8kmon is running - not needed alongside fancontrol or tempcontrol"
    fi
    if [ "$FC" = active ] && [ "$TC" = active ]; then
        echo "note: fancontrol and tempcontrol are both active - pick one"
    fi
    if ! fancontrol_hwmon_ok; then
        echo "note: /etc/fancontrol points at another hwmon than dell_smm (${HW##*/})"
        echo "      fancontrol will refuse to start - rerun install to rewrite it"
    fi

    case $TRACK in
        fancontrol)
            echo "recommended: plain fancontrol (run pwmconfig once if /etc/fancontrol is missing)" ;;
        fancontrol-helper)
            echo "recommended: fancontrol with the SMM helper disabling BIOS control at start" ;;
        tempcontrol)
            echo "recommended: tempcontrol (i8kfan based)" ;;
        none)
            echo "recommended: nothing to set up here - the EC keeps control" ;;
    esac
}

fan_hi() {
    if [ -n "$PWM" ]; then
        echo 255 > "$PWM" 2>/dev/null || true
    else
        i8kfan - 2 > /dev/null 2>&1 || true
    fi
}

fan_mid() {
    if [ -n "$PWM" ]; then
        echo 128 > "$PWM" 2>/dev/null || true
    else
        i8kfan - 1 > /dev/null 2>&1 || true
    fi
}

# prefer the installed helper, fall back to a throwaway build
find_helper() {
    HELPER_USE=""
    if [ -x "$HELPER_BIN" ]; then
        HELPER_USE=$HELPER_BIN
        return 0
    fi
    if [ -f "$HELPER_SRC" ] && command -v cc > /dev/null; then
        TMP_HELPER=$(mktemp /tmp/dellfan.XXXXXX)
        if cc -O2 -o "$TMP_HELPER" "$HELPER_SRC" 2> /dev/null; then
            chmod 700 "$TMP_HELPER"
            HELPER_USE=$TMP_HELPER
            return 0
        fi
        rm -f "$TMP_HELPER"
        TMP_HELPER=""
    fi
    return 1
}

probe_helper_toggle() {
    local out
    find_helper || return 0
    confirm "also check that the SMM BIOS-control toggle is accepted?" || return 0
    out=$("$HELPER_USE" 0 2>&1 > /dev/null)
    if [ -n "$out" ]; then echo "disable: $out"; else echo "disable accepted"; fi
    out=$("$HELPER_USE" 1 2>&1 > /dev/null)
    if [ -n "$out" ]; then echo "enable: $out"; else echo "enable accepted"; fi
}

# the stuck state: the EC has re-armed and ignores SET_FAN. two known ways out.
probe_unlock() {
    if [ -n "$PWM_ENABLE" ] && confirm "try the pwm1_enable auto handshake (2 then 1)?"; then
        echo 2 > "$PWM_ENABLE"
        sleep 2
        echo 1 > "$PWM_ENABLE"
        fan_hi
        sleep 6
        echo "after handshake: $(rpm_now) rpm at max command"
    fi
    if find_helper && confirm "try disabling BIOS control with the SMM helper?"; then
        "$HELPER_USE" 0 > /dev/null
        fan_hi
        sleep 6
        echo "with BIOS control off: $(rpm_now) rpm at max command"
        "$HELPER_USE" 1 > /dev/null
    fi
}

probe_restore() {
    if [ -n "$TMP_HELPER" ]; then
        rm -f "$TMP_HELPER"
        TMP_HELPER=""
    fi
    if [ -n "$RESTART" ]; then
        systemctl start "$RESTART"
        echo "$RESTART started again"
    elif [ -n "$PWM_ENABLE" ]; then
        echo 2 > "$PWM_ENABLE" 2>/dev/null || true
        echo "fan handed back to the EC"
    else
        fan_mid
        echo "no fan daemon was running - fan left at the middle level, the EC curve still applies"
    fi
}

cmd_probe() {
    gather
    [ -n "$HW" ] || die "no dell_smm hwmon device - nothing to probe"
    if [ -z "$PWM" ] && [ -z "$I8KFAN" ]; then
        die "no pwm1 and no i8kfan - nothing can set the fan"
    fi
    echo "this briefly stops any fan daemon and writes to the fan controls."
    echo "everything is restored afterwards. the fan gets loud for a few seconds."
    confirm "continue?" || return 0

    RESTART=""
    if [ "$FC" = active ]; then
        systemctl stop fancontrol
        RESTART=fancontrol
    fi
    if [ "$TC" = active ]; then
        systemctl stop tempcontrol
        RESTART=tempcontrol
    fi
    sleep 1
    if [ -n "$PWM_ENABLE" ]; then
        echo 1 > "$PWM_ENABLE" 2>/dev/null || true
    fi

    local mid hi
    fan_mid
    sleep 6
    mid=$(rpm_now)
    fan_hi
    sleep 6
    hi=$(rpm_now)
    echo "mid command -> $mid rpm, max command -> $hi rpm"

    if [ "${hi:-0}" -gt $(( ${mid:-0} + 500 )) ]; then
        echo "manual control works right now"
        probe_helper_toggle
    else
        echo "the max command was ignored - the EC has re-armed (the stuck state)"
        probe_unlock
    fi

    probe_restore
}

# virgin machine: no dell_smm hwmon. configure the module persistently and load it.
prepare_module() {
    confirm "no dell_smm device - configure and load the kernel module now?" || return 1
    printf 'options dell-smm-hwmon restricted=0 ignore_dmi=1\n' > /etc/modprobe.d/dellfan.conf
    printf 'coretemp\ndell-smm-hwmon\n' > /etc/modules-load.d/dellfan.conf
    modprobe coretemp 2> /dev/null || true
    modprobe dell-smm-hwmon 2> /dev/null || true
    sleep 1
    gather
    if [ -z "$HW" ]; then
        # ignore_dmi only skips the model list, the EC must still answer the Dell
        # SMM signature. force skips that too, plus the BIOS-bug blacklists, and
        # taints the kernel - last resort.
        modprobe -r dell-smm-hwmon 2> /dev/null || true
        printf 'options dell-smm-hwmon restricted=0 force=1\n' > /etc/modprobe.d/dellfan.conf
        modprobe dell-smm-hwmon 2> /dev/null || true
        sleep 1
        gather
        if [ -n "$HW" ]; then
            echo "note: needed force=1 - the EC never answered the Dell SMM signature,"
            echo "      readings may be garbage and SMM calls can stall the machine. run probe."
            if [ -z "$(rpm_now)" ]; then
                echo "warning: no fan reading either - do not trust this device"
            fi
        fi
    fi
    if [ -z "$HW" ]; then
        rm -f /etc/modprobe.d/dellfan.conf /etc/modules-load.d/dellfan.conf
        die "dell-smm-hwmon would not give a hwmon device - not a supported machine?"
    fi
    echo "dell_smm loaded, module configured persistently"
}

# hwmon numbering shifts between boots, and /etc/fancontrol pins a number
fancontrol_hwmon_ok() {
    [ -f /etc/fancontrol ] || return 0
    [ -n "$HW" ] || return 0
    grep -q "DEVNAME=${HW##*/}=dell_smm" /etc/fancontrol
}

write_fancontrol_config() {
    local hw=${HW##*/}
    cat > /etc/fancontrol <<EOF
# written by dellfan, same shape as pwmconfig output
INTERVAL=1
DEVPATH=$hw=devices/platform/dell_smm_hwmon
DEVNAME=$hw=dell_smm
FCTEMPS=$hw/pwm1=$hw/temp1_input
FCFANS=$hw/pwm1=$hw/fan1_input
MAXTEMP=$hw/pwm1=$HIGH
MINTEMP=$hw/pwm1=$LOW
MINSTART=$hw/pwm1=150
MINSTOP=$hw/pwm1=0
EOF
    echo "wrote /etc/fancontrol"
}

install_helper_bin() {
    [ -f "$HELPER_SRC" ] || die "helper source missing at $HELPER_SRC"
    command -v cc > /dev/null || die "no C compiler - install gcc first"
    cc -O2 -Wall -o "$HELPER_BIN" "$HELPER_SRC" || die "helper build failed"
    echo "built $HELPER_BIN"
}

install_self() {
    install -m 755 "$SELF" /usr/local/bin/dellfan
    echo "installed /usr/local/bin/dellfan"
}

offer_aliases() {
    local out=""
    if confirm "add the sen alias (watch sensors every second)?"; then
        out="alias sen='watch -n 1 sensors'"
    fi
    if confirm "add fanmax/fanauto aliases (fanmax = daemon off and max fan, fanauto = back to automatic)?"; then
        out="$out
if [ \"\$(id -u)\" = 0 ]; then
    alias fanmax='dellfan max'
    alias fanauto='dellfan auto'
else
    alias fanmax='sudo dellfan max'
    alias fanauto='sudo dellfan auto'
fi"
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out" > "$ALIAS_FILE"
        echo "aliases written to $ALIAS_FILE - new login shells pick them up"
    fi
}

install_fancontrol() {
    [ -n "$PWM" ] || die "no pwm1 - this track needs the pwm interface"
    if [ ! -f /etc/fancontrol ]; then
        if confirm "no /etc/fancontrol - write a basic one (ramp 40-50 C on the dell_smm fan)?"; then
            write_fancontrol_config
        else
            die "run pwmconfig once first, then rerun install"
        fi
    elif ! fancontrol_hwmon_ok; then
        if confirm "/etc/fancontrol points at the wrong hwmon - rewrite it (custom tuning is lost)?"; then
            write_fancontrol_config
        else
            die "fix /etc/fancontrol by hand or rerun pwmconfig first"
        fi
    fi
    write_temps_conf
    apply_temps_fancontrol
    if [ "$TC" = active ]; then
        if confirm "tempcontrol is active and would fight fancontrol - disable it?"; then
            systemctl disable --now tempcontrol
        fi
    fi
    if [ "$1" = helper ]; then
        install_helper_bin
        mkdir -p "$(dirname "$FC_DROPIN")"
        cat > "$FC_DROPIN" <<EOF
[Service]
# the stock unit drops every capability, the helper needs ioperm
PrivateDevices=no
CapabilityBoundingSet=CAP_SYS_RAWIO
ExecStartPre=$HELPER_BIN 0
# failsafe: anything that stops fancontrol leaves the fan at max, not at a leftover level
ExecStopPost=/bin/sh -c 'for d in /sys/class/hwmon/hwmon*; do [ "\$\$(cat \$\$d/name)" = dell_smm ] && echo 255 > \$\$d/pwm1; done; exit 0'
EOF
        echo "drop-in written: BIOS control off while fancontrol runs, max fan when it stops"
    fi
    systemctl daemon-reload
    systemctl enable fancontrol > /dev/null 2>&1 || true
    if ! systemctl restart fancontrol || ! systemctl is-active --quiet fancontrol; then
        rm -f "$FC_DROPIN"
        systemctl daemon-reload
        systemctl reset-failed fancontrol 2> /dev/null || true
        systemctl restart fancontrol || true
        die "fancontrol would not start with the drop-in - reverted, see journalctl -u fancontrol"
    fi
    echo "fancontrol running"
    install_self
    offer_aliases
}

install_tempcontrol() {
    [ -n "$I8KFAN" ] || die "i8kfan missing - apt install i8kutils"
    [ -n "$I8K" ] || die "no /proc/i8k - see the manual setup section in the README"
    if [ "$FC" = active ]; then
        if confirm "fancontrol is active and would fight tempcontrol - disable it?"; then
            systemctl disable --now fancontrol
        fi
    fi
    install -m 755 "$SRC_DIR/tempcontrol.sh" "$TC_SCRIPT"
    install -m 644 "$SRC_DIR/tempcontrol.service" "$TC_UNIT"
    write_temps_conf
    if [ "$1" = helper ]; then
        install_helper_bin
        mkdir -p "$(dirname "$TC_DROPIN")"
        cat > "$TC_DROPIN" <<EOF
[Service]
ExecStartPre=$HELPER_BIN 0
EOF
        echo "drop-in written: BIOS control off while tempcontrol runs"
    fi
    systemctl daemon-reload
    systemctl enable tempcontrol > /dev/null 2>&1
    if ! systemctl restart tempcontrol || ! systemctl is-active --quiet tempcontrol; then
        rm -f "$TC_DROPIN"
        systemctl daemon-reload
        systemctl reset-failed tempcontrol 2> /dev/null || true
        die "tempcontrol would not start - see journalctl -u tempcontrol"
    fi
    echo "tempcontrol running"
    install_self
    offer_aliases
}

cmd_install() {
    gather
    if [ -z "$HW" ]; then
        prepare_module || { echo "nothing installed"; return 0; }
    fi
    echo "detected track: $TRACK"
    echo "1) plain fancontrol (whitelisted kernel)"
    echo "2) fancontrol + SMM helper drop-in"
    echo "3) tempcontrol"
    echo "4) tempcontrol + SMM helper drop-in"
    local def="" c
    case $TRACK in
        fancontrol) def=1 ;;
        fancontrol-helper) def=2 ;;
        tempcontrol) def=3 ;;
    esac
    read -r -p "pick a track [${def:-none}]: " c < /dev/tty
    c=${c:-$def}
    case $c in
        1|2|3|4) ask_temps ;;
    esac
    case $c in
        1) install_fancontrol plain ;;
        2) install_fancontrol helper ;;
        3) install_tempcontrol plain ;;
        4) install_tempcontrol helper ;;
        *) echo "nothing installed" ;;
    esac
}

ask_temps() {
    local t
    load_temps
    read -r -p "fan start / full speed temperatures in C [$LOW $HIGH]: " t < /dev/tty
    if [ -n "$t" ]; then
        # shellcheck disable=SC2086
        set -- $t
        valid_temps "${1:-}" "${2:-}" || die "give two numbers, low then high, within 20-90 C"
        LOW=$1
        HIGH=$2
    fi
}

# fanoff: stop the daemon and command max explicitly. history independent -
# a plain daemon stop only restores whatever values it saved at start.
cmd_max() {
    gather
    if [ -z "$PWM" ] && [ -z "$I8KFAN" ]; then
        die "no pwm1 and no i8kfan - cannot set the fan"
    fi
    if [ "$FC" = active ]; then systemctl stop fancontrol; fi
    if [ "$TC" = active ]; then systemctl stop tempcontrol; fi
    sleep 1
    if [ -x "$HELPER_BIN" ]; then
        "$HELPER_BIN" 0 > /dev/null
    fi
    if [ -n "$PWM_ENABLE" ]; then
        echo 1 > "$PWM_ENABLE" 2>/dev/null || true
    fi
    fan_hi
    sleep 5
    echo "fan commanded to max, now at $(rpm_now || echo '?') rpm"
    echo "if that is not max, the EC has re-armed - run: dellfan probe"
}

cmd_auto() {
    gather
    if systemctl is-enabled fancontrol > /dev/null 2>&1; then
        systemctl start fancontrol
        echo "fancontrol running"
    elif systemctl is-enabled tempcontrol > /dev/null 2>&1; then
        systemctl start tempcontrol
        echo "tempcontrol running"
    else
        if [ -x "$HELPER_BIN" ]; then
            "$HELPER_BIN" 1 > /dev/null
        fi
        if [ -n "$PWM_ENABLE" ]; then
            echo 2 > "$PWM_ENABLE" 2>/dev/null || true
        fi
        echo "no fan daemon enabled - handed back to the EC"
    fi
}

cmd_temps() {
    gather
    load_temps
    if [ $# -eq 0 ]; then
        echo "fan starts at $LOW C, runs full from $HIGH C"
        if [ -f "$CONF_FILE" ]; then
            echo "set in $CONF_FILE - change with: dellfan temps <low> <high>"
        else
            echo "no $CONF_FILE yet - set one with: dellfan temps <low> <high>"
        fi
        return 0
    fi
    [ $# -eq 2 ] || die "usage: dellfan temps [<low> <high>]"
    valid_temps "$1" "$2" || die "give two numbers, low then high, within 20-90 C"
    LOW=$1
    HIGH=$2
    write_temps_conf
    apply_temps_fancontrol
    [ "$FC" = active ] && systemctl restart fancontrol
    [ "$TC" = active ] && systemctl restart tempcontrol
    echo "fan starts at $LOW C, runs full from $HIGH C"
}

cmd_status() {
    gather
    load_temps
    if [ -x "$HELPER_BIN" ]; then
        echo "helper:      $HELPER_BIN"
    else
        echo "helper:      not installed"
    fi
    if [ -f "$CONF_FILE" ]; then
        echo "temps:       fan from $LOW C, full from $HIGH C ($CONF_FILE)"
    else
        echo "temps:       fan from $LOW C, full from $HIGH C (defaults)"
    fi
    [ -f "$FC_DROPIN" ] && echo "drop-in:     $FC_DROPIN"
    [ -f "$TC_DROPIN" ] && echo "drop-in:     $TC_DROPIN"
    [ -f "$TC_UNIT" ] && echo "unit:        $TC_UNIT"
    [ -f "$ALIAS_FILE" ] && echo "aliases:     $ALIAS_FILE"
    [ -f /etc/modprobe.d/dellfan.conf ] && echo "module conf: /etc/modprobe.d/dellfan.conf"
    echo "services:    fancontrol=$FC tempcontrol=$TC i8kmon=$I8KMON"
    if [ -n "$HW" ]; then
        local p e
        p=$(cat "$PWM" 2>/dev/null || echo '-')
        e=$(cat "$PWM_ENABLE" 2>/dev/null || echo '-')
        echo "fan:         $(rpm_now || echo '?') rpm, pwm=$p, enable=$e"
    fi
    return 0
}

cmd_uninstall() {
    gather
    confirm "remove everything dellfan installed?" || return 0
    local changed=""
    if [ -f "$FC_DROPIN" ]; then
        rm -f "$FC_DROPIN"
        rmdir --ignore-fail-on-non-empty "$(dirname "$FC_DROPIN")"
        changed=1
        echo "removed $FC_DROPIN"
    fi
    if [ -f "$TC_DROPIN" ]; then
        rm -f "$TC_DROPIN"
        rmdir --ignore-fail-on-non-empty "$(dirname "$TC_DROPIN")"
        changed=1
        echo "removed $TC_DROPIN"
    fi
    if [ -f "$TC_UNIT" ]; then
        systemctl disable --now tempcontrol 2> /dev/null || true
        rm -f "$TC_UNIT" "$TC_SCRIPT"
        changed=1
        echo "removed tempcontrol"
    fi
    if [ -x "$HELPER_BIN" ]; then
        "$HELPER_BIN" 1 > /dev/null
        rm -f "$HELPER_BIN"
        echo "BIOS control re-enabled, removed $HELPER_BIN"
    fi
    if [ -f "$ALIAS_FILE" ]; then
        rm -f "$ALIAS_FILE"
        echo "removed $ALIAS_FILE"
    fi
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo "removed $CONF_FILE"
    fi
    if [ -f /usr/local/bin/dellfan ]; then
        rm -f /usr/local/bin/dellfan
        echo "removed /usr/local/bin/dellfan"
    fi
    if [ -f /etc/modprobe.d/dellfan.conf ] || [ -f /etc/modules-load.d/dellfan.conf ]; then
        rm -f /etc/modprobe.d/dellfan.conf /etc/modules-load.d/dellfan.conf
        echo "removed module config (module left loaded)"
    fi
    if [ -f /etc/fancontrol ] && head -1 /etc/fancontrol | grep -q "written by dellfan"; then
        rm -f /etc/fancontrol
        echo "removed generated /etc/fancontrol"
    fi
    if [ -n "$changed" ]; then
        systemctl daemon-reload
        if [ "$FC" = active ] && [ -f /etc/fancontrol ]; then
            systemctl restart fancontrol
        fi
    fi
}

menu_temps() {
    local t
    cmd_temps
    read -r -p "new values, low then high (enter keeps current): " t < /dev/tty
    if [ -n "$t" ]; then
        # shellcheck disable=SC2086
        cmd_temps $t
    fi
}

cmd_menu() {
    local c
    while :; do
        echo
        echo "dellfan: 1 detect  2 probe  3 install  4 status  5 temps  6 uninstall  q quit"
        read -r -p "> " c < /dev/tty
        case $c in
            1) cmd_detect ;;
            2) cmd_probe ;;
            3) cmd_install ;;
            4) cmd_status ;;
            5) menu_temps ;;
            6) cmd_uninstall ;;
            q|Q) return 0 ;;
        esac
    done
}

usage() {
    echo "usage: ${0##*/} [detect|probe|install|status|temps|uninstall|max|auto]"
    echo "temps shows the control temperatures, temps <low> <high> sets them"
    echo "run without arguments for a menu"
}

main() {
    case "${1:-}" in
        -h|--help|help)
            usage
            return 0 ;;
    esac
    [ "$(id -u)" = 0 ] || die "run as root"
    case "${1:-}" in
        "") cmd_menu ;;
        detect) cmd_detect ;;
        probe) cmd_probe ;;
        install) cmd_install ;;
        status) cmd_status ;;
        temps) shift; cmd_temps "$@" ;;
        uninstall) cmd_uninstall ;;
        max) cmd_max ;;
        auto) cmd_auto ;;
        *) usage; return 1 ;;
    esac
}

main "$@"
