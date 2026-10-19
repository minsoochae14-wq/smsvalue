-- 저장 함수 개선
-- 1) 중복 판단: 브랜드+마감일 → 개인정보를 가린 원문의 지문(해시)
-- 2) 신뢰도: 서버가 원문으로 다시 계산하고, AI 점수와 서버 점수 중 낮은 쪽을 저장
-- 3) 공개: 60점 이상 + 스미싱 신호 없음 + 최근 1시간 30건 미만일 때만 'approved', 나머지는 'pending'
-- 4) 입력값 검사: 길이 제한, 카테고리 목록, 마감일 범위
-- 테이블 구조·RLS·mask_pii·increment_view_count는 바꾸지 않음
-- 되돌리기: supabase/rollback/upsert_sms_benefit_before_20261019.sql

-- 문자 지문: 가려진 토큰(***), 발신 표기, 수신거부 안내, 기호·공백을 빼고 비교
create or replace function private.sms_fingerprint(t text)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select md5(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(lower(coalesce(t, '')),
            '\S*\*\S*', '', 'g'),                                      -- 가려진 이름·번호·링크
          '\[?web발신\]?|[\[(]광고[\])]', '', 'g'),                      -- 발신 표기
        '(무료\s*(수신)?\s*거부|수신\s*거부|무료\s*거부)[^\n]*', '', 'g'),  -- 수신거부 안내 줄
      '[^0-9a-z가-힣]', '', 'g')                                       -- 기호·공백
  );
$$;

-- 서버 신뢰도 점수와 스미싱 여부
create or replace function private.sms_server_trust(p_brand text, p_summary text, p_raw text, p_end_date date,
  out score integer, out smishing boolean)
language plpgsql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
declare
  t text := coalesce(p_raw, '');
  s integer := 20;
begin
  if p_brand is not null and length(btrim(p_brand)) >= 2
     and p_brand not in ('알수없음', 'Web발신', 'web발신', '광고', '공공기관') then
    s := s + 30;
  end if;
  if (coalesce(p_summary, '') || ' ' || t) ~ '(\d+\s*%|\d[\d,]*\s*(만|천)?\s*원|\d+\s*\+\s*\d+|쿠폰|할인|무료|적립|캐시백|증정|특가|세일)' then
    s := s + 20;
  end if;
  if p_end_date is not null then
    s := s + 15;
  end if;
  if t ~* '\[(?!web발신|광고)[^\]]{2,20}\]' then
    s := s + 10;
  end if;
  if t ~ '(100\s*%\s*무료|완전\s*(무료|공짜)|전부\s*공짜)' then
    s := s - 40;
  end if;
  if t ~ '(비밀번호|계좌\s*번호|카드\s*번호|인증\s*번호|주민\s*(등록)?\s*번호|개인\s*정보)[^\n]{0,15}(입력|알려|보내|회신)' then
    s := s - 30;
  end if;
  smishing := lower(t) ~ '(bit\.ly|naver\.me|url\.kr|han\.gl|me2\.do|buly\.kr|tinyurl\.com|goo\.gl|is\.gd|t\.ly|vo\.la|zrr\.kr|c11\.kr|lrl\.kr|ko\.gl|abit\.ly|tiny\.one|shorturl\.at)/'
          and t ~ '(택배|배송\s*(조회|지연|실패|불가)|주소\s*(불명|확인|오류)|환급|미납|과태료|결제\s*(완료|승인|취소)|해외\s*결제|본인\s*확인|지원금\s*(신청|지급)|검진\s*결과|부고|청첩장)';
  if smishing then
    s := s - 30;
  end if;
  if length(t) < 15 then
    s := s - 20;
  end if;
  score := greatest(0, least(100, s));
end;
$$;

revoke all on function private.sms_fingerprint(text) from public, anon, authenticated;
revoke all on function private.sms_server_trust(text, text, text, date) from public, anon, authenticated;

create or replace function public.upsert_sms_benefit(p_brand text, p_category text, p_summary text, p_raw_sms text, p_end_date date, p_location text, p_trust_score integer)
 returns json
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  c_min_score constant integer := 60;   -- 이 점수 이상만 바로 공개
  c_hourly_limit constant integer := 30; -- 최근 1시간 등록이 이 개수 이상이면 검토 대기
  c_categories constant text[] := array['음료/카페','편의점','배달앱','외식','패션/의류','뷰티/헬스','마트/쇼핑','금융/카드','통신','IT/앱','독서/교육','여행/숙박','OTT/구독','공공/기타','기타'];

  v_raw text;
  v_brand text;
  v_summary text;
  v_category text;
  v_location text;
  v_end_date date := p_end_date;
  v_fp text;
  v_client_score integer;
  v_trust record;
  v_score integer;
  v_status text;
  existing_id bigint;
  result jsonb;
begin
  -- 입력값 검사
  if length(btrim(coalesce(p_raw_sms, ''))) < 10 then
    raise exception '문자 내용이 너무 짧아요';
  end if;
  v_raw := left(public.mask_pii(p_raw_sms), 2000);
  v_brand := left(nullif(btrim(public.mask_pii(coalesce(p_brand, ''))), ''), 40);
  v_brand := coalesce(v_brand, '알수없음');
  v_summary := left(btrim(public.mask_pii(coalesce(p_summary, ''))), 60);
  v_category := case when p_category = any(c_categories) then p_category else '기타' end;
  v_location := coalesce(left(nullif(btrim(coalesce(p_location, '')), ''), 30), '전국');
  if v_end_date is not null and (v_end_date < current_date - 365 or v_end_date > current_date + 730) then
    v_end_date := null;
  end if;

  -- 같은 문자(지문 일치)가 이미 있으면 제출 수만 +1
  v_fp := private.sms_fingerprint(v_raw);
  select id into existing_id
  from public.sms_benefits
  where private.sms_fingerprint(raw_sms) = v_fp
  order by id
  limit 1;

  if existing_id is not null then
    update public.sms_benefits
    set submit_count = coalesce(submit_count, 1) + 1,
        updated_at = now()
    where id = existing_id;

    select to_jsonb(s) || jsonb_build_object('duplicate', true) into result
    from public.sms_benefits s
    where id = existing_id;
    return result::json;
  end if;

  -- 신뢰도: AI 점수와 서버 점수 중 낮은 쪽
  v_client_score := greatest(0, least(100, coalesce(p_trust_score, 50)));
  select * into v_trust from private.sms_server_trust(v_brand, v_summary, v_raw, v_end_date);
  v_score := least(v_client_score, v_trust.score);

  v_status := 'approved';
  if v_score < c_min_score or v_trust.smishing then
    v_status := 'pending';
  elsif (select count(*) from public.sms_benefits where created_at > now() - interval '1 hour') >= c_hourly_limit then
    v_status := 'pending';
  end if;

  insert into public.sms_benefits
    (brand, category, summary, raw_sms, end_date, location, trust_score, status, submit_count)
  values
    (v_brand, v_category, v_summary, v_raw, v_end_date, v_location, v_score, v_status, 1)
  returning to_jsonb(sms_benefits.*) || jsonb_build_object('duplicate', false) into result;

  return result::json;
end;
$function$;
