-- ================================================================
--  FIT HOUSE — SUPABASE SETUP COMPLETO
--  Ejecuta este script en el SQL Editor de tu proyecto Supabase
--  ( https://app.supabase.com → proyecto → SQL Editor → New Query )
-- ================================================================


-- ----------------------------------------------------------------
-- 1. TABLA: miembros_gym
--    Almacena el perfil de membresía de cada usuario.
--    La columna `id` es una FK hacia auth.users (Supabase Auth).
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.miembros_gym (
  id                   UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre               TEXT        NOT NULL,
  correo               TEXT        NOT NULL UNIQUE,
  fecha_pago           DATE,                          -- último pago registrado
  fecha_vencimiento    DATE,                          -- hasta cuándo está activa la membresía
  estado_suscripcion   TEXT        NOT NULL DEFAULT 'inactivo'
                       CHECK (estado_suscripcion IN ('activo', 'inactivo', 'suspendido')),
  rol                  TEXT        NOT NULL DEFAULT 'cliente'
                       CHECK (rol IN ('cliente', 'admin')),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índice de búsqueda rápida por correo y nombre (para el buscador del admin)
CREATE INDEX IF NOT EXISTS idx_miembros_correo ON public.miembros_gym (correo);
CREATE INDEX IF NOT EXISTS idx_miembros_nombre ON public.miembros_gym USING GIN (to_tsvector('spanish', nombre));


-- ----------------------------------------------------------------
-- 2. TABLA: asistencias_gym
--    Registra cada entrada al gimnasio validada por el escáner QR.
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.asistencias_gym (
  id           BIGSERIAL   PRIMARY KEY,
  id_usuario   UUID        NOT NULL REFERENCES public.miembros_gym(id) ON DELETE CASCADE,
  fecha        DATE        NOT NULL DEFAULT CURRENT_DATE,
  hora_entrada TIME        NOT NULL DEFAULT CURRENT_TIME,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índice compuesto para la query de "ya ingresó hoy" (crítica en el escáner)
CREATE INDEX IF NOT EXISTS idx_asistencias_usuario_fecha
  ON public.asistencias_gym (id_usuario, fecha);

-- Índice temporal para el medidor de aforo (últimas 2 horas)
CREATE INDEX IF NOT EXISTS idx_asistencias_created
  ON public.asistencias_gym (created_at DESC);


-- ================================================================
-- 3. ROW LEVEL SECURITY (RLS)
--    Regla de oro: el cliente solo puede LEER su propio perfil.
--    Solo el admin (via service_role o función SECURITY DEFINER)
--    puede escribir en miembros_gym.
-- ================================================================

-- Activar RLS en ambas tablas
ALTER TABLE public.miembros_gym    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asistencias_gym ENABLE ROW LEVEL SECURITY;


-- ── POLÍTICAS PARA miembros_gym ──────────────────────────────────

-- El cliente puede ver SOLO su propio registro
CREATE POLICY "cliente_ver_propio_perfil"
  ON public.miembros_gym
  FOR SELECT
  USING ( auth.uid() = id );

-- El admin puede ver TODOS los registros
CREATE POLICY "admin_ver_todos"
  ON public.miembros_gym
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.miembros_gym m
      WHERE m.id = auth.uid() AND m.rol = 'admin'
    )
  );

-- NADIE puede hacer UPDATE/DELETE directo desde el cliente.
-- Las renovaciones usan una función SECURITY DEFINER (ver abajo).
-- El INSERT lo hace el trigger after_auth_user_created (ver abajo).


-- ── POLÍTICAS PARA asistencias_gym ──────────────────────────────

-- El cliente ve solo sus propias asistencias
CREATE POLICY "cliente_ver_propias_asistencias"
  ON public.asistencias_gym
  FOR SELECT
  USING ( auth.uid() = id_usuario );

-- El admin ve todas las asistencias
CREATE POLICY "admin_ver_todas_asistencias"
  ON public.asistencias_gym
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.miembros_gym m
      WHERE m.id = auth.uid() AND m.rol = 'admin'
    )
  );

-- INSERT solo permitido desde funciones SECURITY DEFINER (escáner)
-- Ningún cliente puede insertarse asistencias manualmente.


-- ================================================================
-- 4. FUNCIONES SEGURAS (SECURITY DEFINER)
--    Corren con permisos de admin, no del usuario que las invoca.
--    Son el único canal para mutar datos sensibles desde el frontend.
-- ================================================================

-- ── 4a. Renovar membresía ────────────────────────────────────────
--    Llama: rpc('renovar_membresia', { p_user_id, p_dias_plan })
--    Solo puede ser llamada si el caller es admin (se verifica dentro).
CREATE OR REPLACE FUNCTION public.renovar_membresia(
  p_user_id   UUID,
  p_dias_plan INT         -- 1, 30, 90 ó 180
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_rol TEXT;
  v_nueva_fecha DATE;
BEGIN
  -- Verificar que quien llama la función sea admin
  SELECT rol INTO v_caller_rol
  FROM public.miembros_gym
  WHERE id = auth.uid();

  IF v_caller_rol <> 'admin' THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;

  -- Calcular nueva fecha de vencimiento:
  -- Si ya tiene fecha futura, extender desde ahí; si no, desde hoy.
  SELECT GREATEST(COALESCE(fecha_vencimiento, CURRENT_DATE), CURRENT_DATE) + p_dias_plan
  INTO v_nueva_fecha
  FROM public.miembros_gym
  WHERE id = p_user_id;

  -- Aplicar la actualización
  UPDATE public.miembros_gym
  SET
    fecha_pago          = CURRENT_DATE,
    fecha_vencimiento   = v_nueva_fecha,
    estado_suscripcion  = 'activo'
  WHERE id = p_user_id;

  RETURN json_build_object('ok', true, 'nueva_fecha_vencimiento', v_nueva_fecha);
END;
$$;


-- ── 4b. Registrar asistencia (escáner QR) ───────────────────────
--    Llama: rpc('registrar_asistencia', { p_user_id })
--    Valida membresía activa + unicidad diaria antes de insertar.
CREATE OR REPLACE FUNCTION public.registrar_asistencia(
  p_user_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_estado  TEXT;
  v_vence   DATE;
  v_ya_hoy  BOOLEAN;
BEGIN
  -- 1. Verificar que el miembro existe y está activo
  SELECT estado_suscripcion, fecha_vencimiento
  INTO v_estado, v_vence
  FROM public.miembros_gym
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Usuario no encontrado');
  END IF;

  IF v_estado <> 'activo' OR v_vence < CURRENT_DATE THEN
    RETURN json_build_object('ok', false, 'error', 'Membresía vencida o inactiva');
  END IF;

  -- 2. Verificar que no haya ingresado hoy
  SELECT EXISTS (
    SELECT 1 FROM public.asistencias_gym
    WHERE id_usuario = p_user_id AND fecha = CURRENT_DATE
  ) INTO v_ya_hoy;

  IF v_ya_hoy THEN
    RETURN json_build_object('ok', false, 'error', 'El usuario ya ingresó hoy');
  END IF;

  -- 3. Registrar la asistencia
  INSERT INTO public.asistencias_gym (id_usuario, fecha, hora_entrada)
  VALUES (p_user_id, CURRENT_DATE, CURRENT_TIME);

  RETURN json_build_object('ok', true, 'mensaje', 'Acceso concedido. ¡Buena sesión!');
END;
$$;


-- ── 4c. Aforo en vivo (últimas 2 horas) ─────────────────────────
--    Devuelve el conteo de asistencias registradas en las últimas 2h.
--    Puede ser llamada por cualquier usuario autenticado.
CREATE OR REPLACE FUNCTION public.get_aforo_actual()
RETURNS INT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::INT
  FROM public.asistencias_gym
  WHERE created_at >= NOW() - INTERVAL '2 hours';
$$;


-- ── 4d. Stats del atleta (mes en curso) ─────────────────────────
--    El cliente llama: rpc('get_mis_stats')
CREATE OR REPLACE FUNCTION public.get_mis_stats()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dias_mes      INT;
  v_racha         INT;
  v_ultima_visita DATE;
BEGIN
  -- Total de días asistidos en el mes actual
  SELECT COUNT(*) INTO v_dias_mes
  FROM public.asistencias_gym
  WHERE id_usuario = auth.uid()
    AND DATE_TRUNC('month', fecha) = DATE_TRUNC('month', CURRENT_DATE);

  -- Última visita
  SELECT MAX(fecha) INTO v_ultima_visita
  FROM public.asistencias_gym
  WHERE id_usuario = auth.uid();

  RETURN json_build_object(
    'dias_mes',      v_dias_mes,
    'ultima_visita', v_ultima_visita
  );
END;
$$;


-- ================================================================
-- 5. TRIGGER: crear fila en miembros_gym al registrar usuario
--    Se dispara cuando Supabase Auth crea un nuevo auth.user.
--    Toma nombre y correo de los metadatos del invite.
-- ================================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.miembros_gym (id, nombre, correo, rol)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'nombre', 'Sin nombre'),
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'rol', 'cliente')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- Vincular el trigger al evento de nuevo usuario en auth
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ================================================================
-- 6. CREAR EL PRIMER ADMIN MANUALMENTE
--    Después de correr este SQL, crea el usuario admin desde
--    Supabase Auth → Users → "Invite user" con el correo del admin.
--    Luego ejecuta esto para darle rol admin:
-- ================================================================
-- UPDATE public.miembros_gym
-- SET rol = 'admin'
-- WHERE correo = 'admin@fithouse.mx';   -- <-- cambia este correo


-- ================================================================
-- 7. CONFIGURACIÓN DE EMAIL AUTH EN SUPABASE CONSOLE
-- ================================================================
/*
  PASO A: Plantilla de Invitación (Invite User)
  ─────────────────────────────────────────────
  Ve a: Authentication → Email Templates → Invite user
  
  Subject:
    Bienvenido a Fit House — Configura tu acceso
  
  Body (HTML):
  ┌─────────────────────────────────────────────────────────┐
  │ <div style="background:#0A0A0A;padding:40px;font-family:│
  │ sans-serif;color:#E8E8E8;max-width:480px;margin:auto">  │
  │   <h1 style="color:#FF5722;letter-spacing:4px;          │
  │   font-size:28px">FIT HOUSE</h1>                        │
  │   <p style="font-size:16px;line-height:1.6">            │
  │   Hola {{ .Name }},<br><br>                             │
  │   Tu acceso al gimnasio ha sido creado.<br>             │
  │   Haz clic abajo para configurar tu contraseña          │
  │   y acceder a tu perfil de atleta.</p>                  │
  │   <a href="{{ .ConfirmationURL }}"                      │
  │   style="display:inline-block;background:#FF5722;       │
  │   color:#fff;padding:14px 32px;border-radius:4px;       │
  │   font-weight:700;text-decoration:none;                 │
  │   letter-spacing:2px;margin-top:24px">                  │
  │   ACTIVAR MI CUENTA →</a>                               │
  │   <p style="color:#666;font-size:12px;margin-top:32px"> │
  │   Este enlace expira en 24 horas.</p>                   │
  │ </div>                                                  │
  └─────────────────────────────────────────────────────────┘

  PASO B: URL de redirección post-invitación
  ─────────────────────────────────────────────
  En Authentication → URL Configuration → Redirect URLs
  Agrega: https://TU_DOMINIO.com/app.html
  (o http://localhost:5500/app.html para desarrollo local)

  PASO C: Desactivar "Confirm email" para nuevos signups normales
  ─────────────────────────────────────────────
  Authentication → Providers → Email
  Apaga "Confirm email" (el flujo de invite ya lo maneja).

  PASO D: SMTP personalizado (para emails con dominio propio)
  ─────────────────────────────────────────────
  Project Settings → Auth → SMTP Settings
  Configura con tu proveedor (SendGrid, Resend, etc.)
  para que los correos lleguen desde contacto@fithouse.mx
*/
