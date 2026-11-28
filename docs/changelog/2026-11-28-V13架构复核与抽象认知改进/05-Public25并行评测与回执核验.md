# Public25 并行评测与回执核验

2026 年 11 月 28 日在 82 上启动 25 款新版游戏，另开两款旧版作冷启动配对。正式求解器固定在 `2c87e7eddc61dc0bfd0d23027e9dbea99c881208`，旧版固定在 `59efbcd5299e2cd0e6bf85b23f4e82fb65bb0e86`。两组使用同一套公开游戏文件、配置和无限动作预算。两款配对游戏是 lf52 和 wa30，各自使用新实例。调度代码位于 `scripts/public25_cpu/`，不参与求解器的动作选择。

## 并行度实测

82 的 Linux 来宾配有 32 个虚拟 CPU 和 96 GiB 内存。CPU 5–29 各承担一款新版游戏，30、31 各承担一款旧版游戏。评测进程、Julia 求解器及其用户态工作线程分别核过 CPU 掩码，另测了 E-Stitch 子服务能继承同款游戏的绑核。

| 实测量 | 观察值 |
| --- | --- |
| 同时存活的新版游戏进程 | 25 个 Julia 求解器和 25 个 SDK |
| 新版 SDK 首次就绪耗时 | 最短 49.75 秒，中位 51.54 秒，最长 53.78 秒 |
| 来宾内 14.447 秒窗口 | 25 款新版各有 CPU 消耗，合计平均 24.376 个核。两款旧版平均另占 1.999 个核 |
| 宿主独立 10.021 秒窗口 | 25 个对应的虚拟 CPU 线程均有运行计时，合计平均占用 20.242 个宿主逻辑核 |
| 内核辅助线程 | 每个 Julia 进程有一个禁止更改亲和性的线程，来宾采样窗口内这些线程累计消耗 0 CPU 秒 |

台北时间 11:27 的来宾采样中，旧版两款均已确认 RESET，新版当时确认的普通游戏动作数为 0。CPU 统计证明同一时段在并行执行；小关和整局结果需随后从回执读取。逐款绑定、进程、SDK 就绪时间、原始采样 SHA-256 和宿主计时见 [Public25 并行度实测](evidence/Public25并行度实测.json)。

## 运行和复核

在具备本次两份冻结 checkout、对应工具链和公开 SDK 资源的来宾内，以下命令可为独立的新批次做预检并启动。本次正式输出目录为 `/home/solver/public25-v13/runs/parallel-32cpu-2c87e7ed-59efbcd5`。已有批次可直接执行只读核验。

```sh
ops=/home/solver/public25-v13/ops
candidate=2c87e7eddc61dc0bfd0d23027e9dbea99c881208
baseline=59efbcd5299e2cd0e6bf85b23f4e82fb65bb0e86
py=/home/zdx/github/VSAHDC/worktree/TddESCat-v13-candidate-2c87e7ed/.venv/bin/python
new_run=/home/solver/public25-v13/runs/independent-repeat
"$py" "$ops/parallel-public25.py" dry --candidate "$candidate" --baseline "$baseline" --output "$new_run"
"$py" "$ops/parallel-public25.py" run --candidate "$candidate" --baseline "$baseline" --output "$new_run"
```

本批次复用了同版旧基线的工具链资格，经校验后仍为两款基线各建空局。独立运行可省略 `--baseline-qualification`，由运行器重新验证。每款游戏的评测进程由独立 systemd 单元持有，CPU 维护器核对其单独启动的求解器与程序搜索服务。

```sh
run=/home/solver/public25-v13/runs/parallel-32cpu-2c87e7ed-59efbcd5
"$py" "$ops/public25-process-report.py" --output "$run" --threads --sample-seconds 10
"$py" "$ops/audit-live-public25.py" "$run"
```

只读审计按游戏及尝试核对命令、事件和回执内容哈希。活跃场分别报告确认 RESET、确认普通动作和各游戏已见最高小关。正式 WIN 还需要评测和回放成功退出，并核对最终回执、计分卡以及游戏 ID 和 GUID。报告中的 `peak_levels_sum` 为各款最高已完成小关之和。
