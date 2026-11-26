# 12｜JSON升级：旧版原因、依赖修复与具体迁移

本文件属于R1计划。结论：应迁移到本轮核查的 **JSON.jl 1.13.4**；必须同时采用Compose的官方JSON1修复，并改造本项目的解析与规范身份调用。本轮已经查明原因和具体改动，不声称已更新运行代码或生成可用Manifest。

## 1. 为什么当前是JSON0.21，证据是什么

沿 `julia/TddESCat/Project.toml` 的实际提交历史查到，`JSON = "0.21"` 在2026-11-23初始三语言环境提交引入，不是最近特意降级：

- [初始提交0a91ce0](https://github.com/zdx3578/TddESCat/commit/0a91ce0153def920b376b1367b48197057593072)。
- [当时环境说明06](https://github.com/zdx3578/TddESCat/blob/0a91ce0153def920b376b1367b48197057593072/docs/changelog/2026-11-23-三语言框架与复杂移动实施计划/06-三语言环境搭建与预检.md)明确记录：为满足Catlab拉入的Compose兼容范围，JSON选择0.21.4。
- [当前Manifest](https://github.com/zdx3578/TddESCat/blob/0d53a1c683fbe0ba3c9d8e41ac66cb6fe23dce81/julia/TddESCat/Manifest.toml)实际锁 `Catlab 0.17.6 → Compose 0.9.7 → JSON 0.21.4`；同环境另有JSON3 1.14.4，它是不同UUID的包。
- [Compose正式tag v0.9.7的Project](https://github.com/GiovineItalia/Compose.jl/blob/v0.9.7/Project.toml)确实仅允许JSON0.18、0.19、0.20、0.21。

因此，“历史依赖约束”是真实原因，不能把它归咎为随意选旧库。但继续固定旧版也不是唯一方案：上游已经修复，项目应明确升级。

## 2. 最新来源与正式选择

截至本次2026-11-26核查，[JSON官方最新release](https://github.com/JuliaIO/JSON.jl/releases/tag/v1.13.4)为 **1.13.4**，发布时间2026-10-30。不要把用户提到的1.2误读成必须锁1.2.0。

[Julia Pkg兼容语义](https://pkgdocs.julialang.org/v1/compatibility/)中：

| 配置 | 实际范围 | 本项目裁决 |
|---|---|---|
| `JSON = "0.21"` | `[0.21.0, 0.22.0)` | 原范围，排除1.x |
| `JSON = "1.2"` | `[1.2.0, 2.0.0)` | 因而允许1.13.4，不等于只允许1.2 |
| `JSON = "=1.13.4"` | 只允许1.13.4 | 本次应用项目采用精确锁，与现有精确依赖管理一致；升级走显式测试 |

Compose官方修复为 [`139021151ab8cc4bafb3b8fe88c4fd659f734cf3`](https://github.com/GiovineItalia/Compose.jl/commit/139021151ab8cc4bafb3b8fe88c4fd659f734cf3)，2026-06-02合入PR455。源码已增加JSON1兼容，并将 `src/fontfallback.jl` 的 `text_width(widths::Dict, ...)` 改为 `AbstractDict`；这是实际接口修复，不是仅强行放宽compat。本轮latest release仍为v0.9.7且早于该提交，因此**固定官方修复commit**，不用浮动master、不在项目里伪造兼容声明。

[Catlab0.17.6](https://github.com/AlgebraicJulia/Catlab.jl/blob/v0.17.6/Project.toml)允许Compose0.9；该维护提交的版本标识仍为0.9.7。Galley固定源要求JSON1.2范围，JSON1.13.4满足。数据结构依赖需与PDDL/SymbolicPlanners整体解析：本轮选用的SymbolicPlanners维护commit和Galley均允许DataStructures0.18/0.19，不预先宣称已完成整图解析。

## 3. 修改位置与当前后果

源码定位以0d53a1c为准；`ProgramSemantics.jl`在新提交增加内容，旧行号应按函数查找。

| 具体问题 | 代码位置 | 当前逻辑 | 升级后可能后果 | 正确修改 |
|---|---|---|---|---|
| 依赖图限制 | `julia/TddESCat/Project.toml`、`Manifest.toml` | JSON0.21 + Compose注册版 | 单改JSON会出现不相容依赖图 | 同次迁移固定Compose1390、JSON1.13.4及Galley8eef，真实Pkg解析后生成Manifest |
| 默认解析容器变化 | `RunStore.jl: read_json`，其他直接JSON.parse/parsefile调用 | 未显式指定字典类型 | JSON1默认JSON.Object，严格Dict字段/方法可能失败 | 所有协议/证据入口统一显式 `dicttype=Dict{String,Any}`；只保留一套新解析合同 |
| 严格容器字段 | `PolicySemantics.jl` 的 `body::Dict{String,Any}`，程序/语料调用 | 依赖解码对象为Dict，部分嵌套对象也被严格检查 | 仅外层转换可能留下内部JSON.Object | 在统一解析边界递归得到约定字典；内部输入类型仍严格验证 |
| 序列化往返当规范化 | `ProgramSemantics.jl: program_corpus_key / recover_program_jobs!` | `JSON.parse(JSON.json(...))`后用于semantic_hash/canonical_bytes | 库默认容器/数字/字段序可能改变身份 | 使用项目既有规范编码合同，剥离通用JSON默认行为；仍需往返时统一新入口，逐fixture验证 |
| 用JSON文本比较对象 | `LocalEffects.jl`约256行 | 两次 `JSON.json(public_effect_record(...))`字符串比较 | 字典顺序/数值格式可造成伪不相等 | 用明确规范内容比较，不把普通JSON输出顺序当语义 |
| 普通JSON输出参与ID | `JointMechanisms.jl: joint_model`、`OnlineSession.jl`若干状态键 | `content_hash(JSON.json(...))` | 同义值可能因编码改变换ID；混用会影响程序/索引 | 按身份种类区分原始字节摘要与规范定义摘要，迁移所有同类调用，必要时离线派生索引重建 |
| 非有限与大数 | 全部协议数值入口 | 旧解析容许更多非标准数值/只覆盖部分数类型假设 | NaN/Inf、BigInt/BigFloat与域检查不匹配 | 非有限协议数拒绝；有理数按字符串分子分母传；域内整数范围显式检查，不能窄化溢出 |
| 持久写入正确性 | `RunStore.atomic_write` | 已有file fsync、rename、directory fsync | 改序列化时若重写存储层可能倒退 | 保留既有持久化路径，只统一内容编码与解码，不新造数据库 |

[JSON官方迁移文档](https://juliaio.github.io/JSON.jl/stable/migrate/)明确说明默认Object、allownan默认false、整数/浮点类型及结构体序列化的变化；本项目应逐调用迁移，不能只依据兼容标志推断运行正确。

## 4. 可落实的迁移步骤

### 步骤A：固定输入与身份基线

1. 从实际当前实施提交读取Project/Manifest和全部 `JSON.` 调用。执行 `rg -n 'JSON\.|canonical_bytes|semantic_hash|content_hash' julia scripts tests`，逐项区分协议、原始证据、规范定义、诊断显示。
2. 保存现有协议v3 fixtures、公开事件字节摘要、相同定义不同字典插入顺序的规范ID、库manifest及一次学习作业回读结果；只使用无凭据的测试数据。
3. 运行旧版本现有测试并记录真实退出码。原始证据和历史commit不修改；新实现也不同时维护旧JSON分支。

### 步骤B：正确改变依赖图

应用项目增加Compose为显式直接约束，记录其uuid `a81c6b42-2e10-5240-aca2-a61377ecd94b`，因为应用现在需要固定这项传递依赖修复；在支持 `[sources]` 的既定Julia工具链中固定来源：

```toml
[compat]
JSON = "=1.13.4"
Compose = "=0.9.7"

[sources]
Compose = {url = "https://github.com/GiovineItalia/Compose.jl", rev = "139021151ab8cc4bafb3b8fe88c4fd659f734cf3"}
Galley = {url = "https://github.com/finch-tensor/Galley.jl", rev = "8eefbb52c64c9dd1f7cad39e30c9541a9ab9dc56"}
```

这是应并入现有Project对应表的片段，不是覆盖整个Project，也不是本轮已生成锁文件。Galley的uuid由固定源Project读取，不手填猜测。保持Catlab/ACSets/GATlab/AlgebraicRewriting的已验证应用版本；如Pkg报告冲突，记录完整依赖路径并修复具体约束，不引入旧版fallback。

在已编辑的应用项目中用Pkg一次解析选定源码和包，例如拟增 `scripts/migrate_json_dependencies.jl` 执行：

```julia
import Pkg
Pkg.activate("julia/TddESCat")
Pkg.add([
    Pkg.PackageSpec(url="https://github.com/GiovineItalia/Compose.jl",
                    rev="139021151ab8cc4bafb3b8fe88c4fd659f734cf3"),
    Pkg.PackageSpec(name="JSON", version=v"1.13.4"),
    Pkg.PackageSpec(url="https://github.com/finch-tensor/Galley.jl",
                    rev="8eefbb52c64c9dd1f7cad39e30c9541a9ab9dc56"),
])
Pkg.resolve()
Pkg.instantiate()
Pkg.precompile()
```

记录实际命令 `julia --startup-file=no --project=julia/TddESCat scripts/migrate_json_dependencies.jl`。本脚本是待实施方案；当前会话没有Julia，未执行。禁止手编辑Manifest假装解析成功。后续接PDDL/规划器时重复整图校验，不使用浮动master。仓库自己的remote不改动，GitHub代码提交仍经connector。

### 步骤C：统一新解析合同与规范编码

拟采用统一边界函数（放现有RunStore或项目现有协议模块）：

```julia
read_json(path) = JSON.parsefile(path; dicttype=Dict{String,Any}, allownan=false)
parse_json(text) = JSON.parse(text; dicttype=Dict{String,Any}, allownan=false)
```

这是明确选择新的统一输入类型，并非加载失败后的旧版兜底。按协议逐字段验证类型/范围/未知值。普通输出继续 `JSON.json`；正式身份使用项目自己的规范字节规则，包括类型标签、键排序、变量顺序、整数字符串、精确有理数和作用域。不能把`Float64`转字符串误当精确有理数规范编码。

协议语义/编码未改变时保持v3及既有规范ID；若某项既有规范确实不足，明确变更协议、提供独立一次性迁移工具和映射验证，不能在同一版本静默变化。原始HTTP字节hash永远按原字节保留。新worker协议compute/v1独立增加，不占用原E-Stitch v3身份。

### 步骤D：回归与真实消费者

- Julia旧有测试和预检必须重新通过，尤其范畴构造、公开JSON请求、程序语料回读及库恢复。
- Compose固定修复的真实加载及字体/文字宽度相关调用至少做一个非图形服务的最小测试，确认其JSON读取不会因容器改变失败。
- Galley实际连接/归约运行，确认升级不是只为满足版本字符串。
- 原公开事件回放、已完成E-Stitch job回读与规范身份对照；涉及变更身份的派生缓存显式重建，不能偷偷沿用。
- I01/I02与P01/P06/P07保存命令、实际结果及阻断项，才可将12的代码迁移标为完成。

## 5. 交付与未完成边界

实际代码迁移提交应包含：Project、真实生成Manifest、来源锁、统一解析修改、被影响的规范身份/内容比较调用、独立测试和当日中文迁移日志。不会复制旧JSON实现，也不为避冲突降低主算法参数。

**本轮完成的是依赖原因调查、官方修复定位、真实源码影响分析与可执行迁移计划。JSON运行代码仍是当前分支的0.21合同；新环境解析、构建、测试未执行。** 这是实现待办，不能标成已经升级或已经无兼容问题。
