create or replace function public.admin_activity_feed(p_period text default 'today')
returns table(
  activity_type text,
  title text,
  description text,
  user_id uuid,
  task_id uuid,
  amount numeric,
  status text,
  created_at timestamptz
)
language sql
security definer
set search_path = pg_catalog, public, auth
as $$
with bounds as (
  select case lower(coalesce(p_period,'today'))
    when 'week' then date_trunc('week', now() at time zone 'Africa/Lagos') at time zone 'Africa/Lagos'
    when 'month' then date_trunc('month', now() at time zone 'Africa/Lagos') at time zone 'Africa/Lagos'
    else date_trunc('day', now() at time zone 'Africa/Lagos') at time zone 'Africa/Lagos'
  end as start_at
),
events as (
  select 'signup'::text,'New signup'::text,coalesce(p.full_name,p.username,'New StudTask user')::text,u.id,null::uuid,null::numeric,'registered'::text,u.created_at
  from auth.users u left join public.profiles p on p.id=u.id,bounds b where u.created_at>=b.start_at
  union all
  select 'deposit','Deposit','₦'||to_char(d.amount,'FM999,999,990.00')||' via '||coalesce(d.provider,'payment'),d.user_id,null,d.amount,d.status,d.created_at
  from public.deposit_requests d,bounds b where d.created_at>=b.start_at
  union all
  select 'task','New task',t.title,t.user_id,t.id,t.budget,t.status,t.created_at
  from public.tasks t,bounds b where t.created_at>=b.start_at
  union all
  select 'application','Task application',coalesce(t.title,'Task')||' — application submitted',a.runner_id,a.task_id,null,a.status,a.created_at
  from public.task_applications a left join public.tasks t on t.id=a.task_id,bounds b where a.created_at>=b.start_at
  union all
  select 'verification','Verification submitted',coalesce(p.full_name,p.username,'User')||' submitted profile verification',v.user_id,null,null,v.status,v.submitted_at
  from public.profile_verifications v left join public.profiles p on p.id=v.user_id,bounds b where v.submitted_at>=b.start_at
  union all
  select 'verification_review','Verification reviewed',coalesce(p.full_name,p.username,'User')||' verification was reviewed',v.user_id,null,null,v.status,v.reviewed_at
  from public.profile_verifications v left join public.profiles p on p.id=v.user_id,bounds b where v.reviewed_at is not null and v.reviewed_at>=b.start_at
  union all
  select 'withdrawal','Withdrawal request','₦'||to_char(w.amount,'FM999,999,990.00')||' withdrawal request',w.user_id,null,w.amount,w.status,w.created_at
  from public.withdrawal_requests w,bounds b where w.created_at>=b.start_at
  union all
  select 'withdrawal_processed','Withdrawal processed','₦'||to_char(w.net_amount,'FM999,999,990.00')||' withdrawal processed',w.user_id,null,w.net_amount,w.status,w.processed_at
  from public.withdrawal_requests w,bounds b where w.processed_at is not null and w.processed_at>=b.start_at
  union all
  select 'task_payment','Task payment',coalesce(t.title,'Task payment'),coalesce(tp.runner_id,tp.poster_id),tp.task_id,tp.amount,tp.status,tp.created_at
  from public.task_payments tp left join public.tasks t on t.id=tp.task_id,bounds b where tp.created_at>=b.start_at
  union all
  select 'task_payment_update','Task payment update',coalesce(t.title,'Task payment'),coalesce(tp.runner_id,tp.poster_id),tp.task_id,tp.amount,tp.status,tp.updated_at
  from public.task_payments tp left join public.tasks t on t.id=tp.task_id,bounds b where tp.updated_at>=b.start_at and tp.updated_at<>tp.created_at
  union all
  select 'review','Review submitted',coalesce(p.full_name,p.username,'User')||' left a '||r.rating||'/5 review',r.reviewer_id,r.task_id,null,null,r.created_at
  from public.reviews r left join public.profiles p on p.id=r.reviewer_id,bounds b where r.created_at>=b.start_at
  union all
  select 'report','Report submitted',coalesce(r.reason,'User report'),r.reporter_id,r.task_id,null,r.status,r.created_at
  from public.reports r,bounds b where r.created_at>=b.start_at
  union all
  select 'dispute','Task dispute',coalesce(d.reason,'Task dispute'),d.opened_by,d.task_id,null,d.status,d.created_at
  from public.task_disputes d,bounds b where d.created_at>=b.start_at
  union all
  select 'support','Support ticket',s.subject,s.user_id,null,null,s.status,s.created_at
  from public.support_tickets s,bounds b where s.created_at>=b.start_at
  union all
  select 'tip','Tip sent','₦'||to_char(t.amount,'FM999,999,990.00')||' tip',t.tipper_id,null,t.amount,null,t.created_at
  from public.tips t,bounds b where t.created_at>=b.start_at
  union all
  select 'referral','Referral','Referral registration',r.referrer_id,null,null,r.status,r.created_at
  from public.referrals r,bounds b where r.created_at>=b.start_at
  union all
  select 'cancellation','Task cancelled',coalesce(c.reason,'Task cancelled'),c.cancelled_by,c.task_id,null,c.previous_status,c.created_at
  from public.task_cancellations c,bounds b where c.created_at>=b.start_at
  union all
  select 'admin','Admin action',coalesce(l.action,'Admin action')||case when coalesce(l.details,'')<>'' then ': '||l.details else '' end,l.target_user_id,l.target_task_id,null,l.action,l.created_at
  from public.admin_logs l,bounds b where l.created_at>=b.start_at
  union all
  select 'waitlist','Waitlist signup',w.full_name,null,null,null,w.contact_status,w.created_at
  from public.waitlist_signups w,bounds b where w.created_at>=b.start_at
)
select * from events
where exists (select 1 from public.admin_users au where au.user_id=auth.uid())
order by created_at desc
limit 500;
$$;

revoke all on function public.admin_activity_feed(text) from public, anon, authenticated;
grant execute on function public.admin_activity_feed(text) to authenticated;
