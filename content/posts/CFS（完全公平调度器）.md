## CFS（完全公平调度器）

**完全公平调度器（Completely Fair Scheduler, CFS）**，负责CPU时间的动态分配

CFS的调度决策基于一个极其简单的规则：**在任何时刻，调度器总是选择当前运行队列中vruntime值最小的任务来执行。**

### **vruntime**

为了量化每个任务获得的“公平份额”，CFS引入了其核心概念——**虚拟运行时间。**vruntime是一个64位的、以纳秒为单位的数值，存储在每个任务的调度实体结构（sched_entity）中，具体为p->se.vruntime字段。

vruntime在加权意义上，是至今为止被服务得最少的任务，所以立刻调度。这种加权机制是通过用户可调整的nice值来实现的。对于一个高优先级任务（被nice决定的load.weight很大），其vruntime的增长速度会**慢于**物理时间的流逝，反之则反。

- `load.weight = 1024 / (1 << (nice + 20))`
- `vtime = 实际运行时间 × (1024 / load.weight)`

到这里已经实现了加权调度了，但还有两个问题，因为所有进程的vruntime都在随着时间增长而变大，因此一个刚被加入到队列的进程和刚从睡眠中唤醒的进程，他们的vruntime是落后均值的，因此需要做一些适配。

**最小虚拟时间（min_vruntime）：**当一个新任务创建加入运行队列时，它的初始vruntime不会被设置为0，而是被设置为当前运行队列的min_vruntime值 ，该值记录了当前队列中所有任务的vruntime的最小值。这种特性确保了同一运行队列中所有任务的vruntime值保持在一个相对紧凑的范围内

**睡眠者公平性（sleeper fairness）：**CFS的唤醒抢占机制允许一个刚被唤醒的任务（`T`）抢占当前正在运行的任务，让刚醒来的任务立即获得一次“优先调度”，但又不能无限插队，避免饿死正在运行的任务。

- 具体公式：`vruntime(T) = max(vruntime(T), min(vruntime(∗)) − L)`，`L(called“ thresh” in kernel) = 24ms/2 = 12ms`

### **rb-tree**

CFS的每个CPU的运行队列（cfs_rq）都是一颗**红黑树（red-black tree）**

这棵红黑树并非按任务的优先级或到达时间排序，而是**严格按照任务的vruntime值进行时间排序** 。树中的每个节点都是一个sched_entity结构体。根据红黑树的特性，vruntime最小的任务（即最需要被调度的任务）总是位于树的最左侧节点。

- **任务管理（入队/出队）：** 当一个任务变为可运行状态（例如，新创建或从I/O等待中唤醒）时，需要将其插入红黑树。当一个任务阻塞（例如，开始等待I/O）或终止时，需要将其从树中移除。这两项操作的时间复杂度均为O(logN) 
- **任务选择（pick_next_task）：** 选择下一个要运行的任务，即寻找vruntime最小的任务，操作极其高效。调度器只需选择红黑树的最左侧节点即可。而CFS的cfs_rq结构中已经缓存了一个指向最左侧节点的指针（rb_leftmost），因此取最小实际上是**复杂度为O(1)的操作，无需遍历。**

为什么不用O(1)查找的最小堆？

答：进程调度场景里，任务因为阻塞而挂起（如等待磁盘读取或网络数据包）非常频繁 。最小堆虽然查得快，但“删任意元素”几乎是On，太慢了

### 调度策略

CFS是Linux中`SCHED_NORMAL`调度策略的实现者，历史上叫 `SCHED_OTHER`，适用于普通任务的调度。CFS还管理着几个子策略，以应对不同类型的负载：

- **SCHED_BATCH：** 该策略专为非交互式的、CPU密集型的批处理作业设计。调度器会认为这类任务对延迟不敏感，不像普通任务那样容易被抢占，因此每个任务运行的时间可以更长，缓存效率更高，但交互性变差，适用于科学计算、代码编译等后台任务 。
- **SCHED_IDLE：** 该策略用于优先级极低的后台任务。这些任务只应在系统完全空闲，没有任何其他工作可做时才运行。它们的调度不受nice值影响，能分到的cpu时间比例很低，但也是总能分到。

## Cgroup的CPU子系统

cgroups 是 Linux 内核提供的一种可以限制单个进程或者多个进程所使用资源的机制，可以对 CPU、内存等资源实现精细化的控制。Linux 下的容器技术主要通过 cgroups 来实现资源控制。其中和cpu有关的是以下三个

1. cpu 子系统，主要限制进程的 cpu 使用率。
2. cpuacct 子系统，可以统计 cgroups 中的进程的 cpu 使用报告。
3. cpuset 子系统：通过将 CPU 核心编号写入 cpuset 子系统中的cpuset.cpus文件或将内存 NUMA 编号写入 cpuset.mems文件，可以限制一个或一组进程只使用特定的 CPU 或者内存，从而实现实现了对硬件资源的硬分区（hard partitioning）

本节主要介绍cpu子系统，专注于管理CPU时间的分配。

### 控制CPU时间

- **相对份额（软限制）****`cpu.shares（v1）或cpu.weight（v2）`****：**定义了一个cgroup相对于其他cgroup可以获得的CPU时间的**比例权重** 。这个机制只有在系统CPU资源出现争用时才会生效。如果CPU空闲，任何cgroup中的任务都可以使用全部可用的CPU资源，无论其份额设置如何 。
- **绝对带宽限制（硬限制）**：**`cpu.cfs_quota_us / cpu.cfs_period_us（v1）或cpu.max（v2）`****：**这组参数为cgroup设置了一个**CPU使用上限** 。一旦配额用尽，该cgroup中的任务就会被**节流（throttled）**，直到下一个周期开始。份额与带宽这两种机制可以独立使用，也可以结合使用
- **突发限制****` cpu.cfs_burst_us (v1)`****和****`cpu.max.burst(v2)`****：**进程在CPU上执行时，可能会短时间内突然增加CPU使用量，linux可以允许进程在一个周期内使用额外的CPU时间，但需要在后续的周期内找补回来。该参数即用于控制Burst的上限，

### 监控CPU使用

为了有效地管理CPU资源，监控cgroup的状态至关重要。

- **`cpu.stat (v1 & v2)`**：这个文件提供了关于带宽限制的关键信息。
  - nr_periods：已经过去的调度周期数。
  - nr_throttled：cgroup因超出配额而被节流的次数。
  - throttled_time (v1) / throttled_usec (v2)：cgroup中任务被节流的总时长 。
  -  监控nr_throttled和throttled_time是诊断应用性能问题（如延迟增加）的关键
- **`cpu.pressure (v2)`**：cgroup v2引入了压力阻塞信息（Pressure Stall Information, PSI）接口。cpu.pressure文件可以显示由于CPU资源不足，任务等待运行的时间百分比，用来判断CPU争用的激烈程度

## Pod 的CPU Spec、CPU子系统和CFS的关系

### Pod 的CPU Spec是什么

- `requests`：表示 Pod 所需的最小 CPU 资源保证。Kubernetes 会根据这个值为 Pod 分配 CPU 资源。
- `limits`：表示 Pod 可以使用的最大 CPU 资源。如果 Pod 的 CPU 使用量超过这个值，它会被限流`throttled`。
- 二者都表示逻辑上的cpu个数。其中若request和limit都为整数且相等，k8s会为其调用cpuset绑定对应数量的cpu核心。

###  Pod 的CPU Spec与CPU子系统的关系

- `requests`:Pod 的`requests`是 Pod 所需的最小 CPU 资源保证，k8s会根据 Pod 的`requests`值设置 `cpu.shares`。`requests` 越大，`cpu.shares` 的值也越大，从而为 Pod 分配更多的 CPU 时间
- `limits`：Pod 的`limits`用于定义 Pod 可以使用的最大 CPU 资源，Kubernetes 会将每个容器的 CPU limits 累加后作为 Pod 级别的 `cpu.cfs_quota_us` 值，而 `cpu.cfs_period_us` 通常是一个固定值（默认 100 毫秒），由 kubelet 配置

### CPU子系统与CFS的关系

cpu子系统和CFS直接相关，它利用并扩展了CFS的组调度功能 。

- **`cpu.shares`**：`cpu.shares`的值被用来计算cgroup对应的`sched_entity`的`load.weight `。这使得CFS的公平性算法能够自然地扩展到cgroup层级。调度器首先在顶层cgroup之间根据它们的权重分配CPU时间，然后在每个cgroup内部，再根据其子cgroup或内部任务的权重进行下一级的分配 。
- **`cpu.cfs_quota_us / cpu.cfs_period_us（v1）或cpu.max（v2）`****：**一旦周期内的配额用尽，该cgroup中的任务就会被**节流，**直到当前period结束才会重新加入调度队列。
- **层级rb-tree和vruntime**：CFS为每个cgroup维护一个独立的红黑树队列和vruntime。当一个cgroup被调度运行时，它获得的物理时间会根据其权重更新其vruntime，然后这部分时间再被分配给其内部的任务或子cgroup，并相应地更新它们各自的vruntime。层级化的vruntime计算确保了整个cgroup树的公平性。

### CFS配置与内核调度延迟的关系

### [K8S CFS Configuration Support](https://bytedance.larkoffice.com/wiki/wikcnpUCcugmop9PFvg6KF1ICAe)

Kubernetes使用Linux内核的完全公平调度器(CFS)实现CPU资源限制。默认情况下，CFS在100毫秒的周期(cfs_period_us)内强制执行容器的CPU配额(cfs_quota_us)。当容器在一个周期内用尽配额时，所有进程将被节流(Throttled)直到下一个周期开始。如果有容器的CPU使用飙高，很容易出现限流，而这样的延迟增加是period级的，动辄100ms，可能会引发如下问题。

- 请求响应时间延长(RTT增加)
- 活性探测失败导致容器重启
- 微服务调用链超时
- 垃圾回收停顿延长
- 网络连接中断

多线程应用在不绑核时下问题更严重，以 十个线程并行运行在十核心CPU上、pod侧设置逻辑limit为2的场景为例：

- 每个线程在独立核心上运行时，第一个20毫秒就累计消耗200毫秒CPU时间（用完period=100ms的两个逻辑CPU）
- 超出配额后，所有线程被同时节流80毫秒
- 原来50ms的任务可能需要执行210ms才完成
- 核心矛盾是pod通过逻辑CPU数量来设定资源限制，而内核通过划分CPU使用时间来执行限制

另外，影响在服务开启超售的情况下也会变严重：

- 超售导致 Share 变小，share = user_demand / overcommit_ratio * 1024

如何解决限流问题和调度延迟的问题呢？

1. Request角度
   1. 将Request 和 Share 计算解耦 
   2. 针对个别延迟极敏感服务
   3. share 在 request 基础上给予一定 burst ratio的扩大
2. Limit角度
   1. 纵向，比值增大: 调大 cfs_quota_us、调大cfs_quota_us/cfs_period_us 
   2. 横向，比值不变: 调大 cfs_period_us, 保持 cfs_quota_us/cfs_period_us
   3. 经过引用文档的实验，发现调度延迟更关心被 trottle 的次数而不是被挂起的时间
   4. 因此横向调整效果更佳，相当于扩大了“缓冲区”，增加了对burst的宽容度
3. go程序调优角度
   1. 设定GMP的并发写协程为

### 待调研

1. 为什么不直接用**`cfs_burst_us`**配置呢