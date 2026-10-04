// 引擎 B 测试：Windows WebView2 --proxy-server 环境跟随（WebviewSourceNetwork）。
//
// 覆盖：
// 1. 纯函数：windowsProxyServerArg（http/socks5 形态）、stableHash（确定性/
//    区分度/格式）。
// 2. applyForSource/releaseForSource 真链路（manualProxy 与 hosts/DoH 源）：
//    - 测试宿主（非真实 app 进程）：ProxyController 的 MethodChannel 无 handler
//      → _setProxy 失败；Windows 上 _ensureWindowsEnv 的 path_provider 亦无
//      handler → 返回 null（best-effort）。
//    - 断言：不抛异常、refCount 不涨（activeEnvironment 恒 null）、release
//      幂等、无网络覆盖的源不进任何分支。
//
// 环境创建与 cookie 桥的真机行为（WebView2 环境创建成功/cookie 双向同步）桌面
// 沙箱无法端到端验证，由用户真机验证。
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/runtime/webview_source_network.dart';

PluginConfig buildSource({
  String? proxyHost,
  int? proxyPort,
  String proxyProtocol = 'http',
  List<String> hosts = const [],
}) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': 'pms_webview_net_test',
      'name': 'webview-net-test',
      'type': 'animeSource',
      'site': {'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {
        'latest': {'url': '/latest?page={page}'},
      },
      if (proxyHost != null)
        'network': {
          'proxy': {
            'mode': 'manual',
            'protocol': proxyProtocol,
            'host': proxyHost,
            'port': proxyPort,
          },
          if (hosts.isNotEmpty)
            'hosts': [
              for (final h in hosts)
                {'host': h, 'ip': '172.64.229.154', 'enabled': true},
            ],
        },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // MethodChannel 无 handler：ProxyController 调用走 MissingPluginException
    // → _setProxy 回 false → 进入被测的 Windows env 分支。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.pichillilorenzo/flutter_webview_proxy'),
      null,
    );
  });

  group('WebviewSourceNetwork Windows 纯函数', () {
    test('windowsProxyServerArg：http → host:port，socks5 → socks5:// 前缀',
        () {
      expect(WebviewSourceNetwork.windowsProxyServerArg('127.0.0.1', 7890),
          '127.0.0.1:7890');
      expect(
          WebviewSourceNetwork.windowsProxyServerArg('10.0.0.2', 1080,
              socks5: true),
          'socks5://10.0.0.2:1080');
    });

    test('stableHash：确定性 + 不同输入区分 + 8 位十六进制格式', () {
      final a1 = WebviewSourceNetwork.stableHash('--proxy-server=127.0.0.1:1');
      final a2 = WebviewSourceNetwork.stableHash('--proxy-server=127.0.0.1:1');
      final b = WebviewSourceNetwork.stableHash('--proxy-server=127.0.0.1:2');
      expect(a1, a2); // 确定性：同一输入跨进程/跨重启稳定
      expect(a1, isNot(b)); // 不同参数区分（不同 userDataFolder）
      expect(a1, matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(WebviewSourceNetwork.stableHash(''), '811c9dc5'); // FNV-1a 空串偏移基值
      expect(
          WebviewSourceNetwork.stableHash('a'),
          isNot(
              WebviewSourceNetwork.stableHash('ab'))); // 高低字节各一轮生效
    });

    test('windowsBrowserArgs：proxy/maps 组合与空输入', () {
      // 空：直连无覆盖 → 空串（保持旧行为：无参数 env）。
      expect(WebviewSourceNetwork.windowsBrowserArgs(), '');
      // 仅代理（manualProxy 分支形态）。
      expect(WebviewSourceNetwork.windowsBrowserArgs(proxyArg: '1.2.3.4:7890'),
          '--proxy-server=1.2.3.4:7890');
      // 仅 hosts MAP（无代理直连形态）。值含空格必须整体加引号，否则 WebView2
      // 命令行按空格切碎、规则全失效；EXCLUDE 与主机名之间须有空格（规则按
      // 空格分词，EXCLUDElocalhost 是非法 token）。
      expect(
          WebviewSourceNetwork.windowsBrowserArgs(hostMaps: [
            'MAP example.com 172.64.229.154'
          ]),
          '--host-resolver-rules="MAP example.com 172.64.229.154,EXCLUDE localhost"');
      // 双通路并存（hosts 源形态）：代理 + resolver-rules 同串。
      final both = WebviewSourceNetwork.windowsBrowserArgs(
          proxyArg: '127.0.0.1:18975',
          hostMaps: ['MAP a.com 1.1.1.1', 'MAP b.com 2.2.2.2']);
      expect(both,
          '--proxy-server=127.0.0.1:18975 --host-resolver-rules="MAP a.com 1.1.1.1,MAP b.com 2.2.2.2,EXCLUDE localhost"');
      // 确定性：同输入恒同输出（env 缓存 key 稳定的前提）。
      expect(
          WebviewSourceNetwork.windowsBrowserArgs(
              proxyArg: 'x:1', hostMaps: ['MAP a.com 1.1.1.1']),
          WebviewSourceNetwork.windowsBrowserArgs(
              proxyArg: 'x:1', hostMaps: ['MAP a.com 1.1.1.1']));
    });

    test('hostResolverRules：过滤/去重/排序/首 IP 优先', () {
      HostsEntry entry(String host, String ip, {bool enabled = true}) =>
          HostsEntry(host: host, ip: ip, enabled: enabled);
      final rules = WebviewSourceNetwork.hostResolverRules([
        entry('Hanime1.me', '172.64.229.154'), // host 大小写归一
        entry('javchu.com', '2.59.170.20'),
        entry('javchu.com', '104.219.250.37'), // 同 host 多 IP：取首个
        entry('disabled.com', '1.1.1.1', enabled: false), // disabled 剔除
        entry('', '1.1.1.1'), // 空 host 剔除
        entry('noip.com', ''), // 空 ip 剔除
      ]);
      expect(rules, [
        'MAP hanime1.me 172.64.229.154',
        'MAP javchu.com 2.59.170.20',
      ]); // 字典序排序 + 去重
      expect(WebviewSourceNetwork.hostResolverRules(const []), isEmpty);
    });
  });

  group('WebviewSourceNetwork applyForSource 行为守卫', () {
    test('无网络覆盖的源：apply/release 直通，activeEnvironment 恒 null', () async {
      final net = WebviewSourceNetwork.instance;
      final source = buildSource(); // 无 network 块 → effectiveFor 走全局/默认
      await net.applyForSource(source);
      expect(net.activeEnvironment, isNull);
      await net.releaseForSource();
      expect(net.activeEnvironment, isNull);
    });

    test('manualProxy 源（测试宿主）：_setProxy 失败→env 创建失败→不抛、refCount 不涨',
        () async {
      final net = WebviewSourceNetwork.instance;
      final source = buildSource(proxyHost: '127.0.0.1', proxyPort: 18975);
      // 不抛异常即通过（best-effort 契约）。
      await net.applyForSource(source);
      expect(net.activeEnvironment, isNull); // env 创建失败 → refCount 不涨
      await net.releaseForSource(); // 幂等：refCount==0 时 no-op
      await net.releaseForSource();
      expect(net.activeEnvironment, isNull);
    });

    test('hosts/DoH 源（测试宿主）：本地代理可起、_setProxy 失败→env 路径不抛',
        () async {
      final net = WebviewSourceNetwork.instance;
      final source = buildSource(hosts: ['example.com']);
      await net.applyForSource(source);
      expect(net.activeEnvironment, isNull);
      await net.releaseForSource();
      expect(net.activeEnvironment, isNull);
    });

    test('apply(null)：直接返回，无副作用', () async {
      final net = WebviewSourceNetwork.instance;
      await net.applyForSource(null);
      expect(net.activeEnvironment, isNull);
    });
  });

  group('CONNECT 目标解析（HTTPS 隧道 host:port）', () {
    // dart:io 对 CONNECT 的 uri 解析有坑：实测 `CONNECT hanime1.me:443` 得到
    // scheme=`hanime1.me` / path=`443` / host=authority=空串。原实现因此算出
    // host='' → Socket.connect('', 443) → Windows errno 1225，WebView 经本地
    // 代理的所有 HTTPS 流量全灭（设备日志 8 条 tunnel(:443) failed）。
    // 唯一可靠来源是 Host 头。这里用真实 loopback HttpServer 收 CONNECT 请求，
    // 在 handler 内直接断言解析结果。
    Future<(String, int)> captureConnectTarget(
      String requestLine, {
      List<String> extraHeaders = const [],
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final completer = Completer<(String, int)>();
      server.listen((req) {
        try {
          completer.complete(
            WebviewSourceNetwork.instance.debugParseConnectTarget(req, 443),
          );
        } on Object catch (e, st) {
          if (!completer.isCompleted) completer.completeError(e, st);
        }
        req.response.statusCode = 200;
        req.response.close();
      });
      final sock = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      sock.write('$requestLine\r\n');
      for (final h in extraHeaders) {
        sock.write('$h\r\n');
      }
      sock.write('\r\n');
      await sock.flush();
      try {
        return await completer.future.timeout(const Duration(seconds: 10));
      } finally {
        sock.destroy();
        await server.close(force: true);
      }
    }

    test('Host 头带端口：解析出真实 host（修复前为空串）', () async {
      final (host, port) = await captureConnectTarget(
        'CONNECT hanime1.me:443 HTTP/1.1',
        extraHeaders: const ['Host: hanime1.me:443'],
      );
      expect(host, 'hanime1.me');
      expect(port, 443);
    });

    test('Host 头不带端口：回落默认端口', () async {
      final (host, port) = await captureConnectTarget(
        'CONNECT example.com:8443 HTTP/1.1',
        extraHeaders: const ['Host: example.com'],
      );
      expect(host, 'example.com');
      expect(port, 8443, reason: 'Host 无端口时用 defaultPort 兜底');
    });

    test('非 443 端口原样保留（用于非常规 HTTPS 端口站点）', () async {
      final (host, port) = await captureConnectTarget(
        'CONNECT cdn.test:8443 HTTP/1.1',
        extraHeaders: const ['Host: cdn.test:8443'],
      );
      expect(host, 'cdn.test');
      expect(port, 8443);
    });

    test('IPv6 字面量：方括号与端口正确拆解（纯函数，socket 无法承载该形态）',
        () {
      // `CONNECT [::1]:8443` 这种 request-line 会被 dart:io 的 URL 解析直接拒掉
      // （handler 根本不触发），只能直接覆盖解析器。
      expect(
        WebviewSourceNetwork.debugSplitHostPort('[::1]:8443', 443),
        ('::1', 8443),
      );
      expect(
        WebviewSourceNetwork.debugSplitHostPort('[2001:db8::1]', 443),
        ('2001:db8::1', 443),
      );
      // 无端口 → 回落 defaultPort；纯端口串 → 缺 host、只补端口。
      expect(
        WebviewSourceNetwork.debugSplitHostPort('hanime1.me', 8443),
        ('hanime1.me', 8443),
      );
      expect(
        WebviewSourceNetwork.debugSplitHostPort('8443', 443),
        ('', 8443),
      );
      // 非法端口（越界/非数字）不冒充端口，回落 defaultPort。
      expect(
        WebviewSourceNetwork.debugSplitHostPort('a.test:99999', 443),
        ('a.test', 443),
      );
      expect(
        WebviewSourceNetwork.debugSplitHostPort('a.test:abc', 443),
        ('a.test', 443),
      );
      expect(WebviewSourceNetwork.debugSplitHostPort('', 443), ('', 443));
      expect(WebviewSourceNetwork.debugSplitHostPort(null, 443), ('', 443));
    });

    test('defaultPort 随调用方传入（非 443 的 CONNECT 场景）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final completer = Completer<(String, int)>();
      server.listen((req) {
        completer.complete(
          WebviewSourceNetwork.instance.debugParseConnectTarget(req, 8080),
        );
        req.response.statusCode = 200;
        req.response.close();
      });
      final sock =
          await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      sock.write('CONNECT plain.test HTTP/1.1\r\nHost: plain.test\r\n\r\n');
      await sock.flush();
      try {
        final (host, port) =
            await completer.future.timeout(const Duration(seconds: 10));
        expect(host, 'plain.test');
        expect(port, 8080);
      } finally {
        sock.destroy();
        await server.close(force: true);
      }
    });
  });

  // 真机行为（用户验证）：Windows 上 env 创建成功后——
  // * activeEnvironment 非 null 且 release 归零后回 null；
  // * 同 proxyArg 复用缓存环境（_windowsEnvs 命中）；
  // * SilentHtmlCapture 挂 env 后 cookie 双向桥：_preInjectCookies（jar→env）
  //   与 _syncCookies（env→jar）使 cf_clearance 会话贯通；
  // * 代理常驻：release 不停本地代理（端口稳定，env 缓存可复用）。
}
