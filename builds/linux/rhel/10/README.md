# RHEL 10

Build for RHEL 10 with kickstart and Cloud-Init enabled.

Notes:
- Activation key env: REDHAT_SATELLITE_ACTIVATION_KEY_RHEL10
- Satellite server env: REDHAT_SATELLITE_SERVER
- Uses kickstart template in `kickstart/ks.pkrtpl.hcl`.
- `iso_file` takes precedence when set; otherwise `iso_url` downloads and `iso_checksum` validates when provided.
