#version=RHEL10

# RHEL 10
# Accepts the End User License Agreement.
eula --agreed

# Performs the kickstart installation in text mode.
# By default, kickstart installations are performed in graphical mode.
text --non-interactive

# Installs from the first attached CD-ROM/DVD on the system.
cdrom

# Sets the language to use during installation and the default language to use on the installed system.
lang ${ks_language}

# Sets the default keyboard type for the system.
keyboard ${ks_keyboard}

# Sets the system time zone.
timezone ${ks_timezone}

# Configure network information for target system and activate network devices in the installer environment (optional)
# --onboot    enable device at a boot time
# --device    device to be activated and / or configured with the network command
# --bootproto method to obtain networking configuration for device (default dhcp)
# --noipv6    disable IPv6 on this device
network --bootproto=dhcp --activate --onboot=true

# Configure root authentication.
rootpw --iscrypted ${root_password_hash}

# Create build user
user --name=${build_username} --password=${build_password_hash} --iscrypted --gecos="Packer User" --groups=wheel

# Authorize SSH key for root.
sshkey --username=root "${ssh_public_key_root}"
sshkey --username=${build_username} "${ssh_public_key_build}"

# Sets the state of SELinux on the installed system.
# Defaults to enforcing.
selinux --enforcing

# Configure firewall settings for the system.
# --enabled reject incoming connections that are not in response to outbound requests
# --ssh     allow sshd service through the firewall
firewall --enabled --ssh

# Sets up the authentication options for the system.
# The SSSD profile sets sha512 to hash passwords. Passwords are shadowed by default
authselect select sssd

# Modifies the default set of services that will run under the default runlevel.
services --disabled=kdump --enabled=NetworkManager,sshd,chronyd,qemu-guest-agent

# Do not configure X on the system.
skipx

%addon com_redhat_kdump --disable
%end

# Partitioning
bootloader --location=mbr --append="console=ttyS0,115200n8"
clearpart --all --initlabel
part /boot/efi --fstype="efi" --size=600 --fsoptions="umask=0077,shortname=winnt"
part /boot --fstype="xfs" --size=1024
part pv.01 --grow --size=1
volgroup rhel pv.01
logvol none --vgname=rhel --name=thinpool --thinpool --size=51200 --chunksize=512 --grow
logvol / --vgname=rhel --name=root --thin --poolname=thinpool --size=20480 --fstype=xfs
logvol /var --vgname=rhel --name=var --thin --poolname=thinpool --size=10240 --fstype=xfs
logvol /home --vgname=rhel --name=home --thin --poolname=thinpool --size=5120 --fstype=xfs
logvol swap --vgname=rhel --name=swap --thin --poolname=thinpool --size=4096 --fstype=swap

# Packages selection.
%packages --excludedocs
@^minimal-environment
qemu-guest-agent
python3
zsh
git
nfs-utils
openssh-server
curl
vim-minimal
ipa-client
sssd
-iwl*firmware
-bluez
-rdma-core
-infiniband-diags
%end

# Post-installation commands.
%post --log=/root/ks-post.log
# Ensure password auth is enabled for installer SSH access.
cat > /etc/ssh/sshd_config.d/90-packer.conf <<'SSHCONF'
PermitRootLogin yes
PasswordAuthentication yes
Subsystem sftp /usr/libexec/openssh/sftp-server
SSHCONF

systemctl enable qemu-guest-agent
systemctl restart sshd

echo "${build_username} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/${build_username}
sed -i "s/^.*requiretty/#Defaults requiretty/" /etc/sudoers

%end

# Reboot after the installation is complete.
# --eject attempt to eject the media before rebooting.
reboot --eject
