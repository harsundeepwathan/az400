// Role-based access control. Roles are cumulative; permissions are checked per route.
export type Role = 'org_admin' | 'infra_admin' | 'operator' | 'viewer';

export type Permission =
  | 'read'
  | 'incident.manage'
  | 'maintenance.manage'
  | 'monitoring.configure'
  | 'accounts.manage'
  | 'agents.manage'
  | 'users.manage'
  | 'audit.read';

const grants: Record<Role, Permission[]> = {
  viewer: ['read'],
  operator: ['read', 'incident.manage', 'maintenance.manage'],
  infra_admin: ['read', 'incident.manage', 'maintenance.manage', 'monitoring.configure', 'accounts.manage', 'agents.manage'],
  org_admin: [
    'read', 'incident.manage', 'maintenance.manage', 'monitoring.configure', 'accounts.manage', 'agents.manage',
    'users.manage', 'audit.read',
  ],
};

export const ROLES = Object.keys(grants) as Role[];

export function can(role: Role | undefined, p: Permission): boolean {
  return !!role && grants[role].includes(p);
}

export function permissionsFor(role: Role): Permission[] {
  return [...grants[role]];
}
