// =============================================================================
// Swagger UI 多模块初始化器（OmniPG × citywalk PostgREST）
// 机制：PostgREST v14 多 schema（db-schemas）的 OpenAPI spec 按 profile 提供——
//       GET / 默认只返回第一个 schema；带 `Accept-Profile: api_v1_<module>` 头
//       则返回对应模块的完整 spec。Swagger UI 无法为 spec 拉取带自定义头
//       （fragment 会被改写成 query、query 会被 PostgREST 当过滤器解析），
//       因此由本容器 nginx 的 /pgrst-spec/<module> location 注入该头（见
//       gateway/swagger/default.conf），spec URL 全部走同源路径。
//       try-it-out 请求指向 spec 的 servers（PostgREST :3100 直连），
//       requestInterceptor 按最近一次 spec 加载的模块补注 Accept-Profile 头。
// 新增模块：MODULES 数组加一行，并保持与部署 compose 的 PGRST_DB_SCHEMAS 一致。
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
    'api_v1_ai'
  ];

  var activeProfile = MODULES[0];
  function profileFromUrl(url) {
    var m = /pgrst-spec\/([\w.]+)/.exec(url || '');
    return m ? m[1] : null;
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
        if (p) { activeProfile = p; }
        req.headers['Accept-Profile'] = activeProfile;
        return req;
      },
      presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
      plugins: [SwaggerUIBundle.plugins.DownloadUrl],
      layout: 'StandaloneLayout'
    });
  };
})();
