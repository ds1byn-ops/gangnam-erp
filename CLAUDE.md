# CLAUDE.md — 강남펄스 (Gangnam Pulse)

> 병원 제공용 멀티에이전시 환자·정산 관리 SaaS · 주식회사 팔로우코리아
> 이 파일은 Claude Code 인수인계용. 프로젝트 루트에 두면 자동으로 읽힘.

---

## 1. 프로젝트 정체성

- **강남펄스**: 팔로우코리아가 환자를 송출하는 협력 병원에 제공하는 병원 내부용 시스템.
- 우리 내부 시스템 **펄스(Pulse)** 를 병원 관점으로 재설계한 것.
- 핵심 차이 — 정산 방향이 펄스와 **반대**:
  - 펄스(우리): 1개 에이전시 → 여러 병원에 환자 송출, 수수료 **수취**
  - 강남펄스(병원): 1개 병원 ← 여러 에이전시로부터 환자 유입, 각 에이전시에 수수료 **지급**
- 중심축: **에이전시별 지급 정산 + 시술 원장 + 경영 통계·보고**
- 1차 파일럿 병원: **글로비병원 (GLOVI)**

## 2. 기술 스택 (펄스 계승)

- 프론트: SPA (펄스와 동일 스택 유지 — Vite + React 기준)
- 백엔드: **Supabase** (Postgres · Auth · RLS · Edge Function)
- 배포: **Netlify** 자동 배포 (main push)
- 로그인: Supabase Auth 세션 기반 + **Cloudflare Turnstile** 봇 차단
- ⚠️ **기존 펄스 프로젝트(`tbrtfccvsvtusfkqdyow`)는 절대 건드리지 말 것.** 강남펄스는 완전 별개 프로젝트.

## 3. Supabase 연결 정보

- Project: `gangnam_clinic`
- URL: `https://fhuninzvrkzodhvwkxvo.supabase.co`
- Project ref: `fhuninzvrkzodhvwkxvo`
- Region: `ap-northeast-1` (도쿄)
- Compute: Micro (파일럿엔 충분)
- **스키마·시드 이미 적용 완료** (아래 참조)

`.env` 에 넣을 값 (Supabase 대시보드 → Settings → API 에서 복사):
```
VITE_SUPABASE_URL=https://fhuninzvrkzodhvwkxvo.supabase.co
VITE_SUPABASE_ANON_KEY=<대시보드에서 복사>
VITE_TURNSTILE_SITE_KEY=<Cloudflare에서 발급>
```
> service_role key 는 프론트에 **절대 넣지 말 것.** anon key + RLS 로만 접근.

## 4. 데이터 모델 (이미 배포됨)

**테이블 10개** (모두 `hospital_id` 로 RLS 격리):
`hospitals` · `staff_accounts` · `agencies` · `patients` · `procedures` ·
`treatments` · `commission_rules` · `settlements` · `settlement_items` · `platform_admins`

**뷰 2개**:
- `v_settlement_candidates` — 정산 대상 후보. 시술일 시점 유효 요율을 자동 적용해 **수수료까지 계산됨**. 프론트에서 수수료를 직접 계산하지 말고 이 뷰를 조회할 것.
- `v_settlement_issues` — 정산 오류(유입 미설정 `no_agency` / 요율 미등록 `no_rate` / 보류 `hold`).

**주요 필드 메모**:
- `treatments`: `amount`(결제액) · `refund_amount`(환불) · `is_cancelled`(취소) · `pay_status`(paid/partial/refunded) · `settle_status`(unsettled/pending/hold/paid) · `agency_id`(유입 귀속)
- `commission_rules`: `rate_type`(percent/fixed) · `rate_value` · `valid_from`~`valid_to`(요율 이력)
- `patients.external_chart_no`: 기존 EMR 차트번호 매칭키(선택)
- `procedures.npay_code`: 비급여 보고항목 코드 매핑

## 5. 권한 체계 (role) — '비용 숨김' 필수

`staff_accounts.role`: `owner`(원장) / `manager` / `desk`(데스크) / `viewer`
+ `platform_admins` (팔로우코리아 슈퍼관리자)

- **비용 숨김**: `commission_rules` · `settlements` · `settlement_items` 는 RLS 레벨에서 **owner·manager·플랫폼만** 접근. `desk`·`viewer` 는 수수료 데이터 자체를 못 봄.
- UI 에서도 desk 로그인 시 수수료·지급액 컬럼을 렌더하지 말 것 (이중 안전장치).
- `desk`: 환자·시술 거래 입력 가능. `viewer`: 읽기 전용.

## 6. 시드 데이터 (검증 완료)

- 글로비병원 `hospital_id`: `17339b9d-19e7-4033-8c22-8e81efd6c7ce`
- 팔로우코리아 `agency_id`: `14703e6a-9195-410e-b062-0f434cc0c87c` (`is_followkorea=true`)
- 확정 요율: **피부 20% / 성형 15%** (commission_rules 등록됨)
- 시술 마스터 5종, 검증 거래 3건(王/李/张) 입력됨 → 정산 뷰가 **합계 1,470,000원** 정확히 산출 확인.

## 7. 화면 구현 순서 (사이드바 네비 — 펄스 계승)

1. **로그인** — Supabase Auth 세션 + Turnstile. 로그인 후 role 조회해 메뉴 노출 제어.
2. **시술 거래 원장** — 환자·시술·담당의·금액·유입 에이전시 입력/조회, 결제/정산 상태.
3. **대시보드** — KPI 카드(매출·시술건수·에이전시유입·지급예정) + 매출추이 + 유입경로 도넛 + 에이전시 기여 막대 + 인기시술 + 정산알림 + 정산오류체크(`v_settlement_issues`).
4. **에이전시·정산** — 기간 선택 → `v_settlement_candidates` 로 집계 → `settlements`/`settlement_items` insert + treatments `settle_status` 갱신 → 지급 처리 → 명세 CSV.
5. **통계·보고서** — 유입경로·에이전시 퀄리티(LTV·재방문)·월간 리포트.
6. **설정** — 시술 마스터·요율·직원 계정.
7. **환자 관리** — 목록·이력·전후사진·유입경로.

## 8. 정산 처리 규칙 (엣지케이스)

- 취소(`is_cancelled=true`) → 정산 제외.
- 환불(`refund_amount`) → 정산 전이면 `amount - refund_amount` 로 재산출, 지급 후면 다음 달 (−)차감.
- 보류(`settle_status='hold'`) → 정산에서 일시 제외, 해제 후 재편입.
- 요율은 **시술일 시점**(`valid_from~valid_to`)으로 고정 → 소급 오류 방지 (뷰가 이미 처리).

## 9. 브랜딩

- 네이비 `#1F3864` · 골드 `#C9A24B` · 다크골드(텍스트) `#8A6D2B`
- 폰트: Malgun Gothic
- 로고: GLOVI (가로형 대표). SVG 별도 제공 — 헤더·파비콘에 사용.

## 10. 첫 착수 제안

```
1. Vite + React + supabase-js + (펄스와 동일 CSS 방식) 스캐폴드
2. src/lib/supabase.js — createClient(anon key)
3. 로그인 페이지 + 세션 가드 + role 컨텍스트
4. 사이드바 레이아웃 (7개 메뉴, role 기반 노출)
5. 시술 거래 원장부터 CRUD → 대시보드 → 정산 순
6. Netlify 연결 + main 자동배포
```

> 막히면: 정산·통계는 뷰를 신뢰하고 프론트에서 재계산하지 말 것. 모든 목록은 RLS 가 알아서 병원별 격리하므로 쿼리에 hospital_id 필터를 수동으로 넣지 않아도 됨(단, insert 시 hospital_id 는 명시).
