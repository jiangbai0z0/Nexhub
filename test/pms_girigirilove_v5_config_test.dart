import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/resolver/builtin_resolver.dart';

/// pms_girigirilove v5 配置与解析回归（2026-10-05 实测改版）：
/// 站点现名「girigiri愛動漫」（原误标「花子动漫」）；详情页封面属性
/// data-original→data-src；导演/演员并入同一 slide-info 容器、「主演」改
/// 「演员」；剧集选择器改 Map 形态（扁平字符串曾被顶层 $.list 劫持成
/// HTML 选择器，详情剧集恒空）；列表封面 /upload 相对路径由引擎全局补全。
/// 详情/播放页 HTML 为 2026-10-05 真实抓取快照（test/fixtures/）。
void main() {
  late PluginConfig source;

  setUpAll(() {
    final file = File('plugins/builtin/pms_girigirilove.json');
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    source = PluginConfig.fromJson(map);
  });

  group('pms_girigirilove v5 配置消费', () {
    test('名称/版本/路由与视频脚本 override 就位', () {
      expect(source.version, 5);
      expect(source.name, 'girigiri愛動漫');
      expect(source.id, 'pms_girigirilove');
      expect(source.type, SourceType.animeSource);
      for (final api in <String>['latest', 'search', 'detail', 'episodes', 'video']) {
        expect(source.routes.containsKey(api), isTrue, reason: '缺路由 $api');
      }
      final ov = source.parser.overrides ?? const <String, ParserOverride>{};
      expect(ov['video']?.type, 'script');
      expect(ov['video']?.function, 'parseVideo');
      final script = ov['video']?.script ?? '';
      expect(script, contains('function parseVideo('));
      expect(script, contains('player_aaaa'));
      expect(script, contains('encrypt'));
    });

    test('episodes 选择器为 Map 形态（扁平字符串会被顶层 \$list 选择器劫持）', () {
      final ep = source.selectors?['episodes'];
      expect(ep, isA<Map>());
      final list = (ep as Map)['list'] as String;
      expect(list, contains('anthology-list-play'));
      expect(list, contains("a[href*='/playGV']"));
    });

    test('detail 选择器适配 2026-10 模板（data-src 封面 + strong 文本定位）', () {
      final detail = source.selectors?['detail'] as Map;
      expect(detail['cover'], contains('@data-src'));
      // 旧模板属性保留为兜底分支。
      expect(detail['cover'], contains('@data-original'));
      // 导演/演员用 strong 文本 + following-sibling 定位（引擎不支持
      // contains(.,'…') 当前节点谓词，旧写法恒被静默降级为空）。
      expect(detail['director'],
          "//strong[contains(text(),'导演')]/following-sibling::a/text()");
      expect((detail['actors'] as String), contains("contains(text(),'演员')"));
      // 旧模板「主演」标签保留为兜底分支。
      expect((detail['actors'] as String), contains("contains(text(),'主演')"));
      // 不含引擎不支持的当前节点谓词。
      expect(detail['director'] as String, isNot(contains("(.,'")));
      expect((detail['actors'] as String), isNot(contains("(.,'")));
    });
  });

  group('pms_girigirilove 真实页面解析（fixture 快照）', () {
    test('detail：标题/绝对封面/简介/导演/演员/年份/状态', () async {
      final html =
          File('test/fixtures/pms_girigirilove_detail.html').readAsStringSync();
      final r = await const BuiltinResolver()
          .resolveFromHtml(source, 'detail', html);
      expect(r, isA<MediaItem>());
      final item = r as MediaItem;
      expect(item.title, '海贼王女');
      // 封面为根相对路径，必须已补全为绝对 URL（否则 UI 层按本地图渲染，
      // 封面永远空白）。
      expect(item.coverUrl, startsWith('https://ani.girigirilove.com/'));
      expect(item.coverUrl, contains('/upload/vod/'));
      expect(item.description, isNotEmpty);
      expect(item.director, '中泽一登');
      expect(item.actors, contains('濑户麻沙美'));
      expect(item.actors, contains('悠木碧'));
      // 演员不得混入导演字段（following-sibling 误配的回归断言）。
      expect(item.director, isNot(contains('濑户麻沙美')));
      expect(item.year, '2021');
      expect(item.status, '已完结');
    });

    test('episodes：剧集列表完整解析且为相对播放页路径', () async {
      final html =
          File('test/fixtures/pms_girigirilove_detail.html').readAsStringSync();
      final r = await const BuiltinResolver()
          .resolveFromHtml(source, 'episodes', html);
      expect(r, isA<List>());
      final eps = r as List;
      expect(eps.length, 12);
      expect(eps[0].url, '/playGV6547-1-1/');
      expect(eps[0].title, isNotEmpty);
      expect(eps[11].url, '/playGV6547-1-12/');
    });

    // 说明：video 路由的 parseVideo 脚本走真 QuickJS，但 flutter_js 0.8.7 在
    // flutter test 环境构造引擎时会泄漏 enableFetch 未处理异步错误（测试区
    // 判失败），故不进默认测试套件。脚本布线由上方配置层用例覆盖；实际解码
    // 已于 2026-10-05 对真实播放页快照人工验证（解出 mp4 直链）。
  });
}
