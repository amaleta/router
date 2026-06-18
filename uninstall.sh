#!/bin/sh

# Helper to safely delete a uci section by name pattern
delete_uci_section() {
    local config="$1"
    local type="$2"
    local name_pattern="$3"
    local section_id

    section_id=$(uci show "$config" | grep -E "@${type}.*name=.${name_pattern}." | awk -F '[][{}]' '{print $2}' | head -n 1)
    if [ -n "$section_id" ]; then
        while uci -q delete "${config}.@${type}[${section_id}]"; do :; done
        echo "  Removed ${config}.@${type}[${section_id}] (${name_pattern})"
    fi
}

echo "=== Removing scripts ==="
if [ -f /etc/init.d/getdomains ]; then
    /etc/init.d/getdomains disable 2>/dev/null
    rm -f /etc/init.d/getdomains
fi

rm -f /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute

echo "=== Removing crontab entries ==="
if [ -f /etc/crontabs/root ]; then
    sed -i '/getdomains start/d' /etc/crontabs/root
fi

echo "=== Removing domain lists ==="
rm -f /tmp/dnsmasq.d/domains.lst

echo "=== Cleaning firewall ==="

# vpn_domains set + mark_domains rule
delete_uci_section firewall ipset vpn_domains
delete_uci_section firewall rule mark_domains

# vpn_domains_internal set + mark_domains_intenal rule
delete_uci_section firewall ipset vpn_domains_internal
delete_uci_section firewall rule mark_domains_intenal

# vpn_ip set + mark_ip rule
delete_uci_section firewall ipset vpn_ip
delete_uci_section firewall rule mark_ip

# vpn_subnet set + mark_subnet rule
delete_uci_section firewall ipset vpn_subnet
delete_uci_section firewall rule mark_subnet

# vpn_community set + mark_community rule
delete_uci_section firewall ipset vpn_community
delete_uci_section firewall rule mark_community

uci commit firewall
/etc/init.d/firewall restart

echo "=== Cleaning network ==="
# Remove vpn routing table entries
sed -i '/99 vpn$/d' /etc/iproute2/rt_tables
sed -i '/110 vpninternal$/d' /etc/iproute2/rt_tables

# Remove mark rules
delete_uci_section network rule mark0x1
delete_uci_section network rule mark0x2

# Remove internal vpn route
while uci -q delete network.vpn_route_internal; do :; done

uci commit network
/etc/init.d/network restart

echo "=== Cleaning dhcp (dnsmasq ipset entries) ==="
# Remove dhcp ipset entries for vpn_domains_internal (YouTube domains)
dhcp_ipset_count=$(uci show dhcp | grep -c '@ipset')
if [ "$dhcp_ipset_count" -gt 0 ]; then
    dhcp_ipset_id=$(uci show dhcp | grep -E '@ipset.*name=.vpn_domains_internal.' | awk -F '[][{}]' '{print $2}' | head -n 1)
    if [ -n "$dhcp_ipset_id" ]; then
        while uci -q delete "dhcp.@ipset[${dhcp_ipset_id}]"; do :; done
        echo "  Removed dhcp.@ipset[${dhcp_ipset_id}] (vpn_domains_internal)"
        uci commit dhcp
        /etc/init.d/dnsmasq restart
    fi
fi

# Remove YouTube domain cleanup sed from getdomains script (if it still exists)
if [ -f /etc/init.d/getdomains ]; then
    sed -i '/youtube.com/d' /etc/init.d/getdomains
fi

echo "=== Checking Dnsmasq ==="
if uci show dhcp 2>/dev/null | grep -q ipset; then
    echo "WARNING: dnsmasq (/etc/config/dhcp) still has ipset entries. Save the ones you need, then remove the rest."
fi

echo ""
echo "Done. Tunnels, proxies, zones and forwarding are left intact."
echo "Dnscrypt and stubby are also not touched."
