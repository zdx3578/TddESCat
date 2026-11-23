# Rust E-Stitch 核心改造与 Julia 桥：可逐项实施规格

日期：2026-11-23，台北时间，星期一。本文是 TddESCat 新仓库的实施规格，所有新增文件、函数及验收均为待实现项，不表示已有代码或已通过测试。

## 1. 固定边界与依赖身份

新仓库 `zdx3578/TddESCat` 的 `main@fe138e9b556034407dcd42f07552ed3300416128` 当前仅有 `.gitignore`。实际发现器沿用 `mlb2251/egg-stitch@e4cd59047b9e1c7d04bc035a3c1cadd66a1b7c92`，修改其现有 Expand、Reuse、搜索、成本及多轮库学习，不另建 Julia 搜索器。

- 唯一可维护的上游源码放在 `third_party/egg-stitch/`。不得另放第二份可修改的 `egg-stitch`，不得使用 `_vendor/`。上游参照实验也从这个目录编译，通过显式实验配置记录改动和模式，不静默改用另一实现。
- 保留原 `LICENSE`、版权和来源。上游 `Cargo.toml` 明示 `GPL-3.0-or-later`；链接该核心的 Rust bridge 不得擅自声称可以按任意宽松许可证发布。第三方清单记录原许可证、上游 SHA、本地修改列表；项目整体许可证按真实组合确定。
- 上游 `Cargo.lock` 的 `egg` 来自 `mlb2251/egg@196d7d4ba09fcbc28f9a35d206f54d45e24f8410`。这一依赖不能无说明替成 crates.io 同号版本。
- 根 `Cargo.toml` 建立 workspace，成员为 `third_party/egg-stitch` 和 `rust/bridge`。唯一生效的锁文件是根 `Cargo.lock`；迁入时保留上游锁文件的原始 SHA／来源记录，再把锁定依赖迁入 workspace 锁。在 workspace 根声明唯一 `[patch.crates-io]`，把 egg 指向 `third_party/egg/` 的本地 path；该目录由 connector 取得固定提交，不能照搬上游 git+https patch 让 Cargo 绕过 connector 访问 GitHub。`check_sources.py` 拒绝未处理的 GitHub git 依赖。成员内 patch 不生效，不保留第二份。
- `rust-toolchain.toml` 候选锁定 `1.90.0`，`edition = "2024"`。1.85.1 不够：`op_db.rs` 与 `lib.rs` 使用 let chains，该语法在 Rust 1.88.0 才稳定。1.90.0 已发布，但仍须完成 `cargo +1.90.0 check --locked --workspace` 及测试后才记录“已验证”。不得用滚动 `stable` 代替可复现锁。
- 首版正式语义片段为 `op-children-db` 的有限、一阶、无内部 binder 的纯结构表达。定义导出的外层 `lam` 是序列化表示；不是允许输入任意高阶 lambda。输入内部 binder、负 `$n`、未知算子、隐式自由捕获一律明确拒绝。
- 首个正式生产搜索配置固定为已有 best-first 搜索；它允许有界、未穷尽搜索并返回已经精确验证的候选。SMC 不作为出错后的替代路径。后续启用 SMC 前，须完成同一类型、预算及停止协议的适配，并保留其粒子重数与提议概率语义。

官方工具链依据：[Rust 1.88.0](https://blog.rust-lang.org/2025/06/26/Rust-1.88.0/)、[Rust 1.90.0](https://blog.rust-lang.org/2025/09/18/Rust-1.90.0/)。版本锁是构建候选，不是本轮已经编译成功的声明。

## 2. 拟新增文件与唯一职责

下列路径相对 TddESCat 仓库根。运行输入、输出写入配置指定的作业目录，不提交大批运行数据；中文计划、变更和验证报告统一放在 `docs/changelog/2026-11-23-三语言框架与复杂移动实施计划/`。

| 文件 | 必须实现的函数／职责 | 不得承担的职责 |
| --- | --- | --- |
| `third_party/egg-stitch/UPSTREAM.toml` | 记录仓库、完整 SHA、原锁文件哈希、本地补丁说明路径 | 不存第二份代码 |
| `third_party/egg-stitch/src/typed.rs` | `SignatureRegistry`、`check_term`、`check_expand`、`check_reuse`、`checked_add`、`checked_union_instantiation` | 不推断环境机制真假 |
| `third_party/egg-stitch/src/budget.rs` | `Budget::reserve`、`tick`、`Reservation`、`StopReason`；所有大构造共用同一预算 | 不把逻辑行数冒充 RSS |
| `third_party/egg-stitch/src/initial_library.rs` | `validate_dag`、`compile_unfold_rules`、`register_definitions`、`library_cost` | 不把旧定义混作训练样本 |
| `third_party/egg-stitch/src/relation/mod.rs` | 精确关系运算接口、计数和成本返回合同 | 不决定哪些模式值得搜索 |
| `third_party/egg-stitch/src/relation/factors.rs` | 共享行块、重编号视图、有限连接、投影、精确消费 | 不宣称最细分解 |
| `third_party/egg-stitch/src/proof_export.rs` | 从合法规则解释和选中调用导出有限证明、来源映射 | 不导出所有匹配行 |
| `rust/bridge/src/main.rs` | `--manifest <path>` 单入口；严格解析并调用现有核心 | 不接游戏 API，不含游戏凭证 |
| `rust/bridge/src/protocol.rs` | 编译期协议版本、严格请求／结果类型、哈希核对 | 不做宽松字段猜测 |
| `rust/bridge/src/job.rs` | `run_job`、`run_round`、`prepare_next_round`；管理一次冻结作业 | 不成为全局可变概念库 |
| `rust/bridge/src/checkpoint.rs` | `commit_round`、`read_committed_rounds`；完整轮次原子落盘 | 不把半轮次标为完成 |
| `rust/bridge/src/metrics.rs` | 逐阶段增量耗时、累计耗时、预算与规模记录 | 不把累计时间相加 |
| `julia/TddESCat/src/StitchProtocol.jl` | 读写协议、检查版本、解析严格整数 | 不调用 Julia `eval` 解析表达 |
| `julia/TddESCat/src/StitchCodec.jl` | `encode_batch`、`decode_program`、`decode_pattern`、`decode_closed_lambda`、`check_codec_roundtrip` | 不自行发现库模式 |
| `julia/TddESCat/src/StitchBridge.jl` | `freeze_job`、`launch_worker`、`collect_rounds`、`verify_proposal` | 不在 Rust 执行每个像素操作 |
| `julia/TddESCat/src/Library.jl` | 唯一可变定义库、稳定 ID、依赖闭合与版本发布 | 不接受无正文的函数名字 |
| `julia/TddESCat/src/Provenance.jl` | 原始 occurrence 索引、调用来源重建、支持集／残差核对 | 不把相同 e-class 当同一事件 |
| `protocol/v1/learn_job.schema.json` | 作业清单与文件描述 schema | 不容纳任意未知字段 |
| `protocol/v1/learn_result.schema.json` | 完整轮次、停止状态、定义与证明 schema | 不省略完整性字段 |
| `protocol/v1/typed_terms.schema.json` | 签名、参数化定义、自由槽与规则表示 | 不嵌入可执行脚本 |
| `config/stitch.toml` | 搜索、成本、资源、worker 路径、输入片段选择 | 不通过环境变量覆盖配置 |
| `scripts/check_toolchain.py` | 固定版本与锁文件检查、依赖编译冒烟 | 不默默升级工具链 |
| `scripts/run_stitch_fixture.py` | 独立小样本执行、检查退出码与 checkpoint | 不承担实际游戏控制 |
| `tests/fixtures/stitch/` | 正确、错误和资源中止的最小输入／期望输出 | 不放预写关卡 solver |

`Library.jl`、`Provenance.jl` 与其他语义模块由总计划统一所有权；此处只约定 Rust 桥所需方法，不再创建同义的第二份库或证据存储。

## 3. 协议：每个字段具体表示什么

### 3.1 作业清单 `manifest.json`

清单只引用作业输入目录内的相对路径。拒绝 `..`、绝对输入路径、指向目录外的符号链接以及内容哈希不符；正常的可执行文件绝对路径来自经过验证的宿主配置，不从表达数据读取。

| 字段 | 类型 | 含义与检查 |
| --- | --- | --- |
| `protocol_version` | 固定字符串 `tddescat.learn.v1` | Julia 与 Rust 编译期常量必须完全相等；不自动兼容 |
| `codec_version` | 固定字符串 `typed-free-slots.v1` | 本次表达编码与参数编号合同 |
| `job_id` | 字符串 | 一次不可变作业的标识，不进入可学习表达 |
| `evidence_snapshot_id` | 字符串 | Julia 冻结的证据版本；只回显，不被 Rust 修改 |
| `library_base_version` | 字符串 | 本轮基于的完整已发布库版本 |
| `signature_file` | 文件描述 | 算子与类型表；描述内只有 `path`、`sha256`、`bytes` 三项 |
| `programs_file` | 文件描述 | JSON 字符串数组，顺序有意义；一条输入对应一个 program index |
| `origins_file` | 文件描述 | occurrence 的旁路来源引用，不把事件编号放入学习项 |
| `initial_library_file` | 文件描述 | 无环、冻结的旧库；首次允许空数组 |
| `rules_file` | 文件描述 | 经过语义审查的命名等式；可为空数组，不允许任意脚本条件 |
| `config_file` | 文件描述 | 解析后的完整 TOML 配置快照，包含所有实际默认值 |
| `program_count` | 非负整数 | 必须等于字符串数组长度和根来源数量；不去重丢失频率 |
| `slot_context` | 按索引排序的槽声明数组 | 每个 `$n` 的类型、时间角色及共享约束；同批次含义相容 |
| `engine_pin` | 结构化版本记录 | 原上游 SHA、本地源码提交／树哈希、根 Cargo.lock 哈希、Rust 版本、协议编译版本 |

文件描述的 `bytes` 是实际文件字节数，先核限制再分配；`sha256` 只核身份，不能代替类型、语义和证明检查。Rust 不需要原始游戏帧和访问凭证，只拿冻结表达及有限来源引用；详细像素证据留在 Julia 证据系统。

### 3.2 签名与槽声明

首版使用单态化签名；不在这个任务中实现任意多态类型推断。一个算子在一个签名版本内只有一组固定端口类型；需要不同类型实例时由 codec 分别生成明确算子名，并保存其数学解释。

| 记录与字段 | 含义 |
| --- | --- |
| `Sort.id` | 稳定类型名，例如 `Coord`、`Delta`、`RoleBefore`、`RoleAfter`、`Relation`、`ProgramAst`；名字不是“玩家／墙”标签 |
| `Operator.symbol` | 白名单中的符号名；不允许借保留名 `programs`、`lam`、`fn_`、`lib_` 绕过检查 |
| `Operator.inputs` | 按端口顺序列出的类型；必须与子节点数完全一致 |
| `Operator.output` | 结果类型；e-class 中所有代表必须一致 |
| `Operator.purity` | 首版只能是 `pure`；`ProgramAst` 描述动作程序也只是数据，解释学习项绝不发真实动作 |
| `Operator.read_rule` | 从哪些参数继承读取依赖的确定规则；用于来源和动作前条件检查，不用于猜机制 |
| `Operator.binder_children` | 首版必须为空；有内部 binder 的条目拒绝 |
| `Slot.index` | `$n` 的 n，非负连续整数 |
| `Slot.sort` | 槽值所属类型 |
| `Slot.time_role` | `before`、`after` 或声明的无时间值；防止把事后响应混入事前条件 |
| `Slot.role_constraints` | 同一项内明确的相同／不同角色义务；只有已有可判定义务才硬过滤，未知不是不相同 |

类型是结构合法性，不能取代环境验证。比如 `RoleBefore` 与 `RoleAfter` 的联系通过 `link` 表达，不靠把二者直接 Reuse 成同一个瞬时角色。

同一批次的 `$0` 必须具有同一种类型上下文；不同事件可将它绑定到不同实际像素或角色。类型上下文不相容时先由 Julia 分成确定的相容批次，不能把两个不同类型的 `$0` 都投入同一个无区分 e-graph。

这里的相容还包括硬角色约束和读取时序。某事件才成立的身份假设不能混进全批次 Γ；它须作为该项的显式条件，或形成另一种解释上下文。不得因两个 occurrence 合并到同一 e-class，就将一条事件的角色不等事实施加到所有其他事件。

### 3.3 来源记录与输出调用

| 字段 | 含义 |
| --- | --- |
| `program_index` | 输入数组中的 0 起序号；重复程序仍有不同序号 |
| `expression_path` | 从该程序根沿有序子节点走到 occurrence 的整数数组；根为 `[]` |
| `occurrence_id` | 该语法出现位置的稳定引用，不等于 e-class ID |
| `event_ref` | Julia 证据事件的引用，Rust 只回显 |
| `interpretation_ref` | 同一事件的一种候选关系解释版本 |
| `slot_bindings_ref` | Julia 侧将 `$n` 绑定到实际角色／值的记录引用 |
| `support_ref` | 完整帧读取、变化区域及残差记录的引用 |
| 输出 `call_path` | 重写后程序内某个库调用的位置 |
| 输出 `definition_ref` | 所调用定义的本轮临时名或已发布稳定 ID |
| 输出 `argument_terms` | 该被选中调用的参数项；数量等于 arity，不是全匹配表 |
| 输出 `source_occurrences` | 由证明与规则端口来源映射获得的源 occurrence 集合；允许多对多，不编造一一对应 |
| 输出 `proof_ref` | 把原程序和展开后重写程序连接起来的命名等式推导引用 |

一个 e-class 可服务许多 occurrence；这些事件的来源不得在 e-class 合并时被当作同一次干预。语法关系去重与证据出现次数是两个数量。

### 3.4 定义和完整轮次

每个定义记录：`temporary_name`（本轮 `fn_N`）、`arity`（参数数）、`parameter_sorts`（有序参数类型）、`result_sort`（结果类型）、`parameter_reads`（哪些参数来源实际被读取）、`body`（以 Param(k) 表示参数的 AST）、`pattern_text`（上游模式）、`closed_lambda_text`（第二条独立解码路径）、`dependencies`（定义引用）、`body_cost`（正文成本）。

`body` 的节点只允许三种：`Param{index}` 指第几个定义参数；`Const{sort,value}` 保存有类型的常量，`value` 按该类型的规范整数／字符串编码；`Call{operator,args}` 保存算子或库引用以及有序子项。输入项另允许 `Slot{index}`，定义正文禁止它。`Param` 不允许出现在普通输入程序中。结构共享可以在内存用引用，线上首版保持有限树或带明确拓扑顺序的无环引用，拒绝循环和悬空引用。

证明记录使用 `proof_id`（本作业内引用）、`left_term`／`right_term`（两端规范项）、`steps`（有序推导或无环推导节点）。每个规则步给出 `rule_id`（注册表里的规则身份）、`direction`（正向或逆向）、`site_path`（在哪个子项应用）、`substitution`（该步模式变量到有限项的赋值）、`premise_refs`（所依赖的已验证子推导）；同余步给出同一算子及逐端口子推导。Julia 实际重放替换并检查两端，不能只比 term 哈希或相信标注 `valid=true`。定义规则的注册身份同时包含正文版本，避免同名规则事后换体。

完整轮次记录：`round_index`、上述定义数组、全部 `rewritten_programs`、选中调用及证明引用、成本明细、输入与父 checkpoint 哈希，以及下列独立状态：

- `search_exhausted`：是否穷尽**当前配置与合法规则限定的搜索空间**；不是所有可能程序的全局最优保证。
- `match_support_exact`：被保存候选的匹配支持集是否精确；不得把截断行集标 true。
- `apply_complete`：选中定义的应用、最终提取及所需证明是否完成。
- `round_committed`：完整轮次文件已原子写入；与 Julia 是否已经发布是两件事。
- `stop_reason`：`exhausted`、`requested_rounds`、`step_budget`、`deadline`、`managed_bytes`、`hard_memory_limit`、`output_budget`、`invalid_input`、`invariant_violation` 中的明确原因。

候选可以在搜索未穷尽时被精确验证并使用；不完整匹配和半完成应用不能进入已发布库。

## 4. Codec：自由槽、模式参数和 De Bruijn 必须分开

首版三种变量各用独立解析上下文，禁止字符串替换混用。

1. 输入 `$n` 是外部自由槽，由当前输入程序的来源赋值解释；它不是全局对象 ID。
2. 搜索模式 `?#k` 是待抽象的第 k 个参数；Reuse 合并的是参数角色及其合法绑定。
3. 导出闭合 lambda 中 `$i` 是 De Bruijn index（德布鲁因索引），0 指最近的外层 binder。

`StitchCodec.jl` 使用专门 S-expression（符号表达式）解析器，不使用 `eval`、正则替换或 shell 展开。字符转义先在 AST 层规范化；保留名和非法数值在边界拒绝。

### 4.1 明确往返算法

输入：Julia 参数化结构项 `t`、类型上下文 Γ、来源映射 `O`。输出：字符串 `s` 和旁路来源表。

```text
encode_term(t, Γ):
    按签名检查节点算子、端口数、返回类型、读取规则
    将显式 RoleSlot(n) 编成 $n；核对 n < length(Γ)
    将整数／颜色等常量编码为声明的类型常量；禁止颜色被当坐标
    按有序端口递归序列化；来源只更新旁路 O
    assert decode_program(s, Γ) 与 t 在声明的规范化下结构相等
    return s

decode_definition(pattern, lambda, arity, signature):
    P = parse_pattern(pattern); 将 ?#k 转成 Param(k)
    要求 k 在 [0, arity)，各参数在类型传播后只有一个合法类型
    L = parse_exported_lambda(lambda)
    精确剥去 arity 个最外层 lam；首版体内不允许另有 lam
    对体内 $i：要求 0 <= i < arity，转成 Param(arity - 1 - i)
    检查 P 与 L 解码后的 AST、参数类型、读取依赖逐项相同
    检查正文无外部自由槽；依赖全部存在且依赖图无环
    return 经验证的参数化定义
```

零参数定义必须没有 `lam` 和自由变量。未来允许内部 binder 时，索引转换须加入局部深度；当前实现发现内部 binder 就明确 unsupported，不能套用上述简式。

### 4.2 正确与错误样例

正确模式：`(f (g ?#0) (g ?#1))`，arity=2。

正确导出：`(lam (lam (f (g $1) (g $0))))`。

正确调用：`(fn_0 a b)`，展开为 `f(g(a),g(b))`。

错误导出：`(lam (lam (f (g $0) (g $1))))`。类型可能仍相同，但参数顺序错，双路解码必须拒绝。另两个必拒例：arity=2 而体内出现 `$2`；输入 `(lam $0)` 被伪装成普通算子以绕过无内部 binder 约束。

来自不同事件的 `(link $0 $1 (vec 1 0))` 可具有相同语法形式；其 `$0/$1` 分别由自己的 `slot_bindings_ref` 解释。不允许因此断言两个事件的像素身份相同。

## 5. 类型约束落入真实搜索，而不只末端过滤

### 5.1 e-class 与类型入口

`StitchData` 增加明确结果类型和声明的读取信息；`StitchAnalysis` 持有冻结签名表引用。`size` 和原有 `fv` 继续维护。空类型或冲突不是正常合并结果。

`checked_add` 在 `egraph.add` 前检查实际子 e-class 类型；`checked_union_instantiation` 在任何显式等式合并前检查两侧实例类型、作用域、允许等式身份和读取约束。egg 的 `Analysis.merge` 无法否决已发生的合并，因此它只作最后不变量断言；发现不一致整批失败，不能在 merge 中“跳过后继续”。

`io.rs::programs_to_egraph` 不再直接 `add_expr` 未检查项；逐节点检查后构建。规则使用受控 `TypedApplier`，不能让任意 `egg::Pattern` 直接 union。隐式 congruence（同余）合并由固定算子签名和一致子类型保证，另设断言测试。

### 5.2 初始模式必须处理混合类型根

现有 `SearchState::new` 对所有非 programs e-class 建立单孔模式。若给一个混合类型状态强塞单一类型，会漏检或错误复用。

首版改为 `new_typed_seeds(shared)`：按 e-class 结果类型分组，每组一个原有单孔状态；孔类型固定为该组结果类型。best-first 的同一 frontier 接纳这些 seeds，仍用相同全语料成本比较；每个 seed 匹配自己的类型根。候选的 canonical key 加入结果类型及按孔排列的类型／作用域约束。此改动复用同一搜索算法，不启动多套各有真值的发现器。

### 5.3 Expand

`search.rs::expand_shapes` 先根据孔类型过滤不相容的算子返回类型，再计算支持。`apply_action` 在真正分配子状态前再次调用 `check_expand`。

例如孔 `Delta` 允许 `vec:Int×Int→Delta`；不允许 `link:RoleBefore×RoleAfter×Delta→Relation`。展开 `link` 后，三个新孔获得顺序固定的三种类型；同一已 Reuse 的孔若有多个出现位置，所有位置必须满足同一约束。读取依赖由算子规则传播，不能继承成任意同类型值。

`Pattern::expand`、`canonicalize_vars` 和 `concretize` 同步更新类型数组、角色约束和置换映射；把新孔插入类型数组的顺序必须与实际变量重编号一致。

### 5.4 Reuse

`enumerate_successor_actions` 在计算昂贵的两因子支持前做 `check_reuse(i,j)`；`apply_action` 再核验一次。首版两孔必须同类型、同合法作用域，且没有已声明的角色不等约束。仅同类型不足以强行说它们同一角色，实际绑定仍须通过原匹配等价条件。

相容例：两条 `link` 的 `Delta` 参数可以 Reuse；不相容例：`RoleBefore` 与 `Delta`，或显式要求不同的两个 `RoleBefore`。未知身份继续由候选关系表达，不能因无证据而断定不可复用。

保留当前无内部 binder 时的自由槽硬编码禁令：`search.rs` L119–129 的 `invalid_literal_expansion` 仍生效，`$0` 只能经参数进入定义，不能变成某个训练事件的隐式常量。

### 5.5 去重与优化不变量

`SeenTracker`、SMC dedup、Pattern equality/hash 均使用同一 typed canonical key。只改显示字符串而不改键会把合法性不同的状态误合并。

类型过滤只缩小合法候选集合且成本不变时，旧成本下界仍是该子集的下界；但冻结、dominance、自动内联等搜索简化也必须在有限枚举测试中验证不丢合法候选，不能仅凭“类型正确”跳过其覆盖检查。

## 6. 跨批次旧库：导入正文、注册等式、保留成本

输入旧库是 Julia 已发布库的一份冻结快照。Rust 作业中的副本不可修改旧定义，也不成为第二个长期概念库。

```text
import_library(snapshot, signatures):
    验证所有定义 ID、正文哈希、参数签名和依赖均存在
    拓扑排序；若有环、未知依赖或同名不同体，返回 invalid_input
    对每个 C(a0,...,an-1)=body：
        新增 lib_<stable-id> 的固定调用签名
        从 Param(k) 构造新鲜模式变量 ?m0... ?m(n-1)
        生成命名规则 (lib_C ?m0... ?mn) => body[Param(k):=?mk]
        核对 RHS 变量均由 LHS 绑定，类型和读取合同保持
    old_cost = 每个冻结正文按当前成本口径计算一次后相加
    return Registry、typed_rules、old_cost
```

正确例：`C(a,b)=f(g(a),g(b))` 编为 `(lib_C ?m0 ?m1) => (f (g ?m0) (g ?m1))`。错误例：把输出 lambda 中 `$1/$0` 原样放进 RHS；这会偷用本批全局槽，必须拒绝。

在 `load_egraph` 的首次构建、`egraph_from_programs` 的每次重建、以及新定义接受后的后继轮次，传入同一 `LibrarySnapshot` 并重新注册有效定义。新定义若引用本批更早的 `fn_N`，先加入本轮临时库和签名，再准备下一轮。

当前轮的 `fn_N` 也必须先完成类型推导、临时签名注册与定义性规则构造，才能进入 `typed_apply`；不能等添加调用节点后再检查其类型。此临时注册不等于 Julia 发布，当前轮失败即丢弃该临时提案。

注册不是把所有正文无条件塞入 `programs` 根。只有实际调用的展开进入其等价类；未使用的旧定义只保留注册信息和整体库成本。这样保持语料频率及人工 programs 根的含义。

旧库 DAG 保证定义展开本身终止；与其他等式一起饱和仍可能膨胀，因此每次实例化和重建继续受总预算约束。达到预算记录未饱和图，不能宣称所有等价项均已展开。

Julia 接受本轮定义时，按参数化正文、签名、规范化依赖 ID 产生稳定 ID；对定义体、所有调用、依赖和见证做 AST 重命名。哈希碰撞仍比对完整内容。上游 `first_free_fn_index` 只查当前图，不能担任全局库命名器。

## 7. 成本、计数与来源：严格分开

### 7.1 成本

首版保留上游 op-children 成本意义：有权 AST 树展开大小，调用是一个算子加参数项；一段子项若在树中出现两次就计两次。人工 `programs` 根也按同一 upstream 口径计入，所有对照保持一致。导出 lambda 的装饰性外层 `lam` 不另外增加 op-children 的正文成本。

`C_total = C_rewritten_corpus + C_new_definitions + C_frozen_old_library`。

旧定义成本是本批常量，不参与改变候选排序，但必须报告，不能在跨批比较中漏掉。正文依赖调用按调用计，不能既展开依赖正文又把整库成本再加一次。

内部非负成本统一 `u64` 且 checked arithmetic；有符号差值用 `i128`，无穷下界／未定义值用枚举而非借最大整数。上游 `StitchData.size:u32`、`usize` 总和及 `i64` 强转逐点修改，溢出返回明确停止／错误，不环绕、不饱和假装精确。协议成本用规范十进制字符串，Julia 严格解析为整数；压缩比输出分子／分母整数，浮点比率仅作显示。

所有权重固定为配置中的非负整数；首版 `sym_var_cost` 必须大于零。成本模型 ID 及权重进入协议与结果；不得把模型损失、因果置信度或预测分数直接加入现有 best-first 下界。

### 7.2 计数

关系支持数使用精确 `BigUint` 或等价任意精度非负整数，输出十进制字符串。修改 `matching.rs::num_substs`、`search.rs::total_substs` 及支持数乘加，避免 `usize` 乘积溢出。计数所需大整数内存也计入预算。

必须分别报告：唯一绑定数、匹配根数、语料 occurrence 使用数、独立证据事件数。SMC 粒子重数是第五个数量，不等于前四项。TDD model count 不能直接代替语料使用数或独立因果样本数。

SMC 以后启用时，逻辑计数保持精确；转入提议概率的归一化才使用明确的数值近似，并保存 seed、temperature、boost 及数值失败原因。不能先把所有大计数转 usize 溢出后再转浮点。

### 7.3 来源与规则解释

patched egg 的 `egraph.rs` 已提供 `with_explanations_enabled`、`explain_equivalence` 与 `union_instantiations`。本项目用命名的合法规则导出有限推导；不能只接受裸 `union` 生成的源码行号作为数学理由。

`TypedApplier` 以及学习定义应用必须通过 `checked_union_instantiation`：先核类型、绑定和规则身份，再调用 `union_instantiations(lhs,rhs,subst,rule_name)`。语义真值来自已验证定义与合法等式，不来自函数名看起来像证明。

每次重建前导出“本轮输入→本轮输出”的程序证明，checkpoint 保存；下一轮接在上一轮之后，不能在丢弃旧图后期待还能恢复所有早期解释。Julia 独立回放规则、参数替换与调用展开，并按规则预先声明的端口来源映射传递 occurrence；重排允许改变路径，复制产生多个来源关联，不允许丢失原需覆盖的响应和残差。

规则注册首版拒绝 RHS 新增未绑定变量、隐含事件条件和角色读取的无证明删除。单次事件中两边都返回 true 不构成可注册等式。

## 8. 共享因子与全程预算：先改哪些热点

### 8.1 共享行块

把 `Factor.rows: Vec<Vec<Id>>` 改为不可变 `Arc<RowBlock>`；`RowBlock` 内部是连续 Id 存储，加明确 `row_count`、`width`。`FactorView` 持有排序后的逻辑 `slots` 和 `physical_columns`，后者说明每个逻辑列读原行块哪一列。

- `renumber_factor` 只改槽位描述，不复制行块。
- 一般变量 canonicalize 可能改变列顺序；以列映射表示，不按错误顺序解释原内存。
- 行投影若出现重复，先精确去重再改变计数；不能把带重复的视图当集合。
- 首版保持上游可证正确的分解判据；注释改成“尝试独立分解”，不称“最细”。异或三列加独立第四列的例子必须保留。
- `Arc` 共享块只计一次已分配内存；最后一个引用释放时退还预算。描述符、哈希索引、临时缓冲和 proof 内存另计，不凭强引用数重复计。

提供唯一 `iter_rows()`／`value(row,column)` 访问接口后，逐项迁移 `search.rs`、`matching.rs`、`candidates.rs`、`cost.rs::filter_factors_by_candidate` 与 `RewriteScratch::fill` 等消费者。用 `rg '\.rows' third_party/egg-stitch/src` 查全访问点；不能只改 Factor 定义而在某个评分路径重新整表克隆。

### 8.2 预算对象与失败语义

一个 `Budget` 贯穿载入、规则饱和、搜索准备、后继支持扫描、Expand、Reuse、去重、计数、评分、最终应用、证明、序列化和后继重建。禁止每轮或每函数重新获得一整份内存／时间额度。

其配置字段为：`wall_ms`（整作业截止时间）、`managed_bytes`（可追踪分配预算）、`max_egraph_nodes`、`max_live_states`、`max_relation_nodes`、`max_output_bytes`、`check_every_work_units`（长扫描最迟检查间隔）。各字段作用不同，报告全部实际计量；这些数值不得以环境变量提供。

`reserve(bytes, purpose)` 返回 RAII reservation；扩容前检查实际 capacity 增量，`try_reserve` 失败转为明确停止。先分配后检查无效。CPU 密集但不分配的嵌套扫描也定期 `tick()`，保证 deadline 能到达。

追踪预算不等于总 RSS 硬上限；egg 内部、分配器和序列化存在额外空间。宿主 supervisor 同时以 Linux cgroup v2 给整个 worker 进程组设置硬内存限额，分别记录 cgroup peak、RSS 与 tracked bytes。硬杀可能没有当前轮结果，所以先前完整轮次必须独立可恢复。

### 8.3 Expand 与 Reuse 的有界构造

第一版的行式参考实现仍允许真实需要的行存在，但构造前预约预算；任何中途失败只返回 `Incomplete(reason)`，不把已构造前缀当精确子关系。

```text
try_expand(parent_relation, slot, op, budget):
    核对 slot 类型和 op 签名
    获取受影响因子的共享视图；其他因子只重编号
    对旧行以及该slot匹配op的节点：
        budget.tick()
        在创建新行与其容量前 reserve
        加入新孩子；保持去重／唯一性不变量
    全部完成后才创建 ExactRelation；释放构造租约的未用部分
    可再尝试分解；分解临时哈希与投影也受预算
```

Reuse 同因子时过滤行；跨因子时优先建立按规范 e-class ID 的有界索引，再做等值连接，避免为每次过滤都盲扫完整积。首版无内部 binder，作用域均为 0，可用规范 ID 作为连接键；未来跨深度 `shift_equal` 不能直接替成普通 ID 相等。

连接输出可能本来就很大；索引仅减少不必要比较，不承诺压缩全部输出。预算失败即未完成，不删除合法行。不在已有唯一行上再无条件创建第二个全量哈希集合。

### 8.4 最终 apply 必须一起修改

`cost.rs::build_rewritten_egraph` 当前会 `factors_product` 全量积，同时累计 `pending`。改成 `AssignmentIter` 逐个联合绑定消费，并以有界 chunk 保存待合并项。

首版 binder-free 条件下，每个 chunk：规范化旧 Id→检查调用签名→增加调用节点→记录命名定义等式→执行该 chunk 合并→rebuild。后续 chunk 读取的旧 Id 必须经 `find` 重新规范化；不保留跨 rebuild 的裸 e-class 引用。关系快照仍是本轮搜索结束时的不可变集合，不因新 union 增减其逻辑成员。

上游延迟 union 是为避免自由变量分析在 rebuild 前陈旧。当前首版不启用高阶捕获；未来启用时必须重新核查 `shift_free_egraph` 与 chunk 生命周期，不能宣称此方案已覆盖任意 binder。

必须比较流式全量完成与原小规模全积实现的最小成本相等、最终提取程序的展开语义与必要来源一致，两份证明分别通过独立重放。证明路径和等成本候选可能不同，不能无条件要求 proof 字节相同；仅在明确固定 canonical tie-break 后要求输出字符串一致。应用中途停止时不发布这一轮；最后一个已经完成的 checkpoint 仍有效。不能随意只应用“一个看起来最优的绑定”而不证明与上游语义、成本等价。

## 9. 完整轮次落盘和权限边界

把上游 `apply_abstraction` 拆为 `apply_and_extract` 和 `prepare_next_round`。顺序改为：找到候选→完整应用与提取→导出所需证明和来源→原子落盘本轮→需要下一轮时才重建。这避免最后一轮无意义地建下一张图，也避免下一轮重建失败吞掉已经完成的结果。

`commit_round` 写入同一文件系统内的 `round-000001.tmp/`，包含定义、完整重写语料、证明和 manifest；每文件 flush/fsync，最后写校验 manifest，fsync 目录，再 rename 为 `round-000001/` 并 fsync 父目录。消费者只读带校验 manifest 的正式目录；不读取 `.tmp`。

checkpoint 中不包含正在修改的全局 Julia 库。Julia 检查后才调用 `publish_if_current(base_version, evidence_snapshot, proposal)`：若新证据已反驳相关前提，先重验相应依赖；不能覆盖更新版本。一个定义被拒绝，其依赖定义和调用一起拒绝或重算，不能拼接半新半旧库。

worker 的权限与实际职责对应：只读冻结输入和依赖，写本 job 输出，无网络、无 ARC 凭证、无游戏执行能力。Linux 首版用配置指定的 `bwrap` 和已委派 cgroup v2；Julia 构造参数数组直接启动，不拼 shell。预检不满足隔离或硬限额就明确拒绝作业，不偷偷退回无隔离运行。编译依赖阶段和运行 worker 阶段分开，运行时不下载依赖。

退出行为固定：

| 退出码 | 含义 | Julia 行为 |
| --- | --- | --- |
| 0 | 作业按策略自然完成；仍须读 `search_exhausted` | 验证完整轮次，不假定全局最优 |
| 10 | 资源／步数停止，但有完整精确候选轮次 | 验证可用 checkpoint，并记录未穷尽 |
| 20 | 协议、路径、哈希或配置拒绝 | 不发布；返回具体字段和错误 |
| 21 | 类型、定义展开、证明或不变量失败 | 拒绝受影响提案，保留旧发布库 |
| 22 | 预算停止且没有完整新轮次 | 记录未知／未找到；不能说不存在概念 |
| 23 | worker 异常或被硬内存限额终止 | supervisor 保存原因；只检查此前已完整落盘轮次 |

进程退出码不代替 manifest；若文件自称完成但哈希、顺序或父 checkpoint 不符，拒绝读取。外部 kill 由 supervisor 归类，不要求已被杀 worker 自己写出退出原因。

## 10. 后续共享决策图与 TDD 必须满足的运算合同

首版关系后端为共享 factors。第二阶段首先实现 `third_party/egg-stitch/src/relation/mdd.rs`：Multi-valued Decision Diagram（多值决策图，MDD），固定有限域变量序，节点经 hash-consing（按内容共享节点）形成 DAG。从局部基本关系直接编译，连接通过递归 apply、存在投影通过分支 OR 与去重完成，不先展开完整笛卡尔积。它是明确的 MDD 实现，不能标成 TDD 新论文定理实现。TDD 随后以相同合同对照，是明确选择的另一后端，不是失败时静默转换的 fallback。

变量是固定快照中各匹配槽的有限 e-class 值编码；域编码、变量序／变量树、有效值限制和快照版本都参与身份。上游搜索阶段 e-graph 不 union，因而这些 ID 稳定；最终 apply 的 union 之后，下一轮必须重建或正确重映射关系，不能把旧域 count 直接当新图 count。

| 运算 | 输入→输出 | 精确语义／检查 |
| --- | --- | --- |
| `rename_slots` | 关系、双射槽映射→关系 | 只改变量名字，不改变赋值集合；非双射必须走显式约束／投影 |
| `filter_equal` | 关系、两个兼容槽→关系 | 保留两槽值相等的赋值；不删证据频次 |
| `join` | 两关系、共享槽映射→关系 | 共享槽一致的自然连接；预算不足为 Incomplete |
| `project` | 关系、保留槽→关系 | 集合存在量化并去重；投影前后 count 一般不同 |
| `expand` | R(z,x)、孩子关系N(x,c)→R'(z,c) | 精确为 π(z,c)(R ⋈ N)，不得先全量物化再声称避免峰值 |
| `is_empty` | 关系→精确 Bool 或 Incomplete | 未算完不能返回 true |
| `contains` | 关系、完整赋值→Bool | 域外编码拒绝；不把不存在编码当变量值 |
| `count` | 关系→任意精度整数 | 只计有效域中的唯一赋值；处理未出现在子图上的自由变量因子 |
| `min_additive` | 关系、每槽值的整数成本→精确最小成本及argmin | 与当前 factored_min 同义；不将独立因子公式误用于有耦合关系 |
| `fold_weighted` | 关系、明确权重函数→精确值或不支持 | 权重来自调用／来源合同，不从布尔支持数猜出 |
| `one_witness` | 非空关系→一个完整赋值 | 见证只证明存在，不代表全部绑定 |
| `iter_assignments` | 关系、消费预算→迭代器 | 每个合法赋值恰一次；停止时显式未完成 |
| `equivalent` | 同域两关系→Bool或Incomplete | 用于测试支持集；未知不能当相等 |

正常计算返回 `Exact(value)` 或 `Incomplete(reason)`；类型、域、编码不符以及尚未实现的运算返回明确 `RelationError`，其中 `UnsupportedOperation` 不能转为空关系或静默改用另一后端。不返回没有标记的截断近似。布尔支持关系、occurrence 重数和来源索引分开保存，共享关系节点不能合并独立证据身份。

编码三值域若用两位，必须显式排除第四个无效码；例如域 `{0,1,2}` 的全关系 count=3，而不是4。两变量受 `x=y` 约束时count=3，而不是9。存在投影的去重不能累加被消去见证的数量，除非调用的是另一个明确定义的加权运算。

TDD 节点数、构建工作量和实际进程内存分别记录。任意投影／变量树变化不能一概承诺多项式；若采用现有 TiDiDi 重组，不得标成新论文 Theorem 13 的实现。只有 same-domain、same-cost、same-provenance 的有限参考对照通过后才启用相应后端。

MDD 归约若跳过一个仍属于关系作用域的变量，count 必须乘该变量的合法域大小，`min_additive` 必须加该变量合法取值的最小单槽成本；已经被 project 消去的变量则不再计入。不能因节点省略就把作用域变量当不存在。只有成本显式为 `stub + Σslot cost(slot,value)` 时才采用这一动态规划；通用关联成本须有自己的精确算法或返回不支持。布尔成员关系、语料 occurrence multiplicity（出现重数）与 SMC 粒子重数分别维护；后端无法保持既有计数和评分合同就停止切换，不静默换另一个后端。

## 11. 一次完整作业的伪代码

```text
输入：FrozenEvidence、PublishedLibrary、TypedCorpus、配置
输出：ValidatedProposal 或明确未完成／拒绝；可能发布一个新库版本

Julia:
    job = freeze_job(证据版本, 完整旧库, typed corpus, 规则版本, 配置)
    check_codec_roundtrip(job)
    run worker(job.manifest)                         # 一次粗粒度跨语言调用

Rust:
    validate_manifest_and_hashes()
    registry, unfold_rules, old_cost = import_library()
    graph = load_typed_corpus_with_budget()          # 旧定义重新注册
    for round in requested_rounds:
        search = existing_best_first(graph, typed_seeds, one_budget)
        if search没有精确候选: 按原因停止，不构造空的“发现”
        proposal = typed_apply_extract_and_prove(search.best, one_budget)
        if proposal未完成: 停止当前轮；保留旧checkpoint
        assert proposal.cost为精确整数且body/pattern/lambda一致
        commit_round(proposal, input_and_parent_hashes)
        if 下一轮需要: graph = prepare_next_round(proposal, full_temp_library)
    write_job_status()

Julia:
    for committed_round in validated_chain:
        解码pattern和lambda两路；核对参数／类型／依赖
        回放命名等式及库展开，核对每条程序及来源和残差
        按当前证据复核新反例，检查base版本没有被覆盖
        统一稳定ID，原子发布库、重写语料、来源版本
    后续事件调用新定义并记录真实消费者；结果交给控制闭环检验
```

这个 Rust 作业只证明表达压缩与匹配的合同。一次定义发布后是否预测成功、是否改变下一次真实公共动作，是总计划的后继消费者验收，不用压缩率代替。

## 12. Codex 可逐项执行的改源任务

每项先读固定源码与本节合同，再修改所列文件；完成必要测试即提交里程碑，不把无关重构混入。工程任务按依赖串行，测试数据准备可并行。

| 项 | 源码事实与改动位置 | 可执行改法 | 必须通过的测试 |
| --- | --- | --- | --- |
| R1 固定工具链和迁入 | `Cargo.toml` edition2024、GPL、patched egg；根 workspace | 迁入唯一源码，根patch与lock、来源清单，新增bridge crate | `check_toolchain.py`；`cargo check --locked --workspace`；上游现有单元／快照测试 |
| R2 严格协议 | `io.rs` L14–46、L76–88；`main.rs` | manifest runner，配置全量展开，文件限长和哈希核对 | `protocol_reject_unknown_field`、`protocol_reject_hash_mismatch`、`protocol_reject_version` |
| R3 codec与类型 | `lang/mod.rs` L90–140；`op_children.rs` L29–30、L51–52；`family.rs` L103–125、L193–199 | typed分析、受控add/union、Julia双路解码 | `codec_free_slots_roundtrip`、`lambda_param_order`、`reject_free_capture`、`reject_input_binder` |
| R4 搜索提前类型过滤 | `search.rs` L566–641、L739–790、L860–958；`pattern.rs::expand/reuse/canonicalize_vars` | typed seeds、Expand/Reuse前检查、typed canonical key | `typed_expand_rejects_wrong_output`、`typed_reuse_rejects_role_delta`、`typed_canonicalization_preserves_constraints` |
| R5 旧库 | `lib.rs` L418–439、L490–495、L555–588；`io.rs::egraph_from_programs` | DAG导入、Param→新鲜模式变量、每次重建注册、旧成本常量 | `old_library_unfold_after_rebuild`、`reject_library_cycle`、`reject_db_as_rule_parameter`、`old_cost_counted_once` |
| R6 精确数值 | `matching.rs::num_substs`；`search.rs::total_substs`及support；`cost.rs`与`lang/mod.rs`大小 | checked Cost/Delta、BigUint count，分子分母输出 | `count_exceeds_usize_without_wrap`、`cost_overflow_is_error`、`ratio_uses_post_rewrite_baseline` |
| R7 共享与预算 | `factor.rs` L19–35、L57–140、L183–191；`search.rs` L240–284、L311–414 | Arc行块／列视图、分配前预算、所有扫描tick | `renumber_shares_rows`、`projection_deduplicates`、`expand_budget_no_partial_exact`、`reuse_deadline_checks` |
| R8 后继路径 | `best_first.rs` L134–138、L193–258；`smc.rs` L111–160 | 预算下传到prepare、支持枚举、逐后继构造；不先collect全部子状态 | `best_first_stops_inside_child_build`；SMC启用前同样验证 |
| R9 最终应用与证明 | `cost.rs` L687–711；patched egg `egraph.rs` L475–483、L1095–1106 | 流式积、bounded chunk、typed named union、有限程序proof | `stream_apply_equals_small_materialized`、`reject_unregistered_proof_rule`、`origin_survives_commute` |
| R10 完整轮次 | `lib.rs::apply_abstraction` L576–588；`main.rs` L78–81 | apply/extract与next graph分离，round原子保存、supervisor状态 | `kill_after_round_one_keeps_round_one`、`partial_tmp_is_ignored`、`next_rebuild_failure_keeps_checkpoint` |
| R11 Julia发布和消费 | 拟新增StitchBridge/Library/Provenance | 版本核验、依赖闭合、AST重命名、来源与证据新鲜度检查 | `reject_one_definition_rejects_dependents`、`stale_base_does_not_publish`、`next_event_uses_published_definition` |
| R12 可替换关系合同 | 新relation模块与factor适配 | 精确参考后端先闭合，再按相同接口接TDD | `relation_laws_small_domains`、`invalid_binary_code_excluded`、`weighted_support_not_boolean_count` |

R1–R11 构成首个真正可消费的发现闭环；R12 的接口和有限参考测试前置，TDD 实际后端随后实现。不要为了等 TDD 而推迟真实 Rust 发现和 Julia 消费，也不要跳过资源保护先跑无界搜索。

## 13. 最小测试数据与精确期望

### 13.1 必须真正发现新定义的正收益夹具

新建 tests/fixtures/stitch/discover_positive/。签名只含类型 Atom，纯函数 g:Atom→Atom、f:Atom×Atom→Atom，以及 c00…c31 三十二个互不相同的 Atom 常量；初始库和等式集均为空。它是符号结构合同测试，不是预置移动机制。

用确定性生成器生成 16 条输入，第 i 条（i=0…15）为：

~~~text
(f (g c[2*i]) (g c[2*i+1]))
~~~

这里 c[n] 在实际字符串中替换成两位编号的符号，例如第一条是 (f (g c00) (g c01))，不是把方括号语法交给引擎。每个程序和 occurrence 有独立的合成来源。测试输入绝不附上候选宏体或其名字。

固定所有原子/算子/参数成本为 1、人工 programs 根成本为 1，单轮 best_first 搜索、最大抽象 arity=2，不使用重写。独立成本检查器应得到原语料 16×5+1=81。模式 f(g(Param0),g(Param1)) 在声明成本下正文为 5，改写后 16×3+1=49，整体为 54，净节省 27。这个算术只证明搜索空间内有正收益见证；验收必须真的调用搜索并取得合法正收益提案，不能将见证直接塞入输出。

允许引擎返回同成本的参数重命名或另一个合法更优定义；要求独立展开相等、实际总成本<81、非零使用、完成轮次原子落盘。若该有限无重写用例因搜索预算未完成，没有提案，就记 incomplete 并定位预算/搜索，不能伪造发现。完整穷尽后声称无正收益则为错误。

第二批建立 c32…c63 的相同结构新语料，导入首批实际发现的定义：检查旧库不作为训练样本重复加入，调用展开在强制 rebuild 后仍有效，旧库成本只加一次。再删除一个仍被引用的旧定义正文，必须协议拒绝，不把该符号当新常量继续跑。

### 13.2 其它必须核对的反例

测试不依赖特定游戏或手写solver，验证本桥必须保持的语义。`tests/fixtures/stitch/<case>/` 含输入、签名、旧库、规则、配置与期望；失败例也必须验证退出码和不发布。

| 样例 | 输入／干预 | 精确期望 |
| --- | --- | --- |
| 共享位移参数 | `pair(link($0,$1,vec(1,0)),link($2,$3,vec(1,0)))` 和位移`vec(0,2)`的另一项 | 正确类型的共享Delta候选可表示；候选是否最终胜出另测配置，不能预写选择结果 |
| 参数顺序 | 前述双参数f/g例，第二条lambda交换$0/$1 | 第一条通过；交换例拒绝，旧库版本不变 |
| 自由槽无泄漏 | 不同事件同语法$0，分别绑定不同像素；定义体偷写$0 | 正常语法共享且来源分离；偷捕获定义拒绝 |
| 同因子Reuse | R(x,y)={(1,1),(1,2),(2,2)} | equality filter后投影得到{1,2}，count=2 |
| 跨因子Reuse | X={1,2}，Y={2,3} | x=y连接并投影仅{2}，count=1 |
| Expand | R(z,x)={(A,U),(B,V)}；N(U)={(1,2),(3,4)}、N(V)={(5,6)} | R'恰三行(A,1,2)、(A,3,4)、(B,5,6) |
| 投影去重 | R(x,y)={(1,0),(1,1),(2,1)}，project x | {1,2}，不是三条 |
| 集合和occurrence | 两条完全相同输入程序，各有不同event_ref | 表达可共享；program_count=2；证据索引保留2个，不能由e-class数替代 |
| 高阶相关 | a xor b xor c=0，d自由 | 8行；现有成对分解可保留整块；正确重组恒等，不宣称最细 |
| additive min | X={1,2}、Y={3,4}，costX(1)=7、costX(2)=2、costY(3)=5、costY(4)=1 | count=4，min=3，argmin=(2,4) |
| 受约束min | R={(1,4),(2,3)}同成本 | count=2，min=7，argmin=(2,3)；每列最小拼成的(2,4)非法，不能误报3 |
| TDD有效码 | 三值域二进制编码 | 全域count=3；x=y的二维关系count=3 |
| 旧库与重建 | C(a,b)=f(g(a),g(b))，批次含lib_C调用；强制重建一轮 | 重建后仍能匹配正文结构；旧库正文只计一次 |
| 轮次中止 | 第一轮完成后注入第二轮分配失败 | 第一轮目录有效，第二轮不发布，退出10或23依失败方式准确区分 |
| 数值边界 | 65个相互独立二值槽 | count精确为36893488147419103232，不溢出usize |
| 成本边界 | 形成超过允许u64成本的人工权重／大小 | 明确错误；不返回负成本、0成本或最大整数伪结果 |

有限穷举还要比较原行集合参考与优化后端的 `expand/reuse/project/count/min/iter`，包括空关系、零参数真关系（唯一空赋值count=1）、零参数假关系（count=0）、重复投影及不同slot排列。只对这些具体风险增加测试，不重复堆叠镜像实现测试。

## 14. 证据与实施完成的判定

本规格使用的一手源码均固定为上文 SHA：

- [E-Stitch io.rs](https://github.com/mlb2251/egg-stitch/blob/e4cd59047b9e1c7d04bc035a3c1cadd66a1b7c92/src/io.rs)、[lib.rs](https://github.com/mlb2251/egg-stitch/blob/e4cd59047b9e1c7d04bc035a3c1cadd66a1b7c92/src/lib.rs)、[family.rs](https://github.com/mlb2251/egg-stitch/blob/e4cd59047b9e1c7d04bc035a3c1cadd66a1b7c92/src/lang/family.rs)。
- [search.rs](https://github.com/mlb2251/egg-stitch/blob/e4cd59047b9e1c7d04bc035a3c1cadd66a1b7c92/src/search.rs)、[factor.rs](https://github.com/mlb2251/egg-stitch/blob/e4cd59047b9e1c7d04bc035a3c1cadd66a1b7c92/src/factor.rs)、[matching.rs](https://github.com/mlb2251/egg-stitch/blob/e4cd59047b9e1c7d04bc035a3c1cadd66a1b7c92/src/matching.rs)、[cost.rs](https://github.com/mlb2251/egg-stitch/blob/e4cd59047b9e1c7d04bc035a3c1cadd66a1b7c92/src/cost.rs)。
- [patched egg egraph.rs](https://github.com/mlb2251/egg/blob/196d7d4ba09fcbc28f9a35d206f54d45e24f8410/src/egraph.rs)。

本轮补读还发现 `candidates.rs` L34–36、L54以后在捕获位数超过20时只保留一个keep-everything候选的现有退让分支。首版无内部binder，`var_depth=0`，该高阶路径不可达；正式协议拒绝高阶输入。以后扩大片段时，应将超预算改成明确Incomplete并补搜索完整性合同，不能悄悄把这一旧分支当精确全候选枚举。

交付不能以“二进制能运行”签收。必须同时取得：固定工具链构建记录；codec和类型反例测试；跨批库正文可展开；同语义整数成本；原子轮次与异常恢复；独立Julia展开及来源核验；后续新事件确实消费定义的记录。真实控制与因果覆盖另由公共动作闭环验证。本计划没有完成任何一项运行代码改造，也没有产生性能提升或TDD优越性的实测结论。
