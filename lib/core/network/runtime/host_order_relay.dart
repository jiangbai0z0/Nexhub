/// Host 头序中转桥（loopback relay）。
///
/// 背景：部分 Cloudflare 站点对「Host 头名大小写 + 头序」做指纹检测：
/// - `Host`（首字母大写）且位于请求行后第一行 → 200；
/// - `host` 小写、或 Host 排在 User-Agent 等头之后 → 403（Attention Required）。
///
/// Dart SDK `HttpClient` 的请求头存储为 HashMap：头名一律小写、迭代顺序由
/// 哈希决定，应用层无法控制；显式 `'Host'` 键也会被 SDK `_updateHostHeader`
/// 的私有 `_set` 路径重写回小写靠后位置，dio 的 `preserveHeaderCase` 只能
/// 保住非 Host 头名。参考实现（OkHttp 系）天然以「Host 首位 + Title-Case」
/// 形态发送请求，从不触发该指纹。
///
/// 方案：`connectionFactory` 经 [attach] 返回「连到一次性 loopback 监听的
/// 普通 Socket」。SDK 视工厂返回值为最终通道（https 直连时不会再补 TLS），
/// 会把明文 HTTP/1.1 报文写给桥。桥缓冲到请求头结束（`\r\n\r\n`），重写头
/// 块——Host 行（大小写不敏感匹配）删除后以 `Host: <value>` 大写名重插到
/// 请求行后第一位，其余已知头名按浏览器 Title-Case 形态映射（sec-ch-ua*
/// 保持小写，与 Chrome 真实形态一致）——随后通过注入的 [TargetDialer] 拨号
/// 真目标（DNS/hosts/SNI/TLS 全部在 dialer 内完成），之后双向透传。
///
/// keep-alive：同一连接上的后续请求按 Content-Length 状态机继续重写；
/// `Transfer-Encoding: chunked` 的请求体无法低成本解析边界，降级为纯透传
/// （其后的复用请求不再重写，由客户端断开重建兜底——Dart 客户端请求体
/// 几乎总是带 Content-Length，该降级路径仅覆盖流式上传）。
///
/// 通用性：桥对所有 https 直连生效，不做任何域名特判——Host 首位大写是
/// RFC 9112 §3.2 规范形态、Title-Case 与 Chrome/OkHttp 线上形态一致，
/// 对普通站点无副作用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 拨号回调：连接真目标并完成 TLS（或明文），返回最终数据通道。
typedef TargetDialer = Future<Socket> Function(String host, int port);

class HostOrderRelay {
  HostOrderRelay._();

  static final HostOrderRelay instance = HostOrderRelay._();

  /// 请求头块缓冲上限：超出即断开（容错，防异常客户端撑爆内存）。
  static const int _maxHeadBytes = 64 * 1024;

  /// 监听器无客户端连入时的兜底回收时长（连接被取消/失败时防泄漏）。
  static const Duration _idleTtl = Duration(seconds: 60);

  static const Latin1Codec _l1 = Latin1Codec(allowInvalid: true);

  /// 建立一条经过桥的连接。
  ///
  /// 每次调用绑定一个一次性 loopback 监听端口：客户端连入后立即关闭监听并
  /// 用本条连接服务该客户端——一一对应，不存在队列配对，连接失败/取消也
  /// 不会让后续连接错拿别人的拨号器。
  Future<ConnectionTask<Socket>> attach(TargetDialer dialer) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var wired = false;
    // 先声明可空订阅变量再赋值：回调体内需要引用订阅本身（cancel）。
    StreamSubscription<Socket>? sub;
    sub = server.listen((client) {
      // 首个（也是唯一预期的）客户端连入：撤掉监听，专职服务这条连接。
      wired = true;
      unawaited(sub?.cancel());
      unawaited(server.close());
      _serve(client, dialer);
    }, onError: (Object _) => unawaited(server.close()));
    final idle = Timer(_idleTtl, () {
      if (!wired) unawaited(server.close());
    });

    final future = Socket.connect(server.address.address, server.port);
    unawaited(future.whenComplete(idle.cancel));
    return ConnectionTask.fromSocket(future, () {
      unawaited(future.then<void>(
        (socket) => socket.destroy(),
        onError: (Object _) {},
      ));
    });
  }

  /// 单连接服务：缓冲-重写-拨号-双向透传，keep-alive 多请求循环处理。
  ///
  /// 事件回调只做「字节入 [pending] + 排程 drain」；drain 经 [_chain] 串行
  /// 化，唯一 await 点（首次拨号）期间到达的字节会留在 pending 里，由同一次
  /// drain 的循环继续消化，无并发交错。
  void _serve(Socket a, TargetDialer dialer) {
    Socket? b;
    final pending = BytesBuilder(copy: false);
    var closed = false;
    Future<void> chain = Future<void>.value();

    void closeAll() {
      if (closed) return;
      closed = true;
      a.destroy();
      b?.destroy();
    }

    // 请求体状态：length = 按 Content-Length 精确转发；chunked = 透传。
    var bodyRemaining = -1; // -1 = 处于「等待请求头」状态
    var chunkedBody = false;

    Future<void> drain() async {
      while (!closed) {
        if (b == null) {
          // 需要完整请求头才能拨号。
          final data = pending.takeBytes();
          if (data.isEmpty) return;
          final end = _findHeaderEnd(data);
          if (end < 0) {
            if (data.length > _maxHeadBytes) {
              closeAll();
              return;
            }
            pending.add(data);
            return;
          }
          final headBytes = Uint8List.sublistView(data, 0, end + 4);
          final rest = data.sublist(end + 4);
          pending.add(rest);
          final hostValue = _headerValue(headBytes, 'host');
          if (hostValue == null || hostValue.isEmpty) {
            closeAll();
            return;
          }
          final (host, port) = _splitHostPort(hostValue);
          final rewired = rewriteHead(headBytes);
          try {
            b = await dialer(host, port);
          } on Object {
            closeAll();
            return;
          }
          if (closed) {
            // 拨号期间客户端已被取消/关闭：立即回收目标连接。
            b!.destroy();
            b = null;
            return;
          }
          _pumpBack(b!, a);
          b!.add(rewired);
          final te = _headerValue(headBytes, 'transfer-encoding');
          final cl = _headerValue(headBytes, 'content-length');
          if (te != null && te.toLowerCase().contains('chunked')) {
            chunkedBody = true;
            bodyRemaining = -1;
          } else if (cl != null) {
            bodyRemaining = int.tryParse(cl.trim()) ?? 0;
            chunkedBody = false;
          } else {
            bodyRemaining = -1;
            chunkedBody = false;
          }
          continue;
        }

        if (bodyRemaining > 0) {
          final data = pending.takeBytes();
          if (data.isEmpty) return;
          final n = data.length < bodyRemaining ? data.length : bodyRemaining;
          if (n > 0) b!.add(data.sublist(0, n));
          bodyRemaining -= n;
          if (n < data.length) pending.add(data.sublist(n));
          continue;
        }
        if (bodyRemaining == 0) {
          // 请求体已发完：下一个字节属于新请求头（keep-alive）。
          bodyRemaining = -1;
          continue;
        }
        if (chunkedBody) {
          final data = pending.takeBytes();
          if (data.isEmpty) return;
          b!.add(data);
          return; // 无法解析 chunk 边界：本次连接降级为透传。
        }

        // bodyRemaining == -1：等待（下一条）请求头。
        final data = pending.takeBytes();
        if (data.isEmpty) return;
        final end = _findHeaderEnd(data);
        if (end < 0) {
          if (data.length > _maxHeadBytes) {
            closeAll();
            return;
          }
          pending.add(data);
          return;
        }
        final headBytes = Uint8List.sublistView(data, 0, end + 4);
        final rest = data.sublist(end + 4);
        pending.add(rest);
        b!.add(rewriteHead(headBytes));
        final te = _headerValue(headBytes, 'transfer-encoding');
        final cl = _headerValue(headBytes, 'content-length');
        if (te != null && te.toLowerCase().contains('chunked')) {
          chunkedBody = true;
          bodyRemaining = -1;
        } else if (cl != null) {
          bodyRemaining = int.tryParse(cl.trim()) ?? 0;
          chunkedBody = false;
        } else {
          bodyRemaining = -1;
          chunkedBody = false;
        }
        continue;
      }
    }

    a.listen((chunk) {
      if (closed) return;
      pending.add(chunk);
      chain = chain.then((_) => drain()).catchError((Object _) => closeAll());
    }, onDone: closeAll, onError: (Object _) => closeAll());
  }

  /// 回程：目标 → 客户端，纯透传。
  void _pumpBack(Socket b, Socket a) {
    b.listen((data) {
      try {
        a.add(data);
      } on Object {
        // 客户端已关闭：由 closeAll 统一清理。
      }
    }, onDone: () => a.destroy(), onError: (Object _) => a.destroy());
  }

  /// 在头块中查找 `\r\n\r\n` 的起始下标；未找到返回 -1。
  static int _findHeaderEnd(List<int> data) {
    for (var i = 0; i <= data.length - 4; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// 大小写不敏感取头值（首个匹配，trim 后）。
  static String? _headerValue(List<int> head, String lowerName) {
    for (final line in _l1.decode(head).split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      if (line.substring(0, colon).trim().toLowerCase() == lowerName) {
        return line.substring(colon + 1).trim();
      }
    }
    return null;
  }

  /// 拆 Host 值为 (host, port)；无显式端口时 port 返回 0（由 dialer 决定默认值）。
  static (String, int) _splitHostPort(String value) {
    // IPv6 字面量：[::1]:8443
    if (value.startsWith('[')) {
      final close = value.indexOf(']');
      if (close > 0) {
        final host = value.substring(1, close);
        final rest = value.substring(close + 1);
        if (rest.startsWith(':')) {
          return (host, int.tryParse(rest.substring(1)) ?? 0);
        }
        return (host, 0);
      }
    }
    final firstColon = value.indexOf(':');
    final lastColon = value.lastIndexOf(':');
    if (lastColon > 0 && firstColon == lastColon) {
      final port = int.tryParse(value.substring(lastColon + 1));
      if (port != null) return (value.substring(0, lastColon), port);
    }
    return (value, 0);
  }

  /// 已知头名 → 浏览器 Title-Case 形态。sec-ch-ua* 保持小写（Chrome 真实形态）。
  static const Map<String, String> _headerCaseMap = {
    'user-agent': 'User-Agent',
    'accept': 'Accept',
    'accept-encoding': 'Accept-Encoding',
    'accept-language': 'Accept-Language',
    'connection': 'Connection',
    'content-length': 'Content-Length',
    'content-type': 'Content-Type',
    'cookie': 'Cookie',
    'referer': 'Referer',
    'origin': 'Origin',
    'range': 'Range',
    'if-none-match': 'If-None-Match',
    'if-modified-since': 'If-Modified-Since',
    'if-range': 'If-Range',
    'authorization': 'Authorization',
    'cache-control': 'Cache-Control',
    'pragma': 'Pragma',
    'dnt': 'DNT',
    'upgrade-insecure-requests': 'Upgrade-Insecure-Requests',
    'sec-fetch-site': 'Sec-Fetch-Site',
    'sec-fetch-mode': 'Sec-Fetch-Mode',
    'sec-fetch-user': 'Sec-Fetch-User',
    'sec-fetch-dest': 'Sec-Fetch-Dest',
    'last-modified': 'Last-Modified',
    'etag': 'ETag',
    'date': 'Date',
    'x-requested-with': 'X-Requested-With',
  };

  /// 重写请求头块：Host 大写名重插到请求行后第一位，已知头名 Title-Case 化。
  ///
  /// 无 host 行时原样返回（无法确定拨号目标，属异常请求）。
  static List<int> rewriteHead(List<int> head) {
    final text = _l1.decode(head);
    final lines = text.split('\r\n');
    if (lines.length < 2) return head;
    final requestLine = lines.first;
    String? hostValue;
    final headers = <String>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) {
        headers.add(line);
        continue;
      }
      final name = line.substring(0, colon);
      final value = line.substring(colon + 1);
      if (name.trim().toLowerCase() == 'host') {
        hostValue ??= value.trim();
        continue;
      }
      final lower = name.trim().toLowerCase();
      final canonical = _headerCaseMap[lower] ?? name;
      headers.add('$canonical:$value');
    }
    if (hostValue == null || hostValue.isEmpty) return head;
    return _l1.encode(
        <String>[requestLine, 'Host: $hostValue', ...headers, '', '']
            .join('\r\n'));
  }
}
