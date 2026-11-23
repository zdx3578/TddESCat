# cgnav 有限语义核验

日期：2026-11-23，台北时间。此目录是论文代码核验材料，不是 ARC3 运行组件，也不引入 Python 认知栈。

## 输入与复现

通过 GitHub connector 读取 [koetters/cgnav 固定提交](https://github.com/koetters/cgnav/tree/816e514d24467cfd2ec29494c44a901d885d8f75) 的 cgnav.py、resources/family_relations.pcf 和 LICENSE，保持目录关系放到配置的 source_dir。原始源码不作修改。本目录不再分发作者源码或依赖安装目录。

依赖是 Python 3.12.14 与 pygraphviz 2.0.4。可以用 pip 的 --target 参数把 pygraphviz 安装到配置指定的 dependency_dir；编译依赖需环境具备 Graphviz。不要将下载源码、依赖或缓存提交。

配置中的 source_dir 是作者源码目录；dependency_dir 是隔离依赖目录；output_file 是结果输出位置。三个路径都相对配置文件。source_commit 记录固定版本，source_sha256 是执行前必须匹配的 cgnav.py 校验值。它们全部写在 JSON 配置，不用环境变量。

运行：`python cca-probe.py cca-probe-config.json`。需要使用已有下载目录时修改配置路径即可。脚本不修改作者源码，输出包含所用版本、官方样例数量和五项独立同态对照。

## 本轮结果与边界

官方家庭样例得到 9 个概念，符合 README 的数量。五项有限同态对照中，两项一致、三项不一致。后者不是发生比例或整个库的质量分数，而是定向构造的反例。

同态 oracle 枚举所有源节点到目标节点的函数，检查节点属性、全部公开角色及每一关系元组的标签。允许不同源节点映到同一个目标节点；这些测试不额外要求单射。所有用例把两图词表统一，避免把不同签名误当同一问题。

不连通与多窗口用例超出作者建格声明的单窗口范围；关系标签用例在同词表、单窗口、连通图内，仍应拒绝却被接受。原源码 matches 没有核对边的关系标签。见上级 20 文档第 3 节。

时间字段只记录本次执行，不作为性能或可扩展性结论。完整概念语义、一般图实例、项目集成和 ARC3 运行均未由此核验。
