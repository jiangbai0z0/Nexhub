import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/resolver/builtin_resolver.dart';

/// pms_anime7 v3 配置与解析回归（2026-10-05 实测修复）：
/// - 分类 tab：新增 category 路由（ajax/data 的 tid 过滤，tid=all 即全部）
///   与站点导航一致的 categoryEntries；
/// - 播放：episodes 选择器对齐 conch 模板真实 DOM（旧选择器命不中任何
///   节点，详情页剧集恒空导致无法播放）；
/// - 搜索：改走站内搜索页 /vod-search/page/{page}/wd/{keyword}/（旧
///   suggest 接口全字段模糊且按更新时间取前 50 条，结果与关键词基本无关）；
/// - 详情：封面实为 span.hl-item-thumb@data-original（非 img），状态/年份/
///   类型改按 em 标签定位。
/// 详情/搜索页 HTML 为 2026-10-05 真实抓取快照（test/fixtures/）。
void main() {
  late PluginConfig source;

  setUpAll(() {
    final file = File('plugins/builtin/pms_anime7.json');
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    source = PluginConfig.fromJson(map);
  });

  group('pms_anime7 v3 配置消费', () {
    test('名称/版本/六路由与视频脚本 override 就位', () {
      expect(source.version, 3);
      expect(source.name, 'Anime7 动画线上看');
      expect(source.id, 'pms_anime7');
      for (final api in <String>[
        'latest',
        'category',
        'search',
        'detail',
        'episodes',
        'video'
      ]) {
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

    test('category 路由按 tid 过滤；all/数字分类/分页/中文关键词编码', () {
      const base = 'https://anime7.top';
      final all = source.resolveRouteUrl('category',
          activeBaseUrl: base,
          vars: <String, String>{'category': 'all', 'page': '1'});
      expect(all, contains('tid=all'));
      final kr = source.resolveRouteUrl('category',
          activeBaseUrl: base,
          vars: <String, String>{'category': '29', 'page': '2'});
      expect(kr, contains('tid=29'));
      expect(kr, contains('page=2'));
      final search = source.resolveRouteUrl('search',
          activeBaseUrl: base,
          vars: <String, String>{'keyword': '黄泉', 'page': '2'});
      expect(search, startsWith('$base/vod-search/page/2/wd/'));
      expect(search, contains('%E9%BB%84%E6%B3%89'));
    });

    test('categoryEntries 首项「全部」且与站点导航分类一致', () {
      final entries = source.category.categoryEntries;
      expect(entries.first['id'], 'all');
      expect(entries.first['title'], '全部');
      final ids = entries.map((e) => e['id']).toSet();
      expect(ids, containsAll(<String>['29', '38', '37', '28', '31', '30']));
    });

    test('episodes 选择器为线路容器 Map 形态并对齐 conch 模板 DOM', () {
      final ep = source.selectors?['episodes'];
      expect(ep, isA<Map>());
      final m = ep as Map;
      expect(m['lineList'], 'div.hl-tabs-box');
      expect(m['lineName'], contains('hl-tabs-btn'));
      expect(m['list'], contains('ul.hl-plays-list li a'));
    });

    test('search 路由为站内搜索页 HTML（弃用 suggest 接口）', () {
      expect(source.routes['search']!.responseType, 'html');
      expect(source.routes['search']!.url, contains('/vod-search/'));
      final sel = source.selectors?['search'] as Map;
      expect(sel['list'], contains('hl-one-list'));
      expect(sel['id'] as String, contains('substring-after'));
    });
  });

  group('pms_anime7 真实页面解析（fixture 快照）', () {
    test('episodes：单线路 24 集完整解析', () async {
      final html =
          File('test/fixtures/pms_anime7_detail.html').readAsStringSync();
      final r =
          await const BuiltinResolver().resolveFromHtml(source, 'episodes', html);
      expect(r, isA<List<Episode>>());
      final eps = r as List<Episode>;
      expect(eps.length, 24);
      expect(eps.first.url, '/vod-play/9696-1-1/');
      expect(eps.first.title, '第01集');
      expect(eps.first.id, '/vod-play/9696-1-1/');
      expect(eps.last.url, '/vod-play/9696-1-24/');
      // 线路名取自 hl-tabs-btn（「線路1」数字徽标由引擎清理为「線路」）。
      expect(eps.first.lineName, '線路');
    });

    test('detail：标题/绝对封面/简介/导演/演员/年份/状态/类型', () async {
      final html =
          File('test/fixtures/pms_anime7_detail.html').readAsStringSync();
      final r =
          await const BuiltinResolver().resolveFromHtml(source, 'detail', html);
      expect(r, isA<MediaItem>());
      final item = r as MediaItem;
      expect(item.title, '黄泉的使者');
      // 该模板封面不是 <img> 而是 span.hl-item-thumb 的 data-original；
      // 且必须已补全为绝对 URL（否则 UI 层按本地图渲染，封面永远空白）。
      expect(item.coverUrl, startsWith('https://ani7.b-cdn.net/'));
      expect(item.coverUrl, contains('/upload/vod/'));
      expect(item.description, isNotEmpty);
      expect(item.director, '安藤真裕');
      expect(item.actors, contains('小野贤章'));
      expect(item.actors, contains('宫本侑芽'));
      expect(item.actors, isNot(contains('安藤真裕')));
      expect(item.year, '2026');
      expect(item.status, '已完结');
      expect(item.tags, containsAll(<String>['动画', '日韩动漫']));
    });

    test('search：站内搜索页结果（数字 id + 标题 + 封面）', () async {
      final html =
          File('test/fixtures/pms_anime7_search.html').readAsStringSync();
      final r =
          await const BuiltinResolver().resolveFromHtml(source, 'search', html);
      expect(r, isA<List<MediaItem>>());
      final items = r as List<MediaItem>;
      expect(items, isNotEmpty);
      // 「黄泉」快照页：命中 4 条且 id 为纯数字（detail/episodes 路由依赖）。
      expect(items.length, 4);
      for (final it in items) {
        expect(int.tryParse(it.id), isNotNull,
            reason: '搜索结果 id 必须为纯数字 vod_id：${it.id}');
      }
      expect(items.first.id, '9696');
      expect(items.first.title, '黄泉的使者');
      expect(items.first.coverUrl, startsWith('https://'));
      expect(items.first.title, isNot(contains('vod-detail')));
    });

    // 说明：video 路由的 parseVideo 脚本走真 QuickJS，但 flutter_js 0.8.7 在
    // flutter test 环境构造引擎时会泄漏 enableFetch 未处理异步错误（测试区
    // 判失败），故不进默认测试套件（与 pms_girigirilove 同一处理）。脚本布线
    // 由上方配置层用例覆盖；实际解码已于 2026-10-05 对真实播放页快照人工验证
    // （player_aaaa encrypt=2 → atob + 双重 decodeURIComponent → 解出
    // https://vip.dytt-tvs.com/.../index.m3u8，302 跳转 CDN 后 master/变体
    // 均可访问）。
  });
}
