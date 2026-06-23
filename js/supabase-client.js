/* ================================================================
   FIT HOUSE — SUPABASE CLIENT + UTILIDADES COMPARTIDAS
   Importar en todos los módulos JS del sistema.
   
   ⚠️ REEMPLAZA ESTAS DOS CONSTANTES CON TUS VALORES REALES:
      Project Settings → API en tu consola de Supabase.
================================================================ */

// ── Credenciales del proyecto ──────────────────────────────────
const SUPABASE_URL  = 'https://awoxzsalguaercglrywf.supabase.co';   // ← reemplazar
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF3b3h6c2FsZ3VhZXJjZ2xyeXdmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIyNDAyMjcsImV4cCI6MjA5NzgxNjIyN30.9vBd-U8-rnzEwMIOj3cJg-Q_P8TQcwe7eVsHmGs0TnY';                  // ← reemplazar

// La SERVICE_ROLE KEY **NUNCA** va en el frontend.
// Solo se usa en Edge Functions o en el backend de Supabase.


// ── Inicializar cliente Supabase ──────────────────────────────
// Se importa Supabase desde CDN en el HTML que use este módulo.
// window.supabase se inicializa en ese HTML, y luego se usa aquí.
let _supabase = null;

export function getClient() {
  if (!_supabase) {
    // supabase-js v2 expone createClient en window.supabase
    _supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON);
  }
  return _supabase;
}


// ── Helper: obtener sesión activa ─────────────────────────────
export async function getSession() {
  const { data: { session } } = await getClient().auth.getSession();
  return session;
}


// ── Helper: obtener perfil del miembro ───────────────────────
export async function getMiembro(userId) {
  const { data, error } = await getClient()
    .from('miembros_gym')
    .select('*')
    .eq('id', userId)
    .single();
  if (error) throw error;
  return data;
}


// ── Helper: verificar si la membresía está vigente ───────────
export function membresiaActiva(miembro) {
  if (!miembro) return false;
  if (miembro.estado_suscripcion !== 'activo') return false;
  const hoy    = new Date();
  hoy.setHours(0, 0, 0, 0);
  const vence  = new Date(miembro.fecha_vencimiento + 'T00:00:00');
  return vence >= hoy;
}


// ── Toast utility ──────────────────────────────────────────────
export function toast(msg, type = 'info', durMs = 3500) {
  let container = document.getElementById('toast-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'toast-container';
    document.body.appendChild(container);
  }

  const icons = { success: '✓', error: '✕', info: '●' };
  const colors = { success: 'var(--green)', error: 'var(--red)', info: 'var(--accent)' };

  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.innerHTML = `
    <span style="color:${colors[type]};font-weight:700;font-size:16px">${icons[type]}</span>
    <span>${msg}</span>
  `;
  container.appendChild(el);

  setTimeout(() => {
    el.style.transition = 'opacity 0.4s, transform 0.4s';
    el.style.opacity = '0';
    el.style.transform = 'translateY(12px)';
    setTimeout(() => el.remove(), 400);
  }, durMs);
}


// ── Formatear fecha legible ───────────────────────────────────
export function formatDate(dateStr) {
  if (!dateStr) return '—';
  return new Date(dateStr + 'T12:00:00').toLocaleDateString('es-MX', {
    day: '2-digit', month: 'short', year: 'numeric'
  });
}


// ── Días hasta vencimiento ────────────────────────────────────
export function diasRestantes(dateStr) {
  if (!dateStr) return 0;
  const hoy   = new Date(); hoy.setHours(0,0,0,0);
  const vence = new Date(dateStr + 'T00:00:00');
  return Math.ceil((vence - hoy) / 86400000);
}


// ── Generar payload QR anti-fraude ───────────────────────────
// El QR contiene: userId + window de 30s + firma sencilla.
// La firma es un hash ligero para invalidar QRs viejos.
// (En producción, usa HMAC con una secret key del servidor.)
export function generarPayloadQR(userId) {
  const ventana = Math.floor(Date.now() / 30000); // cambia cada 30s
  const raw     = `${userId}|${ventana}`;
  // Firma simple (XOR checksum — suficiente para pantalla compartida)
  let check = 0;
  for (let i = 0; i < raw.length; i++) check ^= raw.charCodeAt(i);
  return `FH:${raw}|${check.toString(16).padStart(2,'0')}`;
}

// Validar payload QR (usado en el escáner)
export function validarPayloadQR(payload) {
  if (!payload || !payload.startsWith('FH:')) return null;
  const inner = payload.slice(3);
  const parts = inner.split('|');
  if (parts.length !== 3) return null;

  const [userId, ventanaStr, firma] = parts;
  const raw     = `${userId}|${ventanaStr}`;
  let check = 0;
  for (let i = 0; i < raw.length; i++) check ^= raw.charCodeAt(i);
  if (check.toString(16).padStart(2,'0') !== firma) return null;

  // Verificar que el QR no tenga más de 1 ventana de antigüedad (60s max)
  const ahora   = Math.floor(Date.now() / 30000);
  const ventana = parseInt(ventanaStr, 10);
  if (Math.abs(ahora - ventana) > 1) return null;   // expirado

  return userId;
}
