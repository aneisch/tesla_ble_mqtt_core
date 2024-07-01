#!/bin/ash

send_command() {
 vin=$1
 shift
 for i in $(seq 5); do
  log_notice "Sending command $@ to vin $vin, attempt $i/5"
  set +e
  message=$(tesla-control -vin $vin -ble -key-name /share/tesla_ble_mqtt/${vin}_private.pem -key-file /share/tesla_ble_mqtt/${vin}_private.pem $@ 2>&1)
  EXIT_STATUS=$?
  set -e
  if [ $EXIT_STATUS -eq 0 ]; then
    log_info "tesla-control send command succeeded"
    break
  else
        if [[ $message == *"Failed to execute command: car could not execute command"* ]]; then
         log_error $message
         log_notice "Skipping command $@ to vin $vin"
         break
        else
     log_error "tesla-control send command failed exit status $EXIT_STATUS."
         log_info $message
         log_notice "Retrying in $SEND_CMD_RETRY_DELAY seconds"
        fi
    sleep $SEND_CMD_RETRY_DELAY
  fi
 done
}

# Tesla VIN to BLE Local Name
tesla_vin2ble_ln() {
  TESLA_VIN=$1
  BLE_LN=""

  log_debug "Calculating BLE Local Name for Tesla VIN $TESLA_VIN"
  VIN_HASH="$(echo -n ${TESLA_VIN} | sha1sum)"
  # BLE Local Name
  BLE_LN="S${VIN_HASH:0:16}C"
  log_debug "BLE Local Name for Tesla VIN $TESLA_VIN is $BLE_LN"

  echo $BLE_LN

}

listen_to_ble() {
  n_cars={$1:-3}

  log_notice "Listening to BLE for presence"
  log_warning "Doesn't support to deprecate previous TESLA_VIN usage"
  PRESENCE_TIMEOUT=10
  set +e
  BLTCTL_OUT=$(bluetoothctl --timeout $PRESENCE_TIMEOUT scan on | grep $BLE_MAC1 2>&1)
  set -e
  log_debug "${BLTCTL_OUT}"
  for count in $(seq $n_cars); do
    BLE_LN=$(eval echo "echo \$BLE_LN${count}")
    BLE_MAC=$(eval "echo \$BLE_MAC${count}")
    PRESENCE_EXPIRES_TIME=$(eval "echo \$PRESENCE_EXPIRES_TIME${count}")
    TESLA_VIN=$(eval "echo \$TESLA_VIN${count}")

    MQTT_TOPIC="tesla_ble_mqtt/$TESLA_VIN/binary_sensor/presence"

    if echo "$(BLTCTL_OUT)" | grep -q $BLE_MAC; then
      log_info "BLE MAC $BLE_MAC presence detected, setting presence ON""
      # We need a function for mosquitto_pub w/ retry
      set +e
      MQTT_OUT=$(mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" --nodelay -t "$MQTT_TOPIC" -m ON 2>&1)
      EXIT_CODE=$?
      set -e
      [ $EXIT_CODE -ne 0 ] \
        && log_error "$(MQTT_OUT)" \
        && continue
      log_info "mqtt topic "$MQTT_TOPIC" succesfully updated to ON"
    elif echo "$(BLTCTL_OUT)" | grep -q ${TESLA_VIN}; then
      log_info "TESLA VIN $TESLA_VIN presence detected, setting presence ON""
      # We need a function for mosquitto_pub w/ retry
      set +e
      MQTT_OUT=$(mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" --nodelay -t "$MQTT_TOPIC" -m ON 2>&1)
      EXIT_CODE=$?
      set -e
      [ $EXIT_CODE -ne 0 ] \
        && log_error "$(MQTT_OUT)" \
        && continue
      log_info "mqtt topic "$MQTT_TOPIC" succesfully updated to ON"
    else
      log_info "VIN $TESLA_VIN and MAC $BLE_MAC presence not detected, setting presence OFF""
      set +e
      MQTT_OUT=$(mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" --nodelay -t "$MQTT_TOPIC" -m OFF 2>&1)
      set -e
      [ $EXIT_CODE -ne 0 ] \
        && log_error "$(MQTT_OUT)" \
        && continue
      log_info "mqtt topic "$MQTT_TOPIC" succesfully updated to OFF"
    fi
  done
}

send_key() {
 vin=$1
 for i in $(seq 5); do
  echo "Attempt $i/5"
  set +e
  tesla-control -ble -vin $vin add-key-request /share/tesla_ble_mqtt/${vin}_public.pem owner cloud_key
  EXIT_STATUS=$?
  set -e
  if [ $EXIT_STATUS -eq 0 ]; then
    log_notice "KEY SENT TO VEHICLE: PLEASE CHECK YOU TESLA'S SCREEN AND ACCEPT WITH YOUR CARD"
    break
  else
    log_notice "COULD NOT SEND THE KEY. Is the car awake and sufficiently close to the bluetooth device?"
    sleep $SEND_CMD_RETRY_DELAY
  fi
 done
}

scan_bluetooth(){
  log_notice "Calculating BLE Advert ${BLE_ADVERT} from VIN"
  log_notice "Scanning Bluetooth for $BLE_ADVERT, wait 10 secs"
  bluetoothctl --timeout 10 scan on | grep $BLE_ADVERT
  log_warning "More work needed on this"
}

delete_legacies(){
  log_notice "Deleting Legacy MQTT Topics"
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/switch/tesla_ble/sw-heater/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/switch/tesla_ble/sentry-mode/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/select/tesla_ble/heated_seat_left/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/select/tesla_ble/heated_seat_right/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/binary_sensor/tesla_ble/presence/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/number/tesla_ble/charging-set-amps/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/number/tesla_ble/charging-set-limit/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/number/tesla_ble/climate-temp/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/generate_keys/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/deploy_key/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/scan_bluetooth/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/wake/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/flash-lights/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/honk/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/lock/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/unlock/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/auto-seat-climate/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/climate-on/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/climate-off/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/trunk-open/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/trunk-close/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/frunk-open/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/charging-start/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/charging-stop/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/charge-port-open/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/charge-port-close/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/windows-close/config -n
  mosquitto_pub -h $MQTT_IP -p $MQTT_PORT -u "${MQTT_USER}" -P "${MQTT_PWD}" -t homeassistant/button/tesla_ble/windows-vent/config -n

  if [ -f /share/tesla_ble_mqtt/private.pem ]; then
    log_notice "Renaming legacy keys"
    mv /share/tesla_ble_mqtt/private.pem /share/tesla_ble_mqtt/${TESLA_VIN1}_private.pem
    mv /share/tesla_ble_mqtt/public.pem /share/tesla_ble_mqtt/${TESLA_VIN1}_public.pem
  fi

}
