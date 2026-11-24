# 充分本地验证与 E-Stitch 内部哈希优化修订

2026-11-24，台北时间。本次读取实现分支 HEAD `2a2b457970e75f6bae97401e56e3758899d3d8bc`；运行代码仍为 c710 基线。本次修改 03–06 的计划与验收规格，**未修改运行代码，未解除当前进程中的实际限制，也未宣称新增性能测试通过。**

## 1. 为什么修订

用户明确要求本地测试给予充足计算，并指出“预算不足”不应成为尚未实现核心功能的解释出口。上一版把大量未经本机测量的数值直接设为默认，混合了资源保护、调度粒度、表示能力和实验范围。这一做法撤回。

本次撤销的正常本地默认包括：32 个召回候选、4 角色、12 个节点、6 列、20,000 工作量、每任务 2 个新定义、256 个子库定义、64 MiB 索引，以及把现有 60 秒／256 MiB／两轮／arity 2 作为新能力验收起点的规定。它们不换成另一组任意更大的数。

类型、相位、公共证据、依赖完整、证明回放与未知动作隔离仍保留。低限额仅用于明确的故障注入测试。

## 2. 限制的实际来源

| 具体问题 | 代码位置 | 当前逻辑与后果 | 实施要求 |
| --- | --- | --- | --- |
| 现有默认太小 | `config/stitch.toml` | 两轮、20,000 步、arity 2、60 秒、256 MiB；直接影响搜索与可表示宏 | 历史对照保留可追溯，正常本地验收不沿用 |
| Rust 限制可配置范围 | `rust/bridge/src/protocol.rs::Config::load` | 还拒绝超过 10 分钟／1 GiB／16 轮／arity 8 等配置 | 删除无测量依据的通用天花板；物理配置与语义范围分别检查 |
| Python 重复硬限 | `python/src/tddesc_tools/stitch.py::run_worker` | 再拒绝 >10 分钟／1 GiB，并设置 systemd／subprocess 截止 | 与同一本地运行策略一致，未设时间截止时不隐藏加回 |
| Julia 又缩时间 | `OnlineSession.jl::online_learn!` | 对 Rust wall time 再取最小值；库大小减配额 | 取消隐式缩减与固定定义数终点 |
| 本可无截断却被包装为必填 | `engine.rs::search`、`main.rs::Job::run` | 始终 `Some(step_limit)`、deadline、固定 rounds | 真正支持 Option 的无固定步数／时间语义，各层贯通 |
| 序列化阻挡合法输入 | `protocol.rs::FileRef::read`、codec／schemas | 4 MiB、128 sorts 等为软件实现常量 | 按问题扩展装载或采用精确分块／流式，不把它们当自然定律 |

特别核实：`third_party/egg-stitch/src/best_first.rs:124–131` 本来就允许不设 num_steps 和 time_limit，运行到 heap 穷尽；并明确不以“近期没有改进”为停止理由。强制小额度主要来自本项目 wrapper 和上一版计划，不是 E-Stitch 的数学要求。

## 3. 本地如何既给足计算，又不无条件耗尽机器

对声明的有限验证域，匹配、关系求值、证明与核心消费必须完成。开放概念搜索按成本层逐层推进，不设置永久的 4 角色／6 列边界；索引分页只改变处理顺序，剩余候选继续可达。

物理资源保护依据实验机可用内存、其他任务和实测增长设定。当前没有读取用户实验机，因此本次不编造内存或运行分钟数。触及保护要保存已验证产物和未完成义务，随后测出原因、优化或提供充足资源继续。

区分三种完成责任：

- **暂用概念**：类型、来源、绑定和条件正确，在已检范围没有未处理反例，可以暂用并继续验证；不要求穷尽所有假设。
- **查询否定**：由“没有找到”断言 false，必须完整检查相关有限域。
- **最优搜索声明**：声称没有更好抽象，必须有搜索穷尽或正确界证书。

核心闭环测试出现 INCOMPLETE，说明工作未完成；不能把“安全停止了”当成功。只有专门检验中断恢复的测试，才把这个状态作为预期输出。

## 4. 哈希确实应该进入 E-Stitch 内部，而且已经部分存在

Hash-consing（结构哈希驻留）已在 egg 的 e-graph 中共享相同节点；SeenTracker 已对模式、类型与冻结集合去重；候选形状和 factor 投影已有哈希聚合。真实 bridge 启用 opt-seen，但关闭 dedup-by-match。

所以本次不是重复加一个笼统的“哈希模块”，而是补三个具体热点：

| 优化 | 当前代码位置与浪费 | 改法与语义义务 |
| --- | --- | --- |
| 去重前移、逐个后继 | `best_first.rs:246–254` 先构造全部 child matches；278–280 才去重 | 先 preview 精确 pattern／sorts／freeze 信息，非变更 seen probe；未重复才 materialize，成功后登记；逐个后继避免临时全集 |
| Expand 形状桶 | `search.rs::build_subset_matches:316–355` 对每行反复扫 e-class 全部节点 | 按规范 e-class 与算子形状索引，桶内精确核验；保留全部子节点组合和来源 |
| Reuse 精确连接 | `search.rs` 的支持计数和实际匹配构造均有跨 factor 双循环 | 同深度用规范 e-class ID 作精确 hash join；同时修改计数／物化及潜在笛卡尔积提前拒绝 |

第三项的数学依据是同深度时 `shift_equal(a,b,d,d)` 与 `find(a)==find(b)` 等价。不同绑定深度仍按原 shift 语义处理。同键多行必须全部保留，不能只存一个“代表匹配”。

外部相似性索引帮助选择材料和访问顺序；内部精确哈希减少重复结构与无用匹配。相似不等于等价，哈希碰撞用真实键比较消解。

## 5. 不直接打开未经核验的剪枝开关

`footprint/tracker.rs` 的匹配脚印包含 hash/fingerprint，但精确列置换核验仅在 `check_slow` 路径执行，typed 端口等完整语义还需贯通。本次不通过打开开关来制造速度结果。

后续若用脚印剪枝，hash 只筛桶，必须再证明类型、深度、端口与冻结策略相容。完整 e-graph／搜索 epoch、角色映射和版本进入缓存边界；不能跨 rebuild 无条件复用旧代表 ID。

## 6. 如何验收修订真正生效

1. 本地运行策略没有在 Julia、Rust、Python 或外层 supervisor 被重新压回旧小限额；不把无上限写成巨大整数。
2. 核心测试在声明域内算完，实际新定义被消费，反例确实改变后续使用；不能全部 unknown 或仅 pending 就 PASS。
3. 三项哈希优化与独立原算法比较完整后继、匹配行、多重性、类型、冻结信息、支持数和证明，不只比较耗时。
4. 性能记录分开显示扫描、展开、输出、临时分配、managed bytes 与 RSS；真实稠密输出仍有成本，不承诺任意问题都线性。
5. 未完成的正常能力验收继续推进；故障注入的小限额单独标注，不混入“已经充分验证”的结论。

实际执行顺序：先贯通充分本地计算的运行策略，复现完整当前工作量；再逐项加入三种精确哈希优化并做同语义对照；最后使用充分计算完成 03–06 中的认知闭环验收。旧源码限制在代码修改前仍存在，本文件只是修正实施要求。

## 固定源码参考

- [项目配置](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/config/stitch.toml)
- [Rust 配置与文件合同](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/rust/bridge/src/protocol.rs)
- [Rust 搜索桥](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/rust/bridge/src/engine.rs)
- [Rust 多轮生命周期](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/rust/bridge/src/main.rs)
- [Python 监管](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/python/src/tddesc_tools/stitch.py)
- [best-first 搜索](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/third_party/egg-stitch/src/best_first.rs)
- [Expand／Reuse／SeenTracker](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/third_party/egg-stitch/src/search.rs)
- [shift 相等](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/third_party/egg-stitch/src/shift_equal.rs)
- [e-graph 结构驻留](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/third_party/egg/src/egraph.rs)
- [匹配脚印](https://github.com/zdx3578/TddESCat/blob/2a2b457970e75f6bae97401e56e3758899d3d8bc/third_party/egg-stitch/src/footprint/tracker.rs)
