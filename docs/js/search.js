/* ===================================================================
   LyreBirdAudio Docs - Client-Side Search
   =================================================================== */

(function () {
  'use strict';

  // ---------------------------------------------------------------
  // Search index — one entry per logical section
  // ---------------------------------------------------------------
  const INDEX = [
    {
      title: 'Overview',
      section: 'Getting Started',
      file: 'index.html',
      keywords: 'lyrebird audio rtsp streaming usb microphone mediamtx 24/7 reliability bird monitoring overview introduction what is'
    },
    {
      title: 'Quick Start',
      section: 'Getting Started',
      file: 'quick-start.html',
      keywords: 'quick start install setup clone git chmod orchestrator wizard stream 5 minutes get started beginning first time'
    },
    {
      title: 'System Requirements',
      section: 'Getting Started',
      file: 'quick-start.html#requirements',
      keywords: 'requirements linux ubuntu debian raspberry pi bash ffmpeg curl systemd udev dependencies hardware cpu memory x86_64 arm64'
    },
    {
      title: 'Installation',
      section: 'Getting Started',
      file: 'quick-start.html#installation',
      keywords: 'install mediamtx manual orchestrator wizard guided setup step by step install_mediamtx.sh'
    },
    {
      title: 'Basic Usage',
      section: 'User Guide',
      file: 'usage.html',
      keywords: 'usage basic start stop restart status streams access vlc ffplay rtsp url connect'
    },
    {
      title: 'Managing Streams',
      section: 'User Guide',
      file: 'usage.html#managing-streams',
      keywords: 'stream manager start stop restart status force-stop lyrebird-stream-manager.sh commands'
    },
    {
      title: 'Accessing Streams',
      section: 'User Guide',
      file: 'usage.html#accessing-streams',
      keywords: 'access streams rtsp url vlc ffplay ffmpeg record clients players'
    },
    {
      title: 'Multiplex Streaming',
      section: 'User Guide',
      file: 'usage.html#multiplex',
      keywords: 'multiplex amix amerge multiple microphones combine merge mix channels all_mics'
    },
    {
      title: 'Configuration Guide',
      section: 'User Guide',
      file: 'configuration.html',
      keywords: 'configuration config audio-devices.conf sample rate bitrate channels codec opus aac pcm device settings'
    },
    {
      title: 'Configuration Files',
      section: 'User Guide',
      file: 'configuration.html#config-files',
      keywords: 'configuration files mediamtx.yml audio-devices.conf udev rules systemd service paths locations'
    },
    {
      title: 'Environment Variables',
      section: 'User Guide',
      file: 'configuration.html#env-vars',
      keywords: 'environment variables MEDIAMTX_HOST API_PORT STREAM_STARTUP_DELAY export override debug'
    },
    {
      title: 'MediaMTX Integration',
      section: 'User Guide',
      file: 'configuration.html#mediamtx',
      keywords: 'mediamtx integration configuration yml rtsp api port modes systemd stream manager'
    },
    {
      title: 'Component Reference',
      section: 'Components',
      file: 'components.html',
      keywords: 'components reference all scripts overview table versions'
    },
    {
      title: 'Orchestrator',
      section: 'Components',
      file: 'components.html#orchestrator',
      keywords: 'orchestrator lyrebird-orchestrator.sh menu wizard management interface interactive'
    },
    {
      title: 'Stream Manager',
      section: 'Components',
      file: 'components.html#stream-manager',
      keywords: 'stream manager lyrebird-stream-manager.sh ffmpeg process lifecycle health monitoring recovery'
    },
    {
      title: 'USB Audio Mapper',
      section: 'Components',
      file: 'components.html#usb-mapper',
      keywords: 'usb audio mapper usb-audio-mapper.sh udev persistent device names symlinks reboot'
    },
    {
      title: 'Capability Checker',
      section: 'Components',
      file: 'components.html#mic-check',
      keywords: 'mic check capability checker lyrebird-mic-check.sh hardware detection sample rate channels format quality'
    },
    {
      title: 'Diagnostics Script',
      section: 'Components',
      file: 'components.html#diagnostics',
      keywords: 'diagnostics lyrebird-diagnostics.sh health checks system quick full debug'
    },
    {
      title: 'MediaMTX Installer',
      section: 'Components',
      file: 'components.html#installer',
      keywords: 'installer install_mediamtx.sh download update verify checksum sha256 version'
    },
    {
      title: 'Webhook Alerts',
      section: 'Components',
      file: 'components.html#alerts',
      keywords: 'alerts webhooks lyrebird-alerts.sh discord slack pushover ntfy notifications rate limit'
    },
    {
      title: 'Prometheus Metrics',
      section: 'Components',
      file: 'components.html#metrics',
      keywords: 'prometheus metrics lyrebird-metrics.sh grafana monitoring scrape export openmetrics'
    },
    {
      title: 'Storage Management',
      section: 'Components',
      file: 'components.html#storage',
      keywords: 'storage management lyrebird-storage.sh disk cleanup retention recordings logs'
    },
    {
      title: 'Troubleshooting',
      section: 'Operations',
      file: 'troubleshooting.html',
      keywords: 'troubleshoot problems issues errors fix no devices found streams won\'t start permission denied crash'
    },
    {
      title: 'No USB Devices Found',
      section: 'Operations',
      file: 'troubleshooting.html#no-devices',
      keywords: 'usb devices not found detection arecord lsusb udev not detected'
    },
    {
      title: 'Streams Won\'t Start',
      section: 'Operations',
      file: 'troubleshooting.html#stream-issues',
      keywords: 'streams won\'t start fail errors logs configuration validation force-stop'
    },
    {
      title: 'Device Names Change After Reboot',
      section: 'Operations',
      file: 'troubleshooting.html#device-names',
      keywords: 'device names change reboot udev rules symlinks device_1 device_2 rename'
    },
    {
      title: 'Permission Errors',
      section: 'Operations',
      file: 'troubleshooting.html#permissions',
      keywords: 'permission denied audio group chmod root sudo usermod'
    },
    {
      title: 'High CPU Usage',
      section: 'Operations',
      file: 'troubleshooting.html#cpu-usage',
      keywords: 'high cpu usage performance ffmpeg accumulation optimize reduce bitrate'
    },
    {
      title: 'Debug Mode',
      section: 'Operations',
      file: 'troubleshooting.html#debug',
      keywords: 'debug mode DEBUG=1 verbose logging logs collect information'
    },
    {
      title: 'Diagnostics & Monitoring',
      section: 'Operations',
      file: 'monitoring.html',
      keywords: 'diagnostics monitoring health check quick full debug exit codes'
    },
    {
      title: 'Performance & Optimization',
      section: 'Operations',
      file: 'monitoring.html#performance',
      keywords: 'performance optimization codec bitrate sample rate raspberry pi cpu memory bandwidth thread queue'
    },
    {
      title: 'System Tuning',
      section: 'Operations',
      file: 'monitoring.html#system-tuning',
      keywords: 'system tuning file descriptors ulimit sysctl network buffers usb latency'
    },
    {
      title: 'Security Overview',
      section: 'Operations',
      file: 'security.html',
      keywords: 'security overview default posture hardening rtsp auth tls encryption api'
    },
    {
      title: 'RTSP Authentication',
      section: 'Operations',
      file: 'security.html#rtsp-auth',
      keywords: 'rtsp authentication auth internal users password jwt mediamtx.yml'
    },
    {
      title: 'Network Security',
      section: 'Operations',
      file: 'security.html#network',
      keywords: 'network security firewall ufw iptables vpn api restrict bind interface'
    },
    {
      title: 'Field Deployments',
      section: 'Operations',
      file: 'security.html#field',
      keywords: 'field deployment remote security recommendations vpn audit physical security'
    },
    {
      title: 'Architecture & Design',
      section: 'Reference',
      file: 'architecture.html',
      keywords: 'architecture design system overview diagrams components interaction mediamtx ffmpeg udev'
    },
    {
      title: 'Architecture Decision Records',
      section: 'Reference',
      file: 'architecture.html#adrs',
      keywords: 'ADR architecture decision records bash mediamtx ffmpeg udev webhook prometheus'
    },
    {
      title: 'Advanced Topics',
      section: 'Reference',
      file: 'advanced.html',
      keywords: 'advanced custom integration api backup restore recovery version management rollback uninstall'
    },
    {
      title: 'Recovery Procedures',
      section: 'Reference',
      file: 'advanced.html#recovery',
      keywords: 'recovery procedures stream not starting device not found complete system recovery'
    },
    {
      title: 'Version Management',
      section: 'Reference',
      file: 'advanced.html#versions',
      keywords: 'version management update upgrade rollback branch tag git lyrebird-updater.sh'
    },
    {
      title: 'Uninstallation',
      section: 'Reference',
      file: 'advanced.html#uninstall',
      keywords: 'uninstall remove cleanup complete removal mediamtx udev service logs'
    },
    {
      title: 'Contributing',
      section: 'Reference',
      file: 'contributing.html',
      keywords: 'contributing development code standards testing shellcheck bats pull request workflow'
    },
    {
      title: 'Changelog',
      section: 'Reference',
      file: 'changelog.html',
      keywords: 'changelog versions releases history breaking changes added fixed'
    }
  ];

  // ---------------------------------------------------------------
  // Simple fuzzy/substring search
  // ---------------------------------------------------------------
  function search(query) {
    if (!query || query.trim().length < 2) return [];
    const terms = query.toLowerCase().trim().split(/\s+/);

    return INDEX
      .map(entry => {
        const haystack = (entry.title + ' ' + entry.section + ' ' + entry.keywords).toLowerCase();
        let score = 0;

        terms.forEach(term => {
          if (entry.title.toLowerCase().includes(term)) score += 10;
          if (entry.section.toLowerCase().includes(term)) score += 5;
          if (entry.keywords.toLowerCase().includes(term)) score += 3;
          // Exact word boundary bonus
          if (new RegExp(`\\b${term}\\b`).test(haystack)) score += 2;
        });

        return { ...entry, score };
      })
      .filter(e => e.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, 8);
  }

  function highlight(text, query) {
    if (!query) return text;
    const terms = query.trim().split(/\s+/).filter(t => t.length > 1);
    if (!terms.length) return text;
    const pattern = new RegExp(`(${terms.map(t => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi');
    return text.replace(pattern, '<mark>$1</mark>');
  }

  function renderResults(results, query) {
    if (!results.length) {
      return `<div class="search-result-empty">No results for "<em>${escapeHtml(query)}</em>"</div>`;
    }
    return results.map(r => `
      <a href="${r.file}" class="search-result-item">
        <div class="search-result-title">${highlight(r.title, query)}</div>
        <div class="search-result-section">${r.section}</div>
      </a>
    `).join('');
  }

  function escapeHtml(str) {
    return str.replace(/[&<>"']/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m]));
  }

  // ---------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------
  function init() {
    const inputEl = document.getElementById('search-input');
    const resultsEl = document.getElementById('search-results');

    if (!inputEl || !resultsEl) return;

    let hideTimer = null;

    inputEl.addEventListener('input', () => {
      const q = inputEl.value.trim();
      if (q.length < 2) {
        resultsEl.innerHTML = '';
        resultsEl.classList.remove('visible');
        return;
      }
      const results = search(q);
      resultsEl.innerHTML = renderResults(results, q);
      resultsEl.classList.add('visible');
    });

    inputEl.addEventListener('keydown', e => {
      if (e.key === 'Escape') {
        resultsEl.classList.remove('visible');
        inputEl.blur();
      }
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        const first = resultsEl.querySelector('.search-result-item');
        if (first) first.focus();
      }
    });

    resultsEl.addEventListener('keydown', e => {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        const focused = resultsEl.querySelector(':focus');
        const next = focused?.nextElementSibling;
        if (next) next.focus();
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        const focused = resultsEl.querySelector(':focus');
        const prev = focused?.previousElementSibling;
        if (prev) prev.focus();
        else inputEl.focus();
      }
      if (e.key === 'Escape') {
        resultsEl.classList.remove('visible');
        inputEl.focus();
      }
    });

    // Hide results when clicking outside
    document.addEventListener('mousedown', e => {
      if (!inputEl.contains(e.target) && !resultsEl.contains(e.target)) {
        resultsEl.classList.remove('visible');
      }
    });

    inputEl.addEventListener('focus', () => {
      if (inputEl.value.trim().length >= 2 && resultsEl.innerHTML) {
        resultsEl.classList.add('visible');
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
