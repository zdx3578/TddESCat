# E-Stitch 开放参数实验：Codex 实施计划

2026-11-24，台北时间。任务顺序：**先完成本计划的参数开放和真实闭环测试，再继续 03–06 的联想驱动概念提升。**

本计划整合 08《E-Stitch功能与参数完整核查》、09《复杂移动实验的E-Stitch配置定案与验收缺口》、10《复杂移动与E-Stitch高复杂度案例对照及配置参考》，并补上配置实际传递、任务终止、现有测试耦合与验收入口。

固定仓库：`zdx3578/TddESCat`。分支：`impl/2026-11-23-toolchain-bootstrap`。核查代码：`257e277a9b784f6c81d685c547fdddb68345aa50`。项目已有 vendored E-Stitch 的上游 pin 保持真实；本次不混入搜索引擎升级。

**交付状态：实施规格和候选配置，运行代码尚未修改。附件可由 TOML 解析器读取，但当前 schema 1 worker 不接受；Codex 必须先实施合同和完整调用链，再启用。本文中的769→481等数字是手算验收预期，尚非运行成绩。**

## 1. 本次决定及范围

### 1.1 主配置只采用一条完成式学习路径

- `max_arity=1000`，恢复上游默认开放程度。
- Best-First Search（最佳优先搜索）不设置任意固定步数、短时间或低匹配容量终点。
- 连续学习至当前冻结问题的**已验证单步压缩固定点**，不再最多两轮，不再总库最多四定义。
- 成功接受1、2、4、8、20、50、100个新定义时保存观察快照；到点继续，不停止。
- 同一轮搜索的20,000、100,000、1,000,000、10,000,000次堆弹出只作为进展观察点，计数按轮重置，另记任务总量。
- 应用分块仍为128行，一块完成后继续处理剩余行。
- 保留当前已接通的类型语言、单位结构费用和优化组合，先测清参数开放的作用。
- 沿已有 Rust 搜索、Julia 独立校验、发布库和预测控制消费者改进，不建立第二套世界模型或兼容 fallback。

二十是本次明确观察点；如果二十之后仍有正收益，继续。若更早已经证明当前问题无正收益，允许结束，不能为了“轮数多”制造空洞定义。[R1][R2][R3]

### 1.2 本次不混入的实验因素

本次不新增运行时大模型、不接入 SMC 生产路径、不实现新的相似检索器、不同时加入任意代数重写或完整程序语言。这些分别改变搜索方式、候选语义和任务调度，属于后续独立工作。

当前条件语言、历史长度、规划范围和对象候选视图保留其声明语义。它们的完整性边界继续报告，不能据本次通过宣称已经覆盖所有 ARC-AGI-3 机制。特别是 `max_parameter_term_nodes=7` 当前检查的是宏展开后的原子效果参数，现有 `vec/coord` 仅3节点，字面量1节点，不是这次宽参数接口的实际阻碍。[R13]

本次必须解除的，是已有合法表达在输入、搜索、证明、输出和签收途中被任意低容量阻断的问题。新增关系构造与联想调度安排在本实验验收之后。

## 2. 轮次、定义数量和抽象层次怎样准确计量

上游每轮至多选取一个新定义，然后改写语料再搜索。下一轮可调用此前定义，但也可能形成另一个独立概念。因此轮次提供发现机会，并不等于抽象层数。[U1]

| 指标 | 含义与计算方式 |
| --- | --- |
| 搜索轮数 | 启动了多少次候选搜索，包括最后一次确认没有新定义的搜索 |
| 完整提交轮数 | 有多少个 Rust round 产物通过完整性检查；可能包含空新增终止轮 |
| 新增定义数 | 相邻累计定义集合的稳定ID差，不能对每轮累计列表长度求和 |
| 库依赖深度 | 原语为0；没有宏依赖的定义为1；其他定义为1加其依赖的最大深度 |
| 实际消费深度 | 从预测、机制或控制直接引用的定义出发，沿传递依赖得到实际使用深度 |
| 环境动作数 | 公共动作交互次数，与学习轮次分别统计 |

当前 `stitch_rounds.jl` 可以提交两轮、却只发布一个新定义：第二轮是确认没有进一步收益的终止记录。当前 `main.rs` 的 `definitions` 还是累计列表。因此“两轮测试通过”不能作为“两层抽象已经形成”的证据。[R4][R5]

定义深度算法：

```text
height(primitive) = 0
height(definition) =
    1 + max(height(dependency) for each referenced definition)
无定义依赖时，max按0计算
先检查无环和无悬空引用，再用拓扑顺序计算
基础库已有深度也计入，不能每个新任务重新归零
```

预测记录可能只直接引用最外层定义，祖先定义通过库依赖闭包核对；不能要求每个祖先都重复出现在直接引用列表中。

## 3. 附件配置及字段合同

### 3.1 文件与目标位置

| 本文随附文件 | 实施后目标 | 用途 |
| --- | --- | --- |
| `estitch-open-test-v1/stitch.toml` | `config/stitch.toml` | 唯一正式学习策略 |
| `estitch-open-test-v1/experiment.toml` | `config/experiments/estitch_open_v1.toml` | 有限验收数据集与观察目标，不控制生产学习容量 |

两个附件均放在本文所在日期目录。实施前不得仅拷贝配置后声称完成。

### 3.2 正式学习策略完整内容

```toml
schema_version = 2
language = "typed-op-children-db-v1"
search = "best-first"
max_arity = 1000
sym_var_cost = 1

[search_options]
priority = "cost"
freeze_rule = "on"
var_order = "mean-nodes-per-class"
lower_bound = "on"
opt_seen = true
opt_dedup_by_match = false
opt_dominance_reuse = false
opt_useless_frozen = false
opt_useless_inline = false
allow_useless_vars = false
no_zero_arity = false
decompose_min_rows = 48

[processing]
apply_chunk_rows = 128

[termination]
learning = "verified_compression_fixed_point"

[progress]
accepted_definition_checkpoints = [1, 2, 4, 8, 20, 50, 100]
search_pop_checkpoints = [20000, 100000, 1000000, 10000000]
```

字段逐项含义：

| 字段 | 含义与实现要求 |
| --- | --- |
| `schema_version` | 配置合同版本2；旧配置明确报错，不静默恢复旧值 |
| `language` | 保持当前带类型的一阶表达语言，不冒称已经接入高阶语义 |
| `search` | 使用已有真实最佳优先搜索器 |
| `max_arity` | 允许返回的定义参数上限1000；不是必须学出1000参数，也不是对象数量 |
| `sym_var_cost` | 结构节点单位费用，保持1；本实验不改变费用模型 |
| `priority` | 当前费用较好的候选优先 |
| `freeze_rule` | 保持规范冻结/展开顺序 |
| `var_order` | 使用原有按每类节点数估计的变量顺序 |
| `lower_bound` | 使用当前类型路径中的费用下界剪枝 |
| `opt_seen` | 保持精确已访问状态去重 |
| 四个其他 `opt_...` | 维持当前关闭状态；本轮不同时改变其类型/匹配剪枝语义 |
| `allow_useless_vars` | 保持false，不人为增加不具区分作用的参数 |
| `no_zero_arity` | 保持false，合法零参数宏仍可压缩重复常量结构 |
| `decompose_min_rows` | 因子达到48行尝试分解；不是最多48行 |
| `apply_chunk_rows` | 每批应用128行，所有后续批继续处理 |
| `termination.learning` | 新桥接多轮完成策略；不是上游原生命令行参数 |
| `accepted_definition_checkpoints` | 对本冻结任务新增且已提交的定义数设观察点；不含基础库定义和空新增轮 |
| `search_pop_checkpoints` | 每轮实际搜索工作观察点；不终止、不删候选 |

每轮已经有原子 checkpoint，本版复用它。观察点不再复制整套大文件；可写带摘要的索引引用。Julia在任务结束或确认的中断后，对各完整前缀独立核验并生成可评测库快照。本次不要求额外实现搜索过程中异步在线发布。

### 3.3 省略限制的确定语义

TOML没有null。候选配置不设置这些限制，应统一映射成 Rust `None`、Julia `nothing`、Python `None`：

- 单轮搜索步数和任务累计搜索步数截止；
- 搜索或整个学习任务的时间截止；
- 最大单匹配因子行数、强制展开程度；
- 图节点、累计状态arena、关系/证明访问量的任意低上限；
- 托管分配和输出大小的任意低上限；
- 学习轮数和库定义总数的固定终点。

不存在字段不等于0，不等于回填旧默认，也不等于用最大整数作哨兵再进行 `+1` 运算。所有计量保留，溢出检查保留。

`seed=1729`目前只是被固定验证而没有传入最佳优先搜索，schema2删除这一伪调参项；场景生成器实际使用的种子仍独立记录。此次不暴露尚未接通的SMC字段、`roll_over`或任意领域重写字段。[R1][R6]

### 3.4 单一策略来源

Julia运行配置中的 `[learning]` 只保留发动机路径、策略文件路径、采集批次和可选先前证据路径等调用信息。新增：

```toml
[learning]
engine = "../target/release/tddesc-stitch"
policy_file = "stitch.toml"
batch_confirmed_events = 8
```

此片段用于 `config/` 中的运行配置；路径相对该运行配置文件解析。真实线上配置已有不同采集批次时保留其批次，不把8当统一新值。

删除这里重复的language、seed、max_rounds、max_learning_seconds、max_new_definitions、max_programs、max_ast_nodes、max_input_slots等学习截断字段。冻结任务把读取到的策略原文与摘要写入输入目录，Python和Rust读取冻结副本，不各自加载可能变化的全局文件。

测试生成器可以修改地址、游戏标识、公共证据目录、目标、冻结评测状态和声明动作序列；不得另写20秒、四定义、十二槽等覆盖。传输连接/请求超时继续检测通信故障，与搜索完成策略独立。

## 4. 两个里程碑和顺序

### 里程碑一：配置、完整运行链和结构学习验收

按M1.1→M1.6执行；协议先定，修改可分文件并行，集成校验顺序执行。

**M1.1：统一合同。**

实施schema2配置、学习协议v2、任务终止摘要、有效配置记录；删除旧小上限回填。公共事件/动作协议保持其现有语义。配置合同、学习任务协议、概念表达语言是不同版本轴，不能一起改名后假装功能已接通。

**M1.2：贯通Rust与vendored typed路径。**

修改配置验证、输入装载、参数注册、搜索、饱和、证明、序列化及计量。不得只改 `Args.num_steps`，却让 `TypedSearch` 继续用旧必填限制。

**M1.3：贯通Julia和Python监督。**

修正等待、签收、发布、库容量与测试生成器；接受合法宽参数。保持进程隔离和公共接口。真正死亡的worker/监督进程必须识别为故障，不因取消截止而无限等待死进程。

**M1.4：迁移旧故障测试。**

替换依赖旧配置字符串的小限额故障测试。使用测试专用故障注入，验证取消、资源失败和写入中断。故障注入不进入正式策略、不读取任何游戏debug接口。

**M1.5：执行O01–O09结构验收。**

包括1000参数编解码、超过8参数真实搜索、超过20定义增长、三层依赖、多证据续学、完整大输入和中断一致性。

**M1.6：提交并推送。**

提交说明必须写分支名、配置合同、已通过的结构验收以及尚未运行的公共控制测试。未完成不得写“参数开放已全面通过”。每20分钟仍提交可审阅进度，不等整个里程碑全部结束才保存。

### 里程碑二：现有公共机制与组合控制复测

**M2.1：完成上游参照和现有完整阶段一。**

上游Furniture/Wheels运行原生参照入口；结构签收与真实搜索已经由M1完成，两者分别报告。现有phase1使用同一个新策略，保留原断言和公共证据。

**M2.2：运行阶段二组合控制。**

复测C01/C02/C03，核对真实输入、实际生效策略、发布定义、机制读取、对象绑定、公共动作与反馈。结果优先分析过程和极端失败，不将普通分数波动当参数因果效果。

**M2.3：输出比较报告并交接03–06。**

必须给出2/4/8/20定义前缀和实际结束的成本、依赖、消费与终止原因。对早于观察点达到固定点的任务记录真实原因。将本版已实现的配置/终止/发布合同作为03–06的前置，后续不要重复建设另一条解除限制路径。

两个里程碑均通过后才开展新的联想检索与关系生成实现；当前旧有限语法在充分搜索后没有新结构，也是有价值的边界结果，不应通过修改语义掩盖。

## 5. 具体问题—位置—当前逻辑—后果—修改

以下位置以固定提交为依据，函数为主，行号辅助定位。[R4]至[R15]

| 具体问题 | 位置 | 当前逻辑 | 后果 | 本版修改 |
| --- | --- | --- | --- | --- |
| 参数配置硬限8 | `rust/bridge/src/protocol.rs::Config::load` | max_arity仅1–8 | 1000配置拒绝 | 按schema2验证非负合法范围，允许1000；合法性与容量分开 |
| 两端定义硬限8 | Rust `codec.rs::Definition::check`；Julia `StitchCodec.jl::decode_definition` | 结果arity<=8 | 搜到也不能消费 | 按完整类型、索引、读取集合、闭合性校验，删除硬8 |
| 原语/槽位/解析另有低上限 | Rust `codec.rs::Registry::new/parse`；Julia解析 | 输入端口8、槽位128、token4096、递归64等 | 宽接口在其他位置失败 | 完整接收声明签名与表达；采用明确长度与迭代解析，保留真实类型检查 |
| 闭合lambda按参数层层嵌套 | `Library.jl::lambda_text` | arity层lam前缀 | 1000参数与64深度冲突 | 专门解析外层参数前缀，再解析一阶正文；两端一致 |
| 输入文件4MiB上限 | `protocol.rs::FileRef::read` | 所有输入文件共用常量 | 来源证据先于搜索失败 | 校验声明长度和摘要，完整读取/流式处理，不静默丢证据 |
| 输入最多2048程序 | `main.rs::Job::load` | 数量硬门槛 | 4537条参照无法输入 | 与manifest实际数量一致即可；去掉任意小容量 |
| 固定轮数和总步数 | `main.rs::Job::run` | for轮数、steps_left跨轮扣减 | 第一轮耗尽即停止续学 | 完成式循环；步骤只计量，未设置限制不扣额度 |
| 强制步数与截止 | `engine.rs::search` | Some(step_limit)、必填deadline | 无法传递开放策略 | Option贯通，原版Args不填截止 |
| typed扩展仍有强制上限 | `third_party/egg-stitch/src/lang/mod.rs::TypedSearch`、`best_first.rs` | 图/arena/关系/时间限制必填 | 只改bridge仍会中断 | 同步Optional；区分累计arena和实际frontier计量 |
| 定义饱和最多32遍 | `engine.rs::saturate` | 32遍后仍变化报step_budget | 图处理与搜索耗尽混同 | 当前已注册定义等式按真不动点处理；中断明确记饱和阶段 |
| 证明和输出仍截断 | `proof.rs::Work/verify`；`main.rs::BoundedOutput` | deadline、证明工作量和4MiB输出 | 搜索成功也无法签收 | 证明全量完成；输出可流式写临时文件后原子提交 |
| worker三重截止 | `python/.../stitch.py::run_worker` | 强制budget；systemd与subprocess再加截止 | Rust开放仍被杀 | 缺省不设RuntimeMaxSec与subprocess timeout，不回填旧内存 |
| solver生命周期派生截止 | `public_run.py::supervise` | 学习秒数乘命令数 | 公共验收提前被终止 | 不再由学习时间推导solver截止；保留通信故障检测 |
| acceptance必须短时间 | `run.py::read_task/run_task`；acceptance配置 | timeout必填、proc.wait(timeout) | 最外层再次收紧 | 本次任务支持省略timeout，等待真实进程终态 |
| Julia等待与总库四定义 | `OnlineSession.jl::wait_worker/online_learn!` | seconds+8；4减基础库数 | 中断/永久封顶 | 按任务终态等待和验证；移除总库门槛，沿原事务发布 |
| 语料和角色小限制 | `LocalEffects.jl::relation_corpus`及其识别调用 | 最大程序/槽位/效果/角色造成跳过 | E-Stitch没得到完整合法材料 | 在当前声明视图中处理所有合格事件及匹配，记录每条纳入/排除原因 |
| 测试动态写回旧值 | `check_online.py::online_config`等 | 20秒、4定义、64程序、12槽、512MiB | 开放策略失效 | 引用唯一policy，不复制策略字段 |
| 每个成功轮都写requested_rounds | `main.rs`；结果schema；Julia签收 | 轮结果与任务终止共用字段 | 中间成功被误当任务结束 | 拆round_outcome与job_termination，新增摘要 |
| 旧测试依赖字符串replace | `tests/julia/stitch_rounds.jl` | 按旧字段文字制造小限制 | 删除字段后测试失效/误测 | 明确故障注入，断言注入点确实被触发 |

局部源码改动仍通过 `rust/bridge/build.rs` 的构建摘要纳入身份。更新 `third_party/egg-stitch/UPSTREAM.toml` 的本地修改说明，不伪造新的上游pin。

### 5.1 输入完整性的边界

“完整”针对本版声明的现有对象视图与效果语言。保留当前四效果族及公共可见性，不能因去掉容量上限就宣称已识别任意对象和变化。

每条公共动作都保存；没有可编译效果、解释歧义、当前语言不支持和容量/实现失败分别登记。容量失败不能被写成语义无效果，零Diff也不能丢掉完整公共响应。

硬编码 `max_roles=min(...,512)` 要解除；有形状/颜色/坐标语义依据的合法域继续校验。现有 `abs(value)>64` 对不同效果值一刀切应拆分：位置位移按帧域验证，数量变化按其计数语义验证；已有整数原语需要的字面量从合法观测构造签名，不能把资源计数错误当作坐标范围。这个修改扩展现有数值域，不引入新机制类别。

### 5.2 资源和隔离

保留离线worker隔离、cgroup v2、NoNewPrivileges、真实进程状态检查、哈希、文件长度、路径与整数溢出校验。

机器内存保护值未设置时继承实际父cgroup/主机限制，记录有效值与峰值，不额外回落256MiB/512MiB。此处不预填20GiB等未经本机确认的值。资源耗尽仍可能发生，发生时保存已完成轮和真实原因，不声明固定点。

等待循环必须能识别worker退出、监督者死亡、最终状态缺失和用户取消。仅“暂时没有更优候选”不构成杀进程条件。

## 6. 版本与结果合同：避免再次把“做过搜索”当成“完成”

### 6.1 版本改动范围

- 学习策略配置采用 `schema_version=2`。
- 学习任务/结果/任务摘要统一使用 `tddescat.learn.v2`，新增对应 `protocol/v2/learn_job.schema.json`、`learn_result.schema.json`、`learn_summary.schema.json`。
- 当前概念项的编码 `typed-free-slots.v1` 与一阶语言语义保持；不将容量开放冒称新语义。
- 未改变的签名、定义、公共事件等schema可被新学习schema按明确$id引用，不复制成含义不同的两套定义。
- `contracts.py` 按$id注册需要的schema资源；活动学习入口只接受v2，旧学习job明确拒绝。公共事件v1继续是自己的合同，不是旧学习器fallback。
- 冻结、worker身份、checkpoint、Julia校验与发布一起更新；旧产物只读留档。新测试从原始公共证据重新冻结，不把旧结果改版本号冒充新验证。

### 6.2 每轮产物保留原证明并说明独立事实

| 字段/事实 | 意义 |
| --- | --- |
| `round_outcome` | 本轮接受了定义，或完整搜索无正收益；不是整个任务停止原因 |
| `search_exhausted` | 当前候选域已处理完；必须和语义/剪枝范围绑定 |
| `saturation_complete` | 本轮声明的定义等式处理达到不动点 |
| `input_scope_complete` | 声明的合格输入没有因容量/实现截断遗漏 |
| `apply_complete`、`match_support_exact` | 现有完整应用和精确支持要求继续成立 |
| `round_committed` | Rust完整轮原子提交；不等于Julia已发布 |
| `definitions` | 保持累计新定义列表语义；新增数用稳定ID集合差计算 |
| 原来源/证明/成本/父摘要 | 保持完整并由Julia独立复核 |

另写任务级 `learning-summary.json`：

| 内容 | 含义 |
| --- | --- |
| `termination_reason` | 固定点、无合格语料、取消、资源中断、验证失败等真实终态 |
| `search_rounds` | 包括无新增终止搜索的次数 |
| `accepted_definitions` | worker本任务真正增加并提交的定义数 |
| `last_checkpoint` | 最后完整轮及摘要，不能指向临时目录 |
| `fixed_point` | 仅满足全部完成条件时为true |
| `scope_refs` | 语料、基础库、签名、等式、费用、配置、代码身份摘要 |
| `effective_limits` | 三语言最终生效值；未设置用JSON null明确记录 |
| `interrupted_phase` | 输入、饱和、搜索、应用、证明、序列化或提交阶段 |
| 实际计量 | 程序规模、节点、匹配、搜索工作、时间和内存 |

Julia另外报告实际发布定义数与消费深度。有效产物可在中断后独立验证使用，但任务摘要仍标未完成，不伪报最优。没有合格输入不是“完成了整个环境的抽象”。

## 7. 核心算法伪代码

### 7.1 完成式学习

```text
freeze(public_evidence, eligible_corpus, base_library,
       signature, equations, cost_model, effective_policy)

accepted_ids = empty_set
search_round = 0
current_programs = frozen_programs
current_library = frozen_library
current_cost = full_cost(current_programs, current_library)

loop:
    search_round += 1
    graph = build_and_saturate(current_programs, current_library)
    result = best_first(graph, max_arity=1000,
                        num_steps=None, time_limit=None)

    if result has candidate:
        independently_verify_types_bindings_sources_and_full_expansion()
        next_cost = full_cost(result.programs, current_library + candidate)
        require next_cost < current_cost
        atomically_commit_round_with_existing_proofs()
        update current_programs, current_library, current_cost
        update accepted_ids by stable-ID set difference
        write checkpoint index when accepted count hits observation point

        if interruption occurred:
            write incomplete summary preserving complete checkpoints
            stop this invocation
        continue

    if result.search_exhausted and graph.saturation_complete
       and frozen_input_scope_complete:
        commit terminal no-positive-gain record
        write fixed-point summary bound to exact scope hashes
        stop
    else:
        write precise incomplete result
        preserve completed checkpoints
        do not issue a fixed-point result
        stop or resume through the same worker path
```

固定点只指当前候选语言与等价理论中的单步改进，不保证全局最佳库，也不排除两个单独无收益而联合有收益的定义。固定有限输入、固定非负整数费用、每次严格下降，可保证成功发布次数有限；不保证单轮搜索耗时小。新证据或语义变化必须新冻结，旧固定点不能阻止新学习。

本次正常运行按每轮完整搜索推进，不额外实现中途发布赢家的调度功能。

### 7.2 宽参数闭合表示解析

当前第一阶语言不支持内部binder，使用这一事实实现明确的外层参数解析，不直接把1000参数交给递归深度64的通用解析器：

```text
read exactly arity outer "(lam" prefixes
parse the first-order body with an explicit parser stack
read exactly arity closing parentheses
require end-of-input
map De Bruijn index j to parameter arity-1-j
require 0 <= j < arity
compare decoded lambda body, pattern body and typed JSON body
check every required parameter index and each type
```

额外/缺失binder、内部非法binder、参数乱序、错误类型仍拒绝。参数表可扩展并不表示放松变量捕获与作用域检查。

### 7.3 Python和Julia等待

```text
launch the same isolated worker with the frozen policy
do not create a search deadline when policy has none

while no terminal status:
    poll actual worker/supervisor process state
    consume progress/status updates
    if process exited:
        read exit status and final summary
        if summary missing: report worker failure, not fixed point
    if user cancelled:
        terminate cleanly, preserve committed rounds, report incomplete
    continue normal polling

verify final summary plus each committed checkpoint in Julia
publish only independently verified valid definitions
```

不再由公共动作数量乘以学习秒数推导solver总截止。网络连接与请求超时仍只处理相应通信故障。

## 8. 能独立核算的测试数据

**实现补充：拆开共享的匹配范围。** 旧 `[search].max_match_witnesses` 同时被 `Config`、`effective_limits` 和 `OnlineSession` 用于对象识别、效果语料、ACTION6坐标枚举及歧义预测，不能删除一个字段后任由其他用途回填旧值。本版将证据/效果/后继识别一侧改为完整匹配迭代，取消 `LocalEffects` 和 `OnlineSession`（旧代码约509行）中的 `min(512, ...)` 截断并检查剩余调用点；分块仍必须处理完全部见证。动作候选枚举与条件搜索使用分别命名、明确声明域的配置，保留本轮既定动作/条件语义。字段迁移一次完成，不保留共享旧字段或隐式fallback。每条公共证据是否完整解释、是否含未决对象对应均写入作用域记录，不能把不完整识别当作固定点证据。

附件 `experiment.toml` 中的数量定义测试材料，不是正式系统截断。其字段含义：

- `stitch_policy`：指向唯一学习策略，按测试档案目录解析。
- `codec_arities`：编解码、注册与调用的边界点。
- `search_arities`：真实自动搜索必须覆盖的接口宽度。
- `instances_per_shape`：每个宽结构至少八个合法实例。
- `independent_families/instances_per_family`：二十四概念测试的族数与实例数。
- `dependency.batches/instances_per_batch`：三批依赖提升测试。
- `minimum_programs/minimum_origins_bytes`：超过旧输入容量的装载与签收测试尺寸。
- `references`：原版语料参照，用单轮隔离宽接口搜索；不是把生产学习恢复成一轮。
- `public_validation`：必须继续验证的现有公共机制和组合控制用例。

### 8.1 宽接口编解码：0、1、8、9、19、64、65、1000

0/1保留已有合法情况；8/9跨过旧硬边界；19对齐真实上游宽接口；64/65检查参数前缀深度；1000证明声明的开放值没有被下游暗中缩小。

这组允许构造明确的有类型定义做往返测试，但必须标为基础设施检查，不能报告“搜索自动学到了1000参数概念”。

### 8.2 宽接口自动发现：4、6、10、12、15、19

对每个宽度w，生成固定的有类型二叉组合树，每个叶位置有一个固定一元包装，叶值使用互不相同的自由槽位。每份输入对槽位作合法替换/置换，角色结构共享。叶不是可内联常量。

```text
for w in [4,6,10,12,15,19]:
    common_shape = balanced_typed_tree_with_w_distinct_role_positions()
    corpus = 8 legal instantiations with independent free slots
    freeze_and_run_real_worker(corpus, empty_library, open_policy)
    verify all committed rounds in Julia
    require a profitable published shared definition with the intended width
    verify every call expands back to its exact original typed term
```

生成器不得使用目标定义、`follow`或预先注入答案库。先独立核算整体共享结构比局部包装更有收益；若等价最优形式不同，按接口独立性、完整展开和实际费用判断，不按临时函数名判断。

### 8.3 二十四个定义但只有一层：跨过二十观察点

二十四族互不共享算子，每族八条：

```text
a_i(b_i(c_i($j))),  i=1..24, j=0..7
```

`$j`为自由槽位而非常量；每个程序四节点。每族应形成一个一参数、四节点正文的定义，调用为二节点。

在当前包含一个统一programs根的费用口径下：

```text
初始：24 × 8 × 4 + 1 = 769
最终：24 × 8 × 2 + 24 × 4 + 1 = 481
每族净收益：12
```

验收要求：

- 实际产生二十四个正收益定义，能跨过第20次接受；
- 二十四定义依赖深度都为1；
- 完整展开还原所有程序；
- 最后无新增的终止轮不被误算成第25个概念；
- 769→481按实际费用口径独立复算，不能硬改结果迎合预期。

### 8.4 三批真实学习形成三层依赖

每批八个实例，后批输入引用前批真实搜索、校验和发布的稳定定义：

```text
批A：a(b(c($j)))  -> 实际学习并发布 A
批B：d(e(A($j))) -> 实际学习并发布 B，正文依赖 A
批C：h(i(B($j))) -> 实际学习并发布 C，正文依赖 B
```

A/B/C是说明标签，代码读取真实稳定ID，不预设fn名称。检查深度3、无环、无缺失依赖、参数与类型一致、完整求值/展开一致。破坏或删除A时，依赖它的B/C不能继续被报告为有效。

这项验证结构组合层次；实际物理因果作用仍由公共机制测试验证。

### 8.5 输入容量与证据完整性

- 至少4537条合法程序完整进入bridge，程序数与manifest一致；
- 合法 `origins.json` 大于4MiB，必须通过同一哈希和来源检查；
- 使用真实合法来源记录扩展大小，不填不受schema验证的垃圾字段；
- 编译前后事件账本能逐条对应，零Diff与未决解释保留；
- 所有输入处理完成，不能用前64条的成功代表全量成功。

容量测试本身不需要把任何无类型分子程序伪装成ARC机制；可用同等规模的合法类型输入检查桥接。上游分子数据可作为完整文件读取对照，正式语义消费仍按项目类型合同。

## 9. 验收矩阵与退出条件

| 编号 | 检查 | 实际入口 | 必须得到的证据 |
| --- | --- | --- | --- |
| O01 | 唯一有效配置 | Config、freeze、Python、Rust | 四处策略摘要相同；没有旧20秒/2轮/4定义回填；未设置值明确为null |
| O02 | 宽参数往返 | 两端codec、Library | 9/19/65/1000成功；坏类型/索引/顺序仍拒绝 |
| O03 | 宽参数真实搜索 | 新 `stitch_open_search.jl` | 真实大于8参数定义、正收益、完整来源和证明 |
| O04 | 超过二十定义 | 二十四族fixture | 二十四新定义、769→481预期核对、深度仍1 |
| O05 | 依赖提升 | 三批续学fixture | 深度3、稳定依赖闭合、展开/求值和损坏拒绝 |
| O06 | 新证据重开 | OnlineSession与同一库 | 旧固定点只绑定旧快照；新输入重新搜索并消费 |
| O07 | 容量/完整性 | 输入、origins、输出、proof | 4537程序与>4MiB合法来源完整处理，不丢尾部 |
| O08 | 终止状态可信 | main、结果schema、Julia | 无收益、已接受、图未完、搜索未完、取消、验证失败分别记录 |
| O09 | 原子提交 | 旧rounds故障测试改写 | 完整轮保留；临时轮拒绝；哈希断裂和证明损坏拒绝 |
| O10 | 原生宽结构参照 | vendored CLI、Furniture/Wheels | 配置和数据摘要、实际arity、成本、步骤、时间、峰值；不将旧历史耗时作为本机门槛 |
| O11 | 六核心公共机制 | check_core_learning/verify_core | 原预测断言保持；M04/M06核对实际引用定义结构，不能仅要求非空引用 |
| O12 | C01/C02/C03闭环 | check_composition、check_camera_composition | 机制→绑定→动作→公共反馈→反例/重绑定完整，旧正确性断言不删 |
| O13 | 参数开放效果 | 每轮指标与同输入前缀评测 | 2/4/8/20前缀成本、依赖、消费及真实结束原因；完整端到端耗时和内存 |

O01–O09是里程碑一出口。O10–O13及现有phase1/phase2必须通过才是里程碑二出口。资源中断属于INCOMPLETE，不能计PASS，也不能自动回退旧小配置。

M04的“两个对象都预测了”与“一个联合宽参数定义被实际消费”分开验证。若原始有限训练集没有产生联合宏，保留原闭环结果，并添加同类公共动作的独立位置/角色实例；不要手工塞入联合机制，也不要把没有联合宏的结果夸称该能力已通过。

## 10. 现有测试如何具体改，不另起一套验收器

### 10.1 Julia脚本

继续使用 `tests/julia/stitch_rounds.jl` 检查旧有证明和原子性，新增 `tests/julia/stitch_open_search.jl` 承载O02–O07。

旧脚本中的以下字符串替换必须删除：

```text
max_steps = 20000 -> max_steps = 1/70
managed_bytes = 268435456 -> managed_bytes = 8192
```

新故障注入应显式指定“首次提交前取消”“第一完整轮之后取消”“写临时目录期间中断”“资源检查抛错”等，并断言确实触发。注入文件仅属于测试夹具，不成为默认学习参数。

### 10.2 Python现有kernel入口

`tests/bench/check_kernel.py` 的stitch脚本清单扩展为旧rounds与新open_search两个脚本。两个脚本当前不能共用一个要求为空的工作目录，必须各用：

```text
public/rust-jobs/stitch_rounds/
public/rust-jobs/stitch_open_search/
```

在 `config/acceptance/stitch_bridge.toml` 增加：

```toml
experiment_config = "../experiments/estitch_open_v1.toml"
```

`run.py::read_task`把该项作为stitch任务的已知配置路径解析，`check_kernel.py`把解析后的绝对路径传给新Julia脚本。去掉该任务短timeout，保持同一个runner等待进程终态。不要靠环境变量注入参数。

参数签名明确为：旧 `stitch_rounds.jl` 仍只接收自己的运行目录；新 `stitch_open_search.jl` 接收 `ARGS = [自身运行目录, experiment_config绝对路径]`。不得把第二参数无差别传给旧脚本。

原生Furniture/Wheels参照也由同一验收任务记录，使用已在仓库中的数据、同一锁定工具链和明确原生CLI。其op-children输入不伪装成项目typed效果输入；项目宽类型桥接由O02/O03验证。

### 10.3 应更新的配置文件

- `config/stitch.toml`；
- `config/offline_public.toml`、`config/real_public.toml`中重复学习字段；
- `tests/bench/check_online.py`及其他调用生成器；
- `config/acceptance/stitch_bridge.toml`与本次phase1/phase2所用任务的短生命周期截止；
- 新 `config/experiments/estitch_open_v1.toml`；
- 相应Config、schema和故障测试。

`config/bench_agent.toml`的公共动作数量是有限采集用例定义，不等于E-Stitch能力参数，不为“全都调大”改变既有裁判用例。场景种子、颜色/形状置换、动作序列和完整响应要求继续记录。

## 11. Codex执行命令和产物

以下为实施完成后的命令，不是现在旧代码已支持新增测试的声明。工作目录是仓库根，沿现有已锁定工具链运行。

```bash
cargo test --workspace
cargo build --release --bin tddesc-stitch

.venv/bin/python -m tddesc_tools.run \
  --config config/acceptance/stitch_bridge.toml \
  --run-dir runs/estitch-open-structure

.venv/bin/python -m tddesc_tools.run \
  --config config/acceptance/phase1.toml \
  --run-dir runs/estitch-open-phase1

.venv/bin/python -m tddesc_tools.run \
  --config config/acceptance/phase2_policy.toml \
  --run-dir runs/estitch-open-phase2 \
  --prerequisite runs/estitch-open-phase1/public/acceptance.json
```

执行目录必须新建，避免污染冻结数据。若实际suite汇总产物位置变化，应依据 `suite.py` 的真实文件路径调整，并验证前置验收摘要、源码身份与任务结果，不传旧版本PASS冒充新版本前置。

原生参照采用同一配置档案指定的1000参数和单轮，例：

```bash
cargo run --release --manifest-path third_party/egg-stitch/Cargo.toml \
  --bin egg-stitch -- --search best-first --language op-children \
  --max-arity 1000 --num-abstractions 1 \
  --input third_party/egg-stitch/data/domains/cogsci/furniture.json \
  --output runs/estitch-open-reference/furniture.json
```

测试驱动负责新建输出目录、记录实际二进制及数据摘要。Wheels同样运行。这里单轮是为了复核宽接口参考，与正式完成式多轮策略不同。不得添加 `follow` 或有损匹配行截断。若1000参照结果与上游百万参数点不同，调查候选范围和局部修改，不能直接改断言遮盖。

必要产物：

| 文件/记录 | 具体内容 |
| --- | --- |
| 冻结输入与有效配置 | 公共来源、语料、类型、基础库、原文策略与各层摘要 |
| 每轮checkpoint | 定义、实际改写、完整证明、成本及父摘要 |
| `learning-summary.json` | 任务终态与范围，不和中间轮结果混淆 |
| 观察点索引 | 1/2/4/8/20/50/100前缀引用及Julia核验状态 |
| 结构统计 | 原始程序数/节点/深度、实际参数、定义依赖深度 |
| 搜索/资源统计 | 每轮堆弹出、arena/frontier、匹配因子和临时峰值、阶段耗时、RSS和托管分配 |
| 消费证据 | 预测引用、对象绑定、公共动作、实际反馈、反例与撤回 |
| 本日中文报告 | PASS/FAIL/INCOMPLETE、具体失败位置、已完成和未完成项 |

不得只保存汇总百分比，不得把配置上限当实耗。普通运行波动不推断因果收益；优先分析新增结构、实际消费与极端失败原因。

## 12. 本次与03–06计划的衔接

本实验先回答：

1. 是否还有封装限制把E-Stitch已有能力堵住？
2. 两个定义之后，是否确实还有能被找到、验证、消费的有效结构？
3. 进一步学习增加的是同层概念、跨层依赖，还是只有无消费者的压缩？
4. 当前有限效果语言在充分搜索后的真实边界是什么？

这些证据完成后，03–06再依次推进统一关系定义、联想召回与精确对齐、触发搜索和反例修订。本版不以接入更多理论替代解除现有调用链的阻碍，也不以调整参数冒称已经完成通用关系发现。

Codex交付时必须区分：参数/接口已开放、结构测试已通过、现有公共控制已通过、联想驱动新功能尚待实施。提交和push说明分支名；每天的报告继续写入对应日期的 `docs/changelog/` 子目录。

## 参考资料与源码

本计划事实来自固定源码；没有新的搜索性能实测。

- [R1] [08-E-Stitch功能与参数完整核查](08-E-Stitch功能与参数完整核查.md)
- [R2] [09-复杂移动实验的E-Stitch配置定案与验收缺口](09-复杂移动实验的E-Stitch配置定案与验收缺口.md)
- [R3] [10-复杂移动与E-Stitch高复杂度案例对照及配置参考](10-复杂移动与E-Stitch高复杂度案例对照及配置参考.md)
- [R4] [Rust学习循环及累计定义](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/rust/bridge/src/main.rs)
- [R5] [现有真实搜索与续学测试](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/tests/julia/stitch_rounds.jl)
- [R6] [Rust配置与输入装载](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/rust/bridge/src/protocol.rs)
- [R7] [Rust类型与表达解析](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/rust/bridge/src/codec.rs)
- [R8] [Julia独立签收](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/julia/TddESCat/src/StitchBridge.jl)
- [R9] [Julia解码](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/julia/TddESCat/src/StitchCodec.jl)
- [R10] [库发布与lambda表示](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/julia/TddESCat/src/Library.jl)
- [R11] [Julia在线学习和等待](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/julia/TddESCat/src/OnlineSession.jl)
- [R12] [Python worker监督](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/python/src/tddesc_tools/stitch.py)
- [R13] [联合机制实际消费](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/julia/TddESCat/src/JointMechanisms.jl)
- [R14] [Python solver监督](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/python/src/tddesc_tools/public_run.py)
- [R15] [验收任务读取与等待](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/python/src/tddesc_tools/run.py)
- [R16] [TypedSearch限制字段](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/third_party/egg-stitch/src/lang/mod.rs)
- [R17] [搜索与定义饱和](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/rust/bridge/src/engine.rs)
- [R18] [现有kernel测试入口](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/tests/bench/check_kernel.py)
- [R19] [schema注册器](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/python/src/tddesc_tools/contracts.py)
- [R20] [阶段二前置验收检查](https://github.com/zdx3578/TddESCat/blob/257e277a9b784f6c81d685c547fdddb68345aa50/python/src/tddesc_tools/suite.py)
- [U1] [上游多轮定义学习](https://github.com/mlb2251/egg-stitch/blob/cdbba10e3075a14c9d7933c125807d7dc6a04b42/src/lib.rs)
- [U2] [上游最佳优先完成语义](https://github.com/mlb2251/egg-stitch/blob/cdbba10e3075a14c9d7933c125807d7dc6a04b42/src/best_first.rs)
- [U3] [上游高参数参照配置](https://github.com/mlb2251/egg-stitch/blob/cdbba10e3075a14c9d7933c125807d7dc6a04b42/expts/arity.py)

