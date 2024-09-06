#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

CONFIG_FILE="mitmrouter.conf"

# Default VARIABLES
BR_IFACE="br0"              # Bridge interface name
WAN_IFACE="eth0"            # WAN interface (Internet facing)
LAN_IFACE="eth1"            # LAN interface (wired)
WIFI_IFACE="wlan0"          # WiFi interface
WIFI_SSID="setec_astronomy" # WiFi SSID
WIFI_PASSWORD="mypassword"  # WiFi password

LAN_IP="192.168.200.1"      # IP address for LAN
LAN_SUBNET="255.255.255.0"  # Subnet mask for LAN
LAN_DHCP_START="192.168.200.10" # Start range for DHCP
LAN_DHCP_END="192.168.200.100"  # End range for DHCP
LAN_DNS_SERVER="1.1.1.1"    # DNS server for DHCP clients

DNSMASQ_CONF="tmp_dnsmasq.conf" # Temporary dnsmasq configuration file
HOSTAPD_CONF="tmp_hostapd.conf" # Temporary hostapd configuration file

# Load configuration from the file if it exists
load_config() {
    if [[ -f $CONFIG_FILE ]]; then
        echo "Loading configuration from $CONFIG_FILE..."
        source $CONFIG_FILE
    else
        echo "Configuration file not found. Using default settings."
    fi
}

# Save current configuration to the file
save_config() {
    echo "Saving current configuration to $CONFIG_FILE..."
    cat <<EOF > $CONFIG_FILE
BR_IFACE="$BR_IFACE"
WAN_IFACE="$WAN_IFACE"
LAN_IFACE="$LAN_IFACE"
WIFI_IFACE="$WIFI_IFACE"
WIFI_SSID="$WIFI_SSID"
WIFI_PASSWORD="$WIFI_PASSWORD"

LAN_IP="$LAN_IP"
LAN_SUBNET="$LAN_SUBNET"
LAN_DHCP_START="$LAN_DHCP_START"
LAN_DHCP_END="$LAN_DHCP_END"
LAN_DNS_SERVER="$LAN_DNS_SERVER"
EOF
}

# Ask user if they want to change a setting, showing the current value
ask_change() {
    local var_name="$1"
    local current_value="$2"
    local new_value
    read -p "Change $var_name [$current_value]? (press enter to keep current): " new_value
    echo "${new_value:-$current_value}"
}

# Prompt the user to configure the settings
prompt_config() {
    read -p "Do you want to configure the network interfaces? (y/N): " configure_interfaces
    if [[ "$configure_interfaces" =~ ^[yY]$ ]]; then
        BR_IFACE=$(ask_change "Bridge Interface (BR_IFACE)" "$BR_IFACE")
        WAN_IFACE=$(ask_change "WAN Interface (WAN_IFACE)" "$WAN_IFACE")
        LAN_IFACE=$(ask_change "LAN Interface (LAN_IFACE)" "$LAN_IFACE")
        WIFI_IFACE=$(ask_change "WiFi Interface (WIFI_IFACE)" "$WIFI_IFACE")
    fi

    read -p "Do you want to configure IP settings? (y/N): " configure_ips
    if [[ "$configure_ips" =~ ^[yY]$ ]]; then
        LAN_IP=$(ask_change "LAN IP" "$LAN_IP")
        LAN_SUBNET=$(ask_change "LAN Subnet" "$LAN_SUBNET")
        LAN_DHCP_START=$(ask_change "DHCP Start Range" "$LAN_DHCP_START")
        LAN_DHCP_END=$(ask_change "DHCP End Range" "$LAN_DHCP_END")
        LAN_DNS_SERVER=$(ask_change "LAN DNS Server" "$LAN_DNS_SERVER")
    fi

    save_config
}

# Check input arguments; must be either "up", "down", or "config"
if [[ "$1" != "up" && "$1" != "down" && "$1" != "config" ]] || [[ $# -ne 1 ]]; then
    echo "Error: Missing or incorrect argument."
    echo "Usage: $0 <up|down|config>"
    exit 1
fi

# If argument is "config", ask for new settings and save to configuration file
if [[ "$1" == "config" ]]; then
    load_config
    prompt_config
    exit 0
fi

# Load config on "up" or "down"
load_config

# Change to the script's directory
SCRIPT_RELATIVE_DIR=$(dirname "${BASH_SOURCE[0]}")
cd "$SCRIPT_RELATIVE_DIR"

# Function to stop services and reset interfaces
stop_services() {
    echo "== Stopping router services"
    sudo killall wpa_supplicant || true # Stop wpa_supplicant if running; ignore errors if not
    sudo killall dnsmasq || true        # Stop dnsmasq if running; ignore errors if not

    echo "== Resetting all network interfaces"
    sudo ip link set $LAN_IFACE down    # Bring down LAN interface
    sudo ip link set $BR_IFACE down     # Bring down bridge interface
    sudo ip link set $WIFI_IFACE down   # Bring down WiFi interface

    sudo brctl delbr $BR_IFACE || true  # Delete bridge interface; ignore errors if it doesn't exist
}

# If argument is "down", stop services and exit
if [[ "$1" == "down" ]]; then
    stop_services
    exit 0
fi

# If argument is "up", configure network and services
if [[ "$1" == "up" ]]; then
    stop_services  # Ensure services are stopped before starting

    echo "== Creating dnsmasq configuration file"
    # Create dnsmasq configuration for DHCP server
    cat <<EOF > "$DNSMASQ_CONF"
interface=${BR_IFACE}
dhcp-range=${LAN_DHCP_START},${LAN_DHCP_END},${LAN_SUBNET},12h
dhcp-option=6,${LAN_DNS_SERVER}
EOF

    echo "== Creating hostapd configuration file"
    # Create hostapd configuration for WiFi access point
    cat <<EOF > "$HOSTAPD_CONF"
interface=${WIFI_IFACE}
bridge=${BR_IFACE}
ssid=${WIFI_SSID}
country_code=US
hw_mode=g
channel=11
wpa=2
wpa_passphrase=${WIFI_PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
ieee80211n=1
#ieee80211w=1 # PMF (Protected Management Frames)
EOF

    echo "== Bringing up interfaces and bridge"
    sudo ip link set $WIFI_IFACE up  # Bring up WiFi interface
    sudo ip link set $WAN_IFACE up   # Bring up WAN interface
    sudo ip link set $LAN_IFACE up   # Bring up LAN interface
    sudo brctl addbr $BR_IFACE       # Create bridge interface
    sudo brctl addif $BR_IFACE $LAN_IFACE  # Add LAN interface to bridge
    sudo brctl addif $BR_IFACE $WIFI_IFACE # Add WiFi interface to bridge
    sudo ip link set $BR_IFACE up    # Bring up bridge interface

    echo "== Setting up iptables"
    # Configure NAT and firewall rules
    sudo iptables -F                      # Flush all iptables rules
    sudo iptables -t nat -F               # Flush all NAT rules
    sudo iptables -t nat -A POSTROUTING -o $WAN_IFACE -j MASQUERADE # Enable NAT on WAN interface
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT # Allow established connections
    sudo iptables -A FORWARD -i $BR_IFACE -o $WAN_IFACE -j ACCEPT   # Allow forwarding from bridge to WAN
    # Optional MITM (Man-In-The-Middle) rules for traffic redirection
    #sudo iptables -t nat -A PREROUTING -i $BR_IFACE -p tcp -d 1.2.3.4 --dport 443 -j REDIRECT --to-ports 8081

    echo "== Setting static IP on bridge interface"
    sudo ip addr add $LAN_IP/$LAN_SUBNET dev $BR_IFACE  # Set static IP for bridge

    echo "== Starting dnsmasq"
    sudo dnsmasq -C $DNSMASQ_CONF  # Start dnsmasq with the generated configuration
fi
