import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';

/// pms_hanime.json v22 配置层验收：用引擎真实的 PluginConfig.fromJson 消费
/// 交付物文件，验证评论/网络收藏新增块的全部关键字段按引擎契约落地。
void main() {
  late PluginConfig source;

  setUpAll(() {
    final file = File('plugins/builtin/pms_hanime.json');
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    source = PluginConfig.fromJson(map);
  });

  group('pms_hanime v22→v28 配置消费', () {
    test('版本号与基础块保持 v21 兼容（v30 = 收藏三形态 + 播放清单）', () {
      expect(source.version, 30);
      expect(source.id, 'pms_hanime');
      expect(source.type, SourceType.animeSource);
      expect(source.routes.containsKey('latest'), isTrue);
      expect(source.routes.containsKey('search'), isTrue);
      expect(source.routes.containsKey('detail'), isTrue);
      expect(source.routes.containsKey('episodes'), isTrue);
      expect(source.routes.containsKey('category'), isTrue);
      expect(source.routes.containsKey('video'), isTrue);
      // v22 列表 id 改提纯数字 code（评论/收藏路由可用），detailUrl 显式补齐
      final searchSel = source.selectors?['search'];
      expect(searchSel, isNotNull);
      expect(searchSel!['id'], "substring-after(//a/@href, 'watch?v=')");
      expect(searchSel['detailUrl'], '//a/@href');
      final categorySel = source.selectors?['category'];
      expect(categorySel!['id'], "substring-after(//a/@href, 'watch?v=')");
    });

    test('comments.login 修键：hanime1_session（真实登录态 cookie）', () {
      final comments = source.comments!;
      expect(comments.login, isNotNull);
      expect(comments.login!.url, 'https://hanime1.me/login');
      expect(comments.login!.checkCookie, 'hanime1_session');
    });

    test('comments.routes：list/replies 路由与 responseType', () {
      final comments = source.comments!;
      // routes 是独立命名空间（comments.routes 而非顶层 routes）
      expect(comments.routes, isNotNull);
      expect(comments.routes.containsKey('list'), isTrue,
          reason: 'list 为必需路由');
      expect(comments.routes.containsKey('replies'), isTrue,
          reason: '回复折叠加载依赖 replies 路由');
      expect(comments.routes['list']!.url,
          contains('/loadComment?type=video&id={id}'));
      expect(comments.routes['replies']!.url, contains('/loadReplies?id={commentId}'));
    });

    test('comments.selectors：embedded 块级 + routeSelectors.replies 覆盖', () {
      final sel = source.comments!.selectors;
      expect(sel, isNotNull);
      expect(sel!['items'], r'$.comments');
      expect(sel['embeddedHtml'], true);
      expect(sel['container'], '#comment-start');
      expect(sel['chunkSize'], 4);
      expect(sel['commentId'],
          "substring-after(//div[starts-with(@id,'reply-section-wrapper')]/@id, 'wrapper-')");
      // routeSelectors 嵌在 selectors 块内（引擎 _selectorsFor 契约）
      final rs = sel['routeSelectors'];
      expect(rs, isA<Map>());
      final replies = (rs as Map)['replies'];
      expect(replies, isA<Map>());
      final rSel = replies as Map;
      expect(rSel['items'], r'$.replies');
      expect(rSel['container'], "div[id^='reply-start']");
      expect(rSel['chunkSize'], 2);
      // commentId:null 清除块级继承（回复楼无 id 语义）
      expect(rSel.containsKey('commentId'), isTrue);
      expect(rSel['commentId'], isNull);
      expect(rSel['likeCount'],
          "//div[@id='comment-like-form-wrapper']/span[2]");
    });

    test('webFavorite：门控/列表/添加三链路字段全部落地', () {
      final wf = source.webFavorite!;
      expect(wf.enabled, isTrue);
      expect(wf.route, 'favorites');
      expect(wf.listEntry, 'favList');
      expect(wf.folders, isTrue);
      expect(wf.requireLogin, isTrue);
      // UI 门控（hasWebFavoriteAdd 只认顶层 addRoute + routes 键）
      expect(wf.addRoute, 'favoritesAdd');
      expect(wf.add, isNotNull);
      expect(wf.add!.route, 'favoritesAdd');
      // 引擎门控断言
      expect(source.hasWebFavoriteAdd, isTrue,
          reason: '顶层 addRoute=favoritesAdd 且 routes 含该键');
      expect(source.hasWebFavoriteBrowse, isTrue,
          reason: 'route=favorites 且 routes 含该键');
    });

    test('收藏相关路由与脚本 override 就位', () {
      expect(source.routes.containsKey('favorites'), isTrue);
      expect(source.routes.containsKey('favoritesAdd'), isTrue);
      expect(source.routes['favorites']!.url, 'https://hanime1.me/');
      final ov = source.parser.overrides ?? const <String, ParserOverride>{};
      expect(ov.containsKey('folders'), isTrue, reason: 'folders=true 时用 overrides.folders');
      expect(ov.containsKey('favList'), isTrue, reason: 'listEntry=favList');
      expect(ov.containsKey('favoritesAdd'), isTrue);
      expect(ov['favList']?.type, 'script');
      expect(ov['folders']?.type, 'script');
      expect(ov['favoritesAdd']?.type, 'script');
      // favoritesAdd 脚本内必须同时含两函数（引擎入口 fallback 契约）
      final script = ov['favoritesAdd']?.script ?? '';
      expect(script, contains('function favoritesAdd('));
      expect(script, contains('function favoritesAddStep2('));
    });

    test('v23 拆源：javchu 不再是 hanime 的镜像', () {
      final raw = File('plugins/builtin/pms_hanime.json').readAsStringSync();
      expect(raw.contains('javchu'), isFalse,
          reason: 'javchu.com 是相似结构的独立网站，已拆为 pms_javchu');
      final hosts = source.network?.hosts ?? const <dynamic>[];
      expect(hosts.where((h) => '${h.host}'.contains('javchu')), isEmpty);
    });

    test('v29 筛选对齐站点表单：genre 10 值含新番預告，search 路由带数组占位', () {
      final raw = File('plugins/builtin/pms_hanime.json').readAsStringSync();
      // 站点搜索表单 genre-option 实测 11 项（全部 + 10 真值），新番預告在列。
      // v24 曾依参考对照数据 genre.json 判断其不存在而剔除，v29 以站点一手取证反转。
      expect(raw.contains('新番預告'), isTrue,
          reason: '站点 genre-option data-value 含「新番預告」（实测 19 卡）');
      expect(source.routes['search']!.url, contains('tags[]={tags}'),
          reason: 'v25 起站点 tags 走 tags[]= 重复参数（数组语义），逗号串会被当成一个不存在的 tag');
      expect(raw.contains('&tags={tags}'), isFalse,
          reason: '旧逗号占位形态必须移除');
      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      final genre = groups.firstWhere((g) => g.id == 'genre');
      final values = genre.options.map((o) => o.value).toSet();
      expect(values.length, 10);
      expect(values, containsAll(<String>[
        '裏番', '泡麵番', 'Motion Anime', '3DCG', '2.5D',
        '2D動畫', 'AI生成', 'MMD', 'Cosplay', '新番預告',
      ]));
      // 站点 10 个 genre 值全部实测有效（裏番 41 / 泡麵番 41 / 新番預告 19 /
      // 其余各 59 卡，无零结果）。分类 Tab 与 genre 组同值集。
      final catValues =
          source.category.categoryEntries.map((e) => e['id']).toSet();
      expect(catValues, values, reason: '分类 Tab 同步到 10 值');
    });

    test('v29 新增 date/duration 两组：值用站点繁体原文并直通路由占位符', () {
      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      final byId = {for (final g in groups) g.id: g};
      final date = byId['date']!;
      expect(date.param, 'date');
      expect(date.multiSelect, isFalse);
      expect(date.options.map((o) => o.value).toList(), <String>[
        '過去 24 小時', '過去 2 天', '過去 1 週',
        '過去 1 個月', '過去 3 個月', '過去 1 年',
      ], reason: '站点 hentai-date-options-wrapper 六值（空值「全部」不列）');
      final duration = byId['duration']!;
      expect(duration.param, 'duration');
      expect(duration.multiSelect, isFalse);
      expect(duration.options.map((o) => o.value).toList(), <String>[
        '1 分鐘 +', '5 分鐘 +', '10 分鐘 +', '20 分鐘 +',
        '30 分鐘 +', '60 分鐘 +', '0 - 10 分鐘', '0 - 20 分鐘',
      ], reason: '站点 hentai-duration-options-wrapper 八值（空值「全部」不列）');
      // 值必须进入 search 路由，否则选了也带不上（引擎按 {date}/{duration}
      // 替换；中文值走 encodeComponent）。
      final url = source.routes['search']!.url;
      expect(url, contains('date={date}'));
      expect(url, contains('duration={duration}'));
    });

    test('v29 全部筛选分组声明 route=search（消除跨路由互斥清空）', () {
      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      expect(groups.length, 12,
          reason: 'genre/sort/date/duration/broad + 7 tags 组');
      for (final g in groups) {
        expect(g.route, 'search',
            reason: '分组 ${g.id} 未声明 route 时回落硬编码 category → '
                '与已声明 search 的分组跨路由互斥、互相清空已选项，'
                '且 __route=category 切到 /search?genre={category} '
                '模板后 genre/sort/tags/broad 占位符全不存在 → 筛选整体失效');
      }
      expect(source.filters!.route, 'search');
    });

    test('v29 tags 面：7 组 240 值全 multiSelect，param=tags，value 繁体 label 简体', () {
      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      final expected = <String, int>{
        'video_attributes': 9,
        'character_relationships': 9,
        'characteristics': 47,
        'appearance_and_figure': 48,
        'story_location': 25,
        'story_plot': 46,
        'sex_positions': 56,
      };
      final titles = <String, String>{
        'video_attributes': '影片属性',
        'character_relationships': '人物关系',
        'characteristics': '角色设定',
        'appearance_and_figure': '外貌身材',
        'story_location': '情景场所',
        'story_plot': '故事剧情',
        'sex_positions': '性交体位',
      };
      var total = 0;
      expected.forEach((id, count) {
        final g = groups.firstWhere(
          (x) => x.id == id,
          orElse: () => throw StateError('缺 tags 组 $id'),
        );
        expect(g.options.length, count, reason: '$id 选项数对齐站点 240 checkbox');
        expect(g.multiSelect, isTrue, reason: '$id 需多选');
        expect(g.param, 'tags', reason: '$id 共用 tags 占位符');
        expect(g.title, titles[id], reason: '$id 标题对齐参考对照数据 zh-rCN strings');
        for (final o in g.options) {
          expect(o.value, isNotEmpty);
          expect(o.label, isNotEmpty);
        }
        // 繁体值→简体名的代表性样例（values 首条：無碼/无码）。
        if (id == 'video_attributes') {
          expect(g.options.first.value, '無碼');
          expect(g.options.first.label, '无码');
        }
        total += g.options.length;
      });
      expect(total, 240, reason: '7 组合计 240 值 = 站点 tags modal 全量');
      // v29 补的 5 个低产 tag（站点实测：黑屌 34 / 哭泣 40 / 體育倉庫 12 卡）。
      final allTags = <String>{
        for (final id in expected.keys)
          ...groups.firstWhere((g) => g.id == id).options.map((o) => o.value),
      };
      expect(allTags.containsAll(<String>[
        '黑屌', '體育倉庫', '哭泣', '玩乳頭', '側面位',
      ]), isTrue, reason: 'v29 逐组差集补齐的 5 个缺失 tag');
    });

    test('v24 homeSections：参考对照数据 12 版块参数映射逐一落地', () {
      final sections = source.homeSections;
      expect(sections.length, 12, reason: '参考对照数据 buildCategoryList 12 版块');
      Map<String, Object> paramsOf(String id) {
        final s = sections.firstWhere((x) => x.id == id);
        return s.params;
      }

      expect(sections.every((s) => s.route == 'search'), isTrue,
          reason: '全部走 search 路由（首页整页混合 12 版块，语义不准）');
      expect(paramsOf('latest-hanime')['genre'], '裏番');
      expect(paramsOf('latest-release')['sort'], '最新上市');
      expect(paramsOf('latest-upload')['sort'], '最新上傳');
      expect(paramsOf('watching-now')['sort'], '他們在看');
      expect(paramsOf('instant-noodle')['genre'], '泡麵番');
      expect(paramsOf('instant-noodle')['sort'], '最新上傳');
      expect(paramsOf('motion-anime')['genre'], 'Motion Anime');
      expect(paramsOf('3d-animation')['genre'], '3DCG');
      expect(paramsOf('animation-2-5d')['genre'], '2.5D');
      expect(paramsOf('animation-2d')['genre'], '2D動畫');
      expect(paramsOf('ai-generated')['genre'], 'AI生成');
      expect(paramsOf('ai-generated')['sort'], '最新上傳');
      expect(paramsOf('mmd')['genre'], 'MMD');
      expect(paramsOf('cosplay')['genre'], 'Cosplay');
    });

    test('v27 去 bot UA：不再用 Dart/3.13 冒充浏览器，改为信任 WebView 注册的真实 UA', () {
      final raw = File('plugins/builtin/pms_hanime.json').readAsStringSync();
      expect(raw.contains('Dart/3.13'), isFalse,
          reason: 'bot UA 由源声明并经 _mergeHeaders 的 ...?extra 覆盖基础 UA，'
              '导致验证 WebView 的 UA 与后续抓取请求不一致 → cf_clearance 失效、反复弹验证');
      expect(source.site.userAgent, anyOf(isNull, isEmpty),
          reason: 'site.userAgent 已移除');
      for (final e in source.routes.entries) {
        expect(e.value.headers?.containsKey('User-Agent') ?? false, isFalse,
            reason: '路由 ${e.key} 不应再声明 User-Agent');
      }
      expect(source.antiHotlinking.userAgent, anyOf(isNull, isEmpty),
          reason: 'antiHotlinking.userAgent 已移除');
      // Referer 必须保留（站点校验来源）
      expect(source.routes['search']!.headers?['Referer'], isNotNull);
      expect(source.antiHotlinking.referer, 'https://hanime1.me');
    });

    test('v27 favList 两跳：首页输入先取 uid 再抓 /user/{uid}/likes', () {
      final ov = source.parser.overrides ?? const <String, ParserOverride>{};
      final script = ov['favList']?.script ?? '';
      expect(script, contains('favListParse'),
          reason: '原解析体改名保留，作为 meta 第二跳处理器');
      expect(script, contains('user-modal-trigger'),
          reason: '从首页 #user-modal-trigger 提 uid（登录后 href=/user/{uid}）');
      expect(script, contains("'/user/'"), reason: '拼真实收藏页 URL');
      expect(script, contains("__processor:'favListParse'"),
          reason: 'meta 协议第二跳处理器名');
      expect(script, contains("__fetchResponseType:'text'"),
          reason: '收藏页是 HTML，须以 text 抓取');
      // 引擎入口 fallback 契约（_runScriptWithRaw: entry = override.function ?? apiName）
      expect(script, contains('function favList('));
      expect(script, contains('function favListParse('));
    });

    test('v30 收藏三形态：folders 三类文件夹、favList 播放清单内容、episodes 分集', () {
      final ov = source.parser.overrides ?? const <String, ParserOverride>{};
      final folders = ov['folders']?.script ?? '';
      expect(folders, contains('playlists'), reason: 'folders 动态拼播放清单文件夹');
      expect(folders, contains("__fetchUrl:base+'/user/'+u+'/playlists'"),
          reason: 'meta 二跳拉 playlists 列表页');
      expect(folders, contains('function foldersParse('));
      expect(folders, isNot(contains("'count'")), reason: '类别总数站点不展示，count 不输出即 UI 无 badge');
      final fav = ov['favList']?.script ?? '';
      expect(fav, contains('function favPlaylistParse('),
          reason: 'playlist?list= 内容页独立解析器');
      expect(fav, contains('data-href'), reason: '内容页卡片以 data-href 承载 watch 链接');
      expect(fav, contains('.replace(/&list=\\d+/g,'),
          reason: '详情 URL 清洗 &list= 尾巴，避免详情/播放串台');
      final eps = ov['episodes']?.script ?? '';
      expect(eps, contains("du0.indexOf('playlist?list=')>=0"),
          reason: '清单 detailUrl 走分集解析而非正片兜底');
      expect(eps, contains('function episodes('));
      // 详情页对 playlist 页的兜底选择器（h1.playlist-title 只存在于清单页）。
      final detailSel = source.selectors?['detail'];
      expect(detailSel, isNotNull);
      expect(detailSel!['title'], contains('.playlist-title'));
      expect(detailSel['cover'], contains('img.main-thumb@src'));
    });

    test('v28 hosts 换权威实测 IP：剔快照/死域，与 DNS 实解一致', () {
      final hosts = source.network?.hosts ?? const <dynamic>[];
      // 曾经参考对照数据 HDns.kt 的 CF 快照 IP，其中 3/5 返回 CF error 1034
      // （Edge IP Restricted，该边缘 IP 未获本站授权），TCP 却通、连接层判定
      // 成功 → 应用层 403 弹验证。全部换成 doh.pub 权威 A 记录实测可用的 IP。
      final ips = hosts.map((h) => '${h.ip}').toSet();
      expect(ips, <String>{
        '104.26.9.104',
        '172.67.74.156',
        '104.26.8.104', // hanime1.me 权威三值，实测 6/6 全 200
        '104.21.42.221',
        '172.67.167.30', // hanime1.com 权威两值，实测 301 → hanime1.me
      });
      expect(hosts, hasLength(5), reason: '3 (me) + 2 (com)');
      // 坏快照 IP 一条都不能留。
      for (final bad in const [
        '172.64.229.154',
        '162.159.0.1',
        '108.162.192.1',
        '172.64.33.1',
        '104.19.0.1',
      ]) {
        expect(ips.contains(bad), isFalse,
            reason: 'CF 快照 IP $bad 实测 403/1034，必须剔除');
      }
      // IPv6 快照同上（实测 403|5507），且站点走 v4 足够。
      expect(hosts.every((h) => !'${h.ip}'.contains(':')), isTrue,
          reason: 'IPv6 快照全部实测不可用，不应保留');
      expect(hosts.every((h) => '${h.enabled}' == 'true'), isTrue);
      final hostNames = hosts.map((h) => '${h.host}').toSet();
      expect(hostNames, <String>{'hanime1.me', 'hanime1.com'});
    });

    test('v28 剔除死域 hanimeone.me：已从 mirrors/hosts/cookieDomains 消失', () {
      final raw = File('plugins/builtin/pms_hanime.json').readAsStringSync();
      // 对照实验定性：hanimeone.me 的权威 A 记录（172.67.215.214 /
      // 104.21.43.14）以自身 SNI 访问全部 000 不可达；同两个 IP 用作
      // hanime1.me 的 --resolve 目标却双双 200 → CF 已摘除该域映射，是死域。
      expect(raw.contains('hanimeone.me'), isFalse,
          reason: '死域残留只会带来一次必然失败的 DNS/连接尝试');
      final mirrors = source.site.mirrors;
      expect(mirrors.map((m) => m.domain), <String>['hanime1.me', 'hanime1.com']);
      expect(source.network?.cookieDomains, <String>[
        'hanime1.me',
        '.hanime1.me',
        'hanime1.com',
        '.hanime1.com',
      ]);
    });
  });
}
