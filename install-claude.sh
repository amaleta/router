#!/bin/sh

#set -x

# ─── Package manager detection ───────────────────────────────────────────────
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

pkg_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update || true
    else
        opkg update | grep -q "Failed to download" && \
            printf "\033[32;1mopkg failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n" && exit 1
    fi
}

pkg_is_installed() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2>/dev/null | grep -q "^$1"
    else
        opkg list-installed 2>/dev/null | grep -q "^$1"
    fi
}

pkg_install_name() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add "$1"
    else
        opkg install "$1"
    fi
}

pkg_install_file() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$1"
    else
        opkg install "$1"
    fi
}

pkg_remove() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del "$1" || true
    else
        opkg remove --force-depends "$1"
    fi
}

# ─── AWG install ─────────────────────────────────────────────────────────────
install_awg_packages() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        # OpenWrt 25.x — AWG уже в официальных feeds
        for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
            if pkg_is_installed "$pkg"; then
                echo "$pkg already installed"
            else
                echo "Installing $pkg..."
                apk add "$pkg" || {
                    echo "Error installing $pkg via apk"
                    exit 1
                }
            fi
        done
    else
        # OpenWrt 24.x — качаем .ipk с GitHub
        PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
        TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
        SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
        VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
        PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
        BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"
        AWG_DIR="/tmp/amneziawg"
        mkdir -p "$AWG_DIR"

        for pkg in amneziawg-tools kmod-amneziawg luci-app-amneziawg; do
            if pkg_is_installed "$pkg"; then
                echo "$pkg already installed"
            else
                FILENAME="${pkg}${PKGPOSTFIX}"
                DOWNLOAD_URL="${BASE_URL}v${VERSION}/${FILENAME}"
                curl -L -o "$AWG_DIR/$FILENAME" "$DOWNLOAD_URL" || {
                    echo "Error downloading $pkg. Install manually and rerun."
                    exit 1
                }
                opkg install "$AWG_DIR/$FILENAME" || {
                    echo "Error installing $pkg"
                    exit 1
                }
            fi
        done
        rm -rf "$AWG_DIR"
    fi
}

# ─── Routes / hotplug ────────────────────────────────────────────────────────
route_vpn() {
    if [ "$TUNNEL" = wg ]; then
cat << EOF > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh
ip route add table vpn default dev wg0
EOF
    elif [ "$TUNNEL" = awg ]; then
cat << EOF > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh
ip route add table vpn default dev awg0
EOF
    elif [ "$TUNNEL" = singbox ] || [ "$TUNNEL" = ovpn ] || [ "$TUNNEL" = tun2socks ]; then
cat << EOF > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh
sleep 10
ip route add table vpn default dev tun0
EOF
    fi
    cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute
}

add_mark() {
    grep -q "99 vpn" /etc/iproute2/rt_tables || echo '99 vpn' >> /etc/iproute2/rt_tables

    if ! uci show network | grep -q mark0x1; then
        printf "\033[32;1mConfigure mark rule\033[0m\n"
        uci add network rule
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit
    fi
}

# ─── Tunnel selection ─────────────────────────────────────────────────────────
add_tunnel() {
    echo "We can automatically configure only Wireguard and Amnezia WireGuard."
    echo "OpenVPN, Sing-box, tun2socks will need to be configured manually."
    echo "Select a tunnel:"
    echo "1) WireGuard"
    echo "2) OpenVPN"
    echo "3) Sing-box"
    echo "4) tun2socks"
    echo "5) wgForYoutube"
    echo "6) Amnezia WireGuard"
    echo "7) Amnezia WireGuard For Youtube"
    echo "8) Skip this step"

    while true; do
        read -r TUNNEL
        case $TUNNEL in
        1) TUNNEL=wg;            break ;;
        2) TUNNEL=ovpn;          break ;;
        3) TUNNEL=singbox;       break ;;
        4) TUNNEL=tun2socks;     break ;;
        5) TUNNEL=wgForYoutube;  break ;;
        6) TUNNEL=awg;           break ;;
        7) TUNNEL=awgForYoutube; break ;;
        8) echo "Skip"; TUNNEL=0; break ;;
        *) echo "Choose from the following options" ;;
        esac
    done

    if [ "$TUNNEL" = 'wg' ]; then
        printf "\033[32;1mConfigure WireGuard\033[0m\n"
        if pkg_is_installed wireguard-tools; then
            echo "Wireguard already installed"
        else
            pkg_install_name wireguard-tools
        fi

        route_vpn

        printf "Enter the private key (from [Interface]):\n"; read -r WG_PRIVATE_KEY

        while true; do
            printf "Enter internal IP address with subnet, e.g. 192.168.100.5/24:\n"; read -r WG_IP
            if echo "$WG_IP" | grep -oqE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
                break
            else
                echo "This IP is not valid. Please repeat"
            fi
        done

        printf "Enter the public key (from [Peer]):\n"; read -r WG_PUBLIC_KEY
        printf "PresharedKey (leave blank if not used):\n"; read -r WG_PRESHARED_KEY
        printf "Enter Endpoint host without port:\n"; read -r WG_ENDPOINT
        printf "Enter Endpoint port [51820]:\n"; read -r WG_ENDPOINT_PORT
        WG_ENDPOINT_PORT=${WG_ENDPOINT_PORT:-51820}

        uci set network.wg0=interface
        uci set network.wg0.proto='wireguard'
        uci set network.wg0.private_key="$WG_PRIVATE_KEY"
        uci set network.wg0.listen_port='51820'
        uci set network.wg0.addresses="$WG_IP"

        if ! uci show network | grep -q wireguard_wg0; then
            uci add network wireguard_wg0
        fi
        uci set network.@wireguard_wg0[0]=wireguard_wg0
        uci set network.@wireguard_wg0[0].name='wg0_client'
        uci set network.@wireguard_wg0[0].public_key="$WG_PUBLIC_KEY"
        uci set network.@wireguard_wg0[0].preshared_key="$WG_PRESHARED_KEY"
        uci set network.@wireguard_wg0[0].route_allowed_ips='0'
        uci set network.@wireguard_wg0[0].persistent_keepalive='25'
        uci set network.@wireguard_wg0[0].endpoint_host="$WG_ENDPOINT"
        uci set network.@wireguard_wg0[0].allowed_ips='0.0.0.0/0'
        uci set network.@wireguard_wg0[0].endpoint_port="$WG_ENDPOINT_PORT"
        uci commit
    fi

    if [ "$TUNNEL" = 'ovpn' ]; then
        if pkg_is_installed openvpn-openssl; then
            echo "OpenVPN already installed"
        else
            pkg_install_name openvpn-openssl
        fi
        printf "\033[32;1mConfigure route for OpenVPN\033[0m\n"
        route_vpn
    fi

    if [ "$TUNNEL" = 'singbox' ]; then
        if pkg_is_installed sing-box; then
            echo "Sing-box already installed"
        else
            AVAILABLE_SPACE=$(df / | awk 'NR>1 { print $4 }')
            if [ "$AVAILABLE_SPACE" -gt 2000 ]; then
                pkg_install_name sing-box
            else
                printf "\033[31;1mNo free space for sing-box.\033[0m\n"
                exit 1
            fi
        fi
        if grep -q "option enabled '0'" /etc/config/sing-box; then
            sed -i "s/  option enabled '0'/  option enabled '1'/" /etc/config/sing-box
        fi
        if grep -q "option user 'sing-box'" /etc/config/sing-box; then
            sed -i "s/  option user 'sing-box'/  option user 'root'/" /etc/config/sing-box
        fi
        if ! grep -q "tun0" /etc/sing-box/config.json 2>/dev/null; then
cat << 'EOF' > /etc/sing-box/config.json
{
  "log": { "level": "debug" },
  "inbounds": [{
    "type": "tun",
    "interface_name": "tun0",
    "domain_strategy": "ipv4_only",
    "address": ["172.16.250.1/30"],
    "auto_route": false,
    "strict_route": false,
    "sniff": true
  }],
  "outbounds": [{
    "type": "$TYPE",
    "server": "$HOST",
    "server_port": $PORT,
    "method": "$METHOD",
    "password": "$PASS"
  }],
  "route": { "auto_detect_interface": true }
}
EOF
            printf "\033[32;1mTemplate config created in /etc/sing-box/config.json. Edit manually.\033[0m\n"
            printf "\033[32;1mDocs: https://sing-box.sagernet.org/configuration/outbound/\033[0m\n"
        fi
        route_vpn
    fi

    if [ "$TUNNEL" = 'wgForYoutube' ]; then
        add_internal_wg Wireguard
    fi

    if [ "$TUNNEL" = 'awgForYoutube' ]; then
        add_internal_wg AmneziaWG
    fi

    if [ "$TUNNEL" = 'awg' ]; then
        printf "\033[32;1mConfigure Amnezia WireGuard\033[0m\n"
        install_awg_packages
        route_vpn

        printf "Enter the private key (from [Interface]):\n"; read -r AWG_PRIVATE_KEY

        while true; do
            printf "Enter internal IP address with subnet, e.g. 10.0.0.2/24:\n"; read -r AWG_IP
            if echo "$AWG_IP" | grep -oqE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
                break
            else
                echo "This IP is not valid. Please repeat"
            fi
        done

        printf "Enter Jc:\n";   read -r AWG_JC
        printf "Enter Jmin:\n"; read -r AWG_JMIN
        printf "Enter Jmax:\n"; read -r AWG_JMAX
        printf "Enter S1:\n";   read -r AWG_S1
        printf "Enter S2:\n";   read -r AWG_S2
        printf "Enter H1:\n";   read -r AWG_H1
        printf "Enter H2:\n";   read -r AWG_H2
        printf "Enter H3:\n";   read -r AWG_H3
        printf "Enter H4:\n";   read -r AWG_H4

        printf "Enter the public key (from [Peer]):\n"; read -r AWG_PUBLIC_KEY
        printf "PresharedKey (leave blank if not used):\n"; read -r AWG_PRESHARED_KEY
        printf "Enter Endpoint host without port:\n"; read -r AWG_ENDPOINT
        printf "Enter Endpoint port [51820]:\n"; read -r AWG_ENDPOINT_PORT
        AWG_ENDPOINT_PORT=${AWG_ENDPOINT_PORT:-51820}

        uci set network.awg0=interface
        uci set network.awg0.proto='amneziawg'
        uci set network.awg0.private_key="$AWG_PRIVATE_KEY"
        uci set network.awg0.listen_port='51820'
        uci set network.awg0.addresses="$AWG_IP"
        uci set network.awg0.awg_jc="$AWG_JC"
        uci set network.awg0.awg_jmin="$AWG_JMIN"
        uci set
