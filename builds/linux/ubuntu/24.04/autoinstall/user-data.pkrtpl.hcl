#cloud-config
autoinstall:
  version: 1
  source:
    id: ubuntu-server-minimal
  locale: ${ks_language}
  keyboard:
    layout: ${ks_keyboard}
  timezone: ${ks_timezone}
  identity:
    hostname: ubuntu-24-04
    username: ${build_username}
    password: ${build_password_hash}
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - ${ssh_public_key_build}
  storage:
    layout:
      name: lvm
  packages:
    - cloud-init
    - curl
    - git
    - nfs-common
    - python3
    - qemu-guest-agent
    - sudo
    - vim
    - zsh
  user-data:
    disable_root: false
    users:
      - name: root
        lock_passwd: false
        passwd: ${root_password_hash}
        ssh_authorized_keys:
          - ${ssh_public_key_root}
      - name: ${build_username}
        sudo: ALL=(ALL) NOPASSWD:ALL
        primary_group: ${build_username}
        groups: users, admin
        shell: /bin/bash
        lock_passwd: false
        passwd: ${build_password_hash}
        ssh_authorized_keys:
          - ${ssh_public_key_build}
  late-commands:
    - curtin in-target -- sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    - curtin in-target -- sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    - curtin in-target -- systemctl enable qemu-guest-agent
    - curtin in-target -- systemctl enable serial-getty@ttyS0.service
    - curtin in-target -- sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 /' /etc/default/grub
    - curtin in-target -- update-grub
