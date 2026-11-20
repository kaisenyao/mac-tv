import Foundation
import Testing
@testable import MacTV

/// 得到：读书架、分类、书单、最近学习、音频，从哪接着听
struct DedaoTests {
    /// 得到回的 {"h":…,"c":{…}} 里的 c
    private func body(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return try #require(object?["c"] as? [String: Any])
    }

    @Test
    func shelfItemsKnowBooksCollectionsCoursesAndFolders() throws {
        let book = try #require(DedaoAPI.item(from: ["enid": "b1", "type": 13, "title": "人类简史", "author": "解读：某某",
                                                     "icon": "//piccdn.example.com/a.jpg", "progress": "40",
                                                     "last_action_time": 1_800_000_000], shelf: .books))
        #expect(book.kind == .book)
        #expect(book.progress == 40)
        #expect(book.cover?.absoluteString == "https://piccdn.example.com/a.jpg")
        #expect(book.studied == 1_800_000_000)
        #expect(book.author == "解读：某某")

        let collection = try #require(DedaoAPI.item(from: ["enid": "c1", "type": 1013, "title": "名家讲书"], shelf: .books))
        #expect(collection.kind == .collection)

        let course = try #require(DedaoAPI.item(from: ["enid": "k1", "title": "课", "publish_num": 120, "progress": 250], shelf: .courses))
        #expect(course.kind == .course)
        #expect(course.count == 120)
        #expect(course.progress == 100)   // 超出范围的按 100 算

        let folder = try #require(DedaoAPI.item(from: ["is_group": true, "group_id": 7, "title": "通勤"], shelf: .courses))
        #expect(folder.kind == .folder(7))
        #expect(folder.id == "group-7")

        // 不是分组又没有编号的：不要
        #expect(DedaoAPI.item(from: ["title": "?"], shelf: .books) == nil)
    }

    @Test
    func bookNamesSplitIntoTitleAndReader() {
        #expect(DedaoAPI.splitName("《给孩子的建筑》| 贾行家解读") == ("《给孩子的建筑》", "贾行家解读"))
        #expect(DedaoAPI.splitName("《我们如何捍卫私人生活》|  林小英解读") == ("《我们如何捍卫私人生活》", "林小英解读"))
        #expect(DedaoAPI.splitName("《赶往火星》｜八光分文化解读") == ("《赶往火星》", "八光分文化解读"))   // 全角竖线
        #expect(DedaoAPI.splitName("（英文原版）Challenger | 刘怡解读") == ("（英文原版）Challenger", "刘怡解读"))
        #expect(DedaoAPI.splitName("本力·揭秘财富第一性") == ("本力·揭秘财富第一性", nil))           // 名家讲书没有解读人
        #expect(DedaoAPI.splitName("《书》|") == ("《书》", nil))
    }

    // MARK: 分类（/pc/sunflower/v1/label/list）

    private let labelList = """
    {"h":{"c":0,"e":""},"c":{"list":[
      {"enid":"ranking:JdeK","id":0,"type":0,"nav_type":1,"name":"热门","label_list":[]},
      {"enid":"pkgGroupType:3yJd","id":0,"type":0,"nav_type":1,"name":"名家讲书","label_list":[]},
      {"enid":"pkgVideoGroupType:3yJd","id":0,"type":0,"nav_type":1,"name":"章鱼书场","label_list":[]},
      {"enid":"VW6o","id":602,"relation_id":602,"type":1,"nav_type":1,"name":"晨间唤醒",
       "label_list":[{"enid":"arxJ","name":"状态启动"},{"enid":"DV4A","name":"市场新书"}]},
      {"enid":"Zgxx","id":700,"relation_id":700,"type":1,"nav_type":1,"name":"镇馆之宝","label_list":null},
      {"enid":"zN7r","id":93,"relation_id":93,"type":1,"nav_type":1,"name":"自然科学",
       "label_list":[{"enid":"X9vmWzAl54WYrJ78ayq1VjKbDeZRxzpvnpXEBOlvko9L026gdm3AnGNMDkG1x8JR","name":"全部"},
                     {"enid":"gMjl","name":"科学思维"},{"enid":"X5j6","name":"天文学"},{"name":"没有编号"}]},
      {"name":"没有编号的分类"}
    ]}}
    """

    @Test
    func topicsKnowRankingsPackagesVideosAndSubjects() throws {
        let topics = DedaoAPI.topics(from: try body(labelList))
        #expect(topics.map(\.name) == ["热门", "名家讲书", "章鱼书场", "晨间唤醒", "镇馆之宝", "自然科学"])
        #expect(topics.map(\.kind) == [.ranking, .package, .video, .subject, .subject, .subject])
        let science = try #require(topics.last)
        // "全部"不算小类，没有编号的不要
        #expect(science.labels == [.init(id: "gMjl", name: "科学思维"), .init(id: "X5j6", name: "天文学")])
        #expect(topics[4].labels.isEmpty)
    }

    @MainActor @Test
    func sidebarPutsHomeFirstThenKnownSubjectsThenNewOnes() throws {
        let sections = DedaoStore.sections(from: DedaoAPI.topics(from: try body(labelList)))
        // 榜单在首页里，视频不要；认得的照顺序排（自然科学在晨间唤醒前），不认得的接在后面
        #expect(sections.map(\.title) == ["首页", "自然科学", "晨间唤醒", "镇馆之宝"])
        #expect(sections.first == .home)
        #expect(sections[1].topic?.id == "zN7r")
        #expect(sections[1].symbol == "atom")
        #expect(sections[3].symbol == "books.vertical.fill")
        // 分类取不到时只有首页
        #expect(DedaoStore.sections(from: []).map(\.id) == ["home"])
        #expect(DedaoStore.sections(from: DedaoAPI.fallbackTopics).map(\.id) == ["home"])
    }

    // MARK: 书单（/pc/label/v2/algo/pc/product/list）

    private let productList = """
    {"h":{"c":0,"e":""},"c":{"product_list":[
      {"item_type":13,"product_type":13,"name":"《给孩子的建筑》| 贾行家解读","intro":"建筑是生活的容器，也是想象的起点。",
       "index_img":"https://piccdn3.umiwi.com/cms_img/a.jpg","id_out":"Gn3OM9gR2qEPrwg4ArNJ816ZVXQjLl",
       "audio_id":"vgj8ow169djr","alias_id":"vgj8ow169djr","has_play_auth":false,"is_vip":false,"progress":0,
       "article_info":{"article_id":8047,"article_audio_duration":1773},"duration":0,
       "hot_learn_desc":"5.6万次学习","score":"4.9","lessons_num":0},
      {"item_type":13,"product_type":1013,"name":"本力·揭秘财富第一性","intro":"穿越盛衰周期",
       "index_img":"http://piccdn3.umiwi.com/img/b.jpeg","id_out":"AeXPDkogNyQnar2kjb4MOmpJV8w7Z6",
       "audio_id":"","alias_id":"","phase_num":2,"lessons_num":2,"score":"","hot_learn_desc":"55万次学习",
       "group_type_name":"名家讲书","odob_alias_list":["7xmo","7vdq"],"progress":"30"},
      {"item_type":66,"product_type":66,"name":"吴军·科技史纲 60 讲","id_out":"k66","phase_num":60,"lessons_num":0,
       "lecturer_name_and_title":"吴军 · 计算机科学家","score":"0"},
      {"item_type":2,"product_type":2,"name":"一本电子书","id_out":"e2"},
      {"product_type":13,"name":"没有编号"}
    ],"request_id":"0d1af921eb93418f88e0278dca3633cd","total":201,"is_more":1}}
    """

    @Test
    func productPagesReadBooksPackagesAndCourses() throws {
        let page = DedaoAPI.productPage(from: try body(productList))
        #expect(page.requestID == "0d1af921eb93418f88e0278dca3633cd")
        #expect(page.more)
        #expect(page.total == 201)
        // 电子书、没有编号的不要
        #expect(page.items.map(\.enid) == ["Gn3OM9gR2qEPrwg4ArNJ816ZVXQjLl", "AeXPDkogNyQnar2kjb4MOmpJV8w7Z6", "k66"])

        let book = page.items[0]
        #expect(book.kind == .book)
        #expect(book.title == "《给孩子的建筑》")
        #expect(book.author == "贾行家解读")
        #expect(book.alias == "vgj8ow169djr")
        #expect(book.duration == 1773)
        #expect(book.heat == "5.6万次学习")
        #expect(book.score == "4.9")
        #expect(book.intro == "建筑是生活的容器，也是想象的起点。")
        #expect(book.cover?.absoluteString == "https://piccdn3.umiwi.com/cms_img/a.jpg")

        let package = page.items[1]
        #expect(package.kind == .collection)
        #expect(package.title == "本力·揭秘财富第一性")
        #expect(package.author.isEmpty)
        #expect(package.count == 2)
        #expect(package.alias.isEmpty)
        #expect(package.score.isEmpty)
        #expect(package.progress == 30)
        #expect(package.cover?.scheme == "https")

        let course = page.items[2]
        #expect(course.kind == .course)
        #expect(course.count == 60)
        #expect(course.shelf == .courses)
        #expect(course.author == "吴军 · 计算机科学家")
        #expect(course.score.isEmpty)   // "0" 分是没有评分

        let last = DedaoAPI.productPage(from: ["product_list": [[String: Any]](), "request_id": "", "total": 3, "is_more": 0])
        #expect(!last.more)
        #expect(last.items.isEmpty)
    }

    // MARK: 最近学习（/api/pc/blade/v2/recent）

    private let recentList = """
    {"h":{"c":0,"e":""},"c":{"list":[
      {"product_id_hazy":"Gn3OM9gR","product_type":13,"title":"《给孩子的建筑》| 贾行家解读",
       "index_img":"https://piccdn3.umiwi.com/a.jpg","timestamp":1795113000000,
       "progress_intro":{"intro":"已听 40%","progress":40,"max_progress":100,"is_finish":false},
       "resource":{"audio_id":"vgj8","audio":{"alias_id":"vgj8","duration":1773,"listen_progress":40.4,"listen_finished":false}},
       "package_info":{"package_pid_hazy":"","package_title":"","package_icon":""}},
      {"product_id_hazy":"k66","product_type":66,"title":"科技史纲 60 讲","author":"吴军","square_img":"//piccdn3.umiwi.com/k.jpg",
       "timestamp":1795112000000,"progress_intro":{"intro":"学到第 3 讲","progress":3,"max_progress":60,"is_finish":0}},
      {"product_id_hazy":"done","product_type":13,"title":"《听完了》| 某某解读","timestamp":1795111000000,
       "resource":{"audio":{"alias_id":"","duration":600,"listen_progress":100,"listen_finished":true}}},
      {"product_id_hazy":"p1013","product_type":1013,"title":"王兴·健康生活实用指南","logo":"https://piccdn3.umiwi.com/p.jpg",
       "timestamp":1795110000000},
      {"product_id_hazy":"ebook","product_type":2,"title":"电子书","timestamp":1795109000000},
      {"product_type":13,"title":"没有编号"}
    ],"timestamp":1795109000000,"has_more":true}}
    """

    @Test
    func recentLearningKeepsOrderAndProgress() throws {
        let page = DedaoAPI.recentPage(from: try body(recentList))
        #expect(page.cursor == 1_795_109_000_000)
        #expect(page.more)
        // 电子书、没有编号的不要；顺序照得到给的（最新的在前）
        #expect(page.items.map(\.enid) == ["Gn3OM9gR", "k66", "done", "p1013"])

        let book = page.items[0]
        #expect(book.kind == .book)
        #expect(book.title == "《给孩子的建筑》")
        #expect(book.author == "贾行家解读")
        #expect(book.progress == 40)          // 先看音频的进度
        #expect(!book.finished)
        #expect(book.alias == "vgj8")
        #expect(book.duration == 1773)
        #expect(book.studied == 1_795_113_000_000)

        let course = page.items[1]
        #expect(course.kind == .course)
        #expect(course.progress == 5)          // 3 / 60
        #expect(course.note == "学到第 3 讲")
        #expect(course.author == "吴军")
        #expect(course.cover?.absoluteString == "https://piccdn3.umiwi.com/k.jpg")
        #expect(course.alias.isEmpty)

        let done = page.items[2]
        #expect(done.finished)
        #expect(done.progress == 100)

        let package = page.items[3]
        #expect(package.kind == .collection)
        #expect(package.progress == 0)
        #expect(package.cover?.absoluteString == "https://piccdn3.umiwi.com/p.jpg")

        // 一页都没有：到头了
        let empty = DedaoAPI.recentPage(from: ["list": [[String: Any]](), "timestamp": 0, "has_more": true])
        #expect(!empty.more)
    }

    @Test
    func tracksResumeWhereYouLeftOffAndKnowWhenTheyCannotPlay() {
        func track(progress: Double, finished: Bool = false, address: String = "https://m.igetget.com/a.m3u8") -> DedaoAPI.Track {
            DedaoAPI.track(["alias_id": "a1", "title": "第一讲", "duration": 600, "listen_progress": progress,
                            "listen_finished": finished, "mp3_play_url": address],
                           title: nil, productEnid: "p", productType: 66, itemEnid: "i", cover: nil)
        }
        #expect(track(progress: 40).resumeAt == 240)
        #expect(track(progress: 40, finished: true).resumeAt == 0)   // 听完了的从头来
        #expect(track(progress: 99).resumeAt == 0)
        #expect(track(progress: 0).resumeAt == 0)
        #expect(track(progress: 10).playable)
        #expect(!track(progress: 10, address: "").playable)          // 没买的、没有音频的
        #expect(!track(progress: 10, address: "ftp://x/y").playable)
        #expect(track(progress: 10).id == "a1")
    }

    // MARK: 文稿（/pc/ddarticle/v1/article/get/v2 的 content：一个 JSON 数组的字符串）

    private let articleContent = """
    [{"aid":"244918","aliasId":"vgj8","desc":"贾行家 亲述","duration":1773,"size":70898211,"title":"《给孩子的建筑》| 贾行家解读","type":"audio"},
     {"type":"salutation","contents":[{"type":"text","text":{"content":"$_IGET_USER_NAME_$,你好"}}],"text":"$_IGET_USER_NAME_$,你好"},
     {"height":6424,"jump":"","legend":"点击查看大图","type":"image","url":"https://piccdn2.umiwi.com/a.png","width":3072},
     {"contents":[{"text":{"content":"前言"},"type":"text"}],"justify":"left","level":2,"text":"前言","type":"header"},
     {"contents":[{"text":{"content":"你好，我是贾行家。"},"type":"text"},{"text":{"content":"\\n"},"type":"text"}],"justify":"left","text":"你好，我是贾行家。\\n","type":"paragraph"},
     {"contents":[{"text":{"content":"孩子需要开阔眼界。"},"type":"text"},
                  {"text":{"content":"建筑师非常适合传授一类知识。","highlight":true},"type":"text"},
                  {"text":{"content":"往往要到五十岁。"},"type":"text"}],"justify":"left","text":"…","type":"paragraph"},
     {"type":"paragraph","text":"只有整段文字的一段"},
     {"type":"paragraph","contents":[{"text":{"content":"   "},"type":"text"}],"text":"   "},
     {"type":"blockquote","text":"建筑是生活的容器"},
     {"type":"list","contents":[[{"type":"text","text":{"content":"第一条"}}],[{"type":"text","text":{"content":"第二条","bold":true}}]]},
     {"type":"elite","text":"解决复杂问题的成熟能力"},
     {"type":"label-group","text":"标签"},
     {"type":"something-new","text":"不认得的不要"}]
    """

    @Test
    func transcriptsReadParagraphsAndSkipPicturesAndAudio() throws {
        let transcript = DedaoAPI.transcript(fromContent: articleContent, userName: "小明")
        let texts = transcript.paragraphs.map(\.text)
        #expect(texts == ["小明，你好", "前言", "你好，我是贾行家。",
                          "孩子需要开阔眼界。建筑师非常适合传授一类知识。往往要到五十岁。", "只有整段文字的一段",
                          "建筑是生活的容器", "· 第一条", "· 第二条", "解决复杂问题的成熟能力"])
        #expect(transcript.paragraphs.map(\.kind) == [.text, .header, .text, .text, .text, .quote, .text, .text, .point])
        #expect(transcript.paragraphs.map(\.id) == Array(0..<9))
        // 划了线的那一句单独标出来
        let marked = transcript.paragraphs[3].runs.filter(\.marked).map(\.text)
        #expect(marked == ["建筑师非常适合传授一类知识。"])
        #expect(transcript.paragraphs[7].runs.last?.marked == true)
        // 每段从第几个字开始（空白不算）
        let lengths = texts.map { $0.filter { !$0.isWhitespace }.count }
        #expect(transcript.paragraphs.map(\.start) == lengths.indices.map { lengths.prefix($0).reduce(0, +) })
        #expect(transcript.characters == lengths.reduce(0, +))

        // 不知道名字：只说"你好"
        #expect(DedaoAPI.transcript(fromContent: articleContent, userName: nil).paragraphs.first?.text == "你好")
        // 读不出来的：空的
        #expect(DedaoAPI.transcript(fromContent: "not json", userName: nil).paragraphs.isEmpty)
        #expect(DedaoAPI.transcript(fromContent: "", userName: nil).characters == 0)
    }

    @Test
    func readAlongIsEstimatedFromCharacterCounts() {
        // 四段，每段 100 字；整篇 400 字
        let paragraphs = (0..<4).map { index in
            DedaoAPI.Transcript.Paragraph(id: index, kind: .text, runs: [.init(text: String(repeating: "字", count: 100), marked: false)],
                                          start: index * 100)
        }
        let transcript = DedaoAPI.Transcript(paragraphs: paragraphs, characters: 400)
        // 全文 100 秒念完（每秒 4 字）：字数和时间成比例
        #expect(!transcript.partial(duration: 100))
        #expect(transcript.paragraph(at: 0, duration: 100) == 0)
        #expect(transcript.paragraph(at: 24, duration: 100) == 0)
        #expect(transcript.paragraph(at: 26, duration: 100) == 1)
        #expect(transcript.paragraph(at: 99, duration: 100) == 3)
        #expect(transcript.paragraph(at: 500, duration: 100) == 3)   // 超出了停在最后一段
        #expect(transcript.time(of: 2, duration: 100) == 50)
        // 音频有 1000 秒、文稿只有 400 字（没买时只给开头）：按正常语速估，念完就停在最后一段
        #expect(transcript.partial(duration: 1000))
        #expect(transcript.paragraph(at: 30, duration: 1000) == 1)    // 30 秒 × 4.3 字 = 129 字
        #expect(transcript.paragraph(at: 900, duration: 1000) == 3)
        #expect(abs(transcript.time(of: 1, duration: 1000) - 100 / 4.3) < 0.001)
        // 没有时长、没有字：第一段
        #expect(transcript.paragraph(at: 10, duration: 0) == 0)
        #expect(DedaoAPI.Transcript(paragraphs: [], characters: 0).paragraph(at: 10, duration: 100) == 0)
    }

    @Test
    func numbersMayArriveAsText() {
        #expect(DedaoAPI.int("12") == 12)
        #expect(DedaoAPI.int("12.7") == 12)
        #expect(DedaoAPI.int(nil) == 0)
        #expect(DedaoAPI.double("1.5") == 1.5)
        #expect(DedaoAPI.string(42) == "42")
        #expect(DedaoAPI.string("") == nil)
        #expect(DedaoAPI.percent(-3) == 0)
        #expect(DedaoAPI.percent(140) == 100)
    }

    @MainActor @Test
    func speedsReadNaturally() {
        // 0.75 到 2，每档差 0.25
        #expect(DedaoPlayer.speeds == [0.75, 1, 1.25, 1.5, 1.75, 2])
        #expect(DedaoPlayer.speeds.map(DedaoStore.speedText) == ["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"])
        #expect(DedaoSleepTimer.choices.count == 5)
    }

    @Test
    func readAlongDependsOnlyOnMediaTimeSoSeekingNeverDrifts() {
        // 十段，长短不一（每段 40 到 220 字），一共 30 分钟
        let lengths = [40, 220, 90, 150, 60, 200, 120, 80, 170, 110]
        var start = 0
        let paragraphs = lengths.enumerated().map { index, count -> DedaoAPI.Transcript.Paragraph in
            defer { start += count }
            return .init(id: index, kind: .text, runs: [.init(text: String(repeating: "字", count: count), marked: false)], start: start)
        }
        let transcript = DedaoAPI.Transcript(paragraphs: paragraphs, characters: start)
        let duration = 1800.0

        // 一路放过来（每半秒报一次时间）走到每一刻时是第几段
        var straight = DedaoReadAlong()
        var lineAt: [Double: Int] = [:]
        for tick in 0...3600 {
            let time = Double(tick) * 0.5
            _ = straight.follow(transcript, time: time, duration: duration)
            lineAt[time] = straight.line
        }
        // 往后拖、往前跳、来回跳、暂停着跳、按住快进中途的每一步：到了同一秒都是同一段
        let jumps: [Double] = [1700, 12, 905.5, 300, 1799.5, 0, 640, 641, 639.5, 1200, 450, 450, 1500.5]
        var seeking = DedaoReadAlong()
        for target in jumps {
            _ = seeking.follow(transcript, time: target, duration: duration)
            #expect(seeking.line == lineAt[target], "跳到 \(target) 秒")
        }
        // 按住快进：每 0.05 秒往前 0.4 秒，走到哪一步都和一路放过来的一样
        var holding = DedaoReadAlong()
        var time = 100.0
        while time < 400 {
            _ = holding.follow(transcript, time: time, duration: duration)
            #expect(holding.line == transcript.paragraph(at: time, duration: duration))
            time += 0.4
        }
        // 倍速只改变念得多快，不改变"第几秒是哪一段"：同一个媒体时间，同一段
        #expect(lineAt[900] == transcript.paragraph(at: 900, duration: duration))
        // 段落变了才算变了（换段时才滚动）
        var along = DedaoReadAlong()
        let first = along.follow(transcript, time: 1, duration: duration)
        let jumped = along.follow(transcript, time: 1000, duration: duration)
        let same = along.follow(transcript, time: 1000.5, duration: duration)
        #expect(!first)
        #expect(jumped)
        #expect(!same)
    }

    @Test
    func sleepTimerCountsDownOrWaitsForTheEndOfTheLecture() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(DedaoSleepTimer(.off, now: now) == nil)
        #expect(DedaoSleepTimer.choices.map(\.title) == ["关闭", "播完本讲", "15 分钟", "30 分钟", "60 分钟"])

        let quarter = try #require(DedaoSleepTimer(.minutes(15), now: now))
        #expect(quarter.deadline == now.addingTimeInterval(900))
        #expect(quarter.remaining(at: now) == 900)
        #expect(quarter.label(at: now) == "15:00")
        #expect(quarter.label(at: now.addingTimeInterval(60.4)) == "14:00")    // 不足一秒的往上算
        #expect(quarter.label(at: now.addingTimeInterval(899.5)) == "0:01")
        #expect(quarter.remaining(at: now.addingTimeInterval(2000)) == 0)       // 过了点就是 0，不会是负的
        #expect(try #require(DedaoSleepTimer(.minutes(60), now: now)).label(at: now) == "60:00")

        let lecture = try #require(DedaoSleepTimer(.endOfTrack, now: now))
        #expect(lecture.deadline == nil)
        #expect(lecture.remaining(at: now) == nil)
        #expect(lecture.label(at: now) == "本讲结束")
    }

    @MainActor @Test
    func sidebarKeepsHomeAndHidesOnlyUncheckedCategories() throws {
        let all = DedaoStore.sections(from: DedaoAPI.topics(from: try body(labelList)))
        #expect(DedaoStore.visible(all, hidden: []).map(\.title) == ["首页", "自然科学", "晨间唤醒", "镇馆之宝"])
        // 勾掉的不显示；首页勾不掉；记的是勾掉的，所以得到新加的分类（这里的"镇馆之宝"）默认显示
        #expect(DedaoStore.visible(all, hidden: ["zN7r", "home"]).map(\.title) == ["首页", "晨间唤醒", "镇馆之宝"])
        #expect(DedaoStore.visible(all, hidden: Set(all.map(\.id))).map(\.title) == ["首页"])
    }

    @Test
    func cancellingIsNotAnError() {
        #expect(DedaoAPI.isCancellation(CancellationError()))
        #expect(DedaoAPI.isCancellation(URLError(.cancelled)))
        #expect(!DedaoAPI.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!DedaoAPI.isCancellation(DedaoError.offline))
    }

    @Test
    func bookTitleSplitsIntoNameAndInterpreter() {
        // "《书名》| 解读人"：大字只写书名，解读人挪到下面一行
        #expect(DedaoPlayerScreen.split("《纳瓦尔宝典》| 听书团队解读") == ("《纳瓦尔宝典》", "听书团队解读"))
        #expect(DedaoPlayerScreen.split("《原则》｜ 刘润解读") == ("《原则》", "刘润解读"))
        // 没有"|"、或者有一边是空的：原样
        let plain = DedaoPlayerScreen.split("第 1 讲 | ")
        #expect(plain.title == "第 1 讲 | " && plain.by == nil)
        #expect(DedaoPlayerScreen.split("发刊词").by == nil)
    }

    // MARK: 主屏顶部

    @MainActor @Test
    func shelfCardsShowTheBookAndWhereYouAre() throws {
        let book = DedaoAPI.Item(kind: .book, enid: "b1", title: "《给孩子的建筑》", author: "贾行家解读", intro: "建筑是生活的容器。",
                                 cover: URL(string: "https://piccdn3.umiwi.com/a.jpg"), progress: 40, finished: false, count: 0,
                                 studied: 0, shelf: .books, duration: 1773)
        let recent = DedaoStore.shelfCard(book, tag: "继续学习", resume: true)
        #expect(recent.tag == "继续学习")
        #expect(recent.title == "给孩子的建筑")                                 // 大标题不要书名号
        #expect(recent.subtitle == "贾行家解读 · 30 分钟")
        #expect(recent.detail == "建筑是生活的容器。")
        #expect(recent.image == book.cover && recent.thumbnail == book.cover)   // 竖封面清楚的放右边，背景用它糊开
        guard case .dedao(_, let resume) = recent.kind else { Issue.record("not a dedao card"); return }
        #expect(resume)                                                             // 最近学习：继续听
        let new = DedaoStore.shelfCard(book, tag: "新书 · 历史", resume: false)
        guard case .dedao(_, let fresh) = new.kind else { return }
        #expect(!fresh)                                                             // 新书：播放
        #expect(new.tag == "新书 · 历史")
        #expect(recent.id != new.id)

        #expect(DedaoStore.progressText(book) == "已听 40%")
        let done = DedaoAPI.Item(kind: .book, enid: "b2", title: "", author: "", intro: "", cover: nil, progress: 100, finished: true,
                                 count: 0, studied: 0, shelf: .books)
        #expect(DedaoStore.progressText(done) == "已听完")
        let untouched = DedaoAPI.Item(kind: .course, enid: "c", title: "", author: "", intro: "", cover: nil, progress: 0, finished: false,
                                      count: 30, studied: 0, shelf: .courses)
        #expect(DedaoStore.progressText(untouched) == nil)
        #expect(DedaoStore.countText(untouched) == "共 30 讲")
        #expect(DedaoStore.shelfCard(untouched, tag: "继续学习", resume: true).subtitle == "课程")
    }

    @Test
    func heroTitlesDropPrefixesAndBookMarks() {
        #expect(DedaoStore.cleanTitle("（英文新书）《繁杂工作》") == ("繁杂工作", "英文新书"))
        #expect(DedaoStore.cleanTitle("（英文原版）Challenger") == ("Challenger", "英文原版"))
        #expect(DedaoStore.cleanTitle("【限时免费】《精进》") == ("精进", "限时免费"))
        #expect(DedaoStore.cleanTitle("《众病之王：癌症传》") == ("众病之王：癌症传", nil))
        #expect(DedaoStore.cleanTitle("带你读懂《荷马史诗》") == ("带你读懂《荷马史诗》", nil))   // 书名号在中间的照留
        #expect(DedaoStore.cleanTitle("本力·揭秘财富第一性") == ("本力·揭秘财富第一性", nil))
        #expect(DedaoStore.cleanTitle("（英文新书）") == ("（英文新书）", nil))               // 只剩括号：原样
        #expect(DedaoStore.minutes(1773) == "30 分钟")
        #expect(DedaoStore.minutes(3900) == "1 小时 5 分钟")
        #expect(DedaoStore.minutes(3600) == "1 小时")
    }

    @MainActor @Test
    func nowPlayingShelfPageSplitsTheTitleAndListsWhatComesNext() {
        func lecture(_ id: String, _ title: String) -> DedaoAPI.Track {
            DedaoAPI.track(["alias_id": id, "title": title, "duration": 600, "mp3_play_url": "https://m.igetget.com/a.m3u8"],
                           title: nil, productEnid: "p", productType: 13, itemEnid: id, cover: nil)
        }
        let now = DedaoStore.shelfNowItem(lecture("a1", "（英文新书）《给孩子的建筑》| 贾行家解读"), paused: false)
        #expect(now.title == "给孩子的建筑")
        #expect(now.subtitle == "贾行家解读 · 10 分钟")
        #expect(now.tag == "正在播放")
        // 停着：同一页（编号不变，不跳页），变成"继续学习"
        let stopped = DedaoStore.shelfNowItem(lecture("a1", "（英文新书）《给孩子的建筑》| 贾行家解读"), paused: true, source: "科技史纲")
        #expect(stopped.id == now.id)
        #expect(stopped.tag == "继续学习")
        #expect(stopped.subtitle == "贾行家解读 · 科技史纲 · 10 分钟")   // 从课程放的：写课程名

        let queue = (1...6).map { lecture("l\($0)", "第\($0)讲") }
        let next = DedaoStore.upcoming(queue, after: 1, count: 3)
        #expect(next.map(\.number) == [3, 4, 5])                 // 序号是在这一串里排第几
        #expect(next.map(\.track.id) == ["l3", "l4", "l5"])
        #expect(DedaoStore.upcoming(queue, after: 4, count: 3).map(\.number) == [6])
        #expect(DedaoStore.upcoming(queue, after: 5, count: 3).isEmpty)   // 最后一讲：后面没有了
        #expect(DedaoStore.upcoming([], after: 0, count: 3).isEmpty)
    }

    @Test
    func newBookPagesSkipWhatYouHeardAndTakeTurnsBetweenCategories() {
        func book(_ id: String, _ title: String, day: Int, progress: Int = 0, alias: String = "") -> DedaoAPI.Item {
            DedaoAPI.Item(kind: .book, enid: id, title: title, author: "", intro: "", cover: URL(string: "https://x.invalid/\(id).jpg"),
                          progress: progress, finished: false, count: 0, studied: 0, shelf: .books, alias: alias,
                          published: 1_794_000_000 + day * 86400)
        }
        let lists: [(category: String, books: [DedaoAPI.Item])] = [
            ("自然科学", [book("s1", "《天文》", day: 9), book("s2", "《物理》", day: 5), book("s3", "《化学》", day: 1)]),
            ("历史", [book("h1", "《中国史》", day: 8), book("h2", "《欧洲史》", day: 7, progress: 30), book("h3", "《美国史》", day: 2)]),
            ("AI", [book("a1", "《大模型》", day: 10, alias: "x1"), book("s1", "《天文》", day: 9)]),
        ]
        // 听过的：最近学习里有同一本（编号对不上也能按音频编号、书名认出来）
        let heard = DedaoStore.heardKeys([book("other-id", "（英文新书）《中国史》", day: 0), book("zz", "?", day: 0, alias: "x1")])
        let picked = DedaoStore.pickNewBooks(lists, heard: heard, count: 5)
        // 第一轮每个分类各一本、新的在前：天文（9 号）；历史的中国史听过、欧洲史听了一半，跳到美国史（2 号）；
        // AI 的大模型听过，下一本天文已经放过了；第二轮：物理
        #expect(picked.map(\.book.enid) == ["s1", "h3", "s2", "s3"])
        #expect(picked.map(\.category) == ["自然科学", "历史", "自然科学", "自然科学"])
        // 够数就停；没有分类就没有
        #expect(DedaoStore.pickNewBooks(lists, heard: [], count: 2).map(\.book.enid) == ["a1", "s1"])
        #expect(DedaoStore.pickNewBooks([], heard: [], count: 7).isEmpty)
    }

    @Test
    func publishDateComesFromTheSortValues() throws {
        let page = DedaoAPI.productPage(from: try body(productList))
        #expect(page.items.allSatisfy { $0.published == 0 })   // 样例里没有 sort_values
        let raw: [String: Any] = ["product_type": 13, "id_out": "n1", "name": "《永明乐》| 赵帅淇解读",
                                  "sort_values": [2, 1795104001000, 1795104001000, -9.223372036854776e18, "7996", "13"]]
        let item = try #require(DedaoAPI.product(from: raw))
        #expect(item.published == 1_795_104_001)
        #expect(DedaoAPI.publishedAt(["sort_values": [2, 0.05, 12]]) == 0)          // 不像时间的不要
    }

    @Test
    func lastHeardQuotesTheParagraphAtThePositionOrGivesWay() {
        let content = """
        [{"type":"header","text":"前言"},
         {"type":"paragraph","text":"你好，我是贾行家。今天为你解读的，是张永和的《给孩子的建筑》。这是第一段，写得长一点，够两三行。"},
         {"type":"header","text":"第一部分"},
         {"type":"paragraph","text":"短的一段。"},
         {"type":"paragraph","text":"接着的一段：建筑是生活的容器，也是想象的起点。"}]
        """
        let transcript = DedaoAPI.transcript(fromContent: content, userName: nil)
        let duration = Double(transcript.characters) / 4   // 每秒四个字，整篇都在
        // 开头：标题跳过，从第一段起
        #expect(DedaoStore.quote(transcript, at: 0, duration: duration)?.hasPrefix("你好，我是贾行家") == true)
        // 念到"短的一段"：太短，接上后面一段
        let short = transcript.paragraphs.first { $0.text == "短的一段。" }!
        let quoted = DedaoStore.quote(transcript, at: transcript.time(of: short.id, duration: duration) + 0.1, duration: duration)
        #expect(quoted == "短的一段。 接着的一段：建筑是生活的容器，也是想象的起点。")
        // 文稿不全（只给了开头）、听到的地方已经在后面了：不放（用介绍）
        #expect(DedaoStore.quote(transcript, at: 1000, duration: 2000) == nil)
        #expect(DedaoStore.quote(DedaoAPI.Transcript(paragraphs: [], characters: 0), at: 0, duration: 10) == nil)
    }

    @MainActor @Test
    func newBookCategoriesAreTheSubjectsNotTheSceneLists() throws {
        let topics = DedaoAPI.topics(from: try body(labelList))
        // 榜单、视频、场景（晨间唤醒）、书单（镇馆之宝）不算；得到新加的主题算
        #expect(DedaoStore.shelfCategories(topics).map(\.name) == ["自然科学"])
        let more = topics + [DedaoAPI.Topic(id: "new", name: "未来新主题", labels: []), DedaoAPI.Topic(id: "zh", name: "职场发展", labels: [])]
        #expect(DedaoStore.shelfCategories(more).map(\.name) == ["职场发展", "自然科学", "未来新主题"])
        let card = DedaoStore.shelfCard(DedaoAPI.Item(kind: .book, enid: "b", title: "", author: "", intro: "", cover: nil, progress: 1,
                                                      finished: false, count: 0, studied: 0, shelf: .books), tag: "继续学习", resume: true)
        #expect(card.id.hasPrefix(DedaoStore.continuePrefix))
    }
}
