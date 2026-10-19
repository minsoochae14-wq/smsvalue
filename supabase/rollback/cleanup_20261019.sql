-- 되돌리기: 20261019170000_keep_links_restore_and_cleanup 의 4)·5) 데이터 정리와 1)·2) 함수 변경
-- (3) 링크 복원과 20261019170100 백업 삭제는 되돌릴 수 없음)

-- 숨김(pending) 처리했던 글 다시 공개
update public.sms_benefits set status = 'approved'
where id in (2, 4, 5, 6, 7, 8, 12, 13, 14, 16, 19, 23, 25, 26, 28, 31, 32, 33, 35, 64, 81, 86, 93);

-- 중복 정리로 합산했던 제출 수·조회 수를 원래 값으로 (정리 직전 값)
update public.sms_benefits as s set submit_count = v.submits, view_count = v.views
from (values (3, 1, 0), (38, 1, 0), (34, 1, 1), (48, 2, 4), (50, 2, 0), (53, 1, 0), (63, 2, 0)) as v(id, submits, views)
where s.id = v.id;

-- 지문 함수: 링크를 빼지 않던 이전 정의
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
            '\S*\*\S*', '', 'g'),
          '\[?web발신\]?|[\[(]광고[\])]', '', 'g'),
        '(무료\s*(수신)?\s*거부|수신\s*거부|무료\s*거부)[^\n]*', '', 'g'),
      '[^0-9a-z가-힣]', '', 'g')
  );
$$;
revoke all on function private.sms_fingerprint(text) from public, anon, authenticated;

-- mask_pii: 링크(쿼리·단축URL·토큰형 경로)도 가리던 이전 정의
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
  r := regexp_replace(r, '\d{6}[-\s]?[1-4]\d{6}', '******-*******', 'g');
  r := regexp_replace(r, '(?<!\d)(?:\d{4}[-\s]?){3}(\d{4})(?!\d)', '****-****-****-\1', 'g');
  r := regexp_replace(r, '(?<!\d)(01[016789])[-.\s]?\d{3,4}[-.\s]?(\d{4})(?!\d)', '\1-****-\2', 'g');
  r := regexp_replace(r, '([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+\.[A-Za-z]{2,})', '\1***@\2', 'g');
  r := regexp_replace(r, '(계좌(?:번호)?|입금\s?계좌|입금처)(\s*[:：]?\s*(?:[가-힣A-Za-z]{2,10}\s)?)(\d[\d-]{4,})(\d{4})(?!\d)', '\1\2****\4', 'g');
  r := regexp_replace(r, '(예금주)(\s*[:：]?\s*)([가-힣])[가-힣]{1,3}', '\1\2\3**', 'g');
  r := regexp_replace(r, '(?<![A-Za-z])(인증\s?번호|인증\s?코드|회원\s?번호|멤버십\s?번호|고객\s?번호|주문\s?번호|예약\s?번호|접수\s?번호|계약\s?번호|OTP|PIN)(?![A-Za-z])(\s*[:：=]?\s*)([A-Za-z0-9])([A-Za-z0-9])[A-Za-z0-9-]{2,}', '\1\2\3\4****', 'gi');
  r := regexp_replace(r, '(쿠폰\s?번호|쿠폰\s?코드|쿠폰|프로모션\s?코드|할인\s?코드|초대\s?코드|추천인?\s?코드|바우처\s?번호|코드)(\s*[:：=]?\s*)([A-Za-z0-9])([A-Za-z0-9])[A-Za-z0-9-]{8,}', '\1\2\3\4******', 'g');
  r := regexp_replace(r, '((?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}/[^\s?#)」』>]*)[?#][^\s)」』>]*', '\1?***', 'gi');
  r := regexp_replace(r, '(?<![A-Za-z0-9.-])(bit\.ly|naver\.me|url\.kr|han\.gl|vo\.la|me2\.do|buly\.kr|t\.ly|tinyurl\.com|goo\.gl|is\.gd|s\.id|zrr\.kr|c11\.kr|dub\.sh|rb\.gy|lrl\.kr|ko\.gl|abit\.ly|tiny\.one|shorturl\.at)/[^\s)」』>]{3,}', '\1/***', 'gi');
  r := regexp_replace(r, '(/)(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{6,}(?=[/?#\s]|$)', '\1***', 'g');
  r := regexp_replace(r, '(?<![가-힣])(?!이용자|구매자|주문자|신청자|방문자|소비자|가입자|구독자|임직원)([김이박최정강조윤장임한오서신권황안송류전홍고문양손배백허유남심노하곽성차주우구민나진지엄채원천방공현함변염여추도소석선설마길연위표명기반왕금옥육인맹제모탁국어은편용예경봉부])[가-힣]([가-힣])(\s?)(고객님|회원님|님)', '\1*\2\3\4', 'g');
  return r;
end;
$function$;
