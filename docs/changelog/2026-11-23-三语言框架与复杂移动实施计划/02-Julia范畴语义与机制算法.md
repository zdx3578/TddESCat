# Julia 范畴与机制内核：现成开源复用、函数合同与实施顺序

日期：2026-11-23，台北时间，星期一。项目：TddESCat。本文是供 Codex 逐项实施的规格；本轮只读取官方固定源码和现有设计文档，没有安装联合 Julia 环境，没有生成已解析的 Manifest，没有运行下述冒烟、性质测试或 ARC3 实验。

## 1. 直接裁决：复用什么，项目仍须写什么

Julia 层直接采用 AlgebraicJulia 的 Catlab、ACSets、GATlab。需要确定的图重写实例时调用 AlgebraicRewriting，不另写一个通用图匹配器、推出求解器、范畴运行时或与 Rust E-Stitch 并行的反统一发现引擎。

四个库的分工不同：

- Attributed C-Set（带属性 C-集合，ACSet）由 ACSets 提供结构容器、部件与箭头存储、索引和序列化。它不负责判断像素是不是玩家、墙或钥匙。
- Catlab 提供显式范畴模型、同态搜索、有限集合及 C-set 的积、拉回、等化子、推出、余等化子、自然性检查、有限关系和有类型顺序语法。
- Generalized Algebraic Theory（广义代数理论，GAT）由 GATlab 提供固定理论签名、模型接口和符号表达。声明 implements 不证明模型满足公理；空的 symbolic model 也不自动使表达按结合律相等。
- AlgebraicRewriting 提供给定规则和匹配的重写、应用条件与 Double Pushout（双推出，DPO）粘合条件检查。它执行已经给出的规则，不发现真实环境规则；不能取代 E-Stitch 或公共反例学习。

项目必须实现的部分是这些库不具有的 ARC3 语义：不可变公共证据与来源、动作前可用性检查、三值认识和求解完成性的区别、E-Stitch 编解码与独立回读、机制参数与条件构造、查询及历史细化、负依赖缓存、修订发布、覆盖调度和实际动作消费。

“尽量复用”应落实成可审查的调用表：每个通用数学算法指向一个上游 API；每个自写函数说明它补充了什么项目语义。禁止写一套同名算法后只在依赖中列出 Catlab。

## 2. 已核查的版本与联合依赖预检

### 2.1 候选锁定点

下表是本轮经官方 GitHub release、tag 对应提交及 Project.toml 读取核对的候选，不是联合安装成功的声明。

| 包 | 候选版本 | 固定源码提交 | 本轮核对到的有关 compat |
| --- | --- | --- | --- |
| Catlab | 0.17.6 | ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32 | ACSets 0.2.27；GATlab 0.2.2；DataStructures 0.17、0.18、0.19；Julia 1.9 |
| ACSets | 0.2.29 | aac441e1bf6e9813ba6da51a97d5d3738c3e549c | AlgebraicInterfaces 0.1.4；DataStructures 0.18、0.19；PrettyTables 3；Julia 1.9 |
| GATlab | 0.2.4 | 0944af7765b404c97f92b9909a56bb2535146caf | AlgebraicInterfaces 0.1.4；DataStructures 0.18、0.19；JSON 0.21 或 1；Julia 1.9 |
| AlgebraicRewriting | 0.5.0 | 23f444de687d3926cbd0c8e7fd2fc574b40af8e6 | Catlab 0.17.1；ACSets 0.2.20；GATlab 0.2.1；DataStructures 0.17、0.18；Julia 1.9 |

这里列的是 Julia compat 字符串，不是要求恰好等于该下界。例如 0.17.1 可容纳 0.17.6，0.2.20 可容纳 0.2.29；四包关于 DataStructures 的交集为 0.18 系列。只有执行 Pkg 的完整解析才能确认全部传递依赖，不能据这几个交集直接宣布 Manifest 已成立。[S1–S4]

工具链候选 Julia 1.10.10 落在上述 Julia compat 范围内。Python 3.12.9 属环境服务边界，不由这四个 Julia 包的 compat 决定。精确 Julia patch 与 Python/Rust 锁由总计划统一，不能在子模块自行漂移。

旧 11-23 文档核查 Catlab 的 692bd5e9d4b792a01bc507a59a19c2311b321359；本轮选择 release tag 对应 ca2b685。官方 compare 返回：旧点在 tag 后三个提交，唯一变更文件为 .buildkite/pipeline.yml，未改 src 或 Project.toml。因此这里采用正式 tag，保留二者关系，不能误称更换了已审查算法实现。[S5]

### 2.2 阶段一第一步：依赖可执行预检

拟文件：

- julia/TddESCat/Project.toml：包 UUID、精确候选 compat、项目自身版本。
- julia/TddESCat/Manifest.toml：由目标 Julia 实际解析生成，禁止手写。
- config/dependencies.toml：记录工具链、候选 tag/commit、固定源码预期、预检状态。
- scripts/preflight_julia.jl：安装后的 API 与行为检查。
- tests/julia/dependency_contracts.jl：精确正反例，避免“using 成功即通过”。
- docs/changelog/当日目录/：实际解析报告、差异和未通过项。

实施顺序：

1. 校验实际 VERSION 为总计划锁定的 Julia patch。读取配置文件，不用环境变量切换版本或行为。
2. 使用正常 registry 包版本作为候选；四个直接依赖写精确版本约束。若采用按 commit 源码锁，通过 connector 导入固定源码，再由 PackageSpec 的本地 path 引用并核源码树；不通过 URL/rev 让包管理器直接访问 GitHub。不得把 registry 版宣称等同于任意 main。
3. 在独立项目执行 Pkg.instantiate / resolve，并生成 Manifest；保存 Pkg.status、直接与传递版本、平台、Julia 版本和源树哈希。
4. 核对解析到的直接版本及源码对应；验证许可证随依赖维护。GATlab 许可证需在实际落锁时读取对应 LICENSE，不凭组织名推断。
5. 运行本节八个冒烟。成功后提交 Project、Manifest、工具链配置和报告，报告分支与提交；不提交下载缓存。
6. 之后所有开发和 CI 都使用该 Manifest。升级是显式新任务，重跑合同检查并记录影响；不在运行时自动降级依赖。

八个冒烟：

- 建立固定 schema 和两个实例，写入部件，索引查询与读取一致。
- C-set 的两个局部模式沿接口推出，得到预期部件数及共同角色。
- 对该推出完整枚举微型 Hom，与接口一致的局部匹配一一对应。
- 两角色到单对象的局部单射拼接后不再单射，附加互异约束必须拒绝。
- 相同源目标但不交换的变换：端点检查可过，check_equations=true 必须返回具体失败方块。
- FreeCategory 的单位、结合规范化及错端点组合拒绝。
- 矩形有限关系的输入输出维数、关系复合及 Post–wlp 方向正确。
- AlgebraicRewriting 的合法 DPO 重写成功；删除仍被外部边引用的节点时，粘合检查拒绝。

阻断标准：解析失败、版本偏离、直接 API 缺失、类型化范畴选择错误、自然性方块错却通过、部分匹配被报完整、矩形关系方向错、DPO 粘合检查缺失，均阻断依赖验收。不能通过切换自写通用数学库或关闭检查来放行。需定位到具体包／API、修正调用或选择一个经重新核查的固定版本，然后重做受影响预检。

AlgebraicRewriting 0.5.0 release 明确移除了 incremental hom search；Catlab 0.17 的迁移说明明确 HomomorphismQuery 尚未重新实现。首版使用已核查的 BacktrackingSearch，不写“库已提供增量 matcher”。项目的增量来自自己的来源、依赖和失效索引。[S6,S7]

## 3. 上游 API 到项目函数的逐项映射

| 项目任务 | 实际复用 API／源码 | 本项目补充的合同 |
| --- | --- | --- |
| 固定类型 schema | Catlab 的 @present、FreeSchema；ACSets 的 @acset_type、add_parts!、set_subpart!、subpart、incident | 类型标签、端口顺序、来源和时序含义；schema 固定，宏定义作为数据增长 |
| 有限实例匹配 | homomorphisms(P,M; cat=C, alg=BacktrackingSearch(), initial=…, predicates=…, monic=…, take=…) | 作用域、角色互异、负条件、三值关系、预算及完整性；不同解释分支不能混合 |
| 求一个存在见证 | homomorphism(P,M; cat=C, any=true) 或 is_homomorphic | 见证来源；false 需要完整完成；超时不能当不存在 |
| 推出和拉回 | pushout[C](f,g)、pullback[C](f,g)、ob、coproj1/2、proj1/2 | 共享接口的语义、类型属性冲突、跨侧互异角色、来源和资源 |
| 等化子与余等化子 | equalizer[C](f,g)、coequalizer[C](f,g)、incl、proj | 比较的是身份还是属性；连通商不是因果对象身份证明 |
| 模式/schema 变换 | ACSetTransformation；is_natural(…;cat=C) | 部件索引合法、属性保持、精确 schema 和版本 |
| 一般有限生成域自然性 | Transformation、naturality_failures(η;check_equations=true)、is_natural | F/G 同源同靶、函子验证、模型作用域闭合、查询范围；不能把该检查报成未知世界因果定理 |
| 有类型顺序程序 | Catlab.Theories.FreeCategory 的 Hom、id、compose | 动作顺序、纯 AST 不发动作、具体参数与资源、实际逐步响应 |
| 精确有限关系 | Catlab 的 FinRel、FinRelationCallable、FinRelationMatrix、BoolRig、compose、meet、join | 模型已定义性、查询覆盖通道、结果穷尽、启用、非空、非确定后果和成本的联合语义 |
| 已定义图重写 | Rule{:DPO}(l,r;cat=C,…)、can_match、get_matches、rewrite_match | 只操作派生模型；不得修改原始证据；匹配、附加条件和粘合检查通过后应用 |
| 结构序列化 | ACSets.generate_json_acset / parse_json_acset | _id 为局部行号；另存稳定 evidence_id 和 occurrence 来源，不让行号变身份 |

上游 homomorphism 默认寻找唯一解；多解可报错。求任意一个时必须显式 any=true。homomorphisms 的 take 只在找到规定数量结果后停止，不是节点预算、时间预算或可恢复 frontier；max 超限抛错，不是“无匹配”。这些是本轮逐行核查到的行为。[S8]

Catlab 的显式 category model 必须一路携带。例如无属性 C-set 使用 ACSetCategory(CSetCat(实例原型))，固定属性语义使用相应 ACSetCat；不能把 CSetCat 用于带属性 schema，也不让自动推断在关键边界悄悄选择 loose 属性语义。[S9]

## 4. 固定 signature 与可以持续增长的宏定义

### 4.1 不为每个学到的概念创建 Julia 类型或新 schema

首版固定：

1. 基础值类型：布尔查询、有限整数、坐标、颜色标签、角色引用、像素支持、历史引用、有限关系、纯程序表达。
2. 基础原语：坐标差、相等、顺序、邻接、集合成员、字段读取、关系合取及投影等；每项有实际解释和读取规则。
3. 结构图：算子节点、按序端口、角色/参数引用、共享连接。
4. 协议项种类：常量、参数、原语调用、宏调用、顺序程序和带标签分支。

学出的宏保存稳定 ID、有序形参、返回类型、定义体、依赖、读取摘要和语义版本。新宏是库中的新定义数据；定义体引用已有原语或旧宏。整个依赖图无环，不执行学到的字符串，不调用 eval 新建环境机制代码。

GATlab / Catlab 的启动宏可以在受审查的源码中声明一次类型和理论；这与对学习结果动态 eval 不同。空的 @symbolic_model 不自动规范化结合律；有类型顺序语法直接复用 Catlab.FreeCategory，它的 compose 使用 strict=true 和 associate_unit。不得重复写一个未经验证的“自由范畴”。[S10,S11]

### 4.2 两个紧凑结构视图足够起步

先解释再建结构：

- “项图”保存一个表达如何由子表达构成。Node 是子表达位置的结构代表，Port 是某算子的第几个输入，owner 指输入属于哪个算子节点，target 指该输入引用哪个子节点。顺序索引、算子标签和类型必须参与匹配约束。
- “角色事实图”保存当前解释的 n 元关系。Role 是候选参与者，Fact 是一项关系事实，Arg 是该事实的一个有序论元，fact 指其所属事实，role 指其参与者。关系名称、论元次序、真假／未知与来源由对应语义表保存。

可以先用无属性 C-set 表示结构骨架，通过 predicates 固定算子、类型和端口候选，通过最终 filter 检查具体值及附加条件；这避免把未知属性伪造为某个 concrete value。若改用 attributed schema，必须选择并测试 tight/variable 属性范畴，不能默默把未知变成可任意映射的属性值。

结构共享和发生位置分开：相同子项可以共享存储节点，每个 occurrence 仍保存自己的表达路径与来源。重复参数若要求同一身份，使用同一个角色约束；同色或同位移只是属性相等，不据此合并真实角色。

宏定义可由协议 AST 回读，并在固定解释器中调用。薄 AST 的必要职责只是跨语言解析、宏引用与来源；底层项和程序规律尽量复用 GATlab/Catlab，不建立第二个库学习器。

### 4.3 项目文件与核心合同

以下文件都在 julia/TddESCat/src/，不是现有实现声明。

| 文件与函数 | 输入及输出 | 必须拒绝或明确报告 |
| --- | --- | --- |
| Schemas.jl / schema_context(signature) | 固定签名版本→schema、显式范畴模型及组件索引 | 未支持 schema 漂移、错误属性类别 |
| ConceptTerms.jl / infer_term(term, Γ, library) | 项、形参上下文、冻结库→类型及读取依赖 | 非法参数序、漏形参、循环宏、未知算子 |
| ConceptTerms.jl / expand_checked(call, library) | 宏调用→保持共享的展开及 occurrence 映射 | 捕获、类型不一致、不支持等式 |
| PhaseCheck.jl / check_available(reads, decision_cutoff, mode) | 实际来源依赖、冻结决策点、用途→可用或具体违规来源 | 真实未来帧、把待返回响应当已知值 |
| CategoryBackend.jl / match_pattern(pattern, scene, scope, budget) | 冻结模式与同一解释→合法绑定、来源及完成状态 | 混解释、缺失当否定、take 截断当全集 |
| CategoryBackend.jl / glue_patterns(p,q,interface) | 局部模式与显式共享映射→推出和注入映射 | 标签／函数属性冲突、未定义角色合并 |
| CategoryBackend.jl / glue_matches(left,right,interface) | 绑定关系→共享一致且附加条件合法的联合绑定 | 跨侧必须互异的角色碰撞、时间/来源不相容 |
| CategoryBackend.jl / check_schema_map(map, C) | ACSet 映射→自然性与部件失败见证 | 只端点检查就报自然性 |
| CategoryBackend.jl / apply_model_rule(rule,match,C) | 已发布派生模型规则和见证→新派生模型及搬运映射 | 修改原始证据；未检 can_match 就直接重写 |

类型推导既在 Rust 搜索中约束，又在 Julia 回读独立核对；二者不是两个发现引擎。

### 4.4 Grounding.jl：从公共帧到完整支持、对应假设与学习语料

Grounding 只提出带来源的候选解释，不预置“哪个颜色是玩家”。输入为公开帧、动作请求、完整公开响应以及 cutoff 前历史；输出为事实、候选支持、跨帧对应分支和纯描述项。原始帧是证据，候选解释不是对原始证据的改写。下面算法是项目拟实现方案，不是上游库或 ARC3 已具备的效果。

`ground_event(event, frozen_library, budget)` 的基本顺序如下：

~~~text
校验事件完整性、帧尺寸与公共坐标约定
建立每帧的像素位置、颜色和仅局部的四邻接/八邻接事实
构造同色邻接图；求两个连通版本并保留其来源和 C4→C8 关系
计算逐位置变化掩码 D；D 只负责索引变化证据，不充当主体支持
对每个解释分支提出完整支持候选：
    相邻同色分量、已学局部关系支持、允许的分量联合/子区域
    允许跨颜色组合，但必须由明确关系、已学定义或有预算的候选语法提出
    包含未变化部分，并保留剩余像素和未解释变化的覆盖义务
对候选前后支持提出有限对应及变换参数候选
对所有候选核对完整支持、颜色/形状关系、遮挡假设及剩余变化
保留多解分支；生成历史描述项、参数来源和角色发生位置
用固定类型与 phase 规则检查语料；交给 E-Stitch 的只有纯项
保存搜索完毕的候选域与未完成前沿，不把预算剪枝当关系否定
~~~

最小反例：一行三像素主体从位置 1–3 移到 2–4，中间位置 2、3 颜色不变，变化掩码只剩 1、4。若只把变化像素当主体，就丢失完整三像素支持，碰撞与窄门判断都会错。因此 `support_candidates` 必须回查前后完整帧；“有变化”只是一条提出候选的索引。一个同色连通分量也可能合并两个接触对象、主体与背景；不能把连通分量强制作为唯一物体身份。

`displacement_candidates(before_support, after_support, geometry, budget)` 先由锚点差、像素对应差和已学参数项给出候选，再检查整体支持关系。若明确采用无环绕、整数像素平移，在宽 W、高 H 的帧上可枚举 δx∈[−(W−1),W−1]、δy∈[−(H−1),H−1] 的有限域；零位移也必须保留。该域只完备于此明确变换族，不覆盖缩放、旋转、环绕、动画或未观测运动；对这些情况返回缺少解释族/未判定，不能将它们宣布不存在。预算分给候选枚举、全支持验证和歧义分支，配置中给每项上限并记录实际停止点。

同色多对象的对应不是按颜色唯一连接。`correspondence_branches` 保存源支持→目标支持的候选映射；同一解释中角色是否互异、是否守恒、允许消失/生成或遮挡，均是明确假设。两个同形对象交换位置时，像素可能完全不变；公开证据不能确定持续身份，就保留多种对应或只作可识别的商，不制造身份真值。候选联合是同一分支内的绑定关系，不把来自不同分支的局部成功片段拼接。

`scene_transform_candidates` 单列镜头或全局显示变换解释：从多个空间分散支持提出同一变换及其例外，同时保留局部对象运动解释。整屏共同平移是镜头候选的证据，不是自动证明；背景、面板和动态主体可以有不同变换通道。只有采用某个显式平移解释分支后，才在该分支内定义相对位移 δlocal=δobserved−δcamera；旋转、缩放等分支需要各自正确的坐标变换，不套用此差值公式。不得先强行消掉最大位移再把剩余量作为无条件动作因果事实。分支预算耗尽保留 unresolved。

输出给学习语料的描述可以包含 `support_before`、`support_after`、`displacement`、动作和关系见证；每个项都带“在哪个已完成事件、哪个解释和哪个表达位置获得”的来源。这里的位移可以由历史后帧估计。随后 `Mechanisms.jl` 必须把它分成固定候选机制参数、动作前可求值参数项或未解释潜变量；只有前两类可以进入当前动作预测。当前目标求解器不能自由选取历史描述中的效果参数来令目标成立。包含当前真实后帧读取的项只可作事后描述，不能充作 Recognizer 或可执行动作前 guard。

这一层的缓存同时记录“未找到其他对应”的负依赖。新增支持、修改组件解释或补齐公开响应时，相应“唯一对应”“没有阻挡”“无面板变化”结论必须失效；原始事件及此前预测仍保留。`Grounding.jl` 只负责候选与语料构造，定义发现仍由唯一 E-Stitch 路径执行。

## 5. Matching、推出和重写的可执行算法

### 5.1 原生匹配之外的控制层

~~~text
match_pattern(P, M, frozen_scope, budget):
    核对 signature、解释版本、来源窗口与 schema 类别
    把已绑定角色编为 initial
    把算子、类型、端口位置、明确值限制编为 predicates
    为要求所有角色不同的组件选择 monic；一般成对互异另做 filter
    对一个持久工作分片调用 Catlab.homomorphisms
    对返回映射检查跨角色资源、否定、时间和身份约束
    为合法映射恢复 occurrence/证据见证
    返回已完成分片、合法见证及未完成分片；不修改模型
~~~

对返回 k 个结果的目标，调用 take=k+1 可判定“超过当前消费上限”；只有原生调用正常完成且结果少于 k+1，才能据此确认该分片穷尽。达到 cap 后保守记 incomplete；不能凭恰好 k 条推断不存在第 k+1 条。

若需要全匹配而分片超限，把某个未固定角色的有限候选域按 initial 分成互不重叠工作分片，继续调用同一个上游 matcher。这只是任务拆分，不复制 CSP 搜索算法。全部分片完成才可声明全集。需要保存分片定义、已完成边界与去重规则。

原生搜索在第一个匹配前仍可能很贵。首轮的硬时限由隔离 Julia worker 与调度器管理，超时只中止当前分片并保留 incomplete。不要声称上游内部可原地续算；重复计算成本须计量。以后若必须加内部预算回调，作为明确维护的窄补丁验收，不调用未承诺稳定的私有 backtracking state 来伪造已有接口。

### 5.2 推出与联合匹配

~~~text
glue_patterns(P, Q, I, i, j):
    验证 i:I→P 与 j:I→Q 的自然性和共享角色含义
    colim = pushout[C](i,j)
    保存合成模式 ob(colim) 及两边注入
    运输类型、端口、来源和 must_distinct 条件
    若同一合并类被要求互异或持有冲突函数值：拒绝
    返回模式及见证

glue_matches(MP, MQ, I):
    按限制到I的共同绑定键连接
    检查同一解释、事件、时间接口和背景条件
    检查所有跨两侧互异角色及共享资源约束
    返回联合关系；保留输入不完整性，不把空前缀当无解
~~~

精确微例：P 要求持有(a,k)，Q 要求匹配(k,d)，I 包含共享 k。场景只有持有(a,k1)、匹配(k2,d)，联合为零；加入匹配(k1,d) 后，联合给出相应见证。它证明绑定合法，不证明“持有”“匹配”的环境解释为真。

单射反例：P、Q 各一个点，I 空，M 一个点；两侧局部映射各自单射，整体两个点映到同一点不单射。因此普通 Hom 的推出—拉回公式不能直接换成“单射 Hom 仍满足同一公式”。必须追加跨侧互异检查。

### 5.3 AlgebraicRewriting 的首个使用边界

当已有明确的派生状态规则 L←K→R，例如“删去旧位置事实、保留同一角色、加入新位置事实”，使用 Rule{:DPO}(l,r;cat=C,monic=…)。先检查 can_match(rule,match;cat=C) 返回 nothing，再调用 rewrite_match(rule,match;cat=C,check=true)。已核源码中直接 rewrite_match 的 DPO 底层检查默认并非强制；项目包装必须显式执行合法性检查。[S12]

原始公共事件不可用这套重写原地改动。被重写的是冻结模型的派生表示，新版本保留 old→new 搬运映射及反例来源。DPO 失败应返回 dangling、identification 或应用条件的具体见证；不能自动换成 SPO 并删掉更多上下文。

重写处理器不生成规则、不判断经验规律稳定。若首个移动闭环只需关系更新，完整 DPO 运行可在阶段二启用；依赖预检先证实现成接口能工作，避免后面重新造轮子。

## 6. 机制关系：未知、完成性、后帧与控制权限

### 6.1 三个互相独立的判断

每个求值返回的内容必须解释清楚：

1. 语义判断：true、false、unknown。unknown 表示当前解释或信息不足。
2. 计算状态：complete、incomplete、unsupported、invalid。预算耗尽是 incomplete，不直接变为 unknown 或 false。
3. 有效范围：模型/解释版本、输入域、输出通道 Ω、来源与参数假设。

有见证的存在性 true 可以在枚举未完成时成立；有具体反例的全称 false 也可以早停成立。相反，存在性 false 与全称 true 需要相应范围的完整搜索。完整性必须与具体量词查询一起解释。

缺失事实不是真假未知的第三个布尔值可以任意商化。部分匹配结果不等于全部满足关系；已定义空关系与尚未定义机制是不同情况。

### 6.2 后帧泄漏的精确检查

PhaseCheck 不应简单禁止所有“后帧”字样。过去已完成事件的后帧，在当前时刻是合法历史；当前待执行动作的真实后帧才是未来信息。

用实际可用来源与冻结决策 cutoff 检查：

- Descriptor（历史描述）可读取已经发生的前后记录。
- Recognizer（当前识别）可读取当前观测及 cutoff 前的历史。
- Predictor（预测关系）可以包含未赋值的 Future 逻辑变量，但不能从真实后帧把它绑定为答案。
- Action Program（动作程序）输出纯程序值；只有唯一执行器可以提交动作。

训练时用后帧估计位移是合法的效果学习；预测时所用位移参数必须是冻结模型中的常量或仅由动作前输入计算的项。目标求解器不能为了成功把位移改成想要的值。

### 6.3 模式参数的四种权限

| 变量种类 | 谁能赋值 | 禁止行为 |
| --- | --- | --- |
| 已观察输入 | 当前不可变证据和绑定 | 为满足目标修改输入 |
| 可控制参数/接口允许的目标角色 | Plan 求解器 | 把真实持续身份、按键实际控制谁当自由旋钮 |
| 机制参数/潜在假设 | 冻结工作模型或明确记录的候选模型选择 | 目标回推时偷偷重新拟合 |
| 未来变量 | 对关系求后继 | 读取真实未来帧；把任意未来都允许称为成功预测 |

## 7. RelationSemantics.jl 与 Post–wlp

### 7.1 复用有限关系，补模型语义

RelationSemantics.jl 拟提供：

- compile_relation(expression, domains, version)：在明确有限域上得到 Catlab 有限关系和变量编号映射。
- compose_rel(first, second)：按同一中间域做关系复合，保存参数/来源及 Ω。
- post(relation, input_set)：可能后继与计算状态。
- wlp(relation, goal_set)：全部已定义后继满足目标的输入集合及反例。
- successors(mechanism, current, action, query_scope, budget)：返回已求后继、未求约束、模型是否定义、Ω、冻结参数、穷尽范围和停止原因。

逻辑定义仍是：

\[
\operatorname{Post}_R(P)=\{y\mid\exists x\in P:\;xRy\},
\qquad
\operatorname{wlp}_R(Q)=\{x\mid\forall y:\;xRy\Rightarrow y\in Q\}.
\]

\[
\operatorname{Post}_R(P)\subseteq Q
\Longleftrightarrow
P\subseteq\operatorname{wlp}_R(Q).
\]

项目写读取这些有限关系的谓词查询包装，不重建通用范畴库。原始网格不展开成“全部可能画面”的完整状态集；关系只覆盖当前具体问题的有限候选域。输出本身很大时明确成本与 incomplete。

### 7.2 矩形矩阵方向是必须执行的依赖测试

已读源码的 FinRelationMatrix 单参数构造使用“列对应输入、行对应输出”；dom 取列数、codom 取行数，R(x,y) 读取 matrix[y,x]。同文件的三参数便捷构造却断言 size(matrix)==(dom,codom)，与这些约定在非方阵下不一致。此为源码检查发现的具体风险，本轮未执行复现；不能称该路径已通过。[S13]

首版包装明确构造 rows=|Y|、cols=|X|，调用单参数 FinRelationMatrix(BoolRig.(matrix))，然后断言 dom/codom 与调用取值。禁止依赖上述含两个维数参数的便捷重载。预检采用 2→3、3→2 关系，不能只测方阵掩盖方向问题；若单参数路径也失败，阻断该后端接入并修正固定依赖，不静默换一套关系语义。

Boolean 关系只表示支持集合。求路径数、来源重数、成本和 SMC 采样重数时不能默认布尔矩阵的 OR 就保留这些信息；这些消费者必须有各自明确接口。

### 7.3 非空、已定义、完整性与保证

Plan.jl 的 precondition 使用上述后继接口，不能仅检 wlp：

~~~text
precondition(H, current, action, goal, budget):
    检查公共动作可用、输入绑定与版本
    goal读取超出Ω → unknown_scope
    机制未定义当前输入 → unknown_model
    result = successors(...)
    未完成目标所需后继搜索 → incomplete
    已定义且完整但无后继 → inconsistent_or_disabled
    后继非空且全部满足goal → model_conditional_guarantee
    仅部分满足 → possible_only
    无后继满足 → goal_not_established
~~~

多步还须传播资源、所有允许分支与响应/终止假设。未达强保证时仍可输出显式假设下的实验候选；不引入额外成功次数门槛。

三个必要反例：空关系使 wlp 空真，但不能执行成功；只搜索到成功分支，不能报告必达；Ω 只有位置时，不能保证剩余资源。前述算法逻辑由独立有限关系表核对，不与生产矩阵包装共用最容易出错的索引函数。

## 8. Mechanisms.jl 与 GuardRepair.jl：结构发现仍由 E-Stitch 承担

Mechanisms.jl 的 propose_mechanisms(definitions, snapshot, cursor, budget) 只进行变量模式划分、参数项枚举、关系求值与适用条件组合。它不复制 E-Stitch 的 Expand/Reuse、子程序提取或另建反统一库。

输入是学出的关系定义 R、公开动作、解释分支、已确认事件、冻结库。参数项仅来自有来源的常数、动作前输入及已允许原语/旧宏的有限组合。按类型和编码成本枚举，保留未搜索前沿。语义等价只按合法定义性规则去重；样本同值只作可恢复候选分组。

对参数候选 θ：
- S 是在冻结解释下支持关系的事件；
- B 是确实违反它的事件；
- U 是无法判定的事件；
- Ω 是预测实际覆盖的效果通道，不是全状态不变承诺。

GuardRepair.jl 的 repair_guard(hypothesis, S, B, U, predicate_pool, budget)：

~~~text
选一个非空支持簇S0，并记录为何归到该作用域
只保留在S0所有事件上为true、且动作前可用的谓词
对每个反例b，收集在b上明确false的候选谓词
若某b没有区分谓词：
    返回该b及缺失区分义务（扩大窗口/历史/角色/关系语言）
否则按成本求能命中每个反例的有限谓词集
    已有可行解可暂用；未完成全搜索不称最优
    返回G、支持、被排除反例、未知、剩余搜索
对所有受影响旧支持和反例重新求值
原事件、旧错误预测、原覆盖义务全部保留
~~~

允许作用域拆分；不允许删除“被新 guard 排除”的历史，使总规律表面变得完美。每个被排除事件进入另一分支的待解释义务。原机制没有未处理范围内反例可暂定使用；这不是全域因果证明。

## 9. QueryAbstraction.jl、CacheIndex.jl 与 Revision.jl

### 9.1 查询和历史细化接口与总计划共用

QueryAbstraction.jl 统一拥有：

- factor_query(alpha, q, finite_scope)：尝试定义 qbar，使 q=qbar∘alpha；同一抽象类里查询不同即返回两个具体状态见证。
- refine_partition(model, queries, actions, budget)：保留目标、资源、可用性及每动作后继类别/输出/代价联合描述；不能只比边际集合。
- check_causal_square(F,G,alpha,generators,scope)：先检查函子与端点，再用明确关系解释检查生成方块；保存 scope 和反例，不把样本相等当全域自然性。

历史细化候选来自公共历史和已学表达，不附加游戏隐藏模式。若当前帧完全相同、过去开关事件不同导致下一动作后果不同，保留能够解释该区分的历史摘要候选。

unknown 不能与所有值“相容后合并”：真—未知、未知—假各自不冲突，真—假冲突，不冲突不是等价关系。随机模型支持内的两次不同结果也不自动证明状态必须拆分；需核对允许后果或预测分布。

### 9.2 自有失效索引的最小责任

CacheIndex.jl 不是上游增量 matcher。它保存本项目派生计算的实际依赖：

- 被读取的公共字段/窗口及其不可变引用；
- 对象解释、宏定义、机制参数和查询版本；
- 成功匹配用到的角色；
- 未找到对象、无邻接、无符合项等负查询读取的集合/索引版本；
- 计算 scope、参数、枚举完整性和预算停止位置。

cache_lookup(query, binding, versions) 只复用全部依赖仍有效的结果。新增一个物体时，“原来没有匹配物体”的缓存必须失效，即使它当时没有引用任何物体节点。

invalidate!(changed_refs) 沿读取/证明依赖闭包标记派生结果失效；不删除原始事件。异步学习完成时，先核对库版本，再核对 snapshot 之后的新相关证据；发布使用唯一入口的 Compare-And-Swap（比较并交换）版本检查。

Revision.jl 的 assess_and_revise!(frozen_prediction, response, versions) 区分：
协议缺失、对象对应冲突、guard 条件错误、效果规律错误、抽象过粗、程序资源/接口错误。它提交修订并使受影响的未执行程序停止；不能通过恢复旧模型撤销已经发生的动作。

### 9.3 必须做真正的消费检查

修订验收不仅比较日志：新版本应改变至少一个后续查询、合法绑定、预测、候选排序或实际动作参数。若模型版本变了而 Controller 继续消费旧缓存，闭环失败。

增量求值与独立完整求值在相同冻结有限问题上比较已完成的语义、绑定和效果集合。两者允许读取不同依赖集合、采用不同保守失效范围；不能要求同预算下的中断状态也完全相同。独立参考路径只用于验证，不是生产 fallback。

## 10. 复杂地图控制的一个完整可核查例子

以下是测试夹具和暂定机制的说明，不是预置 ARC3 机制。

公开网格中有一个两像素横向支持 S={(0,0),(1,0)}，候选锚点 p，动作 a 的候选位移 δ。系统只在后续证据支持后才把该对应解释成可控移动体。暂定条件可能包含：

- 目标支持 p+δ+S 位于已知行动区域；
- 与静态阻挡、动态占据、门状态及方向限制相容；
- 当前资源 e 足够；
- 相关历史模式允许此动作。

关系 G_a(z)∧E_a(z,z') 使用同一角色、动作、历史与解释版本。若模型声明成功效果为 p'=p+δ、e'=e−1，这些是工作假设；若结果通道只覆盖 p/e，不能假设面板、门、计时或其他对象不变。

一次“向右失败”至少有这些竞争解释：选错受控对应、主体完整支持越界、门未开、其他对象占据、方向模式、资源不足、输入协议异常、尚需后续响应帧。系统把可观测分歧转成实验，不把所有失败都写成“墙”。

例如需要先开门再移动：

1. 当前宏和关系给出“改变门状态”的候选作用及资源消耗。
2. Hom/拉回把开门角色、接触角色与移动所需通路角色连接为同一门。
3. 目标条件沿第二步关系回推，再沿第一步关系回推；第二步 guard 在第一步后态检查。
4. 若第一步消耗唯一资源，而第二步也需要该资源，联合模型拒绝当前组合，不因两个动作各自有成功样本就放行。
5. 实际只发送第一步动作。完整响应到来后重新核对门、资源、角色与历史；预测不符则修订并停用旧后缀。
6. 下一动作消费修订版本。面板若提示资源/模式，不能因它不可行走而从证据依赖中删除。
7. “当前动作不能进入某格”只评价当前转移。不可达需要在指定完整模型、动作集合、历史/资源状态及目标范围上证明；有限搜索没找到只报告未完成或当前步界内未达。

大对象碰撞对完整支持或模型要求的扫过区域计算。只检查前沿需有特定平移、静态障碍与已知当前无重叠假设，不能把中心点测试当通用碰撞模型。

这些语义由 Mechanisms、RelationSemantics、QueryAbstraction 与 Plan 共同消费；范畴库负责结构连接和精确关系，E-Stitch 负责可复用定义发现，Python 只处于公共环境服务边界。

## 11. Codex 实施检查清单与定位

| 检查 | 最小正例 | 必须击中的错误 |
| --- | --- | --- |
| 依赖解析 | 四包指定版本与 Julia patch 产出 Manifest | 用 main 漂移或手写 Manifest 冒充已解析 |
| 源码/版本 | tag 与旧 SHA 的生产文件一致 | 仅版本字符串相同就推断源码相同 |
| 类型/程序 | A→B→C 顺序合法、单位化简 | A→B 接 D→E；动作被错误交换 |
| 匹配完整性 | k+1 结果检测消费者 cap | take=k 后把 k 条当全集 |
| 部分无解 | 完整微型域无见证 | 进程超时／预算停止报 false |
| 共享角色 | 持有k1与匹配k1可连接 | 持有k1与匹配k2误拼 |
| 互异角色 | 两个角色映到两个对象 | 两侧各自单射合成后碰撞 |
| 颜色/身份 | 同色不同对象可保留两身份 | 同色直接 Reuse 身份 |
| 连通 | 相邻同色生成分区 | 跨窗桥裁去后仍宣称对象限制自然 |
| 完整支持 | 三像素平移仍恢复完整三像素候选 | 把仅两端变化像素当主体 |
| 对应歧义 | 两个同色同形支持保留多解 | 按颜色唯一绑定或混合解释分支 |
| 变换族范围 | 平移有限域内完成后报告明确范围 | 用平移无解否定旋转、动画或遮挡 |
| 镜头解释 | 平移镜头与局部运动各有作用域 | 强行减去主位移就宣布动作效果 |
| 自然性 | 全部生成方块交换 | 只检查端点、check_equations=false |
| 无损展开 | 相同宏两次调用恢复两个 occurrence | 共享节点导致来源丢失 |
| phase | 过去已确认后帧可作历史 | 当前真实后帧泄漏预测 |
| 参数权限 | θ 为被冻结已支持位移 | 目标在右两格就把未知θ改两格 |
| 矩形关系 | 2→3→2 的明确矩阵合成 | 方阵测试掩盖行列反置 |
| wlp | 全部允许后继满足目标 | 空后继、部分枚举、Ω不足仍保证 |
| guard 修复 | 保留支持，明确false排除反例 | unknown当false；缩成空条件；删旧覆盖 |
| 历史细化 | 同帧不同后果产生可检验历史项 | 单帧哈希合并所有状态 |
| 缓存负依赖 | 原无匹配，新增物体后重算 | 空结果无对象依赖所以永不过期 |
| 发布竞争 | 新证据到达后增量核对再发布 | 旧后台结果覆盖新修订 |
| DPO | 合法接口保留/删除/创建 | dangling失败自动换SPO多删上下文 |
| 实际消费 | 新定义参与下一预测/动作 | 只写解释日志、控制器仍用旧路径 |
| 反例来源 | 夹具验证修订通路，真实轨迹验证消费 | 必须等待真实反例才推进，或伪造真实修复 |
| 资源/来源计数 | 同事件多帧去重，保存所有帧 | 动画帧/裁剪数被当独立实验数 |

以上是功能合同检查，不是要求先完成未知环境的全部因果证明。真实动作、固定公共夹具和离线回放分别记录，不混作经验支持。首轮不得遗漏真实 E-Stitch 调用、非预置定义、后续新事件消费、公共响应核对与下一版本消费。

## 12. 官方固定来源

所有链接指向本轮实际读取的官方仓库固定源码。API 例子是源码核对的使用方案，运行可用性须通过第 2 节预检。

- [S1 Catlab Project.toml](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/Project.toml)。
- [S2 ACSets Project.toml](https://github.com/AlgebraicJulia/ACSets.jl/blob/aac441e1bf6e9813ba6da51a97d5d3738c3e549c/Project.toml)。
- [S3 GATlab Project.toml](https://github.com/AlgebraicJulia/GATlab.jl/blob/0944af7765b404c97f92b9909a56bb2535146caf/Project.toml)。
- [S4 AlgebraicRewriting Project.toml](https://github.com/AlgebraicJulia/AlgebraicRewriting.jl/blob/23f444de687d3926cbd0c8e7fd2fc574b40af8e6/Project.toml)。
- [S5 Catlab tag 与旧固定点比较](https://github.com/AlgebraicJulia/Catlab.jl/compare/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32...692bd5e9d4b792a01bc507a59a19c2311b321359)。
- [S6 AlgebraicRewriting 0.5.0 release](https://github.com/AlgebraicJulia/AlgebraicRewriting.jl/releases/tag/v0.5.0)：删除增量同态搜索的 release 说明。
- [S7 Catlab 0.17 迁移说明](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/docs/src/devdocs/release.md)：显式范畴、HomomorphismQuery 未恢复、hot loop 动态派发边界。
- [S8 Catlab HomSearch](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/src/categorical_algebra/pointwise/homsearch/HomSearch.jl)：L48–150 唯一/存在/列表、take/max；[对应官方测试](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/test/categorical_algebra/pointwise/csetcats/HomSearch.jl)。
- [S9 C-set colimits 官方测试](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/test/categorical_algebra/pointwise/csetcats/Colimits.jl)；[limits 官方测试](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/test/categorical_algebra/pointwise/csetcats/Limits.jl)；[带标签 ACSet 推出及属性冲突测试](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/test/categorical_algebra/pointwise/acsetcats/Colimits.jl)。
- [S10 GATlab theories](https://github.com/AlgebraicJulia/GATlab.jl/blob/0944af7765b404c97f92b9909a56bb2535146caf/docs/src/concepts/theories.md) L119–127；[symbolic models](https://github.com/AlgebraicJulia/GATlab.jl/blob/0944af7765b404c97f92b9909a56bb2535146caf/docs/src/concepts/symbolic_models.md) L15–57；[models](https://github.com/AlgebraicJulia/GATlab.jl/blob/0944af7765b404c97f92b9909a56bb2535146caf/docs/src/concepts/models.md)。
- [S11 Catlab FreeCategory](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/src/theories/Category.jl) L16–18；[实际加载的自然性检查](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/src/categorical_algebra/cats/natural_transformations/Transformations.jl) L65–105。注意仓库还存在相近旧目录 transformations；本轮核对 cats/module.jl 实际 include 的是 natural_transformations。
- [S12 AlgebraicRewriting Utils](https://github.com/AlgebraicJulia/AlgebraicRewriting.jl/blob/23f444de687d3926cbd0c8e7fd2fc574b40af8e6/src/rewrite/Utils.jl) L44–90、L159–211、L273–286；[DPO](https://github.com/AlgebraicJulia/AlgebraicRewriting.jl/blob/23f444de687d3926cbd0c8e7fd2fc574b40af8e6/src/rewrite/DPO.jl) L22–28；[官方使用说明](https://github.com/AlgebraicJulia/AlgebraicRewriting.jl/blob/23f444de687d3926cbd0c8e7fd2fc574b40af8e6/docs/src/index.md)。
- [S13 Catlab FinRelations](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/src/categorical_algebra/misc/FinRelations.jl) L95–118、L129–139、L230–244。
- [S14 ACSets JSON](https://github.com/AlgebraicJulia/ACSets.jl/blob/aac441e1bf6e9813ba6da51a97d5d3738c3e549c/src/serialization/JSONACSets.jl) L28–74；[schema/GAT 互操作](https://github.com/AlgebraicJulia/Catlab.jl/blob/ca2b685bdc5fb7507460a42e8dc4aa3b5d202a32/src/ACSetsGATsInterop.jl)。

既有项目语义依据：11-20/04 K01–K10；11-20/05 的条件修复、闭包与分区细化；11-21/02 的按需求值与负依赖；11-21/04 的真实消费/反例夹具分账；11-23/02 的类型、phase、旧库、来源、共享参数、模型求解权限。它们的旧 Python 计划路径不沿用；本项目按新的 python/、julia/TddESCat/、rust/bridge/、third_party/egg-stitch/ 布局实施。

