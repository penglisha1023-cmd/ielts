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
  const { data: { session } } = await sb.auth.getSession();
  return session ? session.user : null;
};

// Profile cache (display_name rarely changes) — sessionStorage so it
// stays warm across tab navigations within the same session.
IELTS.getProfile = async function (userId) {
  const cacheKey = 'ielts.profile.' + userId;
  const cached = sessionStorage.getItem(cacheKey);
  if (cached) {
    try { return { data: JSON.parse(cached), error: null }; } catch (_) {}
  }
  const { data, error } = await sb.from('profiles').select('*').eq('id', userId).maybeSingle();
  if (data) sessionStorage.setItem(cacheKey, JSON.stringify(data));
  return { data, error };
};

// ---- Score / progress / notes API --------------------------------
IELTS.submitScore = async function (testId, score, total, durationSecs, details) {
  return sb.from('scores').insert({
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
