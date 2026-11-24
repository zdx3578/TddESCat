# 复杂移动实验的 E-Stitch 配置定案与验收缺口

2026-11-24，台北时间。分析对象是用户指定的 `docs/changelog/2026-11-23-三语言框架与复杂移动实施计划/`，同时核对真实语料生成、测试入口、Rust 调用和 Julia 消费代码。

固定仓库：`zdx3578/TddESCat`。分支：`impl/2026-11-23-toolchain-bootstrap`。源码基线：`de3ffe6859d8ff1c73f982d5a1cffcbfa1035872`。本轮只做源码与实验设计分析，没有运行新实验，也没有修改运行代码。

## 1. 配置结论

**这组实验的 `max_arity` 应恢复为原版默认的 1000，不再设为 2，也不把当前协议的 8 当折中目标。** 必须同时打通协议、类型接口、编解码、语料构造和消费者，不能只改一行 TOML。

其他配置按实际含义定案：使用当前已接通的 Best-First Search（最佳优先搜索）；不设任意固定搜索步数和短时间截止；取消总库四定义的终点；对冻结语料持续发布严格降低总结构费用的有效定义，直到当前声明搜索域完成后没有正收益。分块和因式分解继续使用，处理完一块继续下一块。

“至少不低于原版”应理解为表达范围与实际搜索机会不被额外缩窄，不是要求所有数值都增加。`decompose_min_rows` 增大反而更晚尝试分解；SMC 粒子数在当前最佳优先路径不生效；原版未设置的删候选阈值，不能换成一个有限大整数并称为更开放。

**当前没有一份只修改 TOML 就能满足以上要求的配置。** 旧 schema 会拒绝 1000，测试生成器又写回 20 秒和四定义；需要按第 7 节同时修改实现。

## 2. 这套复杂实验究竟要求什么能力

原 04 文档已经区分了核心学习、认识边界与组合控制，不能把所有 M01–M14 都当成同一类“机制已经学会”的测试。[R1]

### 2.1 阶段一必须实际学习和消费的六类

| 场景 | 要验证的作用 | 对概念表示和计算的要求 |
| --- | --- | --- |
| M01 完整支持平移 | 从前后重叠识别完整支持，在新位置预测并影响下一动作 | 前后对象角色、完整支持、位移与动作来源 |
| M02 形状与碰撞 | 区分完整形状可以进入和边缘受阻 | 对象支持、目标支持、阻挡与边界条件 |
| M04 双角色推动 | 同一动作联合预测主体和被推动物体 | 两对象的前后角色、共同位移关系、后方空间 |
| M05 远端条件 | 局部相同却结果不同，促使读取远端条件并修订 | 条件角色、被控对象、动作和效果之间的关系 |
| M06 资源消费 | 位置变化和资源减少同时进入预测 | 移动、资源角色、消费量和前置条件 |
| M08 点击选择 | 点击改变控制对象，随后动作作用于正确对象 | 点击坐标、候选对象、选择状态和后续作用 |

### 2.2 其他阶段一用例主要检查什么

M03 不把像素连通等同于动作可达；M07 保存历史并正确保留未知；M09 不把 ACTION7 预设成全状态逆；M10 保存零 Diff 时的公共通道；M11 保存完整多帧顺序；M12 保留镜头／自主运动的竞争解释；M13 检查连通、裁剪和对象身份边界；M14 不在公共前缀不可辨时虚报唯一机制。

`check_boundaries.py` 的空库测试明确要求 `expected` 与 `assessments` 为空、资格为 unresolved。这些通过说明“未知处理正确”，不能据此报告相应机制已经由 E-Stitch 学会。[R8]

### 2.3 阶段二增加的是真实组合义务

| 场景 | 组合内容 | 单纯增加参数数还不能替代的能力 |
| --- | --- | --- |
| C01 | 开关、门、推动、形状约束与后续路径 | 中间状态重新绑定、条件检查、反例撤回后缀 |
| C02 | 两门共享一份资源，动作有顺序 | 共享资源身份、消费传播、不可交换的程序组合 |
| C03 | 滚动重定位、点击选择、移动、非完全撤销 | 坐标解释、历史与身份修订、跨层依赖失效 |

当前 C01–C03 的控制组合能够使用局部机制，不等于 E-Stitch 已经把完整动作程序学成新宏；两种能力需要分别记录。[R9]、[R10]

## 3. 从实际表达语言推导参数需求

### 3.1 代码里已经存在多角色效果

`ConceptTerms.jl::evidence_signature` 定义了以下接口：[R2]

| 原语 | 输入 → 输出 | 各项含义 |
| --- | --- | --- |
| `vec` | Integer × Integer → Delta | x、y 两个分量组成位移 |
| `coord` | Integer × Integer → Coord | x、y 两个分量组成坐标 |
| `link` | RoleBefore × RoleAfter × Delta → Relation | 动作前角色、动作后角色及其位移 |
| `pigment` | RoleBefore × RoleAfter × Color × Color → Relation | 前后角色与前后颜色 |
| `count_shift` | RoleBefore × RoleAfter × Integer → Relation | 前后资源／计数角色及数量差 |
| `selection` | RoleBefore × RoleAfter × Coord → Relation | 前后选择角色与坐标 |
| `marked` | Relation → Relation | 当前表达语言中的关系标记 |
| `pair` | Relation × Relation → Relation | 把两个效果组合为同一表达 |

原语的输入数量与新定义的独立参数数不同。若 `vec(dx,dy)` 固定在正文，单个 link 可以只需两个角色参数；如果要把位移也泛化，就需要更多参数。

`LocalEffects.jl::relation_corpus` 为每个效果分配独立的前后角色槽，再用 `pair` 组合多个效果。这不是文档里的设想，当前生产语料已经这样生成。[R3]

### 3.2 当前语言中直接展开相关结构所需的接口

下表表示保留独立角色／数值时的直接接口，不是要求所有学习结果都长成同一种正文，也不是新的全局上限。

| 要表示的结构 | 独立参数需求 |
| --- | ---: |
| 单移动，位移固定 | 2：前角色、后角色 |
| 单移动，整个位移泛化 | 3：前角色、后角色、Delta |
| 单移动，dx、dy 分别泛化 | 4 |
| 两对象移动，位移固定 | 4 个前后角色 |
| 两对象共享一个可变 Delta | 5 |
| 两对象共享可变 dx、dy | 6 |
| 两对象各自具有独立可变 dx、dy | 8 |
| 移动＋数量变化，数值固定 | 4 个前后角色 |
| 移动 Delta 与数量差均泛化 | 通常 6 |
| 移动 dx、dy 与数量差分别泛化 | 通常 7 |
| 当前最多六个效果的直接组合 | 已有 12 个角色，尚未计额外数值参数 |

因此二参数不只是“理论上可能太少”。它直接排除了 M04、M06 对应的部分联合定义。

接口能够表达，不等于该定义具有压缩收益。例如纯包装 `f(before,after,delta)=link(before,after,delta)` 不会缩短调用表达，普通 E-Stitch 不会仅因允许三个参数就选择它。宽接口验证应使用确实重复的联合结构，检查真实费用下降与后续消费；不能规定所有三参或五参接口都必须被选为新宏。

1000 是恢复上游开放程度的配置基线。当前实验并不要求一开始使用一千个参数；搜索仍应根据真实语料和费用选择有效表达。未来接口超出某个软件边界时应继续扩展，不把 1000 再解释为认知的数学上限。

### 3.3 为什么现有复杂测试在二参数下仍能通过

`JointMechanisms.jl::joint_model` 实际会：[R4]

1. 展开已发布宏；
2. 沿 `pair` 拆出各个效果；
3. 对照前后角色槽与 `effect.family`；
4. 由 Julia 形成联合机制。

因此当前可以分别学到两个二参数原子宏，再以：

```text
pair(move_macro(before_A, after_A),
     move_macro(before_B, after_B))
```

支持联合预测。这不等于搜索器已经产生：

```text
joint_move(before_A, after_A, before_B, after_B, shared_delta)
```

现有 `verify_core` 对 M04 检查两个位移效果，对 M06 检查移动与计数效果，同时要求存在定义引用；没有检查新联合定义是否保留了多于两个独立参数。[R7]

所以，既有联合预测与控制成果成立，但不能被拿来证明二参数限制满足联合抽象发现目标。

## 4. 实际实验入口比全局配置更窄

真实入口是 acceptance → bench 脚本 → `check_online.py::online_config` → 动态 agent.toml → Julia → Rust worker。[R5]、[R6]

### 4.1 动态生成器写回的限制

| 字段／行为 | 实际值或逻辑 | 对实验的影响 |
| --- | --- | --- |
| `max_programs` | 64 | 更多表达仍在证据中，但本次学习语料被截断 |
| `max_ast_nodes` | 96 | 更长合法表达在进入搜索前被跳过 |
| `max_input_slots` | 12 | 当前每效果两个槽，所以最多六效果 |
| `max_learning_seconds` | 20 | 全局 60 秒又被缩到 20 秒 |
| `max_new_definitions` | 4 | Julia 按整个已有库大小扣除，达到四定义停止新增 |
| `max_guard_atoms` | 2 | 多条件机制的直接条件合取受限 |
| `max_parameter_term_nodes` | 7 | 消费者的参数表达被限制 |
| `max_guard_candidates` | 2048 | 条件候选搜索可能提前停 |
| `max_match_witnesses` | 512 | 更大匹配域可能未核完 |
| `history_lengths` | 0、1、2、4 | 只覆盖这些声明的历史视图，不能据此排除更长历史机制 |

`OnlineSession.jl:373,389–395` 的实际逻辑为：

```julia
available = max_new_definitions - length(base.entries)
rounds = min(configured_rounds, available)
wall_ms = min(stitch_wall_ms, max_learning_seconds * 1000)
```

常规复杂实验最多两轮；C03 显式设置四轮，但仍保留总库四定义与 20 秒等限制。只改 `config/stitch.toml` 不会解决问题。

另一个硬限制在 `LocalEffects.jl:238`：`max_roles=min(max_match_witnesses,512)`。即使上层把见证值调大，角色候选仍会被 512 再次截断。需要逐个处理实际消费点，不能只把配置字段改大。[R3]

### 4.2 三种内存数字与外层截止不同

复杂实验的 Rust 分配量检查为 256 MiB；测试生成器把 worker 进程内存设为 512 MiB，Julia solver 进程为 2 GiB。这不是同一个指标。

Python worker、solver 总生命周期和 acceptance 还有自己的截止。`public_run.py` 会从请求时间、学习时间和公共命令数推导总截止；acceptance 文件另外指定任务时间。因此放开 worker 后，也必须避免外层重新提前终止完整本地验收。[R14]、[R15]、[R16]

本轮没有读取用户实验机，不编造新的内存数字。实施时处理真实机器保护与测量，不能继续沿用这些未经当前工作量验证的小数值作为功能完成的条件。

### 4.3 不应一起盲目放大的实验参数

训练／测评分离、公开命令轨迹长度、裁判的有限域、动作目标和是否冻结模型，规定了实验在检验什么。它们与搜索截断不同。

例如 C03 的有限公开动作序列用于检查滚动、选择和撤销链。不能为取消学习时间限制而随意增加目标环境动作，破坏原有可核验过程。需要更多因果覆盖时，另行扩大实验因素和声明范围。

## 5. 建议落实的 E-Stitch 参数定案

### 5.1 核心配置

| 项目 | 目标设置 | 理由与实现位置 |
| --- | --- | --- |
| 搜索器 | `best-first` | 复用当前已接通的类型检查、确定搜索和证明链 |
| 参数数 | `max_arity = 1000` | 恢复上游开放程度；扩展 protocol/codec，不能被 ≤8 再挡住 |
| 搜索步数 | 不设置固定截断，Rust 为 `None` | 不把有限大整数当无截断；`engine.rs` 不能强制 Some |
| 搜索时间 | 本地完整验证不设任意短截止 | Julia、worker、solver、acceptance 同时贯通，不能加回20／60秒 |
| 近期无改善早停 | 不添加 | best-first 原版不采用该条件 |
| 压缩目标早停 | 不设置任意 `compression_limit` | 未完成搜索不能据此宣称已无更好候选 |
| 多轮终点 | 当前冻结语料的已验证压缩固定点 | 不固定两轮或四轮；见第6节 |
| 总库定义数 | 无固定四定义终点 | 已有库增长不能永久关闭新发现 |
| 符号费用 | `sym_var_cost = 1` | 保留正整数结构费用，便于比较与严格下降检查 |
| 队列顺序 | `priority = cost` | 保持当前费用驱动；不把换排序当已测收益 |
| 冻结规则 | `freeze_rule = on` | 保留规范展开顺序，避免排列重复 |
| 变量顺序 | `mean-nodes-per-class` | 先处理预计展开膨胀较小的变量 |
| 下界剪枝 | `lower_bound = on` | 复用当前类型路径，保持可采纳费用界的前提 |
| 精确已访问去重 | `opt_seen = true` | 保持项目当前状态，并与去重前移优化连接 |
| 匹配脚印等四项剪枝 | 当前保持关闭 | 在 typed／端口／冻结语义核验完成前不盲目打开 |
| 强制展开阈值 | 不设；原生 `none` | 不额外删除因写法较长但可能有价值的候选 |
| 单因子行数剪枝 | 不设 `max_match_set` | 通过因式分解、精确连接与流式继续处理匹配 |
| 尝试因子分解的阈值 | `decompose_min_rows = 48` | 可保留原版优化粒度；不是表达能力上限 |
| SMC 粒子数与温度 | 当前路径不使用 | 不能靠增大未被调用的参数提升能力 |

当前四项关闭指 `opt_dedup_by_match`、`opt_dominance_reuse`、`opt_useless_frozen`、`opt_useless_inline`。先保持已有类型路径的行为，再对每项优化独立核验，不把“开放表达范围”和“盲目打开剪枝”混成同一修改。

### 5.2 目标配置片段：明确是 schema 2 设计，旧代码不可直接运行

这段用于 Codex 落实配置合同；不是声称当前旧解析器已经接受。使用现有 `config/stitch.toml` 作为唯一 E-Stitch 学习策略来源，测试生成器引用该策略，不再另写一套小限制。

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

[termination]
learning = "verified_compression_fixed_point"
```

每一项的映射：根字段选择当前一阶类型语言、最佳优先搜索、1000参数接口和单位结构费用；`search_options` 映射到真实 Args 同名字段；`termination.learning` 是需要新增的桥接多轮完成策略，不是原版命令行参数。

schema 2 中省略的步数、时间、最大匹配因子、强制展开限制必须贯通为未设置，不能回填旧默认。TOML 没有 null；Rust 使用 Option，Julia 使用对应的未设置语义，Python 监管不再派生隐藏短截止。旧 schema 明确拒绝，不保留两条学习实现。

`rounds`、`max_new_definitions` 不再作为固定计数终点；当前 best-first 未消费的固定 seed 字段不再伪装成有效探索参数。语料来源、类型、哈希、依赖与证明检查继续保留。

这一片段不包含本机资源数值和公共动作实验范围，两者不应用假数值补齐。它也不包含当前桥接未消费的原版 `roll_over`：轮间图行为仍由同一个桥接的建图／库导入逻辑明确处理。

## 6. 不设两轮，如何有明确完成条件

对同一份冻结语料与固定费用模型，令：

$$
C_k = C(\text{当前改写语料}) + C(\text{累计定义库}).
$$

每个被接受的定义必须满足：

$$
C_{k+1} < C_k.
$$

在结构费用是非负整数、输入有限且每轮独立校验正确的条件下，每次至少减少一个单位。因此成功接受的轮数自然有限，不需要另设“两轮”或“总库四个定义”的终点。

这只约束成功发布轮数，**不自动证明任意单轮搜索一定快速结束**。当前轮真正穷尽，或所有剩余候选被正确下界排除之后无正收益，才可声明当前冻结语料／语言／等价图上的压缩固定点。中断且没找到结果仍是未完成。

核心循环应是：

```text
冻结本轮公共语料、基础库、类型语义与来源版本
重复：
    以同一真实搜索器搜索候选，参数接口开放到1000
    若存在具有正总费用收益的有效候选：
        独立核对类型、参数、展开、来源、费用与实际调用
        原子发布新定义和改写语料
        记录本轮搜索是否完成；不伪报最优
        继续在更新后的库与语料上学习
    否则若当前声明搜索域已完成：
        记录当前范围的压缩固定点，结束本次冻结学习
    否则：
        记录真实未完成原因与待处理工作，继续解决
新公共数据或语义修订到达后，重新冻结并继续
```

不能用“没有发现”替代“已经完成搜索后不存在正收益”。也不要求先穷尽所有可能世界模型，才允许一个已验证、暂时没有反例的概念被使用。

固定点记录必须绑定语料、当前库、类型语义、有效等式、费用配置与声明搜索域的版本。新证据或相关语义改变后重新冻结，不能沿用旧问题的固定点记录作为新问题已经完成的证书。

## 7. 必须贯通的代码修改位置

| 具体问题 | 代码位置 | 当前逻辑 | 后果 | 具体改法 |
| --- | --- | --- | --- | --- |
| 参数合同≤8 | `rust/bridge/src/protocol.rs::Config::load`；`codec.rs::Registry::new/Definition::check` | 配置、原语输入、定义参数都受硬常量约束 | 1000配置直接拒绝，宽宏无法传回 | 按schema 2统一接口；保留类型、索引与绑定合法性，解除任意小参数常量 |
| Julia侧协议也需一致 | `StitchCodec.jl`、`Config.jl`、学习schema | 有固定字段和规模约束 | 单改Rust会在序列化或发布时失败 | 两端同一类型／参数合同，跨语言golden数据覆盖超过8参数 |
| 语料截断 | `LocalEffects.jl::relation_corpus` | 程序数、表达长、槽数、角色数导致continue或截断 | 材料没有进入搜索，调大arity也无效 | 对声明实验语料完整生成；精确分组时保存后续联合搜索义务；不静默丢剩余程序 |
| 测试重写小配置 | `tests/bench/check_online.py::online_config` | 固定64程序、12槽、20秒、4定义等 | 全局配置被再次压低 | 读取唯一学习策略；只覆盖场景地址、证据路径、冻结状态、目标与公共动作测试范围 |
| 库容量与时间再次收窄 | `OnlineSession.jl:373,382,389–395` | 总库减4、轮数取min、时间取min、等待截止 | 持续发现和完整搜索被终止 | 使用固定点完成策略；保留版本与发布事务，取消数量终点和隐藏短截止 |
| Rust强制步数／截止 | `engine.rs::search`、`main.rs::Job::run` | Some(step_limit)、统一deadline、固定rounds | 原版可选能力被封装为必需截断 | None贯通、多轮费用下降与完成状态贯通 |
| 重写固定32遍 | `engine.rs::saturate` | 有变化时可能到常量后停止 | 定义等式尚未处理完 | 以不动点与真实失败状态区分完成；保留类型和自由变量不变量 |
| 外层再次杀进程 | `stitch.py::run_worker`、`public_run.py::supervise`、`run.py` | worker／solver／acceptance各有截止 | 内层放开不等于实验完整运行 | 各层采用同一完成策略；必要的通信失败检查与真实机器保护另行处理 |
| 条件消费者仍窄 | `Config.jl`、`GuardRepair.jl`、`JointMechanisms.jl` | 两条件原子、有限候选与七节点参数式 | 新概念进入库却未必能被使用 | 在有限声明问题中继续最小解释／区分搜索，不用永久小常量代替完整条件 |
| 动作、条件、历史、序列尚未入正文 | `LocalEffects.jl::effect_program`；`JointMechanisms.jl::joint_model` | 当前只编码单事件效果，动作从外部metadata读取 | 1000参数也不能搜索不存在的程序结构 | 沿既定04/05统一关系语言加入带类型、读时点和来源的机制／顺序构造，并复用同一消费者 |

语料域的某些约束与64×64任务定义有关，另一些只是软件常量。例如当前数值字面量范围与四类效果编码需要分别检查，不能为了“数字大”破坏颜色合法域或坐标解释，也不能把资源数量一概当位移范围处理。

## 8. 现有实验结果能支持什么

原 18 报告记录了 580 个合成场景、118,291 条有限转移等环境检查，同时写明六类核心冻结测评共有八次受支持预测。[R12]

这些数字属于不同层次：

- 大量有限转移主要用于验证环境与独立裁判；
- 核心学习验收检查有限训练／测评切片中的真实定义消费；
- 边界测试主要证明保存证据与未知资格正确；
- 组合控制检查局部机制怎样支持反馈规划。

本轮读取的完整仓库树没有 `runs/` 产物，所以不能独立复核报告中的每一份原始证据，也没有重新运行。不能把十多万条环境转移写成十多万条已经完成的 E-Stitch 因果学习。

`tests/julia/stitch_rounds.jl:27–29` 的原续学语料是16条 `f(g(c_i),g(c_{i+1}))`，其共同模式天然只有两个独立参数。它验证真实搜索、续学、证明和发布，却不覆盖三、五、超过八参数的接口。[R11]

## 9. 配置落实后怎样确认它真正发挥作用

### 第一项确认：完整接口与真实发现

1. 从实际复杂实验入口导出最终生效配置，确认1000没有被下层8参数、Julia20秒、四定义和旧默认重新覆盖。检查真实调用值，不能只核TOML文本。
2. 以独立变化的角色／数值构造纯结构测试，覆盖三参数、联合四至六参数及超过旧八参数边界的合法定义。超过八参数是合同能力检查，不是新的全局上限。
3. 使用真实最佳优先搜索，不用 `follow` 告知目标正文。保留全部候选来源、参数类型、展开与实际费用核对。
4. 检查重写调用→Julia解码→库发布→展开求值的全过程。不能只证明Rust接受了一个宽AST。
5. 对当前有限声明语料，程序、槽、见证和学习完成范围都要有明确记录；不能把剩余语料悄悄丢掉。

不要求每个场景都返回高参数宏。系统应选择有实际收益的结构；如果返回低参数组合，必须说明其接口与共享约束覆盖了什么，而不能用它替代“宽接口可搜索并可消费”的专门验证。

### 第二项确认：复杂移动的实际消费闭环

| 检查对象 | 必须观察的结果 |
| --- | --- |
| M04 | 区分原子宏后拼装与搜索得到的联合定义；联合角色对应、完整位移效果和后方条件均可回溯 |
| M06 | 移动与资源变化共享同一动作证据，消费前提与消耗传播都被后续控制读取 |
| M05／M08 | 远端条件和选择角色影响下一实际公共动作；参数／关系变化后重新绑定 |
| C01 | 中间反馈后重新核对条件与角色，反例撤回后续动作 |
| C02 | 共享资源只有一份，组合不会把两条局部成功错误重复消费 |
| C03 | 滚动后绑定修订和非完全撤销传播到上层程序及下一动作 |

每条链要能连起来：公共事件→表达→学习调用→新定义→展开证明→机制／关系消费者→真实动作→反馈→修订。只多出几个宏、只费用下降或只游戏结果变化都不能独立替代这条链。

完整公开记录保持只读来源；独立裁判的场景真值不进入agent。冻结测评仍冻结学习，反例修订试验另按原规定运行，不靠训练／测评泄漏产生高参数结果。

## 10. 本轮交付边界

本轮已经把“复杂实验应该怎么设”落实为具体参数值、停止语义、实际入口、跨语言修改位置和对应验收。重点是恢复1000参数开放程度、去掉多层隐蔽截断、完成真实宽接口与消费能力。

尚未修改运行代码，也没有实测1000设置后的搜索耗时、内存或新增概念收益。因此当前旧限制仍然存在；本文件是对应这组复杂移动实验的配置实施定案，不是配置已经生效的报告。

## 参考资料

- [R1：复杂移动场景与两阶段签收矩阵][R1]
- [R2：实际概念原语与类型接口][R2]
- [R3：效果表达、角色槽、语料生成与截断][R3]
- [R4：联合机制的实际宏展开与消费者][R4]
- [R5：复杂实验动态agent配置生成器][R5]
- [R6：Julia在线学习、剩余定义容量与时间缩减][R6]
- [R7：核心学习的真实验收条件][R7]
- [R8：边界实验与未知资格检查][R8]
- [R9：C01／C02组合实验入口][R9]
- [R10：C03滚动／选择／撤销实验入口][R10]
- [R11：已有二参数续学合同测试][R11]
- [R12：既有阶段一／阶段二实测报告][R12]
- [R13：原版E-Stitch全部参数与多轮驱动][R13]
- [R14：Python worker监管][R14]
- [R15：solver生命周期与内存口径][R15]
- [R16：验收分发与外层截止][R16]
- [R17：当前Rust配置合同][R17]
- [R18：当前Rust编解码合同][R18]
- [R19：当前Rust真实搜索与定义重写][R19]

[R1]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/docs/changelog/2026-11-23-三语言框架与复杂移动实施计划/04-复杂移动场景与测试实施.md
[R2]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/julia/TddESCat/src/ConceptTerms.jl
[R3]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/julia/TddESCat/src/LocalEffects.jl
[R4]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/julia/TddESCat/src/JointMechanisms.jl
[R5]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/tests/bench/check_online.py
[R6]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/julia/TddESCat/src/OnlineSession.jl
[R7]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/tests/bench/check_core_learning.py
[R8]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/tests/bench/check_boundaries.py
[R9]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/tests/bench/check_composition.py
[R10]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/tests/bench/check_camera_composition.py
[R11]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/tests/julia/stitch_rounds.jl
[R12]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/docs/changelog/2026-11-23-三语言框架与复杂移动实施计划/18-阶段一离线验收与阶段二策略闭环.md
[R13]: https://github.com/mlb2251/egg-stitch/blob/cdbba10e3075a14c9d7933c125807d7dc6a04b42/src/lib.rs
[R14]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/python/src/tddesc_tools/stitch.py
[R15]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/python/src/tddesc_tools/public_run.py
[R16]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/python/src/tddesc_tools/run.py
[R17]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/rust/bridge/src/protocol.rs
[R18]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/rust/bridge/src/codec.rs
[R19]: https://github.com/zdx3578/TddESCat/blob/de3ffe6859d8ff1c73f982d5a1cffcbfa1035872/rust/bridge/src/engine.rs
