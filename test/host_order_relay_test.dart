// HostOrderRelay 回归测试：头块重写纯函数 + 回环集成（HttpClient 经
// connectionFactory 走桥，验证生产接线形态）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexhub/core/network/runtime/host_order_relay.dart';
import 'package:flutter_test/flutter_test.dart';

const _l1 = Latin1Codec(allowInvalid: true);

void main() {
  group('rewriteHead（纯函数）', () {
    test('host 小写任意位置 → Host 大写重插请求行后第一位', () {
      final input = _l1.encode(
          'GET / HTTP/1.1\r\n'
          'user-agent: Dart/3.5\r\n'
          'host: example.test\r\n'
          'accept: */*\r\n'
          '\r\n');
      final out = _l1.decode(HostOrderRelay.rewriteHead(input));
      final lines = out.split('\r\n');
      expect(lines[0], 'GET / HTTP/1.1');
      expect(lines[1], 'Host: example.test');
      expect(lines.where((l) => l.toLowerCase() == 'host: example.test').length, 1);
    });

    test('已知头名 Title-Case 化；sec-ch-ua* 保持小写', () {
      final input = _l1.encode(
          'GET / HTTP/1.1\r\n'
          'host: example.test\r\n'
          'user-agent: UA\r\n'
          'sec-ch-ua: "Chromium";v="124"\r\n'
          'sec-fetch-mode: navigate\r\n'
          '\r\n');
      final out = _l1.decode(HostOrderRelay.rewriteHead(input));
      expect(out, contains('User-Agent: UA'));
      expect(out, contains('Sec-Fetch-Mode: navigate'));
      expect(out, contains('sec-ch-ua: "Chromium";v="124"'));
    });

    test('多段 Host 行只保留首个值', () {
      final input = _l1.encode(
          'GET / HTTP/1.1\r\n'
          'host: first.test\r\n'
          'x-a: 1\r\n'
          'Host: second.test\r\n'
          '\r\n');
      final out = _l1.decode(HostOrderRelay.rewriteHead(input));
      expect(out, contains('Host: first.test'));
      expect(out, isNot(contains('second.test')));
    });

    test('无 host 行原样返回（异常请求容错）', () {
      final input = _l1.encode('GET / HTTP/1.1\r\naccept: */*\r\n\r\n');
      final out = HostOrderRelay.rewriteHead(input);
      expect(_l1.decode(out), _l1.decode(input));
    });
  });

  group('attach（回环集成）', () {
    late ServerSocket origin;
    late List<String> heads;
    late List<String> bodies;
    late int originPort;

    setUp(() async {
      heads = <String>[];
      bodies = <String>[];
      origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      originPort = origin.port;
      origin.listen((client) {
        final buf = <int>[];
        client.listen((chunk) {
          buf.addAll(chunk);
          while (true) {
            final text = _l1.decode(buf);
            final end = text.indexOf('\r\n\r\n');
            if (end < 0) break;
            final head = text.substring(0, end);
            var cl = 0;
            for (final line in head.split('\r\n')) {
              if (line.toLowerCase().startsWith('content-length:')) {
                cl = int.tryParse(line.split(':')[1].trim()) ?? 0;
              }
            }
            final total = end + 4 + cl;
            if (buf.length < total) break;
            heads.add(head);
            bodies.add(cl > 0 ? text.substring(end + 4, total) : '');
            final isPost = head.startsWith('POST');
            final body = isPost ? '{"echo":true}' : '<html>ok</html>';
            client.add(_l1.encode(
                'HTTP/1.1 200 OK\r\nContent-Length: ${_l1.encode(body).length}\r\n'
                'Connection: keep-alive\r\n\r\n$body'));
            buf.removeRange(0, total);
          }
        }, onDone: () => client.destroy());
      });
    });

    tearDown(() async {
      await origin.close();
    });

    test('HttpClient 经 connectionFactory 走桥：Host 首位 + Title-Case', () async {
      Future<Socket> dial(String host, int port) =>
          Socket.connect(InternetAddress.loopbackIPv4, originPort);
      final task = await HostOrderRelay.instance.attach(dial);
      final client = HttpClient();
      client.connectionFactory = (Uri uri, String? ph, int? pp) async => task;
      final req = await client
          .getUrl(Uri.parse('http://example.test/page'))
          .timeout(const Duration(seconds: 5));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();

      expect(resp.statusCode, 200);
      expect(body, '<html>ok</html>');
      expect(heads, hasLength(1));
      final lines = heads.first.split('\r\n');
      expect(lines[1], 'Host: example.test');
      expect(heads.first, contains('User-Agent:'));
      client.close();
    });

    test('keep-alive 复用：第二请求同样重写 Host 首位', () async {
      Future<Socket> dial(String host, int port) =>
          Socket.connect(InternetAddress.loopbackIPv4, originPort);
      final task = await HostOrderRelay.instance.attach(dial);
      final socket = await task.socket.timeout(const Duration(seconds: 5));

      final reader = _RespReader(socket);
      socket.add(_l1.encode(
          'POST /a HTTP/1.1\r\nhost: x.test\r\ncontent-length: 2\r\n\r\nhi'));
      await reader.next();
      socket.add(_l1.encode(
          'GET /b HTTP/1.1\r\nhost: x.test\r\naccept: */*\r\n\r\n'));
      await reader.next();

      expect(heads, hasLength(2));
      expect(heads[0].split('\r\n')[1], 'Host: x.test');
      expect(bodies[0], 'hi');
      expect(heads[1].split('\r\n')[1], 'Host: x.test');
      socket.destroy();
    });

    test('拨号失败：桥断开客户端连接（不悬挂）', () async {
      Future<Socket> dial(String host, int port) async {
        throw const SocketException('dial refused');
      }

      final task = await HostOrderRelay.instance.attach(dial);
      final socket = await task.socket.timeout(const Duration(seconds: 5));
      // 先订阅再写请求：桥 dialer 抛错 → closeAll → a.destroy → 客户端读 done。
      final sub = socket.listen((_) {});
      socket.add(_l1.encode('GET / HTTP/1.1\r\nhost: dead.test\r\n\r\n'));
      // 若桥悬挂不关闭连接，下面这行 5s 超时抛错 = 测试失败。
      await sub.asFuture<void>().timeout(const Duration(seconds: 5));
      socket.destroy();
    });
  });
}

/// 常驻单订阅读取器：顺序消费 keep-alive 多条响应。
class _RespReader {
  _RespReader(this._socket) {
    _sub = _socket.listen((chunk) {
      _buf.addAll(chunk);
      _tryEmit();
    }, onError: (Object e) {
      if (!_completer.isCompleted) _completer.completeError(e);
    }, onDone: () {
      if (!_completer.isCompleted) {
        _completer.completeError(const SocketException('closed'));
      }
    });
  }

  final Socket _socket;
  final List<int> _buf = <int>[];
  // 保留订阅引用（防 GC 回收订阅导致流中断）；测试生命周期内无需主动 cancel。
  // ignore: unused_field
  late final StreamSubscription<Uint8List> _sub;
  Completer<String> _completer = Completer<String>();

  Future<String> next() {
    _completer = Completer<String>();
    _tryEmit();
    return _completer.future.timeout(const Duration(seconds: 5));
  }

  void _tryEmit() {
    if (_completer.isCompleted) return;
    final text = _l1.decode(_buf);
    final end = text.indexOf('\r\n\r\n');
    if (end < 0) return;
    final head = text.substring(0, end);
    int? cl;
    for (final line in head.split('\r\n')) {
      if (line.toLowerCase().startsWith('content-length:')) {
        cl = int.tryParse(line.split(':')[1].trim());
      }
    }
    if (cl == null) return;
    if (_buf.length >= end + 4 + cl) {
      final body = _l1.decode(_buf.sublist(end + 4, end + 4 + cl));
      _buf.removeRange(0, end + 4 + cl);
      _completer.complete(body);
    }
  }
}


