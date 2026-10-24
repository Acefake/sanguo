extends RefCounted

const LINES := {
	"challenge": ["%s在此，谁敢一战！", "%s刀下，不收无名之辈！", "有胆量的，来与%s分个生死！", "%s在此，莫只敢躲在军后！"],
	"answer": ["休要猖狂，%s来取你！", "%s在此，接我一招！", "口气不小，且问%s手中兵刃！"],
	"win": ["这点本事，也敢挡%s！", "%s刀锋未冷，下一个是谁！", "记住%s的名字，回去再练！", "%s在此，还有谁敢上前！"],
	"lose": ["今日算你狠，%s来日讨还！", "%s虽败，这口气还没断！", "这一阵，%s认了；下一阵再算！"],
	"dead": ["%s纵死，也不向你低头！", "好一刀……%s不服！", "%s宁死，绝不屈膝！"],
	"kill_win": ["%s刀下，再添一名！", "敢挡%s，这便是下场！", "%s在此，谁来替他报仇！"],
	"draw": ["今日未分高下，%s改日再战！", "有些本事，%s记住你了！", "%s兵刃未折，这一战还没完！"],
	"captured": ["绑得住%s，绑不住这身骨头！", "%s落在你手，绝不求饶！"]
}

static func pick(event: String, name: String, seed_value: int) -> String:
	var choices: Array = LINES.get(event, LINES["draw"])
	return choices[posmod(seed_value, choices.size())] % name
