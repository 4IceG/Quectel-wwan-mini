#!/bin/sh
[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_quectel_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_string "apn"
	proto_config_add_string "auth"
	proto_config_add_string "username"
	proto_config_add_string "password"
	proto_config_add_string "pincode"
	proto_config_add_int "delay"
	proto_config_add_string "pdptype"
	proto_config_add_boolean "dhcp"
	proto_config_add_boolean "dhcpv6"
	proto_config_add_boolean "sourcefilter"
	proto_config_add_boolean "delegate"
	proto_config_add_int "mtu"
	proto_config_add_int "dhcp_timeout"
	proto_config_add_int "max_retries"
	proto_config_add_defaults
}

wait_for_device() {
	local device="$1"
	local timeout=60
	local count=0

	while [ $count -lt $timeout ]; do
		if [ -c "$device" ]; then
			return 0
		fi
		sleep 1
		count=$((count + 1))
	done
	return 1
}

wait_for_interface() {
	local devpath="$1"
	local timeout=60
	local count=0

	while [ $count -lt $timeout ]; do
		local ifname="$(ls "$devpath/net" 2>/dev/null | head -n1)"
		if [ -n "$ifname" ]; then
			echo "$ifname"
			return 0
		fi
		sleep 1
		count=$((count + 1))
	done
	return 1
}

wait_for_mhi_interface() {
	local timeout=60
	local count=0

	while [ $count -lt $timeout ]; do
		for iface in /sys/class/net/rmnet_mhi*; do
			if [ -d "$iface" ]; then
				local ifname="$(basename "$iface")"
				if [ "$ifname" != "rmnet_mhi*" ]; then
					echo "$ifname"
					return 0
				fi
			fi
		done
		sleep 1
		count=$((count + 1))
	done
	return 1
}

detect_qmi_device() {
	local qmi_device=""
	
	if [ -c "/dev/cdc-wdm0" ]; then
		qmi_device="/dev/cdc-wdm0"
	elif [ -c "/dev/mhi_QMI0" ]; then
		qmi_device="/dev/mhi_QMI0"
	fi
	
	echo "$qmi_device"
}

find_modem_port() {
	local port=""
	
	for tty in /dev/ttyUSB* /dev/mhi_DUN; do
		if [ -c "$tty" ]; then
			if command -v sms_tool >/dev/null 2>&1; then
				if timeout 3 sms_tool -d "$tty" at "ATI" >/dev/null 2>&1; then
					echo "$tty"
					return 0
				fi
			fi
		fi
	done
	
	return 1
}

reset_modem() {
	echo "Searching for modem AT command port..."
	local modem_port=$(find_modem_port)
	
	if [ -z "$modem_port" ]; then
		echo "No responsive modem port found, skipping reset"
		return 1
	fi
	
	echo "Found modem port: $modem_port"
	echo "Resetting modem with AT+CFUN=1,1..."
	
	if command -v sms_tool >/dev/null 2>&1; then
		sms_tool -d "$modem_port" at "AT+CFUN=1,1" >/dev/null 2>&1
	else
		echo "sms_tool not available, skipping reset"
		return 1
	fi
	
	echo "Waiting for modem reset to complete..."
	sleep 15
	return 0
}

restart_dhcp_client() {
	local ifname="$1"
	echo "Restarting DHCP client on $ifname"
	
	killall -TERM udhcpc 2>/dev/null
	sleep 2
	killall -9 udhcpc 2>/dev/null
	
	ip addr flush dev "$ifname" 2>/dev/null
	ip route flush dev "$ifname" 2>/dev/null
	
	udhcpc -i "$ifname" -b -p "/var/run/udhcpc-$ifname.pid" >/dev/null 2>&1 &
	sleep 3
}

get_dns_from_resolv() {
	local ifname="$1"
	local dns_list=""

	if [ -f "/etc/resolv.conf" ]; then
		dns_list=$(grep "nameserver.*# IPV4 $ifname" /etc/resolv.conf | awk '{print $2}')

		if [ -z "$dns_list" ]; then
			dns_list=$(grep "nameserver.*# IPV6 $ifname" /etc/resolv.conf | awk '{print $2}')
		fi

		if [ -z "$dns_list" ]; then
			dns_list=$(grep "nameserver.*$ifname" /etc/resolv.conf | awk '{print $2}')
		fi
	fi

	echo "$dns_list"
}

remove_dns_from_resolv() {
	local ifname="$1"

	if [ -f "/etc/resolv.conf" ]; then
		sed -i "/nameserver.*# IPV4 $ifname/d" /etc/resolv.conf
		sed -i "/nameserver.*# IPV6 $ifname/d" /etc/resolv.conf
		sed -i "/nameserver.*$ifname/d" /etc/resolv.conf
	fi
}

get_interface_config() {
	local ifname="$1"
	local timeout="${2:-30}"
	local retry_num="${3:-0}"
	local count=0

	echo "Waiting for DHCP configuration on $ifname (timeout: ${timeout}s, attempt: $((retry_num + 1)))"

	while [ $count -lt $timeout ]; do
		local ipv4_cidr=$(ip -4 addr show dev "$ifname" 2>/dev/null | grep 'inet.*scope global' | head -1 | awk '{print $2}')
		if [ -n "$ipv4_cidr" ]; then
			v4address="${ipv4_cidr%/*}"
			v4netmask="${ipv4_cidr#*/}"
			v4gateway=$(ip -4 route show dev "$ifname" 2>/dev/null | grep default | awk '{print $3}' | head -1)

			local dns_servers=$(get_dns_from_resolv "$ifname")
			if [ -n "$dns_servers" ]; then
				v4dns1=$(echo "$dns_servers" | head -1)
				v4dns2=$(echo "$dns_servers" | sed -n '2p')
			fi

			local ipv6_addr=$(ip -6 addr show dev "$ifname" 2>/dev/null | grep 'inet6.*scope global' | head -1 | awk '{print $2}')
			if [ -n "$ipv6_addr" ]; then
				v6address="$ipv6_addr"
				v6gateway=$(ip -6 route show dev "$ifname" 2>/dev/null | grep "default dev $ifname" | awk '{print $5}' | head -1)
				if [ -z "$v6gateway" ]; then
					v6gateway=$(ip -6 route show dev "$ifname" 2>/dev/null | grep "default via" | awk '{print $3}' | head -1)
				fi
			fi

			if [ -n "$v4address" ] && [ -n "$v4gateway" ]; then
				echo "Interface configuration detected"
				echo "IPv4: $v4address/$v4netmask via $v4gateway"
				[ -n "$v4dns1" ] && echo "DNS: $v4dns1 $v4dns2"
				[ -n "$v6address" ] && echo "IPv6: $v6address"
				return 0
			fi
		fi
		
		if [ $((count % 10)) -eq 0 ] && [ $count -gt 0 ]; then
			echo "Still waiting for IP configuration... ($count/${timeout}s)"
		fi
		
		sleep 1
		count=$((count + 1))
	done
	
	echo "DHCP timeout after ${timeout} seconds"
	return 1
}

update_IPv4() {
	echo "Updating IPv4 configuration"
	proto_init_update "$ifname" 1

	if [ "$v4netmask" -gt 0 ] && [ "$v4netmask" -le 32 ]; then
		proto_add_ipv4_address "$v4address" "$v4netmask"
	else
		proto_add_ipv4_address "$v4address" "32"
	fi

	[ -n "$v4gateway" ] && proto_add_ipv4_route "$v4gateway" "32"
	[ "$defaultroute" = 0 ] || proto_add_ipv4_route "0.0.0.0" 0 "$v4gateway"

	[ "$peerdns" = 0 ] || {
		[ -n "$v4dns1" ] && proto_add_dns_server "$v4dns1"
		[ -n "$v4dns2" ] && proto_add_dns_server "$v4dns2"
	}

	[ -n "$zone" ] && {
		proto_add_data
		json_add_string zone "$zone"
		proto_close_data
	}

	proto_send_update "$interface"
}

update_IPv6() {
	echo "Creating IPv6 dynamic interface"

	if ubus call network.interface.${interface}6 status >/dev/null 2>&1; then
		echo "Removing existing IPv6 interface"
		ubus call network.interface.${interface}6 down 2>/dev/null
		sleep 1
		ubus call network del_dynamic "{\"name\": \"${interface}6\"}" 2>/dev/null
		sleep 1
	fi

	json_init
	json_add_string name "${interface}6"
	json_add_string ifname "@$interface"
	json_add_string proto "dhcpv6"
	proto_add_dynamic_defaults
	json_add_string extendprefix 1

	[ "$peerdns" = 0 ] || {
		if [ -n "$v6dns1" ] || [ -n "$v6dns2" ]; then
			json_add_array dns
			[ -n "$v6dns1" ] && json_add_string "" "$v6dns1"
			[ -n "$v6dns2" ] && json_add_string "" "$v6dns2"
			json_close_array
		fi
	}

	[ -n "$zone" ] && json_add_string zone "$zone"
	json_close_object
	ubus call network add_dynamic "$(json_dump)"

	sleep 2
	ubus call network.interface.${interface}6 up 2>/dev/null
}

monitor_interface_changes() {
	local interface="$1"
	local ifname="$2"
	local last_v4address=""
	local last_v6address=""

	while true; do
		sleep 10

		if ! ip link show "$ifname" >/dev/null 2>&1; then
			echo "Interface $ifname disappeared, stopping monitor"
			break
		fi

		local current_v4=$(ip -4 addr show dev "$ifname" 2>/dev/null | grep 'inet.*scope global' | head -1 | awk '{print $2}')
		local current_v6=$(ip -6 addr show dev "$ifname" 2>/dev/null | grep 'inet6.*scope global' | head -1 | awk '{print $2}')

		if [ -n "$current_v4" ] && [ "$current_v4" != "$last_v4address" ]; then
			echo "IPv4 change detected on $ifname: $current_v4"

			v4address="${current_v4%/*}"
			v4netmask="${current_v4#*/}"
			v4gateway=$(ip -4 route show dev "$ifname" 2>/dev/null | grep default | awk '{print $3}' | head -1)

			local dns_servers=$(get_dns_from_resolv "$ifname")
			if [ -n "$dns_servers" ]; then
				v4dns1=$(echo "$dns_servers" | head -1)
				v4dns2=$(echo "$dns_servers" | sed -n '2p')
			else
				v4dns1="8.8.8.8"
				v4dns2="8.8.4.4"
			fi

			zone="$(fw3 -q network "$interface" 2>/dev/null)"
			defaultroute=1
			peerdns=1

			update_IPv4
			last_v4address="$current_v4"
		fi

		if [ -n "$current_v6" ] && [ "$current_v6" != "$last_v6address" ]; then
			echo "IPv6 change detected on $ifname: $current_v6"
			update_IPv6
			last_v6address="$current_v6"
		fi
	done
}

find_actual_interface() {
	local base_ifname="$1"
	local timeout=30
	local count=0

	while [ $count -lt $timeout ]; do
		if ip link show "${base_ifname}.1" >/dev/null 2>&1; then
			echo "${base_ifname}.1"
			return 0
		elif ip link show "$base_ifname" >/dev/null 2>&1; then
			local has_ip=$(ip -4 addr show dev "$base_ifname" 2>/dev/null | grep 'inet.*scope global')
			if [ -n "$has_ip" ]; then
				echo "$base_ifname"
				return 0
			fi
		fi
		sleep 1
		count=$((count + 1))
	done
	return 1
}

proto_quectel_setup() {
	local interface="$1"
	local device apn auth username password pincode delay pdptype
	local dhcp dhcpv6 sourcefilter delegate mtu dhcp_timeout max_retries
	local $PROTO_DEFAULT_OPTIONS
	local ip4table ip6table
	local ifname devname devpath qmi_device base_ifname

	json_get_vars device apn auth username password pincode delay
	json_get_vars pdptype dhcp dhcpv6 sourcefilter delegate ip4table
	json_get_vars ip6table mtu dhcp_timeout max_retries $PROTO_DEFAULT_OPTIONS

	[ -n "$delay" ] && sleep "$delay"
	[ -n "$metric" ] || metric="0"
	[ -z "$ctl_device" ] || device="$ctl_device"
	[ -n "$pdptype" ] || pdptype="ipv4v6"
	[ -n "$dhcp_timeout" ] || dhcp_timeout="30"
	[ -n "$max_retries" ] || max_retries="3"

	[ -n "$device" ] || {
		echo "No control device specified"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	}

	echo "Waiting for control device: $device"
	if ! wait_for_device "$device"; then
		echo "Control device $device not found"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	fi

	echo "Detecting QMI control device"
	qmi_device="$(detect_qmi_device)"
	
	if [ -z "$qmi_device" ]; then
		echo "QMI control device not found"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	fi
	
	echo "Using QMI device: $qmi_device"

	if [ "$qmi_device" = "/dev/mhi_QMI0" ]; then
		echo "MHI device detected, waiting for rmnet interface"
		base_ifname="$(wait_for_mhi_interface)"
		[ -n "$base_ifname" ] || {
			echo "MHI network interface not found"
			proto_notify_error "$interface" NO_IFACE
			proto_set_available "$interface" 0
			return 1
		}
		echo "Found MHI base interface: $base_ifname"
	else
		device="$(readlink -f "$device")"
		devname="$(basename "$device")"
		devpath="$(readlink -f "/sys/class/usbmisc/$devname/device/")"

		echo "Waiting for network interface in $devpath"
		base_ifname="$(wait_for_interface "$devpath")"

		[ -n "$base_ifname" ] || {
			echo "Network interface not found"
			proto_notify_error "$interface" NO_IFACE
			proto_set_available "$interface" 0
			return 1
		}
		echo "Found network interface: $base_ifname"
	fi

	[ "$pdptype" = "ipv4" -o "$pdptype" = "ipv4v6" ] && ipv4opt="-4"
	[ "$pdptype" = "ipv6" -o "$pdptype" = "ipv4v6" ] && ipv6opt="-6"
	[ -n "$auth" ] || auth="none"

	local retry_count=0
	local setup_success=0

	while [ $retry_count -lt $max_retries ] && [ $setup_success -eq 0 ]; do
		if [ $retry_count -gt 0 ]; then
			echo "Retry attempt $retry_count/$max_retries after failed DHCP"
			
			proto_kill_command "$interface"
			sleep 5
			
			if reset_modem; then
				if ! wait_for_device "$qmi_device"; then
					echo "QMI device not available after reset"
					retry_count=$((retry_count + 1))
					continue
				fi
			fi
		fi

		echo "Starting quectel-cm with QMI configuration for interface $interface"
		eval "proto_run_command '$interface' /usr/bin/quectel-cm -d -i '$base_ifname' $ipv4opt $ipv6opt ${pincode:+-p $pincode} -s '$apn' '$username' '$password' '$auth'"

		sleep 5

		echo "Finding actual interface for IP configuration"
		ifname="$(find_actual_interface "$base_ifname")"
		
		if [ -z "$ifname" ]; then
			echo "Could not find interface with IP configuration"
			retry_count=$((retry_count + 1))
			continue
		fi

		echo "Using interface: $ifname for IP configuration"

		if get_interface_config "$ifname" "$dhcp_timeout" "$retry_count"; then
			setup_success=1
			break
		else
			echo "Failed to get interface configuration on attempt $((retry_count + 1))"
			retry_count=$((retry_count + 1))
		fi
	done

	if [ $setup_success -eq 0 ]; then
		echo "Failed to setup interface after $max_retries attempts"
		proto_notify_error "$interface" NO_IFACE
		return 1
	fi

	if [ -n "$mtu" ]; then
		echo "Setting MTU to $mtu"
		ip link set dev "$ifname" mtu "$mtu"
	fi

	zone="$(fw3 -q network "$interface" 2>/dev/null)"
	defaultroute=1
	peerdns=1

	echo "Configuring netifd interface $interface"
	proto_init_update "$ifname" 1
	proto_set_keep 1
	proto_add_data
	json_add_string "modem" "Quectel"
	proto_close_data
	proto_send_update "$interface"

	[ -n "$v4address" ] && update_IPv4

	[ -n "$v6address" ] && update_IPv6

	sleep 2
	remove_dns_from_resolv "$ifname"

	echo "Starting interface monitoring for $interface"
	monitor_interface_changes "$interface" "$ifname" &

	echo "Setup complete for interface $interface"
}

proto_quectel_teardown() {
	local interface="$1"
	local device

	json_get_vars device
	[ -z "$ctl_device" ] || device="$ctl_device"

	echo "Stopping network $interface"

	killall -TERM monitor_interface_changes 2>/dev/null
	sleep 1
	killall -9 monitor_interface_changes 2>/dev/null

	if ubus call network.interface.${interface}6 status >/dev/null 2>&1; then
		echo "Cleaning up IPv6 dynamic interface"
		ubus call network.interface.${interface}6 down 2>/dev/null
		ubus call network del_dynamic "{\"name\": \"${interface}6\"}" 2>/dev/null
	fi

	local ifname devname devpath qmi_device
	qmi_device="$(detect_qmi_device)"
	
	if [ "$qmi_device" = "/dev/mhi_QMI0" ]; then
		for iface in /sys/class/net/rmnet_mhi*; do
			if [ -d "$iface" ]; then
				ifname="$(basename "$iface")"
				if [ "$ifname" != "rmnet_mhi*" ]; then
					remove_dns_from_resolv "$ifname"
				fi
			fi
		done
	else
		device="$(readlink -f "$device")"
		devname="$(basename "$device")"
		devpath="$(readlink -f "/sys/class/usbmisc/$devname/device/")"
		ifname="$(ls "$devpath/net" 2>/dev/null | head -n1)"

		if [ -n "$ifname" ]; then
			remove_dns_from_resolv "$ifname"
		fi
	fi

	killall -TERM udhcpc 2>/dev/null

	proto_kill_command "$interface"

	proto_init_update "*" 0
	proto_send_update "$interface"

	echo "Teardown complete for interface $interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol quectel
}