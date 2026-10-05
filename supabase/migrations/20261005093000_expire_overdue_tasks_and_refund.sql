-- Automatically expire incomplete tasks after their deadline.
-- Refund any still-locked task funds to the poster.
-- Prevent applications from being inserted after a task deadline.

create or replace function public.expire_overdue_tasks()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_task public.tasks%rowtype;
  v_payment public.task_payments%rowtype;
  v_wallet public.wallets%rowtype;
  v_count integer := 0;
begin
  for v_task in
    select *
    from public.tasks
    where deadline <= now()
      and status in ('open','accepted','in_progress')
    order by deadline
    for update skip locked
  loop
    select * into v_payment from public.task_payments where task_id=v_task.id for update;

    if found and v_payment.status='locked' then
      if v_payment.poster_id<>v_task.user_id or v_payment.amount<>v_task.budget then
        raise exception 'TASK_PAYMENT_INTEGRITY_FAILED for task %', v_task.id;
      end if;

      select * into v_wallet from public.wallets where id=v_task.user_id for update;
      if not found or v_wallet.locked_balance < v_payment.amount then
        raise exception 'TASK_REFUND_FUNDS_UNAVAILABLE for task %', v_task.id;
      end if;

      update public.wallets
      set available_balance=available_balance+v_payment.amount,
          withdrawable_balance=withdrawable_balance+v_payment.amount,
          locked_balance=locked_balance-v_payment.amount,
          updated_at=now()
      where id=v_task.user_id;

      insert into public.wallet_transactions
        (user_id,type,amount,reference_type,reference_id,description,status)
      values
        (v_task.user_id,'task_refund',v_payment.amount,'task',v_task.id,
         'Task funds refunded because the deadline passed','completed');

      update public.task_payments
      set status='refunded',updated_at=now()
      where id=v_payment.id and status='locked';
    end if;

    update public.task_applications
    set status='rejected'
    where task_id=v_task.id and status in ('pending','selected');

    perform set_config('app.allow_task_system_update','on',true);

    update public.tasks
    set status='cancelled',
        rejection_note='Task expired because its deadline passed.'
    where id=v_task.id and status in ('open','accepted','in_progress');

    perform set_config('app.allow_task_system_update','off',true);

    insert into public.notifications(user_id,task_id,type,title,message,is_read)
    values
      (v_task.user_id,v_task.id,'task_expired','Task expired',
       'Your task passed its deadline and was cancelled. Any locked task funds were refunded to your wallet.',false);

    if v_task.runner_id is not null and v_task.runner_id<>v_task.user_id then
      insert into public.notifications(user_id,task_id,type,title,message,is_read)
      values
        (v_task.runner_id,v_task.id,'task_expired','Task expired',
         'This task passed its deadline and is no longer active.',false);
    end if;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

create or replace function public.prevent_application_after_deadline()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare v_task public.tasks%rowtype;
begin
  select * into v_task from public.tasks where id=new.task_id;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.status <> 'open' or v_task.deadline <= now() then
    raise exception 'TASK_DEADLINE_PASSED';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_prevent_application_after_deadline on public.task_applications;
create trigger trg_prevent_application_after_deadline
before insert on public.task_applications
for each row execute function public.prevent_application_after_deadline();

revoke execute on function public.expire_overdue_tasks() from public;
revoke execute on function public.expire_overdue_tasks() from anon;
revoke execute on function public.expire_overdue_tasks() from authenticated;

select cron.unschedule(1);
select cron.schedule('expire-overdue-tasks-every-5-minutes','*/5 * * * *','select public.expire_overdue_tasks();');

select public.expire_overdue_tasks();
