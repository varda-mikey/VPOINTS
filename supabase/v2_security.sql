-- V-POINTS 2.0 role/scope security layer
-- DEVELOPMENT ONLY. Review before applying to production.
-- Depends on v2_schema.sql + v2_workflows.sql.

-- Security model:
-- EXECUTIVE / NRH: national operational visibility.
-- NATIONAL_FUNCTIONAL_HEAD: national visibility for function-appropriate workflows.
-- REGIONAL_HEAD: assigned region(s) only.
-- ADMIN / BRANCH_LEADER: assigned branch(es) only.
-- Visibility is NOT approval authority. Workflow approval is separately validated.

create or replace function public.vp2_current_role()
returns text language sql stable security definer set search_path=public as $$
  select role_code from public.vp2_management_users
  where user_id = auth.uid() and is_active = true
  limit 1;
$$;

create or replace function public.vp2_current_function()
returns text language sql stable security definer set search_path=public as $$
  select function_name from public.vp2_management_users
  where user_id = auth.uid() and is_active = true
  limit 1;
$$;

create or replace function public.vp2_is_national_viewer()
returns boolean language sql stable security definer set search_path=public as $$
  select coalesce(public.vp2_current_role() in ('EXECUTIVE','NRH','NATIONAL_FUNCTIONAL_HEAD'), false);
$$;

create or replace function public.vp2_can_view_region(target_region_id bigint)
returns boolean language sql stable security definer set search_path=public as $$
  select case
    when auth.uid() is null then false
    when public.vp2_is_national_viewer() then true
    when public.vp2_current_role() = 'REGIONAL_HEAD' then exists (
      select 1 from public.vp2_user_region_assignments a
      where a.user_id=auth.uid() and a.region_id=target_region_id
    )
    else false end;
$$;

create or replace function public.vp2_can_view_branch(target_branch_id bigint)
returns boolean language sql stable security definer set search_path=public as $$
  select case
    when auth.uid() is null then false
    when public.vp2_is_national_viewer() then true
    when public.vp2_current_role() = 'REGIONAL_HEAD' then exists (
      select 1 from public.vp2_branches b
      join public.vp2_user_region_assignments a on a.region_id=b.region_id
      where a.user_id=auth.uid() and b.id=target_branch_id
    )
    when public.vp2_current_role() in ('ADMIN','BRANCH_LEADER') then exists (
      select 1 from public.vp2_user_branch_assignments a
      where a.user_id=auth.uid() and a.branch_id=target_branch_id
    )
    else false end;
$$;

create or replace function public.vp2_can_view_profile(target_profile_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists (
    select 1 from public.vp2_profiles p
    where p.id=target_profile_id and (
      p.id=(select profile_id from public.vp2_management_users where user_id=auth.uid())
      or public.vp2_can_view_branch(p.branch_id)
      or (p.branch_id is null and public.vp2_can_view_region(p.region_id))
      or public.vp2_is_national_viewer()
    )
  );
$$;

-- Generic workflow authority helper. This intentionally separates scope from approval.
create or replace function public.vp2_has_authority(authority_code text, target_region_id bigint default null, target_branch_id bigint default null)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare r text := public.vp2_current_role(); f text := upper(coalesce(public.vp2_current_function(),''));
begin
  if auth.uid() is null then return false; end if;
  if authority_code='VIEW' then
    return public.vp2_is_national_viewer()
      or (target_branch_id is not null and public.vp2_can_view_branch(target_branch_id))
      or (target_region_id is not null and public.vp2_can_view_region(target_region_id));
  elsif authority_code='REGIONAL_MERIT_APPROVAL' then
    return r='REGIONAL_HEAD' and target_region_id is not null and public.vp2_can_view_region(target_region_id);
  elsif authority_code='NATIONAL_MERIT_APPROVAL' then
    return r in ('NRH','EXECUTIVE');
  elsif authority_code='HR_REVIEW' then
    return r='EXECUTIVE' or r='NRH' or (r='NATIONAL_FUNCTIONAL_HEAD' and f='HR');
  elsif authority_code='FSQA_REVIEW' then
    return r='EXECUTIVE' or r='NRH' or (r='NATIONAL_FUNCTIONAL_HEAD' and f='FSQA');
  elsif authority_code='FINAL_POLICY_POST' then
    return r in ('NRH','EXECUTIVE') or (r='REGIONAL_HEAD' and target_region_id is not null and public.vp2_can_view_region(target_region_id));
  end if;
  return false;
end;
$$;

-- Profiles: scope-limited read. Writes are deliberately not opened by broad RLS.
drop policy if exists vp2_profiles_select_scope on public.vp2_profiles;
create policy vp2_profiles_select_scope on public.vp2_profiles for select to authenticated
using (public.vp2_can_view_profile(id));

-- Regions and branches: only locations in the caller's operational scope.
drop policy if exists vp2_regions_select_scope on public.vp2_regions;
create policy vp2_regions_select_scope on public.vp2_regions for select to authenticated
using (public.vp2_can_view_region(id));

drop policy if exists vp2_branches_select_scope on public.vp2_branches;
create policy vp2_branches_select_scope on public.vp2_branches for select to authenticated
using (public.vp2_can_view_branch(id));

-- Users can read their own management-account row. National viewers may read management rows for oversight.
drop policy if exists vp2_management_users_select on public.vp2_management_users;
create policy vp2_management_users_select on public.vp2_management_users for select to authenticated
using (user_id=auth.uid() or public.vp2_is_national_viewer());

-- Point ledger is readable only where the profile itself is visible. No client INSERT/UPDATE/DELETE policy.
drop policy if exists vp2_ledger_select_scope on public.vp2_point_ledger;
create policy vp2_ledger_select_scope on public.vp2_point_ledger for select to authenticated
using (public.vp2_can_view_profile(profile_id));

-- Cases inherit region/branch scope. Client-side posting is not granted here.
drop policy if exists vp2_cases_select_scope on public.vp2_cases;
create policy vp2_cases_select_scope on public.vp2_cases for select to authenticated
using (
  public.vp2_can_view_profile(profile_id)
  and (branch_id is null or public.vp2_can_view_branch(branch_id))
  and (region_id is null or public.vp2_can_view_region(region_id))
);

-- Merits inherit employee/profile scope. Approval remains separate authority.
drop policy if exists vp2_merits_select_scope on public.vp2_merits;
create policy vp2_merits_select_scope on public.vp2_merits for select to authenticated
using (public.vp2_can_view_profile(profile_id));

-- Appraisal visibility follows the appraisee profile. No self-merit is created by this policy.
drop policy if exists vp2_appraisals_select_scope on public.vp2_appraisals;
create policy vp2_appraisals_select_scope on public.vp2_appraisals for select to authenticated
using (public.vp2_can_view_profile(profile_id) or appraiser_user_id=auth.uid());

-- Acknowledgement follows profile visibility.
drop policy if exists vp2_ack_select_scope on public.vp2_acknowledgements;
create policy vp2_ack_select_scope on public.vp2_acknowledgements for select to authenticated
using (public.vp2_can_view_profile(profile_id));

-- Notifications are private to recipient.
drop policy if exists vp2_notifications_own on public.vp2_notifications;
create policy vp2_notifications_own on public.vp2_notifications for select to authenticated
using (user_id=auth.uid());

-- Leader activity: leader sees own activity; national oversight sees all; regional sees activity for profiles in its region.
drop policy if exists vp2_activity_select_scope on public.vp2_leader_activity;
create policy vp2_activity_select_scope on public.vp2_leader_activity for select to authenticated
using (
  leader_user_id=auth.uid()
  or public.vp2_is_national_viewer()
  or (subject_profile_id is not null and public.vp2_can_view_profile(subject_profile_id))
);

-- Audit log is intentionally not exposed to ordinary branch users.
drop policy if exists vp2_audit_select_national on public.vp2_audit_log;
create policy vp2_audit_select_national on public.vp2_audit_log for select to authenticated
using (public.vp2_current_role() in ('EXECUTIVE','NRH'));

-- Policy reference is readable to authenticated management users.
drop policy if exists vp2_policies_read on public.vp2_policies;
create policy vp2_policies_read on public.vp2_policies for select to authenticated
using (exists(select 1 from public.vp2_management_users u where u.user_id=auth.uid() and u.is_active));

-- IMPORTANT: Evidence, sign-off, case-action and mutation policies remain deny-by-default until
-- the controlled RPC/server actions are implemented. This prevents the browser from directly
-- changing points, approving its own submissions, or bypassing required workflow.
