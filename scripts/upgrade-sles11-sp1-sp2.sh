#!/bin/bash

# Remi Bergsma github@remi.nl
# Script to perform upgrade from SLES 11 SP1 -> SP2
# We have servers 'wget' and then 'run' this script
# and monitor 'syslog' (via Logstash) for results.

# Error var
ERROR=""

# Run a given command and log its result
function runCmd {
    if [ ! -z "$1" ]; then
        eval "$1"
        rc=$?
        if [ $rc -gt 0 ]; then
            ERRMSG="Error: $2: cmd '$1' returned code $rc"
            echo "$ERRMSG"
            logger -p daemon.crit -t SLES11-upgrade "SP2-UPGRADE: ${ERRMSG}"
            ERROR+=" '$2'"
        else
            echo "Successfully ran '$1'"
        fi
    fi
}

# Check kernel version 
function kernel_version {
        # Check for the update kernel
        if [ "$(uname -r| cut -d "-" -f1 )" = "2.6.32.12" ] ; then 
            echo "Running 2.6 kernel detected"
        else 
            logger -p daemon.crit -t SLES11-upgrade "SP2: Unexpected kernel version detected, need SP1 2.6 kernel!"
            echo "**** ERROR **** on $(hostname): Unexpected kernel version detected, need SP1 2.6 kernel!"
            ERROR+=" 'unexpected kernel'"
            exit 1
        fi     
}

# Detect OS version
function detect_os {
    SLES_FILE="/etc/SuSE-release"
    RHEL_FILE="/etc/redhat-release"

    if [ -f $SLES_FILE ] ; then                                                                          
        LINUXVERSION="SLES"
        VERSION=$(grep VERSION $SLES_FILE | awk {'print $3'})
        SPVERSION=$(grep PATCHLEVEL $SLES_FILE | awk {'print $3'})
    elif [ -f $RHEL_FILE ] ; then
        LINUXVERSION="RHEL"
        VERSION=$(grep VERSION $RHEL_FILE | awk {'print $7'}| cut -d. -f1)
        SPVERSION=$(grep PATCHLEVEL $RHEL_FILE | awk {'print $3'}| cut -d. -f2)
    fi
}

# For debug purposes
function print_os_version {
    detect_os
    echo "LINUX is $LINUXVERSION, VERSION is $VERSION and SPVERSION is $SPVERSION on $(hostname)!"
}

# Make sure we only run on SLES 11 SP1
detect_os
if [[ $LINUXVERSION -ne "SLES" ]] || [[ $VERSION -ne 11 ]] || [[ $SPVERSION -ne 1 ]]; then
    echo "**** ERROR Not SLES 11 SP1 ****"
    logger -p daemon.crit -t SLES11-upgrade "SP2: ERROR not running SLES 11 SP1. Stopping upgrade!"
    exit 1
fi

# check kernel version
kernel_version

# Enable multi kernel support (save the old kernel)
cp -pr /etc/zypp/zypp.conf /etc/zypp/zypp.conf.orig
CMD="sed -i 's/^multiversion/#multiversion/g' /etc/zypp/zypp.conf"
runCmd "${CMD}" " multiversion_sed"

echo "# Enable multi kernel support
multiversion = provides:multiversion(kernel)
multiversion.kernels = latest,latest-2,running,2.6.32.12-0.7
" >> /etc/zypp/zypp.conf
rc=$?
if [ $rc -gt 0 ]; then
    echo "**** ERROR adding multiversion returned code $rc ****"
    ERROR+=" 'multiversion'"
else
    echo "Successfully enabled multiversion in /etc/zypp/zypp.conf"
fi

# SLES 11 SP1 does not handle the 'multiversion' properly:
# So, copy the 2.6 kernel modules (zypper will save the kernel but not the modules :s)
# Move is faster, but we need to keep the modules in place since we run 2.6 while this script runs
WHAT="Copy 2.6 kernel modules"
CMD="cp -pr /lib/modules/2.6.32.12-0.7-default /lib/modules/2.6.32.12-0.7-default-saved"
echo ${WHAT}
runCmd "${CMD}" "${WHAT}"

# Upgrade all SP1 packages last version - this brings in the 11.2 repo's
WHAT="Update current packages to last version"
CMD="zypper --non-interactive --no-gpg-checks up"
echo ${WHAT}
runCmd "${CMD}" "${WHAT}"

# Clean caches
WHAT="Clean repo caches"
CMD="zypper clean"
echo ${WHAT}
runCmd "${CMD}" "${WHAT}"

# Refresh
WHAT="Refresh repo"
CMD="zypper --no-gpg-checks ref"
echo ${WHAT}
runCmd "${CMD}" "${WHAT}"

# Remove old release file 
WHAT="Remove SLES11.1 release file"
CMD="zypper --no-gpg-checks --non-interactive rm sles-release-11.1"
echo ${WHAT}
runCmd "${CMD}" "${WHAT}"

# Upgrade all packages
WHAT="Upgrade all packages"
CMD="zypper --no-gpg-checks --non-interactive up"
echo ${WHAT}
runCmd "${CMD}" "${WHAT}"

# Restore the 2.6 kernel modules, so we can still boot 2.6 with SP2
WHAT="Restore 2.6 kernel modules"
CMD="mv /lib/modules/2.6.32.12-0.7-default /lib/modules/2.6.32.12-0.7-default-sp2upgrade-magweg\
&& mv /lib/modules/2.6.32.12-0.7-default-saved /lib/modules/2.6.32.12-0.7-default"
echo ${WHAT}
runCmd "${CMD}" "${WHAT}"

# Boot into our new 3.0 kernel
if [ -z "$ERROR" ]; then
    echo "**** OK **** All OK on $(hostname), now booting into our new kernel!"
    LOGMSG="Upgrade OK, now rebooting into our new SP2 kernel"
    logger -p daemon.info -t SLES11-upgrade "SP2-UPGRADE: ${LOGMSG}"
    sleep 2
    # reboot
    shutdown -r now
else
    # Log msg to stdout
    echo "**** ERROR **** on $(hostname): ($ERROR ); please investigate '/var/log/upgrade-sles11-sp1-sp2.log' and reboot manually."
    # Log msg to Logstash via syslog
    LOGMSG="Error: Host not auto-rebooted due to: $ERROR error(s); please investigate '/var/log/upgrade-sles11-sp1-sp2.log' and reboot manually."
    logger -p daemon.crit -t SLES11-upgrade "SP2-UPGRADE: ${LOGMSG}"
fi
