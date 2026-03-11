# Rocky Linux 9

Build for Rocky Linux 9 with kickstart and Cloud-Init enabled.

Notes:
- Uses kickstart template in `kickstart/ks.pkrtpl.hcl`.
- `iso_file` takes precedence when set; otherwise `iso_url` downloads and `iso_checksum` validates when provided.
