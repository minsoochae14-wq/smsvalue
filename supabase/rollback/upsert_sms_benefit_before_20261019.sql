-- 되돌리기용: 20261019 harden_upsert_sms_benefit 적용 전의 upsert_sms_benefit 정의
-- 문제가 생기면 이 파일을 SQL Editor에서 실행하면 이전 동작으로 돌아갑니다.
-- (새로 추가한 private.sms_fingerprint / private.sms_server_trust 함수는 남아 있어도 무해합니다)

CREATE OR REPLACE FUNCTION public.upsert_sms_benefit(p_brand text, p_category text, p_summary text, p_raw_sms text, p_end_date date, p_location text, p_trust_score integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  existing_id bigint;
  result json;
  v_raw text := left(public.mask_pii(p_raw_sms), 2000);
  v_summary text := public.mask_pii(p_summary);
begin
  -- brand + end_date 기준으로 중복 확인
  -- end_date가 null이면 brand + summary 기준
  select id into existing_id
  from public.sms_benefits
  where brand = p_brand
    and (
      (p_end_date is not null and end_date = p_end_date)
      or
      (p_end_date is null and summary = v_summary)
    )
  limit 1;

  if existing_id is not null then
    -- 이미 있으면 카운트만 +1
    update public.sms_benefits
    set submit_count = submit_count + 1,
        updated_at = now()
    where id = existing_id;

    select row_to_json(s) into result
    from public.sms_benefits s
    where id = existing_id;
  else
    -- 없으면 새로 추가 (마스킹된 문자만 저장)
    insert into public.sms_benefits
      (brand, category, summary, raw_sms, end_date, location, trust_score, status, submit_count)
    values
      (p_brand, p_category, v_summary, v_raw, p_end_date, p_location, p_trust_score, 'approved', 1)
    returning row_to_json(sms_benefits.*) into result;
  end if;

  return result;
end;
$function$;
