import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/scraper/verification_detector.dart';

void main() {
  group('VerificationDetector', () {
    test('401 / 403 always require verification', () {
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 401, body: 'x'),
        isTrue,
      );
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 403, body: 'x'),
        isTrue,
      );
    });

    test('503 with Cloudflare challenge feature requires verification', () {
      const body = '<html><body>cf-ray: 123</body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 503, body: body),
        isTrue,
      );
    });

    test('200 with __cf_chl challenge feature requires verification', () {
      const body = 'please wait <div class="__cf_chl"></div>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isTrue,
      );
    });

    test('demo slider guard page requires verification', () {
      const body = '<script src="/_guard/slide.js"></script>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isTrue,
      );
    });

    test('normal 200 page does not require verification', () {
      const body = '<html><body>hello world</body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isFalse,
      );
    });

    // ---- 笔趣阁（Cloudflare 反代）回归：正常页含被动标记不得误判 ----

    test(
        'book-source-style normal page (passive CF marker + full of chapter links, '
        '>8KB) must NOT require verification', () {
      // 实测 m.biqubu3.com 正常页（首页 17KB / 书页 8.3KB / 章节页 12.8KB）均含
      // challenge-platform 被动标记；体积超过挑战壳长度闸门（8192）→ 必须
      // 放行，否则从历史进入详情页会被误判进验证循环。
      final links = StringBuffer();
      for (var i = 1; i <= 200; i++) {
        links.writeln('<a href="/book_18093/$i.html">第$i章 章节标题占位内容</a>');
      }
      final body = '<html><head>'
          '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js">'
          '</script></head><body><div class="chapterlist">$links</div>'
          '</body></html>';
      // 前置断言：构造页体量与实测正常页一致（超过挑战壳长度闸门）。
      expect(body.trim().length, greaterThan(8192));
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isFalse,
      );
    });

    test('200 short challenge shell with passive CF marker requires'
        'verification', () {
      // 真正的 CF 临时挑战壳：只有几 KB 的等待/重定向壳 + 被动标记 → 判验证。
      const body = '<html><head>'
          '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/jsch/v1">'
          '</script></head><body>please wait while we check your browser'
          '</body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isTrue,
      );
    });

    test('503 without challenge feature does not require verification', () {
      const body = '<html><body>service unavailable</body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 503, body: body),
        isFalse,
      );
    });

    // ---- WAF「拦截应答」检测（部分源: 200 + body="closed"）----

    test('200 with body exactly "closed" requires verification (Edge WAF)', () {
      expect(
        VerificationDetector.isVerificationRequired(
            statusCode: 200, body: 'closed'),
        isTrue,
      );
    });

    test('body "closed" with surrounding whitespace/case still matches', () {
      expect(
        VerificationDetector.isVerificationRequired(
            statusCode: 200, body: '  CLOSED\n'),
        isTrue,
      );
    });

    test('normal content containing the word "closed" is NOT verification', () {
      // 关键防误伤：正常页面里出现 closed 一词不能触发验证死循环。
      const body =
          '<html><body><span class="status">已完结 closed</span></body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isFalse,
      );
    });

    test('short non-JSON body + Edge WAF Server header requires verification',
        () {
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 200,
          body: 'denied',
          headers: {'Server': 'Edge/1.1.18'},
        ),
        isTrue,
      );
    });

    test('Cloudflare 1034 (Edge IP Restricted) 被识别为选路失败', () {
      // 真机实测原文（hanime1.me 快照 IP 返回体，403 解压后 7451B 的片段）。
      const body = '<html><head><title>hanime1.me | Edge IP Restricted'
          '</title></head><body><h1>Error 1034</h1>'
          '<p>error code: 1034</p>'
          '<p>The host (hanime1.me) resolved to an IP address that the owner '
          'of the website does not have access to.</p></body></html>';
      expect(
        VerificationDetector.isEdgeIpRestricted(statusCode: 403, body: body),
        isTrue,
      );
      // 同响应仍是「需要处理」的一类（403 语义不变，由调用方选路重试）。
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 403,
          body: body,
        ),
        isTrue,
      );
    });

    test('1034 标记大小写不敏感', () {
      expect(
        VerificationDetector.isEdgeIpRestricted(
          statusCode: 403,
          body: '<h1>Edge IP Restricted</h1>',
        ),
        isTrue,
      );
      expect(
        VerificationDetector.isEdgeIpRestricted(
          statusCode: 403,
          body: '<p>ERROR CODE: 1034</p>',
        ),
        isTrue,
      );
    });

    test('1034 判定的边界：非 403 / 空 body / 超长 body 都不算', () {
      const short = '<h1>Error 1034</h1><p>error code: 1034</p>';
      expect(
        VerificationDetector.isEdgeIpRestricted(statusCode: 200, body: short),
        isFalse,
      );
      expect(
        VerificationDetector.isEdgeIpRestricted(statusCode: 503, body: short),
        isFalse,
      );
      expect(
        VerificationDetector.isEdgeIpRestricted(statusCode: 403, body: ''),
        isFalse,
      );
      expect(
        VerificationDetector.isEdgeIpRestricted(statusCode: 403, body: null),
        isFalse,
      );
      // 长度闸门：正常大页面即便偶然含同名字样也不当作 1034。
      final huge = StringBuffer('<h1>Error 1034</h1>')
        ..write('x' * (65 * 1024));
      expect(
        VerificationDetector.isEdgeIpRestricted(
          statusCode: 403,
          body: huge.toString(),
        ),
        isFalse,
      );
    });

    test('普通 403（非 1034）不误判为选路失败', () {
      expect(
        VerificationDetector.isEdgeIpRestricted(
          statusCode: 403,
          body: '<form>turnstile</form>',
        ),
        isFalse,
      );
      expect(
        VerificationDetector.isEdgeIpRestricted(
          statusCode: 403,
          body: '<html><body>Attention Required! | Cloudflare</body></html>',
        ),
        isFalse,
      );
    });

    test('valid JSON body + Edge Server header is NOT verification', () {
      // 同一 WAF 放行后返回的正常大 JSON 不能被误判。
      const body =
          '{"code":1,"msg":"数据列表","page":1,"list":[{"vod_id":1,"vod_name":"x"}]}';
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 200,
          body: body,
          headers: {'server': 'Edge/1.1.18'},
        ),
        isFalse,
      );
    });

    // ---- MacCMS「系统安全验证」拦截页（233动漫搜索/筛选路由）回归 ----

    test('MacCMS 系统安全验证页（继续访问按钮）requires verification', () {
      // 实测 cn.233dm.com /search/*.html 未过会话时返回的整页（200，~5.3KB）：
      // mx-mac_msg_jump 弹窗容器 + verify_submit「继续访问」按钮 + 页内联
      // verify_check AJAX 脚本。不判为验证页会把该 HTML 缓存解析 → 搜索恒 0 条。
      const body = '<!DOCTYPE html><html lang="en"><head>'
          '<title>系统安全验证 - 233动漫_cn.233dm.com</title>'
          '<style>.mx-mac_msg_jump{margin:35px auto}</style>'
          '<script>var maccms={"path":"","mid":"1"};</script>'
          "<script>\$('.verify_submit').click(function(){"
          "MAC.Ajax(maccms.path+'/index.php/ajax/verify_check?type=search',"
          "'post','json',{i:refresh()},function(r){location.reload();});});"
          '</script></head><body>'
          '<div class="mx-mac_msg_jump">'
          '<div class="text">因访问过多，请点击下方【继续访问】</div>'
          '<div class="form"><div class="jump item">'
          '<input type="button" class="verify_submit btnverify" value="继续访问">'
          '</div></div></div></body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isTrue,
      );
    });

    test('MacCMS 正常搜索结果页（真实 200 正文）不得误判为验证页', () {
      // 实测过验证后的搜索结果页结构：JIHA_djfJghJ 列表 + h4.title + 封面。
      // 正常内容页不含 mx-mac_msg_jump/verify_submit/verify_check 任一标记，
      // 加入特征后不得触发验证循环。
      const body = '<!DOCTYPE html><html><head><title>搜索 火影 - 233动漫</title>'
          '</head><body><ul class="JIHA_djfJghJ clearfix">'
          '<li class="col-md-6"><div>'
          '<a class="lazyload" href="/anime/0f7d64bb.html" data-original='
          '"https://as.cfhls.top/upload/vod/1.jpg"><span class="GDC_Fbfa">'
          '<b>1080P</b></span></a>'
          '<div><h4 class="title text-overflow"><a href="/anime/0f7d64bb.html">'
          '火影忍者剧场版</a></h4></div></div></li></ul></body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isFalse,
      );
    });

    // ---- 验证码「组件」≠ 挑战页（hanime1.me 登录态 watch 页回归）----

    test('hanime 登录态 watch 大页（评论区 hCaptcha 组件）不得误判为验证页', () {
      // 真机实锤（2026-10-05）：登录态 GET /watch?v=408492 → 200/190004B 正常
      // 内容页，评论区挂 hCaptcha 发帖验证组件（data-sitekey×2）。旧逻辑把
      // data-sitekey 当主动挑战标记 → ScriptResolver 预取被判验证墙
      // rawLength=0 → video/episodes 解析不出（「详情页解析不完全，视频解析
      // 不了」）。组件挂在正常大页 ≠ 页面是挑战页。
      const pageHead = '<!DOCTYPE html><html><head>'
          '<title>櫻春女學院的男優 - Hanime1.me</title></head><body>';
      const commentCaptcha = '<div style="margin-bottom: 10px;">'
          '<div style="display: inline-block; vertical-align: top;" '
          'class="h-captcha" data-sitekey='
          '"5959a57c-915a-48e8-8d35-48155f9b8529" data-theme="dark"></div>'
          '</div>';
      // 前置断言：体量对齐真实 190KB 大页（远超 8KB 挑战壳闸门）。
      final body = StringBuffer(pageHead)
        ..write('<div class="video-wrapper"><video id="player"></video></div>');
      for (var i = 0; i < 300; i++) {
        body.write('<a href="/watch?v=4$i">相关影片标题占位 $i</a>');
      }
      body.write(commentCaptcha);
      body.write('<div class="h-captcha" data-sitekey='
          '"5959a57c-915a-48e8-8d35-48155f9b8529"></div></body></html>');
      expect(body.length, greaterThan(8192));
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 200,
          body: body.toString(),
        ),
        isFalse,
      );
    });

    test('g-recaptcha/turnstile 组件挂在正常大页同样放行', () {
      final body = StringBuffer(
          '<html><head><title>评论区</title></head><body>');
          for (var i = 0; i < 300; i++) {
            body.write('<a href="/post/$i">帖子标题占位 $i</a>');
          }
          body.write('<div class="g-recaptcha" data-sitekey="6LeX"></div>');
          body.write('<div class="cf-turnstile" data-sitekey="0x4A"></div>');
          body.write('</body></html>');
          expect(body.length, greaterThan(8192));
          expect(
            VerificationDetector.isVerificationRequired(
              statusCode: 200,
              body: body.toString(),
            ),
            isFalse,
          );
    });

    test('整页极小的 recaptcha 挑战壳仍判验证（组件+极短壳路径）', () {
      // 组件降级为「被动标记」语义后，真挑战壳（整页就是一个验证表单，<8KB）
      // 走「被动标记 + 极短壳」路径依旧拦截，不会漏判。
      const shell = '<html><head><title>One more step</title></head><body>'
          '<form action="/challenge"><div class="g-recaptcha" '
          'data-sitekey="6LeX"></div><input type="submit" value="Continue">'
          '</form></body></html>';
      expect(shell.trim().length, lessThanOrEqualTo(8192));
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: shell),
        isTrue,
      );
    });
  });
}
