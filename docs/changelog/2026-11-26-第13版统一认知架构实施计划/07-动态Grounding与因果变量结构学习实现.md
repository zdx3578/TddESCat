# 07｜动态 Grounding、作用关系、变量发明与持续结构学习

本规格对应 04 的 M1.3、M2.1。沿用 05 的快照/证据/类型合同、06 的区域和联合索引。M1 完善精确公共变化→作用候选→任务→反馈的生产链；M2 再使统计和抽象发现不断扩大模型语言。不能等概率电路或程序合成全部完成才发出第一动作。

本次源码基线为 `TddESCat@0d53a1c683fbe0ba3c9d8e41ac66cb6fe23dce81`，包括已存在的 `RelationTasks.jl` 与 `RelationPolicies.jl`。以下明确区分三件事：源码已经完成的能力、需要修改的项目适配层、第三方库已经提供的算法。**生产概率/代数电路只接入 CirKit 0.3.1 官方实现；Julia 保持语义知识、样本、对象/变量修订和唯一动作仲裁的所有权。** 不再新写 Julia 概率电路数值内核，也不同时安装 ProbabilisticCircuits.jl、SPFlow、DeepLog 作为其他生产路径。

归纳与统计的输入是有可回读定义的 Ground Atoms（基原子事实）：例如区域成员、对象候选绑定、相邻关系、动作参数、前后关系改变及公开状态。原始像素和返回帧用于公共证据保存、精确关系提取和有需要的向下精化；不得把整帧像素直接交给 Inductive Logic Programming（归纳逻辑程序设计，ILP）或概率电路，要求其从零重新发现全部几何与语义。区域也只是一种初始支持候选，不能直接等同于功能对象。

## 1. 现有模块的接入裁决

| 源码落点 | 保留内容 | 修改内容及消费者 |
|---|---|---|
| `Grounding.jl` `ground_event`、`support_candidates`、`correspondence_candidates` | 基础分区、平移验证、原证据 | 统一所有帧及区域；增加可续分解/组合、类型化对应与剩余变化；供 LocalEffects/绑定使用 |
| `LocalEffects.jl` 的 `observed_effects`、`public_effect_record`、`relation_corpus` | `PublicEffects`、已知效果、残差和 alternatives | 将原 effect family 转为共享关系表达；所有真实变化及歧义进入待解释义务；不只把已熟悉的作用编入学习样本 |
| `JointMechanisms.jl` 的 `observed_joint_model`、`evaluate_joint_rule`、`measure_joint` | 已有具体联合效果、相对点击/作用角色绑定、预测及回执核验 | 扩展为有版本的统一角色与上下文关系；保留非局部作用、歧义和残差；域扩张需要证据，现有相对位置迁移不等于完整对象语义 |
| `InterventionLearning.jl` 的 `choose_intervention`、`observe_intervention!` | 已有公开干预经验、变化上下文重探及晋级证据 | 分开局部作用、同关任务、跨关晋级；保存未变化与失败；将实验建议交现有仲裁器，不新增动作通道 |
| `RelationTasks.jl` 的 `observe_relations!`、`prepare_relation_tests`、`task_arbitration` | 已有 producer 索引、具体效果检验、局部关系任务、延迟作用探测和失败续学 | 接入版本化变量、条件、置信信息及未决覆盖义务；经验 `bound/replicated` 与因果识别、数学证明分别表达 |
| `RelationPolicies.jl` 的 `policy_episodes`、`policy_corpus`、`relation_policy_choice`、`confirm_relation_policy!` | 已有从公开轨迹提取顺序、分支、重复的入口，E-Stitch 语料及动作后策略反馈 | 历史状态修订使关联策略失效/重绑；统计学习和可选自动机只产生候选及实验义务，不绕过现有策略签收 |
| `AssociationIndex.jl`、`AssociationScheduler.jl` | 现有证据联想和调度入口 | 06 的六维联合召回及反例义务；按实际查询语义生成候选，不能限定同形同动作才能召回 |
| `SceneMemory.jl`、`ProjectionRevision.jl`、`GuardRepair.jl`、`Revision.jl` | 现有状态记忆与修订入口 | 共同版本和依赖事务，动态状态和因果条件精化；将未知重新派为辨别性实验 |
| `OnlineSession.jl` 的 `OnlineKnowledge`、`archive_trial!`、`candidate_evaluation` | 权威在线知识、真实 trial、候选预测 | 更新同一知识快照；按依赖而不是仅按动作重新验证；消费以下统一作用契约 |

这些是对已存在源码的改进，不新增独立 PC 游戏智能体。`RelationTasks` 已在主循环参与动作选择和反馈，`RelationPolicies` 已有实际策略执行路径，不能把这些能力重新列为“从零开发”。以下 `explain_event`、`discover_variables!`、`effect_contract` 等名称是**本项目拟增/拟统一的接口**，不是既有导出函数或 CirKit API。实际落点、第三方函数和结果消费者见第 6、7 节；语义发布统一经过 05 的事务。

## 2. 从公共事件形成可计算的作用证据（M1）

### 2.1 EventEffectView 与作用角色分离

`explain_event(snapshot_before, event_view, region_views, deltas) -> EffectEvidence`。

| 项目 | 含义及读取来源 |
|---|---|
| `event_ref` / `before_scope` / `after_scopes` | 唯一真实事件，实际前帧和所有返回帧；不把中间帧拆成独立动作 |
| `action` | 公开动作编号、坐标参数及可用性；未知回执不进入此接口 |
| `observed_effects` | 由精确事实差得到的像素、区域、关系、公开状态变化；新增、删除、保持不变都能查询 |
| `role_hypotheses` | 被选中、可能直接作用、受影响、参与上下文、保持不变等角色的候选绑定；不同角色不能默认相同 |
| `mapping_candidates` | 原支持与新支持的候选对应，含类型、实际映射、拟解释范围、见证；允许多对多和无匹配 |
| `unexplained` | 尚未被当前解释充分覆盖的变化（包括没有可识别对象的变化、无法解释的中间帧及公开状态变化） |
| `alternatives` | 可能同时解释历史但预测不同的机制/对象假设；不覆盖原始证据 |
| `completeness` | 观测已保存与候选解释是否枚举完整分别记录；不以观察完整推定机制完整 |

例如点击开关后远端区域改变：点击坐标已知，所点击区域的几何归属已知，远端变化已知；“开关是直接控制对象”“远端是由开关传播的间接结果”仅为候选。即使两个区域同色、同形或总是共同变化，也不据此确定其功能身份或因果方向。对全局无坐标动作同样不能选最大运动区域作为主体答案。

### 2.2 作用关系生成：用统一代数处理，不用游戏名称派发学习器

最初词汇只含公共事实和通用关系（位置、集合、颜色、相邻、相等、差分、时间、整数、动作及公开状态）。用已有 `ConceptTerm` 及 `RelationQueries` 的操作注册表表示候选；位置平移、几何变换等是通用数学算子，不是预设游戏机制。没有“这是移动关所以调用移动专用 learner”的分支。

```text
on_confirmed_event(before_snapshot, event):
    assert request confirmed and event order valid
    views = region_view(all frames); delta = event_delta(views)
    changes = derive_relations(delta, exact spatial facts, public fields)
    seed obligations for every observed change and every action role possibility
    verify frozen predictions against all referenced event frames / public fields
    record supported/refuted/unknown evidence, residuals and unresolved obligations
    revoke affected dependencies or mark their queries unavailable
    commit the exact event snapshot under 05 §5.2
    enqueue frozen background jobs for role alignment, candidate extensions and history checks
    recompute actual action candidates using the committed snapshot

run_frozen_relation_job(snapshot, obligations, frontier):
    retrieve structural and temporal candidates, preserving unfinished frontier
    align roles jointly with typed variable joins
    validate proposals against all relevant frames, public facts and histories
    return independently complete proposals with evidence and read ranges
    # Publication goes through the parent, scope and late-evidence checks in 05 §5.2.
```

“解释覆盖”用联合候选的实际输出与整个事件比对，而非将互不兼容的局部解释直接 union。当两个候选分别解释不同变化但要求同一个对象同时在两个互斥位置时，联合约束应拒绝；在并行、合并、拆分确有证据的条件下可允许多作用。对完全相同的事实及映射，使用规范定义共享计算，不合并独立事件。

### 2.3 对象候选生成、对应搜索与可续枚举

第一批候选是全部基础区域，包括背景和边缘；保留原像素成员。随后由 delta、历史映射和实验响应产生新候选。具体操作：

- **分解**：把同一基础区域按跨帧实际变化掩码、已知可分离响应、历史对应、颜色/边界/空间谓词的交及差划为子集。若单纯差分不能区分同色接触对象，沿候选边界、成员关系及历史对应继续生成精化；相同支持去重。不能把变化掩码直接宣布为完整对象。
- **组合**：在候选支持间用已知空间/时间关系、共同响应或条件相关性进行联合。物理不邻接的区域也可进入同一对象/机制候选。对象候选允许有多个部件、不同颜色、不连通及重叠；基础区域分区仍唯一。共享成员用显式约束，不禁止所有重叠。
- **对应**：用候选支持、角色类型、成员关系和可能变换建立二部对应，优先利用精确指纹/空间/属性索引减少候选。已知变换用完整支持与边界验证，未知变换用有限关系组合候选及残差表达；不能将最佳相似度直接当身份。允许新增、消失、拆分、合并、重叠和歧义。仅在有显式双射约束的子问题用二部匹配，不把所有动作都强制一对一。

候选搜索定义为有类型的表达式语言：有限集合/关系常量、已观察对象/角色槽、合法变换函数、Join/Project/Select/Union/Diff/Composition 等；不断从当前证据和已确认抽象扩充原语。产生器按规范表达式复杂度及证据相关性调度，所有合法未排除候选有可续任务。相同内容、类型不合法、已证明矛盾、已完整证明被支配才排除；统计低分只改变顺序。每个 finite domain certificate 明确当时的原语、定义域、表达式语言、等价归并与已经枚举的范围；没有全局无限候选已闭合的标志。原 `max_support_pixels=96`、相邻两区和最大候选数等不再是语义边界；不得偷偷减小为另一任意值。运行过程可分批、按真实资源暂停和保存完整 frontier。

```text
expand_support(frontier, snapshot):
    candidate = pop canonical next expression from fair scheduler
    if type_invalid or proof_of_infeasible: return rejected with certificate
    normalize symbolic member relation (NOT collapse provenance)
    if already checked in same scope/version: reuse check and proof
    emit query result and exact underlying support / unknown
    enqueue typed decompositions, unions, bindings, structural transformations
    when observations revise scope: invalidate affected checks and reopen frontier
```

在合成小域独立枚举全部支持和合法映射，比较候选关系和最终作用覆盖；真实64×64不要求先物化全部子集才行动，允许未枚举状态，但不得宣称已穷尽。这里的可续性是必要算法功能，不是“预算耗尽丢结果”。

## 3. 六类发现触发：如何真正产生新变量

`discover_variables!(snapshot, trigger) -> proposals + discriminating_obligations`。不是收到事件后固定调用六个昂贵全量算法；各触发共用候选生成、索引、检验器，只有受影响的关系进入工作队列。

| 触发 | 候选如何生成 | 如何通过或拒绝 |
|---|---|---|
| 共同集合结构 | 对已观察支持求交/差/包含、属性倒排查询、共同子关系；发现形状/部件/相对角色 | 成员回读、不同实例绑定、精确关系及历史作用检查 |
| 重复计算结构 | 在查询表达式 DAG、规范化 ATDD、关系因子中查找重复节点/相同子函数；提出参数化属性 | 相同类型及域上的语义等价证明；参数槽要有明确绑定；检查实际复用 |
| 共同变化 | 按作用事件及角色索引对齐多事件 delta/转换关系；对共同映射做反统一 | 在全部联合响应上重演，保留未解释变化；改变局部作用可区分共同运动与因果联动 |
| 预测差异 | 联合检索对同动作、可比状态给不同输出的候选；构造差分谓词与候选历史测试 | 找可合法实现的区分实验；未知反事实保留为待验 |
| 无法解释的真实变化 | 残差与未变化集合、远端角色、公开进度、前置历史作关系组合；检查所有相关类型候选而非只找近邻 | 新变量须解释既有反例、保留正例，独立检验新轨迹；无证据不确认为真 |
| 动作实验产生差异 | 在已对齐上下文比较不同动作、参数、或同动作不同条件；提出作用域/条件/隐藏状态区别 | 控制相关的效应和反例见证；随机性、观测缺失、隐藏状态不被自动当确定性因果 |

每个 proposal 携带类型、定义表达式、适用域、实例来源、为何触发、竞争解释、依赖版本、证据截止和当前验证状态。不能直接凭神经嵌入或数值 factor 生成无可绑定语义的对象。新增变量同时具备向下计算/绑定接口和向上抽象接口；未来不可计算时保留未知，不发布为可控机制。

## 4. 作用契约：同一表达服务于预测、联想和实际动作（M1）

对现有 `JointMechanism`、`ActiveMechanism` 扩展统一语义，不另立 effect 模型系统。目标接口 `effect_contract(rule_ref, snapshot)`：

| 字段/关系 | 必须回答的问题 |
|---|---|
| `roles` 与 `role_binding` | 动作所选/可能直接作用/受影响/上下文角色分别是谁，如何在当前观察绑定；联合约束与歧义保留 |
| `action_domain` | 实际公开动作编号和合法参数域；当前作用已验证范围及剩余范围 |
| `guard` | 所有必需条件与已知不充分条件；由当前、历史、资源或公开状态关系定义，不强制空间局部 |
| `transition` | 前后状态的类型化关系/概率模型；声明所覆盖的效果变量、发生顺序和联合效应 |
| `invariants` | 已有依据的不变属性/区域/公开量，以及尚未检查的部分；不把未观察到的变量当不变 |
| `evidence` | 正例、负例、竞争解释的区分见证、反例、当前已知范围/版本；原始事件可回读 |
| `status` | 候选、在声明域内有支持、被反驳、未充分区分、可精确模型验证等分别表达；不把经验支持称作数学完备性 |

`instantiate(contract, state, action)` 使用 05 bind 与 06 联合索引，返回一致角色绑定集合及未知部分；`predict` 用同一 transition 计算全部可见后继或已声明效果；`validate_prediction` 在新公共事件上比对冻结的事前预测。若只预测了一部分，不把其余变化默认正确。`refine_contract` 根据实际残差/冲突增删条件、拆分或组合角色、改变状态解释；每次修订都须通过版本事务。作用源与目标可跨区域、跨时间；近因与远端效应是否可识别是额外证据责任。

最小因果单元的候选语义为“给定动作/参数、绑定角色与上下文，发生什么可观测效果、哪些已知部分不变”。最小性是相对于明确的变量语言/目标/实验域而言：逐一尝试删除候选条件或合并角色，检查是否仍能保持已声明预测和作用区分；保留未被证实冗余的条件。并行机制可分解，联合依赖必须保留。不得用一个低秩因子或单个动画变化替代因果最小性。

### 4.1 局部任务启动，解除跨关正例前置

从实际已观察到的可重复、可区分变化生成 `RelationTask` 候选：希望建立/消除/维持哪个关系以及为什么。未破首关时可以有局部任务，即使不知道终局目标；局部任务的作用是探索可控关系、扩大机制与状态知识，不能冒充晋级。跨关目标模型继续需要真实跨实例证据；删除的是将这种证据作为所有学习启动门槛的错误耦合。

按 08 将局部任务、正式目标、待区分实验和恢复任务交给同一个仲裁器。不要在 `InterventionLearning` 里另建动作执行路径。

## 5. 关系闭包与布尔因子候选：复用同一关系核心（M2）

Boolean Matrix Factorization（布尔矩阵因子分解，BMF）和 Formal Concept Analysis（形式概念分析，FCA）在这里提供可验证的共同属性、闭包和矩形覆盖能力。它们不是两个必须部署的独立学习系统。本项目复用 `RelationQueries.jl`、06 的成员/属性索引以及 `ConceptConstruction.jl` 的概念构造入口，完成以下候选算法；PyBMF、Caspailleur 只保留为离线研究对照，不进入生产依赖，也不以等待安装它们延后语义候选的实现。

输入：由公共区域/对象实例及其经过验证的属性产生带作用域的部分关系 I(o,a)。每个单元可为已知真、已知假、未知或经验冲突；未知位置不是0。属性词汇由第3节持续扩展。

```text
from positive occurrence postings choose common attribute intersection
for attribute set A:
    E = objects satisfying every attribute in A (exact or supported scope)
    derive common attributes A2 of E, only if universal claim proven in scope
    canonical concept candidate (E,A2), record unresolved cells separately
    proposed rectangle E × A2 must not cover known false cells
    check coverage of observed positive incidences and residual
    schedule queries/experiments for unknown cells if relevant to action
    retain exact common factor with witnesses; preserve residual and alternatives
```

在完整二值形式背景中可直接使用 Galois closure（伽罗瓦闭包），内涵/外延互相计算，闭包幂等；在部分背景中分别维护一定成立和可能成立的扩展范围，不能将未知填零后称闭合概念。利用倒排位图求交生成候选；对子集按规范顺序惰性枚举，证明无解时剪枝。BMF 不是唯一概念格，最优布尔秩求解本身困难；本阶段用实际可验证的矩形发现/残差分解，不承诺最优分解。对稠密合成小域以独立穷举判断是否错误覆盖；对实际域报告表达长度、覆盖、未验证数、候选采用和复用成本。语义抽象进入 08；单纯数学共享保持可解压和证据。

具体调用链为：第 3 节的共同集合/残差触发 → `ConceptConstruction.jl` 中拟增 `propose_relational_factor!` → `RelationQueries.jl` 的关系查询与 06 成员索引计算交/差/包含 → 返回候选外延、内涵、反例和未定单元 → 同一概念签收事务 → `JointMechanisms` 的角色绑定、条件查询与任务召回。候选结果不直接新增无定义的潜变量。每个已发布因子都有展开查询，删除或修订源事实后能够按依赖重新计算，不能只保存不可逆的低秩矩阵。

独立小域裁判直接遍历原始部分关系，核对已知真/假不被改写、闭包只在声明的完整背景使用、未知范围未丢失、因子展开加残差与原关系一致。这样签收的是所需能力，而不是“调用某个 BMF/FCA 库即已完成”的名称清单。

## 6. Probabilistic Circuits（概率电路，PC）：CirKit 负责数值，Julia 负责持续学习语义（M2）

### 6.1 唯一生产后端、部署边界和实际 API

锁定 Python 包 **`libcirkit==0.3.1`**，发布源码提交 **`aa7c78c3da676638e9b26ba4b7754171922c0327`**，许可 GPLv3。其元数据要求 Python ≥3.10、PyTorch ≥2.3.0、NumPy ≥2.1.0；实际完整依赖由独立计算项目的锁文件固定，不能把这些最低要求误写为已测试的组合。包名是 `libcirkit`，导入名是 `cirkit`。[发布记录](https://pypi.org/project/libcirkit/0.3.1/)与[固定提交的项目元数据](https://github.com/april-tools/cirkit/blob/aa7c78c3da676638e9b26ba4b7754171922c0327/pyproject.toml)是版本依据。

拟增独立项目 `python/compute/pyproject.toml`，计算进程入口 `python/compute/src/tddesc_compute/worker.py`，电路适配器 `cirkit_adapter.py`；同一纯计算环境可承载计划中 cvc5 的官方 Python 适配器，不能复用公共环境/裁判的 `tddesc_tools` 环境。worker 不接收公共动作凭据、游戏 API 地址、环境内部状态、可写知识目录或任意 Python 表达式。它只读取 Julia 封装的有类型请求：本次作业 `inputs/` 是冻结只读输入，`outputs/` 是允许 worker 写候选工件的独立区域；请求/结果仅引用相应白名单内经摘要校验的相对路径，不以输出权限改写输入。候选经 `ComputeBridge.jl` 返回，由 Julia 签收后成为不可变正式工件；动作权和知识签收权均在 Julia。作业路径、解释器、设备、精度和训练参数均写配置文件，不用环境变量传配置。

以下上游能力已按固定提交核实；左列项目函数名均为**拟增 adapter**，不是上游已有接口。

| 调用者 → 项目适配器 | CirKit / PyTorch 的真实 API | 返回内容 → 消费者 |
|---|---|---|
| `CircuitLearning.jl` 的结构提案 → `CircuitAdapter.jl` 拟增 `submit_circuit_candidate!` → Python `build_symbolic` | `cirkit.symbolic.circuit.Circuit(layers, in_layers, outputs)`；`CategoricalLayer`、`HadamardLayer` / `KroneckerLayer`、`SumLayer`；`Parameter`、`SoftmaxParameter`、`ConstantParameter` | 具有固定变量编号/作用域的符号结构；回显结构摘要 → Julia 核对变量与角色绑定版本 |
| 同一候选请求 → Python `compile_candidate` | `PipelineContext(backend="torch", semiring="lse-sum", fold=True, optimize=True).compile(sc)` | 编译后的 `TorchCircuit` 与结构属性 → 训练、查询和独立核验；不据“编译成功”签收语义正确 |
| `candidate_evaluation` 的批量概率查询 → 项目 `query_circuit` | `circuit(x)`；`IntegrateQuery(circuit)(x, integrate_vars=mask)` | 对数联合/边缘值及错误状态 → `CircuitAdapter` 还原变量含义，供关系任务排序和冻结预测使用 |
| `query_circuit` 的条件分布请求 → 项目 `conditional_distribution` | 两次以上上述边缘查询，按共同模型计算对数比；上游无本项目 `condition(...)` 接口 | 目标取值的条件概率、分母及未知原因 → `RelationTasks` 的带证据预测；不能代替精确合法性与角色绑定 |
| 类型/作用域已核验的代数查询 → 项目 `compose_query` | `cirkit.symbolic.functional.evidence(sc, obs)`、`integrate(sc, scope=...)`、`multiply(sc1, sc2)` | 受结构兼容条件约束的新符号电路 → 同一编译/查询路径；不承诺任意两电路均可高效相乘 |
| Julia 冻结训练数据和结构 → 项目 `train_candidate` | `torch.optim.Adam(circuit.parameters(), ...)`、损失 `.backward()`、`optimizer.step()` / `zero_grad()` | 新参数、训练/验证指标、参数摘要 → Julia 发布审查；结构生成、变量发明和知识事务均不是 Adam 的职责 |

API 源码依据：[`Circuit`](https://github.com/april-tools/cirkit/blob/aa7c78c3da676638e9b26ba4b7754171922c0327/cirkit/symbolic/circuit.py)、[layers](https://github.com/april-tools/cirkit/blob/aa7c78c3da676638e9b26ba4b7754171922c0327/cirkit/symbolic/layers.py)、[pipeline](https://github.com/april-tools/cirkit/blob/aa7c78c3da676638e9b26ba4b7754171922c0327/cirkit/pipeline.py)、[queries](https://github.com/april-tools/cirkit/blob/aa7c78c3da676638e9b26ba4b7754171922c0327/cirkit/backend/torch/queries.py)、[symbolic operations](https://github.com/april-tools/cirkit/blob/aa7c78c3da676638e9b26ba4b7754171922c0327/cirkit/symbolic/functional.py)、[官方训练示例](https://github.com/april-tools/cirkit/blob/aa7c78c3da676638e9b26ba4b7754171922c0327/notebooks/learning-a-circuit.ipynb)。

CirKit 也有 `cirkit.backend.torch.em_optimizer.EM`，这是 Expectation Maximization（期望最大化，EM）参数优化器，并不是在线对象/结构发现器。本阶段统一使用上述梯度训练合同，避免同时维护另一条未完成缺失值验收的训练路径。官方 EM 的训练钩子和期望计数不能直接充当真实干预次数；保留为后续研究参考。ProbabilisticCircuits.jl、SPFlow、DeepLog 同样只进入文献/对照清单，不参与运行时选路。

### 6.2 Julia 保有的样本与变量合同

拟增 `julia/TddESCat/src/CircuitLearning.jl`，负责从当前知识快照产生语义特征、记录冻结预测、组织结构候选及重训练。拟增 `CircuitAdapter.jl` 仅负责检查、编码、请求和结果还原；通用进程/协议职责放 `ComputeBridge.jl`，不把知识算法塞入通信层。协议使用拟增 `protocol/compute/v1/request.schema.json` 与 `result.schema.json`；既有 E-Stitch `protocol/v3` 独立保留。

每项数据都须解释清楚其含义，不以一个无说明的数值矩阵替代：

| 合同项 | 含义、来源与责任 |
|---|---|
| 事件集合与截止点 | 每个训练观察以唯一已确认 `event_ref` 为真实事件去重主键；带 before/after 引用及公开顺序截止。测试条件、历史和模型投影用于分组/解释，改变这些字段不产生一次新的真实干预。重复读取、多帧、重复推导不增加事件数。一个动作作用多个对象时保留联合记录；不能把同一事件展开成多个独立样本 |
| 变量定义版本 | 每列指向可执行关系定义、类型、角色绑定及离散值域版本。类别编号由 Julia 固定映射，worker 不得自行重新编号；不同游戏/对象语义未验证等价时不混合统计 |
| 值与观察掩码 | `values[B,D]` 是合法域内的整数编码，B 为唯一事件数、D 为本模型变量数；`observed_mask[B,D]` 表示该单元确有观测见证。未知、未执行、角色歧义和证据冲突另存原因，不能编码成 false、类别 0、NaN 或负索引 |
| 轨迹与独立性分组 | 会话、attempt、关卡/任务及可比起点标识用于分组评估。事件去重只消除重复计数，不证明相邻事件独立；按轨迹保留统计相关性，不用像素或角色数量虚增置信度 |
| 结构与参数版本 | 结构表达、变量顺序、作用域分解和参数分别有版本/内容摘要；句柄包含 `structure_version`、`parameter_version` 与 `parameter_digest`。结构相同可以复用编译计划，但不能把仍被旧预测借用的参数对象原地修改；参数变更产生新不可变句柄和预测版本 |
| 学习与验证分区 | Julia 在训练之前固定事件清单、输入截止与训练分区；留出轨迹不能进入训练。后台新证据补验记录单独的 `validation_through`，最终发布记录当前快照。它们不能改写原训练截止或事前预测的截止；候选训练后的回放不能冒充事前预测 |
| 请求/响应身份 | 请求包含基础快照、变量/角色/结构/参数版本、证据截止、配置及依赖 pin 的摘要；响应原样回显并附候选工件摘要、结构检查、训练指标及未知原因。核对实际读取依赖，不能只因无关快照推进拒绝结果。不完整模型工件不得发布；批量查询按子请求身份消费已完成且依赖仍有效的部分，同时保留未完成范围，不能把整批误标为完整 |

有限随机变量覆盖动作参数、角色绑定后可计算的上下文、历史区别、联合效果、公开进度/终止状态。动态对象只是产生新定义或新绑定的来源，不在 PC 内直接改变“对象是什么”。新增变量或域扩张时，由 Julia 从原始公共事件和版本化关系定义重新编码受影响事件；没有对应历史观测就保持缺失，不能按新模型的预测补成真值。

未知语义分两层处理：数值层用边缘化计算 `P(已观察部分)`；知识层仍保留“为何没有观测”。若观测缺失机制本身影响选择或结果，应单独建模/分层评估，不因使用边缘似然就宣称样本无偏或因果可识别。冲突标签不得挑选一个真值覆盖另一个；先保留竞争解释，必要时拒绝该确定性训练任务。

### 6.3 编译结构与概率查询的硬约束

首个结构使用上下文的有类型决策分解：按某变量取值建立互斥分支，分支内乘积仅连接不相交变量范围；联合效果使用联合类别或继续分解，不凭便于计算就假设独立。相同可证明子函数可共享计算。可分解性只保证这种表示的计算性质，不证明真实世界变量独立。

CirKit 的 `CategoricalLayer` 是单变量叶，`num_categories` 至少为 2。单值域须由 Julia 消去为确定条件或在符号层合法表示常量，不伪造不存在的类别。多个语义变量不同基数时逐叶使用相应基数，不将一张图像模板误作语义关系模板。精确指示叶可用 `Parameter.from_input(ConstantParameter(..., value=one_hot))`，并固定不训练；普通分类叶用规范化概率参数。

**`SumLayer` 的默认权重是正态初始化，不保证非负或归一化，禁止直接用于生产概率模型。** 项目适配器显式用 `Parameter.from_unary(SoftmaxParameter(shape), TensorParameter(...))` 构造归一化权重，或对精确统计结果使用不可训练的已验证常量。训练后检查非负、有限数值及归一化。`Circuit.is_smooth`、`is_decomposable`、必要时 `is_structured_decomposable` 是上游已有属性；分支确定性及语义约束由 Julia 的分支构造证书和小域裁判检验，不杜撰 `is_deterministic` API。

使用 `semiring="lse-sum"` 时，数值输出为对数值。请求明确目标变量 T、已观察证据 E 和其余变量：

```text
query_distribution(request):                         # 本项目拟增适配器伪代码
    verify schema, model versions and declared variable/target domains
    q = IntegrateQuery(compiled_circuit)              # 上游真实 API
    batch_results = []
    for item in request.items:
        bind E, T and the observed_mask for this item
        if target unbound: append completed/unknown item; continue
        enforce any already observed target; never overwrite fixed evidence
        x = encode valid values; put legal placeholders only in masked positions
        log_den = q(x, integrate_vars = all variables outside E)
        if log_den == -Inf:
            append completed/unknown item with reason zero_evidence_mass; continue
        if log_den is NaN or +Inf:
            append failed item with numeric reason; continue
        answers = []; failed_assignments = []
        for t in this item's enumerated target assignments:
            if t contradicts fixed evidence:
                append answer(t, probability=0, zero_model_mass=true); continue
            x_t = x with only unfixed target columns set to t
            log_num = q(x_t, integrate_vars = all variables outside (E union T))
            if log_num == -Inf:
                append answer(t, probability=0, zero_model_mass=true)
            elif log_num is finite:
                log_p = log_num - log_den
                append answer(t, probability=exp(log_p), finite_log_probability=log_p,
                              zero_model_mass=false, underflow_if_present)
            else:
                append failed assignment with numeric reason
        append item result(answers, failed_assignments, covered_scope, remaining_work)
    return batch result with each item's identity, execution and coverage status
```

协议的语义输入统一叫 `observed_mask`：`True` 表示有实际观测，和逻辑值真/假无关。上游 `integrate_vars` 为布尔张量，`True` 表示要积分掉；适配器按本次查询的已固定变量取反构造，不能直接透传观察掩码。先放合法占位值是因为 `IntegrateQuery` 仍会计算叶的普通 forward，不能指望它跳过非法类别。上游返回维度为 `(B,O,K)`，O 为输出向量数、K 为每个向量的单元数；本项目单一概率模型要求 `O=K=1`，adapter 检查后取出，不任意 squeeze。

全变量积分检查归一化常数；归一化失败为候选不合格，不能悄悄重新标定后签收。**分母为 0 是条件分布未定义；分母有限而分子为 0 是合法概率 0。** 在 worker 内部后者可以是 `log_num=-Inf`，必须转换为有明确模型零质量标记的有限概率值，不能把 IEEE 无穷/NaN 写进 JSON；模型的零概率也不证明真实环境事件不可能。非零概率浮点下溢为 0 时保留有限 `log_probability` 并标注数值下溢，不能把它判成精确不可能；NaN/+Inf 则是数值故障。超出已声明误差界的非法概率也须拒绝，不能裁剪掩盖。响应明确 `value_encoding` 是 probability 或 log_probability，数值误差与统计不确定性分别记录。

每个目标赋值都有单独结果，循环结束后才返回该项分布；每个批次保留全部子请求身份。只有目标域和所有子查询确实完成才报告完整。对大目标域按 06 可续枚举分批查询，返回已覆盖部分及剩余游标；未查询、数值失败和已算得零概率不能混成一种状态。不能把部分赋值重新归一化成完整条件分布，也不用任意 epsilon 修补零分母。

概率通道采用非负规范化结构；代数研究通道可以计算具有不同类型的函数，但必须独立标明数域与运算语义。带负系数的代数电路、张量坐标和有理数 ATDD 不能直接解释为负概率，也不能把 PyTorch 浮点运算当精确有理数等价证明。CirKit 的乘法等组合操作仍需它所要求的结构条件，统一接口不意味着任意代数、任意电路都具有同样的可处理性。

### 6.4 持续结构学习：项目负责的算法，而非假定上游 `fit/structure_update` 已存在

`OnlineSession.jl` 在确认动作回执、`observe_relations!` 完成并提交对应证据后，调用拟增 `enqueue_circuit_update!`。动作前则先在当前已发布版本取得概率预测并冻结。`CircuitLearning.jl` 维护的工作队列由第 3 节触发，不在每步盲目全量训练。参考在线 PC 文献的结构更新思路，但新增变量、对象重绑、数据重编码、结构拆分/合并、训练提交和失效传播全部是本项目要完成的责任。

```text
on_confirmed_effect(snapshot, event):                 # Julia：拟增流程
    insert event exactly once; preserve its joint response and all frames
    score the frozen BEFORE-action prediction using the actual receipt
    derive semantic features at a declared feature/role version
    update exact observed counts and evidence dependency indices
    enqueue affected context splits, predicate additions and sharing candidates

prepare_circuit_revision(snapshot, obligation):       # Julia：拟增流程
    enumerate legal typed distinctions, including joint/XOR distinctions
    retrieve original events at a fixed cutoff; deduplicate by event_ref
    re-encode all affected events with explicit missing/conflict reasons
    freeze training/validation groups, schema and candidate circuit structure
    submit one typed request via CircuitAdapter -> ComputeBridge

train_candidate(request):                            # Python：拟增 adapter
    sc = build_symbolic(request.structure)            # 构造官方符号层
    check smoothness/decomposability and expected variable scopes
    cc = PipelineContext(...).compile(sc)            # 官方编译，不重写数值核
    use torch.optim.Adam on the normalized trainable parameters
    for a training batch:
        log_likelihood = IntegrateQuery(cc)(values, integrate_vars=missing_mask)
        loss = negative mean log_likelihood of informative unique events
        loss.backward(); optimizer.step(); optimizer.zero_grad()
    evaluate frozen validation groups without parameter updates
    return candidate specification, parameters, checks and version echoes

accept_circuit_revision(snapshot, response):          # Julia：拟增流程
    verify request identity, hashes, evidence cutoff and current dependencies
    if actual definition/domain/encoding/parameter dependencies became invalid:
        reject candidate and enqueue rebuild; keep the refinement obligation; return
    else:
        validate newly relevant evidence since the frozen job cutoff
        record validation_through separately from the unchanged training cutoff
        if validation unfinished: keep candidate and its remaining obligation; return
        if a disqualifying counterexample appears:
            publish the hypothesis revision, not this candidate model; return
    independently check small-domain probabilities and control distinctions
    compare predictive error, calibration, structure cost and rare conditions
    publish immutable structure/parameter version against the current parent snapshot
    if the parent changes during publication: recheck dependencies, never overwrite
    invalidate affected probability caches, guards, task rankings and policies
    rebind pending tasks; later PUBLIC receipts assess the new version
```

“在线”在这里指持续消费公共证据并修订已发布模型，不承诺每个新事件原位改图。结构未变可从同结构的参数工件继续拟合；变量、域或结构变更则从固定事件索引重建/重训练受影响候选。仅保存边流或成对统计不足以重建任意高阶分裂：原事件及可重算定义必须保留。二阶互信息只排序，不能排除 XOR 等高阶区别；模型内期望计数和先验伪计数不得写入真实干预计数。

完整参数工件由项目保存规范结构说明、变量映射、编译配置、上游 pin、参数 `state_dict` 及内容摘要；恢复时按同一说明重建/编译，再严格加载匹配参数并重跑查询一致性测试。不能假设 CirKit 有本项目的完整知识快照序列化接口，也不将不受控 pickle 作为跨进程协议。热加载只替换 Julia 已签收的不可变版本；worker 崩溃、重试、重复响应不得多次提交。

采用 prequential（先预测后学习）评估：新事实必须在预测冻结之后才能参与训练。按 episode/会话分组报告负对数似然、校准、未知率、条件覆盖与控制相关差异；训练拟合不能算泛化。低频但改变动作结果的条件不能仅因平均损失改善而被合并。精确同函数共享需要精确语义证据；统计共享是可撤销假设，保留原分支定义和事件索引，反例出现时可恢复并重训练。

### 6.5 结果消费者、失效和没有自动获得的保证

`candidate_evaluation` / `RelationTasks.prepare_relation_tests` 消费概率结果前检查对象绑定、动作合法性、变量域及实际依赖版本；基础快照用于追溯，不要求所有无关快照变化都使模型作废。当前状态的绑定/查询证据变化需要重算相应查询；训练截止之后仅追加事件，不自动使仍合法的同结构模型失效，但必须触发事前误差记录和学习义务；定义/编码改变或失效条件成立则立即撤销依赖。概率用于比较竞争解释、预测联合效果和安排区分实验；合法性、精确关系约束、数学等价及已知反例仍由 Julia 的确定语义控制。`P(E|A,C)` 不自动等于 `P(E|do(A),C)`；实际干预、可比上下文、混杂假设及识别条件须单独说明。

反例触发的依赖闭包为：对象/角色或变量定义 → 编码样本/电路结构及参数 → 查询缓存与条件预测 → 关系 producer / 任务候选 → 关联程序和策略。`ProjectionRevision.jl`、`GuardRepair.jl`、`Revision.jl` 与 05 事务共同执行失效，不仅清空一个数值缓存。每项消费者要拒绝错版本结果，并在新快照重绑；旧模型仅作为历史证据保留，不作为失效后的兼容求解路径。

新增 PC 必须通过本文件第 9 节的独立小域概率裁判、样本/版本测试及公开动作闭环验收，才能用于正式排序。当前库支持只解决计算内核复用，不意味着自动发现因果变量、保证样本独立、给出因果置信度或完成控制。缺少数据时继续现有同一关系核心的证据驱动实验，留下统计能力未完成标记；不重启一个图像训练或旧求解器路径。

## 7. 预测状态与时间结构：从响应历史中发现变量（M2）

Predictive State Representation（预测状态表示，PSR）的目标是用未来测试响应区分状态。不是把所有历史完整复制到状态键，也不是把相同当前画面永远合并。

生产必须完成历史区别、可验证状态定义和反例后的状态修订；这不要求先同时部署谱学习、自动机学习和另一种 PC 动态模板。首先扩展现有 `RelationTasks` / `RelationPolicies` 和关系核心的历史谓词；仅在 M2 出现明确历史区别子任务、且输入满足下面合同后，启用 **AALpy 2.0.0** 这一额外算法插件。

### 7.1 先实现证据驱动的历史条件与响应矩阵

历史 h 表示公开事件前缀及当前绑定；测试 τ 表示合法后续动作序列及相应可观察结果谓词。矩阵 H(h,τ) 只填实际执行、可比条件下取得的测试结果或其统计估计；未执行项保持 missing。动作序列无法到达、未执行、观察不到应独立标注。RESET 后状态只有经公开帧及响应验证才能当作等价起点。没有任意游戏内部状态设置接口。

具体实现：按当前可观测关系与作用契约检索可比历史；当同一动作的确定预测出现相反观测时，从历史谓词、顺序、重复次数、公开量及上下文变化产生区分候选；对每个候选检验能否使旧反例可解释且保留旧正例，按证据复杂度和实际区分效果组织工作队列。历史长度按待解释差异逐步扩充，不把现有固定 `[0,1,2,4]` 当穷尽域。若同一完整公开历史仍有不同结果，保留随机性或未识别隐藏变量，不能强迫确定分类。

`predictive_signature(history, observed_tests, snapshot)` 生成带测试集合、实际结果、未知范围和证据的响应关系；已观察测试相同只提出暂时可共享状态；新测试打破等价时分裂状态定义，重开原控制任务。学习初期可用精确状态关系做控制，谱学习只是明确的候选动态表示，不是等待训练才行动的必要条件。

### 7.2 AALpy 2.0：有明确输入/输出的可选历史学习任务

AALpy（An Active Automata Learning Library，主动自动机学习库，也提供被动算法）锁定 `aalpy==2.0.0`、tag `v.2.0.0`、提交 `da5612c31c0c40a62eb371e0997e3b26f71bdbe0`，MIT 许可、Python ≥3.10。实际被动学习入口是 **`from aalpy.learning_algs import run_RPNI`**，函数名中的 RPNI 必须大写；它指 Regular Positive and Negative Inference（正负样本规则推断）。不安装额外 PSR 库，也不把其他自动机算法失败后自动切换成另一套未验收模型。

上游调用明确为：

```python
from aalpy.learning_algs import run_RPNI

model = run_RPNI(
    data=prefix_closed_data,
    automaton_type="mealy",
    algorithm="gsm",
    input_completeness=None,
    print_info=False,
)
```

`gsm` 是上游 Generalized State Merging（广义状态合并）实现。`input_completeness=None` 保留缺失边；禁止用 `self_loop` 或 `sink_state` 为未观察动作补造已知输出。`model is None` 表示数据不满足确定性要求，返回冲突及证据给 Julia，不丢弃反例来强行得到一个自动机。依据：[固定版本入口源码](https://github.com/DES-Lab/AALpy/blob/da5612c31c0c40a62eb371e0997e3b26f71bdbe0/aalpy/learning_algs/deterministic_passive/RPNI.py)、[前缀数据处理源码](https://github.com/DES-Lab/AALpy/blob/da5612c31c0c40a62eb371e0997e3b26f71bdbe0/aalpy/learning_algs/deterministic_passive/rpni_helper_functions.py)、[发布包](https://pypi.org/project/aalpy/2.0.0/)。

**trace 编码由 Julia 定义：**输入符号 `a_t` 包含公开动作种类、参数/角色的已核验类别和必要上下文；没有参数等价证明时保留实际参数，不能因同属 ACTION6 就合并所有位置。输出 `y_t` 是该动作真实回执的规范关系变化、已检查不变部分及公开状态，不是当前模型的预测。符号映射带版本和可回读定义，不把事件唯一编号作为用于记忆答案的特征。多个返回帧共同形成这一次动作的输出，不能变成额外输入步骤。

每条可比较轨迹 `[(a1,y1),(a2,y2),...]` 向 Mealy 学习器提供 `((a1,),y1)`、`((a1,a2),y2)` 等**每个前缀和最后一步输出**；并非只给整条输入和一组未定义标签。每条来源轨迹/事件继续存于 Julia 的旁路证据索引。仅合并经公开证据支持为可比起点的轨迹；RESET 只表示生命周期重启，不能自动等于同一个内部状态。存在缺失输出的前缀不伪造标签，保留原证据和补充测试义务；当前学习任务使用具有完整前缀观测的可比部分。

| 实际调用链 | 要完成的项目代码与消费者 |
|---|---|
| `RelationTasks.relation_checks` / 策略反馈出现历史歧义 → Julia 拟增历史学习任务 → `ComputeBridge` | 由 `RelationPolicies.jl` / `GuardRepair.jl` 的修订入口组织有版本的 trace；为待区分历史分配义务，不新增动作执行器 |
| `python/compute/src/tddesc_compute/history_adapter.py`（拟增） → `run_RPNI(...)` | 验证前缀闭包及符号版本，调用真实上游 API，提取候选状态/转移及其原证据；缺失转移和冲突明确返回 |
| 候选模型/区分序列 → Julia 关系检验器 → `RelationTasks` / 08 仲裁 | 在原公共 trace 上独立重演候选；将能够区分历史的可达输入序列转为实验义务，附目标响应、起点约束和来源。仲裁器只派发下一合法公开动作 |
| 实际回执 → `observe_relations!` / `confirm_relation_policy!` → 05 修订事务 | 实验反馈更新状态条件；状态分裂同时使相关 PC 编码、guard、策略和任务失效并重绑，不自动信任自动机给出的新身份 |

```text
refine_history(obligation, snapshot):                  # Julia：拟增流程
    select comparable public prefixes and response predicates
    freeze symbol/role/context versions and evidence cutoff
    if passive data are prefix-complete and deterministic at this encoding:
        submit the explicit AALpy task to the pure compute worker
    else:
        keep conflicts/unknowns and propose observable discriminating conditions
    replay any returned candidate against original event-response relations
    derive distinguishing tests only as reachability-constrained obligations
    let the shared arbitrator choose the next legal public action
    after its receipt, refine state definitions and invalidate dependents
```

这里不创建可直接调用游戏的 System Under Learning（待学习系统，SUL），不接 live equivalence oracle（在线等价查询裁判），也不赋予 AALpy RESET 权限。被动自动机对提供数据一致，不等于对所有未来轨迹成立；自动机状态共享先进入候选定义，只有 Julia 的签收才使其成为正式 `state_relation`。若独立验收不通过，该历史任务保留未完成，不把已知历史区别删掉。

### 7.3 PSR / 谱学习保留研究对照，所需能力不能随选型删除

参考 [Connecting Weighted Automata, Tensor Networks and Recurrent Neural Networks Through Spectral Learning](https://arxiv.org/abs/2010.10029) 与 [Closing the Learning-Planning Loop with Predictive State Representations](https://arxiv.org/abs/0912.2385)。共同未来测试、响应矩阵、历史条件精化和状态反例必须由关系核心完成；谱分解只是其可能的压缩方法，当前不加入必须交付的第三套运行时。

对已确认共同测试覆盖、可估计的有限子矩阵，可以研究 Singular Value Decomposition（奇异值分解，SVD）及秩；无缺失精确有限关系可研究有理数秩。只在相同实际矩阵的已观察完整子块上，子块秩才提供全矩阵秩的下界；不由部分观测直接宣告系统最小维度。受控 PSR 的算子必须遵守动作干预测试和归一化更新语义，不能机械用普通序列自动机替代受控模型。负内部坐标不等于负概率；非法概率输出不靠截断/再归一化掩盖。

正式输出始终是可计算的 `state_relation` 和 `transition`，带从历史计算状态的定义、反向绑定和证据。动态模板或谱学习只有在另立明确任务、核实识别条件并通过同一独立裁判后才能替换其实现；当前谱模型、全局低秩或最小维度保证均列为未完成研究，不能借“统一表示”预支结论。

## 8. 因果覆盖与主动实验义务

`coverage_ledger(snapshot, action_domain, role_scope, model_scope)` 按 05 的事实/假设与未知语义组织义务。每条义务是声明域内的动作参数、可绑定角色、可比上下文、候选效果/不变部分、正反见证和辨别状态。不能统计“动作编号都按过”就宣布闭合；合法坐标域完整枚举或有证明的分区归并只说明候选覆盖，并不说明所有对应干预已实证。

具体要求：所有公开可用 ACTION1–7；ACTION6 完整参数域（实际合法坐标及映射），基于区域内条件和作用证据构建等价类，未辨别位置保留；ACTION7 的前后状态、历史条件及作用独立学习；RESET 仅按公开规则管理生命周期。所有动作的 no-change 观测也保存：无可见变化不等于无因果效应。初始不为每个像素伪造一个因果关系；用符号域记录待验证范围，按目标相关性、竞争预测和探索公平性选择实验。对未知作用、隐藏历史和远端响应安排可达性验证。

稳定性报告按动作/角色/上下文声明域列出独立事件数、正确预测、不一致、未知、未辨别类别、参数域范围、效应及不变部分的覆盖；概率置信度、因果方向识别与可控目标成功率独立。确定性规则的有限域数学证明不等于现实因果置信度。没有适当对照、重复或识别条件时如实标记不可识别。不得把一次游戏分数变化、所有游戏平均分或对某个游戏重复成功当作动作对象完整因果证据。

## 9. 本文件的具体功能闭环签收

M1 在现有 `RelationTasks` / `RelationPolicies` 闭环上完善对象、作用范围和版本合同；M2 接入唯一 CirKit 计算后端及持续语义学习，历史学习插件按明确任务启用。以下验收按能力独立，不能用“第三方库安装成功”或若干普通游戏成绩代替。

| 验收项 | 独立输入/裁判 | 必须签收的结果与实际消费者 |
|---|---|---|
| 完整公开作用链 | 同色接触、多色组合、远端影响、无变化、多个中间帧、参数位置不同响应的隔离 fixture；裁判独立保存公开回执 | 已确认事件→关系差分→作用候选→冻结预测→唯一派发→反例→修订→再次绑定。`OnlineSession` 决策、预测、回执和 `observe_relations!` 的事件链一致 |
| 关系闭包/因子 | 小型完整及部分关系的直接穷举裁判，包含未知、冲突及重叠因子 | 展开加残差恢复已知关系，不覆盖已知假，不将未知填零；变量定义能被 `JointMechanisms` 实际绑定和查询 |
| CirKit API 与数值 | 使用独立枚举概率表计算联合、边缘及条件值，禁止拿另一个 CirKit 查询作唯一 oracle | 核对类别/变量映射、`(B,O,K)`、log 空间、缺失 mask、零分子/零分母、数值下溢、多类别全部赋值、部分批次、全缺失、规范化和梯度训练；不支持的结构明确报错，不换后端 |
| 唯一事件及统计口径 | 同一回执重复送入、多帧、一个动作影响多个对象、重复工件响应 | 事件数不增长，训练/验证轨迹不泄漏；共同事件不被统计为多次独立因果实验，来源见证可回读 |
| 变量/结构修订 | 联合 XOR、稀少但控制相关的条件、域扩张、角色重绑、合并后出现反例 | 从原事件重算高阶数据，掩码和版本正确；发布新 PC 后相关 producer、缓存、任务与策略重绑，旧版本结果被拒绝 |
| 进程与持久恢复 | worker 中断/重复回复、错 request/快照/结构、工件被改、恢复后查询比对 | 纯计算进程不能发动作或修改权威知识；恢复的同版本概率一致，重复响应只提交一次，陈旧结果不污染当前快照 |
| 历史区别 | 当前帧及最近动作相同而较早历史改变结果；不同 reset 起点、缺失前缀、确定性冲突 | 关系核心保存区别；启用 AALpy 时检查前缀编码、缺失边和独立重演。区分序列进入仲裁并获得真实回执，不由插件自行执行 |
| 置信与控制责任 | 固定事前模型、独立轨迹组、选择性缺失、机制改变、局部效果成立但 GAME_OVER | 分开报告预测正确、因果可识别、作用稳定性和目标结果；任何一项未完成都不能由 `bound/replicated`、PC 精确推理或局部 `established` 代替 |

验收结果要回答“新变量/模型是否改变了有证据支持的任务选择，并在后续公开回执中得到检验”，不能只输出模型文件。性能按同一任务过程统计编码、编译、训练、查询、通信和重绑总成本；确实减少了重复计算后才认定复用收益，不通过删除合法候选或必要反例任务制造加速。

完整产物、执行命令和生产进程隔离见 09。**本次只修订实施规格并核对上游/当前源码；尚未新增上述 adapter、安装计算环境、运行新测试或复现概率/自动机实验。** 当前源码已有关系任务、策略和失败续学，但新增概率后端、统计置信、通用动态对象、全作用闭合覆盖及跨版本失效责任仍按本规格实施和验收。

## 10. 本节固定依据与代码定位

- 当前实现：[RelationTasks.jl](https://github.com/zdx3578/TddESCat/blob/0d53a1c683fbe0ba3c9d8e41ac66cb6fe23dce81/julia/TddESCat/src/RelationTasks.jl)、[RelationPolicies.jl](https://github.com/zdx3578/TddESCat/blob/0d53a1c683fbe0ba3c9d8e41ac66cb6fe23dce81/julia/TddESCat/src/RelationPolicies.jl)、[OnlineSession.jl](https://github.com/zdx3578/TddESCat/blob/0d53a1c683fbe0ba3c9d8e41ac66cb6fe23dce81/julia/TddESCat/src/OnlineSession.jl)。定位采用函数名和固定提交，避免把旧行号套在已推进的分支上。
- CirKit 源码 pin 为 `aa7c78c3da676638e9b26ba4b7754171922c0327`；发布 wheel SHA-256 为 `74329f2da8fb012b5667a02a3f2bffad95eafc7066747f4e9f7e80a75588c421`。版本、许可和 API 来源见 6.1；锁定安装包和完整依赖后仍需本项目验收，不由论文名或 README 推断兼容性。
- AALpy 源码 pin 为 `da5612c31c0c40a62eb371e0997e3b26f71bdbe0`；2.0.0 wheel SHA-256 为 `1300a55c430948ab0f2f1a31945cdc50d5bbbc1cef6dbd44b981ebe0f6416557`。只在 7.2 的 M2 历史任务中启用，来源见 7.2。
- 在线 PC、BMF/FCA、PSR 等研究用于启发候选算法及独立对照，不作为“已有可直接调用的完整实现”承诺。理论适用条件、数值近似和真实因果验证各自保留，不由统一 worker 混成一种真值语义。
