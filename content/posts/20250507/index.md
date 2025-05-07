+++

date = '2025-05-07T11:22:12+08:00'
draft = false
title = 'Kube-Scheduler 深度解析：从源码看 Kubernetes 调度核心'

+++

Kubernetes 的 kube-scheduler 是集群的中枢决策者，负责为每一个新创建的、未指定节点的 Pod 选择最合适的运行节点。这一决策过程对集群的效率、应用性能和整体可靠性至关重要 1。本文将深入 kube-scheduler 的内部机制，通过分析其 Go 语言源代码，揭示其从启动、核心调度逻辑到高度可扩展的调度框架的演进与实现。Kubernetes 的调度器经历了从相对单一的设计到高度可扩展的调度框架的演变，这是理解其当前强大能力的关键 3。

调度器的设计直接影响着集群上运行的应用程序的可用性和资源利用率。如果 Pod 被放置在不合适的节点上，可能会导致某些节点资源紧张而另一些节点资源闲置，或者违反 Pod 间的亲和性与反亲和性规则，进而影响应用的通信效率或容错能力。因此，深入理解调度器的工作原理，有助于更好地配置和排查问题，最终提升集群的整体表现。早期版本的调度器逻辑相对固定，难以满足日益增长的定制化需求 4。虽然之后引入的 Extender 机制提供了一定的扩展能力，但在性能和灵活性上仍有局限 4。调度框架的出现，允许开发者通过插件将自定义逻辑直接注入调度流程，这不仅促进了相关生态系统的繁荣，也使得核心调度器能够保持精简和易维护，同时满足多样化的调度需求，例如针对机器学习、批处理作业或需要特定硬件的工作负载 5。

## 一、 启动流程：Kube-Scheduler 的初始化与核心组件构建

理解 kube-scheduler 如何初始化自身及其主要数据结构，是深入其调度逻辑的前提。

### 1.1 启动入口与命令解析

kube-scheduler 的启动入口位于 `kubernetes/cmd/kube-scheduler/scheduler.go` 文件中的 `main` 函数 7。它利用了 Cobra 框架来处理命令行参数和应用的配置启动。具体来说，`main` 函数会调用 `kubernetes/cmd/kube-scheduler/app/server.go` 文件中的 `app.NewSchedulerCommand` 函数来创建和初始化 Cobra 命令 7。

随后，`runCommand` 函数被调用，它负责编排整个启动过程，包括创建调度器配置 (`CompletedConfig`) 和调度器实例 (`scheduler.Scheduler`)。这一过程的核心是调用 `Setup` 函数 7。`Setup` 函数会验证传入的选项，根据选项创建配置，并最终调用 `scheduler.New` 函数来实例化调度器 7。

这种分层设计体现了良好的软件工程实践。`cmd/kube-scheduler/scheduler.go` 作为顶层入口非常轻量。`cmd/kube-scheduler/app/server.go` 负责解析命令行参数、管理配置选项，并协调 `Setup` 过程 7。而核心的调度器对象及其复杂的初始化逻辑则封装在 `pkg/scheduler/scheduler.go` 的 `scheduler.New` 函数中 7。这种模块化的结构使得各部分可以独立演进和测试，例如，修改命令行参数的处理逻辑，通常不会影响到核心调度算法的实现。

### 1.2 `scheduler.New`：调度器实例的诞生

`scheduler.New` 函数位于 `kubernetes/pkg/scheduler/scheduler.go`，是 kube-scheduler 实例化的核心。在此函数内部，众多关键组件被创建和初始化，为后续的调度工作奠定基础 7。

关键组件的创建包括：

- **插件注册表 (Plugin Registries)**：通过调用 `frameworkplugins.NewInTreeRegistry()` 创建内置插件的注册表，并与通过选项传入的外部插件注册表进行合并 7。这是调度框架能够灵活加载和管理插件的基础。
- **调度器缓存 (`internalcache.Cache`)**：调用 `internalcache.New()` 创建，用于存储节点和 Pod 的状态信息。这个缓存对于提高调度性能至关重要，它避免了每次调度都从 API Server 读取数据，并支持“假定调度 (assume pod)”的乐观策略，即在 Pod 真正绑定到节点前，先在缓存中标记其已分配，从而提高调度吞吐量 7。
- **调度队列 (`internalqueue.SchedulingQueue`)**：通过 `internalqueue.NewSchedulingQueue()` 创建。这是一个优先级队列，其中包含等待调度的 Pod。调度队列内部又细分为几种不同状态的队列，如 `activeQ` (活跃队列，准备被调度的 Pod)、`backoffQ` (退避队列，调度失败后暂时不参与调度的 Pod) 和 `unschedulableQ` (不可调度队列) 7。队列的排序逻辑由调度器配置（Profile）中的排序函数决定。
- **调度配置 (`profile.Map`)**：调用 `profile.NewMap()` 创建。每个 Profile 封装了一套特定的调度框架配置，包括启用的插件集合及其参数 7。Pod 可以通过其 `.spec.schedulerName` 字段指定使用哪个 Profile 进行调度 11。这种设计从一开始就考虑了多调度器配置和针对不同工作负载的定制化调度行为，即便在完整的调度框架成熟之前，这种架构上的远见也为日后的扩展打下了基础。它使得用户可以在单个调度器二进制文件中运行逻辑上不同的调度策略，例如为通用无状态应用和批处理作业配置不同的 Profile。
- **快照 (`internalcache.Snapshot`)**：在每个调度周期开始时，会基于调度器缓存创建一个不可变的快照。这个快照为单次调度决策提供了一致性的集群状态视图，避免了在调度过程中因集群状态变更而引发的竞态条件 7。
- **事件处理器 (Event Handlers)**：调用 `addAllEventHandlers` 注册事件处理器，用于监听集群中 Pod、Node 等资源的变更，并据此更新调度器的内部状态（如缓存和队列）7。

调度器缓存和快照机制是保障调度器高性能和一致性的关键。缓存提供了对节点和 Pod 状态的快速内存访问，避免了与 API Server 的频繁通信。而快照则确保了在单个调度周期内，调度算法所依赖的集群视图是稳定和一致的，这对于做出正确的调度决策至关重要。

## 二、 核心调度流程：从传统两阶段到调度框架

kube-scheduler 的核心任务是为 Pod 选择最佳节点。其调度流程经历了从经典的“预选-优选”两阶段模型到更为灵活和可扩展的调度框架的演进。

### 2.1 传统的两阶段调度：预选与优选

在调度框架引入之前，kube-scheduler 主要依赖一个两阶段的过程来筛选和评估节点 1：

1. **预选阶段（Predicates/ Filtering)**：此阶段的目标是过滤掉不满足 Pod 基本运行要求的节点。调度器会应用一系列预选策略（Predicates），例如检查节点是否有足够的资源（如 CPU、内存，对应 `PodFitsResources` 策略）、节点端口是否冲突（`PodFitsHostPorts`）、节点是否有不可容忍的污点 (Taints) 等 1。在早期的代码实现中，这一逻辑主要由 `k8s.io/kubernetes/plugin/pkg/scheduler/core/generic_scheduler.go` 文件中的 `findNodesThatFit()` 函数负责 1。
2. **优选阶段(Priorities/Scoring)**：通过预选阶段的节点被认为是“可行”的。接下来，优选阶段会对这些可行节点进行打分，以找出“最优”的节点。调度器会应用一系列优选函数（Priority functions），每个函数都会为节点打一个分数（通常在 0-10 或 0-100 的范围内）。最终，每个节点的总分是所有优选函数得分的加权和 1。得分最高的节点将被选中。如果多个节点的得分相同，通常会从中随机选择一个 1。早期版本中，此逻辑主要由 `PrioritizeNodes()` 函数实现 1。

### 2.2 调度框架下的调度周期与绑定周期

随着 Kubernetes Enhancement Proposal (KEP) 624 的引入，调度流程被重构为更为精细的“调度周期 (Scheduling Cycle)”和“绑定周期 (Binding Cycle)” 5。

- **调度周期 (Scheduling Cycle)**：为单个 Pod 选择一个合适的节点。这个过程是串行执行的，即在同一时刻，调度器只为一个 Pod 执行调度周期，以确保决策的可预测性并简化状态管理 5。
- **绑定周期 (Binding Cycle)**：将调度周期选定的节点应用到 Pod 对象上（即更新 Pod 的 `.spec.nodeName` 字段）。绑定周期可以并发执行，以提高整体的调度吞吐量 5。

现代 kube-scheduler 中，`pkg/scheduler/schedule_one.go` 文件内的 `ScheduleOne` 函数是调度单个 Pod 的入口点，它会调用调度框架来执行这些周期 15。

从硬编码的预选/优选逻辑演进到基于插件的调度框架，是 Kubernetes 调度器设计理念上的一次根本性转变，标志着向更声明式、更可组合的调度范式迈进。旧模型要求修改核心代码并重新编译调度器才能调整调度逻辑 1。Extender 机制虽然提供了进程外扩展的能力，但受限于 HTTP 调用的性能开销和有限的扩展点 4。调度框架则通过提供丰富的扩展点和进程内插件机制，实现了高性能和细粒度的调度控制。这意味着用户现在可以通过配置 Profile 和插件组合来“定制”调度行为，而无需深入修改调度器核心源码。

调度周期的串行执行是一个经过深思熟虑的设计选择。为单个 Pod 进行筛选和打分可能涉及对复杂集群状态和 Pod 需求的评估。如果并发处理多个 Pod 的调度决策，并且这些决策都依赖于一个快速变化的共享缓存，可能会导致数据不一致或竞态条件。一旦节点选定（调度周期结束），绑定操作主要是一个 API 调用。将其设计为异步的绑定周期，允许调度器在等待绑定完成的同时，更快地从队列中拾取下一个待调度的 Pod，从而优化了整体吞吐量 14。这种设计在决策的正确性和系统的高吞吐量之间取得了平衡。

此外，`PercentageOfNodesToScore` 配置项 7 是一个针对大规模集群的关键性能优化。在拥有数千个节点的集群中，对所有通过预选阶段的节点进行打分可能非常耗时。该参数允许调度器仅对一部分可行节点进行打分。其默认值是自适应的（例如，可能是 50−(num of nodes)/125），意味着在小集群中会对更多比例的节点打分，而在大集群中则降低比例，以保证调度延迟在一个可接受的范围内 9。这体现了在寻找“绝对最优”节点与“足够好且快速”找到节点之间的务实权衡。

## 三、 核心亮点之一：Kubernetes 调度框架 (KEP-624) - 可扩展性的革命

Kubernetes 调度框架是现代 kube-scheduler 的基石，它通过一套定义良好的插件扩展点，赋予了调度器前所未有的灵活性和可定制性。

### 3.1 设计动机与目标

调度框架的提出，源于对旧有调度机制局限性的深刻认识。随着 Kubernetes 功能的不断丰富，直接在核心调度器中添加新特性变得越来越困难，导致代码日益臃肿，维护和排错的复杂度也随之增加。对于那些需要自定义调度逻辑的用户而言，跟上核心调度器的快速迭代并集成自己的修改，也成了一项艰巨的任务 5。

先前存在的 Extender 机制虽然提供了一种扩展方式，但其基于 HTTP 的远程调用带来了显著的性能瓶颈，且扩展点数量有限，例如，通常只能有一个 Extender 负责最终的绑定操作 4。

因此，调度框架的核心目标是：**允许大部分调度特性以插件的形式实现，从而保持调度核心的简洁和可维护性** 5。

调度框架作为 Alpha 特性在 Kubernetes 1.15 版本中首次引入 12。KEP-624 5 详细规划了其发展蓝图，目标是在 1.16 版本达到 Alpha，1.17 版本达到 Beta，并在 1.19 版本达到稳定状态 (GA)（实际的 Alpha 版本为 1.15，KEP 中的版本可能反映了最初的规划或后续调整）。

### 3.2核心概念

调度框架的核心概念包括 5：

- **插件 (Plugins)**：插件是实现特定调度行为的代码单元，它们在编译时被链接到调度器二进制文件中。
- **组件配置 (ComponentConfig)**：通过 kube-scheduler 的配置文件（通常是 `KubeSchedulerConfiguration` API 对象），可以启用、禁用插件，甚至调整某些插件的执行顺序。
- **树外插件 (Out-of-Tree Plugins)**：用户可以开发自己的插件，并将它们编译到自定义的调度器二进制文件中，而无需修改 Kubernetes 的核心代码库。

### 3.3 扩展点：构建调度逻辑的基石

调度框架在调度周期和绑定周期的不同阶段定义了一系列扩展点 (Extension Points)，插件可以在这些点上注册并执行自定义逻辑。

![1](/Users/mengyipeng/Documents/blog/my-blog/public/posts/20250507/1.png)

以下是主要的扩展点 5：

| **扩展点 (Extension Point)** | **目的与描述**                                               | **关键接口方法 (示例)**                  | **调用时机/频率**                                      | **示例内置插件**                                             |
| ---------------------------- | ------------------------------------------------------------ | ---------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------ |
| `QueueSort`                  | 对调度队列中的 Pod 进行排序，决定 Pod 被调度的顺序。         | `Less(PodInfo1, PodInfo2)`               | 每当 Pod 入队或需要重新排序时                          | `PrioritySort` (默认)                                        |
| `PreFilter`                  | 在实际过滤节点之前，对 Pod 信息进行预处理，或检查集群/Pod 必须满足的某些条件。如果任一 `PreFilter` 插件失败，调度周期将中止。 | `PreFilter(pod)`                         | 每个调度周期一次                                       | `NodePorts`, `NodeResourcesFit`, `InterPodAffinity`          |
| `Filter`                     | 类似于传统的预选阶段，用于过滤掉不能运行目标 Pod 的节点。如果任一 `Filter` 插件将节点标记为不可行，则后续该节点的 `Filter` 插件将不再被调用。 | `Filter(pod, nodeInfo)`                  | 每个调度周期中，针对每个节点调用一次（可能被提前中止） | `NodeResourcesFit`, `NodeName`, `TaintToleration`, `InterPodAffinity` |
| `PostFilter`                 | 当 `Filter` 阶段未能找到任何可用节点时调用。通常用于执行抢占逻辑，尝试通过驱逐其他 Pod 来使当前 Pod 可调度。 | `PostFilter(pod, filteredNodeStatusMap)` | 如果 `Filter` 后无可用节点，则调用一次                 | `DefaultPreemption`                                          |
| `PreScore`                   | 在对节点进行实际打分之前执行，用于预计算或生成可供 `Score` 插件共享的状态。 | `PreScore(pod, nodes)`                   | `Filter` 后，`Score` 前，每个调度周期一次              | `TaintToleration`, `InterPodAffinity`, `NodeResourcesBalancedAllocation` |
| `Score`                      | 类似于传统的优选阶段，对通过 `Filter` 阶段的节点进行打分，以确定其优先级。每个 `Score` 插件都会为每个节点生成一个分数。 | `Score(pod, nodeName)`                   | 对每个通过 `Filter` 的节点调用一次                     | `NodeResourcesBalancedAllocation`, `ImageLocality`, `TaintToleration`, `InterPodAffinity` |
| `NormalizeScore`             | 在所有 `Score` 插件完成打分后调用，用于将不同插件产生的原始分数归一化到一个统一的范围（例如 0-100）。 | `NormalizeScore(scores)`                 | `Score` 后，每个调度周期一次                           | (通常由框架本身处理或通过辅助函数实现)                       |
| `Reserve`                    | 一个有状态的操作。在 Pod 绑定到节点之前，用于在选定节点上声明或预留资源。此扩展点通常与 `Unreserve` 成对出现，用于失败时的回滚。 | `Reserve(pod, nodeName)`                 | 选定节点后，`Permit` 前，每个调度周期一次              | `VolumeBinding`                                              |
| `Permit`                     | 在绑定之前的最后一道“关卡”。插件可以返回 `approve`（允许绑定）、`deny`（拒绝绑定，将导致 Pod 返回队列并触发 `Unreserve`）或 `wait`（等待某个条件满足，有超时机制）。这对于实现如“成组调度”或资源配额检查等复杂场景至关重要。 | `Permit(pod, nodeName)`                  | `Reserve` 后，`PreBind` 前，每个调度周期一次           | (通常用于自定义插件，如批处理调度)                           |
| `PreBind`                    | 在实际执行绑定操作之前调用，允许插件执行一些最终的准备工作。 | `PreBind(pod, nodeName)`                 | `Permit` 成功后，`Bind` 前，每个绑定周期一次           | `VolumeBinding`                                              |
| `Bind`                       | 执行实际的绑定操作，即将 Pod 的 `.spec.nodeName` 更新为选定的节点。通常在一个 Profile 中只有一个 `Bind` 插件处于激活状态。 | `Bind(pod, nodeName)`                    | `PreBind` 成功后，每个绑定周期一次                     | `DefaultBinder`                                              |
| `PostBind`                   | 在 Pod 成功绑定到节点之后调用，用于执行一些清理工作或记录信息。 | `PostBind(pod, nodeName)`                | `Bind` 成功后，每个绑定周期一次                        | (通常用于自定义插件，如日志记录)                             |

所有扩展点和执行顺序

![2](2.png)

### 3.4 插件 API 与生命周期

调度框架为插件提供了必要的 API 和上下文信息 5：

- **`CycleState`**：这是一个在单个调度周期内（从 `PreFilter` 到 `PostBind`）共享的键值存储。插件可以使用它来传递数据或缓存计算结果，避免在后续扩展点重复计算。
- **`FrameworkHandle`**：为插件提供访问调度器内部组件的句柄，例如调度器缓存 (`SchedulerCache`)、Informer 工厂 (`SharedInformerFactory`) 以及 Kubernetes API 客户端 (`kubernetes.Interface`)。
- **插件注册**：插件通过其名称和一个工厂函数（用于创建插件实例）在调度器启动时进行注册。
- **插件配置**：通过 `KubeSchedulerConfiguration` API 对象中的 `profiles` 字段来配置。每个 Profile 可以定义一组启用的插件、它们的顺序（对于某些扩展点如 `Filter` 很重要）以及可选的插件参数 11。

`Permit` 扩展点的引入，极大地增强了调度器的能力，使其能够处理以往难以实现的复杂调度场景。例如，对于需要同时调度多个 Pod 的“成组调度”（gang scheduling），`Permit` 插件可以让已选定节点的 Pod 进入“等待”状态，直到组内所有 Pod 都找到了各自的节点并达到 `Permit` 阶段，或者直到超时。若超时，则所有相关 Pod 都会被拒绝，并触发已预留资源的释放。这种机制避免了资源被长时间无效占用，同时为需要外部协调或满足特定条件的调度提供了可能。

`Reserve` 和 `Unreserve` 机制对于有状态插件至关重要，确保了资源核算的完整性。某些插件可能需要在调度过程中试探性地“声明”或“标记”节点上的特定资源（如特定的 GPU 设备或网络带宽）。`Reserve` 阶段允许这种操作。如果后续的某个插件（如 `Permit` 或 `PreBind` 阶段的插件）执行失败，或者最终的绑定操作未能成功，`Unreserve` 阶段会确保这些试探性的声明被回滚。没有这种机制，调度器对可用资源的视图可能会变得不一致，从而导致后续的调度决策出错。

通过配置文件启用、禁用插件或调整其执行顺序的能力，意味着管理员可以在不重新编译调度器的情况下，显著改变其行为。这为生产环境中的运维提供了极大的灵活性，也使得尝试不同的调度策略变得更加容易。例如，如果某个打分插件计算开销较大且对当前集群负载并非必需，管理员可以禁用它；或者，如果某个过滤插件具有很高的选择性（能快速排除大量不合格节点），可以将其顺序提前以节省后续插件的计算量。这种配置驱动的定制化，大大降低了调整调度行为的门槛。

## 四、 调度决策剖析：核心内置插件源码解读

为了更具体地理解调度框架如何工作，下面将分析几个关键的内置插件，并结合其在源码中的实现，探讨它们如何在特定的扩展点上发挥作用。这些插件的源码通常位于 `pkg/scheduler/framework/plugins/` 目录下，其子目录对应各个插件的实现 19。

### 4.1 `NodeResourcesFit` (Filter 插件)

- **目的**：检查节点是否拥有足够的、可分配的资源（如 CPU、内存、临时存储以及自定义资源）来满足 Pod 的请求。

- **源码位置**：`pkg/scheduler/framework/plugins/noderesources/fit.go`

- 逻辑简述：该插件实现了 `FilterPlugin` 接口。其核心的 `Filter`方法会遍历 Pod 中的所有容器，累加它们的资源请求总量，然后与 `nodeInfo.AllocatableResource()`（表示节点可分配资源）进行比较。如果节点的任何一种可分配资源小于 Pod 的请求量，则该节点不适合运行此 Pod，插件将返回一个表示失败的状态 

  ```go
  // Simplified conceptual logic for NodeResourcesFit.Filter
  func (f *Fit) Filter(ctx context.Context, cycleState *framework.CycleState, pod *v1.Pod, nodeInfo *framework.NodeInfo) *framework.Status {
      // Calculate total requested resources by the pod
      podRequest := calculatePodResourceRequest(pod)
  
      // Check if node has enough allocatable resources
      if!fits(podRequest, nodeInfo.AllocatableResource()) {
          return framework.NewStatus(framework.Unschedulable, "Insufficient node resources")
      }
      return framework.NewStatus(framework.Success)
  }
  ```

  

### 4.2 `TaintToleration` (Filter, PreScore, Score 插件)

- **目的**：确保 Pod 遵守节点的污点 (Taints)。如果 Pod 没有相应的容忍 (Toleration)，它将无法调度到带有特定污点的节点上。此外，该插件还会根据 `PreferNoSchedule` 类型的污点对节点进行打分 22。

- **源码位置**：`pkg/scheduler/framework/plugins/tainttoleration/taint_toleration.go` 24

- 逻辑简述

  ：

  - **`Filter`**：检查节点上是否存在 Pod 不能容忍的 `NoSchedule` 或 `NoExecute` 效果的污点。如果存在，则过滤掉该节点。
  - **`PreScore`**：此阶段会收集 Pod 规范中定义的、针对 `PreferNoSchedule` 效果的容忍项，并将其存储在 `CycleState` 中，供 `Score` 阶段使用 24。
  - **`Score`**：计算节点上 `PreferNoSchedule` 污点中，有多少是 Pod 不能容忍的。不能容忍的污点越少，节点的得分越高（通常实现为从一个最大分值中减去不可容忍的污点数量，或者直接返回一个负相关的计数值）24。

  Go

  ```
  // Simplified conceptual logic for TaintToleration.Score
  func (pl *TaintToleration) Score(ctx context.Context, state *framework.CycleState, pod *v1.Pod, nodeName string) (int64, *framework.Status) {
      nodeInfo, _ := pl.handle.SnapshotSharedLister().NodeInfos().Get(nodeName)
      node := nodeInfo.Node()
      // preScoreState would contain pod's tolerations for PreferNoSchedule
      preScoreState, _ := getPreScoreState(state)
  
      tolerations := preScoreState.tolerationsPreferNoSchedule
      numIntolerableTaints := countIntolerableTaintsPreferNoSchedule(node.Spec.Taints, tolerations)
  
      // Higher score for fewer intolerable taints
      return framework.MaxNodeScore - int64(numIntolerableTaints), framework.NewStatus(framework.Success)
  }
  ```

### 4.3 `InterPodAffinity` (Filter, PreScore, Score 插件)

- **目的**：处理 Pod 亲和性（倾向于与某些 Pod 部署在同一拓扑域）和反亲和性（倾向于避免与某些 Pod 部署在同一拓扑域）规则 12。

- **源码位置**：`pkg/scheduler/framework/plugins/interpodaffinity/inter_pod_affinity.go` （基于 19 的路径推断）

- 逻辑简述

  ：

  - **`PreFilter` 和 `PreScore`**：预计算 Pod 的亲和性/反亲和性规则，以及集群中已存在 Pod 的标签和拓扑信息，并将这些中间结果存入 `CycleState`。这避免了在为每个节点执行 `Filter` 或 `Score` 时重复进行代价较高的 Pod 列表和标签匹配操作。
  - **`Filter`**：评估 Pod 定义中 `requiredDuringSchedulingIgnoredDuringExecution` 类型的亲和性/反亲和性规则。如果硬性要求不满足，则过滤掉该节点。
  - **`Score`**：评估 `preferredDuringSchedulingIgnoredDuringExecution` 类型的规则。根据匹配的规则及其权重，为节点增加或减少分数。

许多插件，如 `InterPodAffinity` 和 `TaintToleration`，会同时实现 `Filter` 和 `Score`（有时还包括 `PreFilter`/`PreScore`）扩展点。这种设计允许对同一特性（如污点或亲和性）应用不同层级的调度策略：通过 `Filter` 强制执行硬性约束，通过 `Score`表达软性偏好。例如，Pod 可能*必须*避免带有 `NoSchedule` 污点的节点（由 `Filter` 插件处理），同时倾向避免带有 `PreferNoSchedule` 污点的节点（由 `Score` 插件处理）。这种分阶段评估为复杂的放置策略提供了细致的控制。

`PreFilter` 和 `PreScore` 阶段对于优化调度性能至关重要。它们允许插件在每个 Pod 的调度周期开始时（`PreFilter`）或在对所有节点进行打分之前（`PreScore`）执行一次性的、可能较为耗时的计算，并将结果缓存在 `CycleState` 中。随后，针对每个节点调用的 `Filter` 或 `Score` 方法就可以直接使用这些预计算的结果，从而显著减少了在大型集群中因重复计算带来的开销。例如，`TaintToleration` 插件在 `PreScore` 阶段收集 Pod 对 `PreferNoSchedule` 污点的容忍信息，正是这种优化思想的体现 24。

### 4.4 `NodePorts` (PreFilter, Filter 插件)

- **目的**：检查 Pod 请求的 `hostPort`（主机端口）在节点上是否可用。
- **源码位置**：`pkg/scheduler/framework/plugins/nodeports/node_ports.go` （基于 19 的路径推断，26 提供了具体细节）
- 逻辑简述
  - **`PreFilter`**：可以从 Pod 定义中提取出所有请求的 `hostPort` 信息。
  - **`Filter`**：检查 `nodeInfo`（节点信息对象）中记录的已使用主机端口，判断 Pod 请求的端口是否存在冲突。如果存在冲突，则该节点不可用。`NodePorts` 插件的 `Filter` 函数会返回一个错误原因，如 "node(s) didn't have free ports for the requested pod ports" 26。

### 4.5 `NodeName` (Filter 插件)

- **目的**：如果 Pod 的 `.spec.nodeName` 字段已经被设置，此插件确保 Pod 只会被调度（或“适合”）到这一个指定的节点上。
- **源码位置**：`pkg/scheduler/framework/plugins/nodename/node_name.go` （基于 19 的路径推断）
- **逻辑简述**：其 `Filter` 方法非常直接：如果 Pod 的 `.spec.nodeName` 有值，则比较该值与当前正在被评估的 `nodeInfo.Node().Name`。如果不匹配，则该节点被过滤掉。

### 4.6 其他重要插件与生态

除了上述插件，还有许多其他重要的内置插件，例如：

- **`VolumeBinding`**：处理 `StorageClass` 中 `volumeBindingMode` 设置为 `WaitForFirstConsumer` 的持久卷声明 (PVC)。它会延迟卷的动态创建和绑定，直到第一个使用该 PVC 的 Pod 被调度，从而确保卷创建在 Pod 将要运行的拓扑区域（如可用区）。
- **`PodTopologySpread`**：根据 Pod 的拓扑分布约束（`topologySpreadConstraints`），将一组相关的 Pod 分散到不同的拓扑域（如节点、机架、可用区）中，以提高应用的可用性和容错性。

所有这些内置插件都在 `pkg/scheduler/framework/plugins/registry.go` 中注册，并在默认的调度 Profile 中根据需要启用。

值得一提的是，Kubernetes 社区还维护了一个名为 `kubernetes-sigs/scheduler-plugins` 的代码仓库 27。这个仓库包含了许多基于调度框架实现的“树外 (out-of-tree)”插件，提供了诸如容量调度、协同调度（co-scheduling）、更高级的抢占策略等功能。这个项目的存在和活跃度，充分证明了调度框架作为可扩展平台的成功。它表明调度框架不仅是一个理论上的设计，更是一个被社区广泛采用的实用工具，用以解决核心调度器未直接覆盖的、真实世界中的复杂调度需求。

## 五、 资源紧缺时的抉择：Pod 优先级与抢占机制

在资源受限的 Kubernetes 集群中，为了保证高优先级的 Pod 能够及时运行，kube-scheduler 引入了抢占 (Preemption) 机制。当一个高优先级的 Pod 因资源不足而无法调度时，调度器会尝试驱逐一个或多个运行在节点上的低优先级 Pod，从而为高优先级 Pod腾出空间。

### 5.1 抢占的触发条件

抢占逻辑通常在常规的调度流程（Filter 阶段）未能为 Pod P 找到合适的节点后被触发 29。此时，Pod P 处于悬决 (Pending) 状态。调度框架中的 `PostFilter` 扩展点是执行抢占逻辑的理想位置 18。默认的抢占实现本身就是一个 `PostFilter` 插件。

### 5.2 抢占的执行流程

抢占过程大致如下 29：

1. **寻找牺牲节点 (Victim Node Selection)**：调度器（的抢占插件）会遍历集群中的节点，尝试找到一个或多个节点，在这些节点上，如果移除一些优先级低于 Pod P 的 Pod，就能使 Pod P 成功调度。
2. **评估可行性**：对于每个潜在的牺牲节点，调度器会模拟驱逐低优先级 Pod 后的资源状况，判断 Pod P 是否能够满足其所有需求（包括资源、亲和性等）。
3. 选择牺牲者 Pod (Victim Pod Selection)
   - 被选为牺牲者的 Pod 的优先级必须低于抢占者 Pod P。
   - 调度器会优先选择优先级最低的 Pod 作为牺牲者。
   - 调度器会尝试尊重 PodDisruptionBudgets (PDBs)，即尽量不驱逐那些会导致其所属应用违反 PDB 的 Pod。然而，PDB 并非绝对的保护伞；如果为了调度一个非常高优先级的 Pod 而别无选择，PDB 也可能被打破 29。
   - 如果存在多个节点可以执行抢占，调度器通常会选择那个能够通过驱逐“代价最小”的一组 Pod（例如，优先级总和最低）来满足 Pod P 需求的节点。
4. **设置提名节点 (Nominated Node)**：一旦选定了牺牲节点和牺牲者 Pod，抢占者 Pod P 的 `.status.nominatedNodeName` 字段会被设置为目标节点的名称 29。这个字段起到了一个重要的提示作用，告知调度器系统该节点正在为 Pod P 进行资源清理，应优先考虑将 Pod P 调度到此节点。
5. **驱逐牺牲者 Pod**：调度器向 API Server 发送删除牺牲者 Pod 的请求。这些 Pod 会经历正常的优雅终止流程。
6. **调度抢占者 Pod**：当牺牲者 Pod 被成功删除，节点资源得到释放后，抢占者 Pod P 会再次进入调度流程。由于其 `.status.nominatedNodeName` 已设置，调度器会优先尝试将其调度到该提名节点上。

抢占机制虽然对于保障关键应用的运行至关重要，但它本质上是一种有损操作。`nominatedNodeName` 机制试图提高抢占的成功率和效率。因为从发出驱逐命令到资源真正释放需要一段时间（Pod 的优雅终止期），在这期间，如果没有 `nominatedNodeName` 的“软预留”，那么被释放的资源可能会被集群中其他碰巧正在调度的 Pod 抢先占用，导致最初的抢占者 Pod P 仍然无法调度到目标节点，形成“抢占踩踏”的现象。`nominatedNodeName` 通过向调度器传递一个强烈的信号，即“此节点正在为特定 Pod 清理资源”，从而降低了这种风险，但它并不保证最终一定能调度成功，因为节点状态可能在提名后再次发生变化。

抢占逻辑与 PodDisruptionBudgets (PDBs) 之间的交互，揭示了 Kubernetes 在设计上的一种内在权衡：一方面要维护应用的可用性（通过 PDB），另一方面要确保高优先级工作负载的运行。调度器会尽力寻找不违反 PDB 的抢占方案，但如果一个优先级足够高的 Pod 无法调度，且所有可能的抢占方案都会违反某个低优先级应用的 PDB，那么为了整体集群的关键任务，PDB 可能会被牺牲。集群管理员需要清晰地理解这种优先级和可用性之间的平衡，并合理配置 Pod 优先级和 PDB。

值得注意的是，默认的抢占逻辑 (`DefaultPreemption` 插件) 是作为 `PostFilter` 插件实现的。这意味着，拥有特定复杂抢占需求的用户，理论上可以替换或扩展此插件，实现自定义的抢占策略。例如，可以根据业务价值而非仅仅 Pod 优先级来选择牺牲者，或者实现更复杂的跨节点抢占分析（尽管默认抢占主要针对单节点内的资源腾挪 29）。这再次突显了调度框架的强大扩展能力。

## 六、 尘埃落定：绑定阶段

当调度器为 Pod 成功选择了一个节点，并且所有相关的 `Permit` 插件都予以放行后，调度流程就进入了最后的绑定阶段。这个阶段的目的是将调度决策固化下来，正式将 Pod 与选定的节点关联起来。

绑定周期包含以下几个关键的扩展点 5：

1. **`PreBind` 插件**：在实际执行绑定操作之前运行。这些插件可以用于执行一些需要在 Pod 绑定到节点前完成的准备工作。例如，如果 Pod 需要特定的网络资源（如 IP 地址或网络接口），`PreBind` 插件可以在此时进行分配或配置，确保当 Pod 的容器启动时，这些资源已经就绪。`VolumeBinding` 插件也可能在此阶段进行卷的最终确认。

2. Bind 插件：负责执行核心的绑定操作。这通常意味着调用 Kubernetes API Server，将 Pod 对象的 .spec.nodeName 字段更新为选定节点的名称。在一个调度 Profile 中，通常只有一个 Bind 插件是激活的，最常见的是 DefaultBinder 插件。一旦 API Server 确认了这一更新，kubelet 组件在该选定节点上就会监听到这个分配给自己的 Pod，并开始拉取镜像、创建和运行其容器 1。早期的 Extender 机制也允许实现自定义的 bind 逻辑 16。

   DefaultBinder 的实现位于 pkg/scheduler/framework/plugins/defaultbinder/default_binder.go。

3. **`PostBind` 插件**：在 Pod 成功绑定到节点之后运行。这些插件主要用于执行一些清理工作、记录日志或触发后续的通知。例如，一个自定义的 `PostBind` 插件可以更新一个外部的资产管理系统，记录 Pod 的实际部署位置。

调度框架的 `RunBindPlugins` 和 `RunPostBindPlugins` 方法（通常在 `pkg/scheduler/framework/runtime/framework.go` 中）会负责调用在当前 Profile 中注册并启用的相应插件。

`Bind` 插件的可扩展性为一些高级集成场景提供了可能。虽然 `DefaultBinder` 的任务相对简单（即更新 Pod 的 `NodeName`），但一个自定义的 `Bind` 插件可以做得更多。例如，在金融行业或有严格合规要求的环境中，自定义 `Bind` 插件可以在向 API Server 发送绑定请求之前，先与外部的审计系统或策略引擎交互，确保调度决策符合所有规定，或者在绑定后触发特定的安全配置流程。这种能力将 Kubernetes 的调度决策与更广泛的基础设施管理和策略执行紧密联系起来。

调度周期（节点选择）和绑定周期（API 更新）的分离，特别是后者可以异步执行的设计 14，对调度器的整体吞吐量至关重要。节点选择过程可能涉及复杂的计算和状态评估，相对耗时。而绑定操作主要是一个网络 I/O（API 调用）。一旦节点选定并通过了 `Permit` 阶段，调度器可以将实际的绑定任务交给一个独立的 goroutine 处理，然后自身可以立即从队列中获取下一个待调度的 Pod 进行处理 14。这种类似流水线的处理方式，显著提高了调度器在单位时间内能够处理的 Pod 数量。

## 七、 核心亮点之二：调度设计的现实意义

kube-scheduler 内部的诸多设计，如可插拔的调度框架、抢占机制以及各种精细化的插件，并不仅仅是技术上的精巧实现，它们对生产环境中的 Kubernetes 集群运行具有深远且实际的影响。

### 7.1 可插拔框架：定制化与可观测性

调度框架的引入，使得 Kubernetes 能够适应远超以往的、多样化的工作负载需求。对于拥有特殊需求（如高性能计算 HPC、机器学习 ML 训练、电信网络功能虚拟化 NFV）的组织而言，它们不再需要fork Kubernetes 核心代码库来修改调度逻辑。取而代之的是，可以通过开发自定义插件来满足其独特需求。例如：

- 一个自定义的 `Score` 插件可以优先选择那些配备了特定硬件加速器（如 GPU、FPGA）且利用率较低的节点，而这些硬件的细微差别可能超出了默认插件的感知范围。
- 一个自定义的 `Permit` 插件可以实现复杂的“成组调度”逻辑，确保一组相互依赖的 Pod 要么一起成功调度，要么一起失败，这对于某些分布式计算任务至关重要。

此外，当 Pod 长时间处于 "Pending" 状态时，理解调度框架的各个阶段和当前激活的插件，对于排查问题至关重要。通过分析调度器日志，可以追溯 Pod 在哪个插件的哪个扩展点（Filter, Score, Permit 等）遇到了障碍。调度框架的模块化设计使得这种诊断过程更加清晰可循。SIG Scheduling 也在持续探索提升调度器可观测性和吞吐量的内部增强，例如 `QueueingHint` 机制 31，它很可能就是利用了框架的灵活性来优化调度信号的传递和处理。

### 7.2 抢占机制：守护关键业务

Pod 优先级与抢占机制是确保高优先级应用（如关键的在线服务、核心业务组件）在资源紧张时仍能获得所需资源的“最后一道防线”。这对于满足这些应用的服务等级目标 (SLO) 是不可或缺的。

然而，抢占是一把双刃剑。它通过驱逐低优先级 Pod 来为高优先级 Pod 让路，这必然会对被驱逐的应用造成干扰。集群管理员必须深入理解 Pod 优先级类 (PriorityClasses) 和 PodDisruptionBudgets (PDBs) 的工作原理和相互作用，才能在高优先级任务的及时性与低优先级服务的稳定性之间做出合理的平衡和配置 29。错误或不当的优先级配置可能导致不必要的应用抖动，甚至引发级联性的服务中断。

### 7.3 亲和性与拓扑分布：精细调度

诸如 `InterPodAffinity`（Pod 间亲和性/反亲和性）和 `PodTopologySpread`（Pod 拓扑分布约束）等插件，为用户提供了强大的工具来精细控制 Pod 的部署位置，从而实现：

- **高可用性**：通过将应用的多个实例分散到不同的故障域（如不同的节点、机架、可用区），可以显著降低单点故障导致整个应用不可用的风险。
- **性能优化**：可以将需要频繁、低延迟通信的 Pod 组件（如应用服务器和其本地缓存）部署在同一节点或同一可用区，以减少网络延迟，提升整体性能。

这些规则的配置可能相当复杂 12，一个健壮且正确的插件实现（如内置的 `InterPodAffinity` 和 `PodTopologySpread` 插件）对于确保这些用户意图得到准确执行至关重要。

调度框架的真正威力在于，它允许将多个自定义或特定用途的插件组合在一个调度 Profile 中，共同作用以实现高度复杂的、针对特定领域的调度行为。想象这样一个场景：一个 `Filter` 插件确保 Pod 只被调度到拥有特定昂贵硬件（如专业级 GPU）的节点上；一个 `Score` 插件优先选择那些此类硬件利用率尚低的节点，以实现负载均衡；同时，一个 `Permit` 插件负责与外部的许可证管理系统交互，确保在 Pod 启动前已获得使用该硬件的许可。这种分层、组合式的策略，能够满足单一、 monolithic 调度器难以企及的复杂约束和偏好。

随着集群规模的扩大和工作负载类型的日益多样化，默认的调度器配置可能不再是所有场景下的最优解。深入理解调度框架及其可用插件，使集群管理员和架构师能够主动地微调调度行为，以期达到更好的资源利用率、应用性能，甚至可能带来显著的成本节约或更严格的 SLO 遵从性 32。例如，根据工作负载的特性（批处理 vs. Web 服务，CPU 密集型 vs. 内存密集型），选择不同的节点资源分配策略插件（如 `NodeResourcesLeastAllocated` 倾向于分散，`NodeResourcesMostAllocated` 倾向于集中，`NodeResourcesBalancedAllocation` 寻求均衡 20）或调整其权重，可以显著影响集群的整体运行效率。这标志着从被动的问题排查转向主动的系统优化。

## 八、 调度器的演进之路与未来展望

kube-scheduler 的发展历程是 Kubernetes 整体演进的一个缩影，它清晰地展示了从一个功能核心出发，根据实际应用需求和社区反馈，不断进行重构以提升可扩展性、性能和灵活性的过程。

### 8.1 历史沿革

- **早期阶段**：初期的 kube-scheduler 设计相对简单和 monolithic，其核心调度逻辑（预选和优选）是硬编码在程序中的 3。虽然能够满足 Kubernetes 早期的基本调度需求，但随着用户场景的复杂化，这种设计的局限性逐渐显现。
- **Extender 机制**：为了提供一定的扩展能力，Kubernetes 引入了 Extender 机制。它允许用户通过配置 webhook，在调度流程的特定点（主要是预选和优选之后）调用外部服务来影响调度决策 16。然而，Extender 基于 HTTP(S) 的远程调用带来了性能开销，且其扩展点有限，灵活性不足 4。
- **调度框架 (KEP-624)**：这是 kube-scheduler 发展史上的一个重要里程碑。调度框架通过在调度流程中定义一系列精细的扩展点，并允许用户以插件的形式将自定义逻辑编译进调度器，从而在保持高性能的同时，提供了前所未有的可扩展性。该框架在 Kubernetes 1.15 版本中以 Alpha 状态引入 12，并按照 KEP-624 5 的规划逐步成熟。

以下表格概述了对 kube-scheduler 产生重大影响的一些关键特性和 KEP：

| **Kubernetes 版本 (约)** | **特性 / KEP (Enhancement Proposal)**                        | **重要性与影响**                                             |
| ------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| 早期                     | Pod 优先级与抢占机制                                         | 奠定了关键应用资源保障的基础，允许高优先级 Pod 驱逐低优先级 Pod 29。 |
| 1.14 (KEP-16 引入)       | KEP-16: Pod Scheduling Readiness (`.spec.schedulingGates`)   | 允许用户控制 Pod 何时才被认为准备好、可以被调度器考虑，有助于处理需要前置条件（如外部资源依赖）的 Pod 33。 |
| 1.15 (Alpha)             | KEP-624: Scheduling Framework                                | 革命性的重构，引入插件化架构，极大地增强了调度器的可扩展性和可定制性，是现代 kube-scheduler 的核心 5。 |
| 1.26 (Alpha)             | KEP-4381: Dynamic Resource Allocation (DRA) - Structured Parameters | 针对第三方资源的动态分配机制的增强，旨在让核心 Kubernetes 组件（如调度器、集群自动伸缩器）能更好地理解和处理这些资源，提升调度效率和决策能力 34。 |
| 1.30 (Beta 增强)         | KEP-2400: Node Memory Swap Support                           | 改进了对节点上 Swap 内存的支持，可能会影响到 `NodeResourcesFit` 等资源检查插件的行为，并为特定类型的工作负载提供更灵活的内存管理选项 34。 |



这段演进历史清晰地反映了一个成功的开源基础设施软件的普遍发展模式：首先构建一个满足核心需求的功能系统，然后在实际应用中不断发现其局限性，并通过社区协作进行迭代式的重构和增强，以追求更高的性能、更强的灵活性和更广泛的适用性。

### 8.2 未来展望与 SIG Scheduling 的焦点

Kubernetes SIG Scheduling (负责调度器相关组件的特别兴趣小组) 持续推动着 kube-scheduler 的发展。根据近期的分享和发布说明，未来的发展方向和当前的焦点包括 31：

- **持续提升可扩展性与吞吐量**：这是 SIG Scheduling 长期关注的核心议题。通过优化调度框架的内部实现（如 `QueueingHint` 增强 31）和改进插件的效率，来应对日益增长的集群规模和调度需求。

- 子项目与生态发展

  ：SIG Scheduling 积极孵化和支持围绕核心调度器的子项目，以解决更细分领域的复杂调度问题。例如：

  - **Kueue**：一个作业排队控制器，负责管理批处理作业的准入、排队和资源分配，它与 kube-scheduler 协同工作，决定何时将作业的 Pod 提交给 kube-scheduler 进行实际的节点分配 31。
  - **Descheduler**：用于识别并驱逐那些虽然已经运行、但不再满足当前调度策略（如节点亲和性、污点容忍等因集群状态变化而不再满足）的 Pod，以便 kube-scheduler 能够将它们重新调度到更合适的节点上 31。 这种围绕核心组件构建专业化工具的策略，类似于微服务架构的思想，使得 Kubernetes 调度生态系统能够在不使核心调度器过度复杂化的前提下，解决更广泛的问题。

- **应对多样化的工作负载需求和挑战**：随着 Kubernetes 被用于更多新兴领域（如 AI/ML、边缘计算），调度器需要不断适应新的资源类型、调度约束和性能要求 31。KEP-4381 中对动态资源分配 (DRA) 的增强正是这一趋势的体现 34。

## 九、 总结：深入理解，掌控调度

kube-scheduler 作为 Kubernetes 的“大脑”，其内部机制虽然复杂，但通过对其源代码的逐步剖析，可以清晰地看到其设计理念的演进和强大功能的实现。从最初的启动流程、核心组件的构建，到经典的“预选-优选”调度范式，再到革命性的调度框架及其丰富的插件扩展点，每一部分都凝聚了社区的智慧和工程实践的结晶。

深入理解抢占机制、绑定流程以及诸如 `NodeResourcesFit`、`TaintToleration`、`InterPodAffinity` 等关键内置插件的工作原理，不仅能够帮助我们更有效地排查 Pod Pending 等疑难杂症，更能指导我们如何根据实际业务需求，通过配置 Profile、启用或开发自定义插件，来优化集群的资源利用率、提升应用性能，并保障关键业务的稳定运行。

对于希望进一步探索 kube-scheduler 源码的读者，`pkg/scheduler/` 目录是一个绝佳的起点，特别是 `schedule_one.go` 文件，它串联了单个 Pod 的完整调度流程 31。同时，积极关注和参与 Kubernetes SIG Scheduling 社区的讨论和贡献 31，是了解调度器最新进展和未来方向的最佳途径。

掌握 kube-scheduler 的内部工作原理，意味着对 Kubernetes 资源管理和应用部署拥有了更深层次的掌控力。这种知识不仅仅局限于调度器本身，其背后所体现的 Kubernetes 控制器设计模式（如 Informer 机制、工作队列、与 API Server 的交互等）同样适用于理解 Kubernetes 生态系统中的其他核心组件。最终，这种深入的理解将转化为更高效、更可靠地驾驭 Kubernetes 这一强大平台的能力。

#### **引用的著作**

1. Kube-Scheduler源码解析| xigang's home, 访问时间为 五月 7, 2025， https://xigang.github.io/2018/05/05/kube-scheduler/
2. certified-kubernetes-administrator-course/docs/02-Core-Concepts/08-Kube-Scheduler.md at master - GitHub, 访问时间为 五月 7, 2025， https://github.com/kodekloudhub/certified-kubernetes-administrator-course/blob/master/docs/02-Core-Concepts/08-Kube-Scheduler.md
3. CamSaS – The evoluation of cluster scheduler architectures - University of Cambridge, 访问时间为 五月 7, 2025， https://www.cl.cam.ac.uk/research/srg/netos/camsas/blog/2016-03-09-scheduler-architectures.html
4. The Burgeoning Kubernetes Scheduling System – Part 1: Scheduling Framework - Alibaba Cloud Community, 访问时间为 五月 7, 2025， https://www.alibabacloud.com/blog/the-burgeoning-kubernetes-scheduling-system-part-1-scheduling-framework_597318
5. Scheduling Framework - kubernetes/enhancements - GitHub, 访问时间为 五月 7, 2025， https://github.com/kubernetes/enhancements/blob/master/keps/sig-scheduling/624-scheduling-framework/README.md
6. Kubernetes资源调度——scheduler | 李乾坤的博客, 访问时间为 五月 7, 2025， https://qiankunli.github.io/2019/03/03/kubernetes_scheduler.html
7. Kubernetes:kube-scheduler 源码分析- hxia043 - 博客园, 访问时间为 五月 7, 2025， https://www.cnblogs.com/xingzheanan/p/18000774
8. kubernetes/cmd/kube-scheduler/app/server.go at master - GitHub, 访问时间为 五月 7, 2025， https://github.com/kubernetes/kubernetes/blob/master/cmd/kube-scheduler/app/server.go
9. kubernetes/pkg/scheduler/scheduler.go at master - GitHub, 访问时间为 五月 7, 2025， https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/scheduler.go
10. kube-scheduler组件监控指标及大盘使用说明- 容器服务Kubernetes 版ACK - 阿里云, 访问时间为 五月 7, 2025， https://www.alibabacloud.com/help/zh/ack/ack-managed-and-ack-dedicated/user-guide/monitor-kube-scheduler
11. k8s-src-analysis/kube-scheduler/KubeSchedulerConfiguration.md at master - GitHub, 访问时间为 五月 7, 2025， https://github.com/jindezgm/k8s-src-analysis/blob/master/kube-scheduler/KubeSchedulerConfiguration.md
12. Kubernetes Pod Scheduling: Tutorial and Best Practices - CloudBolt, 访问时间为 五月 7, 2025， https://www.cloudbolt.io/kubernetes-pod-scheduling/
13. A repo explaining with an example how to extend the kubernetes default scheduler - GitHub, 访问时间为 五月 7, 2025， https://github.com/akanso/extending-kube-scheduler
14. Kubernetes Scheduler Framework - GoFrame官网- 类似PHP-Laravel, Java-SpringBoot的Go企业级开发框架, 访问时间为 五月 7, 2025， https://wiki.goframe.org/display/~john/Kubernetes+Scheduler+Framework
15. kubernetes/pkg/scheduler/schedule_one.go at master - GitHub, 访问时间为 五月 7, 2025， https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/schedule_one.go
16. Create a custom Kubernetes scheduler - IBM Developer, 访问时间为 五月 7, 2025， https://developer.ibm.com/articles/creating-a-custom-kube-scheduler/
17. Kubernetes 1.15 releases with extensibility around core Kubernetes APIs, cluster lifecycle stability, and more! - Packt, 访问时间为 五月 7, 2025， https://www.packtpub.com/zh-id/learning/tech-news/kubernetes-1-15-releases-with-extensibility-around-core-kubernetes-apis-cluster-lifecycle-stability-and-more
18. [译] kubernetes:kube-scheduler 调度器代码结构概述- hxia043 - 博客园, 访问时间为 五月 7, 2025， https://www.cnblogs.com/xingzheanan/p/17976793
19. cluster-autoscaler/vendor/k8s.io/kubernetes/pkg/scheduler/framework/plugins · 47080466bea2b330c947450f14e0d42128aa9d83 · Redpoint Games / Kubernetes Autoscaler · GitLab, 访问时间为 五月 7, 2025， https://src.redpoint.games/redpointgames/kubernetes-autoscaler/-/tree/47080466bea2b330c947450f14e0d42128aa9d83/cluster-autoscaler/vendor/k8s.io/kubernetes/pkg/scheduler/framework/plugins
20. noderesources package - github.com/divinerapier/learn-kubernetes/pkg/scheduler/framework/plugins/noderesources - Go Packages, 访问时间为 五月 7, 2025， https://pkg.go.dev/github.com/divinerapier/learn-kubernetes/pkg/scheduler/framework/plugins/noderesources
21. Custom Kube-Scheduler: Why And How to Set it Up in Kubernetes - Cast AI, 访问时间为 五月 7, 2025， https://cast.ai/blog/custom-kube-scheduler-why-and-how-to-set-it-up-in-kubernetes/
22. 自定义开发调度器 - Karmada, 访问时间为 五月 7, 2025， https://karmada.io/zh/docs/developers/customize-karmada-scheduler/
23. Taints and Tolerations | Kubernetes, 访问时间为 五月 7, 2025， https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
24. kubernetes/pkg/scheduler/framework/plugins/tainttoleration/taint_toleration.go at master - GitHub, 访问时间为 五月 7, 2025， https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/framework/plugins/tainttoleration/taint_toleration.go
25. Kubernetes Scheduler: How To Make It Work With Inter-Pod Affinity And Anti-Affinity - Cast AI, 访问时间为 五月 7, 2025， https://cast.ai/blog/kubernetes-scheduler-how-to-make-it-work-with-inter-pod-affinity-and-anti-affinity/
26. nodeports package - k8s.io/kubernetes/pkg/scheduler/framework/plugins/nodeports - Go Packages, 访问时间为 五月 7, 2025， https://pkg.go.dev/k8s.io/kubernetes/pkg/scheduler/framework/plugins/nodeports
27. Develop - Scheduler Plugins - Kubernetes, 访问时间为 五月 7, 2025， https://scheduler-plugins.sigs.k8s.io/docs/user-guide/develop/
28. kubernetes-sigs/scheduler-plugins - GitHub, 访问时间为 五月 7, 2025， https://github.com/kubernetes-sigs/scheduler-plugins
29. Pod 优先级和抢占| Kubernetes, 访问时间为 五月 7, 2025， https://kubernetes.io/zh-cn/docs/concepts/scheduling-eviction/pod-priority-preemption/
30. 聊聊kube-scheduler如何完成调度和调整调度权重-华为开发者问答, 访问时间为 五月 7, 2025， https://developer.huawei.com/consumer/cn/forum/topic/0202138295175505164
31. Spotlight on SIG Scheduling - Kubernetes Contributors, 访问时间为 五月 7, 2025， https://www.kubernetes.dev/blog/2024/09/24/sig-scheduling-spotlight-2024/
32. Kubernetes Scheduling: How It Works and Key Influencing Factors - PerfectScale, 访问时间为 五月 7, 2025， https://www.perfectscale.io/blog/kubernetes-scheduling
33. Pod Scheduling Readiness - Kubernetes, 访问时间为 五月 7, 2025， https://kubernetes.io/docs/concepts/scheduling-eviction/pod-scheduling-readiness/
34. A Peek at Kubernetes v1.30, 访问时间为 五月 7, 2025， https://kubernetes.io/blog/2024/03/12/kubernetes-1-30-upcoming-changes/

