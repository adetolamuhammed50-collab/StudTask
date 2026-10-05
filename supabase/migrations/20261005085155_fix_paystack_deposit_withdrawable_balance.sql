-- Fix Paystack deposits so newly credited funds are also withdrawable/usable for task funding.
-- Repair legacy wallet rows where available and withdrawable balances drifted apart.

create or replace function public.complete_paystack_deposit(p_reference text, p_amount numeric, p_payload jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path to ''
as $function$
declare v_ref text:=trim(coalesce(p_reference,'')); v_d public.deposit_requests%rowtype; v_w public.wallets%rowtype; v_event uuid; v_event_key text:='charge.success:'||v_ref;
begin
 if v_ref='' or length(v_ref)>120 then raise exception 'INVALID_PROVIDER_REFERENCE'; end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'INVALID_AMOUNT'; end if;
 insert into public.payment_webhook_events(provider,event_id,event_type,processed,payload)
 values('paystack',v_event_key,'charge.success',false,coalesce(p_payload,'{}'::jsonb))
 on conflict (provider,event_id) do nothing returning id into v_event;
 if v_event is null then
   select id into v_event from public.payment_webhook_events where provider='paystack' and event_id=v_event_key for update;
   if (select processed from public.payment_webhook_events where id=v_event) then return; end if;
 end if;
 select * into v_d from public.deposit_requests where provider='paystack' and provider_reference=v_ref for update;
 if not found then raise exception 'DEPOSIT_NOT_FOUND'; end if;
 if v_d.status<>'pending' then
   update public.payment_webhook_events set processed=true,processed_at=now() where id=v_event;
   return;
 end if;
 if v_d.amount<>p_amount then raise exception 'AMOUNT_MISMATCH'; end if;
 if upper(coalesce(p_payload->'data'->>'currency','NGN'))<>'NGN' then raise exception 'INVALID_CURRENCY'; end if;
 if coalesce(p_payload->'data'->>'status','success')<>'success' then raise exception 'INVALID_PAYMENT_STATUS'; end if;
 select * into v_w from public.wallets where id=v_d.user_id for update;
 if not found then insert into public.wallets(id) values(v_d.user_id) returning * into v_w; end if;
 update public.wallets
 set available_balance=available_balance+v_d.amount,
     withdrawable_balance=withdrawable_balance+v_d.amount,
     updated_at=now()
 where id=v_d.user_id;
 insert into public.wallet_transactions(user_id,type,amount,reference_type,reference_id,description,status)
 values(v_d.user_id,'deposit',v_d.amount,'deposit',v_d.id,'Paystack deposit','completed');
 update public.deposit_requests set status='completed',processed_at=now() where id=v_d.id;
 update public.payment_webhook_events set processed=true,processed_at=now() where id=v_event;
end;
$function$;

update public.wallets
set withdrawable_balance=available_balance, updated_at=now()
where withdrawable_balance is distinct from available_balance;
