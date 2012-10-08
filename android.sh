#!/bin/bash

DEVICE=
VENDOR=
DEVICE_NAME=
VARIANT=eng
USE_CCACHE=yes
MAKE_FLAGS=

REPO=`which repo`
#REPO_URL="root@192.168.1.35:/git/gerrit.googlesource.com/git-repo.git"
#REPO_BRANCH="local"
#REPO_NO_VERIFY=yes
#REPO_REFERENCE="root@192.168.1.35:/git/"

FASTBOOT=`which fastboot`
ADB=`which adb`

BOOTIMG_KERNEL_CMDLINE="no_console_suspend=1 wire.search_count=5"
BOOTIMG_KERNEL_BASE=0x11800000

CONFIG=".config"

# $1: directory to store config file to
store_config() {
    PWD=$(cd `dirname $0`; pwd)
    rm -f ${PWD}/${CONFIG}
    echo MAKE_FLAGS=${MAKE_FLAGS} > ${CONFIG}    
    echo USE_CCACHE=${USE_CCACHE} >> ${CONFIG}
    echo DEVICE_NAME=${DEVICE_NAME} >> ${CONFIG}
    echo DEVICE=${DEVICE} >> ${CONFIG}
    echo VENDOR=${VENDOR} >> ${CONFIG}
    echo VARIANT=${VARIANT} >> ${CONFIG}
}

# $1: directory to load config file from
load_config() {
    PWD=$(cd `dirname $0`; pwd)
    . "${PWD}/${CONFIG}"
    if [ $? -ne 0 ]; then
	    echo "ERROR: Could not load ${CONFIG}. Did you run 'config'?"
	    exit -1
    fi
    export USE_CCACHE
}

# $1: manifest git repository
# $2: manifest git branch
do_init() {
    if [ -z ${REPO} ]; then
	    echo "ERROR: 'repo' not found. Abort!"
	    exit -1
    fi
    if [ $# -lt 1 ]; then
        echo "ERROR: Not enough arguments. Abort!"
        exit -1
    fi
    MANIFEST_GIT=$1
    if [ $# -eq 2 ]; then
        MANIFEST_BRANCH=$2
    fi    
    load_config
    rm -rf .repo/manifest*
    if [ -z ${MANIFEST_GIT} ]; then
        echo "ERROR: Please provide manifest's git"
        exit -1
    fi
    if [ -z ${MANIFEST_BRANCH} ]; then
        ${REPO} init -u ${MANIFEST_GIT} -b master
    else
	    ${REPO} init -u ${MANIFEST_GIT} -b ${MANIFEST_BRANCH}
	fi
	ret=$?
	if [ $ret -ne 0 ]; then
	    echo "ERROR: Init failed."
	    exit -1
	fi
	exit 0
}

# $#=0
do_sync() {
    if [ -z ${REPO} ]; then
	    echo "ERROR: 'repo' not found. Abort!"
	    exit -1
    fi
    load_config
    sudo ${REPO} sync
	ret=$?
	if [ $ret -ne 0 ]; then
	    echo "ERROR: Sync failed."
	    exit -1
	fi
	exit 0
}

# $1: device name
# $2 (if have): variant
do_config() {
    if [ $# -lt 1 ]; then
        echo "ERROR: Not enough arguments. Abort!"
        exit -1
    fi
    if [ $# -eq 2 ]; then
        VARIANT=$2
    fi
    CORE_COUNT=`grep processor /proc/cpuinfo | wc -l`
    MAKE_FLAGS="-j$((CORE_COUNT + 2)) ${MAKE_FLAGS}"
    case "$1" in
        "htc_leo")
            DEVICE_NAME=leo
            DEVICE=htc_leo
            VENDOR=htc
        ;;
        "hp_tenderloin")
            DEVICE_NAME=tenderloin
            DEVICE=hp_tenderloin
            VENDOR=hp
        ;;
        *)
            echo "ERROR: Not supported device. Abort!"
            exit -1
        ;;
    esac
    store_config
}

do_build() {
    load_config
    echo "INFO: Target '${DEVICE}-${VARIANT}'"
    DATE_TIME=`date +"%Y%m%d_%H%M%S"`
    LOG_FILE=make_${DATE_TIME}.log
    . build/envsetup.sh &&
    lunch ${DEVICE}-${VARIANT}
    if [ $? -eq 0 ] ; then
        time make $MAKE_FLAGS $@ 2>&1 | tee ${LOG_FILE}
    fi
    ret=$?
	if [ $ret -ne 0 ]; then
	    echo "ERROR: Build failed."
	    exit -1
	fi
    echo "Done."
    exit 0
}

do_erase_partition() {
    if [ -z ${FASTBOOT} ]; then
	    echo "ERROR: 'fastboot' not found. Abort!"
	    exit -1
    fi
    sudo ${FASTBOOT} erase $1
    ret=$?
    if [ $ret -ne 0 ]; then
	    echo "ERROR: Erase failed."
	    exit -1
	fi
}

do_flash_partition() {
    if [ -z ${FASTBOOT} ]; then
	    echo "ERROR: 'fastboot' not found. Abort!"
	    exit -1
    fi
    IMG_PATH="out/target/product/${DEVICE_NAME}/$1.img"
    if [ ! -e ${IMG_PATH} ]; then
        echo "Image for flashing '$1' is not exist. Abort!"
        exit -1
    fi
    do_erase_partition $1
    sudo ${FASTBOOT} flash $1 ${IMG_PATH}
    ret=$?
	if [ $ret -ne 0 ]; then
	    echo "ERROR: Flash failed."
	    exit -1
	fi
}

do_flash() {
    if [ $# -lt 1 ]; then
        echo "ERROR: Not enough arguments. Abort!"
        exit -1
    fi
    load_config
    echo "INFO: Target '${DEVICE}-${VARIANT}'"
    case "$1" in
        "system") do_flash_partition system ;;
        "data" | "userdata") do_flash_partition userdata ;;
        "boot") do_flash_partition boot ;;
        "all") 
            do_erase_partition cache
            do_flash_partition boot
            do_flash_partition userdata
            do_flash_partition system
        ;;
        *)
            echo "Nothing to flash."
        ;;
    esac
    exit 0
}

# $1 (if have): reboot-bootloader 
do_reboot() {
    if [ -z ${FASTBOOT} ]; then
	    echo "ERROR: 'fastboot' not found. Abort!"
	    exit -1
    fi
    if [ $# -eq 0 ]; then
        sudo ${FASTBOOT} reboot
        ret=$?
        if [ $ret -ne 0 ]; then
            echo "ERROR: Reboot failed."
            exit -1
        fi
        exit 0
    fi
    case "$1" in
        "bootloader")
            sudo ${FASTBOOT} reboot-bootloader
            ret=$?
            if [ $ret -ne 0 ]; then
	            echo "ERROR: Reboot bootloader failed."
	            exit -1
	        fi 
        ;;
        *)
            echo "ERROR: incorrect argument '$1'. Abort!"
        ;;
    esac   
}

# $1 (if have): output file
do_logcat() {
    if [ -z ${ADB} ]; then
	    echo "ERROR: 'adb' not found. Abort!"
	    exit -1
    fi
    if [ $# -eq 0 ]; then
        DATE_TIME=`date +"%Y%m%d_%H%M%S"`
        LOG_FILE=logcat_${DATE_TIME}.log
    else
        LOG_FILE=$1        
    fi
    sudo ${ADB} logcat 2>&1 | tee "${LOG_FILE}"
    ret=$?
    if [ $ret -ne 0 ]; then
        echo "ERROR: Logcat failed."
        exit -1
    fi
}

# Flash "raw" initrd.gz & kernel into 'boot' partition
# $1: path to zImage (kernel)
# $2: path to initrd.gz
do_flash_boot() {
    if [ -z ${FASTBOOT} ]; then
	    echo "ERROR: 'fastboot' not found. Abort!"
	    exit -1
    fi
    if [ $# -ne 2 ]; then
        echo "ERROR: Not enough arguments. Abort!"
        exit -1
    fi
    KERNEL_PATH=$1
    INITRD_PATH=$2
    echo "INFO: Kernel: ${KERNEL_PATH}"
    echo "INFO: Kernel command line: ${BOOTIMG_KERNEL_CMDLINE}"
    echo "INFO: Kernel base address: ${BOOTIMG_KERNEL_BASE}"
    echo "INFO: Init Ramdisk: ${INITRD_PATH}"
    sudo ${FASTBOOT} -c "${BOOTIMG_KERNEL_CMDLINE}" -b ${BOOTIMG_KERNEL_BASE} flash:raw boot ${KERNEL_PATH} ${INITRD_PATH}
    ret=$?
    if [ $ret -ne 0 ]; then
        echo "ERROR: Flash boot failed."
        exit -1
    fi
}

# Flash "raw" initrd.gz & kernel into 'sboot' partition
# $1: path to zImage (kernel)
# $2: path to initrd.gz
do_flash_sboot() {
    if [ -z ${FASTBOOT} ]; then
	    echo "ERROR: 'fastboot' not found. Abort!"
	    exit -1
    fi
    if [ $# -ne 2 ]; then
        echo "ERROR: Not enough arguments. Abort!"
        exit -1
    fi
    KERNEL_PATH=$1
    INITRD_PATH=$2
    echo "INFO: Kernel: ${KERNEL_PATH}"
    echo "INFO: Kernel command line: ${BOOTIMG_KERNEL_CMDLINE}"
    echo "INFO: Kernel base address: ${BOOTIMG_KERNEL_BASE}"
    echo "INFO: Init Ramdisk: ${INITRD_PATH}"
    sudo ${FASTBOOT} -c "${BOOTIMG_KERNEL_CMDLINE}" -b ${BOOTIMG_KERNEL_BASE} flash:raw sboot ${KERNEL_PATH} ${INITRD_PATH}
    ret=$?
    if [ $ret -ne 0 ]; then
        echo "ERROR: Flash sboot failed."
        exit -1
    fi
}

do_help() {
    echo "Usage: $0 <COMMAND> [ARGS]                                   "
    echo "Available commands:                                          "
    echo " Common:                                                     "
    echo "    init <MANIFEST_GIT> [MANIFEST_BRANCH]                    "
    echo "    sync                                                     "
    echo "    config [DEVICE:{htc_leo|...}]                            "
    echo "    build                                                    "
    echo "    flash <TARGET:{all|boot|system|userdata|data}>           "
    echo "                                                             "
    echo " Specific purposes:                                          "
    echo "    reboot [bootloader]                                      "
    echo "    logcat [OUTPUT_FILE]                                     "
    echo "    flash-boot [KERNEL:{zImage|kernel}] [INITRD:initrd.gz]"
    echo "    flash-sboot [KERNEL:{zImage|kernel}] [INITRD:initrd.gz]"
    echo "                                                             "
}

if [ $# -lt 1 ]; then
    do_help
    echo "ERROR: Not enough arguments. Abort!"
    exit -1
fi

case "$1" in
    "init") do_init "${@:2}" ;;
    "sync") do_sync "${@:2}" ;;
    "config") do_config "${@:2}" ;;
    "build") do_build "${@:2}" ;;
	"flash") do_flash "${@:2}" ;;
    "reboot") do_reboot "${@:2}" ;;
    "logcat") do_logcat "${@:2}" ;;
    "flash-boot") do_flash_boot "${@:2}" ;;
    "flash-sboot") do_flash_sboot "${@:2}" ;;
    *)
        do_help
    ;;
esac
exit 0
