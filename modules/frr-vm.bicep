// =============================================================================
// FRR/strongSwan VM Module - ER Path (Primary)
// =============================================================================
// Creates:
// - Linux VM with FRRouting + strongSwan
// - Cloud-init configuration for:
//   * Single IPsec tunnel to vWAN VPN Gateway Instance 0
//   * BGP to Instance 0 BGP peer, advertising aggregate 10.0.0.0/16
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

// vWAN VPN Gateway Instance 0 (ER path)
param hubVpnGwBgpIp0 string      // e.g., 192.168.1.13
param hubVpnGwPublicIp0 string   // Instance 0 public IP

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
// Cloud-init configuration for FRR + strongSwan (ER Path Only)
// =============================================================================
// Values are injected directly by Bicep format() function
// Only __LOCAL_IP__ needs runtime detection and replacement
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
  # strongSwan ipsec.conf - Single tunnel to VPN Gateway Instance 0
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

      # ER Path tunnel (to VPN GW Instance 0)
      conn er-path
        left=%defaultroute
        leftsubnet=10.0.0.0/16
        leftid=%any
        right={0}
        rightsubnet=192.168.0.0/16,10.100.0.0/16,10.200.0.0/16
        rightid={0}

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

  # FRR configuration - Advertise AGGREGATE route (10.0.0.0/16)
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
        ! ER-PATH neighbor (VPN GW Instance 0) - receives AGGREGATE
        neighbor {3} remote-as 65515
        neighbor {3} ebgp-multihop 64
        neighbor {3} update-source __LOCAL_IP__
        neighbor {3} timers 3 9
        neighbor {3} description ER-PATH
        !
        address-family ipv4 unicast
          redistribute static
          neighbor {3} soft-reconfiguration inbound
          neighbor {3} route-map TO_ER_PATH out
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
      echo "=== ER-Path Setup started at $(date) ==="
      
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
      
      # Wait for tunnel to establish
      echo "Waiting for IPsec tunnel..."
      sleep 20
      ipsec status || true
      
      # Add route to BGP peer via default gateway
      echo "Adding route to BGP peer {3}..."
      ip route add {3}/32 via $DEFAULT_GW dev eth0 || true
      
      echo "Starting FRR..."
      systemctl enable frr
      systemctl restart frr
      
      # Wait for BGP to establish
      sleep 20
      
      echo "=== Setup complete at $(date) ==="
      echo ""
      echo "IPsec status:"
      ipsec status || true
      echo ""
      echo "BGP summary:"
      vtysh -c "show ip bgp summary" || true

runcmd:
  - /opt/setup-vpn.sh
''', hubVpnGwPublicIp0, vpnPsk, string(onpremAsn), hubVpnGwBgpIp0)

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
