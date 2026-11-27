// =============================================================================
// Swagger UI 多模块 + 四视角实时 ACL 过滤初始化器（OmniPG × citywalk PostgREST）
// 四层硬隔离第 4 层：
//   - 通过同源 POST /pgrst-acl 实时拉取当前 Schema 的 PostgreSQL ACL 权限矩阵
//   - 在顶栏注入四视角胶囊切换器（记忆在 localStorage.cw_swagger_surface）：
//       1) 📦 全量 (all)         —— 全部接口 + 自动冠以 [🌐 C端公开] / [👤 C端会员专享] / [🛡️ B端管理专用]
//       2) 🌐 用户端·公开 (public) —— 仅 web_anon 可读接口，自动切换 host=localhost:9080 basePath=/public
//       3) 👤 用户端·会员 (member) —— 仅 role_member 可访问接口，自动切换 host=localhost:9080 basePath=/app
//       4) 🛡️ 管理端·专用 (admin)  —— 仅管理员/编辑专用纯后台接口，保持 host=localhost:3100 basePath=/
// =============================================================================
(function () {
  var MODULES = [
    'api_v1_platform',
    'api_v1_masterdata',
    'api_v1_commons',
    'api_v1_content',
    'api_v1_content_comment',
    'api_v1_content_feedback',
    'api_v1_content_notes',
    'api_v1_content_places',
    'api_v1_content_reaction',
    'api_v1_content_translations',
    'api_v1_creator',
    'api_v1_business',
    'api_v1_payout',
    'api_v1_rewards',
    'api_v1_files',
    'api_v1_identity',
    'api_v1_social',
    'api_v1_chat',
    'api_v1_map',
    'api_v1_search',
    'api_v1_notification',
    'api_v1_moderation',
    'api_v1_fraud',
    'api_v1_seo',
    'api_v1_observation',
    'api_v1_ai',
    'api_v1_osm'
  ];

  var STORAGE_KEY = 'cw_swagger_surface';
  var VALID_SURFACES = ['all', 'public', 'member', 'admin'];
  var activeProfile = MODULES[0];
  var activeSurface = (function () {
    try {
      var saved = window.localStorage.getItem(STORAGE_KEY);
      return VALID_SURFACES.indexOf(saved) >= 0 ? saved : 'all';
    } catch (e) {
      return 'all';
    }
  })();

  var specCache = {};
  var aclCache = {};
  var loadingToken = 0;

  function profileFromUrl(url) {
    var m = /pgrst-spec\/([\w.]+)/.exec(url || '');
    return m ? m[1] : null;
  }

  function clone(obj) {
    return JSON.parse(JSON.stringify(obj));
  }

  function classifyPath(pathKey, aclMap) {
    if (pathKey === '/') {
      return { anon: false, member: false, admin: true, kind: 'root' };
    }
    var entry = aclMap && aclMap[pathKey];
    if (entry) {
      return entry;
    }
    return { anon: false, member: false, admin: true, kind: pathKey.indexOf('/rpc/') === 0 ? 'rpc' : 'view' };
  }

  function badgeFor(acl) {
    if (acl.anon) return '[🌐 C端公开] ';
    if (acl.member) return '[👤 C端会员专享] ';
    if (acl.admin) return '[🛡️ B端管理专用] ';
    return '';
  }

  function buildFilteredSpec(rawSpec, aclMap, surface) {
    var spec = clone(rawSpec);
    var srcPaths = spec.paths || {};
    var outPaths = {};
    var counts = { all: 0, public: 0, member: 0, admin: 0 };

    Object.keys(srcPaths).forEach(function (pathKey) {
      var pathItem = srcPaths[pathKey];
      var acl = classifyPath(pathKey, aclMap);
      var isRpc = pathKey.indexOf('/rpc/') === 0;
      var isRoot = pathKey === '/';
      var isPublic = !isRoot && !!acl.anon;
      var isMember = !isRoot && !!acl.member;
      var isAdminOnly = !isRoot && !acl.anon && !acl.member && !!acl.admin;

      if (!isRoot) {
        counts.all += 1;
        if (isPublic) counts.public += 1;
        if (isMember) counts.member += 1;
        if (isAdminOnly) counts.admin += 1;
      }

      var include = false;
      if (surface === 'all') include = true;
      else if (surface === 'public') include = isPublic;
      else if (surface === 'member') include = isMember;
      else if (surface === 'admin') include = isAdminOnly;

      if (!include) return;

      var badge = badgeFor(acl);
      var filteredItem = {};
      Object.keys(pathItem).forEach(function (method) {
        var mLower = method.toLowerCase();
        // 在 C 端视角（public / member）中，视图仅保留 GET 方法，隐藏不可执行的 POST/PATCH/DELETE
        if ((surface === 'public' || surface === 'member') && !isRpc && mLower !== 'get' && mLower !== 'parameters') {
          return;
        }
        // 在 C 端视角中，RPC 仅保留 POST 方法
        if ((surface === 'public' || surface === 'member') && isRpc && mLower !== 'post' && mLower !== 'parameters') {
          return;
        }
        var op = clone(pathItem[method]);
        if (op && typeof op === 'object' && mLower !== 'parameters' && badge) {
          var existing = op.summary || '';
          if (existing.indexOf(badge) !== 0) {
            op.summary = badge + existing;
          }
        }
        filteredItem[method] = op;
      });

      if (Object.keys(filteredItem).length > 0) {
        outPaths[pathKey] = filteredItem;
      }
    });

    spec.paths = outPaths;

    if (surface === 'public') {
      spec.host = 'localhost:9080';
      spec.basePath = '/public';
      spec.schemes = ['http'];
    } else if (surface === 'member') {
      spec.host = 'localhost:9080';
      spec.basePath = '/app';
      spec.schemes = ['http'];
    } else {
      spec.host = 'localhost:3100';
      spec.basePath = '/';
      spec.schemes = ['http'];
    }

    return { spec: spec, counts: counts };
  }

  function injectStyles() {
    if (document.getElementById('cw-swagger-surface-style')) return;
    var style = document.createElement('style');
    style.id = 'cw-swagger-surface-style';
    style.textContent =
      '#cw-surface-bar { display:flex; align-items:center; gap:6px; margin-left:14px; flex-wrap:wrap; }' +
      '.cw-surface-btn { border:1px solid rgba(255,255,255,0.28); background:rgba(255,255,255,0.08); color:#fff; ' +
      '  padding:5px 11px; border-radius:999px; font-size:12px; font-weight:600; cursor:pointer; transition:all .15s ease; white-space:nowrap; }' +
      '.cw-surface-btn:hover { background:rgba(255,255,255,0.2); }' +
      '.cw-surface-btn.active { background:#10b981; border-color:#34d399; color:#042f2e; box-shadow:0 0 0 2px rgba(16,185,129,0.25); }' +
      '.cw-surface-btn[data-surface="admin"].active { background:#f59e0b; border-color:#fbbf24; color:#451a03; }' +
      '.cw-surface-btn[data-surface="member"].active { background:#38bdf8; border-color:#7dd3fc; color:#082f49; }' +
      '.cw-surface-btn[data-surface="all"].active { background:#e2e8f0; border-color:#f8fafc; color:#0f172a; }';
    document.head.appendChild(style);
  }

  function updateBarUI(counts) {
    var bar = document.getElementById('cw-surface-bar');
    if (!bar) return;
    var labels = {
      all: '📦 全量',
      public: '🌐 用户端·公开',
      member: '👤 用户端·会员',
      admin: '🛡️ 管理端·专用'
    };
    VALID_SURFACES.forEach(function (s) {
      var btn = bar.querySelector('[data-surface="' + s + '"]');
      if (!btn) return;
      btn.className = 'cw-surface-btn' + (activeSurface === s ? ' active' : '');
      var cntText = counts && typeof counts[s] === 'number' ? ' (' + counts[s] + ')' : '';
      btn.textContent = labels[s] + cntText;
    });
  }

  function ensureSurfaceBar() {
    injectStyles();
    var wrapper = document.querySelector('.swagger-ui .topbar .topbar-wrapper');
    if (!wrapper) return false;
    if (document.getElementById('cw-surface-bar')) return true;

    var bar = document.createElement('div');
    bar.id = 'cw-surface-bar';
    VALID_SURFACES.forEach(function (s) {
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'cw-surface-btn';
      btn.setAttribute('data-surface', s);
      btn.addEventListener('click', function () {
        if (activeSurface === s) return;
        activeSurface = s;
        try { window.localStorage.setItem(STORAGE_KEY, s); } catch (e) {}
        applySurface(activeProfile, activeSurface);
      });
      bar.appendChild(btn);
    });
    wrapper.appendChild(bar);
    updateBarUI(null);
    return true;
  }

  function fetchModuleData(profile) {
    var specPromise = specCache[profile]
      ? Promise.resolve(specCache[profile])
      : fetch('/pgrst-spec/' + profile)
          .then(function (r) { return r.json(); })
          .then(function (json) { specCache[profile] = json; return json; });

    var aclPromise = aclCache[profile]
      ? Promise.resolve(aclCache[profile])
      : fetch('/pgrst-acl', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ p_schema: profile })
        })
          .then(function (r) { return r.ok ? r.json() : {}; })
          .catch(function () { return {}; })
          .then(function (json) { aclCache[profile] = json || {}; return aclCache[profile]; });

    return Promise.all([specPromise, aclPromise]);
  }

  function applySurface(profile, surface) {
    if (!window.ui || !window.ui.specActions) return;
    var myToken = ++loadingToken;
    fetchModuleData(profile).then(function (res) {
      if (myToken !== loadingToken) return;
      var built = buildFilteredSpec(res[0], res[1], surface);
      updateBarUI(built.counts);
      window.ui.specActions.updateJsonSpec(built.spec);
    }).catch(function (err) {
      console.error('[Swagger Surface] failed to apply surface:', err);
    });
  }

  window.onload = function () {
    window.ui = SwaggerUIBundle({
      urls: MODULES.map(function (m) {
        return { name: m.replace(/^api_v1_/, ''), url: '/pgrst-spec/' + m };
      }),
      'urls.primaryName': MODULES[0].replace(/^api_v1_/, ''),
      dom_id: '#swagger-ui',
      deepLinking: true,
      filter: true,
      tryItOutEnabled: true,
      requestInterceptor: function (req) {
        var p = profileFromUrl(req.url);
        if (p) {
          activeProfile = p;
        }
        if (req.url && req.url.indexOf('/pgrst-acl') === -1) {
          req.headers['Accept-Profile'] = activeProfile;
          if (req.method && req.method.toUpperCase() === 'POST') {
            req.headers['Content-Profile'] = activeProfile;
          }
        }
        return req;
      },
      onComplete: function () {
        ensureSurfaceBar();
        applySurface(activeProfile, activeSurface);
      },
      presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
      plugins: [SwaggerUIBundle.plugins.DownloadUrl],
      layout: 'StandaloneLayout'
    });

    // 兜底监听顶栏渲染与模块下拉切换
    var tries = 0;
    var timer = setInterval(function () {
      tries += 1;
      if (ensureSurfaceBar() || tries > 30) {
        clearInterval(timer);
      }
    }, 200);
  };
})();
