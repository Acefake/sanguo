extends RefCounted

# Project-authored battlefield dialogue, not quotations from the original game.
const LINES := {
	"evade": ["避开箭阵，前军压住敌弓！", "中军转移，莫让敌箭白白伤兵！"],
	"attack": ["诸军齐进，莫失阵脚！", "列阵迎敌，随我破阵！", "敌军已近，奋力向前！"],
	"ranged": ["弓手就位，瞄准放箭！", "张弓待令，齐射敌阵！", "看准来敌，不可虚发！"],
	"siege": ["靠近城墙，准备强攻！", "诸军合力，攻破城门！", "稳住阵列，步步向前！"],
	"retreat": ["莫要恋战，依次撤回！", "收拢队伍，整军再战！", "后队掩护，缓缓退却！"],
	"rally": ["莫要慌乱，守住阵脚！", "诸位勿惧，我仍在此！", "重整旗鼓，不可散乱！"],
	"march": ["保持队形，向前推进！", "沿路警戒，勿失同伴！", "诸军随行，谨防伏兵！"],
	"hold": ["整军待命，听候军令。", "养精蓄锐，静候战机。", "守住此地，不可懈怠。"]
}
const PERSONAL := {
	"关羽": {"attack": "关某在此，谁敢来战！", "retreat": "暂退一步，整军再战。"},
	"周仓": {"attack": "跟紧某家，一起冲阵！", "march": "随我前行，莫落队伍！"},
	"袁绍": {"attack": "诸军并进，不可失阵！", "siege": "合兵攻城，一举克之！"},
	"田丰": {"hold": "先观其势，再寻破绽。", "siege": "审势而进，勿徒耗兵。"},
	"诸葛亮": {"attack": "稳住阵脚，依计而行。", "hold": "静观其变，以待良机。"},
	"孙策": {"attack": "江东儿郎，随我破敌！"},
	"黄忠": {"ranged": "老夫弓在，敌军休走！"},
	"魏延": {"attack": "让某杀开一条路！"},
	"颜良": {"attack": "来将通名，与某一战！"},
	"文丑": {"attack": "贼将何在，速来迎战！"},
	"关兴": {"attack": "奋勇向前，莫辱军旗！"},
	"张苞": {"attack": "诸军随我，杀开敌阵！"}
}

static func line_for(name: String, event: String, variation: int) -> String:
	if PERSONAL.get(name, {}).has(event): return PERSONAL[name][event]
	var options: Array = LINES.get(event, LINES["hold"])
	return options[posmod(variation, options.size())]
