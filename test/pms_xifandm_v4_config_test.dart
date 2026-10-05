import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/utils/json_path.dart';

/// pms_xifandm v4 配置回归（2026-10-05）：
/// 站点由 MacCMS（anime.xifanacg.com）301 迁移至 Next.js 新站
/// （next.xifanacg.com），旧 MacCMS 接口全部失效；数据改走新站 Supabase
/// 后端 api.xifanacg.com（PostgREST 公开表 animes/episodes + 播放签发
/// Edge Function）。引擎为此新增：路由/站点 headers 合并、路由 body 模板
/// POST、「参数名={参数名}」空值整段移除——本测试锁住这三个通用能力与
/// 该源的 URL 拼装形态。
void main() {
  late PluginConfig source;

  setUpAll(() {
    final file = File('plugins/builtin/pms_xifandm.json');
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    source = PluginConfig.fromJson(map);
  });

  group('pms_xifandm v4 配置消费', () {
    test('版本/类型/路由与站点鉴权头就位', () {
      expect(source.version, 4);
      expect(source.id, 'pms_xifandm');
      expect(source.type, SourceType.animeSource);
      expect(source.site.baseUrl, 'https://api.xifanacg.com');
      expect(source.site.headers?['apikey'], isNotEmpty);
      expect(source.site.headers?['Authorization'], contains('Bearer '));
      for (final api in <String>[
        'latest',
        'search',
        'detail',
        'episodes',
        'video',
        'category',
      ]) {
        expect(source.routes.containsKey(api), isTrue, reason: '缺路由 $api');
      }
      // 站点迁移后旧 MacCMS 域名/接口不得再出现在任何路由（其接口已全部
      // 301；migrationMessage 文案提及旧域名属正常）。
      for (final r in source.routes.values) {
        expect(r.url, isNot(contains('anime.xifanacg.com')));
        expect(r.url, isNot(contains('ds_api')));
        expect(r.url, isNot(contains('ajax/data')));
      }
    });

    test('video 路由声明 JSON body 模板（隐含 POST）', () {
      final route = source.routes['video']!;
      expect(route.body, isNotNull);
      expect(route.body, contains('"action":"fallback"'));
      expect(route.body, contains('{url}'));
      expect(route.headers?['Content-Type'], 'application/json');
    });
  });

  group('路由 URL 拼装（resolveRouteUrl）', () {
    test('latest：offset 占位符算术 {page*20-20}', () {
      final p1 = source.resolveRouteUrl(
        'latest',
        activeBaseUrl: source.site.baseUrl,
        vars: const {'page': '1'},
      );
      final p2 = source.resolveRouteUrl(
        'latest',
        activeBaseUrl: source.site.baseUrl,
        vars: const {'page': '2'},
      );
      expect(p1, contains('offset=0'));
      expect(p2, contains('offset=20'));
      expect(p1.contains('{'), isFalse, reason: '不得残留占位符: $p1');
    });

    test('category：空筛选整段移除，不留 `meta_tags=` 空参数（PostgREST 400 根因）', () {
      final url = source.resolveRouteUrl(
        'category',
        activeBaseUrl: source.site.baseUrl,
        vars: const {
          'category': '1',
          'page': '1',
          'class': '',
          'year': '',
          'by': 'updated_at.desc',
        },
      );
      expect(url, contains('type_id=eq.1'));
      expect(url, contains('order=updated_at.desc'));
      expect(url, isNot(contains('meta_tags=')), reason: url);
      expect(url, isNot(contains('release_year=')), reason: url);
      expect(url.contains('{'), isFalse, reason: url);
    });

    test('可选标记 {k?} 语义：普通 {k} 空值保留参数（MacCMS 旧语义不回归）', () {
      final cfg = PluginConfig.fromJson(<String, dynamic>{
        'id': 't',
        'type': 'animeSource',
        'site': const {'domain': 'example.com', 'baseUrl': 'https://example.com'},
        'routes': const {'search': 'https://example.com/list?query={query}&page=1'},
      });
      final kept = cfg.resolveRouteUrl(
        'search',
        activeBaseUrl: 'https://example.com',
        vars: const {'query': '', 'page': '1'},
      );
      expect(kept, contains('query='));
      // 显式可选标记：空值整段移除（参数名可与占位符名不同）。
      const optUrl =
          'https://api.example.com/x?select=id&meta_tags={class?}&limit=5';
      final cfg2 = PluginConfig.fromJson(<String, dynamic>{
        'id': 't2',
        'type': 'animeSource',
        'site': const {
          'domain': 'api.example.com',
          'baseUrl': 'https://api.example.com',
        },
        'routes': const {'category': optUrl},
      });
      final removed = cfg2.resolveRouteUrl(
        'category',
        activeBaseUrl: 'https://api.example.com',
        vars: const {'class': ''},
      );
      expect(removed, 'https://api.example.com/x?select=id&limit=5');
      // 变量整体缺失（无 defaults）同样整段移除。
      final absent = cfg2.resolveRouteUrl(
        'category',
        activeBaseUrl: 'https://api.example.com',
        vars: const <String, String>{},
      );
      expect(absent, 'https://api.example.com/x?select=id&limit=5');
    });

    test('category：中文类型值编码花括号（cs.{奇幻} → %7B…%7D），直写合法数组字面量', () {
      final url = source.resolveRouteUrl(
        'category',
        activeBaseUrl: source.site.baseUrl,
        vars: const {
          'category': '1',
          'page': '1',
          'class': 'cs.{奇幻}',
          'year': 'eq.2026',
          'by': 'view_count.desc',
        },
      );
      expect(url, contains('meta_tags=cs.%7B%E5%A5%87%E5%B9%BB%7D'), reason: url);
      expect(url, contains('release_year=eq.2026'));
      expect(url, contains('order=view_count.desc'));
      // 值里的花括号必须被编码，否则会被占位符 cleanup 吞掉。
      expect(url.contains('{奇幻}'), isFalse, reason: url);
    });

    test('search：关键词 URL 编码进 or= 三路 ilike', () {
      final url = source.resolveRouteUrl(
        'search',
        activeBaseUrl: source.site.baseUrl,
        vars: const {'keyword': '海贼王', 'page': '1'},
      );
      expect(url, contains(Uri.encodeComponent('海贼王')));
      expect(url, contains('search_title.ilike.'));
      expect(url.contains('{'), isFalse, reason: url);
    });

    test('body 模板直替：episode_id 以数字注入（签发接口仅收数值）', () {
      final body = PluginConfig.interpolateRouteBody(
        source.routes['video']!.body!,
        const {'url': '101040'},
      );
      expect(body, '{"action":"fallback","episode_id":101040}');
      // 必须是合法 JSON 且 episode_id 为数值。
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect(decoded['episode_id'], 101040);
      expect(decoded['action'], 'fallback');
    });

    test('body 模板：未命中占位符被清理，不产出坏 JSON', () {
      // 裸单词占位符清理；JSON 结构花括号（键值均带引号）不受影响。
      final body = PluginConfig.interpolateRouteBody(
        '{"a":"{missing}","b":"{url}"}',
        const {'url': '1'},
      );
      expect(body, '{"a":"","b":"1"}');
      final structural = PluginConfig.interpolateRouteBody(
        '{"k":"{url}"}',
        const {'url': '9'},
      );
      expect(structural, '{"k":"9"}');
    });
  });

  group('选择器语义（PostgREST 裸数组响应）', () {
    final rows = <dynamic>[
      {'id': 3282, 'title': '名侦探光之美少女！', 'cover_url': 'https://img/x.jpg'},
      {'id': 3506, 'title': '黑化吧！圣女大人 Season2'},
    ];

    test('list "\$" 直接求值裸数组根', () {
      final r = JsonPath.eval('\$', rows);
      expect(r, same(rows));
    });

    test('detail 选择器 \$[0].x 命中首元素；空数组安全为空', () {
      expect(JsonPath.eval(r' $[0].title'.trim(), rows), '名侦探光之美少女！');
      expect(JsonPath.eval(r' $[0].director'.trim(), rows), isNull);
      expect(JsonPath.eval(r' $[0].title'.trim(), <dynamic>[]), isNull);
    });

    test('episodes：id/url 同取数值集数 id（video body 的 {url} 来源）', () {
      final sel = source.selectors?['episodes'] as Map;
      expect(sel['url'], '\$.id');
      final ep = <String, dynamic>{
        'id': 101040,
        'episode_number': 1.0,
        'title': null,
      };
      expect(JsonPath.eval(sel['id'] as String, ep), 101040);
      expect(JsonPath.eval(sel['url'] as String, ep), 101040);
      expect(JsonPath.eval(sel['number'] as String, ep), 1.0);
    });
  });
}
