-- 링크 정책 통일 + 기존 데이터 정리 + 원문 백업 삭제
-- 1) mask_pii: 링크(경로·쿼리·단축URL) 가리기를 뺌 — 앱과 같은 정책(링크는 그대로)
-- 2) sms_fingerprint: 링크를 빼고 비교 (링크가 가려진 예전 글과 새 글을 같은 문자로 인식)
-- 3) 백업 원문에 새 mask_pii를 다시 적용해 기존 글의 가려진 링크만 복원
-- 4) 같은 문자(지문 일치)는 한 글만 공개하고 나머지는 pending, 제출·조회 수는 남는 글에 합산
-- 5) 새 채점 기준(min(AI 점수, 서버 점수) < 60 또는 스미싱) 미달 글은 pending
-- 6) 원문 백업 삭제는 다음 파일(20261019170100_drop_raw_backup.sql)에서
-- 되돌리기: 4)·5)는 supabase/rollback/cleanup_20261019.sql, 1)·2)는 같은 파일의 함수 정의. 3)은 되돌릴 수 없음

create or replace function public.mask_pii(t text)
 returns text
 language plpgsql
 immutable
 set search_path to 'public', 'pg_temp'
as $function$
declare
  r text;
begin
  if t is null then
    return null;
  end if;
  r := t;

  -- 1) 주민등록번호
  r := regexp_replace(r, '\d{6}[-\s]?[1-4]\d{6}', '******-*******', 'g');
  -- 2) 카드번호(16자리): 뒤 4자리만 남김
  r := regexp_replace(r, '(?<!\d)(?:\d{4}[-\s]?){3}(\d{4})(?!\d)', '****-****-****-\1', 'g');
  -- 3) 휴대폰(010 등): 가운데 가림 (080/1588 등 업체 번호는 유지)
  r := regexp_replace(r, '(?<!\d)(01[016789])[-.\s]?\d{3,4}[-.\s]?(\d{4})(?!\d)', '\1-****-\2', 'g');
  -- 4) 이메일
  r := regexp_replace(r, '([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+\.[A-Za-z]{2,})', '\1***@\2', 'g');
  -- 5) 계좌번호(키워드 뒤): 뒤 4자리만 남김
  r := regexp_replace(r, '(계좌(?:번호)?|입금\s?계좌|입금처)(\s*[:：]?\s*(?:[가-힣A-Za-z]{2,10}\s)?)(\d[\d-]{4,})(\d{4})(?!\d)', '\1\2****\4', 'g');
  -- 5-2) 예금주 이름
  r := regexp_replace(r, '(예금주)(\s*[:：]?\s*)([가-힣])[가-힣]{1,3}', '\1\2\3**', 'g');
  -- 6a) 본인 식별성이 강한 번호(인증/회원/주문/예약 등)
  r := regexp_replace(r, '(?<![A-Za-z])(인증\s?번호|인증\s?코드|회원\s?번호|멤버십\s?번호|고객\s?번호|주문\s?번호|예약\s?번호|접수\s?번호|계약\s?번호|OTP|PIN)(?![A-Za-z])(\s*[:：=]?\s*)([A-Za-z0-9])([A-Za-z0-9])[A-Za-z0-9-]{2,}', '\1\2\3\4****', 'gi');
  -- 6b) 쿠폰/코드: 10자 이상 긴 코드만 개인화로 보고 가림 (BAEMIN25 같은 짧은 공용 코드는 유지)
  r := regexp_replace(r, '(쿠폰\s?번호|쿠폰\s?코드|쿠폰|프로모션\s?코드|할인\s?코드|초대\s?코드|추천인?\s?코드|바우처\s?번호|코드)(\s*[:：=]?\s*)([A-Za-z0-9])([A-Za-z0-9])[A-Za-z0-9-]{8,}', '\1\2\3\4******', 'g');
  -- 7) 링크는 가리지 않음 (개인 추적 링크와 일반 링크를 구분할 수 없어 앱과 같이 그대로 둠)
  -- 8) 사람 이름: OOO 고객님 / OOO님 (3글자 + 흔한 성씨만)
  r := regexp_replace(r, '(?<![가-힣])(?!이용자|구매자|주문자|신청자|방문자|소비자|가입자|구독자|임직원)([김이박최정강조윤장임한오서신권황안송류전홍고문양손배백허유남심노하곽성차주우구민나진지엄채원천방공현함변염여추도소석선설마길연위표명기반왕금옥육인맹제모탁국어은편용예경봉부])[가-힣]([가-힣])(\s?)(고객님|회원님|님)', '\1*\2\3\4', 'g');

  return r;
end;
$function$;

-- 문자 지문: 링크, 가려진 토큰(***), 발신 표기, 수신거부 안내, 기호·공백을 빼고 비교
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
          regexp_replace(
            regexp_replace(lower(coalesce(t, '')),
              '(https?://)?([a-z0-9-]+\.)+[a-z]{2,}(/\S*)?', '', 'g'),       -- 링크
            '\S*\*\S*', '', 'g'),                                          -- 가려진 이름·번호
          '\[?web발신\]?|[\[(]광고[\])]', '', 'g'),                          -- 발신 표기
        '(무료\s*(수신)?\s*거부|수신\s*거부|무료\s*거부)[^\n]*', '', 'g'),      -- 수신거부 안내 줄
      '[^0-9a-z가-힣]', '', 'g')                                           -- 기호·공백
  );
$$;
revoke all on function private.sms_fingerprint(text) from public, anon, authenticated;

-- 3) 링크 복원: 지금 원문 = mask_pii(백업 원문) 이므로, 새 mask_pii로 다시 가리면 링크만 원래대로 돌아옴
update public.sms_benefits s
set raw_sms = left(public.mask_pii(b.raw_sms), 2000)
from private.sms_benefits_raw_backup b
where b.id = s.id
  and s.raw_sms is distinct from left(public.mask_pii(b.raw_sms), 2000);

-- 4) 중복 정리: 같은 지문 묶음에서 한 글만 남김
--    남길 글 순서: 의미 없는 브랜드 제외 → 묶음 안 다수 브랜드 → 원문에 있는 브랜드 → 원문 앞쪽 브랜드 → 서버 점수 → AI 점수 → 먼저 올라온 글
with base as (
  select s.id, s.brand, s.raw_sms, s.summary, s.end_date, s.trust_score,
         coalesce(s.submit_count, 1) as submits, coalesce(s.view_count, 0) as views,
         private.sms_fingerprint(s.raw_sms) as fp
  from public.sms_benefits s
  where s.status = 'approved'
),
voted as (
  select b.*,
         count(*) over (partition by fp, brand) as brand_votes,
         count(*) over (partition by fp) as n,
         sum(submits) over (partition by fp) as total_submits,
         sum(views) over (partition by fp) as total_views
  from base b
),
ranked as (
  select v.*,
         row_number() over (
           partition by fp
           order by (brand in ('알수없음', 'Web발신', 'web발신', '광고', '공공기관')) asc,
                    brand_votes desc,
                    (strpos(raw_sms, brand) > 0) desc,
                    nullif(strpos(raw_sms, brand), 0) asc nulls last,
                    (private.sms_server_trust(brand, summary, raw_sms, end_date)).score desc,
                    trust_score desc nulls last,
                    id
         ) as rn
  from voted v
)
update public.sms_benefits s
set submit_count = case when r.rn = 1 then r.total_submits else s.submit_count end,
    view_count   = case when r.rn = 1 then r.total_views   else s.view_count end,
    status       = case when r.rn = 1 then s.status        else 'pending' end,
    updated_at   = now()
from ranked r
where s.id = r.id and r.n > 1;

-- 5) 새 채점 기준 미달 글 숨김
update public.sms_benefits s
set status = 'pending', updated_at = now()
where s.status = 'approved'
  and (
    least(coalesce(s.trust_score, 50), (private.sms_server_trust(s.brand, s.summary, s.raw_sms, s.end_date)).score) < 60
    or (private.sms_server_trust(s.brand, s.summary, s.raw_sms, s.end_date)).smishing
  );
