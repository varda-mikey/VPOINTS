-- V-POINTS 2.0 controlled action layer
-- DEVELOPMENT ONLY. Do not apply to production until reviewed/tested.
-- Depends on v2_schema.sql, v2_workflows.sql, v2_security.sql.

-- Never let the browser directly edit point totals. All official point changes go through this function.
create or replace function public.vp2_post_ledger(
  p_profile_id uuid, p_points integer, p_entry_type text, p_source_type text,
  p_source_id text, p_reason text, p_reverses_ledger_id bigint default null
) returns bigint
language plpgsql security definer set search_path=public as $$
declare v_id bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_points = 0 then raise exception 'Point entry cannot be zero'; end if;
  if not public.vp2_can_view_profile(p_profile_id) then raise exception 'Out of scope'; end if;
  if p_entry_type not in ('BASELINE','MERIT','POLICY','REVERSAL') then raise exception 'Invalid ledger type'; end if;
  if p_entry_type='REVERSAL' and (p_reverses_ledger_id is null or nullif(trim(p_reason),'') is null) then
    raise exception 'Reversal requires original entry and reason';
  end if;
  insert into public.vp2_point_ledger(profile_id,points,entry_type,source_type,source_id,reason,posted_by,reverses_ledger_id)
  values(p_profile_id,p_points,p_entry_type,p_source_type,p_source_id,p_reason,auth.uid(),p_reverses_ledger_id)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.vp2_post_ledger(uuid,integer,text,text,text,text,bigint) from public, anon, authenticated;

-- Employee activation. Validation authority: Regional OR HR OR NRH; Executive also allowed for oversight.
create or replace function public.vp2_activate_profile(p_profile_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare p public.vp2_profiles%rowtype; r text; f text;
begin
  select * into p from public.vp2_profiles where id=p_profile_id for update;
  if not found then raise exception 'Profile not found'; end if;
  r:=public.vp2_current_role(); f:=upper(coalesce(public.vp2_current_function(),''));
  if not ((r='REGIONAL_HEAD' and public.vp2_can_view_region(p.region_id)) or r in ('NRH','EXECUTIVE') or (r='NATIONAL_FUNCTIONAL_HEAD' and f='HR')) then
    raise exception 'Not authorized to activate profile';
  end if;
  if p.status='ACTIVE' then return; end if;
  update public.vp2_profiles set status='ACTIVE', activated_at=now(), activated_by=auth.uid() where id=p_profile_id;
  if not exists(select 1 from public.vp2_point_ledger where profile_id=p_profile_id and entry_type='BASELINE') then
    insert into public.vp2_point_ledger(profile_id,points,entry_type,source_type,source_id,reason,posted_by)
    values(p_profile_id,100,'BASELINE','PROFILE_ACTIVATION',p_profile_id::text,'Starting V-Points',auth.uid());
  end if;
  insert into public.vp2_audit_log(actor_user_id,event_type,entity_type,entity_id,metadata)
  values(auth.uid(),'PROFILE_ACTIVATED','PROFILE',p_profile_id::text,jsonb_build_object('baseline',100));
end $$;

-- Merit approval: staff merit requires Regional approval; management merit routes upward.
create or replace function public.vp2_approve_merit(p_merit_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare m public.vp2_merits%rowtype; p public.vp2_profiles%rowtype; r text; ledger bigint;
begin
  select * into m from public.vp2_merits where id=p_merit_id for update;
  if not found or m.status<>'PENDING' then raise exception 'Merit is not pending'; end if;
  select * into p from public.vp2_profiles where id=m.profile_id;
  r:=public.vp2_current_role();
  if m.submitted_by=auth.uid() and p.linked_user_id=auth.uid() then raise exception 'Self merit is not allowed'; end if;
  if p.profile_level in ('STAFF','BRANCH') then
    if not (r='REGIONAL_HEAD' and public.vp2_can_view_region(p.region_id)) then raise exception 'Regional approval required'; end if;
  elsif p.profile_level='REGIONAL' then
    if r not in ('NRH','EXECUTIVE') then raise exception 'National approval required'; end if;
  elsif p.profile_level='NATIONAL' then
    if r<>'EXECUTIVE' then raise exception 'Executive approval required'; end if;
  else raise exception 'Unsupported merit route'; end if;
  insert into public.vp2_point_ledger(profile_id,points,entry_type,source_type,source_id,reason,posted_by)
  values(m.profile_id,m.requested_points,'MERIT','MERIT',m.id::text,m.reason,auth.uid()) returning id into ledger;
  update public.vp2_merits set status='APPROVED',approved_by=auth.uid(),approved_at=now(),ledger_id=ledger where id=m.id;
  insert into public.vp2_audit_log(actor_user_id,event_type,entity_type,entity_id,metadata)
  values(auth.uid(),'MERIT_APPROVED','MERIT',m.id::text,jsonb_build_object('points',m.requested_points,'ledger_id',ledger));
end $$;

-- Final policy result: only after outcome/sign-offs. Point value comes from policy master, never arbitrary browser input.
create or replace function public.vp2_post_policy_result(p_case_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare c public.vp2_cases%rowtype; pol public.vp2_policies%rowtype; ledger bigint;
begin
  select * into c from public.vp2_cases where id=p_case_id for update;
  if not found then raise exception 'Case not found'; end if;
  if c.policy_id is null then raise exception 'Policy/ACT required'; end if;
  if c.hr_outcome is null then raise exception 'Recorded outcome required before posting'; end if;
  if c.status='COMPLETED' then raise exception 'Case already posted'; end if;
  if not public.vp2_has_authority('FINAL_POLICY_POST',c.region_id,c.branch_id) then raise exception 'No final posting authority'; end if;
  if exists(select 1 from public.vp2_signoffs s where s.entity_type='CASE' and s.entity_id=c.id and s.decision is null) then
    raise exception 'Required sign-off is still pending';
  end if;
  select * into pol from public.vp2_policies where id=c.policy_id and is_active;
  if not found then raise exception 'Active policy not found'; end if;
  if upper(c.hr_outcome) in ('NOT SUBSTANTIATED','DISMISSED','NO POINT EFFECT') then
    update public.vp2_cases set final_point_effect=0,status='CLOSED',closed_by=auth.uid(),closed_at=now(),updated_at=now() where id=c.id;
  else
    if coalesce(pol.points,0)<=0 then raise exception 'Policy has no configured point deduction'; end if;
    insert into public.vp2_point_ledger(profile_id,points,entry_type,source_type,source_id,reason,posted_by)
    values(c.profile_id,-abs(pol.points),'POLICY','CASE',c.id::text,pol.act_code||' — '||pol.title,auth.uid()) returning id into ledger;
    update public.vp2_cases set final_point_effect=-abs(pol.points),status='COMPLETED',closed_by=auth.uid(),closed_at=now(),updated_at=now() where id=c.id;
  end if;
  insert into public.vp2_audit_log(actor_user_id,event_type,entity_type,entity_id,metadata)
  values(auth.uid(),'POLICY_RESULT_POSTED','CASE',c.id::text,jsonb_build_object('act',pol.act_code));
end $$;

-- Controlled reversal. Original ledger row remains immutable.
create or replace function public.vp2_reverse_ledger(p_ledger_id bigint,p_reason text)
returns bigint language plpgsql security definer set search_path=public as $$
declare old public.vp2_point_ledger%rowtype; newid bigint;
begin
  if nullif(trim(p_reason),'') is null then raise exception 'Correction reason required'; end if;
  if public.vp2_current_role() not in ('NRH','EXECUTIVE') then raise exception 'National authorization required'; end if;
  select * into old from public.vp2_point_ledger where id=p_ledger_id;
  if not found then raise exception 'Ledger entry not found'; end if;
  if exists(select 1 from public.vp2_point_ledger where reverses_ledger_id=p_ledger_id) then raise exception 'Entry already reversed'; end if;
  insert into public.vp2_point_ledger(profile_id,points,entry_type,source_type,source_id,reason,posted_by,reverses_ledger_id)
  values(old.profile_id,-old.points,'REVERSAL','LEDGER_CORRECTION',old.id::text,p_reason,auth.uid(),old.id) returning id into newid;
  insert into public.vp2_audit_log(actor_user_id,event_type,entity_type,entity_id,metadata)
  values(auth.uid(),'LEDGER_REVERSED','POINT_LEDGER',old.id::text,jsonb_build_object('reversal_id',newid,'reason',p_reason));
  return newid;
end $$;

-- Meaningful staff review event. One coverage credit per leader/profile/day; repeated tapping cannot farm coverage.
create unique index if not exists vp2_activity_review_daily_unique
on public.vp2_leader_activity(leader_user_id,subject_profile_id,event_date)
where event_type='PROFILE_REVIEW';

create or replace function public.vp2_record_profile_review(p_profile_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if not public.vp2_can_view_profile(p_profile_id) then raise exception 'Out of scope'; end if;
  insert into public.vp2_leader_activity(leader_user_id,subject_profile_id,event_type,event_date,metadata)
  values(auth.uid(),p_profile_id,'PROFILE_REVIEW',current_date,jsonb_build_object('source','employee_profile'))
  on conflict do nothing;
  return found;
end $$;

-- Monthly Team Coverage: distinct active profiles reviewed at least once in the period.
create or replace function public.vp2_team_coverage(p_start date default date_trunc('month',current_date)::date,p_end date default current_date)
returns table(reviewed bigint,total bigint,coverage_percent numeric)
language sql stable security definer set search_path=public as $$
  with eligible as (
    select p.id from public.vp2_profiles p
    where p.status='ACTIVE' and p.profile_level in ('STAFF','BRANCH') and public.vp2_can_view_profile(p.id)
  ), reviewed_profiles as (
    select distinct a.subject_profile_id id from public.vp2_leader_activity a
    join eligible e on e.id=a.subject_profile_id
    where a.leader_user_id=auth.uid() and a.event_type='PROFILE_REVIEW' and a.event_date between p_start and p_end
  )
  select (select count(*) from reviewed_profiles), (select count(*) from eligible),
    case when (select count(*) from eligible)=0 then 0
    else round(100.0*(select count(*) from reviewed_profiles)/(select count(*) from eligible),1) end;
$$;

-- Public execution is denied; authenticated users receive only the specific safe actions below.
revoke all on function public.vp2_activate_profile(uuid) from public,anon;
revoke all on function public.vp2_approve_merit(uuid) from public,anon;
revoke all on function public.vp2_post_policy_result(uuid) from public,anon;
revoke all on function public.vp2_reverse_ledger(bigint,text) from public,anon;
revoke all on function public.vp2_record_profile_review(uuid) from public,anon;
revoke all on function public.vp2_team_coverage(date,date) from public,anon;
grant execute on function public.vp2_activate_profile(uuid) to authenticated;
grant execute on function public.vp2_approve_merit(uuid) to authenticated;
grant execute on function public.vp2_post_policy_result(uuid) to authenticated;
grant execute on function public.vp2_reverse_ledger(bigint,text) to authenticated;
grant execute on function public.vp2_record_profile_review(uuid) to authenticated;
grant execute on function public.vp2_team_coverage(date,date) to authenticated;
