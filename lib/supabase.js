// ===================================================================
// Supabase client initialiser + auth helpers + small data API.
// Loaded by index.html, dashboard.html, and inside each test iframe.
// ===================================================================
//
// Requires <script> tags loaded in this order *before* this file:
//   1. https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm  (as module) — OR the UMD build
//   2. /lib/config.js  (sets window.SUPABASE_URL / SUPABASE_KEY)
// ===================================================================

(function () {
  if (!window.supabase || !window.supabase.createClient) {
    console.error('[supabase.js] Supabase UMD bundle not loaded. Include <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script> first.');
    return;
  }
  if (window.sb) return; // already initialised

  const sb = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      storageKey: 'ielts.auth'
    }
  });
  window.sb = sb;
})();

// ---- Auth helpers --------------------------------------------------
window.IELTS = window.IELTS || {};

// Race any promise against a timeout. supabase-js sets no fetch timeout, so a
// single stalled request (flaky mobile / iPad / 微信 webview / a stuck token
// refresh) would otherwise hang forever and leave the page "一直加载". With this
// guard a stalled request rejects fast and callers fall back gracefully.
IELTS.withTimeout = function (promise, ms = 8000, label = 'request') {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(label + ' 超时(' + ms + 'ms)')), ms))
  ]);
};

IELTS.signUp = async function (email, password, displayName) {
  const { data, error } = await sb.auth.signUp({
    email, password,
    options: { data: { display_name: displayName } }
  });
  return { data, error };
};

IELTS.signIn = async function (email, password) {
  const { data, error } = await sb.auth.signInWithPassword({ email, password });
  return { data, error };
};

IELTS.signOut = async function () {
  await sb.auth.signOut();
  location.href = '/';
};

// getSession reads from localStorage (no network round-trip).
// Use this for client-side routing/auth checks; RLS still enforces
// the actual JWT on every data query so we don't trade off security.
IELTS.getUser = async function () {
  try {
    const { data: { session } } = await IELTS.withTimeout(sb.auth.getSession(), 10000, 'getSession');
    return session ? session.user : null;
  } catch (e) {
    // Don't spin forever — degrade to "signed out" so the login view shows.
    console.warn('[auth] getSession 失败/超时:', e.message);
    return null;
  }
};

// Profile cache (display_name rarely changes) — sessionStorage so it
// stays warm across tab navigations within the same session.
IELTS.getProfile = async function (userId) {
  const cacheKey = 'ielts.profile.' + userId;
  const cached = sessionStorage.getItem(cacheKey);
  if (cached) {
    try { return { data: JSON.parse(cached), error: null }; } catch (_) {}
  }
  try {
    const { data, error } = await IELTS.withTimeout(
      sb.from('profiles').select('*').eq('id', userId).maybeSingle(), 6000, 'getProfile');
    if (data) sessionStorage.setItem(cacheKey, JSON.stringify(data));
    return { data, error };
  } catch (e) {
    return { data: null, error: e };
  }
};

// ---- Score / progress / notes API --------------------------------
IELTS.submitScore = async function (testId, score, total, durationSecs, details) {
  const user = await IELTS.getUser();
  if (!user) return { error: { message: 'not signed in' } };
  return sb.from('scores').insert({
    user_id: user.id,
    test_id: testId,
    score, total,
    duration_secs: durationSecs,
    details: details || null
  });
};

IELTS.fetchScores = async function () {
  return sb.from('scores').select('*').order('finished_at', { ascending: false });
};

IELTS.upsertProgress = async function (testId, answers, timerSecs) {
  return sb.from('progress').upsert({
    test_id: testId,
    answers: answers || {},
    timer_secs: timerSecs || 0,
    user_id: (await IELTS.getUser())?.id,
    updated_at: new Date().toISOString()
  });
};

IELTS.fetchProgress = async function (testId) {
  const { data, error } = await sb.from('progress')
    .select('*').eq('test_id', testId).maybeSingle();
  return { data, error };
};

IELTS.upsertNote = async function (testId, hid, quote, noteText) {
  return sb.from('notes').upsert({
    user_id: (await IELTS.getUser())?.id,
    test_id: testId,
    hid, quote,
    note_text: noteText || '',
    updated_at: new Date().toISOString()
  }, { onConflict: 'user_id,test_id,hid' });
};

IELTS.deleteNote = async function (testId, hid) {
  return sb.from('notes').delete().eq('test_id', testId).eq('hid', hid);
};

IELTS.fetchNotes = async function (testId) {
  const q = sb.from('notes').select('*');
  if (testId !== undefined) q.eq('test_id', testId);
  return q.order('updated_at', { ascending: false });
};

// ---- Misc utilities ----------------------------------------------
IELTS.requireAuth = async function () {
  const user = await IELTS.getUser();
  if (!user) {
    location.href = '/';
    return null;
  }
  return user;
};

IELTS.audioUrl = function (testId) {
  return window.AUDIO_BUCKET_URL + '/' + testId + '.mp3';
};

// ---- Admin helpers -----------------------------------------------
IELTS.isAdmin = async function () {
  const user = await IELTS.getUser();
  if (!user) return false;
  const cacheKey = 'ielts.isAdmin.' + user.id;
  const cached = sessionStorage.getItem(cacheKey);
  if (cached === '1') return true;
  if (cached === '0') return false;
  try {
    const { data } = await IELTS.withTimeout(
      sb.from('profiles').select('is_admin').eq('id', user.id).maybeSingle(), 6000, 'isAdmin');
    const ok = !!(data && data.is_admin);
    sessionStorage.setItem(cacheKey, ok ? '1' : '0');
    return ok;
  } catch (e) {
    return false;   // don't cache a transient failure
  }
};

IELTS.fetchAdminStudentOverview = async function () {
  return sb.rpc('get_admin_student_overview');
};
