#!/usr/bin/env bash
# Install (or update) the Pi's network keepers: the Wi-Fi watchdog, the avahi
# name check, and a persistent system log. Run from the Mac; needs sudo on the Pi.
#
#   OWL_WIFI="Home 5G" OWL_WIFI_BACKUP="Home" recorder/system/install.sh
#
# OWL_WIFI / OWL_WIFI_BACKUP are NetworkManager connection names (nmcli con);
# leave the backup out if there's only one link. OWL_WIFI_DRIVER is the USB
# Wi-Fi adapter's kernel module, reloaded if reconnecting doesn't help.
# Without these, settings already on the Pi are kept.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${OWL_HOST:-nightowl}"

echo "Installing the network keepers on $HOST"
scp -q "$HERE/wifi-watchdog.sh" "$HERE/avahi-name-check.sh" "$HERE/90-avahi-name" "$HERE/journald-persistent.conf" "$HOST:/tmp/"
ssh "$HOST" "set -e
  sudo install -m 755 /tmp/wifi-watchdog.sh /tmp/avahi-name-check.sh /usr/local/sbin/
  sudo install -m 755 /tmp/90-avahi-name /etc/NetworkManager/dispatcher.d/
  sudo install -d /etc/systemd/journald.conf.d
  sudo install -m 644 /tmp/journald-persistent.conf /etc/systemd/journald.conf.d/persistent.conf
  sudo systemctl restart systemd-journald
  echo '*/2 * * * * root /usr/local/sbin/wifi-watchdog.sh' | sudo tee /etc/cron.d/wifi-watchdog >/dev/null
  if [ -n '${OWL_WIFI:-}' ] || [ ! -e /etc/default/nightowl-wifi ]; then
    printf 'WIFI_CON=%q\nWIFI_DEV=%q\nBACKUP_CON=%q\nBACKUP_DEV=%q\nWIFI_DRIVER=%q\n' \
      '${OWL_WIFI:-}' '${OWL_WIFI_DEV:-wlan1}' '${OWL_WIFI_BACKUP:-}' '${OWL_WIFI_BACKUP_DEV:-wlan0}' '${OWL_WIFI_DRIVER:-}' \
      | sudo tee /etc/default/nightowl-wifi >/dev/null
  fi
  rm -f /tmp/wifi-watchdog.sh /tmp/avahi-name-check.sh /tmp/90-avahi-name /tmp/journald-persistent.conf
  echo settings:; cat /etc/default/nightowl-wifi"
echo "Done. Log on the Pi: /var/log/wifi-watchdog.log"
