SKIPUNZIP=0

ASL=
REPLACE="
"
bootinspect() {
    if [ "$BOOTMODE" ] && [ "$KSU" ]; then
        ui_print "- Install from KernelSU"
        ui_print "- KernelSU Version：$KSU_KERNEL_VER_CODE（App）+ $KSU_VER_CODE（ksud）"
    elif [ "$BOOTMODE" ] && [ "$APATCH" ]; then
        ui_print "- Install from APatch"
        ui_print "- Apatch Version：$APATCH_VER_CODE（App）+ $KERNELPATCH_VERSION（KernelPatch）"
    elif [ "$BOOTMODE" ] && [ "$MAGISK_VER_CODE" ]; then
        ui_print "- Install from Magisk"
        ui_print "- Magisk Version：$MAGISK_VER（App）+ $MAGISK_VER_CODE"
    else
        abort "- Unsupported installation mode. Please install from the application (Magisk/KernelSu/Apatch)"
    fi
    [ "$ARCH" != "arm64" ] && abort "- Unsupported platform: $ARCH" || ui_print "- Device platform: $ARCH"
}

link_busybox() {
    local busybox_file=""
    local BUSYBOX_PATHS="/data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox"

    for path in $BUSYBOX_PATHS; do
        if [ -f "$path" ]; then
            busybox_file="$path"
            break
        fi
    done

    if [ -n "$busybox_file" ]; then
        mkdir -p "$MODPATH/system/xbin"
        # "$busybox_file" --install -s "$MODPATH/system/xbin"
        # This method creates links pointing to all commands of busybox, so it is not recommended. The following is an alternative approach for creating symbolic links pointing to the busybox file for specific commands
        for cmd in fuser; do
            ln -sf "$busybox_file" "$MODPATH/system/xbin/$cmd"
        done

        if ! inotifyd --help >/dev/null 2>&1; then
            ln -sf "$busybox_file" "$MODPATH/system/xbin/inotifyd"
        fi
    else
        abort "- No available Busybox file found Please check your installation environment"
    fi

    set_perm_recursive "$MODPATH/system/xbin" 0 0 0755 0755
    export PATH="$MODPATH/system/xbin:$PATH"
}

inotifyfile() {
    id_value=$(sed -n 's/^id=\(.*\)$/\1/p' "$MODPATH/module.prop")
    MONITORFILE=".${id_value}.service.sh"

    sed -i "2c MODULEID=\"$id_value\"" "$MODPATH/inotify.sh"
    mkdir -p /data/adb/service.d
    mv -f "$MODPATH/inotify.sh" "/data/adb/service.d/$MONITORFILE"
    chmod +x "/data/adb/service.d/$MONITORFILE"

    sed -i "s/inotify.sh/$MONITORFILE/g" "$MODPATH/uninstall.sh"
}

configuration() {
    . "$MODPATH/config.conf"

    BASE_DIR="/data"
    CONTAINER_DIR="${BASE_DIR}/${RURIMA_LXC_OS}"
    sed -i "s|^CONTAINER_DIR=.*|CONTAINER_DIR=$CONTAINER_DIR|" "$MODPATH/config.conf"

    SUPPORT=$(sed -nE 's/^OS_LIST="([^"]+)"/\1/p' "$MODPATH/setup/setup.sh")

    if ! echo "$SUPPORT" | grep -qw "$RURIMA_LXC_OS"; then
        abort "- $RURIMA_LXC_OS is not supported by the setup script"
    fi

    if [ -d "$CONTAINER_DIR" ]; then
        ui_print "- Already installed"
        ruri -U "$CONTAINER_DIR"
        if [ -d "$CONTAINER_DIR.old" ]; then
            version=1
            while [ -d "$CONTAINER_DIR.old.$version" ]; do
                version=$((version + 1))
            done
            mv "$CONTAINER_DIR.old" "$CONTAINER_DIR.old.$version"
        fi
        mv -f "$CONTAINER_DIR" "$CONTAINER_DIR.old"
        ui_print "- Shut down the container and back up the relevant directories and files to the ${CONTAINER_DIR}.old"
    fi
}

# ========== 新增 OpenWRT 下载函数 ==========
download_openwrt() {
    . "$MODPATH/config.conf"
    local OPENWRT_DOWNLOAD_URL=""
    
    # 判断版本，选择稳定版/开发版地址
    if [ "${RURIMA_LXC_OS_VERSION}" = "edge" ]; then
        OPENWRT_DOWNLOAD_URL="${OPENWRT_EDGE_URL}"
    else
        OPENWRT_DOWNLOAD_URL="${OPENWRT_URL}"
    fi

    ui_print "- Downloading OpenWRT ${RURIMA_LXC_OS_VERSION} rootfs..."
    ui_print "- Download URL: ${OPENWRT_DOWNLOAD_URL}"
    
    # 创建容器目录
    mkdir -p "$CONTAINER_DIR"
    # 使用 rurima 下载 OpenWRT rootfs
    ./rurima download "${OPENWRT_DOWNLOAD_URL}" "${CONTAINER_DIR}/rootfs.tar.gz"
    
    if [[ $? != 0 ]]; then
        abort "- OpenWRT rootfs download failed! Please check network or URL."
    fi

    # 解压 rootfs
    ui_print "- Extracting OpenWRT rootfs..."
    mkdir -p "${CONTAINER_DIR}/rootfs"
    tar -xf "${CONTAINER_DIR}/rootfs.tar.gz" -C "${CONTAINER_DIR}/rootfs"
    if [[ $? != 0 ]]; then
        abort "- OpenWRT rootfs extract failed!"
    fi
    ui_print "- OpenWRT rootfs extract completed!"
}

automatic() {
    ui_print "- A network connection is required to download the root filesystem. Please connect to WiFi before installation whenever possible"

    # ========== 新增 OpenWRT 分支判断 ==========
    if [ "${RURIMA_LXC_OS}" = "openwrt" ]; then
        # 下载 OpenWRT rootfs（非 LXC 镜像）
        download_openwrt
    else
        # 原版 LXC 镜像下载逻辑
        ui_print "- Downloading the root filesystem using the source ${RURIMA_LXC_MIRROR}..."
        rurima lxc pull -n -m ${RURIMA_LXC_MIRROR} -o ${RURIMA_LXC_OS} -v ${RURIMA_LXC_OS_VERSION} -s "$CONTAINER_DIR"
        if [[ $? != 0 ]]; then
            ui_print "- Download failed. Attempting to download the root filesystem using the fallback source ${RURIMA_LXC_MIRROR_FALLBACK}..."
            rurima lxc pull -n -m ${RURIMA_LXC_MIRROR_FALLBACK} -o ${RURIMA_LXC_OS} -v ${RURIMA_LXC_OS_VERSION} -s "$CONTAINER_DIR"
        fi
    fi

    ui_print "- Starting the chroot environment to perform automated installation..."
    ui_print "- Please ensure the network environment is stable. The process may take some time, so please be patient!"
    ui_print ""
    sleep 2
    getprop ro.product.model > "$CONTAINER_DIR/etc/hostname"
    mkdir -p "$CONTAINER_DIR/tmp" "$CONTAINER_DIR/usr/local/lib/servicectl/enabled"
    cp "$MODPATH/setup/setup.sh" "$CONTAINER_DIR/tmp/setup.sh"
    cp -r "$MODPATH/setup/servicectl"/* "$CONTAINER_DIR/usr/local/lib/servicectl/"
    chmod 777 "$CONTAINER_DIR/tmp/setup.sh" "$CONTAINER_DIR/usr/local/lib/servicectl/servicectl" "$CONTAINER_DIR/usr/local/lib/servicectl/serviced"

    ruri "$CONTAINER_DIR" /bin/sh /tmp/setup.sh "$RURIMA_LXC_OS" "$PASSWORD" "$PORT"
    ruri -U "$CONTAINER_DIR"

    ui_print "- Automated installation completed!"
    ui_print "- Note: Please change the default password. Exposing an SSH port with password authentication instead of key-based authentication is always a high-risk behavior!"
}

main() {
    bootinspect
    link_busybox

    if [ -z "$ASL" ]; then
        configuration
        automatic
    fi

    inotifyfile
}

main

# set_perm_recursive $MODPATH 0 0 0755 0644
set_perm "$MODPATH/container_ctrl.sh" 0 0 0755

ui_print ""
(sleep 5 && reboot) &
ui_print "The system will restart in 5 seconds..."
