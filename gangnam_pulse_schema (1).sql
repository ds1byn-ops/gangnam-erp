-- =====================================================================
--  강남펄스 (Gangnam Pulse) — Supabase 스키마 v1.0
--  병원 제공용 멀티에이전시 환자·정산 관리 SaaS
--  주식회사 팔로우코리아 · 2026.07
--
--  구성: 10개 테이블(9 핵심 + platform_admins) · 멀티테넌트 RLS
--       · 정산 계산/오류 뷰 · '비용 숨김' 권한(desk 수수료 차단)
--  적용: 신규 Supabase 프로젝트의 SQL Editor 또는 apply_migration
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. 상태 값 규약 (영문 코드 · 한글 라벨은 프론트에서 매핑)
--    role         : owner(원장) manager desk(데스크) viewer
--    pay_status   : paid(완료) partial(부분) refunded(환불)
--    settle_status: unsettled(미정산) pending(정산대기) hold(보류) paid(지급완료)
--    rate_type    : percent(정률) fixed(정액)
--    settlement.status : unpaid(미지급) scheduled(지급예정) paid(지급완료)
-- ---------------------------------------------------------------------

create extension if not exists pgcrypto;

-- =====================================================================
-- 1. 플랫폼 운영자 (팔로우코리아 · 슈퍼관리자)
-- =====================================================================
create table platform_admins (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text,
  created_at  timestamptz not null default now()
);

-- =====================================================================
-- 2. 병원 (테넌트)
-- =====================================================================
create table hospitals (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  biz_no      text,
  plan_tier   text not null default 'basic' check (plan_tier in ('basic','pro')),
  status      text not null default 'trial'  check (status in ('active','paused','trial')),
  contact     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- =====================================================================
-- 3. 직원 계정 (Supabase Auth 연동)
-- =====================================================================
create table staff_accounts (
  id          uuid primary key references auth.users(id) on delete cascade,
  hospital_id uuid not null references hospitals(id) on delete cascade,
  name        text not null,
  role        text not null default 'desk' check (role in ('owner','manager','desk','viewer')),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index idx_staff_hospital on staff_accounts(hospital_id);

-- =====================================================================
-- 4. 거래 에이전시 (수수료 지급 대상)
-- =====================================================================
create table agencies (
  id             uuid primary key default gen_random_uuid(),
  hospital_id    uuid not null references hospitals(id) on delete cascade,
  name           text not null,
  is_followkorea boolean not null default false,
  payout_method  jsonb not null default '{}'::jsonb,
  memo           text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_agencies_hospital on agencies(hospital_id);

-- =====================================================================
-- 5. 환자 (+ 유입경로 · 기존 EMR 매칭키)
-- =====================================================================
create table patients (
  id                uuid primary key default gen_random_uuid(),
  hospital_id       uuid not null references hospitals(id) on delete cascade,
  name              text not null,
  nationality       text,
  source_agency_id  uuid references agencies(id) on delete set null,
  source_channel    text,
  contact           jsonb not null default '{}'::jsonb,
  first_visit       date,
  external_chart_no text,               -- 기존 EMR 차트번호 매칭키 (선택)
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index idx_patients_hospital on patients(hospital_id);
create index idx_patients_source   on patients(hospital_id, source_agency_id);

-- =====================================================================
-- 6. 시술 마스터
-- =====================================================================
create table procedures (
  id          uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references hospitals(id) on delete cascade,
  name        text not null,
  category    text,                     -- 피부 / 성형 등 (요율 매칭 기준)
  price       numeric(12,0) not null default 0,
  is_covered  boolean not null default false,
  npay_code   text,                     -- 비급여 보고항목 코드 매핑
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index idx_procedures_hospital on procedures(hospital_id);

-- =====================================================================
-- 7. 시술 거래 원장 (핵심)
-- =====================================================================
create table treatments (
  id            uuid primary key default gen_random_uuid(),
  hospital_id   uuid not null references hospitals(id) on delete cascade,
  patient_id    uuid not null references patients(id) on delete restrict,
  procedure_id  uuid not null references procedures(id) on delete restrict,
  agency_id     uuid references agencies(id) on delete set null,  -- 유입 귀속(정산 대상)
  doctor        text,
  treated_at    timestamptz not null default now(),
  amount        numeric(12,0) not null default 0,
  refund_amount numeric(12,0) not null default 0,                 -- 환불 금액 (정산 차감)
  is_cancelled  boolean not null default false,                   -- 취소 → 정산 제외
  pay_status    text not null default 'paid'
                  check (pay_status in ('paid','partial','refunded')),
  settle_status text not null default 'unsettled'
                  check (settle_status in ('unsettled','pending','hold','paid')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index idx_treat_hospital_date on treatments(hospital_id, treated_at);
create index idx_treat_agency_settle on treatments(hospital_id, agency_id, settle_status);
create index idx_treat_patient       on treatments(patient_id);

-- =====================================================================
-- 8. 에이전시별 수수료율 (요율 이력: valid_from ~ valid_to)
-- =====================================================================
create table commission_rules (
  id          uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references hospitals(id) on delete cascade,
  agency_id   uuid not null references agencies(id) on delete cascade,
  category    text,                     -- null이면 전체 시술 적용
  rate_type   text not null default 'percent' check (rate_type in ('percent','fixed')),
  rate_value  numeric(12,2) not null,   -- percent: %  /  fixed: 원
  valid_from  date not null default current_date,
  valid_to    date,                     -- null이면 현재 유효
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index idx_rules_lookup on commission_rules(hospital_id, agency_id, category, valid_from);

-- =====================================================================
-- 9. 정산 (에이전시 지급 단위)
-- =====================================================================
create table settlements (
  id           uuid primary key default gen_random_uuid(),
  hospital_id  uuid not null references hospitals(id) on delete cascade,
  agency_id    uuid not null references agencies(id) on delete restrict,
  period       text not null,            -- 예: '2026-07'
  total_amount numeric(12,0) not null default 0,
  pay_method   text,
  status       text not null default 'unpaid'
                 check (status in ('unpaid','scheduled','paid')),
  paid_at      date,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index idx_settle_lookup on settlements(hospital_id, agency_id, period);

-- =====================================================================
-- 10. 정산 상세 (정산 ↔ 거래 연결) — hospital_id 비정규화(RLS·인덱스용)
-- =====================================================================
create table settlement_items (
  id            uuid primary key default gen_random_uuid(),
  hospital_id   uuid not null references hospitals(id) on delete cascade,
  settlement_id uuid not null references settlements(id) on delete cascade,
  treatment_id  uuid not null references treatments(id) on delete restrict,
  base_amount   numeric(12,0) not null default 0,   -- 정산 기준액 (amount - refund)
  commission    numeric(12,0) not null default 0,   -- 산출 수수료
  created_at    timestamptz not null default now()
);
create index idx_items_settlement on settlement_items(settlement_id);
create index idx_items_treatment  on settlement_items(treatment_id);

-- =====================================================================
-- 11. updated_at 자동 갱신 트리거
-- =====================================================================
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'hospitals','staff_accounts','agencies','patients','procedures',
    'treatments','commission_rules','settlements'
  ] loop
    execute format(
      'create trigger trg_%1$s_updated before update on %1$s
         for each row execute function set_updated_at()', t);
  end loop;
end $$;

-- =====================================================================
-- 12. 인증·권한 헬퍼 함수
-- =====================================================================
create or replace function current_hospital_id()
returns uuid language sql stable security definer set search_path = public as $$
  select hospital_id from staff_accounts where id = auth.uid() and is_active limit 1;
$$;

create or replace function current_staff_role()
returns text language sql stable security definer set search_path = public as $$
  select role from staff_accounts where id = auth.uid() and is_active limit 1;
$$;

create or replace function is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where id = auth.uid());
$$;

-- 자기 병원 소속 여부
create or replace function in_my_hospital(h uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select is_platform_admin() or h = current_hospital_id();
$$;

-- =====================================================================
-- 13. RLS 활성화
-- =====================================================================
alter table platform_admins  enable row level security;
alter table hospitals        enable row level security;
alter table staff_accounts   enable row level security;
alter table agencies         enable row level security;
alter table patients         enable row level security;
alter table procedures       enable row level security;
alter table treatments       enable row level security;
alter table commission_rules enable row level security;
alter table settlements      enable row level security;
alter table settlement_items enable row level security;

-- platform_admins: 본인 레코드만 조회 (관리는 서비스롤)
create policy pa_self on platform_admins for select
  using (id = auth.uid());

-- hospitals: 자기 병원만 조회 / 생성·수정은 플랫폼 운영자
create policy hosp_sel on hospitals for select using (in_my_hospital(id));
create policy hosp_all on hospitals for all
  using (is_platform_admin()) with check (is_platform_admin());

-- staff_accounts: 자기 병원 조회 / 계정관리는 owner·플랫폼
create policy staff_sel on staff_accounts for select using (in_my_hospital(hospital_id));
create policy staff_wr  on staff_accounts for all
  using (is_platform_admin() or (hospital_id = current_hospital_id() and current_staff_role() = 'owner'))
  with check (is_platform_admin() or (hospital_id = current_hospital_id() and current_staff_role() = 'owner'));

-- 일반 업무 테이블: 자기 병원 조회 / write는 viewer 제외
-- agencies
create policy ag_sel on agencies for select using (in_my_hospital(hospital_id));
create policy ag_wr  on agencies for all
  using (in_my_hospital(hospital_id) and current_staff_role() in ('owner','manager'))
  with check (in_my_hospital(hospital_id) and current_staff_role() in ('owner','manager'));

-- patients (desk도 입력 가능)
create policy pt_sel on patients for select using (in_my_hospital(hospital_id));
create policy pt_wr  on patients for all
  using (in_my_hospital(hospital_id) and current_staff_role() in ('owner','manager','desk'))
  with check (in_my_hospital(hospital_id) and current_staff_role() in ('owner','manager','desk'));

-- procedures (마스터 관리는 owner·manager)
create policy pr_sel on procedures for select using (in_my_hospital(hospital_id));
create policy pr_wr  on procedures for all
  using (in_my_hospital(hospital_id) and current_staff_role() in ('owner','manager'))
  with check (in_my_hospital(hospital_id) and current_staff_role() in ('owner','manager'));

-- treatments (desk 입력 가능)
create policy tr_sel on treatments for select using (in_my_hospital(hospital_id));
create policy tr_wr  on treatments for all
  using (in_my_hospital(hospital_id) and current_staff_role() in ('owner','manager','desk'))
  with check (in_my_hospital(hospital_id) and current_staff_role() in ('owner','manager','desk'));

-- === '비용 숨김' 민감 테이블: owner·manager·플랫폼만 접근 (desk·viewer 차단) ===
-- commission_rules
create policy cr_sel on commission_rules for select
  using (in_my_hospital(hospital_id) and (is_platform_admin() or current_staff_role() in ('owner','manager')));
create policy cr_wr on commission_rules for all
  using (in_my_hospital(hospital_id) and (is_platform_admin() or current_staff_role() in ('owner','manager')))
  with check (in_my_hospital(hospital_id) and (is_platform_admin() or current_staff_role() in ('owner','manager')));

-- settlements
create policy st_sel on settlements for select
  using (in_my_hospital(hospital_id) and (is_platform_admin() or current_staff_role() in ('owner','manager')));
create policy st_wr on settlements for all
  using (in_my_hospital(hospital_id) and (is_platform_admin() or current_staff_role() in ('owner','manager')))
  with check (in_my_hospital(hospital_id) and (is_platform_admin() or current_staff_role() in ('owner','manager')));

-- settlement_items
create policy si_sel on settlement_items for select
  using (in_my_hospital(hospital_id) and (is_platform_admin() or current_staff_role() in ('owner','manager')));
create policy si_wr on settlement_items for all
  using (in_my_hospital(hospital_id) and (is_platform_admin() or current_staff_role() in ('owner','manager')))
  with check (in_my_hospital(hospital_id) and (is_platform_admin() or current_staff_role() in ('owner','manager')));

-- =====================================================================
-- 14. 정산 계산 뷰 — 정산 대상 후보 (시술일 시점 유효 요율 적용)
--     결제완료 · 미취소 · 미정산 · 유입 에이전시 존재 거래
-- =====================================================================
create or replace view v_settlement_candidates
with (security_invoker = true) as
select
  t.id            as treatment_id,
  t.hospital_id,
  t.agency_id,
  t.patient_id,
  t.treated_at,
  p.category,
  (t.amount - t.refund_amount)              as base_amount,
  cr.rate_type,
  cr.rate_value,
  case
    when cr.rate_type = 'percent'
      then round((t.amount - t.refund_amount) * cr.rate_value / 100)
    when cr.rate_type = 'fixed'
      then cr.rate_value
    else 0
  end                                        as commission
from treatments t
join procedures p on p.id = t.procedure_id
left join lateral (
  select c.rate_type, c.rate_value
  from commission_rules c
  where c.hospital_id = t.hospital_id
    and c.agency_id   = t.agency_id
    and (c.category is null or c.category = p.category)
    and c.valid_from <= t.treated_at::date
    and (c.valid_to is null or c.valid_to >= t.treated_at::date)
  order by (c.category is not null) desc, c.valid_from desc   -- 카테고리 지정 요율 우선, 최신순
  limit 1
) cr on true
where t.pay_status = 'paid'
  and t.is_cancelled = false
  and t.settle_status = 'unsettled'
  and t.agency_id is not null;

-- =====================================================================
-- 15. 정산 오류 체크 뷰 (정산 전 데이터 검증)
--     issue_type: no_agency(유입 미설정) / no_rate(요율 미등록) / hold(보류)
-- =====================================================================
create or replace view v_settlement_issues
with (security_invoker = true) as
-- 유입 에이전시 미설정
select t.id as treatment_id, t.hospital_id, 'no_agency'::text as issue_type,
       t.treated_at, t.amount
from treatments t
where t.pay_status = 'paid' and t.is_cancelled = false
  and t.settle_status = 'unsettled' and t.agency_id is null
union all
-- 요율 미등록 (에이전시는 있으나 유효 요율 없음)
select t.id, t.hospital_id, 'no_rate', t.treated_at, t.amount
from treatments t
join procedures p on p.id = t.procedure_id
where t.pay_status = 'paid' and t.is_cancelled = false
  and t.settle_status = 'unsettled' and t.agency_id is not null
  and not exists (
    select 1 from commission_rules c
    where c.hospital_id = t.hospital_id and c.agency_id = t.agency_id
      and (c.category is null or c.category = p.category)
      and c.valid_from <= t.treated_at::date
      and (c.valid_to is null or c.valid_to >= t.treated_at::date)
  )
union all
-- 보류(Hold) 거래
select t.id, t.hospital_id, 'hold', t.treated_at, t.amount
from treatments t
where t.settle_status = 'hold';

-- =====================================================================
-- 16. (옵션) 파일럿 시드 예시 — 실제 auth 계정 생성 후 주석 해제하여 사용
-- ---------------------------------------------------------------------
-- insert into hospitals (name, biz_no, plan_tier, status)
--   values ('글로비병원', '000-00-00000', 'pro', 'active');
--
-- -- 팔로우코리아 에이전시 등록 (위 hospital id 사용)
-- insert into agencies (hospital_id, name, is_followkorea)
--   values ('<glovi_hospital_id>', '팔로우코리아', true);
--
-- -- 확정 요율: 피부 20% / 성형 15%
-- insert into commission_rules (hospital_id, agency_id, category, rate_type, rate_value)
--   values
--   ('<glovi_hospital_id>', '<followkorea_agency_id>', '피부', 'percent', 20),
--   ('<glovi_hospital_id>', '<followkorea_agency_id>', '성형', 'percent', 15);
-- =====================================================================

-- end of schema
