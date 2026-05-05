// ===================================================================
// nav.js — renders the shared top navigation on every authenticated page.
//
// Usage: include after supabase.js, then in DOMContentLoaded call:
//   await IELTS_NAV.mount('me');     // 'me' | 'listening' | 'reading' | 'writing' | 'speaking' | 'leaderboard'
// ===================================================================

window.IELTS_NAV = (function () {
  const TABS = [
    { id: 'me',          label: '我的',     href: '/' },
    { id: 'listening',   label: '雅思听力', href: '/listening.html' },
    { id: 'reading',     label: '雅思阅读', href: '/reading.html' },
    { id: 'writing',     label: '雅思写作', href: '/writing.html' },
    { id: 'speaking',    label: '雅思口语', href: '/speaking.html' },
    { id: 'leaderboard', label: '排行榜',   href: '/leaderboard.html' }
  ];

  function render(activeTabId) {
    const html = `
      <nav class="top-nav">
        <a href="/" class="nav-brand">DNL雅思机经</a>
        <div class="nav-tabs">
          ${TABS.map(t => `<a href="${t.href}" data-tab="${t.id}" class="${t.id === activeTabId ? 'active' : ''}">${t.label}</a>`).join('')}
        </div>
        <div class="nav-user">
          <span class="who" id="nav-who"></span>
          <button class="btn" id="nav-signout" type="button">退出</button>
        </div>
      </nav>
    `;
    return html;
  }

  async function mount(activeTabId) {
    // Insert nav at top of body
    const navHtml = render(activeTabId);
    const wrap = document.createElement('div');
    wrap.innerHTML = navHtml;
    document.body.insertBefore(wrap.firstElementChild, document.body.firstChild);

    document.getElementById('nav-signout').addEventListener('click', () => IELTS.signOut());

    // Display name
    const user = await IELTS.getUser();
    if (user) {
      const { data: profile } = await IELTS.getProfile(user.id);
      const who = document.getElementById('nav-who');
      if (who) who.textContent = profile?.display_name ? `Hi, ${profile.display_name}` : user.email;
    }

    // Prefetch the other tabs so subsequent clicks are near-instant.
    requestIdleCallback ? requestIdleCallback(prefetchTabs) : setTimeout(prefetchTabs, 800);
    return user;
  }

  function prefetchTabs() {
    TABS.forEach(t => {
      if (document.querySelector(`link[rel="prefetch"][href="${t.href}"]`)) return;
      const l = document.createElement('link');
      l.rel  = 'prefetch';
      l.href = t.href;
      l.as   = 'document';
      document.head.appendChild(l);
    });
  }

  return { render, mount, TABS };
})();
