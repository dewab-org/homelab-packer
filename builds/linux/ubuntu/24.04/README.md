# Ubuntu 24.04

Ubuntu 24.04 template using autoinstall (NoCloud seed ISO).

Required outcomes:
- Autoinstall + Cloud-Init enabled
- QEMU guest agent installed and enabled
- Serial console enabled (installer and runtime)
- Template cleanup after provisioning

Notes:
- Autoinstall seed data lives in `autoinstall/`.
- `iso_file` takes precedence when set; otherwise `iso_url` downloads and `iso_checksum` validates when provided.
- ISO downloads use Packer cache; cache is ignored by git.
