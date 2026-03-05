// =============================================================================
// FRR/strongSwan VM Module - VPN Backup (Secondary) - Multi-Hub
// =============================================================================
// Creates:
// - Linux VM with FRRouting + strongSwan
// - Cloud-init configuration for:
//   * IPsec tunnels to each hub's vWAN VPN Gateway Instance 1
//   * BGP peers to each Instance 1, advertising specific routes 10.0.1.0/24, 10.0.2.0/24
// =============================================================================

param location string
param adminUsername string
@secure()
param adminPassword string
param sshPublicKey string
param vmSize string
param subnetId string
@secure()
param vpnPsk string

// Hub1 vWAN VPN Gateway Instance 1 (VPN backup)
param hubVpnGwBgpIp1 string      // e.g., 192.168.1.12
param hubVpnGwPublicIp1 string   // Instance 1 public IP

// Hub2 vWAN VPN Gateway Instance 1 (VPN backup)
param hub2VpnGwBgpIp1 string     // e.g., 192.168.2.12
param hub2VpnGwPublicIp1 string  // Instance 1 public IP

// Hub3 vWAN VPN Gateway Instance 1 (VPN backup)
param hub3VpnGwBgpIp1 string     // e.g., 192.168.3.12
param hub3VpnGwPublicIp1 string  // Instance 1 public IP

var vmName = 'frr-router-backup'
var nicName = '${vmName}-nic'
var publicIpName = '${vmName}-pip'
var onpremAsn = 65001

// =============================================================================
// Public IP for VPN Backup
// =============================================================================
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// =============================================================================
// Network Interface - Single IP for VPN-backup tunnel
// =============================================================================
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
          primary: true
        }
      }
    ]
    enableIPForwarding: true
  }
}

// =============================================================================
// Cloud-init configuration for FRR + strongSwan (VPN Backup - Multi-Hub)
// =============================================================================
// Values are injected directly by Bicep format() function
// Only __LOCAL_IP__ needs runtime detection and replacement
// 3 IPsec tunnels (one per hub) + 3 BGP peers, all advertising specifics
// =============================================================================
var cloudInitConfig = format('''#cloud-config
package_update: true
package_upgrade: true

packages:
  - strongswan
  - strongswan-pki
  - libcharon-extra-plugins
  - frr
  - frr-pythontools
  - netcat-openbsd

write_files:
  # strongSwan ipsec.conf - 3 tunnels to each hub's VPN Gateway Instance 1
  - path: /etc/ipsec.conf
    content: |
      config setup
        charondebug="ike 1, knl 1"

      conn %default
        ikelifetime=28800s
        keylife=3600s
        rekeymargin=3m
        keyingtries=3
        keyexchange=ikev2
        authby=secret
        ike=aes256-sha256-modp1024!
        esp=aes256-sha256!
        type=tunnel
        auto=start
        dpdaction=clear
        dpddelay=30s
        dpdtimeout=120s

      # VPN Backup tunnel to Hub1 VPN GW Instance 1 (westus3)
      conn vpn-backup-hub1
        left=%defaultroute
        leftsubnet=10.0.0.0/16
        leftid=%any
        right={0}
        rightsubnet=192.168.1.0/24,10.100.0.0/16,10.200.0.0/16
        rightid={0}

      # VPN Backup tunnel to Hub2 VPN GW Instance 1 (eastus2)
      conn vpn-backup-hub2
        left=%defaultroute
        leftsubnet=10.0.0.0/16
        leftid=%any
        right={4}
        rightsubnet=192.168.2.0/24,10.110.0.0/16,10.210.0.0/16
        rightid={4}

      # VPN Backup tunnel to Hub3 VPN GW Instance 1 (westus)
      conn vpn-backup-hub3
        left=%defaultroute
        leftsubnet=10.0.0.0/16
        leftid=%any
        right={6}
        rightsubnet=192.168.3.0/24,10.120.0.0/16,10.220.0.0/16
        rightid={6}

  # strongSwan secrets
  - path: /etc/ipsec.secrets
    permissions: '0600'
    content: |
      : PSK "{1}"

  # FRR daemons config
  - path: /etc/frr/daemons
    content: |
      zebra=yes
      bgpd=yes
      ospfd=no
      ospf6d=no
      ripd=no
      ripngd=no
      isisd=no
      pimd=no
      ldpd=no
      nhrpd=no
      eigrpd=no
      babeld=no
      sharpd=no
      staticd=yes
      pbrd=no
      bfdd=no
      fabricd=no
      vrrpd=no
      pathd=no

  # FRR configuration - Advertise SPECIFIC routes (10.0.1.0/24, 10.0.2.0/24) to all 3 hubs
  # __LOCAL_IP__ will be replaced at runtime with actual private IP
  - path: /etc/frr/frr.conf
    content: |
      frr version 8.1
      frr defaults traditional
      hostname frr-router-backup
      log syslog informational
      service integrated-vtysh-config
      !
      ! Static routes for specific on-prem networks
      ip route 10.0.1.0/24 Null0
      ip route 10.0.2.0/24 Null0
      !
      ! Prefix list for specific routes only
      ip prefix-list SPECIFICS seq 5 permit 10.0.1.0/24
      ip prefix-list SPECIFICS seq 10 permit 10.0.2.0/24
      !
      ! Route-map for VPN backup: Only advertise specific routes
      route-map TO_VPN_BACKUP permit 10
        match ip address prefix-list SPECIFICS
      route-map TO_VPN_BACKUP deny 20
      !
      ! BGP configuration
      router bgp {2}
        bgp router-id __LOCAL_IP__
        no bgp ebgp-requires-policy
        bgp log-neighbor-changes
        !
        ! Hub1 VPN-BACKUP neighbor (VPN GW Instance 1)
        neighbor {3} remote-as 65515
        neighbor {3} ebgp-multihop 64
        neighbor {3} update-source __LOCAL_IP__
        neighbor {3} timers 3 9
        neighbor {3} description VPN-BACKUP-HUB1
        !
        ! Hub2 VPN-BACKUP neighbor (VPN GW Instance 1)
        neighbor {5} remote-as 65515
        neighbor {5} ebgp-multihop 64
        neighbor {5} update-source __LOCAL_IP__
        neighbor {5} timers 3 9
        neighbor {5} description VPN-BACKUP-HUB2
        !
        ! Hub3 VPN-BACKUP neighbor (VPN GW Instance 1)
        neighbor {7} remote-as 65515
        neighbor {7} ebgp-multihop 64
        neighbor {7} update-source __LOCAL_IP__
        neighbor {7} timers 3 9
        neighbor {7} description VPN-BACKUP-HUB3
        !
        address-family ipv4 unicast
          redistribute static
          neighbor {3} soft-reconfiguration inbound
          neighbor {3} route-map TO_VPN_BACKUP out
          neighbor {5} soft-reconfiguration inbound
          neighbor {5} route-map TO_VPN_BACKUP out
          neighbor {7} soft-reconfiguration inbound
          neighbor {7} route-map TO_VPN_BACKUP out
        exit-address-family
      !
      line vty
      !

  # Setup script - only replaces __LOCAL_IP__ and adds routes
  - path: /opt/setup-vpn.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      
      LOG=/var/log/vpn-setup.log
      exec > >(tee -a $LOG) 2>&1
      echo "=== VPN-Backup Multi-Hub Setup started at $(date) ==="
      
      # Get local private IP
      LOCAL_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){{3}}' | head -1)
      echo "Local IP: $LOCAL_IP"
      
      # Get default gateway
      DEFAULT_GW=$(ip route | grep default | awk '{{print $3}}')
      echo "Default Gateway: $DEFAULT_GW"
      
      # Replace __LOCAL_IP__ placeholder in FRR config
      sed -i "s/__LOCAL_IP__/$LOCAL_IP/g" /etc/frr/frr.conf
      
      # Enable IP forwarding
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
      sysctl -w net.ipv4.ip_forward=1
      
      echo "Starting IPsec..."
      systemctl enable ipsec
      systemctl restart ipsec
      
      # Wait for tunnels to establish
      echo "Waiting for IPsec tunnels..."
      sleep 30
      ipsec status || true
      
      # Add routes to all 3 BGP peers via default gateway
      echo "Adding routes to BGP peers..."
      ip route add {3}/32 via $DEFAULT_GW dev eth0 || true
      ip route add {5}/32 via $DEFAULT_GW dev eth0 || true
      ip route add {7}/32 via $DEFAULT_GW dev eth0 || true
      
      echo "Starting FRR..."
      systemctl enable frr
      systemctl restart frr
      
      # Wait for BGP to establish
      sleep 30
      
      echo "=== Setup complete at $(date) ==="
      echo ""
      echo "IPsec status:"
      ipsec status || true
      echo ""
      echo "BGP summary:"
      vtysh -c "show ip bgp summary" || true

runcmd:
  - /opt/setup-vpn.sh
''', hubVpnGwPublicIp1, vpnPsk, string(onpremAsn), hubVpnGwBgpIp1, hub2VpnGwPublicIp1, hub2VpnGwBgpIp1, hub3VpnGwPublicIp1, hub3VpnGwBgpIp1)

// =============================================================================
// Virtual Machine
// =============================================================================
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: sshPublicKey != ''
        ssh: sshPublicKey != '' ? {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        } : null
      }
      customData: base64(cloudInitConfig)
    }
    storageProfile: {
      imageReference: {
        publisher: 'canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================
output vmId string = vm.id
output vmName string = vm.name
output publicIpAddress string = publicIp.properties.ipAddress
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
