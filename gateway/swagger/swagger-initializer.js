// =============================================================================
// Swagger UI 多模块初始化器（OmniPG × citywalk PostgREST）
// 机制：PostgREST v14 多 schema（db-schemas）的 OpenAPI spec 按 profile 提供——
//       GET / 默认只返回第一个 schema；带 `Accept-Profile: api_v1_<module>` 头
//       则返回对应模块的完整 spec。Swagger UI 原生不支持该头，因此：
//       ① 每个模块一个 spec URL（用 #profile= 片段编码模块名，fragment 不发给服务端）
//       ② requestInterceptor 从 URL 提取模块名注入 Accept-Profile 头
//       ③ try-it-out 请求无 ?profile= 标记，复用最近一次 spec 加载的模块
// 新增模块：在 MODULES 数组加一行即可（保持与部署 compose 的 PGRST_DB_SCHEMAS 一致）。
// =============================================================================
(function () {
  var PGRST = 'http://localhost:3100';
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
    'api_v1_fraud'
  ];

  var activeProfile = MODULES[0];
  // 模块名编码在 fragment（#profile=...）——query 参数（?profile=...）会被 PostgREST
  // 当作过滤器解析报 PGRST100；fragment 不随请求发给服务端，仅拦截器内部解析后剥离
  function profileFromUrl(url) {
    var m = /#?profile=([\w.]+)/.exec(url || '');
    return m ? m[1] : null;
  }

  window.onload = function () {
    window.ui = SwaggerUIBundle({
      urls: MODULES.map(function (m) {
        return { name: m.replace(/^api_v1_/, ''), url: PGRST + '/#profile=' + m };
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
          // 剥离 fragment，服务端收到干净的 /
          req.url = req.url.replace(/#.*$/, '');
        }
        req.headers['Accept-Profile'] = activeProfile;
        return req;
      },
      presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
      plugins: [SwaggerUIBundle.plugins.DownloadUrl],
      layout: 'StandaloneLayout'
    });
  };
})();
