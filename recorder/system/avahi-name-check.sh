#!/bin/bash
# After a Wi-Fi reconnect avahi sometimes sees its own old record, calls it a
# conflict and renames the Pi <name>-2.local; the phone looks for <name>.local.
# Put the name back. Run by the watchdog and by NetworkManager on reconnect.
want="$(hostname).local"
have=$(busctl call org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetHostNameFqdn 2>/dev/null | cut -d'"' -f2)
if [ -n "$have" ] && [ "$have" != "$want" ]; then
  echo "$(date '+%F %T') avahi was $have; restarting" >> /var/log/wifi-watchdog.log
  systemctl restart avahi-daemon
fi
