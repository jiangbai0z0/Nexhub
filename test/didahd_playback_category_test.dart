// 嘀嗒影视（pms_didahd）播放/分类修复的回归测试（v2，2026-10-05）。
//
// v1 播放层降级（migrationMessage 声明播放需 WebView 通道）的结论已过时：
// 实测播放页 player_aaaa 的 ffm3u8 线（sid=1，非凡云）url 为明文 m3u8 直链，
// 引擎 VideoExtractor 应能从内联脚本抽出该地址，无需 WebView。
// 分类：MacCMS ajax/data 的过滤参数为 tid（type 参数无效），「全部」用
// {category?} 可选标记在空值时整段移除。
// HTML/JSON fixture 为 2026-10-05 实抓样本，用于锁定真实页面形态。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/resolver/builtin_resolver.dart';
import 'package:nexhub/core/resolver/video_extractor.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

PluginConfig _loadSource() {
  final map =
      jsonDecode(File('plugins/builtin/pms_didahd.json').readAsStringSync())
          as Map<String, dynamic>;
  return PluginConfig.fromJson(map);
}

void main() {
  group('VideoExtractor · 嘀嗒影视播放页（真实 HTML fixture）', () {
    test('ffm3u8 线（sid=1）：抽出明文 m3u8 直链', () {
      final html = _fixture('didahd_play_ffm3u8.html');
      final videos = VideoExtractor.extract(
        html,
        baseUrl: 'https://www.didahd.xyz/play/3842-1-1.html',
      );
      expect(videos, isNotEmpty, reason: '播放页内联脚本含明文 m3u8，应可抽取');
      final urls = videos.map((v) => v.url).toList();
      expect(
        urls.any((u) => u.startsWith('https://') &&
            u.contains('.m3u8') &&
            u.contains('ffzy')),
        isTrue,
        reason: '应命中非凡云（ffzy）m3u8，实际: $urls',
      );
    });

    test('baidu 网盘线（sid=2）：解析不到可播放直链（预期失败而非误报）', () {
      final html = _fixture('didahd_play_baidu.html');
      final videos = VideoExtractor.extract(
        html,
        baseUrl: 'https://www.didahd.xyz/play/3842-2-1.html',
      );
      final playable = videos
          .where((v) => v.url.contains('.m3u8') || v.url.contains('.mp4'))
          .toList();
      expect(playable, isEmpty, reason: '百度网盘分享链接不是媒体直链，不应误报为可播放');
    });
  });

  group('PluginConfig · 嘀嗒影视配置结构', () {
    test('版本/路由就位 + video 路由 {url} 直通', () {
      final config = _loadSource();
      expect(config.version, 3);
      expect(config.routes['video'], isNotNull, reason: '必须声明 video 路由才能走内置解析');
      expect(config.routes['category'], isNotNull);
      final url = config.resolveRouteUrl(
        'video',
        activeBaseUrl: config.site.baseUrl,
        vars: {'url': '/play/3842-1-1.html'},
      );
      expect(url, 'https://www.didahd.xyz/play/3842-1-1.html');
      // 绝对地址 episode href 也不应被拼出双 host 坏链。
      final url2 = config.resolveRouteUrl(
        'video',
        activeBaseUrl: config.site.baseUrl,
        vars: {'url': 'https://www.didahd.xyz/play/3842-1-1.html'},
      );
      expect(url2, 'https://www.didahd.xyz/play/3842-1-1.html');
    });

    test('category 路由：tid 过滤 + 「全部」空值整段移除', () {
      final config = _loadSource();
      final t4 = config.resolveRouteUrl(
        'category',
        activeBaseUrl: config.site.baseUrl,
        vars: {'category': '4', 'page': '2'},
      );
      expect(t4, contains('tid=4'));
      expect(t4, contains('page=2'));

      final all = config.resolveRouteUrl(
        'category',
        activeBaseUrl: config.site.baseUrl,
        vars: {'category': '', 'page': '1'},
      );
      expect(all, isNot(contains('tid=')), reason: '「全部」时 tid 整段移除，等价全站');
      expect(all, contains('page=1'));
    });

    test('分类 entries 覆盖首页导航五个一级分类 + 全部', () {
      final config = _loadSource();
      final entries = config.category.categoryEntries;
      final ids = entries.map((e) => e['id']).toSet();
      expect(ids, containsAll(['', '1', '2', '3', '4', '5']));
      expect(entries.length, 6);
    });

    test('category JSON 响应与 latest 同构（真实抓包 fixture，tid=4）', () {
      final catJson =
          jsonDecode(_fixture('didahd_category_t4.json')) as Map<String, dynamic>;
      final list = catJson['list'] as List;
      expect(list, isNotEmpty);
      for (final item in list.cast<Map>()) {
        expect(item['vod_id'], isNotNull);
        expect(item['vod_name'], isNotNull);
        expect(item['vod_pic'], isNotNull);
        // MacCMS tid 过滤含子分类：子类的 type_id 是自身 id，type_id_1 才是父分类。
        final typeId = item['type_id'];
        final typeId1 = item['type_id_1'];
        expect(
          typeId == 4 || typeId1 == 4,
          isTrue,
          reason: 'tid=4 过滤应只返回动漫及其子分类，实际 type_id=$typeId type_id_1=$typeId1',
        );
      }
    });
  });

  group('VideoExtractor.playerRe · MacCMS 一层嵌套（vod_data）', () {
    test('player_aaaa 含 vod_data 子对象时模式1可直接命中（encrypt=3 明文透传）', () {
      const html = '<script>var player_aaaa={"flag":"play","encrypt":3,'
          '"vod_data":{"vod_name":"测试"},"url":"https://cdn.example.com/x/index.m3u8",'
          '"from":"ffm3u8","sid":1,"nid":1}</script>';
      final videos = VideoExtractor.extract(html, baseUrl: 'https://x.test/');
      expect(videos, isNotEmpty);
      expect(videos.first.url, 'https://cdn.example.com/x/index.m3u8');
    });
  });

  group('pms_didahd 选集解析 · 真实详情页 fixture（v3 选择器修复）', () {
    // v1 的列表选择器 ul.myui-play-list 在页面中不存在，选集恒为 0 条
    // （表现为「详情页没有解析到视频」无法播放）。v3 改为真实存在的
    // ul.myui-content__list，容器用 [id^=playlist] 精确圈定（排除推荐区）。
    late PluginConfig source;

    setUpAll(() => source = _loadSource());

    test('多线路长番（2943 欺诈游戏）：6 线路 81 集，线路名与集数对齐', () async {
      final html = _fixture('didahd_detail_2943.html');
      final r =
          await const BuiltinResolver().resolveFromHtml(source, 'episodes', html);
      expect(r, isA<List<Episode>>());
      final eps = r as List<Episode>;
      expect(eps.length, 81);

      final byLine = <String, List<Episode>>{};
      for (final e in eps) {
        byLine.putIfAbsent(e.lineName ?? '', () => []).add(e);
      }
      expect(byLine.keys.toList(),
          ['超清G', '超清B', '超清K', 'UC网盘', '夸克网盘', '百度网盘'],
          reason: '线路名应与 nav-tabs 一致，且不被「同类型/同主演」推荐页签污染');
      expect(byLine['超清G']!.length, 26);
      expect(byLine['超清G']!.first.url, '/play/2943-4-1.html');
      expect(byLine['超清G']!.last.url, '/play/2943-4-26.html');
      expect(byLine['夸克网盘']!.length, 1, reason: '网盘线只挂合集链接');
    });

    test('连载新番（3842）：4 线路各 1 集，sid 与 href 原样保留', () async {
      final html = _fixture('didahd_detail_fresh.html');
      final r =
          await const BuiltinResolver().resolveFromHtml(source, 'episodes', html);
      expect(r, isA<List<Episode>>());
      final eps = r as List<Episode>;
      expect(eps.length, 4);
      final urls = eps.map((e) => e.url).toSet();
      expect(urls,
          containsAll(['/play/3842-1-1.html', '/play/3842-3-1.html']));
      expect(eps.first.lineName, isNotEmpty);
    });
  });
}
