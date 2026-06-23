# FIT HOUSE — Sistema SaaS de Membresías

## Estructura del proyecto

```
fithouse-saas/
├── 00_SUPABASE_SETUP.sql          ← Ejecutar primero en SQL Editor
├── README.md                       ← Esta guía
├── css/
│   └── tokens.css                  ← Design tokens globales
├── js/
│   └── supabase-client.js          ← Cliente compartido + utilidades
├── pages/
│   ├── login.html                  ← Pantalla de inicio de sesión
│   ├── app.html                    ← Perfil del atleta + QR + Aforo
│   ├── scanner.html                ← Escáner QR de la entrada
│   └── admin.html                  ← Panel de administración
└── supabase/
    └── functions/
        └── invite-user/
            └── index.ts            ← Edge Function para invitaciones
```

---

## PASO 1 — Crear proyecto en Supabase

1. Ve a https://app.supabase.com → **New Project**
2. Elige región, nombre de DB y contraseña fuerte
3. Espera ~2 min hasta que el proyecto esté listo

---

## PASO 2 — Ejecutar el SQL de setup

1. Abre tu proyecto → **SQL Editor** → **New Query**
2. Pega y ejecuta todo el contenido de `00_SUPABASE_SETUP.sql`
3. Verifica que las tablas `miembros_gym` y `asistencias_gym` aparezcan en **Table Editor**

---

## PASO 3 — Conectar las credenciales en el frontend

Abre `js/supabase-client.js` y reemplaza las dos constantes:

```js
const SUPABASE_URL  = 'https://TU_PROJECT_ID.supabase.co';
const SUPABASE_ANON = 'TU_ANON_PUBLIC_KEY';
```

Encuéntralas en: **Project Settings → API → Project URL y anon key**

> ⚠️ La `service_role` key **nunca** va en el frontend. Solo en la Edge Function.

---

## PASO 4 — Configurar el email de invitación

1. **Authentication → Email Templates → Invite user**
   - Pega el HTML del template que está comentado en `00_SUPABASE_SETUP.sql`
   
2. **Authentication → URL Configuration → Redirect URLs**
   - Agrega: `https://TU_DOMINIO.com/pages/app.html`
   - Para local: `http://localhost:5500/pages/app.html`

3. (Opcional) **Project Settings → Auth → SMTP**
   - Configura SendGrid o Resend para emails con tu dominio personalizado

---

## PASO 5 — Crear el primer admin

1. Ve a **Authentication → Users → Invite** e invita el correo del admin
2. Abre **SQL Editor** y ejecuta:
   ```sql
   UPDATE public.miembros_gym
   SET rol = 'admin'
   WHERE correo = 'admin@fithouse.mx';
   ```

---

## PASO 6 — Desplegar la Edge Function

Instala Supabase CLI:
```bash
npm install -g supabase
supabase login
```

Inicializa y despliega:
```bash
supabase init
supabase link --project-ref TU_PROJECT_ID
supabase functions deploy invite-user --no-verify-jwt
```

Agrega los secrets de la función en Supabase:
```bash
supabase secrets set SITE_URL=https://TU_DOMINIO.com
# SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY se inyectan automáticamente
```

---

## PASO 7 — Configurar el número de WhatsApp

En `pages/login.html`, `pages/app.html` y `index.html`, busca:
```
wa.me/TU_NUMERO
```
y reemplaza con tu número en formato internacional sin +: `5215512345678`

---

## Flujo completo del sistema

```
[Recepcionista] → admin.html
  → Busca atleta / Registra nuevo → inviteUserByEmail (Edge Fn)
                                       ↓ email automático
  → Atleta recibe link → crea contraseña → login.html

[Atleta] → login.html → app.html
  ✓ Membresía activa → QR dinámico (expira cada 30s)
  ✗ Vencida          → Pantalla de bloqueo

[Entrada del gym] → scanner.html
  → Lee QR → validarPayloadQR() → rpc('registrar_asistencia')
     ✓ Todo ok        → Acceso concedido + INSERT asistencia
     ✗ Ya ingresó hoy → Denegado
     ✗ Vencido        → Denegado
```

---

## Seguridad implementada

| Capa | Mecanismo |
|------|-----------|
| Autenticación | Supabase Auth (JWT) |
| Datos sensibles | RLS: cliente solo lee su fila |
| Renovación | SECURITY DEFINER fn — solo admin puede llamarla |
| Asistencias | SECURITY DEFINER fn — el cliente no puede auto-insertarse |
| Invitaciones | Edge Function con SERVICE_ROLE (nunca expuesta) |
| QR anti-fraude | Payload firmado + ventana temporal de 30s |

---

## Variables de entorno a cambiar antes de producción

| Archivo | Variable | Descripción |
|---------|----------|-------------|
| `js/supabase-client.js` | `SUPABASE_URL` | URL de tu proyecto |
| `js/supabase-client.js` | `SUPABASE_ANON` | Anon public key |
| `pages/*.html` | `TU_NUMERO` | WhatsApp en formato `521XXXXXXXXXX` |
| `pages/app.html` | `CAPACIDAD_MAX` | Aforo máximo del local |
| `pages/admin.html` | `CAPACIDAD_MAX` | Mismo valor |
| Edge Function | `SITE_URL` | Dominio de producción |
