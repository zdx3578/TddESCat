# 07｜动态 Grounding、作用关系、变量发明与持续结构学习

本规格对应 04 的 M1.3、M2.1。沿用 05 的快照/证据/类型合同、06 的区域和联合索引。M1 先打通精确公共变化→作用候选→任务→反馈的生产链；M2 再使统计和抽象发现不断扩大模型语言。不能等概率电路或程序合成全部完成才发出第一动作。

## 1. 现有模块的接入裁决

| 源码落点 | 保留内容 | 修改内容及消费者 |
|---|---|---|
| `Grounding.jl` `ground_event`、`support_candidates`、`correspondence_candidates` | 基础分区、平移验证、原证据 | 统一所有帧及区域；增加可续分解/组合、类型化对应与剩余变化；供 LocalEffects/绑定使用 |
| `LocalEffects.jl:1–24,304–345` | `PublicEffects`、已知效果、残差和 alternatives | 将原 effect family 转为共享关系表达；所有真实变化及歧义进入待解释义务；不只把已熟悉的作用编入学习样本 |
| `JointMechanisms.jl:158–165,260–277` | 已有联合效果、点击绑定及未知门禁 | 用统一角色绑定与上下文关系表达点击、受影响角色和非局部联动；验证域扩张，不以局部改色类别为跨位置许可 |
| `InterventionLearning.jl:59–87,138–163` | 已有公共干预经验和晋级证据 | 分开局部作用、同关任务、跨关晋级；从第一关即可学习局部作用；机制联想需要完整效果，不只是同类别 |
| `AssociationIndex.jl`、`AssociationScheduler.jl` | 现有证据联想和调度入口 | 06 的六维联合召回及反例义务；按实际查询语义生成候选，不能限定同形同动作才能召回 |
| `SceneMemory.jl`、`ProjectionRevision.jl`、`GuardRepair.jl`、`Revision.jl` | 现有状态记忆与修订入口 | 共同版本和依赖事务，动态状态和因果条件精化；将未知重新派为辨别性实验 |
| `OnlineSession.jl` 的 `OnlineKnowledge`、`archive_trial!`、`candidate_evaluation` | 权威在线知识、真实 trial、候选预测 | 更新同一知识快照；按依赖而不是仅按动作重新验证；消费以下统一作用契约 |

这些是对 04 已定位源码的改进，不新增独立 PC 游戏智能体。以下拟定接口均可用现有结构扩充实现。

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
    retrieve candidates from structural and temporal indices + live search frontier
    align candidate roles jointly with typed variable joins
    evaluate proposed effects against ALL relevant event frames / public fields
    record supported/refuted/unknown interpretations separately
    residual = observed facts not accounted for by a consistent interpretation
    for obligation in residual or conflicting role/guard:
        propose refinements, combinations, state distinctions; preserve frontier
    update all affected task producers and conditional models transactionally
    commit snapshot; recompute actual action candidates using that snapshot
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

## 5. Boolean Matrix Factorization（布尔矩阵因子分解，BMF）与语义候选（M2）

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

## 6. Probabilistic Circuits（概率电路，PC）在线学习（M2）

### 6.1 学习数据及结构：必须是有可绑定含义的变量

基于已知区域和当前候选的关系特征学习，而非从4096个像素重新拟合几何；必要时由残差向下精化支持。一次独立确认的作用事件贡献一个训练事件；重复读同一回执、多帧、同一推导的重复见证不能增加样本次数。不同对象实例同一动作可形成联合记录而非假设独立样本。将动作、角色绑定、可观测上下文、历史特征、联合效果类别、公开进度/终止事件作为类型化有限随机变量；不同游戏的语义映射未验证时不可混合统计。变量版本变更触发重算。

目标是结构化可分解的非负、归一化 PC。先实现小型可审计在线电路于 Julia 关系学习入口，使用离散指示叶、分类概率叶、Sum（加权求和）和 Product（乘积）。不直接引入需要大量离线图像训练的网络。固定版本的 ProbabilisticCircuits.jl 作为库接口与批量推理对照候选（[文档](https://tractables.github.io/ProbabilisticCircuits.jl/stable/)，需核对版本/API）；不能假设它已支持本项目的新增变量/证据事务。基础学习器实现以下明确的 split/merge 及统计更新，不能把调用第三方 fit 作为全部算法。

首个可执行结构是上下文的有类型决策分解：每个 sum 的子分支按某变量的互斥取值选择；branch 由其指示因子与余下变量的分布相乘；其余已固定输入的边缘/效果可用分类叶。对联合效果用联合类别或继续结构化分解，不能把多个效果无证据地相乘假定独立。相同子函数允许共享，叶参数保持有效概率。每个 sum 的子范围一致，每个 product 的子变量范围互不重叠，分支支持集互斥；归一化权重从已确认统计计算。连续新属性须明确域扩张与未知处理。对缺失特征，边缘化其域；分母为0/未知时不生成确定条件概率。

### 6.2 在线结构更新的具体算法

参考 [Online Structure Learning of Probabilistic Circuits](https://tractable-probabilistic-modeling.github.io/tpm2026/papers/)，但原论文二阶流不足以恢复新分裂的全部高阶历史统计；本项目必须以真实事件索引重算受影响上下文。记录每条边的事件集合（或等价无损因子）、边流计数 a_e，变量边缘和成对统计 m_e/J_e 用于候选优先级；不把共享边的重复路径当多个独立观察。对缺失输入不虚构完全观测，概率推断可用边缘似然；确定性因果证据计数只用实际见证。若存在潜变量，期望计数只用于概率参数，不当真实样本。

```text
observe_pc(event, feature_version):
    add uniquely identified evidence to relevant context
    evaluate current PC, record joint residual and prediction loss
    update observed counts and dependencies; enqueue affected leaves
    proposals = all legal typed context distinctions / discovered predicates
    prioritize by information gain, residual separation, shared factor opportunities
    include joint features when single features do not distinguish (e.g. XOR)
    for candidate split or merge from persistent agenda:
        retrieve matching events using indices at fixed cutoff
        compute exact relevant joint counts from ORIGINAL event features
        construct normalized children or shared subcircuits
        check smoothness/decomposability/determinism as required
        evaluate held-out/prequential predictive loss, complexity and control distinctions
        if model valid and justified: publish candidate PC version through 05
        else record rejection with scope; retain evidence and unknown conditions
```

分裂条件使用真实可计算关系，允许两变量及高阶组合；互信息只排序不能做完备排除（XOR 的一阶互信息可为0）。对有限类别及明确可比样本，叶预测可使用 Dirichlet（狄利克雷）平滑，后验均值 (n_k+α_k)/(N+Σα)；先验参数须配置并记录，只用于概率预测，不能将伪计数当因果证据。统计强度和经验预测准确率分别报告；非独立轨迹应按事件/会话分组评估而不是把像素数量当样本量。需要结构确定的经验关系不能被概率平滑篡改。

采用 prequential（先预测后学习）损失比较：在事件尚未读入时的冻结 PC 上计算负对数概率和校准，收到结果后更新；训练拟合不算泛化。合并可因相同函数的精确证明发生，或作为近似统计共享提案，经完整历史及留出检验、控制区分检查后采用；不删除原分支语义和历史。对于低频但影响控制的差异禁止仅因统计相似而合并。反例出现后按依赖恢复必要条件，并重新计算完整历史流。共享结构造成复制成本时测总收益；没有收益不声称已压缩。

PC 计算后端提供 `condition/marginal/predict_distribution/structure_update`，输出带版本、证据截止、归一化及适用范围；不得直接调用公共动作。`P(E|A,C)` 的数值不自动等于 `P(E|do(A),C)`；后者需要真实干预和充分的识别条件。统计模型用于排序候选/概率预测和区分实验，已验证的精确约束仍由确定语义承担。对缺少数据的新游戏，先执行现有证据驱动的统一学习与实验，不训练大型模型或用旧求解器 fallback。

## 7. 预测状态与时间结构：从响应历史中发现变量（M2）

Predictive State Representation（预测状态表示，PSR）的目标是用未来测试响应区分状态。不是把所有历史完整复制到状态键，也不是把相同当前画面永远合并。

### 7.1 先实现证据驱动的历史条件与响应矩阵

历史 h 表示公开事件前缀及当前绑定；测试 τ 表示合法后续动作序列及相应可观察结果谓词。矩阵 H(h,τ) 只填实际执行、可比条件下取得的测试结果或其统计估计；未执行项保持 missing。动作序列无法到达、未执行、观察不到应独立标注。RESET 后状态只有经公开帧及响应验证才能当作等价起点。没有任意游戏内部状态设置接口。

具体实现：按当前可观测关系与作用契约检索可比历史；当同一动作的确定预测出现相反观测时，从历史谓词、顺序、重复次数、公开量及上下文变化产生区分候选；对每个候选检验能否使旧反例可解释且保留旧正例，按证据复杂度和实际区分效果组织工作队列。历史长度按待解释差异逐步扩充，不把现有固定 `[0,1,2,4]` 当穷尽域。若同一完整公开历史仍有不同结果，保留随机性或未识别隐藏变量，不能强迫确定分类。

`predictive_signature(history, observed_tests, snapshot)` 生成带测试集合、实际结果、未知范围和证据的响应关系；已观察测试相同只提出暂时可共享状态；新测试打破等价时分裂状态定义，重开原控制任务。学习初期可用精确状态关系做控制，谱学习只是明确的候选动态表示，不是等待训练才行动的必要条件。

### 7.2 谱学习的可执行对照（不强行移植无控制模型）

参考 [Connecting Weighted Automata, Tensor Networks and Recurrent Neural Networks Through Spectral Learning](https://arxiv.org/abs/2010.10029) 与 [Closing the Learning-Planning Loop with Predictive State Representations](https://arxiv.org/abs/0912.2385)。对已确认共同测试覆盖、可估计的有限子矩阵，计算奇异值和矩阵秩；无缺失精确有限关系可用有理数秩。部分矩阵的观测子块秩只提供下界，不自动确定真实系统维度。

候选实现：选择有共同已执行测试的前缀/后缀集，形成 H 及按符号扩展的 H_a（动作-观察对或明确控制的测试符号，不能把策略选择概率混入干预概率）。在已满足对应谱学习条件的子域中取 H=UΣVᵀ，令 P=U√Σ，Q=√ΣVᵀ，则 A_a=P⁺H_a Q⁺；起止读出向量由实际空前缀/后缀确定。在受控预测状态中必须按原 PSR 的动作干预测试和归一化更新语义构造算子，不能机械把普通序列自动机当受控模型。SVD（奇异值分解）的秩选择需记录数值精度、样本覆盖和独立预测验证；不能按任意固定秩删去控制状态。学习到负数坐标并不必然错误，但若输出概率非法、不归一化或预测对照失败，则候选不准进入概率控制；不靠截断/归一化掩盖模型错误。利用动态求和乘积模板作为替代研究对照时也用同样证据和测试域。一个版本只执行经确认的正式动态语义；候选模型并行检验不是兼容路径。

生产输出仍是统一 `state_relation` 和 `transition`，含从历史计算状态的定义与反向绑定见证。仅在谱学习的覆盖与可识别条件满足时签收其算法结论；数据不够标记未完成，不能给全局低秩保证。是否比精确历史条件更高效，以相同真实任务过程的净收益评价。

## 8. 因果覆盖与主动实验义务

`coverage_ledger(snapshot, action_domain, role_scope, model_scope)` 按 05 的事实/假设与未知语义组织义务。每条义务是声明域内的动作参数、可绑定角色、可比上下文、候选效果/不变部分、正反见证和辨别状态。不能统计“动作编号都按过”就宣布闭合；合法坐标域完整枚举或有证明的分区归并只说明候选覆盖，并不说明所有对应干预已实证。

具体要求：所有公开可用 ACTION1–7；ACTION6 完整参数域（实际合法坐标及映射），基于区域内条件和作用证据构建等价类，未辨别位置保留；ACTION7 的前后状态、历史条件及作用独立学习；RESET 仅按公开规则管理生命周期。所有动作的 no-change 观测也保存：无可见变化不等于无因果效应。初始不为每个像素伪造一个因果关系；用符号域记录待验证范围，按目标相关性、竞争预测和探索公平性选择实验。对未知作用、隐藏历史和远端响应安排可达性验证。

稳定性报告按动作/角色/上下文声明域列出独立事件数、正确预测、不一致、未知、未辨别类别、参数域范围、效应及不变部分的覆盖；概率置信度、因果方向识别与可控目标成功率独立。确定性规则的有限域数学证明不等于现实因果置信度。没有适当对照、重复或识别条件时如实标记不可识别。不得把一次游戏分数变化、所有游戏平均分或对某个游戏重复成功当作动作对象完整因果证据。

## 9. 本文件的具体功能闭环签收

- M1：已确认事件全量→区域/差分→统一 EffectEvidence→作用契约候选→共同任务入口→事前冻结预测→下一公开动作→反例→依赖事务→再次绑定。验证同色接触拆分、多色组合、远端影响、无变化、多个中间帧、点击位置不同响应；不能只输出解释日志。
- M2：六种触发分别产生可计算新变量；BMF/PC/历史响应精化真正进入同一知识快照和正式控制；验证联合 XOR、稀少控制条件、歧义/隐藏历史、机制变化、PC 分裂后的精确历史统计、合并再分裂。谱学习/动态模板对照明确条件及未完成范围。
- 所有拟新增算法接口需对应实际调用处与独立裁判；完整测试矩阵、产物和性能测量见 09。当前文档只给实施规格，未运行上述算法、未复现实验，也不宣称完整因果覆盖已经实现。
