-- V-POINTS 2.0 ACT routing engine
-- DEVELOPMENT ONLY. Policy substance must come from official VARDA ACT source.
-- This file maps legacy approval labels to V2 workflow roles without changing ACT rules/points.

create or replace function public.vp2_route_from_policy(
  p_department text,
  p_legacy_approval text,
  p_severity text
) returns jsonb
language plpgsql immutable as $$
declare
  d text:=upper(coalesce(p_department,''));
  a text:=upper(coalesce(p_legacy_approval,''));
  s text:=upper(coalesce(p_severity,''));
  reviewers jsonb:='[]'::jsonb;
  final_role text;
begin
  -- Branch Manager legacy review is represented by operational branch/regional review.
  if a like '%BRANCH MANAGER%' then reviewers:=reviewers||'"REGIONAL_HEAD"'::jsonb; end if;
  if a like '%PEOPLE MANAGEMENT%' or d like '%PEOPLE MANAGEMENT%' then reviewers:=reviewers||'"HR"'::jsonb; end if;
  if a like '%FSQA%' or d='FSQA' or d like '%FSQA%' then reviewers:=reviewers||'"FSQA"'::jsonb; end if;
  if a like '%ACCOUNT%' or d like '%ACCOUNT%' then reviewers:=reviewers||'"ACCOUNTING"'::jsonb; end if;
  if a like '%SAFETY%' then reviewers:=reviewers||'"SAFETY"'::jsonb; end if;
  if a like '%RETAIL MANAGEMENT%' then reviewers:=reviewers||'"NRH"'::jsonb; end if;
  if a like '%EXECUTIVE%' then reviewers:=reviewers||'"EXECUTIVE"'::jsonb; end if;

  -- Final posting authority is intentionally conservative.
  if a like '%EXECUTIVE%' then final_role:='EXECUTIVE';
  elsif a like '%RETAIL MANAGEMENT%' or s='CRITICAL' then final_role:='NRH';
  else final_role:='REGIONAL_HEAD'; end if;

  return jsonb_build_object(
    'reviewers',reviewers,
    'final_posting_role',final_role,
    'source','LEGACY_APPROVAL_MAPPING',
    'note','Visibility is separate from sign-off and final posting authority.'
  );
end $$;

-- Rebuild route metadata from the official policy fields after ACT import/update.
create or replace function public.vp2_refresh_policy_routes()
returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
  if public.vp2_current_role() not in ('NRH','EXECUTIVE') then raise exception 'National authorization required'; end if;
  update public.vp2_policies
  set mapped_route=public.vp2_route_from_policy(department,legacy_approval,severity), updated_at=now();
  get diagnostics n=row_count;
  insert into public.vp2_audit_log(actor_user_id,event_type,entity_type,entity_id,metadata)
  values(auth.uid(),'POLICY_ROUTES_REFRESHED','POLICY_MASTER','ALL',jsonb_build_object('count',n));
  return n;
end $$;

-- Generate required sign-off rows for a case from policy routing.
create or replace function public.vp2_prepare_case_route(p_case_id uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare c public.vp2_cases%rowtype; p public.vp2_policies%rowtype; role_name text; n integer:=0;
begin
  select * into c from public.vp2_cases where id=p_case_id for update;
  if not found then raise exception 'Case not found'; end if;
  if not public.vp2_can_view_profile(c.profile_id) then raise exception 'Out of scope'; end if;
  if c.policy_id is null then raise exception 'ACT policy required'; end if;
  select * into p from public.vp2_policies where id=c.policy_id and is_active;
  if not found then raise exception 'Active ACT policy not found'; end if;

  for role_name in select distinct value#>>'{}' from jsonb_array_elements(coalesce(p.mapped_route->'reviewers','[]'::jsonb)) loop
    if not exists(select 1 from public.vp2_signoffs where entity_type='CASE' and entity_id=c.id and required_role=role_name) then
      insert into public.vp2_signoffs(entity_type,entity_id,required_role) values('CASE',c.id,role_name); n:=n+1;
    end if;
  end loop;
  update public.vp2_cases set status='FOR REVIEW',updated_at=now() where id=c.id;
  insert into public.vp2_case_actions(case_id,action_type,remarks,actor_user_id)
  values(c.id,'ROUTE_PREPARED','Required review/sign-off route generated from ACT policy master.',auth.uid());
  return n;
end $$;

-- Record a controlled case sign-off. Reviewer role/function must match required role.
create or replace function public.vp2_decide_signoff(p_signoff_id bigint,p_decision text,p_remarks text default null)
returns void language plpgsql security definer set search_path=public as $$
declare s public.vp2_signoffs%rowtype; c public.vp2_cases%rowtype; rolecode text; func text; allowed boolean:=false;
begin
  select * into s from public.vp2_signoffs where id=p_signoff_id for update;
  if not found or s.entity_type<>'CASE' then raise exception 'Sign-off not found'; end if;
  select * into c from public.vp2_cases where id=s.entity_id;
  if not public.vp2_can_view_profile(c.profile_id) then raise exception 'Out of scope'; end if;
  rolecode:=public.vp2_current_role(); func:=upper(coalesce(public.vp2_current_function(),''));
  allowed:=case s.required_role
    when 'REGIONAL_HEAD' then rolecode='REGIONAL_HEAD' and public.vp2_can_view_region(c.region_id)
    when 'HR' then public.vp2_has_authority('HR_REVIEW',c.region_id,c.branch_id)
    when 'FSQA' then public.vp2_has_authority('FSQA_REVIEW',c.region_id,c.branch_id)
    when 'NRH' then rolecode in ('NRH','EXECUTIVE')
    when 'EXECUTIVE' then rolecode='EXECUTIVE'
    when 'ACCOUNTING' then rolecode='EXECUTIVE' or rolecode='NRH' or (rolecode='NATIONAL_FUNCTIONAL_HEAD' and func='ACCOUNTING')
    when 'SAFETY' then rolecode in ('NRH','EXECUTIVE') or (rolecode='NATIONAL_FUNCTIONAL_HEAD' and func='SAFETY')
    else false end;
  if not allowed then raise exception 'Reviewer does not hold required authority'; end if;
  if upper(p_decision) not in ('SIGNED OFF','RETURN','NEEDS MORE INFORMATION','NOT RELIED UPON') then raise exception 'Invalid decision'; end if;
  update public.vp2_signoffs set decision=upper(p_decision),remarks=p_remarks,reviewer_user_id=auth.uid(),decided_at=now() where id=s.id;
  insert into public.vp2_case_actions(case_id,action_type,outcome,remarks,actor_user_id)
  values(c.id,'SIGNOFF',upper(p_decision),p_remarks,auth.uid());
end $$;

revoke all on function public.vp2_refresh_policy_routes() from public,anon;
revoke all on function public.vp2_prepare_case_route(uuid) from public,anon;
revoke all on function public.vp2_decide_signoff(bigint,text,text) from public,anon;
grant execute on function public.vp2_refresh_policy_routes() to authenticated;
grant execute on function public.vp2_prepare_case_route(uuid) to authenticated;
grant execute on function public.vp2_decide_signoff(bigint,text,text) to authenticated;
