"""Build the editable national demonstration map; coordinates are art layout, not surveyed geography."""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGIONS = {
    "liangzhou": ("凉州", [(160,170),(220,145),(285,157),(360,150),(435,177),(500,220),(615,248),(730,260),(795,302),(780,352),(720,380),(645,403),(590,435),(490,442),(432,417),(375,393),(292,410),(250,380),(205,376),(218,311),(181,284),(194,236)], (420,230)),
    "bingzhou": ("并州", [(730,260),(756,216),(795,168),(855,153),(916,170),(944,215),(1008,223),(1080,195),(1107,250),(1112,306),(1073,350),(1085,395),(1030,440),(940,445),(890,416),(805,440),(740,438),(720,380),(780,352),(795,302)], (865,365)),
    "youzhou": ("幽州", [(1080,195),(1130,170),(1146,130),(1200,117),(1240,88),(1310,72),(1360,99),(1430,90),(1465,108),(1546,120),(1605,137),(1680,130),(1735,160),(1680,178),(1622,217),(1517,224),(1450,265),(1360,283),(1301,250),(1208,271),(1174,310),(1112,306),(1107,250)], (1370,130)),
    "jizhou": ("冀州", [(1112,306),(1174,310),(1208,271),(1301,250),(1360,283),(1355,335),(1316,375),(1330,404),(1290,440),(1245,447),(1215,430),(1162,445),(1112,441),(1085,395),(1073,350)], (1200,355)),
    "qingzhou": ("青州", [(1360,283),(1412,290),(1445,325),(1510,321),(1566,340),(1607,365),(1655,371),(1644,400),(1599,406),(1554,421),(1509,429),(1463,450),(1403,460),(1356,453),(1330,404),(1316,375),(1355,335)], (1510,345)),
    "sili": ("司隶", [(590,435),(645,403),(720,380),(740,438),(805,440),(890,416),(940,445),(1030,440),(1085,395),(1112,441),(1097,490),(1119,532),(1095,556),(1013,554),(962,532),(903,557),(843,541),(784,565),(740,549),(682,570),(642,535),(582,537),(546,501)], (875,466)),
    "yanzhou": ("兖州", [(1112,441),(1162,445),(1215,430),(1245,447),(1290,440),(1330,404),(1356,453),(1334,500),(1378,525),(1360,556),(1290,576),(1232,544),(1171,556),(1119,532),(1097,490)], (1170,477)),
    "xuzhou": ("徐州", [(1356,453),(1403,460),(1463,450),(1509,429),(1517,474),(1509,510),(1527,560),(1500,605),(1476,650),(1414,664),(1378,640),(1329,641),(1290,617),(1290,576),(1360,556),(1378,525),(1334,500)], (1475,535)),
    "yuzhou": ("豫州", [(1095,556),(1119,532),(1171,556),(1232,544),(1290,576),(1290,617),(1329,641),(1378,640),(1382,685),(1347,722),(1299,717),(1241,738),(1164,729),(1116,750),(1078,714),(1090,670),(1059,624),(1013,554)], (1248,680)),
    "yizhou": ("益州", [(432,417),(490,442),(590,435),(546,501),(582,537),(642,535),(682,570),(740,549),(784,565),(843,541),(903,557),(935,608),(919,661),(947,704),(911,760),(931,811),(886,852),(879,907),(825,925),(771,899),(706,922),(659,898),(596,917),(570,879),(507,868),(482,818),(426,827),(415,773),(367,748),(375,699),(339,664),(370,623),(357,579),(392,547),(386,492)], (510,640)),
    "jingzhou": ("荆州", [(903,557),(962,532),(1013,554),(1059,624),(1090,670),(1078,714),(1116,750),(1164,729),(1196,780),(1162,818),(1214,862),(1197,914),(1143,948),(1094,924),(1041,951),(983,927),(932,947),(879,907),(886,852),(931,811),(911,760),(947,704),(919,661),(935,608)], (990,710)),
    "yangzhou": ("扬州", [(1378,640),(1414,664),(1476,650),(1509,678),(1543,692),(1576,741),(1548,784),(1524,827),(1484,858),(1460,899),(1403,920),(1372,947),(1312,942),(1261,965),(1197,914),(1214,862),(1162,818),(1196,780),(1164,729),(1241,738),(1299,717),(1347,722),(1382,685)], (1370,819)),
    "jiaozhou": ("交州", [(570,879),(596,917),(659,898),(706,922),(771,899),(825,925),(879,907),(932,947),(983,927),(1041,951),(1094,924),(1143,948),(1197,914),(1261,965),(1312,942),(1298,995),(1228,1013),(1153,1014),(1086,992),(1017,1022),(935,1008),(875,1030),(822,1005),(755,1028),(693,1008),(653,1031),(615,1010),(613,961),(579,949)], (856,973)),
}
# (id, display name, x, y, owner). Blank owner is genuinely unclaimed.
CITIES = {
    "liangzhou": [("jiuquan","酒泉",250,250,"ma_teng"),("zhangye","张掖",325,260,"ma_teng"),("wuwei","武威",440,320,"ma_teng"),("jincheng","金城",560,350,"han_sui"),("tianshui","天水",650,370,"")],
    "bingzhou": [("yunzhong","云中",830,245,""),("yanmen","雁门",915,212,""),("dingxiang","定襄",980,267,""),("jinyang","晋阳",930,300,"dong_zhuo"),("shangdang","上党",980,388,"zhang_yang")],
    "youzhou": [("ji","蓟",1150,240,"liu_yu"),("yuyang","渔阳",1200,205,"liu_yu"),("beiping","北平",1300,185,"gongsun_zan"),("liaoxi","辽西",1430,170,"gongsun_zan"),("xiangping","襄平",1615,172,"gongsun_du")],
    "jizhou": [("ye","邺",1195,410,"yuan_shao"),("nanpi","南皮",1305,310,"yuan_shao"),("pingyuan","平原",1260,403,"yuan_shao"),("zhongshan","中山",1160,330,"yuan_shao"),("changshan","常山",1115,370,"zhang_yan")],
    "qingzhou": [("jinan","济南",1370,400,"yuan_shao"),("beihai","北海",1495,392,"yuan_shao"),("donglai","东莱",1590,375,"kong_rong"),("linzi","临淄",1410,340,"")],
    "sili": [("changan","长安",795,490,"dong_zhuo"),("hongnong","弘农",910,485,"dong_zhuo"),("west_pass","西侧关隘",975,500,"dong_zhuo"),("luoyang","洛阳",1030,510,"dong_zhuo"),("east_pass","东侧关隘",1095,520,"dong_zhuo"),("hedong","河东",950,470,"dong_zhuo"),("henei","河内",1054,465,"dong_zhuo")],
    "yanzhou": [("chenliu","陈留",1195,505,"cao_cao"),("puyang","濮阳",1260,480,"cao_cao"),("dingtao","定陶",1295,535,"cao_cao"),("shanyang","山阳",1235,540,"cao_cao")],
    "xuzhou": [("xiaopei","小沛",1360,570,"liu_bei"),("xiapi","下邳",1440,580,"lu_bu"),("langye","琅琊",1460,495,"tao_qian"),("guangling","广陵",1410,628,"tao_qian")],
    "yuzhou": [("xuchang","许昌",1145,600,"cao_cao"),("qiao","谯",1285,630,"cao_cao"),("runan","汝南",1200,695,"yuan_shu"),("yingchuan","颍川",1120,638,""),("peiguo","沛国",1320,680,"yuan_shu")],
    "yizhou": [("wudu","武都",715,600,"liu_yan"),("hanzhong","汉中",810,610,"zhang_lu"),("zitong","梓潼",710,660,"liu_yan"),("chengdu","成都",610,725,"liu_yan"),("baxi","巴西",810,700,"liu_yan"),("jiangzhou","江州",815,785,"liu_yan"),("yuesui","越嶲",640,805,"liu_yan"),("yongchang","永昌",575,833,""),("jianning","建宁",750,856,"")],
    "jingzhou": [("xiangyang","襄阳",1025,650,"liu_biao"),("jiangling","江陵",1035,738,"liu_biao"),("jiangxia","江夏",1115,768,"liu_biao"),("changsha","长沙",1085,838,"sun_jian"),("lingling","零陵",986,872,"liu_biao"),("guiyang","桂阳",1145,882,"liu_biao"),("wuling","武陵",958,817,"liu_biao")],
    "yangzhou": [("shouchun","寿春",1407,700,"yuan_shu"),("jianye","建业",1457,752,"sun_jian"),("wu","吴",1505,805,"sun_jian"),("kuaiji","会稽",1468,858,"sun_jian"),("chaisang","柴桑",1242,808,"liu_yao"),("yuzhang","豫章",1316,858,"liu_yao"),("lujiang","庐江",1345,755,"yuan_shu"),("jianan","建安",1370,885,"")],
    "jiaozhou": [("jiaozhi","交趾",650,980,"shi_xie"),("hepu","合浦",1000,980,""),("cangwu","苍梧",1090,970,"shi_xie"),("nanhai","南海",1180,980,"shi_xie")],
}
FACTIONS = {
    "dong_zhuo": ("董卓","董","#d8a15e"), "cao_cao": ("曹操","曹","#79b995"),
    "yuan_shao": ("袁绍","袁","#79c6ce"), "liu_bei": ("刘备","刘","#d7c76d"),
    "lu_bu": ("吕布","吕","#c77570"), "yuan_shu": ("袁术","袁","#9a8fba"),
    "ma_teng": ("马腾","马","#adbd73"), "han_sui": ("韩遂","韩","#b7a186"),
    "zhang_yang": ("张杨","张","#cfb898"), "liu_yu": ("刘虞","刘","#9dc3b4"),
    "gongsun_zan": ("公孙瓒","公","#a5bfcf"), "gongsun_du": ("公孙度","公","#799eb2"),
    "zhang_yan": ("张燕","张","#949ca4"), "kong_rong": ("孔融","孔","#92c4b5"),
    "tao_qian": ("陶谦","陶","#b5c296"), "liu_yan": ("刘焉","刘","#c8ad72"),
    "zhang_lu": ("张鲁","张","#aaa16d"), "liu_biao": ("刘表","刘","#95bc79"),
    "sun_jian": ("孙坚","孙","#71b6a6"), "liu_yao": ("刘繇","刘","#a5b49b"),
    "shi_xie": ("士燮","士","#b4ba88"),
}


def main():
    old_map = json.loads((ROOT / "data/map_slice.json").read_text(encoding="utf-8"))
    old_scenario = json.loads((ROOT / "data/scenario_demo.json").read_text(encoding="utf-8"))
    places, states, regions = [], {}, []
    for rid, seeds in CITIES.items():
        name, polygon, label = REGIONS[rid]
        regions.append(dict(id=rid, name=name, polygon=polygon, label=label, place_ids=[seed[0] for seed in seeds]))
        for pid, title, x, y, owner in seeds:
            kind = "pass" if pid in ("west_pass", "east_pass") else "city"
            places.append(dict(id=pid, name=title, type=kind, region_id=rid, x=x, y=y))
            if pid in old_scenario["places"]:
                state = old_scenario["places"][pid].copy()
            else:
                n = len(places)
                state = dict(population=90000+(n*13700)%180000, economy=45+(n*7)%35,
                             garrison=4000+(n*1100)%11000, grain=25000+(n*3700)%45000,
                             treasury=1500+(n*170)%2800, order=55+(n*3)%28,
                             training=40+(n*5)%35, defense=40+(n*7)%35, equipment=50,
                             description=f"{name}的战略据点，城务与军备使用全国演示规则。")
            state["faction"] = owner
            states[pid] = state
    positions = {p["id"]: (p["x"],p["y"]) for p in places}
    edges, used = [], set()

    def edge(a, b, cost=None, ident=None):
        key = tuple(sorted((a,b)))
        if key in used:
            return
        used.add(key)
        ax,ay=positions[a]; bx,by=positions[b]
        length=math.hypot(bx-ax,by-ay)
        bend=10 if len(edges)%2 else -10
        mx=(ax+bx)/2-(by-ay)/max(length,1)*bend
        my=(ay+by)/2+(bx-ax)/max(length,1)*bend
        edges.append(dict(id=ident or f"w{len(edges)+1:03}", **{"from":a,"to":b},
                          cost=cost or max(1,round(length/45)), points=[[ax,ay],[round(mx),round(my)],[bx,by]]))

    for old in old_map["routes"]:
        edge(old["from"],old["to"],old["cost"],old["id"])
    for seeds in CITIES.values():
        reached={seeds[0][0]}
        remaining={s[0] for s in seeds[1:]}
        while remaining:
            _,a,b=min((math.dist(positions[a],positions[b]),a,b) for a in reached for b in remaining)
            edge(a,b)
            reached.add(b); remaining.remove(b)
    for a,b in [("tianshui","wudu"),("tianshui","changan"),("jinyang","changan"),("shangdang","henei"),
                ("dingxiang","ji"),("ji","zhongshan"),("shangdang","changshan"),("ye","puyang"),
                ("pingyuan","jinan"),("henei","ye"),("beihai","langye"),("xiapi","guangling"),
                ("guangling","shouchun"),("runan","shouchun"),("runan","xiangyang"),("yingchuan","xiangyang"),
                ("changan","hanzhong"),("hanzhong","xiangyang"),("jiangzhou","jiangling"),
                ("jiangxia","chaisang"),("jiangxia","lujiang"),("guiyang","cangwu"),("lingling","hepu"),
                ("jianning","jiaozhi"),("jianan","nanhai"),("chaisang","jianye")]:
        edge(a,b)
    world = dict(image_size=[1920,1080], title="天下舆图 · 全国", art_layout=True,
                 disclaimer="全国演示版：州界、城池坐标与道路为美术布局，势力与数值不对应确切历史年份。",
                 regions=regions, places=places, routes=edges)
    scenario = dict(title="群雄并起 · 全国演示", disclaimer=world["disclaimer"],
                    factions={k:dict(name=v[0],short=v[1],color=v[2]) for k,v in FACTIONS.items()}, places=states)
    for filename, payload in [("world_map.json",world),("scenario_world_demo.json",scenario)]:
        (ROOT/"data"/filename).write_text(json.dumps(payload,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(f"National map: {len(regions)} regions, {len(places)} places, {len(edges)} roads, {len(FACTIONS)} factions")


if __name__ == "__main__":
    main()
