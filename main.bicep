targetScope = 'subscription'

// =============================================================================
// vWAN ExpressRoute/VPN Failover Lab - FRR/strongSwan Edition
// =============================================================================
// This lab demonstrates the route preference behavior between two S2S VPN 
// connections simulating ExpressRoute (preferred) and VPN backup scenarios.
//
// Architecture:
// - Two on-prem VMs running FRRouting + strongSwan
//   * VM1 (frr-router): ER-path tunnel to VPN GW Instance 0
//     - Advertises aggregate 10.0.0.0/16 via BGP
//   * VM2 (frr-router-backup): VPN-backup tunnel to VPN GW Instance 1
//     - Advertises specific 10.0.1.0/24, 10.0.2.0/24 via BGP
// - Shows how LPM (Longest Prefix Match) causes VPN routes to win
// - Demonstrates Route Maps as the solution
// =============================================================================

@description('Primary region for deployment')
param location string = 'westus3'

@description('Resource group name')
param resourceGroupName string = 'vwan-failover-lab'

@description('Virtual WAN name')
param vwanName string = 'vwan-failover'

@description('Hub name')
param hubName string = 'hub1'

@description('Admin username for VMs')
param adminUsername string = 'azureuser'

@description('Admin password for VMs')
@secure()
param adminPassword string

@description('SSH public key for the FRR VM')
param sshPublicKey string = ''

@description('VM size for FRR router')
param vmSize string = 'Standard_B2s'

@description('Deploy Azure Firewall with Routing Intent (adds ~15 min to deployment)')
param enableFirewall bool = false

@description('Deploy Azure Bastion for VM access (adds ~5 min to deployment)')
param enableBastion bool = false

@description('Azure Firewall SKU (if enabled)')
@allowed(['Standard', 'Premium'])
param firewallSku string = 'Standard'

@description('Enable Route Maps to fix failback (deploy after initial testing)')
param enableRouteMaps bool = false

@description('Pre-shared key for VPN tunnels')
@secure()
param vpnPsk string

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}

// Network Infrastructure (vWAN, Hub, On-Prem VNet)
module network 'modules/network.bicep' = {
  scope: rg
  name: 'network-deployment'
  params: {
    location: location
    vwanName: vwanName
    hubName: hubName
  }
}

// Hub VPN Gateway (deploy early as it takes ~30 mins)
module vpnGateway 'modules/vpn-gateway.bicep' = {
  scope: rg
  name: 'vpngw-deployment'
  params: {
    location: location
    hubName: hubName
    hubId: network.outputs.hubId
  }
}

// FRR/strongSwan VM 1 - ER Path (on-prem router simulation)
module frrVm 'modules/frr-vm.bicep' = {
  scope: rg
  name: 'frr-vm-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    sshPublicKey: sshPublicKey
    vmSize: vmSize
    subnetId: network.outputs.onpremSubnetId
    vpnPsk: vpnPsk
    hubVpnGwBgpIp0: vpnGateway.outputs.bgpPeeringAddress0
    hubVpnGwPublicIp0: vpnGateway.outputs.publicIpAddress0
  }
}

// FRR/strongSwan VM 2 - VPN Backup (second on-prem router)
module frrVmBackup 'modules/frr-vm-backup.bicep' = {
  scope: rg
  name: 'frr-vm-backup-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    sshPublicKey: sshPublicKey
    vmSize: vmSize
    subnetId: network.outputs.onpremSubnetId
    vpnPsk: vpnPsk
    hubVpnGwBgpIp1: vpnGateway.outputs.bgpPeeringAddress1
    hubVpnGwPublicIp1: vpnGateway.outputs.publicIpAddress1
  }
}

// VPN Sites and Connections (link on-prem to hub - 2 sites for ER/VPN simulation)
module vpnSites 'modules/vpn-sites.bicep' = {
  scope: rg
  name: 'vpn-sites-deployment'
  params: {
    location: location
    vwanName: vwanName
    hubVpnGwName: vpnGateway.outputs.vpnGatewayName
    onpremPublicIp: frrVm.outputs.publicIpAddress      // ER-path VM PIP
    onpremPublicIp2: frrVmBackup.outputs.publicIpAddress  // VPN-backup VM PIP
    onpremBgpIp: frrVm.outputs.privateIpAddress        // ER-path VM private IP
    onpremBgpIp2: frrVmBackup.outputs.privateIpAddress   // VPN-backup VM private IP
    vpnPsk: vpnPsk
  }
}

// Azure Firewall and Routing Intent (optional - not needed for LPM demo)
module firewall 'modules/firewall.bicep' = if (enableFirewall) {
  scope: rg
  name: 'firewall-deployment'
  params: {
    location: location
    hubName: hubName
    firewallSku: firewallSku
  }
  dependsOn: [
    network
    vpnGateway
  ]
}

// Azure Bastion (optional - for management access)
module bastion 'modules/bastion.bicep' = if (enableBastion) {
  scope: rg
  name: 'bastion-deployment'
  params: {
    location: location
    vnetName: network.outputs.onpremVnetName
  }
  dependsOn: [
    network
  ]
}

// Route Maps (optional - deploy after demonstrating the problem)
module routeMaps 'modules/route-maps.bicep' = if (enableRouteMaps) {
  scope: rg
  name: 'routemaps-deployment'
  params: {
    hubName: hubName
  }
  dependsOn: [
    vpnSites
  ]
}

// Spoke VNets connected to hub
module spokes 'modules/spokes.bicep' = {
  scope: rg
  name: 'spokes-deployment'
  params: {
    location: location
    hubId: network.outputs.hubId
  }
  dependsOn: [
    vpnGateway
  ]
}

// Workload VMs (on-prem + spokes)
module workloadVms 'modules/workload-vms.bicep' = {
  scope: rg
  name: 'workload-vms-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    onpremSubnetId: network.outputs.onpremWorkloadsSubnetId
    spoke1SubnetId: spokes.outputs.spoke1SubnetId
    spoke2SubnetId: spokes.outputs.spoke2SubnetId
  }
}

output vwanId string = network.outputs.vwanId
output hubId string = network.outputs.hubId
output frrVmPublicIp string = frrVm.outputs.publicIpAddress
output frrVmPrivateIp string = frrVm.outputs.privateIpAddress
output frrVmBackupPublicIp string = frrVmBackup.outputs.publicIpAddress
output frrVmBackupPrivateIp string = frrVmBackup.outputs.privateIpAddress
output hubVpnGwPublicIp0 string = vpnGateway.outputs.publicIpAddress0
output hubVpnGwPublicIp1 string = vpnGateway.outputs.publicIpAddress1
output onpremVmPrivateIp string = workloadVms.outputs.onpremVmPrivateIp
output spoke1VmPrivateIp string = workloadVms.outputs.spoke1VmPrivateIp
output spoke2VmPrivateIp string = workloadVms.outputs.spoke2VmPrivateIp
