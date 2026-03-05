// =============================================================================
// FRR/strongSwan VM Module - ER Path (Primary) - Multi-Hub
// =============================================================================
// Creates:
// - Linux VM with FRRouting + strongSwan
// - Cloud-init configuration for:
//   * IPsec tunnels to each hub's vWAN VPN Gateway Instance 0
//   * BGP peers to each Instance 0, advertising aggregate 10.0.0.0/16
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

// Hub1 vWAN VPN Gateway Instance 0 (ER path)
param hubVpnGwBgpIp0 string      // e.g., 192.168.1.13
param hubVpnGwPublicIp0 string   // Instance 0 public IP

// Hub2 vWAN VPN Gateway Instance 0 (ER path)
param hub2VpnGwBgpIp0 string     // e.g., 192.168.2.13
param hub2VpnGwPublicIp0 string  // Instance 0 public IP

// Hub3 vWAN VPN Gateway Instance 0 (ER path)
param hub3VpnGwBgpIp0 string     // e.g., 192.168.3.13
param hub3VpnGwPublicIp0 string  // Instance 0 public IP

var vmName = 'frr-router'
var nicName = '${vmName}-nic'
var publicIpName = '${vmName}-pip'
var onpremAsn = 65001

// =============================================================================
// Public IP for ER Path
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
// Network Interface - Single IP for ER-path tunnel
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
// Cloud-init configuration for FRR + strongSwan (ER Path - Multi-Hub)
// =============================================================================
// Values are injected directly by Bicep format() function
// Only __LOCAL_IP__ needs runtime detection and replacement
// 3 IPsec tunnels (one per hub) + 3 BGP peers, all advertising 10.0.0.0/16
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
  # strongSwan ipsec.conf - 3 tunnels to each hub's VPN Gateway Instance 0
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

      # ER Path tunnel to Hub1 VPN GW Instance 0 (westus3)
      conn er-path-hub1
        left=%defaultroute
        leftsubnet=10.0.0.0/16
        leftid=%any
        right={0}
        rightsubnet=192.168.1.0/24,10.100.0.0/16,10.200.0.0/16
        rightid={0}

      # ER Path tunnel to Hub2 VPN GW Instance 0 (eastus2)
      conn er-path-hub2
        left=%defaultroute
        leftsubnet=10.0.0.0/16
        leftid=%any
        right={4}
        rightsubnet=192.168.2.0/24,10.110.0.0/16,10.210.0.0/16
        rightid={4}

      # ER Path tunnel to Hub3 VPN GW Instance 0 (westus)
      conn er-path-hub3
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

  # FRR configuration - Advertise AGGREGATE route (10.0.0.0/16) to all 3 hubs
  # __LOCAL_IP__ will be replaced at runtime with actual private IP
  - path: /etc/frr/frr.conf
    content: |
      frr version 8.1
      frr defaults traditional
      hostname frr-router
      log syslog informational
      service integrated-vtysh-config
      !
      ! Static route for aggregate on-prem network
      ip route 10.0.0.0/16 Null0
      !
      ! Prefix list for aggregate route only
      ip prefix-list AGGREGATE seq 5 permit 10.0.0.0/16
      !
      ! Route-map for ER path: Only advertise aggregate
      route-map TO_ER_PATH permit 10
        match ip address prefix-list AGGREGATE
      route-map TO_ER_PATH deny 20
      !
      ! BGP configuration
      router bgp {2}
        bgp router-id __LOCAL_IP__
        no bgp ebgp-requires-policy
        bgp log-neighbor-changes
        !
        ! Hub1 ER-PATH neighbor (VPN GW Instance 0)
        neighbor {3} remote-as 65515
        neighbor {3} ebgp-multihop 64
        neighbor {3} update-source __LOCAL_IP__
        neighbor {3} timers 3 9
        neighbor {3} description ER-PATH-HUB1
        !
        ! Hub2 ER-PATH neighbor (VPN GW Instance 0)
        neighbor {5} remote-as 65515
        neighbor {5} ebgp-multihop 64
        neighbor {5} update-source __LOCAL_IP__
        neighbor {5} timers 3 9
        neighbor {5} description ER-PATH-HUB2
        !
        ! Hub3 ER-PATH neighbor (VPN GW Instance 0)
        neighbor {7} remote-as 65515
        neighbor {7} ebgp-multihop 64
        neighbor {7} update-source __LOCAL_IP__
        neighbor {7} timers 3 9
        neighbor {7} description ER-PATH-HUB3
        !
        address-family ipv4 unicast
          redistribute static
          neighbor {3} soft-reconfiguration inbound
          neighbor {3} route-map TO_ER_PATH out
          neighbor {5} soft-reconfiguration inbound
          neighbor {5} route-map TO_ER_PATH out
          neighbor {7} soft-reconfiguration inbound
          neighbor {7} route-map TO_ER_PATH out
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
      echo "=== ER-Path Multi-Hub Setup started at $(date) ==="
      
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
''', hubVpnGwPublicIp0, vpnPsk, string(onpremAsn), hubVpnGwBgpIp0, hub2VpnGwPublicIp0, hub2VpnGwBgpIp0, hub3VpnGwPublicIp0, hub3VpnGwBgpIp0)

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
