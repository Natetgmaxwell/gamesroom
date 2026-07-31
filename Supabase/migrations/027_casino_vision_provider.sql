-- 027: Casino pack — per-room vision provider config.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/027_casino_vision_provider.sql
--
-- Extends casino_room_config with the vision provider choice. v1 ships two:
--   - 'on_device' (default): VNDetectRectanglesRequest + hue heuristic. No
--     network, no key. Cheap, low accuracy.
--   - 'minimax_vision': POST the captured JPEG to api.minimax.io/v1/chat/completions
--     with a one-shot prompt; the API key travels in the Authorization header.
--     Higher accuracy at the cost of latency and a per-photo API call.
--
-- Plaintext key storage matches the existing mascot_api_key pattern (encryption
-- is v0.10+ work). The key is per-room, so a different room can use a different
-- provider / model without touching the global config.

-- 1. Extend casino_room_config.
alter table public.casino_room_config
  add column if not exists vision_provider text not null default 'on_device',
  add column if not exists vision_model text,
  add column if not exists vision_api_key text;

-- Cheap constraint: provider must be one of the known values, or NULL.
alter table public.casino_room_config
  drop constraint if exists casino_room_config_vision_provider_check;
alter table public.casino_room_config
  add constraint casino_room_config_vision_provider_check
    check (vision_provider in ('on_device', 'minimax_vision'));

-- 2. update upsert_casino_config: round-trip the new fields. Signature is
--    additive — old callers keep working because the new parameters default.
create or replace function public.upsert_casino_config(
  p_room_id uuid,
  p_enabled boolean,
  p_chip_color_map jsonb default '{}'::jsonb,
  p_standard_presets boolean default true,
  p_vision_provider text default 'on_device',
  p_vision_model text default null,
  p_vision_api_key text default null
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms where id = p_room_id and created_by = v_caller) then
    raise exception 'Only the host can configure casino' using errcode = '42501';
  end if;

  if p_vision_provider not in ('on_device', 'minimax_vision') then
    raise exception 'Unknown vision provider: %', p_vision_provider using errcode = '23514';
  end if;

  insert into public.casino_room_config (
    room_id, enabled, chip_color_map, standard_presets,
    vision_provider, vision_model, vision_api_key
  )
  values (
    p_room_id, p_enabled, p_chip_color_map, p_standard_presets,
    p_vision_provider, p_vision_model, p_vision_api_key
  )
  on conflict (room_id) do update
    set enabled = excluded.enabled,
        chip_color_map = excluded.chip_color_map,
        standard_presets = excluded.standard_presets,
        vision_provider = excluded.vision_provider,
        vision_model = excluded.vision_model,
        vision_api_key = excluded.vision_api_key,
        updated_at = now();

  return true;
end;
$$;

grant execute on function public.upsert_casino_config(
  uuid, boolean, jsonb, boolean, text, text, text
) to authenticated;

-- 3. update get_casino_config to return the new columns. DROP + CREATE because
--    RETURNS TABLE column list changed (Postgres 42P13).
drop function if exists public.get_casino_config(uuid);
create function public.get_casino_config(p_room_id uuid)
returns table (
  room_id uuid,
  enabled boolean,
  chip_color_map jsonb,
  standard_presets boolean,
  vision_provider text,
  vision_model text,
  vision_api_key text
)
language sql
security definer
stable
as $$
  select
    crc.room_id, crc.enabled, crc.chip_color_map, crc.standard_presets,
    crc.vision_provider, crc.vision_model, crc.vision_api_key
  from public.casino_room_config crc
  where crc.room_id = p_room_id;
$$;

grant execute on function public.get_casino_config(uuid) to authenticated;
