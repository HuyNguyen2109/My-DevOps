Please help me review this initialization bash script which is same folder with this instruction about bootstrapping Docker Swarm, I need this script updated with following prerequisites:
- This script can be remote executed from a "satellite" machine
- This "satellite" machine and those designated nodes for Swarm must be in the same Wireguard network (help me add code to check if Wireguard is installed and configured for those designated nodes to communicate with each other)
- The Swarm role and node hostname will be defined at the start of the script
- Run those command of each nodes:
    1. sudo apt update && sudo apt upgrade -y && sudo apt dist-upgrade -y
    2. Command for Wireguard installation (kernel mode not userspace mode)
    3. Create default folder for Wireguard if not exists (default at /etc/wireguard, using sudo if must)
    4. Generate pub-key, priv-key as Wireguard official documentation on each node and define the wg0.conf as following format (The number of [Peer] block will depend on the total of nodes defined at the start of script):
    ```conf
    [Interface]
    Address = 10.50.0.X/24
    ListenPort = 51821
    PrivateKey = <generated-private-key>

    [Peer]
    PublicKey = <peer-public-key>
    AllowedIPs = 10.50.0.X/32
    Endpoint = <peer-public-ip>:51821
    PersistentKeepalive = 25
    ```
- Check if designated nodes have Debian server-based distro and UFW installed; if not, install UFW, enable its service with systemctl (using sudo if needed), add these rules, then reload:

    **For Manager Nodes:**

    | Port/Protocol | Action | Interface | From |
    |---|---|---|---|
    | 22/tcp | ALLOW IN | any | Anywhere |
    | 443/tcp | ALLOW IN | any | Anywhere |
    | 80/tcp | ALLOW IN | any | Anywhere |
    | 51821/udp | ALLOW IN | any | Anywhere |
    | 51820/udp | ALLOW IN | any | Anywhere |
    | 2377/tcp | ALLOW IN | wg0 | Anywhere |
    | 7946/tcp | ALLOW IN | wg0 | Anywhere |
    | 7946/udp | ALLOW IN | wg0 | Anywhere |
    | 4789/udp | ALLOW IN | wg0 | Anywhere |
    | 2375/tcp | ALLOW IN | any | Anywhere |

    **For Worker Nodes:**

    | Port/Protocol | Action | Interface | From |
    |---|---|---|---|
    | 22/tcp | ALLOW IN | any | Anywhere |
    | 51821/udp | ALLOW IN | any | Anywhere |
    | 51820/udp | ALLOW IN | any | Anywhere |
    | 7946/tcp | ALLOW IN | wg0 | Anywhere |
    | 7946/udp | ALLOW IN | wg0 | Anywhere |
    | 4789/udp | ALLOW IN | wg0 | Anywhere |
- For SSH accessing of each node, its credentials will be fetched at folder ".ssh-credentials", each credentials file will represent for a node SSH credentials with file name is node's hostname with "." as prefix (for filtering in .gitignore to make sure they cannot be committed and pushed accidentally)
- Keep the function install_prereqs() in current bash script to install all neccessary dependencies or Docker. Also keep all steps after that to make sure Docker can run on each node without sudo prefix
- On detect_mesh_ip() function, If node has more than one "Wireguard-based" interface, use the "Wireguard vanilla" interface (wg0) as the highest piority to make connection among Swarm nodes
- Keep all docker overlay network creations as it
