# Shared by install.sh and uninstall.sh: both need the device in rooted Android, but it may be running MU300 Linux
# right now (then there is no adb device, only SSH on the USB network). Offer to send it back to Android.
# Uses: say(), die(), ask()

MU300_IP=${MU300_IP:-192.168.77.1}

# true when something answers on the Linux SSH port of the USB network
linux_mode_running() {
    command -v nc >/dev/null || return 1
    nc -z -G 3 -w 3 "$MU300_IP" 22 >/dev/null 2>&1
}

# ask the running Linux to boot Android next and reboot; then wait for adb
linux_mode_to_android() {
    say "The device is running MU300 Linux, not Android"
    echo "  Installing and uninstalling happen from Android (slot a), so the device has to reboot first."
    echo "  I can ask it over SSH; you will be prompted for its password."
    ask go "Reboot the device into Android now? (yes/no)" yes
    [ "$go" = yes ] || die "boot Android yourself (in Linux: sudo mu300-next-boot android && sudo reboot)"
    for user in ubuntu root; do
        echo "  trying $user@$MU300_IP"
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 \
             "$user@$MU300_IP" 'command -v sudo >/dev/null && sudo mu300-next-boot android || mu300-next-boot android; sync; (sleep 2; reboot) >/dev/null 2>&1 &' 2>/dev/null; then
            break
        fi
    done
    echo "  waiting for Android"
    n=0
    while [ $n -lt 60 ]; do
        [ "$(adb get-state 2>/dev/null)" = device ] && { echo "  Android is up"; return 0; }
        n=$((n + 1)); sleep 5
    done
    die "the device did not come back as Android; boot it yourself (mu300-next-boot android)"
}

# call before anything else that needs adb
require_android() {
    [ "$(adb get-state 2>/dev/null)" = device ] && return 0
    linux_mode_running && linux_mode_to_android && return 0
    die "no adb device (boot Android, enable USB debugging)"
}
