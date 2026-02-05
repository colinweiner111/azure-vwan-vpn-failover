// =============================================================================
// Bastion Module - Azure Bastion for VM Access
// =============================================================================
// Creates:
// - Bastion NSG with required rules
// - Bastion Public IP
// - Azure Bastion (Standard SKU for IP-based connections)
// - Hub connection for Bastion VNet
// =============================================================================

param location string
param hubName string

// =============================================================================
// Bastion NSG
// =============================================================================
resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'bastion-nsg'
  location: location
  properties: {
    securityRules: [
      // Inbound rules
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      // Outbound rules
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowGetSessionInformation'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRanges: [
            '80'
            '443'
          ]
        }
      }
    ]
  }
}

// =============================================================================
// Update Bastion VNet subnet with NSG
// =============================================================================
resource bastionVnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: 'bastion-vnet'
}

resource bastionSubnetNsg 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: bastionVnet
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: '10.250.0.0/26'
    networkSecurityGroup: {
      id: bastionNsg.id
    }
  }
}

// =============================================================================
// Bastion Public IP
// =============================================================================
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'bastion-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// =============================================================================
// Azure Bastion
// =============================================================================
resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: 'bastion-vnet-bastion'
  location: location
  sku: {
    name: 'Standard'  // Required for IP-based connections
  }
  properties: {
    enableTunneling: true  // Required for native client support
    enableIpConnect: true  // Required for IP-based connections
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: bastionSubnetNsg.id
          }
          publicIPAddress: {
            id: bastionPip.id
          }
        }
      }
    ]
  }
}

// =============================================================================
// Hub Connection for Bastion VNet
// Note: propagateDefaultRoute must be disabled for Bastion to work with
// Routing Intent (secured hub). This is a vWAN requirement.
// =============================================================================
resource hub 'Microsoft.Network/virtualHubs@2023-11-01' existing = {
  name: hubName
}

resource bastionHubConn 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  parent: hub
  name: 'bastion-vnet-conn'
  properties: {
    remoteVirtualNetwork: {
      id: bastionVnet.id
    }
    enableInternetSecurity: false  // Don't route internet through firewall
    routingConfiguration: {
      propagatedRouteTables: {
        ids: [
          {
            id: '${hub.id}/hubRouteTables/defaultRouteTable'
          }
        ]
        labels: [
          'default'
        ]
      }
      vnetRoutes: {
        staticRoutes: []
      }
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================
output bastionId string = bastion.id
output bastionName string = bastion.name
output bastionPipId string = bastionPip.id
