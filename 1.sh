#!/bin/bash

# IMPORTANT - contents of this script must be idempotent

# Here's the syntax to do an idempotent line replace or append from a file.
# <SourceString> = The start of the line you want to replace. For example, the word AllowUsers which has a line like "AllowUsers cxadmin"
# <DestinationString> = The complete line you want to exist in the file
# <FileName> = The full path of the file you are modifying
#grep -q "^<SourceString>.*" <FileName> && sed "s/^<SourceString>.*/<DestinationString>/" -i <FileName> ||
#    sed "$ a\<DestinationString>" -i <FileName>

# Function to find the proper device name (e.g. /dev/sdc) based on the LUN.
findDeviceName() {
    LUN="${1}"
    # These devices are always on SCSI host 1
    lsscsi -b "1:::${LUN}" | awk '{print $2}'
}

# Function to mount Azure File Share
mount_azure_file_share() {
    # Install cifs-utils package
    sudo yum install cifs-utils -y
    mkdir -p /etc/smbcredentials

    # Check if 'oracle' user exists
    if id "oracle" &>/dev/null; then
        ORACLEUID=$(id -u oracle)
        ORACLEGID=$(id -g oracle)
    else
        echo "User 'oracle' does not exist."
        exit 1
    fi

    mkdir -p /mnt/rman

    # Change ownership
    chown oracle: /mnt/rman
    
    # Determine which mount targets to use based on environment
    case ${ENVIRONMENT_GROUP} in
        "dev")
            TARGETS=("dev")
            ;;
        "nonprod")
            TARGETS=("nonprod")
            ;;
        "prod")
            TARGETS=("nonprod","prod")
            ;;
        *)
            echo "Invalid environment group specified."
            exit 1
            ;;
    esac    


    # Split the storage account names, keys, hostnmes, mount targets and loop through each
    IFS=',' read -ra ACCOUNTS <<<"${STORAGE_ACCOUNT_NAME}"
    IFS=',' read -ra KEYS <<<"${STORAGE_ACCOUNT_KEY}"
    IFS=',' read -ra HOSTNAMES <<<"${STORAGE_ACCOUNT_HOSTNAME}"
    IFS=',' read -ra FILE_SHARES <<<"${FILE_SHARE}"
    IFS=',' read -ra MOUNT_TARGETS <<<"${TARGETS}"
        
    for index in "${!ACCOUNTS[@]}"; do
        storage_account=${ACCOUNTS[index]}
        storage_key=${KEYS[index]}
        storage_account_hostname=${HOSTNAMES[index]}
        file_share=${FILE_SHARES[index]}

        # Initialize each storage account credential file and other operations
        credential_file="/etc/smbcredentials/${storage_account}.cred"
        touch "${credential_file}"
        echo "username=${storage_account}" | sudo tee "${credential_file}" >/dev/null
        echo "password=${storage_key}" | sudo tee -a "${credential_file}" >/dev/null
        chmod 600 "${credential_file}"
        
        # Mount targets if they're not already mounted
            MOUNT_POINT="/mnt/rman/${MOUNT_TARGETS[index]}"

            [ ! -d "${MOUNT_POINT}" ] && mkdir -p "${MOUNT_POINT}"

            if ! mountpoint -q "${MOUNT_POINT}"; then
                sudo mount -t cifs "//${storage_account_hostname}/${file_share}" "${MOUNT_POINT}" -o vers=3.0,credentials=/etc/smbcredentials/${storage_account}.cred,uid=${ORACLEUID},gid=${ORACLEGID},serverino,sec=ntlmssp
            fi

            # Add to fstab if not already present
            FSTAB_ENTRY="//${storage_account_hostname}/${file_share} ${MOUNT_POINT} cifs nofail,vers=3.0,credentials=/etc/smbcredentials/${storage_account}.cred,uid=${ORACLEUID},gid=${ORACLEGID},serverino"
            if ! grep -qF "${FSTAB_ENTRY}" /etc/fstab; then
                echo "${FSTAB_ENTRY}" | sudo tee -a /etc/fstab >/dev/null
            fi
    done

}

# Set variables from arguments passed in by Terraform custom script extension
CLIENTCODE="${1}"
LINUXTIMEZONE="${2}"
SHORTNAME="${3}"
ENVIRONMENT_GROUP="${4}"
STORAGE_ACCOUNT_NAME="${5}"
STORAGE_ACCOUNT_KEY="${6}"
FILE_SHARE="${7}"
STORAGE_ACCOUNT_HOSTNAME="${8}"

# Data Disks expected by image
DEVICE_U01=$(findDeviceName 0)
DEVICE_U02=$(findDeviceName 1)

# Extra archive storage disks
DEVICE_U03=$(findDeviceName 2)
DEVICE_U04=$(findDeviceName 3)

# Expand drives u01 and u02
echo "Expanding drives to max size"
pvresize "${DEVICE_U01}"
pvresize "${DEVICE_U02}"
lvextend -l+100%FREE -r /dev/mapper/vg_u01-lv_u01
lvextend -l+100%FREE -r /dev/mapper/vg_u02-lv_u02

# Initialize and mount u03 and u04 if not already present in fstab
echo "Checking for u03 disk information"
if ! grep -qF '/dev/mapper/vg_u03-lv_u03' /etc/fstab; then
    echo "Initializing disk u03"
    vgcreate vg_u03 "${DEVICE_U03}"
    lvcreate -l+100%FREE -n lv_u03 vg_u03
    mkfs -t ext4 /dev/vg_u03/lv_u03
    mkdir /u03
    mount -t ext4 /dev/vg_u03/lv_u03 /u03
    echo "/dev/mapper/vg_u03-lv_u03 /u03  ext4  defaults,noatime,nofail,discard  1 2" >>/etc/fstab
fi

echo "Checking for u04 disk information"
if ! grep -qF '/dev/mapper/vg_u04-lv_u04' /etc/fstab; then
    echo "Initializing disk u04"
    vgcreate vg_u04 "${DEVICE_U04}"
    lvcreate -l+100%FREE -n lv_u04 vg_u04
    mkfs -t ext4 /dev/vg_u04/lv_u04
    mkdir /u04
    mount -t ext4 /dev/vg_u04/lv_u04 /u04
    echo "/dev/mapper/vg_u04-lv_u04 /u04  ext4  defaults,noatime,nofail,discard  1 2" >>/etc/fstab
fi

# Mount file share
mount_azure_file_share

# Set Bootloader Password
echo "Checking for bootloader password"
if [ ! -f /boot/efi/EFI/redhat/user.cfg ]; then
    echo "Setting bootloader password"
    echo "printf '%s\n' \"$BOOTLOADERPASSWORD\" \"$BOOTLOADERPASSWORD\" | script -qf -c 'grub2-setpassword' /dev/null" >/tmp/grub-pass.sh
    chmod +x /tmp/grub-pass.sh
    nohup bash /tmp/grub-pass.sh &
    rm -f /tmp/grub-pass.sh
fi


# Set TimeZone
echo "Set TimeZone to client time"
timedatectl set-timezone "${LINUXTIMEZONE}"

echo "Configuring time synchronization"

cat <<EOF >/etc/chrony.conf
# Use PTP source clock, provided by the Hyper-V host
local stratum 2
refclock PHC /dev/ptp_hyperv poll 3 dpoll -2 offset 0

# Windows time server, as a secondary source
server time.windows.com

# Allow the system clock to be stepped if its offset is larger than 1 second.
makestep 1.0 -1

# Record the rate at which the system clock gains/losses time.
driftfile /var/lib/chrony/drift
EOF

# Restart the chronyd service to apply changes
systemctl restart chronyd

# TODO: PC3-984 -- Commented out because currently there is no design for the DatabaseVM to be able to resolve a DNS name to its IP address.
# # Update postfix config for fqdn
# if ! grep -qF "relayhost = [emailrelay-internal]" /etc/postfix/main.cf; then
#   grep -q "^relayhost.*" /etc/postfix/main.cf && sed "s/^relayhost.*/relayhost = [emailrelay-internal.cc${CLIENTCODE}.local]/" -i /etc/postfix/main.cf ||
#     sed "$ a\relayhost = [emailrelay-internal.cc${CLIENTCODE}.local]" -i /etc/postfix/main.cf
#   systemctl restart postfix
# fi

# Set SSHD back to 900 because waagent removes it
echo "Update SSHD ClientAliveInterval to 900"
sed -i 's/ClientAliveInterval 180/ClientAliveInterval 900/g' /etc/ssh/sshd_config

# Create users required by BeyondTrust PRA
# -m creates a home directory
# -g adds to the dba group, which already exists
useradd -m -g dba -c "Database Administrator user" dba
useradd -m -c "System Admin user" systemsadmin
# Members of the wheel group are able to use sudo to obtain all root privileges
usermod -aG wheel dba
usermod -aG wheel systemsadmin

# # [sshd_config] add to AllowUsers list, for BeyondTrust PRA purposes
echo "Modify SSHD AllowUsers list"
grep -q "^AllowUsers.*" /etc/ssh/sshd_config && sed "s/^AllowUsers.*/AllowUsers cxadmin oracle svc.secscan dba systemsadmin/" -i /etc/ssh/sshd_config ||
    sed "$ a\AllowUsers cxadmin oracle svc.secscan dba systemsadmin" -i /etc/ssh/sshd_config

# Create a Sudoers file for BeyondTrust PRA users, since BeyondTrust PRA can't pass credentials for SUDO
echo "Create new sudoers file"
echo "dba ALL=(ALL:ALL) NOPASSWD: ALL
systemsadmin ALL=(ALL:ALL) NOPASSWD: ALL" >/etc/sudoers.d/pamusers
chmod 0440 /etc/sudoers.d/pamusers

# Create svc.secscan user for Rapid7 scanning occurred during image build, so we just modify here
echo "adding svc.secscan user and config"

# Add the public CLIENT key to the svc.secscan account (Sourced from PasswordState)
if ! grep -qF "${RAPID7SCANPUBKEY}" /home/svc.secscan/.ssh/authorized_keys; then
    echo "${RAPID7SCANPUBKEY}" >/home/svc.secscan/.ssh/authorized_keys
fi
# Reset permission on authorized_keys just in case
chown -R svc.secscan:svc.secscan /home/svc.secscan/.ssh
chmod 644 /home/svc.secscan/.ssh/authorized_keys
chmod 700 /home/svc.secscan/.ssh

# Restart SSHD
echo "restart SSHD"
systemctl restart sshd

echo "End post_deploy.sh script"
