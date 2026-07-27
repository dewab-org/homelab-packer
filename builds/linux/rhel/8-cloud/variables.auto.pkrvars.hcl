# Base template 9128 is bootstrapped from the upstream qcow2 by
# builds/linux/common/scripts/bootstrap-cloud-bases.py (see
# builds/linux/common/cloud-base-images.json for the pinned image + sha256).
clone_vm_id   = 9128
vm_id         = 9138
template_name = "rhel-8-cloud"
tags          = "rhel;cloud-init;packer"
rhel_subscription = true
