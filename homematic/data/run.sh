#!/usr/bin/env bashio
# shellcheck disable=SC1091
set -e

WAIT_PIDS=()

# Init folder
mkdir -p /share/hm-firmware
mkdir -p /share/hmip-firmware
mkdir -p /data/crRFD
mkdir -p /data/rfd
mkdir -p /data/hs485d
mkdir -p /data/userprofiles

ln -s /data/userprofiles /etc/config/userprofiles

# Init files
touch /data/hmip_user.conf
touch /data/rega_user.conf
touch /data/homematic.regadom
touch /data/userprofiles/userAckInstallWizard_Admin

# Import helpers
. /usr/lib/hm-firmware.sh
. /usr/lib/hm-interface.sh

# Setup Interfaces
init_interface_list "$(bashio::config 'rf_enable')" \
    "$(bashio::config 'hmip_enable')" \
    "$(bashio::config 'wired_enable')"

# RF support
if bashio::config.true 'rf_enable'; then
    for rf_device in $(bashio::config 'rf|keys'); do
        TYPE=$(bashio::config "rf[${rf_device}].type")

        # Update config
        if [ "$TYPE" == "CCU2" ]; then
            DEVICE=$(bashio::config "rf[${rf_device}].device")
            (
                echo "[Interface $1]"
                echo "Type = CCU2"
                echo "ComPortFile = $DEVICE"
                echo "AccessFile = /dev/null"
                echo "ResetFile = /sys/class/gpio/gpio18/value"
            ) >> /etc/config/rfd.conf

            # Init GPIO
            if [ ! -d /sys/class/gpio/gpio18 ]; then
                echo 18 > /sys/class/gpio/export
                sleep 2
            fi
            if [ "$(cat /sys/class/gpio/gpio18/direction)" != "out" ]; then
                echo out > /sys/class/gpio/gpio18/direction
                sleep 2
            fi

            echo 0 > /sys/class/gpio/gpio18/value || echo "Can't set default value!"
            sleep 0.5
        fi
    done

    # Update Firmware
	if bashio::config.true 'rf[${rf_device}].update'; then
		firmware_update_rfd
	else
        bashio::log.info "RFd update is disabled"
    fi

    # Run RFD
    "$HM_HOME/bin/rfd" -c -l 0 -f /opt/hm/etc/config/rfd.conf &
    WAIT_PIDS+=($!)
fi

# Wired support
if bashio::config.true 'wired_enable'; then
    for wired_device in $(bashio::config 'wired|keys'); do
        SERIAL=$(bashio::config "wired[${wired_device}].serial")
        KEY=$(bashio::config "wired[${wired_device}].key")
        IP=$(bashio::config "wired[${wired_device}].ip")

        # Update config
        (
            echo "[Interface $1]"
            echo "Type = HMWLGW"
            echo "Serial Number = $SERIAL"
            echo "Encryption Key = $KEY"
            echo "IP Address = $IP"
        ) >> /etc/config/hs485d.conf
    done

    # Update Firmware
    firmware_update_wired

    # Run hs485d
    "$HM_HOME/bin/hs485d" -g -i 0 -f /opt/hm/etc/config/hs485d.conf &
    WAIT_PIDS+=($!)
fi

# HMIP support
if bashio::config.true 'hmip_enable'; then
    # Restore data
    if [ -f /data/hmip_address.conf ]; then
        cp -f /data/hmip_address.conf /etc/config/
    fi

    # Setup settings
    for hmip_device in $(bashio::config 'hmip|keys'); do
        TYPE=$(bashio::config "hmip[${hmip_device}].type")
        DEVICE=$(bashio::config "hmip[${hmip_device}].device")
        ADAPTER=$((hmip_device+1))

        # Update Firmware
        firmware_update_hmip "${DEVICE}"

        # Update config
        (
            echo "Adapter.${ADAPTER}.Type=${TYPE}"
            echo "Adapter.${ADAPTER}.Port=${DEVICE}"
        ) >> /etc/config/crRFD.conf
    done

    # Run HMIPServer
    # shellcheck disable=SC2086
    java -Xmx64m -Dlog4j.configuration=file:///etc/config/log4j.xml -Dfile.encoding=ISO-8859-1 -jar /opt/HMServer/HMIPServer.jar /etc/config/crRFD.conf /etc/config/HMServer.conf &
    WAIT_PIDS+=($!)

    if [ ! -f /data/hmip_address.conf ]; then
        sleep 30
        cp -f /etc/config/hmip_address.conf /data/
    fi
else
    java -Xmx64m -Dlog4j.configuration=file:///etc/config/log4j.xml -Dfile.encoding=ISO-8859-1 -jar /opt/HMServer/HMServer.jar /etc/config/HMServer.conf &
    WAIT_PIDS+=($!)
fi

# Register stop
function stop_homematic() {
    bashio::log.info "Kill Processes..."
    kill -15 "${WAIT_PIDS[@]}"
    wait "${WAIT_PIDS[@]}"
    bashio::log.info "Done."
}
trap "stop_homematic" SIGTERM SIGHUP

# Wait until interfaces are initialized
sleep 30

# Start Regahss
"$HM_HOME/bin/ReGaHss" -f /etc/config/rega.conf &
WAIT_PIDS+=($!)

# Start WebInterface
openssl req -new -x509 -nodes -keyout /etc/config/server.pem -out /etc/config/server.pem -days 3650 -subj "/C=DE/O=HomeMatic/OU=Hass.io/CN=$(hostname)"
lighttpd-angel -D -f /opt/hm/etc/lighttpd/lighttpd.conf &
WAIT_PIDS+=($!)

# Sync time periodically
if bashio::config.true 'rf_enable'; then
    while true
    do
        sleep 30m
        bashio::log.info "$(date '+%Y-%m-%d %H:%M:%S.%3N') Run SetInterfaceClock now."
        "$HM_HOME/bin/SetInterfaceClock" 127.0.0.1:2001
    done
fi

# Wait until all is done
wait "${WAIT_PIDS[@]}"
