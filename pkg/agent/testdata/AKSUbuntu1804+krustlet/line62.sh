#!/bin/bash

echo "Sourcing cse_install_distro.sh for Ubuntu"

removeMoby() {
    apt_get_purge 10 5 300 moby-engine moby-cli
}

removeContainerd() {
    apt_get_purge 10 5 300 moby-containerd
}

installDeps() {
    if [[ $(isARM64) == 1 ]]; then
        wait_for_apt_locks
        if [ "${UBUNTU_RELEASE}" == "22.04" ]; then
            retrycmd_if_failure_no_stats 120 5 25 curl -fsSL https://packages.microsoft.com/config/ubuntu/${UBUNTU_RELEASE}/packages-microsoft-prod.deb > /tmp/packages-microsoft-prod.deb || exit $ERR_MS_PROD_DEB_DOWNLOAD_TIMEOUT
        else
            retrycmd_if_failure_no_stats 120 5 25 curl -fsSL https://packages.microsoft.com/config/ubuntu/${UBUNTU_RELEASE}/multiarch/packages-microsoft-prod.deb > /tmp/packages-microsoft-prod.deb || exit $ERR_MS_PROD_DEB_DOWNLOAD_TIMEOUT
        fi
    else
        retrycmd_if_failure_no_stats 120 5 25 curl -fsSL https://packages.microsoft.com/config/ubuntu/${UBUNTU_RELEASE}/packages-microsoft-prod.deb > /tmp/packages-microsoft-prod.deb || exit $ERR_MS_PROD_DEB_DOWNLOAD_TIMEOUT
    fi
    retrycmd_if_failure 60 5 10 dpkg -i /tmp/packages-microsoft-prod.deb || exit $ERR_MS_PROD_DEB_PKG_ADD_FAIL

    aptmarkWALinuxAgent hold
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
    apt_get_dist_upgrade || exit $ERR_APT_DIST_UPGRADE_TIMEOUT
    BLOBFUSE_VERSION="1.4.5"
    local OSVERSION
    OSVERSION=$(grep DISTRIB_RELEASE /etc/*-release| cut -f 2 -d "=")
    if [ "${OSVERSION}" == "16.04" ]; then
        BLOBFUSE_VERSION="1.3.7"
    fi

    if [[ $(isARM64) != 1 ]]; then
      # no blobfuse package in arm64 ubuntu repo
      pkg_list=(blobfuse=${BLOBFUSE_VERSION} blobfuse2)
      if [[ "${OSVERSION}" == "22.04" ]]; then
        # blobfuse package is not available on Ubuntu 22.04
        pkg_list=(blobfuse2)
      fi
      for apt_package in ${pkg_list[*]}; do
        if ! apt_get_install 30 1 600 $apt_package; then
          journalctl --no-pager -u $apt_package
          exit $ERR_APT_INSTALL_TIMEOUT
        fi
      done
    fi

    for apt_package in apache2-utils apt-transport-https ca-certificates ceph-common cgroup-lite cifs-utils conntrack cracklib-runtime ebtables ethtool fuse git glusterfs-client htop iftop init-system-helpers inotify-tools iotop iproute2 ipset iptables jq libpam-pwquality libpwquality-tools mount nfs-common pigz socat sysfsutils sysstat traceroute util-linux xz-utils netcat dnsutils zip rng-tools; do
      if ! apt_get_install 30 1 600 $apt_package; then
        journalctl --no-pager -u $apt_package
        exit $ERR_APT_INSTALL_TIMEOUT
      fi
    done
}

installSGXDrivers() {
    if [[ $(isARM64) == 1 ]]; then
        # no intel sgx on arm64
        return
    fi

    echo "Installing SGX driver"
    local VERSION
    VERSION=$(grep DISTRIB_RELEASE /etc/*-release| cut -f 2 -d "=")
    case $VERSION in
    "18.04")
        SGX_DRIVER_URL="https://download.01.org/intel-sgx/dcap-1.2/linux/dcap_installers/ubuntuServer18.04/sgx_linux_x64_driver_1.12_c110012.bin"
        ;;
    "16.04")
        SGX_DRIVER_URL="https://download.01.org/intel-sgx/dcap-1.2/linux/dcap_installers/ubuntuServer16.04/sgx_linux_x64_driver_1.12_c110012.bin"
        ;;
    "*")
        echo "Version $VERSION is not supported"
        exit 1
        ;;
    esac

    local PACKAGES="make gcc dkms"
    wait_for_apt_locks
    retrycmd_if_failure 30 5 3600 apt-get -y install $PACKAGES  || exit $ERR_SGX_DRIVERS_INSTALL_TIMEOUT

    local SGX_DRIVER
    SGX_DRIVER=$(basename $SGX_DRIVER_URL)
    local OE_DIR=/opt/azure/containers/oe
    mkdir -p ${OE_DIR}

    retrycmd_if_failure 120 5 25 curl -fsSL ${SGX_DRIVER_URL} -o ${OE_DIR}/${SGX_DRIVER} || exit $ERR_SGX_DRIVERS_INSTALL_TIMEOUT
    chmod a+x ${OE_DIR}/${SGX_DRIVER}
    ${OE_DIR}/${SGX_DRIVER} || exit $ERR_SGX_DRIVERS_START_FAIL
}

updateAptWithMicrosoftPkg() {
    if [[ $(isARM64) == 1 ]]; then
        if [ "${UBUNTU_RELEASE}" == "22.04" ]; then
            retrycmd_if_failure_no_stats 120 5 25 curl https://packages.microsoft.com/config/ubuntu/${UBUNTU_RELEASE}/prod.list > /tmp/microsoft-prod.list || exit $ERR_MOBY_APT_LIST_TIMEOUT
        else
            retrycmd_if_failure_no_stats 120 5 25 curl https://packages.microsoft.com/config/ubuntu/${UBUNTU_RELEASE}/multiarch/prod.list > /tmp/microsoft-prod.list || exit $ERR_MOBY_APT_LIST_TIMEOUT
        fi
    else
        retrycmd_if_failure_no_stats 120 5 25 curl https://packages.microsoft.com/config/ubuntu/${UBUNTU_RELEASE}/prod.list > /tmp/microsoft-prod.list || exit $ERR_MOBY_APT_LIST_TIMEOUT
    fi

    retrycmd_if_failure 10 5 10 cp /tmp/microsoft-prod.list /etc/apt/sources.list.d/ || exit $ERR_MOBY_APT_LIST_TIMEOUT
    if [[ ${UBUNTU_RELEASE} == "18.04" ]]; then {
        echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/ubuntu/18.04/multiarch/prod testing main" > /etc/apt/sources.list.d/microsoft-prod-testing.list
    }
    elif [[ ${UBUNTU_RELEASE} == "20.04" || ${UBUNTU_RELEASE} == "22.04" ]]; then {
        echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/ubuntu/${UBUNTU_RELEASE}/prod testing main" > /etc/apt/sources.list.d/microsoft-prod-testing.list
    }
    fi
    
    retrycmd_if_failure_no_stats 120 5 25 curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/microsoft.gpg || exit $ERR_MS_GPG_KEY_DOWNLOAD_TIMEOUT
    retrycmd_if_failure 10 5 10 cp /tmp/microsoft.gpg /etc/apt/trusted.gpg.d/ || exit $ERR_MS_GPG_KEY_DOWNLOAD_TIMEOUT
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
}

cleanUpGPUDrivers() {
    rm -Rf $GPU_DEST /opt/gpu
}

# CSE+VHD can dictate the containerd version, users don't care as long as it works
installStandaloneContainerd() {
    UBUNTU_RELEASE=$(lsb_release -r -s)
    UBUNTU_CODENAME=$(lsb_release -c -s)
    CONTAINERD_VERSION=$1
    # azure-built runtimes have a "+azure" suffix in their version strings (i.e 1.4.1+azure). remove that here.
    CURRENT_VERSION=$(containerd -version | cut -d " " -f 3 | sed 's|v||' | cut -d "+" -f 1)
    CURRENT_COMMIT=$(containerd -version | cut -d " " -f 4)
    # v1.4.1 is our lowest supported version of containerd

    if [ -z "$CURRENT_VERSION" ]; then
        CURRENT_VERSION="0.0.0"
    fi
    
    # we always default to the .1 patch versons
    CONTAINERD_PATCH_VERSION="${2:-1}"

    # runc needs to be installed first or else existing vhd version causes conflict with containerd.
    logs_to_events "AKS.CSE.installContainerRuntime.ensureRunc" "ensureRunc ${RUNC_VERSION:-""}" # RUNC_VERSION is an optional override supplied via NodeBootstrappingConfig api

    # the user-defined package URL is always picked first, and the other options won't be tried when this one fails
    CONTAINERD_PACKAGE_URL="${CONTAINERD_PACKAGE_URL:=}"
    if [[ ! -z ${CONTAINERD_PACKAGE_URL} ]]; then
        echo "Installing containerd from user input: ${CONTAINERD_PACKAGE_URL}"
        # we'll use a user-defined containerd package to install containerd even though it's the same version as
        # the one already installed on the node considering the source is built by the user for hotfix or test
        logs_to_events "AKS.CSE.installContainerRuntime.removeMoby" removeMoby
        logs_to_events "AKS.CSE.installContainerRuntime.removeContainerd" removeContainerd
        logs_to_events "AKS.CSE.installContainerRuntime.downloadContainerdFromURL" downloadContainerdFromURL ${CONTAINERD_PACKAGE_URL}
        logs_to_events "AKS.CSE.installContainerRuntime.installDebPackageFromFile" "installDebPackageFromFile ${CONTAINERD_DEB_FILE}" || exit $ERR_CONTAINERD_INSTALL_TIMEOUT
        echo "Succeeded to install containerd from user input: ${CONTAINERD_PACKAGE_URL}"
        return 0
    fi

    #if there is no containerd_version input from RP, use hardcoded version
    if [[ -z ${CONTAINERD_VERSION} ]]; then
        CONTAINERD_VERSION="1.4.13"
        CONTAINERD_PATCH_VERSION="2"
        echo "Containerd Version not specified, using default version: ${CONTAINERD_VERSION}-${CONTAINERD_PATCH_VERSION}"
    else
        echo "Using specified Containerd Version: ${CONTAINERD_VERSION}-${CONTAINERD_PATCH_VERSION}"
    fi

    CURRENT_MAJOR_MINOR="$(echo $CURRENT_VERSION | tr '.' '\n' | head -n 2 | paste -sd.)"
    DESIRED_MAJOR_MINOR="$(echo $CONTAINERD_VERSION | tr '.' '\n' | head -n 2 | paste -sd.)"
    HAS_GREATER_VERSION="$(semverCompare "$CURRENT_VERSION" "$CONTAINERD_VERSION")"

    if [[ "$HAS_GREATER_VERSION" == "0" ]] && [[ "$CURRENT_MAJOR_MINOR" == "$DESIRED_MAJOR_MINOR" ]]; then
        echo "currently installed containerd version ${CURRENT_VERSION} matches major.minor with higher patch ${CONTAINERD_VERSION}. skipping installStandaloneContainerd."
    else
        echo "installing containerd version ${CONTAINERD_VERSION}"
        logs_to_events "AKS.CSE.installContainerRuntime.removeMoby" removeMoby
        logs_to_events "AKS.CSE.installContainerRuntime.removeContainerd" removeContainerd
        # if containerd version has been overriden then there should exist a local .deb file for it on aks VHDs (best-effort)
        # if no files found then try fetching from packages.microsoft repo
        CONTAINERD_DEB_FILE="$(ls ${CONTAINERD_DOWNLOADS_DIR}/moby-containerd_${CONTAINERD_VERSION}*)"
        if [[ -f "${CONTAINERD_DEB_FILE}" ]]; then
            logs_to_events "AKS.CSE.installContainerRuntime.installDebPackageFromFile" "installDebPackageFromFile ${CONTAINERD_DEB_FILE}" || exit $ERR_CONTAINERD_INSTALL_TIMEOUT
            return 0
        fi
        logs_to_events "AKS.CSE.installContainerRuntime.downloadContainerdFromVersion" "downloadContainerdFromVersion ${CONTAINERD_VERSION} ${CONTAINERD_PATCH_VERSION}"
        CONTAINERD_DEB_FILE="$(ls ${CONTAINERD_DOWNLOADS_DIR}/moby-containerd_${CONTAINERD_VERSION}*)"
        if [[ -z "${CONTAINERD_DEB_FILE}" ]]; then
            echo "Failed to locate cached containerd deb"
            exit $ERR_CONTAINERD_INSTALL_TIMEOUT
        fi
        logs_to_events "AKS.CSE.installContainerRuntime.installDebPackageFromFile" "installDebPackageFromFile ${CONTAINERD_DEB_FILE}" || exit $ERR_CONTAINERD_INSTALL_TIMEOUT
        return 0
    fi
}

downloadContainerdFromVersion() {
    CONTAINERD_VERSION=$1
    mkdir -p $CONTAINERD_DOWNLOADS_DIR
    # Adding updateAptWithMicrosoftPkg since AB e2e uses an older image version with uncached containerd 1.6 so it needs to download from testing repo.
    # And RP no image pull e2e has apt update restrictions that prevent calls to packages.microsoft.com in CSE
    # This won't be called for new VHDs as they have containerd 1.6 cached
    updateAptWithMicrosoftPkg 
    apt_get_download 20 30 moby-containerd=${CONTAINERD_VERSION}* || exit $ERR_CONTAINERD_INSTALL_TIMEOUT
    cp -al ${APT_CACHE_DIR}moby-containerd_${CONTAINERD_VERSION}* $CONTAINERD_DOWNLOADS_DIR/ || exit $ERR_CONTAINERD_INSTALL_TIMEOUT
}

downloadContainerdFromURL() {
    CONTAINERD_DOWNLOAD_URL=$1
    mkdir -p $CONTAINERD_DOWNLOADS_DIR
    CONTAINERD_DEB_TMP=${CONTAINERD_DOWNLOAD_URL##*/}
    retrycmd_curl_file 120 5 60 "$CONTAINERD_DOWNLOADS_DIR/${CONTAINERD_DEB_TMP}" ${CONTAINERD_DOWNLOAD_URL} || exit $ERR_CONTAINERD_DOWNLOAD_TIMEOUT
    CONTAINERD_DEB_FILE="$CONTAINERD_DOWNLOADS_DIR/${CONTAINERD_DEB_TMP}"
}

installMoby() {
    ensureRunc ${RUNC_VERSION:-""} # RUNC_VERSION is an optional override supplied via NodeBootstrappingConfig api
    CURRENT_VERSION=$(dockerd --version | grep "Docker version" | cut -d "," -f 1 | cut -d " " -f 3 | cut -d "+" -f 1)
    local MOBY_VERSION="19.03.14"
    local MOBY_CONTAINERD_VERSION="1.4.13"
    if semverCompare ${CURRENT_VERSION:-"0.0.0"} ${MOBY_VERSION}; then
        echo "currently installed moby-docker version ${CURRENT_VERSION} is greater than (or equal to) target base version ${MOBY_VERSION}. skipping installMoby."
    else
        removeMoby
        updateAptWithMicrosoftPkg
        MOBY_CLI=${MOBY_VERSION}
        if [[ "${MOBY_CLI}" == "3.0.4" ]]; then
            MOBY_CLI="3.0.3"
        fi
        apt_get_install 20 30 120 moby-engine=${MOBY_VERSION}* moby-cli=${MOBY_CLI}* moby-containerd=${MOBY_CONTAINERD_VERSION}* --allow-downgrades || exit $ERR_MOBY_INSTALL_TIMEOUT
    fi
}

ensureRunc() {
    RUNC_PACKAGE_URL="${RUNC_PACKAGE_URL:=}"
    # the user-defined runc package URL is always picked first, and the other options won't be tried when this one fails
    if [[ ! -z ${RUNC_PACKAGE_URL} ]]; then
        echo "Installing runc from user input: ${RUNC_PACKAGE_URL}"
        mkdir -p $RUNC_DOWNLOADS_DIR
        RUNC_DEB_TMP=${RUNC_PACKAGE_URL##*/}
        RUNC_DEB_FILE="$RUNC_DOWNLOADS_DIR/${RUNC_DEB_TMP}"
        retrycmd_curl_file 120 5 60 ${RUNC_DEB_FILE} ${RUNC_PACKAGE_URL} || exit $ERR_RUNC_DOWNLOAD_TIMEOUT
        # we'll use a user-defined containerd package to install containerd even though it's the same version as
        # the one already installed on the node considering the source is built by the user for hotfix or test
        installDebPackageFromFile ${RUNC_DEB_FILE} || exit $ERR_RUNC_INSTALL_TIMEOUT
        echo "Succeeded to install runc from user input: ${RUNC_PACKAGE_URL}"
        return 0
    fi

    TARGET_VERSION=${1:-""}
    if [[ -z ${TARGET_VERSION} ]]; then
        TARGET_VERSION="1.0.3"

        if [[ $(isARM64) == 1 ]]; then
            # RUNC versions of 1.0.3 later might not be available in Ubuntu AMD64/ARM64 repo at the same time
            # so use different target version for different arch to avoid affecting each other during provisioning
            TARGET_VERSION="1.0.3"
        fi
    fi

    if [[ $(isARM64) == 1 ]]; then
        if [[ ${TARGET_VERSION} == "1.0.0-rc92" || ${TARGET_VERSION} == "1.0.0-rc95" ]]; then
            # only moby-runc-1.0.3+azure-1 exists in ARM64 ubuntu repo now, no 1.0.0-rc92 or 1.0.0-rc95
            return
        fi
    fi

    CPU_ARCH=$(getCPUArch)  #amd64 or arm64
    CURRENT_VERSION=$(runc --version | head -n1 | sed 's/runc version //')
    if [ "${CURRENT_VERSION}" == "${TARGET_VERSION}" ]; then
        echo "target moby-runc version ${TARGET_VERSION} is already installed. skipping installRunc."
        return
    fi
    # if on a vhd-built image, first check if we've cached the deb file
    if [ -f $VHD_LOGS_FILEPATH ]; then
        RUNC_DEB_PATTERN="moby-runc_${TARGET_VERSION/-/\~}+azure-*_${CPU_ARCH}.deb"
        RUNC_DEB_FILE=$(find ${RUNC_DOWNLOADS_DIR} -type f -iname "${RUNC_DEB_PATTERN}" | sort -V | tail -n1)
        if [[ -f "${RUNC_DEB_FILE}" ]]; then
            installDebPackageFromFile ${RUNC_DEB_FILE} || exit $ERR_RUNC_INSTALL_TIMEOUT
            return 0
        fi
    fi
    apt_get_install 20 30 120 moby-runc=${TARGET_VERSION/-/\~}* --allow-downgrades || exit $ERR_RUNC_INSTALL_TIMEOUT
}

#EOF
