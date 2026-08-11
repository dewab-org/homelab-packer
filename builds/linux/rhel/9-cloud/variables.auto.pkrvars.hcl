# Base template 9129 is bootstrapped from the upstream qcow2 by
# builds/linux/common/scripts/bootstrap-cloud-bases.py (see
# builds/linux/common/cloud-base-images.json for the pinned image + sha256).
clone_vm_id       = 9129
vm_id             = 9139
template_name     = "rhel-9-cloud"
tags              = "rhel;cloud-init;packer"
rhel_subscription = true
