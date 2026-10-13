#!/bin/bash
IFACE=${IFACE:-wlp2s0}
INTERVAL=${INTERVAL:-60}
DIR=/textfile
NAMES=/names.txt
OUT=$DIR/lan_devices.prom

while true; do
  TMP=$(mktemp "$DIR/.lan.XXXXXX")
  arp-scan --interface="$IFACE" --localnet -x --retry=3 2>/dev/null | sort -u -k2,2 > /tmp/arp.txt
  {
    echo "# HELP lan_device_up Device seen in ARP scan"
    echo "# TYPE lan_device_up gauge"
    while IFS=$'\t' read -r ip mac vendor; do
      name=$(awk -v m="$mac" 'tolower($1)==tolower(m){ $1=""; sub(/^ +/,""); print; exit }' "$NAMES" 2>/dev/null)
      name=${name:-$mac}
      vendor=${vendor//\"/}
      echo "lan_device_up{ip=\"$ip\",mac=\"$mac\",name=\"$name\",vendor=\"$vendor\"} 1"
    done < /tmp/arp.txt
    echo "# TYPE lan_devices_total gauge"
    echo "lan_devices_total $(wc -l < /tmp/arp.txt)"
    echo "# TYPE lan_scan_last_timestamp gauge"
    echo "lan_scan_last_timestamp $(date +%s)"
  } > "$TMP"
  chmod 644 "$TMP" && mv "$TMP" "$OUT"
  sleep "$INTERVAL"
done
