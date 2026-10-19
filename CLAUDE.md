# 문자혜택 (smsvalue)

사용자가 받은 광고 문자(SMS)를 올리면 AI가 브랜드·혜택·기간을 분류해 공유하는 모바일 웹앱.

- `index.html`: 실제 서비스 페이지 (단일 파일, HTML/CSS/JS 포함)
- `index_15.html`: 예전 버전. 수정하지 말 것
- 백엔드: Supabase (`sms_benefits` 테이블, RPC `upsert_sms_benefit`·`increment_view_count`, Edge Function `hyper-processor`로 AI 분석)
- 코드의 Supabase 키는 공개용 anon 키
- `upsert_sms_benefit`(서버)이 원문을 `mask_pii`로 가리고, 마스킹된 원문의 지문으로 중복을 판단하며, 신뢰도를 `min(AI 점수, 서버 점수)`로 다시 계산해 60점 미만·스미싱 의심·도배(1시간 30건 이상)면 `pending`으로 저장한다. 응답에 `status`와 `duplicate`가 들어 있다.
- DB 변경 SQL은 `supabase/migrations/`, 되돌리기 SQL은 `supabase/rollback/`에 남긴다

## 작업 규칙

### 머지
사용자가 PR 생성부터 `main` 머지까지 맡겼다. 단, 아래 조건을 모두 만족할 때만 머지한다.

1. 변경 사항을 브라우저(Playwright + Chromium)로 실제 화면에서 테스트했다.
   - 로컬 웹서버로 띄울 것 (`file://`은 CORS에 막힘)
   - 목록 로드, 상세 화면, 문자 분석 등 바뀐 기능을 확인
   - 페이지 오류(pageerror)가 없어야 함
2. 테스트가 하나라도 실패하거나 확인하지 못한 부분이 있으면 머지하지 않고 사용자에게 알린다.
3. 머지 후에는 무엇을 바꿨는지, 무엇을 테스트했는지 사용자에게 짧게 알린다.

### 실제 데이터 보호
- 테스트 중에는 실제 DB에 쓰지 않는다. `**/rest/v1/rpc/**` 요청(제출, 조회수 증가)은 차단하고 테스트한다.
- DB 스키마 변경, 데이터 삭제, Supabase 설정 변경은 사용자에게 먼저 묻는다.

### 코드
- 사용자가 입력한 값(문자 원문, 브랜드, 요약 등)을 HTML에 넣을 때는 반드시 `esc()`로 이스케이프한다.
- 기존 코드 스타일(ES5 `var`, 문자열 연결로 HTML 생성)을 따른다.
- 사용자에게는 한국어로, 쉬운 말로 설명한다.
