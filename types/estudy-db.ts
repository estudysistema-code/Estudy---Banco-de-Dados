/* Tipos do banco Estudy (PostgreSQL) e do contrato de sync por namespace.
 * Espelham db/migrations/*.sql. Datas: 'YYYY-MM-DD' · horas: 'HH:MM' · instantes: ISO 8601. */

// ---------- enums ----------
export type ActivityType = 'CAMPO' | 'TEORIA' | 'PROVA' | 'SIMULACAO' | 'MEDWAY' | 'ACOLHIMENTO' | 'ACADEMIA' | 'ESTUDO' | 'PESSOAL';
export type PresenceStatus = 'pendente' | 'presente' | 'falta' | 'justificada';
export type EventOrigin = 'grade' | 'import' | 'manual' | 'sugestao';
export type PlanSource = 'seed' | 'import';
export type AuthProvider = 'email' | 'apple' | 'google';
export type TaskStatus = 'aberta' | 'andamento' | 'concluida';
export type MemberRole = 'owner' | 'admin' | 'editor' | 'member' | 'viewer';
export type MembershipStatus = 'active' | 'removed';
export type InviteStatus = 'active' | 'exhausted' | 'revoked';
export type AssetExt = 'pdf' | 'docx' | 'jpg' | 'jpeg' | 'png';
export type AssetContext = 'workspace' | 'onboarding';
export type AiStatus = 'pendente' | 'processando' | 'concluido' | 'erro';
export type AiJobKind = 'plan_import' | 'asset_summary' | 'asset_flashcards' | 'asset_embeddings';
export type WorkspaceColor = 'estudo' | 'campo' | 'prova' | 'simulacao' | 'medway' | 'acolhimento' | 'academia' | 'teoria';
export type WorkspaceIcon = '◍' | '◆' | '●' | '▲' | '■' | '✦' | '⬢' | '◈';

export interface Permissions {
  manageWorkspace: boolean; manageMembers: boolean; manageInvites: boolean;
  manageTasks: boolean; manageEvents: boolean; manageAssets: boolean;
  comment: boolean; view: boolean; deleteWorkspace: boolean;
}

// ---------- linhas (snake_case, como no banco) ----------
export interface UserRow { id: string; display_name: string; avatar_url: string | null; course: string; institution: string; is_mock: boolean; created_at: string; updated_at: string; }
export interface IdentityRow { user_id: string; username: string | null; email: string | null; full_name: string; period: string; provider: AuthProvider | null; provider_subject: string | null; pass_hash: string | null; pass_algo: 'sha256-client' | 'argon2id' | 'bcrypt' | null; onboarded: boolean; onboarded_at: string | null; signed_in: boolean; created_at: string; updated_at: string; }
export interface TermRow { id: string; label: string; source: PlanSource; owner_user_id: string | null; course: string; institution: string; start_date: string | null; end_date: string | null; created_at: string; updated_at: string; }
export interface RotationRow { id: string; term_id: string; code: string; label: string; module: string; name: string; sort_order: number; }
export interface WeekRow { id: string; term_id: string; code: string; rotation_id: string | null; rod_label: string; module: string; start_date: string; end_date: string; }
export interface ScheduleItemRow { id: string; term_id: string; position: number; date: string; start_time: string; end_time: string; type: ActivityType; title: string; }
export interface EnrollmentRow { user_id: string; term_id: string; student_code: string | null; is_active: boolean; enrolled_at: string; }
export interface PlannerEventRow { id: string; user_id: string; term_id: string | null; source_item_id: string | null; date: string; start_time: string; end_time: string; type: ActivityType; title: string; subject: string; note: string; status: PresenceStatus; origin: EventOrigin; custom: boolean; attendance_marked_at: string | null; created_at: string; updated_at: string; deleted_at: string | null; }
export interface WeekNoteRow { user_id: string; week_id: string; body: string; updated_at: string; }
export interface UserGoalsRow { user_id: string; gym_per_week: number; study_hours_per_week: number; updated_at: string; }
export interface WorkspaceRow { id: string; name: string; description: string; color: WorkspaceColor; icon: WorkspaceIcon; owner_id: string; invite_code: string | null; is_mock: boolean; created_at: string; inserted_at: string; updated_at: string; deleted_at: string | null; }
export interface MembershipRow { id: string; workspace_id: string; user_id: string; role: MemberRole; responsibility: string; joined_at: string; status: MembershipStatus; removed_at: string | null; invite_id: string | null; permissions: Permissions; updated_at: string; }
export interface InviteRow { id: string; workspace_id: string; code: string; created_by: string; created_at: string; expires_at: string | null; max_uses: number | null; current_uses: number; status: InviteStatus; revoked_at: string | null; }
export interface WorkspaceEventRow { id: string; workspace_id: string; date: string; start_time: string; end_time: string; title: string; note: string; created_by: string; created_at: string; updated_by: string | null; updated_at: string; deleted_at: string | null; }
export interface TaskRow { id: string; workspace_id: string; title: string; description: string; assignee_id: string | null; due_date: string | null; status: TaskStatus; completed_at: string | null; created_by: string; created_at: string; updated_by: string | null; updated_at: string; deleted_at: string | null; }
export interface AssetRow { id: string; context: AssetContext; workspace_id: string | null; owner_user_id: string | null; name: string; size_bytes: number; ext: AssetExt; mime_type: string | null; sha256: string | null; added_by: string; added_at: string; ai_status: AiStatus; stored: boolean; storage_key: string | null; storage_url: string | null; updated_at: string; deleted_at: string | null; }
export interface ActivityRow { id: string; workspace_id: string; kind: 'comment'; author_id: string; body: string; parent_id: string | null; task_id: string | null; target_type: 'task' | null; target_id: string | null; created_at: string; updated_at: string; deleted_at: string | null; }
export interface DomainEventRow { id: number; name: string; aggregate_type: string; aggregate_id: string; workspace_id: string | null; user_id: string | null; payload: Record<string, unknown>; occurred_at: string; published_at: string | null; }
export interface AiJobRow { id: string; user_id: string; kind: AiJobKind; status: AiStatus; asset_ids: string[]; model: string | null; result: unknown; error: string | null; created_at: string; started_at: string | null; finished_at: string | null; }

// ---------- contrato do Store (shape exato que o planner_aluno026.html lê) ----------
export interface Envelope<T> { v: number; at: string; data: T; }
export type Namespace = 'identity' | 'users' | 'planner' | 'workspace' | 'memberships' | 'invites';

export interface IdentityNs { userId: string; username: string; email: string; passHash: string | null; provider: AuthProvider | null; name: string; course: string; institution: string; period: string; avatarUrl: string | null; onboarded: boolean; signedIn: boolean; files: { name: string; size: number }[]; }
export interface UserRef { id: string; displayName: string; avatarUrl: string | null; course: string; institution: string; createdAt: string; updatedAt: string; }
export interface UsersNs { byId: Record<string, UserRef>; }
export interface PlannerEvent { id: string; date: string; start: string; end: string; type: ActivityType; title: string; note: string; status: PresenceStatus; done: boolean; custom: boolean; }
export interface PlannerNs {
  events: PlannerEvent[]; notes: Record<string, string>; goals: { gym: number; study: number };
  weeks?: { id: string; start: string; end: string; rod: string; mod: string }[];   // só em plano importado
  baseline?: [string, string, string, ActivityType, string][];                     // só em plano importado
}
export interface WorkspaceNs { workspaces: Array<{
  id: string; name: string; description: string; color: string /* 'var(--estudo)' */; icon: WorkspaceIcon; ownerId: string;
  inviteCode: string | null; createdAt: string; updatedAt: string; dirty: boolean;
  events: { id: string; date: string; start: string; end: string; title: string; note: string; createdBy: string; createdAt: string }[];
  tasks: { id: string; title: string; desc: string; assignee: string | null; due: string | null; status: TaskStatus;
           comments: { id: string; author: string; text: string; at: string }[]; createdBy: string; createdAt: string }[];
  files: { id: string; name: string; size: number; ext: AssetExt; addedBy: string; addedAt: string; aiStatus: AiStatus; stored: boolean }[];
  comments: { id: string; author: string; text: string; at: string; parentId: string | null }[];
}>; }
export interface MembershipsNs { items: { id: string; workspaceId: string; userId: string; role: MemberRole; responsibility: string; joinedAt: string; status: MembershipStatus; permissions: Permissions }[]; }
export interface InvitesNs { items: { id: string; workspaceId: string; code: string; createdBy: string; createdAt: string; expiresAt: string | null; maxUses: number | null; currentUses: number; status: InviteStatus }[]; }

/** Relatório devolvido por api.ns_put / api.ns_import */
export interface PutReport {
  namespace: Namespace; applied: boolean; reason?: 'stale'; v?: number; at?: string;
  skipped?: Array<Record<string, unknown> & { reason: string }>;
  warnings?: unknown[]; readOnly?: { workspace: string; section: 'meta' | 'events' | 'tasks' | 'files' | 'comments' }[];
  [counter: string]: unknown;
}
