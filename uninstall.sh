#!/bin/sh

ERRORS=0

# Helper to safely delete a uci section by name pattern
delete_uci_section() {
    local config="$1"
    local type="$2"
    local name_pattern="$3"
    local section_id
    local _i

    section_id=$(uci show "$config" 2>/dev/null | grep -E "@${type}.*name=.${name_pattern}." | awk -F '[][{}]' '{print $2}' | head -n 1)
    if [ -n "$section_id" ]; then
        _i=0
        while uci -q delete "${config}.@${type}[${section_id}]" && [ "$_i" -lt 20 ]; do
            _i=$((_i + 1))
        done
        if [ "$_i" -gt 0 ]; then
            echo "  Removed ${config}.@${type}[${section_id}] (${name_pattern})"
        else
            echo "  ERROR: failed to delete ${config}.@${type} (${name_pattern})" >&2
            ERRORS=$((ERRORS + 1))
        fi
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
    /etc/init.d/cron restart 2>/dev/null
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

uci commit firewall || { echo "ERROR: uci commit firewall failed" >&2; ERRORS=$((ERRORS + 1)); }

echo "=== Cleaning network ==="
# Remove vpn routing table entries
sed -i '/99 vpn$/d' /etc/iproute2/rt_tables
sed -i '/110 vpninternal$/d' /etc/iproute2/rt_tables

# Remove mark rules
delete_uci_section network rule mark0x1
delete_uci_section network rule mark0x2

# Remove internal vpn route
_i=0
while uci -q delete network.vpn_route_internal && [ "$_i" -lt 20 ]; do
    _i=$((_i + 1))
done

uci commit network || { echo "ERROR: uci commit network failed" >&2; ERRORS=$((ERRORS + 1)); }

echo "=== Cleaning dhcp (dnsmasq ipset entries) ==="
# Remove dhcp ipset entries for vpn_domains_internal (YouTube domains)
if uci show dhcp 2>/dev/null | grep -q "name='vpn_domains_internal'"; then
    dhcp_ipset_id=$(uci show dhcp | grep -E "@ipset.*name=.vpn_domains_internal." | awk -F '[][{}]' '{print $2}' | head -n 1)
    if [ -n "$dhcp_ipset_id" ]; then
        _i=0
        while uci -q delete "dhcp.@ipset[${dhcp_ipset_id}]" && [ "$_i" -lt 20 ]; do
            _i=$((_i + 1))
        done
        echo "  Removed dhcp.@ipset[${dhcp_ipset_id}] (vpn_domains_internal)"
        uci commit dhcp || { echo "ERROR: uci commit dhcp failed" >&2; ERRORS=$((ERRORS + 1)); }
    fi
fi

# Remove YouTube domain cleanup sed from getdomains script (if it still exists)
if [ -f /etc/init.d/getdomains ]; then
    sed -i '/youtube.com/d' /etc/init.d/getdomains
fi

echo "=== Restarting services ==="
/etc/init.d/firewall restart 2>/dev/null || { echo "ERROR: firewall restart failed" >&2; ERRORS=$((ERRORS + 1)); }
/etc/init.d/network restart 2>/dev/null || { echo "ERROR: network restart failed" >&2; ERRORS=$((ERRORS + 1)); }
/etc/init.d/dnsmasq restart 2>/dev/null || { echo "ERROR: dnsmasq restart failed" >&2; ERRORS=$((ERRORS + 1)); }

echo "=== Checking residuals ==="
if uci show dhcp 2>/dev/null | grep -q ipset || \
   uci show firewall 2>/dev/null | grep -q ipset; then
    echo "WARNING: ipset entries remain in dhcp or firewall config. Review and remove manually."
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo "Completed with $ERRORS error(s). Review output above."
    exit 1
else
    echo "Done. Tunnels, proxies, zones and forwarding are left intact."
    echo "Dnscrypt and stubby are also not touched."
fi
