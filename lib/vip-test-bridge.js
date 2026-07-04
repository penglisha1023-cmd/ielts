// ===================================================================
// vip-test-bridge.js — runs inside each VIP test page (after the template).
//
// The VIP template is a newer, self-contained build with a different
// architecture from the original 88 tests:
//   * It keeps ALL user state (answers + timer `secs` + notes HTML) in ONE
//     localStorage blob under window.localStorageKey.
//   * It exposes window.App / window.DATA / window.CONFIG_DATA.
//   * Grading: clicking #finish enters review mode and tags each
//     #nav [data-q] element with class "correct" / "incorrect".
//
// This bridge wires that template into Supabase:
//   * progress  — mirror the localStorage blob to the `progress` table
//                 (push on every save; hydrate a fresh device from cloud).
//   * score     — on finish/grade, count correct nav items and insert a row.
//   * notes     — mirror #notesList cards to the `notes` table.
// Falls back to local-only behaviour when signed out.
// ===================================================================

(function () {
  const TEST_ID = window.TEST_ID;
  if (!TEST_ID) { console.error('[vip-bridge] window.TEST_ID missing'); return; }

  let enabled = false;                       // true once a signed-in user is confirmed
  const origSet = localStorage.setItem.bind(localStorage);
  let pushTimer = null;

  const key       = () => window.localStorageKey;
  const readBlob  = () => { try { return JSON.parse(localStorage.getItem(key()) || 'null'); } catch (_) { return null; } };
  const timerSecs = () => { const b = readBlob(); return (b && +b.secs) || 0; };

  // ---- Mirror every template save() to the cloud (debounced) --------------
  function schedulePush() {
    if (!enabled) return;
    clearTimeout(pushTimer);
    pushTimer = setTimeout(() => {
      const raw = localStorage.getItem(key());
      if (raw != null) IELTS.upsertProgress(TEST_ID, { vip: raw }, timerSecs()).catch(console.error);
    }, 900);
  }

  // Patch setItem immediately (before the template's first save fires) so no
  // write is ever missed once syncing is enabled.
  localStorage.setItem = function (k, v) {
    origSet(k, v);
    if (enabled && k === key()) schedulePush();
  };

  whenReady(async () => {
    // Let the template's DOMContentLoaded init() restore + render first.
    await new Promise(r => setTimeout(r, 0));

    const user = await IELTS.getUser();
    if (!user) {
      showBanner('未登录,成绩与笔记不会同步到云端。请回首页登录。', '#fef3c7', '#92400e');
      return;
    }
    enabled = true;

    await initialOverlay();   // may reload once on a fresh device
    watchGrading();
    observeNotes();
    schedulePush();           // push whatever state is currently loaded
  });

  // -----------------------------------------------------------------
  // Cross-device hydrate: if this device has no local progress but the
  // cloud does, write the cloud blob into localStorage and reload once so
  // the template restores it. Never clobbers existing local work.
  // -----------------------------------------------------------------
  async function initialOverlay() {
    const flag = 'vip_overlaid_' + TEST_ID;
    if (sessionStorage.getItem(flag)) return;
    let prog;
    try { ({ data: prog } = await IELTS.fetchProgress(TEST_ID)); } catch (_) { return; }
    const cloud = prog && prog.answers && prog.answers.vip;
    if (!cloud) return;
    const local = localStorage.getItem(key());
    if (local) return;                       // keep same-device state as source of truth
    sessionStorage.setItem(flag, '1');
    origSet(key(), cloud);                    // set without triggering a push
    location.reload();
  }

  // -----------------------------------------------------------------
  // Score: after the user finishes, read the graded nav and submit.
  // -----------------------------------------------------------------
  function questionList() {
    if (window.App && App.config && Array.isArray(App.config.questionList)) return App.config.questionList;
    if (window.DATA && Array.isArray(DATA.questionIds)) return DATA.questionIds;
    return [];
  }

  let lastSubmitted = null;   // "correct/total" of the last submitted score (dedupe)

  function maybeSubmitScore() {
    // Only when the test has actually been graded (review mode + tagged nav).
    if (!(window.App && App.state && App.state.isReviewing)) return;
    if (!document.querySelector('#nav [data-q].correct, #nav [data-q].incorrect')) return;
    const qs = questionList();
    if (!qs.length) return;
    let correct = 0;
    const perQ = {};
    qs.forEach(q => {
      const nav = document.querySelector('#nav [data-q="' + cssEscape(q) + '"]');
      const ok = !!(nav && nav.classList.contains('correct'));
      if (ok) correct++;
      perQ[q] = ok;
    });
    const sig = correct + '/' + qs.length;
    if (sig === lastSubmitted) return;   // avoid duplicate identical submits
    lastSubmitted = sig;
    IELTS.submitScore(TEST_ID, correct, qs.length, timerSecs(), { perQ })
      .then(res => { if (res && res.error) { lastSubmitted = null; console.error('[vip-bridge] submitScore', res.error); } else { toast('成绩已保存 ' + sig); } })
      .catch(e => { lastSubmitted = null; console.error('[vip-bridge] submitScore', e); });
  }

  // Watch the question nav: grading (Finish) is the only thing that tags items
  // with .correct / .incorrect. Observing it captures the score no matter how
  // grading was triggered — far more robust than hooking one button's click.
  function watchGrading() {
    const nav = document.querySelector('#nav');
    if (!nav) return;
    let t;
    new MutationObserver(() => { clearTimeout(t); t = setTimeout(maybeSubmitScore, 120); })
      .observe(nav, { subtree: true, attributes: true, attributeFilter: ['class'] });
  }

  // -----------------------------------------------------------------
  // Notes: mirror #notesList cards to the `notes` table so they appear in
  // the admin dashboard (cross-device note text also rides in the blob).
  // -----------------------------------------------------------------
  function quoteOf(card) { return card.querySelector('.note-quote')?.textContent || ''; }

  function syncNoteCard(card) {
    const hid = card.dataset.hid;
    if (!hid) return;
    const ta  = card.querySelector('textarea');
    const del = card.querySelector('.delete-note');

    if (ta && !ta.dataset.bridged) {
      ta.dataset.bridged = '1';
      let t;
      ta.addEventListener('input', () => {
        clearTimeout(t);
        t = setTimeout(() => IELTS.upsertNote(TEST_ID, hid, quoteOf(card), ta.value).catch(console.error), 700);
      });
    }
    if (del && !del.dataset.bridged) {
      del.dataset.bridged = '1';
      // capture phase: run before the template removes the card
      del.addEventListener('click', () => IELTS.deleteNote(TEST_ID, hid).catch(console.error), true);
    }
    // Register the note's existence (so it shows in the dashboard).
    IELTS.upsertNote(TEST_ID, hid, quoteOf(card), ta ? ta.value : '').catch(console.error);
  }

  function observeNotes() {
    const list = document.querySelector('#notesList');
    if (!list) return;
    list.querySelectorAll('.note-card').forEach(syncNoteCard);
    new MutationObserver(muts => {
      muts.forEach(m => (m.addedNodes || []).forEach(n => {
        if (n.nodeType === 1 && n.classList && n.classList.contains('note-card')) syncNoteCard(n);
      }));
    }).observe(list, { childList: true });
  }

  // -----------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------
  function whenReady(cb) {
    (function tick() {
      if (window.App && window.localStorageKey && document.readyState !== 'loading') return cb();
      setTimeout(tick, 30);
    })();
  }

  let toastEl = null, toastTimer = null;
  function toast(text) {
    if (!toastEl) {
      toastEl = document.createElement('div');
      toastEl.style.cssText = 'position:fixed;bottom:64px;left:50%;transform:translateX(-50%);z-index:9999;' +
        'background:#3d4a3f;color:#fff;padding:8px 16px;border-radius:8px;font-size:.9em;' +
        'box-shadow:0 4px 16px rgba(0,0,0,.2);opacity:0;transition:opacity .2s;';
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = text;
    toastEl.style.opacity = '1';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { if (toastEl) toastEl.style.opacity = '0'; }, 2200);
  }

  function showBanner(text, bg, fg) {
    const b = document.createElement('div');
    b.style.cssText = 'position:fixed;bottom:12px;left:0;right:0;text-align:center;z-index:9999;' +
      'background:' + bg + ';color:' + fg + ';padding:8px 12px;font-size:.9em;';
    b.textContent = text;
    document.body.appendChild(b);
  }

  function cssEscape(s) { return String(s).replace(/["\\]/g, '\\$&'); }
})();
