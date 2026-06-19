#!/bin/sh

#set -x

REPO_OWNER="FrankSandow"
REPO_NAME="awg-immortalwrt"
API_BASE="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
RELEASE_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download"

PKG_MANAGER=""
PKG_EXT=""
RELEASE_TAG=""

usage() {
    cat <<EOF
Usage: ${0##*/} [-h] [-e] [-n] [-t TAG]
    -h       show this help
    -e       do not install 'luci-i18n-amneziawg-ru' package
    -n       do not configure the amneziawg interface
    -t TAG   use specific release tag (auto-detect if omitted)
EOF
    exit 0
}

detect_package_manager() {
    if command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_EXT="apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MANAGER="opkg"
        PKG_EXT="ipk"
    else
        printf "\033[32;1mNo supported package manager found (apk/opkg).\033[0m\n"
        exit 1
    fi
}

pkg_update() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk update
    else
        opkg update
    fi
}

is_pkg_installed() {
    pkg_name="$1"
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk info -e "$pkg_name" >/dev/null 2>&1
    else
        opkg list-installed 2>/dev/null | grep -q "^${pkg_name} "
    fi
}

install_local_pkg() {
    pkg_file="$1"
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk add --allow-untrusted "$pkg_file"
    else
        opkg install "$pkg_file"
    fi
}

get_pkgarch() {
    PKGARCH_UBUS=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.arch' 2>/dev/null)
    if [ -n "$PKGARCH_UBUS" ]; then
        echo "$PKGARCH_UBUS"
        return
    fi

    if command -v opkg >/dev/null 2>&1; then
        opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}'
        return
    fi

    if [ -f /etc/openwrt_release ]; then
        PKGARCH_RELEASE=$(grep "^DISTRIB_ARCH='" /etc/openwrt_release | cut -d"'" -f2)
        if [ -n "$PKGARCH_RELEASE" ]; then
            echo "$PKGARCH_RELEASE"
            return
        fi
    fi

    if command -v apk >/dev/null 2>&1; then
        apk --print-arch
        return
    fi

    uname -m
}

# Query GitHub API to find the latest release for this IWRT version.
# Release tags follow the format: {tools_ver}-v{iwrt_ver}
#   or: {tools_ver}_kmod{...}-v{iwrt_ver}
# Both end with -v{IWRT_VER}.
detect_release_tag() {
    local iwrt_ver="$1"
    local page=1
    local all_tags=""

    # Paginate through releases (GitHub returns 100 per page max)
    while true; do
        local tags_page
        tags_page=$(curl -sL "${API_BASE}/releases?per_page=100&page=${page}" \
            | grep '"tag_name"' \
            | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/".*//')

        if [ -z "$tags_page" ]; then
            break
        fi

        all_tags="${all_tags}${tags_page}
"
        page=$((page + 1))
    done

    # Find the first (newest) tag ending with -v{IWRT_VER}
    echo "$all_tags" | while IFS= read -r tag; do
        case "$tag" in
            *"-v${iwrt_ver}") echo "$tag"; return 0 ;;
        esac
    done
}

# Get asset names for a given release tag
get_release_assets() {
    local tag="$1"
    curl -sL "${API_BASE}/releases/tags/${tag}" \
        | grep '"name"' \
        | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//;s/".*//'
}

# Find an asset matching: {prefix}_{anything}_{PKGARCH}_{TARGET}_{SUBTARGET}.{ext}
# Falls back to the other package extension if preferred not found.
download_package() {
    local prefix="$1"
    local assets="$2"
    local awg_dir="$3"
    local tag="$4"

    local match_suffix="_${PKGARCH}_${TARGET}_${SUBTARGET}."

    # Try preferred extension first, then fallback
    local ext_try="$PKG_EXT"
    local ext_other="ipk"
    if [ "$ext_try" = "ipk" ]; then
        ext_other="apk"
    fi

    for ext in "$ext_try" "$ext_other"; do
        local filename
        filename=$(echo "$assets" | grep "^${prefix}.*${match_suffix}${ext}$" | head -1)
        if [ -n "$filename" ]; then
            local url="${RELEASE_BASE}/${tag}/${filename}"
            printf "  Downloading %s\n" "$filename" >&2
            if wget -q -O "$awg_dir/$filename" "$url" && [ -s "$awg_dir/$filename" ]; then
                echo "$filename"
                return 0
            fi
            rm -f "$awg_dir/$filename"
        fi
    done

    return 1
}

#OpenWRT repository must be available for installing kmod-amneziawg dependencies
check_repo() {
    printf "\033[32;1mChecking OpenWrt repo availability...\033[0m\n"
    if [ "$PKG_MANAGER" = "apk" ]; then
        pkg_update >/dev/null 2>&1 || \
            { printf "\033[32;1mapk failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n"; exit 1; }
    else
        pkg_update | grep -q "Failed to download" && \
            printf "\033[32;1mopkg failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n" && exit 1
    fi
}

install_awg_packages() {
    PKGARCH=$(get_pkgarch)
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    IWRT_VER=$(ubus call system board | jsonfilter -e '@.release.version')

    printf "\033[32;1mDetected system:\033[0m\n"
    printf "  ImmortalWRT: %s\n" "$IWRT_VER"
    printf "  Target:      %s/%s\n" "$TARGET" "$SUBTARGET"
    printf "  PkgArch:     %s\n" "$PKGARCH"
    printf "  PkgManager:  %s\n" "$PKG_MANAGER"

    # Resolve release tag
    if [ -z "$RELEASE_TAG" ]; then
        printf "\033[32;1mAuto-detecting release for ImmortalWRT %s...\033[0m\n" "$IWRT_VER"
        RELEASE_TAG=$(detect_release_tag "$IWRT_VER")
    fi

    if [ -z "$RELEASE_TAG" ]; then
        echo "Error: No release found for ImmortalWRT $IWRT_VER"
        echo "Available releases can be browsed at:"
        echo "  https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
        exit 1
    fi

    printf "\033[32;1mRelease tag: %s\033[0m\n" "$RELEASE_TAG"

    # Fetch asset list for this release
    printf "\033[32;1mFetching release assets...\033[0m\n"
    ASSETS=$(get_release_assets "$RELEASE_TAG")
    if [ -z "$ASSETS" ]; then
        echo "Error: Could not fetch assets for release $RELEASE_TAG"
        exit 1
    fi

    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"

    # --- kmod-amneziawg ---
    if is_pkg_installed "kmod-amneziawg"; then
        echo "kmod-amneziawg already installed"
    else
        KMOD_FILE=$(download_package "kmod-amneziawg" "$ASSETS" "$AWG_DIR" "$RELEASE_TAG")
        if [ $? -eq 0 ]; then
            printf "  kmod-amneziawg downloaded successfully\n" >&2
            install_local_pkg "$AWG_DIR/$KMOD_FILE"
            if [ $? -eq 0 ]; then
                echo "kmod-amneziawg installed successfully"
            else
                echo "Error installing kmod-amneziawg. Please install it manually and run the script again"
                exit 1
            fi
        else
            echo "Error downloading kmod-amneziawg for your platform."
            echo "Check available assets at: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/${RELEASE_TAG}"
            exit 1
        fi
    fi

    # --- amneziawg-tools ---
    if is_pkg_installed "amneziawg-tools"; then
        echo "amneziawg-tools already installed"
    else
        TOOLS_FILE=$(download_package "amneziawg-tools" "$ASSETS" "$AWG_DIR" "$RELEASE_TAG")
        if [ $? -eq 0 ]; then
            printf "  amneziawg-tools downloaded successfully\n" >&2
            install_local_pkg "$AWG_DIR/$TOOLS_FILE"
            if [ $? -eq 0 ]; then
                echo "amneziawg-tools installed successfully"
            else
                echo "Error installing amneziawg-tools. Please install it manually and run the script again"
                exit 1
            fi
        else
            echo "Error downloading amneziawg-tools for your platform."
            exit 1
        fi
    fi

    # --- luci-proto-amneziawg ---
    if is_pkg_installed "luci-proto-amneziawg"; then
        echo "luci-proto-amneziawg already installed"
    else
        LUCI_FILE=$(download_package "luci-proto-amneziawg" "$ASSETS" "$AWG_DIR" "$RELEASE_TAG")
        if [ $? -eq 0 ]; then
            printf "  luci-proto-amneziawg downloaded successfully\n" >&2
            install_local_pkg "$AWG_DIR/$LUCI_FILE"
            if [ $? -eq 0 ]; then
                echo "luci-proto-amneziawg installed successfully"
            else
                echo "Error installing luci-proto-amneziawg. Please install it manually and run the script again"
                exit 1
            fi
        else
            echo "Error downloading luci-proto-amneziawg for your platform."
            exit 1
        fi
    fi

    # --- luci-i18n-amneziawg-ru (optional) ---
    if [ $ASK_FOR_TRANSLATION = 1 ]; then
        printf "\033[32;1mInstall Russian language pack? (y/n) [n]: \033[0m\n"
        read INSTALL_RU_LANG
        INSTALL_RU_LANG=${INSTALL_RU_LANG:-n}

        if [ "$INSTALL_RU_LANG" = "y" ] || [ "$INSTALL_RU_LANG" = "Y" ]; then
            if is_pkg_installed "luci-i18n-amneziawg-ru"; then
                echo "luci-i18n-amneziawg-ru already installed"
            else
                I18N_FILE=$(download_package "luci-i18n-amneziawg-ru" "$ASSETS" "$AWG_DIR" "$RELEASE_TAG")
                if [ $? -eq 0 ]; then
                    printf "  luci-i18n-amneziawg-ru downloaded successfully\n" >&2
                    install_local_pkg "$AWG_DIR/$I18N_FILE"
                    if [ $? -eq 0 ]; then
                        echo "luci-i18n-amneziawg-ru installed successfully"
                    else
                        echo "Warning: Error installing luci-i18n-amneziawg-ru (non-critical)"
                    fi
                else
                    echo "Warning: Russian localization not available for this platform (non-critical)"
                fi
            fi
        else
            printf "\033[32;1mSkipping Russian language pack installation.\033[0m\n"
        fi
    fi

    rm -rf "$AWG_DIR"
}

configure_amneziawg_interface() {
    INTERFACE_NAME="awg1"
    CONFIG_NAME="amneziawg_awg1"
    PROTO="amneziawg"
    ZONE_NAME="awg1"

    read -r -p "Enter the private key (from [Interface]):"$'\n' AWG_PRIVATE_KEY_INT

    while true; do
        read -r -p "Enter internal IP address with subnet, example 192.168.100.5/24 (from [Interface]):"$'\n' AWG_IP
        if echo "$AWG_IP" | egrep -oq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
            break
        else
            echo "This IP is not valid. Please repeat"
        fi
    done

    read -r -p "Enter the public key (from [Peer]):"$'\n' AWG_PUBLIC_KEY_INT
    read -r -p "If use PresharedKey, Enter this (from [Peer]). If your don't use leave blank:"$'\n' AWG_PRESHARED_KEY_INT
    read -r -p "Enter Endpoint host without port (Domain or IP) (from [Peer]):"$'\n' AWG_ENDPOINT_INT

    read -r -p "Enter Endpoint host port (from [Peer]) [51820]:"$'\n' AWG_ENDPOINT_PORT_INT
    AWG_ENDPOINT_PORT_INT=${AWG_ENDPOINT_PORT_INT:-51820}
    if [ "$AWG_ENDPOINT_PORT_INT" = '51820' ]; then
        echo $AWG_ENDPOINT_PORT_INT
    fi

    read -r -p "Enter Jc value (from [Interface]):"$'\n' AWG_JC
    read -r -p "Enter Jmin value (from [Interface]):"$'\n' AWG_JMIN
    read -r -p "Enter Jmax value (from [Interface]):"$'\n' AWG_JMAX
    read -r -p "Enter S1 value (from [Interface]):"$'\n' AWG_S1
    read -r -p "Enter S2 value (from [Interface]):"$'\n' AWG_S2
    read -r -p "Enter H1 value (from [Interface]):"$'\n' AWG_H1
    read -r -p "Enter H2 value (from [Interface]):"$'\n' AWG_H2
    read -r -p "Enter H3 value (from [Interface]):"$'\n' AWG_H3
    read -r -p "Enter H4 value (from [Interface]):"$'\n' AWG_H4

    read -r -p "Enter S3 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_S3
    read -r -p "Enter S4 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_S4
    read -r -p "Enter I1 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I1
    read -r -p "Enter I2 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I2
    read -r -p "Enter I3 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I3
    read -r -p "Enter I4 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I4
    read -r -p "Enter I5 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I5

    uci set network.${INTERFACE_NAME}=interface
    uci set network.${INTERFACE_NAME}.proto=$PROTO
    uci set network.${INTERFACE_NAME}.private_key=$AWG_PRIVATE_KEY_INT
    uci set network.${INTERFACE_NAME}.listen_port='51821'
    uci set network.${INTERFACE_NAME}.addresses=$AWG_IP

    uci set network.${INTERFACE_NAME}.awg_jc=$AWG_JC
    uci set network.${INTERFACE_NAME}.awg_jmin=$AWG_JMIN
    uci set network.${INTERFACE_NAME}.awg_jmax=$AWG_JMAX
    uci set network.${INTERFACE_NAME}.awg_s1=$AWG_S1
    uci set network.${INTERFACE_NAME}.awg_s2=$AWG_S2
    uci set network.${INTERFACE_NAME}.awg_h1=$AWG_H1
    uci set network.${INTERFACE_NAME}.awg_h2=$AWG_H2
    uci set network.${INTERFACE_NAME}.awg_h3=$AWG_H3
    uci set network.${INTERFACE_NAME}.awg_h4=$AWG_H4

    [ -n "$AWG_S3" ] && uci set network.${INTERFACE_NAME}.awg_s3=$AWG_S3
    [ -n "$AWG_S4" ] && uci set network.${INTERFACE_NAME}.awg_s4=$AWG_S4
    [ -n "$AWG_I1" ] && uci set network.${INTERFACE_NAME}.awg_i1=$AWG_I1
    [ -n "$AWG_I2" ] && uci set network.${INTERFACE_NAME}.awg_i2=$AWG_I2
    [ -n "$AWG_I3" ] && uci set network.${INTERFACE_NAME}.awg_i3=$AWG_I3
    [ -n "$AWG_I4" ] && uci set network.${INTERFACE_NAME}.awg_i4=$AWG_I4
    [ -n "$AWG_I5" ] && uci set network.${INTERFACE_NAME}.awg_i5=$AWG_I5

    if ! uci show network | grep -q ${CONFIG_NAME}; then
        uci add network ${CONFIG_NAME}
    fi

    uci set network.@${CONFIG_NAME}[0]=$CONFIG_NAME
    uci set network.@${CONFIG_NAME}[0].name="${INTERFACE_NAME}_client"
    uci set network.@${CONFIG_NAME}[0].public_key=$AWG_PUBLIC_KEY_INT
    uci set network.@${CONFIG_NAME}[0].preshared_key=$AWG_PRESHARED_KEY_INT
    uci set network.@${CONFIG_NAME}[0].route_allowed_ips='1'
    uci set network.@${CONFIG_NAME}[0].persistent_keepalive='25'
    uci set network.@${CONFIG_NAME}[0].endpoint_host=$AWG_ENDPOINT_INT
    uci set network.@${CONFIG_NAME}[0].allowed_ips='0.0.0.0/0'
    uci add_list network.@${CONFIG_NAME}[0].allowed_ips='::/0'
    uci set network.@${CONFIG_NAME}[0].endpoint_port=$AWG_ENDPOINT_PORT_INT
    uci commit network

    if ! uci show firewall | grep -q "@zone.*name='${ZONE_NAME}'"; then
        printf "\033[32;1mZone Create\033[0m\n"
        uci add firewall zone
        uci set firewall.@zone[-1].name=$ZONE_NAME
        uci set firewall.@zone[-1].network=$INTERFACE_NAME
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    fi

    if ! uci show firewall | grep -q "@forwarding.*name='${ZONE_NAME}'"; then
        printf "\033[32;1mConfigured forwarding\033[0m\n"
        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].name="${ZONE_NAME}-lan"
        uci set firewall.@forwarding[-1].dest=${ZONE_NAME}
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi

    service network restart
}

ASK_FOR_TRANSLATION=1
ASK_FOR_INTERFACE_CONFIG=1

while getopts ":ehnt:" opt; do
    case "$opt" in
        h) usage ;;
        e) ASK_FOR_TRANSLATION=0 ;;
        n) ASK_FOR_INTERFACE_CONFIG=0 ;;
        t) RELEASE_TAG="$OPTARG" ;;
        \?) echo "Unknown option -$OPTARG" >&2; usage ;;
    esac
done
shift "$((OPTIND-1))"

detect_package_manager
check_repo

install_awg_packages

if [ "$ASK_FOR_INTERFACE_CONFIG" = 0 ]; then
    exit 0
fi

printf "\033[32;1mDo you want to configure the amneziawg interface? (y/n): \033[0m\n"
read IS_SHOULD_CONFIGURE_AWG_INTERFACE

if [ "$IS_SHOULD_CONFIGURE_AWG_INTERFACE" = "y" ] || [ "$IS_SHOULD_CONFIGURE_AWG_INTERFACE" = "Y" ]; then
    configure_amneziawg_interface
else
    printf "\033[32;1mSkipping amneziawg interface configuration.\033[0m\n"
fi