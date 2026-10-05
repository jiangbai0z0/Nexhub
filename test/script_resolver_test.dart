import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/resolver/js_context.dart';
import 'package:nexhub/core/resolver/script_resolver.dart';
import 'package:nexhub/core/resolver/webview_resolver.dart';
import 'package:nexhub/core/scraper/verification_detector.dart';

/// 测试用宿主桥（所有方法返回空桩，run 不依赖真实网络）。
class _StubBridge implements JsHostBridge {
  const _StubBridge();
  @override
  Future<String> httpGet(String url, {Map<String, String>? headers}) async => '';
  @override
  Future<dynamic> httpGetJson(String url, {Map<String, String>? headers}) async => <String, dynamic>{};
  @override
  Future<String> httpPost(String url, String body, {Map<String, String>? headers}) async => '';
  @override
  Future<String> httpPostForm(String url, Map<String, String> params,
      {Map<String, String>? headers}) async => '';
  @override
  String? query(String html, String selector) => null;
  @override
  List<String> queryAll(String html, String selector) => const [];
  @override
  String? queryAttr(String html, String selector, String attr) => null;
  @override
  String? queryXPath(String html, String xpath) => null;
  @override
  String? queryHtml(String html, String selector) => null;
  @override
  String contentClean(String html) => html;
  @override
  String md5(String s) => s;
  @override
  String base64Encode(String s) => s;
  @override
  String base64Decode(String s) => s;
  @override
  String rc4(String data, String key) => data;
  @override
  String aesDecrypt(String cipherBase64, String key, String iv) => '';
  @override
  String resolveUrl(String relative) => relative;
  @override
  void log(String msg) {}

  // ---- crypto extension stubs ----
  @override
  String sha1(String s) => '';
  @override
  String sha256(String s) => '';
  @override
  String sha512(String s) => '';
  @override
  String hmac(String key, String data, {String algorithm = 'sha256'}) => '';
  @override
  String hexEncode(List<int> bytes) => '';
  @override
  List<int> hexDecode(String hex) => const <int>[];
  @override
  String aesEcb(String key, String data,
      {bool encrypt = true, String encoding = 'base64'}) => '';
  @override
  String aesCbc(String key, String data, String iv,
      {bool encrypt = true, String encoding = 'base64'}) => '';
  @override
  String aesCfb(String key, String data, String iv,
      {bool encrypt = true, String encoding = 'base64'}) => '';
  @override
  String aesOfb(String key, String data, String iv,
      {bool encrypt = true, String encoding = 'base64'}) => '';

  // ---- image extension stubs ----
  @override
  List<String> extractImagesFromHtml(String html, {String? selector}) => const [];
  @override
  List<String> extractLazyImagesFromHtml(String html, {String? selector}) => const [];
  @override
  bool isValidImageUrl(String url) => false;
  @override
  String? guessFormat(String url, {List<int>? bytes}) => null;
  @override
  List<String> filterImages(List<String> urls,
      {Map<String, dynamic>? rules}) => const [];
  @override
  List<String> getPageUrls(String html, Map<String, dynamic> config) => const [];

  // ---- storage extension stubs ----
  @override
  String? storageGet(String key) => null;
  @override
  void storageSet(String key, String value) {}
  @override
  void storageRemove(String key) {}

  // ---- http extension stubs ----
  @override
  Future<String> httpPut(String url, String body,
      {Map<String, String>? headers}) async => '';
  @override
  Future<String> httpDelete(String url, {Map<String, String>? headers}) async => '';
  @override
  Future<Map<String, dynamic>> httpFetch(String url,
      {String method = 'GET',
      Map<String, String>? headers,
      String? body}) async => <String, dynamic>{};
  @override
  Future<void> utilsSetTimeout(int ms) async {}
}

/// 可注入的假引擎：直接返回预设数据（或抛错），无需真实 JS 运行时。
class FakeJsEngine implements JsEngine {
  FakeJsEngine(this._data, {this.throws = false});
  final dynamic _data;
  final bool throws;

  @override
  JsHostBridge get bridge => const _StubBridge();

  @override
  Future<dynamic> run(String script, String function, List<dynamic> args) async {
    if (throws) throw Exception('boom');
    return _data;
  }

  @override
  void injectContext(Map<String, String> vars) {}

  @override
  void dispose() {}
}

/// 预取层验证墙桥：httpGet/httpGetJson 必抛 VerificationRequiredException
/// （模拟 CF 403）。json/html 两条预取通道都要拦——responseTypeFor 缺省即 json。
class _VerifyWallBridge extends _StubBridge {
  const _VerifyWallBridge();
  @override
  Future<String> httpGet(String url, {Map<String, String>? headers}) async =>
      throw VerificationRequiredException(url: url, statusCode: 403);
  @override
  Future<dynamic> httpGetJson(String url, {Map<String, String>? headers}) async =>
      throw VerificationRequiredException(url: url, statusCode: 403);
}

/// 走验证墙桥的假引擎：预取撞墙；run 返回预设数据
/// （预设空 = 脚本消费空 raw 空产出；预设非空 = 脚本自救成功）。
class _VerifyWallEngine extends FakeJsEngine {
  _VerifyWallEngine(super._data);
  @override
  JsHostBridge get bridge => const _VerifyWallBridge();
}

PluginConfig get _source => PluginConfig.fromJson(<String, dynamic>{
      'id': 'fake', 'name': 'fake', 'type': 'animeSource',
      'site': {'baseUrl': 'https://x.com'},
      'parser': {
        'type': 'script',
        'entrypoints': {'latest': 'parseLatest', 'detail': 'parseDetail'},
        'script': 'function parseLatest(html, context){ return []; }',
      },
      'routes': {'latest': {'url': '/l'}, 'detail': {'url': '/d'}},
    });

void main() {
  group('ScriptResolver', () {
    test('maps list result to List<MediaItem>', () async {
      final resolver = ScriptResolver(
        engineFactory: (_) => FakeJsEngine(<dynamic>[
          {'id': '1', 'title': 'A', 'cover': 'c.png'},
          {'id': '2', 'title': 'B'},
        ]),
      );
      final items = await resolver.resolve(_source, 'latest')
          as List<MediaItem>;
      expect(items.length, 2);
      expect(items.first.title, 'A');
      expect(items.first.coverUrl, 'c.png');
    });

    test('maps detail result to MediaItem', () async {
      final resolver = ScriptResolver(
        engineFactory: (_) => FakeJsEngine(<String, dynamic>{
          'id': '1',
          'title': 'Detail',
          'detail': '/d/1',
        }),
      );
      final item = await resolver.resolve(_source, 'detail') as MediaItem;
      expect(item.title, 'Detail');
      expect(item.detailUrl, '/d/1');
    });

    test('error isolation: engine throws -> SourceResolveException (not crash)', () async {
      final resolver = ScriptResolver(
        engineFactory: (_) => FakeJsEngine(null, throws: true),
      );
      expect(
        () => resolver.resolve(_source, 'latest'),
        throwsA(isA<SourceResolveException>()),
      );
    });

    test('uses hybrid override entrypoint for video', () async {
      final hybridSource = PluginConfig.fromJson(<String, dynamic>{
        'id': 'h', 'name': 'h', 'type': 'animeSource',
        'site': {'baseUrl': 'https://x.com'},
        'parser': {
          'type': 'hybrid',
          'overrides': {
            'video': {'type': 'script', 'entrypoints': {'video': 'parseVideo'}},
          },
        },
        'routes': {'video': {'url': '/v'}},
      });
      var capturedEntry = '';
      final resolver = ScriptResolver(
        engineFactory: (source) => _CapturingEngine(
          (fn) => capturedEntry = fn,
          <String, dynamic>{'url': 'https://v/1', 'type': 'mp4'},
        ),
      );
      final video = await resolver.resolve(hybridSource, 'video') as VideoResult;
      expect(capturedEntry, 'parseVideo');
      expect(video.url, 'https://v/1');
    });

    test('injects route vars into engine context', () async {
      final captured = <String, String>{};
      final resolver = ScriptResolver(
        engineFactory: (_) => _InjectCaptureEngine(captured),
      );
      await resolver.resolve(_source, 'latest',
          vars: <String, String>{'page': '2', 'category': 'kr'});
      expect(captured['page'], '2');
      expect(captured['category'], 'kr');
    });

    test('useWebview 脚本源直接执行脚本：不再抛 WebViewHtmlRequest', () async {
      // 旧行为（已移除）：对 useWebview 源无条件抛 WebViewHtmlRequest 强制
      // WebView 渲染——但脚本源通常自行 ctx.http 抓取、不消费渲染 HTML，
      // WebView 毫无意义且反爬站点上 InAppWebView 数秒后 native 崩溃。
      // 现契约（resolve() 注释）：脚本直接执行；需要渲染后 HTML 的声明式源
      // 由 ResolverRegistry 派发 WebViewResolver，不经过本解析器。
      final useWebviewSource = PluginConfig.fromJson(<String, dynamic>{
        'id': 'uwv', 'name': 'uwv', 'type': 'mangaSource',
        'site': {'baseUrl': 'https://x.com'},
        'useWebview': true,
        'parser': {
          'type': 'hybrid',
          'overrides': {
            'latest': {'type': 'script', 'entrypoints': {'latest': 'parseList'}},
          },
        },
        'routes': {'latest': {'url': '/l'}},
      });
      var factoryCalled = false;
      final resolver = ScriptResolver(
        engineFactory: (_) {
          factoryCalled = true;
          return FakeJsEngine(<dynamic>[
            {'id': '1', 'title': 'Direct'},
          ]);
        },
      );
      final items = await resolver.resolve(useWebviewSource, 'latest')
          as List<MediaItem>;
      // 脚本必须被执行（short-circuit 已移除），且产出正常返回。
      expect(factoryCalled, isTrue,
          reason: 'short-circuit 移除后引擎工厂必须被调用');
      expect(items, hasLength(1));
      expect(items.first.title, 'Direct');
    });

    test('预取撞验证墙 + 脚本空产出 → 重抛 VerificationRequiredException（真机 /watch 403 案）', () async {
      // 复刻 hanime 家族源形态：脚本消费预取 raw（不自抓），CF 403 → 空 raw
      // → 空产出。修复前此场景静默吞成空列表（用户看不到验证入口）。
      final resolver = ScriptResolver(
        engineFactory: (_) => _VerifyWallEngine(<dynamic>[]),
      );
      await expectLater(
        resolver.resolve(_source, 'latest'),
        throwsA(isA<VerificationRequiredException>()),
      );
    });

    test('预取撞验证墙但脚本自救产出 → 不误伤，正常返回列表', () async {
      // 自抓型脚本（ctx.http.get 自取数据）在预取失败时仍能产出：
      // 重抛逻辑只允许在「空产出」时触发，不得殃及自救成功的脚本。
      final resolver = ScriptResolver(
        engineFactory: (_) => _VerifyWallEngine(<dynamic>[
          {'id': '1', 'title': 'self-rescued'},
        ]),
      );
      final items = await resolver.resolve(_source, 'latest')
          as List<MediaItem>;
      expect(items.length, 1);
      expect(items.first.title, 'self-rescued');
    });

    test('无验证墙 + 脚本空产出 → 保持空列表（空结果本身不报错）', () async {
      // 回归锁：重抛只绑定「验证墙 + 空产出」组合。普通空结果
      // （结构变化/无数据）必须维持原静默语义，不得升级成异常。
      final resolver = ScriptResolver(
        engineFactory: (_) => FakeJsEngine(<dynamic>[]),
      );
      final items = await resolver.resolve(_source, 'latest')
          as List<MediaItem>;
      expect(items, isEmpty);
    });

    test('resolveFromHtml passes rendered HTML as raw to script entry', () async {
      final capturedArgs = <dynamic>[];
      final resolver = ScriptResolver(
        engineFactory: (_) => _ArgsCaptureEngine(
          capturedArgs,
          <dynamic>[
            {'id': '1', 'title': 'A', 'cover': 'c.png'},
          ],
        ),
      );
      final items = await resolver.resolveFromHtml(
        _source,
        'latest',
        '<html>rendered</html>',
      ) as List<MediaItem>;
      expect(items.length, 1);
      expect(items.first.title, 'A');
      expect(items.first.coverUrl, 'c.png');
      // Verify HTML was passed as the raw argument (single-arg unwrapped).
      expect(capturedArgs.length, 1);
      expect(capturedArgs.first, '<html>rendered</html>');
    });

    test('resolveFromHtml does not trigger WebViewHtmlRequest for useWebview source', () async {
      // resolveFromHtml is the post-render reentry point: it MUST NOT re-throw
      // WebViewHtmlRequest (would cause infinite loop). Verifies that even when
      // source.useWebview==true, resolveFromHtml executes the script directly.
      final useWebviewSource = PluginConfig.fromJson(<String, dynamic>{
        'id': 'uwv2', 'name': 'uwv2', 'type': 'mangaSource',
        'site': {'baseUrl': 'https://x.com'},
        'useWebview': true,
        'parser': {
          'type': 'hybrid',
          'overrides': {
            'latest': {'type': 'script', 'entrypoints': {'latest': 'parseList'}},
          },
        },
        'routes': {'latest': {'url': '/l'}},
      });
      final resolver = ScriptResolver(
        engineFactory: (_) => FakeJsEngine(<dynamic>[
          {'id': '1', 'title': 'Rendered'},
        ]),
      );
      final items = await resolver.resolveFromHtml(
        useWebviewSource,
        'latest',
        '<html>rendered</html>',
      ) as List<MediaItem>;
      expect(items.length, 1);
      expect(items.first.title, 'Rendered');
    });

    group('meta 预取地址解析与安全校验', () {
      test('根相对路径拼接到 base，绝对地址原样保留', () {
        expect(
          ScriptResolver.debugResolveMetaFetchUrl(
              '/vodplay/1-1-1.html', 'https://www.dmwo.one'),
          'https://www.dmwo.one/vodplay/1-1-1.html',
        );
        expect(
          ScriptResolver.debugResolveMetaFetchUrl(
              'https://cdn.example.com/x.json', 'https://x.com'),
          'https://cdn.example.com/x.json',
        );
        // scheme 相对：沿用 base 的 https。
        expect(
          ScriptResolver.debugResolveMetaFetchUrl('//cdn.example.com/x',
              'https://x.com'),
          'https://cdn.example.com/x',
        );
      });

      test('非 http(s) 与 localhost/私有/保留地址一律拒绝（返回空串）', () {
        expect(ScriptResolver.debugResolveMetaFetchUrl('file:///etc/passwd',
            'https://x.com'), '');
        expect(ScriptResolver.debugResolveMetaFetchUrl('ftp://x.com/y',
            'https://x.com'), '');
        expect(ScriptResolver.debugResolveMetaFetchUrl('http://localhost/x',
            'https://x.com'), '');
        expect(ScriptResolver.debugResolveMetaFetchUrl('http://127.0.0.1/x',
            'https://x.com'), '');
        expect(ScriptResolver.debugResolveMetaFetchUrl('http://10.0.0.9/x',
            'https://x.com'), '');
        expect(ScriptResolver.debugResolveMetaFetchUrl('http://192.168.1.2/x',
            'https://x.com'), '');
        expect(ScriptResolver.debugResolveMetaFetchUrl('http://172.20.3.4/x',
            'https://x.com'), '');
        expect(ScriptResolver.debugResolveMetaFetchUrl('http://169.254.1.9/x',
            'https://x.com'), '');
        // 环回的 IPv4-mapped IPv6 形态同样拒绝。
        expect(ScriptResolver.debugResolveMetaFetchUrl(
            'http://[::ffff:127.0.0.1]/x', 'https://x.com'), '');
        // 公网地址不受影响。
        expect(ScriptResolver.debugResolveMetaFetchUrl('http://8.8.8.8/x',
            'https://x.com'), 'http://8.8.8.8/x');
      });

      test('meta fetchUrl 安全校验不过 → 该跳降级为空结果，不发起请求', () async {
        final resolver = ScriptResolver(
          engineFactory: (_) => FakeJsEngine(<String, dynamic>{
            '__meta': true,
            '__fetchUrl': 'http://127.0.0.1/vodplay/1-1-1.html',
            '__fetchResponseType': 'text',
            '__processor': '__processAltLine',
          }),
        );
        final items = await resolver.resolve(_source, 'latest')
            as List<MediaItem>;
        expect(items, isEmpty);
      });
    });
  });
}

/// 捕获被调用函数名的假引擎。
class _CapturingEngine implements JsEngine {
  _CapturingEngine(this._onRun, this._data);
  final void Function(String fn) _onRun;
  final dynamic _data;

  @override
  JsHostBridge get bridge => const _StubBridge();

  @override
  Future<dynamic> run(String script, String function, List<dynamic> args) async {
    _onRun(function);
    return _data;
  }

  @override
  void injectContext(Map<String, String> vars) {}

  @override
  void dispose() {}
}

/// 记录 injectContext 入参的假引擎（验证路由层 vars 已注入 JS context）。
class _InjectCaptureEngine implements JsEngine {
  _InjectCaptureEngine(this._captured);
  final Map<String, String> _captured;

  @override
  JsHostBridge get bridge => const _StubBridge();

  @override
  Future<dynamic> run(String script, String function, List<dynamic> args) async =>
      <dynamic>[];

  @override
  void injectContext(Map<String, String> vars) => _captured.addAll(vars);

  @override
  void dispose() {}
}

/// 捕获传给脚本入口的 raw 参数（验证 resolveFromHtml 透传 HTML）。
class _ArgsCaptureEngine implements JsEngine {
  _ArgsCaptureEngine(this._captured, this._data);
  final List<dynamic> _captured;
  final dynamic _data;

  @override
  JsHostBridge get bridge => const _StubBridge();

  @override
  Future<dynamic> run(String script, String function, List<dynamic> args) async {
    _captured.addAll(args);
    return _data;
  }

  @override
  void injectContext(Map<String, String> vars) {}

  @override
  void dispose() {}
}
