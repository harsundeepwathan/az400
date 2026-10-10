export type OpState = 'healthy' | 'warning' | 'critical' | 'down' | 'stopped' | 'unknown' | 'maintenance' | 'no_data';

export const STATE_ORDER: OpState[] = ['down', 'critical', 'warning', 'unknown', 'no_data', 'maintenance', 'stopped', 'healthy'];

export const STATE_LABEL: Record<OpState, string> = {
  healthy: 'Healthy', warning: 'Warning', critical: 'Critical', down: 'Down', stopped: 'Stopped',
  unknown: 'Unknown', maintenance: 'Maintenance', no_data: 'No data',
};

export const PROVIDER_LABEL: Record<string, string> = {
  azure: 'Azure', digitalocean: 'DigitalOcean', alibaba: 'Alibaba Cloud', onprem: 'On-premises', aws: 'AWS', gcp: 'Google Cloud', vmware: 'VMware', demo: 'Demo',
};

// Categorical slot per provider: fixed by entity, never by rank.
export const PROVIDER_SLOT: Record<string, number> = { azure: 1, alibaba: 2, digitalocean: 3, onprem: 7, aws: 4, gcp: 5, vmware: 6 };

export const TYPE_LABEL: Record<string, string> = {
  vm: 'Virtual machine', vm_scale_set: 'Scale set', app_service: 'App Service', function_app: 'Function app', sql_database: 'SQL database',
  managed_database: 'Managed database', storage_account: 'Storage account', object_bucket: 'Bucket', load_balancer: 'Load balancer',
  app_gateway: 'Application gateway', firewall: 'Firewall', vpn_gateway: 'VPN gateway', kubernetes_cluster: 'Kubernetes', volume: 'Volume', server: 'Server',
};

export function accountState(status: string): OpState {
  return status === 'active' ? 'healthy' : status === 'degraded' ? 'warning' : status === 'error' ? 'critical' : 'no_data';
}
