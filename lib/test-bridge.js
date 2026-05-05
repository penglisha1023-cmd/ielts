// ===================================================================
// test-bridge.js — runs inside each test page (after the IIFE).
// Wires the original App into Supabase: progress sync, score submission,
// and notes sync. Falls back to local-only behaviour if not signed in.
// ===================================================================

(function () {
  const TEST_ID = window.TEST_ID;
  if (!TEST_ID) { console.error('[bridge] window.TEST_ID missing'); return; }

  // ---- Inject Morandi theme override ASAP so first paint matches the rest of the app
  (function injectTheme() {
    const css = `
      :root {
        --bg-color: #ebe4d9 !important;
        --panel-color: #f7f1e7 !important;
        --text-color: #3d362e !important;
        --border-color: #d7cdbe !important;
        --splitter-color: #d7cdbe !important;
        --accent-color: #8fa394 !important;
        --answered-bg: #c8d2dc !important;
        --answered-border: #9aa6b3 !important;
        --answered-text: #4d5862 !important;
        --correct-bg: #c8d6cc !important;
        --correct-border: #7d9282 !important;
        --correct-text: #4a5a4f !important;
        --incorrect-bg: #e3c9bc !important;
        --incorrect-border: #b58575 !important;
        --incorrect-text: #6b3f2e !important;
        --shadow: 0 4px 16px rgba(60,52,44,.10) !important;
      }
      .hl { background: #d8c1ac !important; }
      .hl-blue { background: #c8d2dc !important; }
      .answer-highlight { background-color: #c8d2dc !important; border-bottom-color: #9aa6b3 !important; }
      body { background: var(--bg-color); }
      .progress-bar-wrapper { background-color: #d7cdbe !important; }
      input.blank { border-color: #b8ad9e !important; }
      input.blank:focus { box-shadow: 0 0 3px var(--accent-color) !important; }
    `;
    const style = document.createElement('style');
    style.id = 'morandi-theme';
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  })();

  function whenReady(cb) {
    (function tick() {
      if (window.App && document.readyState !== 'loading') return cb();
      setTimeout(tick, 30);
    })();
  }

  whenReady(async () => {
    // Allow original App.init() (registered on DOMContentLoaded) to run first.
    await new Promise(r => setTimeout(r, 0));

    const user = await IELTS.getUser();

    // Show a banner if not signed in — practice still works locally.
    if (!user) {
      showBanner('未登录,成绩与笔记不会同步到云端。请回首页登录。', '#fef3c7', '#92400e');
      return;
    }

    // ---- Patch saveState: also push to Supabase progress ----
    const origSave = App.saveState.bind(App);
    App.saveState = function () { origSave(); pushProgress(); };

    // ---- Patch gradeAndHighlight: after grading, push score ----
    const origGrade = App.gradeAndHighlight.bind(App);
    App.gradeAndHighlight = function () {
      origGrade();
      // give the DOM a tick to settle .correct/.incorrect classes
      setTimeout(pushScore, 80);
    };

    // ---- Patch notes.create: push new note to Supabase + bind events ----
    const origCreate = App.notes.create.bind(App.notes);
    App.notes.create = function (span) {
      origCreate(span);
      const card = document.querySelector('#notes-list .note-card'); // most recent
      if (card && card.dataset.hid) {
        bindNoteCard(card);
        const quote = card.querySelector('.note-quote')?.textContent || '';
        IELTS.upsertNote(TEST_ID, card.dataset.hid, quote, '').catch(console.error);
      }
    };

    // Bind already-rendered note cards (re-hydrated from localStorage).
    document.querySelectorAll('#notes-list .note-card').forEach(bindNoteCard);

    // ---- Initial overlay from Supabase ----
    try {
      const { data: prog } = await IELTS.fetchProgress(TEST_ID);
      if (prog) overlayProgress(prog);
      const { data: notes } = await IELTS.fetchNotes(TEST_ID);
      if (Array.isArray(notes)) overlayNotes(notes);
    } catch (e) { console.warn('[bridge] initial sync failed', e); }
  });

  // -----------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------

  function showBanner(text, bg, fg) {
    const b = document.createElement('div');
    b.style.cssText = `position:fixed;bottom:80px;left:0;right:0;text-align:center;z-index:200;background:${bg};color:${fg};padding:8px 12px;font-size:.9em;`;
    b.textContent = text;
    document.body.appendChild(b);
  }

  function bindNoteCard(card) {
    const hid = card.dataset.hid;
    if (!hid) return;
    const ta = card.querySelector('textarea');
    const delBtn = card.querySelector('button[data-act="del-note"]');
    if (ta && !ta.dataset.bridged) {
      ta.dataset.bridged = '1';
      let timer;
      ta.addEventListener('input', () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          const quote = card.querySelector('.note-quote')?.textContent || '';
          IELTS.upsertNote(TEST_ID, hid, quote, ta.value).catch(console.error);
        }, 600);
      });
    }
    if (delBtn && !delBtn.dataset.bridged) {
      delBtn.dataset.bridged = '1';
      // Capture phase so we run before the original handler removes the card.
      delBtn.addEventListener('click', () => {
        IELTS.deleteNote(TEST_ID, hid).catch(console.error);
      }, true);
    }
  }

  function collectAnswers() {
    const a = { text: {}, single: {}, multiple: {}, matching: {} };
    document.querySelectorAll('input.blank').forEach(i => { a.text[i.name] = i.value; });
    document.querySelectorAll('input[type=radio]:checked').forEach(i => { a.single[i.name] = i.value; });
    document.querySelectorAll('input[type=checkbox]:checked').forEach(i => {
      (a.multiple[i.name] = a.multiple[i.name] || []).push(i.value);
    });
    document.querySelectorAll('select').forEach(s => { if (s.value) a.matching[s.name] = s.value; });
    return a;
  }

  function pushProgress() {
    IELTS.upsertProgress(TEST_ID, { answers: collectAnswers() }, App.state.timerSecs).catch(console.error);
  }

  function pushScore() {
    const items = document.querySelectorAll('.q-nav-item');
    let correct = 0;
    const details = { perQ: {} };
    items.forEach(it => {
      const q = it.dataset.qnum;
      const ok = it.classList.contains('correct');
      if (ok) correct++;
      details.perQ[q] = ok;
    });
    IELTS.submitScore(TEST_ID, correct, items.length, App.state.timerSecs, details).catch(console.error);
  }

  function overlayProgress(prog) {
    const answersBlob = (prog.answers && prog.answers.answers) || {};
    Object.entries(answersBlob.text || {}).forEach(([n, v]) => {
      const i = document.querySelector(`input[name="${cssEscape(n)}"]`);
      if (i && !i.value) i.value = v;
    });
    Object.entries(answersBlob.single || {}).forEach(([n, v]) => {
      const i = document.querySelector(`input[name="${cssEscape(n)}"][value="${cssEscape(v)}"]`);
      if (i) i.checked = true;
    });
    Object.entries(answersBlob.multiple || {}).forEach(([n, vs]) => {
      (vs || []).forEach(v => {
        const i = document.querySelector(`input[name="${cssEscape(n)}"][value="${cssEscape(v)}"]`);
        if (i) i.checked = true;
      });
    });
    Object.entries(answersBlob.matching || {}).forEach(([n, v]) => {
      const s = document.querySelector(`select[name="${cssEscape(n)}"]`);
      if (s) s.value = v;
    });
    if (prog.timer_secs && prog.timer_secs > App.state.timerSecs) {
      App.state.timerSecs = prog.timer_secs;
      App.updateTimerUI();
    }
    App.updateNavState && App.updateNavState();
  }

  function overlayNotes(notes) {
    notes.forEach(n => {
      const card = document.querySelector(`#notes-list .note-card[data-hid="${cssEscape(n.hid)}"]`);
      if (card) {
        const ta = card.querySelector('textarea');
        if (ta && !ta.value && n.note_text) ta.value = n.note_text;
      }
      // If the highlighted span doesn't exist (e.g. fresh device with no
      // localStorage), we cannot reconstruct the highlight without DOM context.
      // Notes still appear in the dashboard; in-page highlights re-appear once
      // localStorage is hydrated on that device.
    });
  }

  function cssEscape(s) {
    return String(s).replace(/["\\]/g, '\\$&');
  }
})();
