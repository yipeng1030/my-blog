

它是一种I/O控制器，可以根据程序优先级为块设备上的I/O操作分配带宽，并且可以通过设置权重值来限制特定应用程序或进程对块设备的I/O带宽使用。

## 一、背景

长期以来，I/O 控制器（如 cgroup v1 的 blkio 和 cgroup v2 的 io.throttle）主要依赖于两个简单指标：带宽（BPS, Bytes Per Second）和每秒 I/O 操作数（IOPS）。然而，在现代存储设备上，这些指标已不足以实现公平、高效的资源分配。其根本缺陷在于，它们无法衡量不同 I/O 操作对设备造成的真实“成本”或“压力”。

一个 4KB 的随机写入请求与一个 1MB 的顺序读取请求，虽然在 IOPS 和 BPS 上有明确的度量，但它们对存储设备的内部资源（如控制器、缓存、FTL 映射表、NAND 闪存通道）的占用是截然不同的。特别是对于机械硬盘，寻道成本占主导地位；而对于 SSD，内部并行性、垃圾回收（GC）和写入放大等因素使得成本模型更为复杂 。   

因此，一个基于 BPS/IOPS 的静态限制策略往往会陷入两难境地：该限制可能同时“过高又过低”。例如，一个 IOPS 限制可能无法阻止大量小尺寸随机 I/O 耗尽设备的命令处理能力，从而导致延迟急剧上升；而一个 BPS 限制又可能不必要地扼杀了设备本可以高效处理的大尺寸顺序 I/O 吞吐量。这种“一刀切”的方法是一种粗糙的、通常效果不佳的工具。  

## 二、IOCost核心概念

其核心创新是将控制指标从 BPS/IOPS 这种人为的、与设备无关的单位，转变为一个更根本的、与设备特性紧密相关的单位：预估的设备占用成本 (estimated device occupancy cost)，通过vtime调整以进程为单位调整一个io的相对时间成本，进而实现优先级。

iocost 的基本思想是为每一个 I/O 请求估算一个“成本”，这个估算的依据来源于用户和Iocost子系统对磁盘的动态评估，这个成本代表了该 I/O 将占用设备多长时间。通过这种方式，iocost 为所有不同类型（随机/顺序、读/写、大小不同）的 I/O 操作提供了一个对成本进行比较的方式。

### 2.1 设备感知

对于每个设备，IOCost引入了一个成本模型和一组服务质量（QoS）参数，以定义和规范设备行为。

#### **io.cost.model-成本模型**

块设备级，显式告诉内核该设备的各种性能上限以便其建立“成本模型”。以下是线性模型的几个参数。

| rbps/wbps           | 最大顺序读写带宽（Byte/s） |
| ------------------- | -------------------------- |
| rseqiops/wseqiops   | 顺序读写最大 IOPS（4K）    |
| rrandiops/wrandiops | 随机读写最大 IOPS（4K）    |

- 语义：per-device，帮助计算“完成一次 IO 要花多少虚拟时间”。
- 离线阶段：跑 fio/基准测试，把线性系数（斜率、截距）算出来并写进 /sys/fs/cgroup/…/blkio.cost.model；
- 在线阶段：model 不再改动，只在“快路径”里作用在计算每次IO的绝对成本的过程，用来扣减 cgroup 预算。

#### **io.cost.qos-服务质量参数**

也是块设备级别的，可以理解为开始限流的“水位”，只不过依据是分位延迟计算的。

```Bash
echo "254:48 enable=1 ctrl=user rpct=95 rlat=10000 wpct=95 wlat=10000 min=50 max=150" \> /sys/fs/cgroup/io.cost.qos
```

- 语义：per-device，描述“这块盘要满足的延迟/带宽 SLA”。
- 完全由用户给定：例如 p99_read_lat ≤ 20 ms ——“读延迟 p99 不能高于 20 ms”。
- 机器不能改 qos，但会：
  - 离线：根据用户 qos 跑 RCB → 得到 vrate 区间 [L, H]；
  - 在线：在规划路径里把 vrate 限制在 [L, H] 内，从而“间接兑现”qos

### 2.2 负载感知

对于工作负载，IOCost利用cgroup权重进行比例配置。这使得工作负载的配置独立于设备的复杂性，提高了异构环境中大规模配置的便利性和稳健性。

####  **io.weight—按比例权重：**

这是最主要的面向用户的配置项。管理员不是为 cgroup 设置绝对的 BPS/IOPS 上限，而是分配一个相对权重（范围 1-10000，默认 100）。当多个 cgroup 同时竞争 I/O 资源时，iocost 会根据它们各自的权重占总权重的比例来分配设备的总容量。

- 语义：per-cgroup，表示该 cgroup 在“全局预算池”里占的相对份额。
- 用户给定初值；
- 内核在规划路径里通过 donation 把闲置权重临时清零，等效动态调节，但不会永久改写用户写的值。

#### **donation-捐赠：**

对于active cgroup分配了带宽没用满的情况，有盈余的cgroup会把自己的多余的份额捐给其他紧张的cgroup，来用户无感地最大化带宽利用率。

若某一周期内cgroup H只能占用15%的带宽，但是它有35%的配额，那么它会贡献出20%的带宽给parent，parent cgroup会统计自己拿到的所有donation，然后按weight比例和实际需求公平的分配给子cgroup。当优先满足子cgroup的需求后还有多余，就贡献给再上一级的cgroup去权衡如何分配。

#### **debt-账单：**

进程间可能有共享的全局资源，例如大粒度的全局锁或像node这种共享的META数据，IOCost不能对其进行限速，否则低优先级对其的读取会反而阻塞高优先级，这就是进程优先级反转故障。

因此iocost引入了debt负债机制：当kernel发现是REQ_META和REQ_SWAP类型的io请求时，iocost会记录当前io请求的abs_cost然后跳过sleep立刻返回，优先将这类请求下发到磁盘驱动。跳过的这些abs_cost时间属于当前cgroup的”欠款“，记录在一个per cgroup的账单上，cgroup需要将其还清才能继续下发io请求。

### 2.3 io下发

#### **vtime-虚拟时间**

系统中存在一个全局的 vtime 时钟，同时per cgroup也维护一个本地虚拟时钟，这个本地时钟只由ta发出的io请求的相对成本所推动，也就是反应其使用磁盘的时间。每当一个周期开始，cgroup试图下发io请求前，Iocost都会先比较其本地时钟和全局时钟的差距，如果本地时钟过快，就会延迟这个io直到下次周期再比较。

因此全局时钟前进的速度就十分重要，它以一个可调的速率 (vrate) 前进。这个可调速率直接正比例地影响设备io下发速率。Iocost实际上就是通过调整vrate来限制io下发速率，进而保证磁盘的服务质量的。

## 三、工作流程

为了应对现代 NVMe SSD 每秒数百万次 I/O 操作（IOPS）的巨大压力，iocost 采用了巧妙的双路径架构，将决策过程分离为快速路径和慢速路径 。   

![img](https://bytedance.larkoffice.com/space/api/box/stream/download/asynccode/?code=YzM2ZGRmNzRhMTc2YTc0OGIxZDE0NjZlMmJiNGQ1ZTVfcjhxS1RXSGNLTk9oQlVCN0hkeW82QjB4UGM0cnZZM1JfVG9rZW46RjdaTWJQeEtGbzdhU0x4c1FqTWNaVURBbmFjXzE3NTkwMzg1NDA6MTc1OTA0MjE0MF9WNA)

### **“签发路径” (Issue Path, ~µs 级别)：**

是处理每个 I/O 请求 (bio) 的快速通道。当一个 bio 到达时，签发路径会基于预先配置好的成本模型，进行一次非常廉价的成本计算，并迅速决定是立即分派该 I/O 还是进行节流。此路径的目标是将延迟开销降至最低，确保控制器本身不会成为性能瓶颈。

1. iocost接收一个bio，bio是一个描述io操作的请求
2. iocost从bio中提取特征，使用成本模型计算绝对成本
3. 绝对IO成本除以cgroup的层次权重（hweight），得出相对的IO成本
4. 展示了一个全局vtime时钟，它以虚拟时间率（rate）指定的速率前进。每个cgroup跟踪它的本地vtime，在每个IO上按IO的相对成本推进
5. 代表了基于本地vtime落后于全局vtime的程度的节流决策。这个差距代表一个cgroup的当前IO预算。如果预算等于或大于一个IO的相对成本，则立即发出该IO。否则，该IO必须等待，直到全局vtime追上来

### **“规划路径” (Planning Path, ~ms 级别)：**

这是一个较慢的、周期性运行的后台路径。它负责收集和分析设备在一段时间内的行为（如 I/O 完成延迟）和各个 cgroup 的资源使用情况。基于这些统计数据，规划路径会做出战略性调整，例如修正整体的 I/O 速率、管理预算捐赠等，以确保系统能够适应变化的负载和模型本身的误差 。  

1. IOCost根据设备反馈调整全局vrate，进而等比例放大/缩小所有 cgroup 在下个周期内的 IO 预算
2. IOCost的捐赠算法把“非活跃 cgroup”权重临时清零，把节省下来的预算捐给活跃 cgroup，保证设备利用率，而无需在热点路径做复杂计算

### **离线Offline：**

1. 为每块盘生成一对（cost 模型，QoS 参数）
   1. 用 fio 等工具跑基准测试，把设备的“IO 成本模型”写成线性公式或者 eBPF 程序；
   2. 再用官方工具 ResourceControlBench 跑两种典型场景（独占、与内存泄露容器混部），确定 vrate 范围——下限保证延迟不再恶化，上限保证吞吐量不再有收益——QoS 参数就落在两条边界之间

## 四、参考

- https://zhuanlan.zhihu.com/p/691568250
- 论文原文：https://www.cs.cmu.edu/~dskarlat/publications/iocost_asplos22.pdf