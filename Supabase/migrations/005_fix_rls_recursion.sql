-- Fix RLS infinite recursion: replace auth.uid() with current_user_id()
--
-- auth.uid() is a security-definer wrapper that internally queries
-- public.users, which has its own RLS policies. The cross-table
-- relationships (room_memberships -> rooms -> users) create an
-- infinite recursion chain. This function reads the JWT claim
-- directly, bypassing the RLS chain entirely.

-- Drop all existing policies on affected tables before recreating.
-- Users
DROP POLICY IF EXISTS "users read own row" ON public.users;
DROP POLICY IF EXISTS "users insert own row" ON public.users;
DROP POLICY IF EXISTS "users update own row" ON public.users;

-- Rooms
DROP POLICY IF EXISTS "creator can read own rooms" ON public.rooms;
DROP POLICY IF EXISTS "creator can insert own rooms" ON public.rooms;
DROP POLICY IF EXISTS "creator can update own rooms" ON public.rooms;
DROP POLICY IF EXISTS "creator can delete own rooms" ON public.rooms;
DROP POLICY IF EXISTS "member sees room" ON public.rooms;

-- Room memberships
DROP POLICY IF EXISTS "user sees own memberships" ON public.room_memberships;
DROP POLICY IF EXISTS "host sees room members" ON public.room_memberships;
DROP POLICY IF EXISTS "no direct inserts" ON public.room_memberships;
DROP POLICY IF EXISTS "user can leave own membership" ON public.room_memberships;
DROP POLICY IF EXISTS "host can remove members" ON public.room_memberships;

-- Helper: read JWT sub claim directly. SECURITY DEFINER + stable
-- means it runs once per statement and bypasses RLS on users.
CREATE OR REPLACE FUNCTION public.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT NULLIF(current_setting('request.jwt.claims', true)::json->>'sub', '')::uuid;
$$;

-- ── users ──────────────────────────────────────────────────────
CREATE POLICY "users read own row" ON public.users
  FOR SELECT USING (current_user_id() = id);

CREATE POLICY "users insert own row" ON public.users
  FOR INSERT WITH CHECK (current_user_id() = id);

CREATE POLICY "users update own row" ON public.users
  FOR UPDATE USING (current_user_id() = id);

-- ── rooms ──────────────────────────────────────────────────────
CREATE POLICY "creator can read own rooms" ON public.rooms
  FOR SELECT USING (current_user_id() = created_by);

CREATE POLICY "creator can insert own rooms" ON public.rooms
  FOR INSERT WITH CHECK (current_user_id() = created_by);

CREATE POLICY "creator can update own rooms" ON public.rooms
  FOR UPDATE USING (current_user_id() = created_by);

CREATE POLICY "creator can delete own rooms" ON public.rooms
  FOR DELETE USING (current_user_id() = created_by);

CREATE POLICY "member sees room" ON public.rooms
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.room_memberships m
      WHERE m.room_id = rooms.id
        AND m.user_id = current_user_id()
    )
  );

-- ── room_memberships ───────────────────────────────────────────
CREATE POLICY "user sees own memberships" ON public.room_memberships
  FOR SELECT USING (current_user_id() = user_id);

CREATE POLICY "host sees room members" ON public.room_memberships
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.rooms r
      WHERE r.id = room_memberships.room_id
        AND r.created_by = current_user_id()
    )
  );

CREATE POLICY "no direct inserts" ON public.room_memberships
  FOR INSERT WITH CHECK (false);

CREATE POLICY "user can leave own membership" ON public.room_memberships
  FOR DELETE USING (current_user_id() = user_id);

CREATE POLICY "host can remove members" ON public.room_memberships
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM public.rooms r
      WHERE r.id = room_memberships.room_id
        AND r.created_by = current_user_id()
    )
  );
