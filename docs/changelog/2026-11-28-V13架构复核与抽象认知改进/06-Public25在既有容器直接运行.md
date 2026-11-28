# Public25 在 82 的既有容器直接运行

评测从 `ssh 82` 得到的现有 Docker 环境启动。显式指定 `--native-docker` 时，启动器在该环境中直接启动 SDK、Julia 和 E-Stitch。25 款分别使用独立的本地回环端口、证据目录和 CPU。启动器把内存执行模式投影为 `cooperative`。E-Stitch 已声明的内存上限由 `prlimit` 施加为进程地址空间上限。隔离边界是既有容器，清单记录了这一模式。

求解器基点为 `2c87e7eddc61dc0bfd0d23027e9dbea99c881208`。原有动作选择、官方 SDK、事务回执、回放和计分卡读取路径继续用于此批。使用 Public25 原任务目录和不限动作预算。以下命令从已配置 `config/runtime.local.toml` 及依赖的 checkout 执行。

```sh
.venv/bin/python -m scripts.evaluate_public25 \
  --native-docker --precompile-online --workers 25 \
  --bundle /home/zdx/github/VSAHDC/TddESCat/.runtime/public25-native/bundle \
  --output /home/zdx/github/VSAHDC/TddESCat/.runtime/public25-native/runs/public25-native-2c87e7ed
```

台北时间 14:55:51 启动入口，派发前共享的 Julia 准备耗时 278.46 秒。15:01 核实 25 个原生 Julia 进程处于各自指定的 CPU，25 个 SDK 分别监听本地端口。15:03:26 核实 25 款各有一个普通动作的确认回执。从逐款评测启动到首步的中位数是 78.84 秒，从确认 RESET 到首步是 31.64 秒。将 ar25 的首段回执复制出来后，原回放入口独立应用了 2 个事件。[逐款启动、回执哈希与回放](evidence/Public25直接运行首步复核.json)

此前的 QEMU 批次使用另一个运行目录。此前发表的 90 分 19 秒为该批次的首步中位耗时。以上时间按各自的已确认回执统计。

旧版比较固定在 `59efbcd5299e2cd0e6bf85b23f4e82fb65bb0e86`。准备好的旧版 checkout 中可以运行 `python -m scripts.public25_cpu.run_native_pair`，传入 `--bundle`、`--candidate`（新版输出目录）和独立的 `--output`。它核对两版的 SDK 目录清单、配置、学习策略和 E-Stitch 二进制，选两个尚未分给新版的 CPU 派发。两款依然使用空实例和不限动作预算。

台北时间 15:15 核验，原生旧版的两款都已确认 ACTION1。独立比较读回双方的首帧、动作和完整动作返回帧，lf52、wa30 各有一个匹配的 RESET 和一个匹配的普通动作。
