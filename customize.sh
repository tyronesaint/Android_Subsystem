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
        ui_print "- Shut down the container and back up to ${CONTAINER_DIR}.old"
    fi
}

# ========== 核心修复：OpenWRT 下载&解压逻辑 ==========
download_openwrt() {
    . "$MODPATH/config.conf"
    local OPENWRT_DOWNLOAD_URL=""
    
    # 选择下载地址（稳定版/开发版）
    if [ "${RURIMA_LXC_OS_VERSION}" = "edge" ]; then
        OPENWRT_DOWNLOAD_URL="${OPENWRT_EDGE_URL}"
    else
        OPENWRT_DOWNLOAD_URL="${OPENWRT_URL}"
    fi

    # 1. 创建容器根目录（关键：直接用 CONTAINER_DIR 作为解压根目录）
    mkdir -p "$CONTAINER_DIR"
    ui_print "- OpenWRT container dir: $CONTAINER_DIR"

    # 2. 断点续传下载 rootfs（避免重复下载）
    ui_print "- Downloading OpenWRT ${RURIMA_LXC_OS_VERSION} rootfs..."
    ui_print "- URL: ${OPENWRT_DOWNLOAD_URL}"
    if command -v curl >/dev/null 2>&1; then
        curl -L -C - -o "${CONTAINER_DIR}/rootfs.tar.gz" "${OPENWRT_DOWNLOAD_URL}"
    elif command -v wget >/dev/null 2>&1; then
        wget -c -O "${CONTAINER_DIR}/rootfs.tar.gz" "${OPENWRT_DOWNLOAD_URL}"
    else
        abort "- No curl/wget found! Cannot download rootfs."
    fi

    # 3. 校验文件是否下载完成（大小>0）
    if [ ! -f "${CONTAINER_DIR}/rootfs.tar.gz" ] || [ ! -s "${CONTAINER_DIR}/rootfs.tar.gz" ]; then
        abort "- OpenWRT rootfs download failed! File is empty or missing."
    fi
    ui_print "- Download completed! File size: $(du -h ${CONTAINER_DIR}/rootfs.tar.gz | awk '{print $1}')"

    # 4. 解压到容器根目录（核心修复：直接解压到 CONTAINER_DIR，而非 CONTAINER_DIR/rootfs）
    ui_print "- Extracting OpenWRT rootfs to $CONTAINER_DIR..."
    tar -xf "${CONTAINER_DIR}/rootfs.tar.gz" -C "${CONTAINER_DIR}" --strip-components=0
    if [[ $? != 0 ]]; then
        abort "- OpenWRT rootfs extract failed! Check if the file is corrupted."
    fi

    # 5. 删除临时压缩包（节省空间）
    rm -f "${CONTAINER_DIR}/rootfs.tar.gz"
    ui_print "- Extract completed! Rootfs size: $(du -sh ${CONTAINER_DIR} | awk '{print $1}')"
}

automatic() {
    ui_print "- Require network! Connect to WiFi if possible."

    # 优先下载 OpenWRT
    if [ "${RURIMA_LXC_OS}" = "openwrt" ]; then
        download_openwrt
    else
        # 原版 LXC 下载逻辑
        ui_print "- Downloading from ${RURIMA_LXC_MIRROR}..."
        rurima lxc pull -n -m ${RURIMA_LXC_MIRROR} -o ${RURIMA_LXC_OS} -v ${RURIMA_LXC_OS_VERSION} -s "$CONTAINER_DIR"
        if [[ $? != 0 ]]; then
            ui_print "- Retry from fallback ${RURIMA_LXC_MIRROR_FALLBACK}..."
            rurima lxc pull -n -m ${RURIMA_LXC_MIRROR_FALLBACK} -o ${RURIMA_LXC_OS} -v ${RURIMA_LXC_OS_VERSION} -s "$CONTAINER_DIR"
        fi
    fi

    ui_print "- Starting chroot installation..."
    ui_print "- Please wait, this may take a few minutes!"
    ui_print ""
    sleep 2
    getprop ro.product.model > "$CONTAINER_DIR/etc/hostname"
    mkdir -p "$CONTAINER_DIR/tmp" "$CONTAINER_DIR/usr/local/lib/servicectl/enabled"
    cp "$MODPATH/setup/setup.sh" "$CONTAINER_DIR/tmp/setup.sh"
    cp -r "$MODPATH/setup/servicectl"/* "$CONTAINER_DIR/usr/local/lib/servicectl/"
    chmod 777 "$CONTAINER_DIR/tmp/setup.sh" "$CONTAINER_DIR/usr/local/lib/servicectl/"*

    # 执行 setup.sh 初始化
    ruri "$CONTAINER_DIR" /bin/sh /tmp/setup.sh "$RURIMA_LXC_OS" "$PASSWORD" "$PORT"
    ruri -U "$CONTAINER_DIR"

    ui_print "- Installation completed!"
    ui_print "- WARNING: Change default password immediately! (passwd)"
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

set_perm "$MODPATH/container_ctrl.sh" 0 0 0755

ui_print ""
(sleep 5 && reboot) &
ui_print "System will restart in 5 seconds..."
