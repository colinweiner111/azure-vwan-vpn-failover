// =============================================================================
// Network Module - vWAN Hub and On-Prem VNet
// =============================================================================
// Creates:
// - Virtual WAN with single hub
// - On-Prem VNet (simulates on-premises network with FRR/strongSwan router)
// =============================================================================

param location string
param vwanName string
param hubName string

// =============================================================================
// Virtual WAN
// =============================================================================
resource vwan 'Microsoft.Network/virtualWans@2023-11-01' = {
  name: vwanName
  location: location
  properties: {
    type: 'Standard'
    allowBranchToBranchTraffic: true
  }
}

// =============================================================================
// Virtual Hub
// =============================================================================
resource hub 'Microsoft.Network/virtualHubs@2023-11-01' = {
  name: hubName
  location: location
  properties: {
    addressPrefix: '192.168.1.0/24'
    virtualWan: {
      id: vwan.id
    }
    sku: 'Standard'
    // Hub routing preference - set to ExpressRoute to prefer ER when prefix lengths match
    // Note: LPM still wins regardless of this setting
    hubRoutingPreference: 'ExpressRoute'
  }
}

// =============================================================================
// On-Prem VNet - Simulates customer's on-premises network
// Contains FRR/strongSwan router VM that creates 2 tunnels to vWAN
// Address Space: 10.0.0.0/16 (what will be advertised to Azure)
// =============================================================================
resource onpremVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'onprem-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'router'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: onpremNsg.id
          }
        }
      }
      {
        name: 'workloads-1'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: onpremNsg.id
          }
        }
      }
      {
        name: 'workloads-2'
        properties: {
          addressPrefix: '10.0.2.0/24'
          networkSecurityGroup: {
            id: onpremNsg.id
          }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.255.0/27'
        }
      }
    ]
  }
}

// =============================================================================
// Network Security Group for On-Prem
// =============================================================================
resource onpremNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'onprem-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowIKE'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '500'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowNATT'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '4500'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowBGP'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '179'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowICMP'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Icmp'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// =============================================================================
// Outputs
// =============================================================================
output vwanId string = vwan.id
output hubId string = hub.id
output onpremVnetId string = onpremVnet.id
output onpremVnetName string = onpremVnet.name
output onpremSubnetId string = onpremVnet.properties.subnets[0].id
output onpremWorkloadsSubnetId string = onpremVnet.properties.subnets[1].id
