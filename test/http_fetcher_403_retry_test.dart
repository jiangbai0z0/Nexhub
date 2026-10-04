// 引擎 A（用户拍板 1.A）：无 body 的纯硬 403 在验证提示前退避重试。
//
// HttpFetcher 是单例+私有构造，测试通过 loopback HttpServer 发起真实 HTTP：
// TestWidgetsFlutterBinding 默认装「假 HttpClient」挡真实联网，
// `HttpOverrides.global = null` 恢复（同 debug_source_probe_test 范式）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/network/model/effective_network_profile.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/model/source_network_config.dart';
import 'package:nexhub/core/scraper/http_fetcher.dart';
import 'package:nexhub/core/scraper/verification_detector.dart';
import 'package:nexhub/core/services/config_loader.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  setUpAll(() {
    // 恢复真实网络：flutter test 的绑定默认全局假 HttpClient（一律 400）。
    HttpOverrides.global = null;
    // 关掉隐身延迟，测试不必等 300~1100ms 随节拍（退避时长由 403 分支自证）。
    ConfigLoader.instance.setStealthMode(false);
  });

  setUp(() {
    // 单例跨测试污染清理：所有用例的 host 都是 127.0.0.1（端口不属于 host），
    // 上一个测试抛 VerificationRequiredException 前会写入 20s 验证冷却并残留。
    // 写入「已过期」冷却，_throttleHost 会在到期清理路径上立即移除它
    // （HttpFetcher 无公开清空 API，setVerifyCooldown 是测试可见接口）。
    HttpFetcher.instance.setVerifyCooldown(
      '127.0.0.1',
      DateTime.now().subtract(const Duration(seconds: 1)),
    );
  });

  /// 起一个按脚本应答的 loopback 服务器，返回 (url, 关闭钩子)。
  /// 脚本耗尽后持续重复最后一步（持续失败场景无需枚举无数条）。
  Future<(String, Future<void> Function())> startServer(
    List<({int status, String body})> script,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var i = 0;
    server.listen((req) async {
      final idx = i < script.length ? i : script.length - 1;
      i++;
      final step = script[idx];
      req.response.statusCode = step.status;
      req.response.headers.set('content-type', 'text/html; charset=utf-8');
      // 用 add 写真字节；write() 会对参数 toString()，把空字节列表写成 "[]"，
      // 使「无 body 403」变成非空幻影体，破坏重试语义。
      req.response.add(utf8.encode(step.body));
      await req.response.close();
    });
    return (
      'http://127.0.0.1:${server.port}/probe',
      () async {
        await server.close(force: true);
      }
    );
  }

  test('纯 403（无 body）：退避重试后放行，不再抛验证异常', () async {
    final (url, close) = await startServer(const [
      (status: 403, body: ''),
      (status: 403, body: ''),
      (status: 200, body: '<html><body>ok</body></html>'),
    ]);
    try {
      final sw = Stopwatch()..start();
      final body = await HttpFetcher.instance.getHtml(url);
      sw.stop();
      expect(body, contains('ok'));
      // 两次递增退避（1500+ 与 3000+ 毫秒）至少应耗 ~4s。
      expect(sw.elapsed.inMilliseconds, greaterThan(3500));
      expect(sw.elapsed.inMilliseconds, lessThan(15000));
      // 冷却清理：重试成功后同站紧随请求不被 20s 验证冷却拖住。
      final sw2 = Stopwatch()..start();
      await HttpFetcher.instance.getHtml(url);
      sw2.stop();
      expect(sw2.elapsed.inMilliseconds, lessThan(3000));
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('403 持续失败：重试耗尽后仍抛 VerificationRequiredException', () async {
    final (url, close) = await startServer(
      List.filled(6, const (status: 403, body: '')),
    );
    try {
      final sw = Stopwatch()..start();
      await expectLater(
        HttpFetcher.instance.getHtml(url),
        throwsA(
          isA<VerificationRequiredException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.body, 'body', ''),
        ),
      );
      sw.stop();
      // 3 次尝试 + 2 次退避 ≈ 4.5s+jitter。
      expect(sw.elapsed.inMilliseconds, greaterThan(3500));
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('403 带挑战体（turnstile）：不重试，立即抛验证异常', () async {
    final (url, close) = await startServer(const [
      (status: 403, body: '<form>turnstile</form>'),
      (status: 200, body: 'SHOULD_NOT_SERVE'),
    ]);
    try {
      final sw = Stopwatch()..start();
      await expectLater(
        HttpFetcher.instance.getHtml(url),
        throwsA(
          isA<VerificationRequiredException>()
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
      sw.stop();
      // 无退避：应远快于 403 重试路径（节流下限 ~800ms）。
      expect(sw.elapsed.inMilliseconds, lessThan(3000));
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('CF 1034（Edge IP Restricted）：按选路失败重试，换到好 IP 后放行', () async {
    // 真机现象：快照 IP 中 3/5 返回 403 + error 1034（TCP 却是通的），旧逻辑
    // 因 body 非空判定 hard403=false 直接上抛 → 用户看到验证页。1034 是按 IP
    // 授权的选路失败，退避重试让 DnsResolver 轮转到下一个候选即可自愈。
    const restricted = '<html><head><title>hanime1.me | Edge IP Restricted'
        '</title></head><body><h1>Error 1034</h1>'
        '<p>error code: 1034</p></body></html>';
    final (url, close) = await startServer(const [
      (status: 403, body: restricted),
      (status: 403, body: restricted),
      (status: 200, body: '<html><body>recovered</body></html>'),
    ]);
    try {
      final sw = Stopwatch()..start();
      final body = await HttpFetcher.instance.getHtml(url);
      sw.stop();
      expect(body, contains('recovered'));
      // 两次递增退避（1500+ / 3000+）至少 ~4s：证明真的走了重试而非直通。
      expect(sw.elapsed.inMilliseconds, greaterThan(3500));
      expect(sw.elapsed.inMilliseconds, lessThan(15000));
      // 重试成功应清掉验证冷却，同站紧随请求不被 20s 冷却拖住。
      final sw2 = Stopwatch()..start();
      await HttpFetcher.instance.getHtml(url);
      sw2.stop();
      expect(sw2.elapsed.inMilliseconds, lessThan(3000));
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('CF 1034 持续失败：重试耗尽后仍抛验证异常（保留用户可介入路径）', () async {
    const restricted = '<html><body><h1>Error 1034</h1>'
        '<p>error code: 1034</p></body></html>';
    final (url, close) = await startServer(
      List.filled(6, const (status: 403, body: restricted)),
    );
    try {
      await expectLater(
        HttpFetcher.instance.getHtml(url),
        throwsA(
          isA<VerificationRequiredException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.body, 'body', contains('1034')),
        ),
      );
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('401：不重试，立即抛验证异常', () async {
    final (url, close) = await startServer(const [
      (status: 401, body: ''),
      (status: 200, body: 'SHOULD_NOT_SERVE'),
    ]);
    try {
      await expectLater(
        HttpFetcher.instance.getHtml(url),
        throwsA(
          isA<VerificationRequiredException>()
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('首次即 200：零退避直通（回归保护）', () async {
    final (url, close) = await startServer(const [
      (status: 200, body: '<html><body>fast</body></html>'),
    ]);
    try {
      final sw = Stopwatch()..start();
      final body = await HttpFetcher.instance.getHtml(url);
      sw.stop();
      expect(body, contains('fast'));
      expect(sw.elapsed.inMilliseconds, lessThan(3000));
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('hosts 多候选 + 403：丢弃连接池后重解析换到下一个候选 IP', () async {
    // 真机自愈路径的行为契约：`hanime1.me` 的 hosts 快照 8 条里 5 条返回
    // 403 + error 1034（TCP 通、仅应用层失败）。若 403 后只做退避重试而不换
    // 连接池，Dart 连接池会继续复用那条绑定在坏 IP 上的 keep-alive 连接
    // （探针实证：4 次请求 connectionFactory 只被调用 2 次），轮转是空转。
    // 本用例把「坏 IP」和「好 IP」绑在同一端口上，用响应体区分谁被命中。
    const restricted = '<html><body><h1>Error 1034</h1>'
        '<p>error code: 1034</p></body></html>';
    const badIp = '127.0.0.1';
    const goodIp = '127.0.0.2';
    final bad = await HttpServer.bind(InternetAddress.tryParse(badIp)!, 0);
    final port = bad.port;
    bad.listen((req) async {
      req.response.statusCode = 403;
      req.response.headers.set('content-type', 'text/html; charset=utf-8');
      req.response.add(utf8.encode(restricted));
      await req.response.close();
    });
    // 同一端口绑另一个 loopback 地址（不同本地地址可共用端口号）。
    final good = await HttpServer.bind(InternetAddress.tryParse(goodIp)!, port);
    good.listen((req) async {
      req.response.statusCode = 200;
      req.response.headers.set('content-type', 'text/html; charset=utf-8');
      req.response.add(utf8.encode('<html><body>good-B</body></html>'));
      await req.response.close();
    });
    try {
      // hosts 顺序「先坏后好」：轮转游标从 0 开始，首次必撞坏 IP。
      final net = EffectiveNetworkProfile.fromConfig(
        NetworkConfig.defaults,
        override: const SourceNetworkConfig(
          hosts: <HostsEntry>[
            HostsEntry(ip: badIp, host: 'probe.test'),
            HostsEntry(ip: goodIp, host: 'probe.test'),
          ],
        ),
      );
      final body = await HttpFetcher.instance.getHtml(
        'http://probe.test:$port/probe',
        net: net,
      );
      // 命中好 IP 的响应体 ⇒ 换 IP 真的生效了。没有 _dropConnectionPool 时，
      // 第二次请求会复用绑定在坏 IP 上的连接，拿回 1034 文本 → 此处失败。
      expect(body, contains('good-B'));
    } finally {
      await bad.close(force: true);
      await good.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
