# SSH Credentials Directory
# =========================
#
# This directory stores SSH credentials for each Swarm node.
# Each file should be named with a "." prefix followed by the node's hostname.
#
# Example files:
#   .swarm-manager-01
#   .swarm-manager-02
#   .swarm-worker-01
#
# File Format Options:
# --------------------
#
# Option 1: Path to SSH private key file (recommended)
#   First line: absolute path to the private key
#   Second line (optional): SSH username (default: root)
#
#   Example content of .swarm-manager-01:
#     /home/user/.ssh/id_rsa_swarm
#     root
#
# Option 2: Username:Password format (less secure)
#   Single line with username:password
#
#   Example content of .swarm-manager-01:
#     root:my_secure_password
#
# SECURITY NOTES:
# ---------------
# - All files prefixed with "." are ignored by git (see .gitignore)
# - Use SSH key-based authentication whenever possible
# - If using passwords, ensure this directory has restricted permissions (chmod 700)
# - Never commit credential files to version control
