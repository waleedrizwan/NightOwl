#!/bin/bash
# Runs every 2 min (cron). Keeps the Pi on the network: if the router stops
# answering, reconnect Wi-Fi, then the backup link, then restart networking,
# then reload the USB Wi-Fi driver, then reboot as a last resort.
# Settings (connection names, driver) are in /etc/default/nightowl-wifi.
LOG=/var/log/wifi-watchdog.log
STATE=/run/wifi-watchdog.fails
WIFI_CON="" WIFI_DEV=wlan1 BACKUP_CON="" BACKUP_DEV=wlan0 WIFI_DRIVER=""
[ -r /etc/default/nightowl-wifi ] && . /etc/default/nightowl-wifi
gw=$(ip route | awk '/^default/ {print $3; exit}')
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

/usr/local/sbin/avahi-name-check.sh

if [ -n "$gw" ] && ping -c 3 -W 2 "$gw" >/dev/null 2>&1; then
  [ -s "$STATE" ] && log "network back after $(cat "$STATE") failed checks"
  rm -f "$STATE"
  # Two links on one subnet break LAN traffic: keep the backup off while the main one works.
  if [ -n "$BACKUP_CON" ] && ip route | grep -q "^default.*dev $WIFI_DEV" \
     && nmcli -t -f DEVICE,STATE dev | grep -q "^$BACKUP_DEV:connected"; then
    log "$WIFI_DEV is up; disconnecting backup $BACKUP_DEV"; nmcli dev disconnect "$BACKUP_DEV" >/dev/null
  fi
  exit 0
fi

fails=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )); echo "$fails" > "$STATE"
log "can't reach ${gw:-the router} (fail $fails); $(ip -br addr | tr '\n' ' ')"
dmesg | tail -20 >> "$LOG"

case $fails in
  1)   [ -n "$WIFI_CON" ] && nmcli con up "$WIFI_CON" >>"$LOG" 2>&1 ;;
  2)   if [ -n "$BACKUP_CON" ]; then
         log "trying the backup link"
         [ -n "$WIFI_CON" ] && nmcli con down "$WIFI_CON" >>"$LOG" 2>&1
         nmcli con up "$BACKUP_CON" >>"$LOG" 2>&1
       fi ;;
  3)   log "restarting NetworkManager"; systemctl restart NetworkManager ;;
  4)   if [ -n "$WIFI_DRIVER" ]; then
         log "reloading Wi-Fi driver"; modprobe -r "$WIFI_DRIVER"; sleep 2; modprobe "$WIFI_DRIVER"
       fi
       systemctl restart NetworkManager ;;
  *)   log "rebooting"; sync; systemctl reboot ;;
esac
