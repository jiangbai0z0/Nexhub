import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';

/// pms_javchu.json 配置层验收。v4 起 javchu.com（官方第四镜像域）已停放
/// （80=Namecheap parking、源站 IP 全死），源整体迁移到主域 hanime1.me 的
/// AV 分区——与 pms_hanime 同平台同结构，仅 genre/tags/sort 值域不同。
/// 验收用引擎真实的 PluginConfig.fromJson 消费交付物文件。
void main() {
  late PluginConfig source;

  setUpAll(() {
    final file = File('plugins/builtin/pms_javchu.json');
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    source = PluginConfig.fromJson(map);
  });

  group('pms_javchu 独立源配置', () {
    test('基础块：独立 id、同构路由集', () {
      expect(source.id, 'pms_javchu');
      expect(source.type, SourceType.animeSource);
      expect(source.site.baseUrl, 'https://hanime1.me');
      for (final r in const [
        'latest',
        'search',
        'detail',
        'episodes',
        'category',
        'video',
        'favorites',
        'favoritesAdd',
      ]) {
        expect(source.routes.containsKey(r), isTrue, reason: '路由 $r 就位');
      }
    });

    test('hosts：hanime1.me 三条官方 DNS 实测 IP（v5 换掉会过期的 CF 快照）', () {
      final hosts = source.network?.hosts ?? const <dynamic>[];
      final meHosts = hosts.where((h) => '${h.host}' == 'hanime1.me').toList();
      expect(meHosts.length, 3,
          reason: 'v5 与 pms_hanime v28 同步：doh.pub 权威 A 记录实测可用三值');
      final ips = meHosts.map((h) => '${h.ip}').toSet();
      expect(ips, <String>{
        '104.26.9.104', '172.67.74.156', '104.26.8.104',
      });
      expect(meHosts.every((h) => '${h.enabled}' == 'true'), isTrue);
      // 旧 CF 快照 IP：其中 3/5 返回 error 1034（Edge IP Restricted，该边缘 IP
      // 未获本站授权），TCP 通但应用层 403 弹验证——必须全清。
      for (final bad in const [
        '172.64.229.154', '162.159.0.1', '108.162.192.1',
        '172.64.33.1', '104.19.0.1',
      ]) {
        expect(ips.contains(bad), isFalse, reason: 'CF 快照 IP $bad 已剔除');
      }
      // 死域残留必须清干净——停放域 IP（2.59 WorldStream 死源站 /
      // 104.219 Namecheap 停放页）留着只会 TLS 炸或拉到 parking 页。
      expect(
        ips.intersection(<String>{'2.59.170.20', '104.219.250.37'}),
        isEmpty,
      );
    });

    test('v5 去 bot UA：源内不再有任何 Dart/3.13 冒充浏览器的声明', () {
      final raw = File('plugins/builtin/pms_javchu.json').readAsStringSync();
      expect(raw.contains('Dart/3.13'), isFalse,
          reason: 'bot UA 覆盖基础 UA → 与验证 WebView 的真实 UA 不一致，'
              'cf_clearance 会话失效，反复弹验证');
      expect(source.site.userAgent, anyOf(isNull, isEmpty));
      expect(source.antiHotlinking.userAgent, anyOf(isNull, isEmpty));
      for (final e in source.routes.entries) {
        final headers = e.value.headers;
        expect(headers?.containsKey('User-Agent') ?? false, isFalse,
            reason: '路由 ${e.key} 不应再声明 User-Agent');
      }
      // Referer 保留（站点校验来源），与 hanime 源同构。
      expect(source.antiHotlinking.referer, 'https://hanime1.me');
    });

    test('死域零残留：javchu.com 域名在交付物中完全消失', () {
      final raw = File('plugins/builtin/pms_javchu.json').readAsStringSync();
      expect(raw.contains('javchu.com'), isFalse,
          reason: 'javchu.com 已停放（Namecheap parking + 源站 IP 全死），'
              '26 处引用必须全部迁 hanime1.me');
      // mirrors/hosts/cookieDomains 全部指向主域。
      for (final m in source.site.mirrors) {
        expect(m.domain, 'hanime1.me');
        expect(m.baseUrl, 'https://hanime1.me');
      }
      final hosts = source.network?.hosts ?? const <dynamic>[];
      expect(hosts.every((h) => '${h.host}' == 'hanime1.me'), isTrue);
      final domains = source.network?.cookieDomains ?? const <String>[];
      expect(domains, <String>['hanime1.me', '.hanime1.me']);
    });

    test('评论/收藏链路同构落地', () {
      final comments = source.comments;
      expect(comments!.login!.url, 'https://hanime1.me/login');
      // Laravel 会话键名同构（参考对照数据四站共用同一 cookie jar 语义）。
      expect(comments.login!.checkCookie, 'hanime1_session');
      expect(comments.routes.containsKey('list'), isTrue);
      expect(comments.routes.containsKey('replies'), isTrue);
      final wf = source.webFavorite!;
      expect(wf.route, 'favorites');
      expect(wf.addRoute, 'favoritesAdd');
      expect(source.hasWebFavoriteBrowse, isTrue);
      expect(source.hasWebFavoriteAdd, isTrue);
      final ov = source.parser.overrides ?? const <String, ParserOverride>{};
      expect(ov['favList']?.type, 'script');
      expect(ov['folders']?.type, 'script');
      expect(ov['favoritesAdd']?.type, 'script');
    });

    test('v7 筛选全走 tags 面：死 AV genre 值清零 + 5 组同路由声明', () {
      final raw = File('plugins/builtin/pms_javchu.json').readAsStringSync();
      // v7 拔掉 6 个死 AV genre 值：那是 javchu.com 自站的值，搬到 hanime1.me
      // 后实测 11639~11670B 空结果页（唯一卡 0）——站点上不存在这些值。
      for (final dead in const [
        '日本AV', '素人業餘', '高清無碼', 'AI解碼', '國產AV', '國產素人',
      ]) {
        expect(raw.contains(dead), isFalse, reason: '死 AV 分类值已清：$dead');
      }
      // javchu 也不再复用 hanime 的里番向 genre 值（走 tag 面）。
      for (final banned in const ['裏番', '泡麵番', 'Motion Anime', '新番預告']) {
        expect(raw.contains(banned), isFalse, reason: 'AV 源无此类型：$banned');
      }
      expect(source.version, 7);

      // 分类路由必须把 tag 值送进 tags[] 槽位。v6 误用
      // /search?genre={category}&page={page} —— tag 值塞 genre 槽位恒 0 卡。
      expect(source.routes['category']!.url, contains('tags[]={category}'),
          reason: 'v7 分类路由改 tags[] 槽位（实测 200 / 59 卡）');
      expect(source.routes['category']!.url, isNot(contains('genre=')),
          reason: 'genre 槽位不再承接 tag 值');
      expect(source.routes['search']!.url, contains('tags[]={tags}'),
          reason: '与 hanime 同构：tags[] 重复参数数组语义');
      expect(raw.contains('&tags={tags}'), isFalse);

      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      final byId = {for (final g in groups) g.id: g};
      // 原 genre 组整体移除（无任何活值可承载）。
      expect(byId.containsKey('genre'), isFalse);
      final tagGroup = byId['tags']!;
      expect(tagGroup.multiSelect, isTrue, reason: 'tags 面支持多选');
      final tagValues = tagGroup.options.map((o) => o.value).toSet();
      expect(tagValues, <String>{
        '無碼', '人妻', '風俗娘', '痴女', '痴漢', '調教', '性奴隸', '巨乳',
        '中文字幕',
      }, reason: '站点实测有结果的 AV 向 tag（各 59 卡）');
      // 分类 Tab 与 tags 组同值集（分类就是 tags 面的入口）。
      final catValues = source.category.categoryEntries
          .map((e) => e['id'])
          .toSet();
      expect(catValues, tagValues.difference(<String>{'中文字幕'}),
          reason: '8 个分类 = tags 组去掉中文字幕');
    });

    test('v7 筛选分组全部声明 route=search（消除跨路由互斥清空）', () {
      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      expect(groups.length, 5, reason: 'tags/sort/date/duration/broad');
      for (final g in groups) {
        expect(g.route, 'search',
            reason: '分组 ${g.id} 必须声明 route，否则回落 category 与 tags 组'
                '跨路由互斥、互相清空已选项');
      }
      expect(source.filters!.route, 'search');
      final byId = {for (final g in groups) g.id: g};
      expect(byId['sort']!.options.map((o) => o.value).toSet().length, 9,
          reason: '站点排序 9 值');
      expect(byId['date']!.options.length, 6, reason: 'v7 新增日期面');
      expect(byId['duration']!.options.length, 8, reason: 'v7 新增时长面');
      expect(byId['broad']!.options.length, 2);
      // date/duration 值用站点繁体原文（实测 date=過去 24 小時 → 8 卡真过滤）。
      expect(byId['date']!.options.map((o) => o.value), contains('過去 24 小時'));
      expect(
          byId['duration']!.options.map((o) => o.value), contains('10 分鐘 +'));
    });

    test('v7 homeSections：12 版块全部改用站点真实 tag/排序参数', () {
      final sections = source.homeSections;
      expect(sections.length, 12, reason: 'AV 分区 12 版块');
      expect(sections.every((s) => s.route == 'search'), isTrue);
      HomeSectionConfig sectionOf(String id) =>
          sections.firstWhere((x) => x.id == id);
      Map<String, Object> paramsOf(String id) => sectionOf(id).params;

      // 8 个 tag 版块逐一落地（tag 值实测各 59 卡）。
      const tagSections = <String, String>{
        'nomask': '無碼',
        'hitozuma': '人妻',
        'fuzoku': '風俗娘',
        'chijo': '痴女',
        'chikan': '痴漢',
        'kyoiku': '調教',
        'dorei': '性奴隸',
        'kyonyu': '巨乳',
      };
      for (final e in tagSections.entries) {
        expect(paramsOf(e.key)['tags'], e.value, reason: '版块 ${e.key}');
        expect(paramsOf(e.key)['sort'], '最新上傳');
        expect(paramsOf(e.key).containsKey('genre'), isFalse,
            reason: 'v7 版块不再走 genre 槽位');
      }
      expect(paramsOf('chinese-subtitle')['tags'], '中文字幕');
      expect(paramsOf('chinese-subtitle')['sort'], '最新上傳');
      expect(paramsOf('latest-release')['sort'], '最新上市');
      expect(paramsOf('latest-upload')['sort'], '最新上傳');
      expect(paramsOf('watching-now')['sort'], '他們在看');
      // 全部版块参数里不得再出现死 AV genre 值。
      for (final s in sections) {
        expect(s.params.containsKey('genre'), isFalse,
            reason: '版块 ${s.id} 不应有 genre 参数');
      }
    });
  });
}
