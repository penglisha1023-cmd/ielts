// ===================================================================
// reading-bridge.js — runs inside each reading test page.
// Wires the standalone reading page into Supabase:
//   - progress (current answers) pushed on each radio / select / text change
//   - score pushed when submitAnswers() finishes
//   - initial overlay restores progress from Supabase on first paint
//
// Reading test_id space is offset by READING_ID_OFFSET to avoid colliding
// with listening test ids (1-88) in the shared `scores` / `progress`
// tables. The catalog page mirrors this offset when reading data back.
// ===================================================================

(function () {
  const READING_ID = window.READING_ID;
  if (!READING_ID) { console.error('[reading-bridge] window.READING_ID missing'); return; }

  const READING_ID_OFFSET = 10000;
  const TEST_ID = READING_ID + READING_ID_OFFSET;
  window.READING_TEST_ID = TEST_ID;

  function whenReady(cb) {
    if (document.readyState !== 'loading') return cb();
    document.addEventListener('DOMContentLoaded', cb);
  }

  whenReady(async () => {
    // Yield once so the page's own DOMContentLoaded handler (loadAnswers etc.)
    // has run and populated radios from localStorage first — we only fill in
    // the gaps from Supabase rather than overwriting fresh local edits.
    await new Promise(r => setTimeout(r, 0));

    const user = await IELTS.getUser();
    if (!user) {
      showBanner('未登录,成绩与进度不会同步到云端。请回首页登录。', '#fef3c7', '#92400e');
      return;
    }

    // ---- 1. Pull existing progress and overlay any missing answers ----
    try {
      const { data: prog } = await IELTS.fetchProgress(TEST_ID);
      if (prog && prog.answers) {
        const blob = (prog.answers && prog.answers.answers) || prog.answers;
        overlayAnswers(blob);
      }
    } catch (e) { console.warn('[reading-bridge] initial sync failed', e); }

    // ---- 2. Bind input listeners to push progress (debounced) ----
    let pushTimer;
    function schedulePush() {
      clearTimeout(pushTimer);
      pushTimer = setTimeout(pushProgress, 500);
    }
    document.querySelectorAll('input[type=radio], select, input[type=text]').forEach(el => {
      const ev = (el.tagName === 'INPUT' && el.type === 'text') ? 'input' : 'change';
      el.addEventListener(ev, schedulePush);
    });

    // ---- 3. Wrap submitAnswers to push score after grading ----
    if (typeof window.submitAnswers === 'function') {
      const origSubmit = window.submitAnswers;
      window.submitAnswers = function () {
        const ret = origSubmit.apply(this, arguments);
        // Original sets window.lastResults synchronously; push on a tick.
        setTimeout(pushScore, 60);
        return ret;
      };
    }
  });

  // -----------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------

  function showBanner(text, bg, fg) {
    const b = document.createElement('div');
    b.style.cssText =
      'position:fixed;bottom:20px;left:0;right:0;text-align:center;z-index:200;' +
      'background:' + bg + ';color:' + fg + ';padding:8px 12px;font-size:.9em;';
    b.textContent = text;
    document.body.appendChild(b);
  }

  function collectAnswers() {
    const a = {};
    document.querySelectorAll('input[type=radio]:checked').forEach(i => { a[i.name] = i.value; });
    document.querySelectorAll('select').forEach(s => { if (s.value) a[s.name] = s.value; });
    document.querySelectorAll('input[type=text]').forEach(i => { if (i.value) a[i.name] = i.value; });
    return a;
  }

  function pushProgress() {
    IELTS.upsertProgress(TEST_ID, { answers: collectAnswers() }, 0).catch(console.error);
  }

  function pushScore() {
    // The page declares `let lastResults` at script-top, so it lives in the
    // global declarative env, not on window. Use `typeof` to read it safely.
    let results = [];
    try { if (typeof lastResults !== 'undefined') results = lastResults; } catch (_) {}
    if (!results || !results.length) return;
    let correct = 0;
    const perQ = {};
    results.forEach(r => {
      if (r.isCorrect) correct++;
      perQ[r.id] = !!r.isCorrect;
    });
    IELTS.submitScore(TEST_ID, correct, results.length, 0, { perQ: perQ }).catch(console.error);
  }

  function overlayAnswers(blob) {
    if (!blob || typeof blob !== 'object') return;
    Object.entries(blob).forEach(([name, value]) => {
      if (value == null || value === '') return;
      // Radios
      const radio = document.querySelector(
        'input[type=radio][name="' + cssEscape(name) + '"][value="' + cssEscape(value) + '"]'
      );
      if (radio) {
        const groupChecked = document.querySelector(
          'input[type=radio][name="' + cssEscape(name) + '"]:checked'
        );
        if (!groupChecked) radio.checked = true;
        return;
      }
      // Selects
      const sel = document.querySelector('select[name="' + cssEscape(name) + '"]');
      if (sel) {
        if (!sel.value) sel.value = value;
        return;
      }
      // Text inputs
      const txt = document.querySelector('input[type=text][name="' + cssEscape(name) + '"]');
      if (txt && !txt.value) {
        txt.value = value;
      }
    });
  }

  function cssEscape(s) {
    return String(s).replace(/["\\]/g, '\\$&');
  }
})();
