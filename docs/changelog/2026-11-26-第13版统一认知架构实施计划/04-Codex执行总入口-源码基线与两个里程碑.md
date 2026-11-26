# 04｜第13版统一认知架构：可实施技术规格总入口

日期：2026-11-26（台北时间，星期四）｜设计与源码定位完成，未实施代码、未运行游戏。本文及 05–09 是同一套实施规格，不是六个独立项目，也不是六个里程碑。01–03 保留为研究演变与理论依据；对于工程接口、执行顺序、验收，以 04–09 为准。若与现有正式协议冲突，先依据 05 中的迁移规则处理，禁止在生产中长期维护新旧两个求解路径。

## 一、基线已经查清：实际实施项目是 TddESCat

通过 GitHub connector 只读获取以下仓库，不使用 SSH，不读取本地工作树，也不读取游戏私有状态。

| 证据 | 固定引用 | 判断 |
|---|---|---|
| `zdx3578/arc3wm` 的 `main` | [`0325e51`](https://github.com/zdx3578/arc3wm/commit/0325e51f9d27f17ce124492d1f0a7fc1729663fa)，2026-09-08 | 不是本次新体系的当前代码基线 |
| `arc3wm` 的 `debug/v149-process-retention-game-analysis` | [`e96e1c5`](https://github.com/zdx3578/arc3wm/commit/e96e1c5980840fdffc8d5de38e5c7c58e23b5582)，2026-10-27 | 历史分支，不切换、不修改；远端不是用户本地最新工作树 |
| `arc3wm` 的 `docs/2026-11-19-causal-concept-closed-loop` | [`942b1ed`](https://github.com/zdx3578/arc3wm/commit/942b1ed05a179330e3dec9a290de34dc02a30745)，2026-11-23 | 已明示下一步代码进入独立项目 TddESCat；Julia 负责证据、范畴语义、控制，Rust E-Stitch 负责结构发现 |
| **`zdx3578/TddESCat` 的 `impl/2026-11-23-toolchain-bootstrap`** | **[`acf7da47`](https://github.com/zdx3578/TddESCat/commit/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e)**，2026-11-26 11:26 台北时间 | 本计划的只读源码审查锚点；当前远端包含 11-26 跨玩法泛化整改文件 |

本次从上述不可变 commit 读取了 Julia 关键实现、项目入口、实际配置和 Rust 学习桥接的 Julia 一侧，另读取 11-26 四份专项复核的主要结论、目录及代码定位。未独立复现其中作者报告，也未检查用户未提交代码。实际开发前重新确认实施分支头及本地未提交差异；不回滚或覆盖已有修复。若该分支已推进，逐项重查而不是按旧行号盲改。

必须阅读的项目文档（均在上述固定版本的仓库中）：
- `docs/changelog/2026-11-23-三语言框架与复杂移动实施计划/00-Codex执行入口与两个阶段交付.md`、`01-项目布局公共接口与证据事务.md`、`02-Julia范畴语义与机制算法.md`、`03-Rust-EStitch适配与资源闭环.md`、`04-复杂移动场景与测试实施.md`、`05-阶段二规划关系优化与验收.md`。
- `docs/changelog/2026-11-24-阶段二组合控制/04-统一关系定义与语义实现规格.md`、`05-多层联想与搜索调度实现规格.md`、`11-E-Stitch开放参数实验-Codex实施计划.md`、`15-联想与连续动作高级抽象实施计划.md`。
- `docs/changelog/2026-11-25-自主学习通关/13-最新闭环复核与共同策略实施计划.md` 及 14–16 的实现与复测。
- `docs/changelog/2026-11-26-跨玩法泛化与统一关系闭环/01-源码复核与两阶段整改计划.md`、02–04 专项复核。这一已有两阶段整改计划不是另起的第三、第四里程碑；本规格将其统一关系、任务仲裁、策略候选来源与第13版索引/压缩接合。

## 二、基于实际源码的改造裁决

下面位置以 `acf7da47` 为准。表中“当前逻辑”来自本轮直接读取的源码片段或完整函数，不能把方案中的拟增接口当作已实现。链接用于 Codex 跳转；所有现存文件位置相对于 `julia/TddESCat/src/`，除非另标。

| 具体问题 | 代码位置 | 当前逻辑 | 后果 | 对应实现 |
|---|---|---|---|---|
| 基础分割已经存在，但候选定义过窄 | [Grounding.jl:4–53](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/Grounding.jl#L4-L53) | `color_components` 计算全色4/8连通；`support_candidates` 默认96像素且只取单组件/相邻二元组合 | 已知大区、跨区、子区不能凭此进入充分候选 | 复用分割；区域全集加证据驱动任意阶组合/精化的可续枚举。96及相邻二元限制不作为新算法的语义边界（06、07） |
| 对应只支持特定变换，停止状态未充分细分 | [Grounding.jl:55–114](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/Grounding.jl#L55-L114) | `SupportCorrespondence` 固定 `delta`；`correspondence_candidates` 检查同色整数平移，有限工作/见证；`ground_event` 比较最后帧 | 完成标记只针对有限变换语言；多帧响应和未知变换缺少共同候选入口 | 以类型化对应关系、完整帧序列和剩余未解释变化代替唯一 `delta`；平移保留为已知通用算子而非唯一世界语义（06、07） |
| 关系计算已有真值/见证基础，不该另建数据库 | [RelationQueries.jl:1–95、153–238、269–279](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/RelationQueries.jl#L153-L238) | 有 `RelationScope/Table/Evaluation`、见证 DAG、哈希连接、投影、选择、并集、受限否定；缺行只有枚举完整且域完整时判假 | 适合直接扩展；现连接每次新建 buckets，未建立长期索引和共同代数执行计划 | 扩充原关系层；规范类型域、已知范围、证据依赖，编译查询计划，缓存版本化访问结构；保留正确的未知语义（05、06） |
| 关系复合的证据关联还可细化 | [RelationSemantics.jl:1–77](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/RelationSemantics.jl#L1-L77) | `FiniteRelation` 用元组→证据集合；复合将每条见证的 refs union，再保存中间值集合；已有安全前像门 | 扁平 union 不足以独立撤回某个 AND 证明、保留其他 OR 证明；全局 complete 太粗 | 复合改用既有 RelationQueries 的 AND/OR 见证与逐输入覆盖证书；保持同一类型接口，严格区分可能/保证前像（05、08） |
| 联想索引只覆盖窄端口 | [AssociationIndex.jl:7–13、45–68](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/AssociationIndex.jl#L45-L68) | `entries/ports/inverse_features`，端口 action+形状 hash；`recall_associations` 先同端口同形状再排序；直接索引 feature | 跨形状和跨作用关系的联想不充分；哈希命中不能证明偏序关系 | 升级同一索引所有者，按查询声明六维索引，形状提示仅排序；未出现特征返回空 posting，反例更新依赖（06） |
| 作用证据断在局部解释族 | [LocalEffects.jl:1–24、304–345](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/LocalEffects.jl#L304-L345) | `PublicEffects` 已有 residual、alternatives、public_delta；空 effects 或共同场景变换歧义直接不入相关语料 | 未解释变化难触发新可验证关系；易使结构发现只消费已熟悉效果 | 保留完整公共事件和 residual；用缺失关系/候选与证据域构造待区分义务，已验证关系才入正式程序语料（07、08） |
| 点击效果迁移与对象作用关系不完整 | [JointMechanisms.jl:22–39、158–165、260–277](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/JointMechanisms.jl#L260-L277) | `ClickBinding.local_pigment` 决定新位置许可；非局部改色需锚定位置，作用角色常绑定不足返回 unknown | 通用点击位置变换、远端作用、多对象难以统一控制 | 点击角色与受影响角色分别建关系；同一语义契约联合绑定、保持目标/条件及效果；新位置经验证才提升作用域（07） |
| 首关学习启动与作用学习有窄入口 | [InterventionLearning.jl:59–87、138–163](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/InterventionLearning.jl#L59-L87) | 晋级规则依赖跨两关正例；同类作用联想主要用外观/类别/历史记录 | 未破首关时无法产生这种晋级解释；类别相同不等于效果相同 | 单步作用任务、同关中间目标、跨关晋级分开建模，统一完整效果关系；先以真实可控制变化启动（07、08） |
| ACTION6 坐标候选截断及仲裁覆盖 | [OnlineSession.jl:240–263、703–707、848–887](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/OnlineSession.jl#L848-L887) | 每组代表坐标，take(max_action_coordinates)；点击探索可覆盖 spatial_choice/policy_note；无点击才走另一实验分支 | 点击内部可能未辨别，探索中断有效任务，多个决策入口冲突 | 完整坐标合法域的符号分区/遍历与保留待实验义务；统一 Task/ActionCandidate 仲裁一次决策，不再事后覆盖（08） |
| 已有程序消费，但策略语料预构造骨架 | [PolicySemantics.jl:38–108](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/PolicySemantics.jl#L38-L108) | `remaining_sites` 模型条件；统一 Repeat(Branch(...),Stop)，`analyze_policy_body` 仅接受相应树形 | E-Stitch 的实际抽象仍受一种任务本体限制 | 从真实关系任务轨迹构造 typed Step/Seq/Choice/Repeat 等候选，解释器支持不同合法正文；不预造通关模板（08） |
| 程序与反向目标查询未真正统一 | [ProgramSemantics.jl:1–27](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/ProgramSemantics.jl#L17-L27)；[GoalRegression.jl:18–42、107–129](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/GoalRegression.jl#L18-L42) | `program_relation_contract` 汇总首步条件和末步结果；goal_producer_needs 遍历 active 原子机制及动作 | 程序不能普遍被效果索引检索，组合中间前提难从终点反推 | 同一作用契约用于原子机制与程序；完整关系组合及递归回归，共同生产者索引（08） |
| 修订成本与知识一致发布 | [OnlineSession.jl:19–32、185–199](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/OnlineSession.jl#L185-L199) | `OnlineKnowledge` 已维护 rules/active/trials/programs/policies/observations/projections；追加 trial 后遍历 rules 更新同动作条件 | 不能只按动作判断全部依赖；对象/条件版本变化后索引、统计、程序及缓存需一致 | 扩展同一知识所有者为快照发布和依赖事务，增量重算且有完整重算裁判（05） |
| 生产入口与学习协议已经存在 | [scripts/run.jl:7–59](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/scripts/run.jl#L7-L59)、[StitchBridge.jl:1–46、204–226](https://github.com/zdx3578/TddESCat/blob/acf7da47e02c65af50bdb8b28f0e3d9d93e4a89e/julia/TddESCat/src/StitchBridge.jl#L1-L46) | `capture→run_online!`；已有 manifest、证据快照、库基版、协议版本、来源与引擎 pin、round 验证 | 若新实现另做独立启动/学习器会丢掉已经有的闭环 | 保留正式入口与 E-Stitch worker；扩展现有 manifest 的关系/任务/版本契约，实际调用与复用验收（05、08、09） |

原有局部作用、关系查询、任务、策略、程序消费已经存在。不能宣称当前系统只有日志、完全没有结构发现或没有策略消费。11-26 的项目复核称原版 ls20 真实任务和策略有消费，但这只是该证据范围的结果；本轮未重新跑其归档、其余24款原始轨迹或游戏。不将正常分数波动作为改革的主要因果归因。

## 三、统一职责与语言裁决

沿用真实项目的三语言方案，不另造三个世界模型。

- **Julia**：唯一正式知识语义、公共证据关联、区域和关系、索引、语义抽象、条件效果、版本、预测与真实行动仲裁。以现有 `OnlineKnowledge`、`RelationEvaluation`、`Recorder`、`LibrarySnapshot` 等为所有者边界。优先扩展现有模块；拟增加的内部文件只是责任分隔，不再建影子库。
- **Rust**：E-Stitch 真实结构搜索，保持当前 `rust/bridge` 和既有 worker。精确代数树决策图的计算内核采用 Factor Rank 补充实现的审计后接口（06），只提供纯函数计算/认证结果；不拥有对象或环境语义、不发动作、不独立学习游戏。若新内核存在许可证/兼容性/构造问题，记录阻塞，不用伪实现替代正式实验。
- **Python**：已存在的隔离合成环境、独立裁判、实验编排及汇总。禁止真值进入 Julia learner，禁止用 Python 游戏私有字段补全公共证据。沿用 `python/src/tddesc_tools/` 及 `scripts/` 的 runner，不另做求解器。
- 不引入大语言模型（Large Language Model）依赖；Catlab 继续承担已实现的范畴关系构造与检查。形式证明只声明给定模型内的性质；独立真实证据验证另行执行。

统一语义用 `Typed Relations and Functions`（类型化关系与函数）；计算使用布尔/计数/精确有理数/非负概率等显式代数类型，不能随意替换。数学表示、知识身份、程序库、索引、计算结果之间仅用带版本的可验证引用；调用链不直接跨越事实权威。真正的计算底座仍是横向服务，不把所有区域强行转换成大型 ATDD 或概率电路。不同执行计划必须实现同一明确语义，不是旧版求解回退。

## 四、两里程碑实施依赖（必须按依赖推进，不按文件数量计进度）

### 里程碑一：精确语义、区域、多维索引及统一作用任务的生产闭环

1. **M1.1 基线与协议**：固定当前真实分支/提交/配置、回放轨迹、现有性能；运行已有测试；落实 05 的证据、版本、类型、完整性接口。不能用新 schema 静默读取旧含义。
2. **M1.2 区域与关系核心**：落实 06 的完整四连通分区、帧序列差分、统一关系运算、证据因子和索引；在正式生产调用上替换重复计算；实现完整定义函数的精确 ATDD 对照和底层持续共享。候选未知仍显式保留。
3. **M1.3 统一作用和任务入口**：落实 07 的事件作用关系、对象角色、分解/组合义务、同关任务及失败知识保留；不把首关晋级/接触家族当作学习入口。落实 08 的单仲裁及完整动作域（包括 ACTION6 参数/历史、ACTION7、RESET），要求决定性反例真的改变下一公开动作。
4. **M1.4 独立裁判与端到端复核**：按09执行精确语义、索引和压缩2×2对照、版本失效、恢复、真实单步反馈，记录真实热点。只在达到 M1 门禁后提交里程碑；不能等待第二阶段才让生产消费者使用计算核心。

### 里程碑二：持续学习、跨层压缩、抽象程序及真实控制

1. **M2.1 变量/因子/动态状态学习**：07 的 BMF、PC、预测状态、反例差异与高阶组合；从完整区域证据提出可绑定的新变量；控制相关性必须实证。底层统计与精确事实分离。
2. **M2.2 语义与程序抽象**：08 的概念闭包、反统一、谓词发明、E-Stitch 多种真实任务轨迹语料与旧库续学；六维偏序查询找到共同结构；程序条件等价、版本、跨实例验证；禁止固定策略模板。
3. **M2.3 双向控制与搜索压缩**：目标/子目标、作用/程序统一效果索引、递归前像、分支与循环解释器、合法实验生成、失败约束和可恢复搜索；七类压缩均有持续触发与撤销路径。
4. **M2.4 公开真实验收**：完成 09 合成裁判、前缀回放、独立消融、public25 原版公开过程比较。观察新结构/知识实际改变预测、候选空间与控制；动作—对象最小因果单元闭合按声明域逐项验收。H1/H2/H3 分开裁决，不把单次通过或分数波动代替因果和计算责任。

每个子任务有可运行测试、明确调用者、日志和变更说明；子任务不是新增里程碑。实施期间至少每20分钟提交并推送一次明确的工作分支（能安全提交时及时提交，不把未通过状态标为通过）；不要自动切换历史监控分支。配置写 TOML 等文件，不用环境变量；所有中文实施记录在当日 `docs/changelog/日期-主题/` 下。不得人为降低现行学习参数或设置新算法限额制造速度；正式比赛或真实资源限制需要如实报告，保存续算状态。没有目标分支写入授权/当前本地差异不能核对时，先用本文档压缩包交付，不直接覆盖活跃实现分支。

## 五、阅读与交付矩阵

| 文件 | 内容 | 落实责任 |
|---|---|---|
| 05-统一语义接口与证据版本事务.md | 逐项接口、共享身份、证据、未知、事务、恢复及跨语言协议 | 两阶段通用；M1 先完成 |
| 06-区域关系代数索引与精确压缩实现.md | 全域区域、跨帧变化、类型化运算、六维索引、Factor Rank、关系共享、增量 | M1.2，M2 继续使用 |
| 07-动态Grounding与因果变量结构学习实现.md | 作用事件、角色、分裂合并、六类发现触发、BMF/PC/动态模型、完整因果单元 | M1.3 + M2.1 |
| 08-抽象程序目标回归与统一控制实现.md | 多维偏序/条件等价、反统一/谓词/真实 E-Stitch、七层压缩、任务与单仲裁 | M1.3 + M2.2/M2.3 |
| 09-实施配置独立测试与生产闭环验收.md | 实施文件落点、配置迁移、测试矩阵、实验命令原则、观测指标、交付门 | 两阶段最终签收依据 |

05–09 的新类型/函数名是具体实现契约的提案，不声称存在于当前源码；既有函数名称和行号来源见本节源码表。以当前已存在结构实现同等契约时，优先就地修改，不强制新建一批同名模块。完成时提交实际采用的文件/函数路径与规格逐项映射。
