/* ===================================================================
   LyreBirdAudio Docs - Navigation & Sidebar
   =================================================================== */

(function () {
  'use strict';

  // ---------------------------------------------------------------
  // Navigation structure
  // ---------------------------------------------------------------
  const NAV = [
    {
      section: 'Getting Started',
      items: [
        { title: 'Overview', file: 'index.html' },
        { title: 'Quick Start', file: 'quick-start.html' },
      ]
    },
    {
      section: 'User Guide',
      items: [
        { title: 'Basic Usage', file: 'usage.html' },
        { title: 'Configuration', file: 'configuration.html' },
      ]
    },
    {
      section: 'Components',
      items: [
        { title: 'Component Reference', file: 'components.html' },
      ]
    },
    {
      section: 'Operations',
      items: [
        { title: 'Troubleshooting', file: 'troubleshooting.html' },
        { title: 'Monitoring & Diagnostics', file: 'monitoring.html' },
        { title: 'Security', file: 'security.html' },
      ]
    },
    {
      section: 'Reference',
      items: [
        { title: 'Architecture', file: 'architecture.html' },
        { title: 'Advanced Topics', file: 'advanced.html' },
        { title: 'Contributing', file: 'contributing.html' },
        { title: 'Changelog', file: 'changelog.html' },
      ]
    }
  ];

  // Flat ordered list for prev/next navigation
  const ALL_PAGES = NAV.flatMap(s => s.items);

  // ---------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------
  function currentFile() {
    const path = window.location.pathname;
    const file = path.split('/').pop() || 'index.html';
    return file === '' ? 'index.html' : file;
  }

  function buildSidebar() {
    const current = currentFile();

    let html = `
      <div class="sidebar-header">
        <a href="index.html" class="sidebar-logo">
          <span class="sidebar-logo-icon">🐦</span>
          <span class="sidebar-logo-text">
            <span class="sidebar-logo-name">LyreBirdAudio</span>
            <span class="sidebar-logo-sub">Documentation</span>
          </span>
        </a>
      </div>
      <div class="sidebar-search">
        <span class="sidebar-search-icon">🔍</span>
        <input type="text" id="search-input" placeholder="Search docs…" autocomplete="off" spellcheck="false" aria-label="Search documentation">
        <div id="search-results"></div>
      </div>
      <nav class="sidebar-nav" role="navigation" aria-label="Documentation navigation">
    `;

    NAV.forEach((section, sIdx) => {
      const sectionId = `section-${sIdx}`;
      html += `
        <div class="nav-section" id="${sectionId}">
          <div class="nav-section-header" role="button" tabindex="0" aria-expanded="true" data-section="${sectionId}">
            <span>${section.section}</span>
            <span class="nav-section-arrow">▾</span>
          </div>
          <ul class="nav-section-items">
      `;

      section.items.forEach(item => {
        const isActive = item.file === current;
        html += `
          <li class="nav-item ${isActive ? 'active' : ''}">
            <a href="${item.file}" ${isActive ? 'aria-current="page"' : ''}>${item.title}</a>
          </li>
        `;
      });

      html += `</ul></div>`;
    });

    html += `</nav>`;

    // Sidebar footer
    html += `
      <div class="sidebar-footer">
        <div class="sidebar-footer-links">
          <a href="https://github.com/tomtom215/LyreBirdAudio" target="_blank" rel="noopener">
            <span class="icon">⬡</span> GitHub Repository
          </a>
          <a href="https://github.com/tomtom215/LyreBirdAudio/issues" target="_blank" rel="noopener">
            <span class="icon">🐛</span> Report an Issue
          </a>
          <a href="https://github.com/tomtom215/LyreBirdAudio/discussions" target="_blank" rel="noopener">
            <span class="icon">💬</span> Discussions
          </a>
        </div>
      </div>
    `;

    return html;
  }

  function buildTopbar() {
    const current = currentFile();
    const currentIdx = ALL_PAGES.findIndex(p => p.file === current);
    const currentPage = ALL_PAGES[currentIdx];
    const sectionName = NAV.find(s => s.items.some(i => i.file === current))?.section || '';

    return `
      <button class="topbar-toggle" id="sidebar-toggle" aria-label="Toggle sidebar">☰</button>
      <div class="topbar-breadcrumb">
        <a href="index.html">LyreBirdAudio</a>
        ${sectionName ? `<span class="sep">/</span><span>${sectionName}</span>` : ''}
        ${currentPage && currentPage.title !== 'Overview' ? `<span class="sep">/</span><span class="current">${currentPage.title}</span>` : ''}
      </div>
      <div class="topbar-actions">
        <a href="https://github.com/tomtom215/LyreBirdAudio" class="topbar-btn" target="_blank" rel="noopener">
          ⬡ GitHub
        </a>
      </div>
    `;
  }

  function buildPageNav() {
    const current = currentFile();
    const currentIdx = ALL_PAGES.findIndex(p => p.file === current);
    const prev = currentIdx > 0 ? ALL_PAGES[currentIdx - 1] : null;
    const next = currentIdx < ALL_PAGES.length - 1 ? ALL_PAGES[currentIdx + 1] : null;

    let html = '';

    if (prev) {
      html += `
        <a href="${prev.file}" class="page-nav-btn prev">
          <span class="page-nav-arrow">←</span>
          <span>
            <span class="page-nav-btn-label">Previous</span>
            <span class="page-nav-btn-title">${prev.title}</span>
          </span>
        </a>
      `;
    } else {
      html += '<span></span>';
    }

    if (next) {
      html += `
        <a href="${next.file}" class="page-nav-btn next">
          <span>
            <span class="page-nav-btn-label">Next</span>
            <span class="page-nav-btn-title">${next.title}</span>
          </span>
          <span class="page-nav-arrow">→</span>
        </a>
      `;
    }

    return html;
  }

  // ---------------------------------------------------------------
  // Collapsible sections
  // ---------------------------------------------------------------
  function initCollapsibleSections() {
    const headers = document.querySelectorAll('.nav-section-header');
    headers.forEach(header => {
      const sectionId = header.dataset.section;
      const section = document.getElementById(sectionId);
      const storageKey = `lyrebird-nav-${sectionId}`;
      const savedState = localStorage.getItem(storageKey);

      // Restore saved state, but always expand active section
      const hasActive = section && section.querySelector('.nav-item.active');
      if (savedState === 'collapsed' && !hasActive) {
        section.classList.add('collapsed');
        header.setAttribute('aria-expanded', 'false');
      }

      header.addEventListener('click', () => toggleSection(header, section, storageKey));
      header.addEventListener('keydown', e => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          toggleSection(header, section, storageKey);
        }
      });
    });
  }

  function toggleSection(header, section, storageKey) {
    const isCollapsed = section.classList.toggle('collapsed');
    header.setAttribute('aria-expanded', isCollapsed ? 'false' : 'true');
    localStorage.setItem(storageKey, isCollapsed ? 'collapsed' : 'expanded');
  }

  // ---------------------------------------------------------------
  // Mobile sidebar toggle
  // ---------------------------------------------------------------
  function initSidebarToggle() {
    const toggleBtn = document.getElementById('sidebar-toggle');
    const sidebar = document.getElementById('sidebar');
    const overlay = document.getElementById('sidebar-overlay');

    if (!toggleBtn || !sidebar) return;

    toggleBtn.addEventListener('click', () => openSidebar(sidebar, overlay));
    if (overlay) {
      overlay.addEventListener('click', () => closeSidebar(sidebar, overlay));
    }

    document.addEventListener('keydown', e => {
      if (e.key === 'Escape' && sidebar.classList.contains('open')) {
        closeSidebar(sidebar, overlay);
      }
    });
  }

  function openSidebar(sidebar, overlay) {
    sidebar.classList.add('open');
    if (overlay) overlay.classList.add('visible');
    document.body.style.overflow = 'hidden';
  }

  function closeSidebar(sidebar, overlay) {
    sidebar.classList.remove('open');
    if (overlay) overlay.classList.remove('visible');
    document.body.style.overflow = '';
  }

  // ---------------------------------------------------------------
  // Anchor links for headings
  // ---------------------------------------------------------------
  function addAnchorLinks() {
    const headings = document.querySelectorAll('.content h2, .content h3, .content h4');
    headings.forEach(h => {
      if (!h.id) return;
      const anchor = document.createElement('a');
      anchor.className = 'anchor-link';
      anchor.href = `#${h.id}`;
      anchor.innerHTML = '¶';
      anchor.title = 'Permalink';
      h.appendChild(anchor);
    });
  }

  // ---------------------------------------------------------------
  // Code copy buttons
  // ---------------------------------------------------------------
  function addCopyButtons() {
    document.querySelectorAll('pre').forEach(pre => {
      const wrapper = document.createElement('div');
      wrapper.className = 'code-wrapper';
      pre.parentNode.insertBefore(wrapper, pre);
      wrapper.appendChild(pre);

      const btn = document.createElement('button');
      btn.className = 'copy-btn';
      btn.textContent = 'Copy';
      btn.setAttribute('aria-label', 'Copy code to clipboard');
      wrapper.appendChild(btn);

      btn.addEventListener('click', async () => {
        const code = pre.querySelector('code')?.textContent || pre.textContent;
        try {
          await navigator.clipboard.writeText(code);
          btn.textContent = 'Copied!';
          btn.classList.add('copied');
          setTimeout(() => {
            btn.textContent = 'Copy';
            btn.classList.remove('copied');
          }, 2000);
        } catch {
          btn.textContent = 'Copy';
        }
      });
    });
  }

  // ---------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------
  function init() {
    // Inject sidebar
    const sidebarEl = document.getElementById('sidebar');
    if (sidebarEl) {
      sidebarEl.innerHTML = buildSidebar();
    }

    // Inject topbar
    const topbarEl = document.getElementById('topbar');
    if (topbarEl) {
      topbarEl.innerHTML = buildTopbar();
    }

    // Inject page nav
    const pageNavEl = document.getElementById('page-nav');
    if (pageNavEl) {
      pageNavEl.innerHTML = buildPageNav();
    }

    // Setup interactions
    initCollapsibleSections();
    initSidebarToggle();
    addAnchorLinks();
    addCopyButtons();

    // Scroll active nav item into view
    const activeItem = document.querySelector('.nav-item.active a');
    if (activeItem) {
      setTimeout(() => activeItem.scrollIntoView({ block: 'nearest', behavior: 'smooth' }), 150);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  // Expose for search.js
  window.LybirdNav = { ALL_PAGES, NAV };
})();
