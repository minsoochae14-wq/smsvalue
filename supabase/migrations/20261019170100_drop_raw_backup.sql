-- 원문 백업 삭제 (실명·계좌 등 개인정보 원본 제거)
-- 앞 마이그레이션에서 기존 글의 링크를 복원한 뒤 실행. 되돌릴 수 없음
drop table private.sms_benefits_raw_backup;
