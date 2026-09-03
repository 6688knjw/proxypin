# Requirements Document

## Introduction

本功能在 ProxyPin 的 Android APK 版本中内嵌 MCP（Model Context Protocol）服务。同一局域网内的 AI 客户端（Claude Desktop、Cursor、OpenCode 等）通过 Streamable HTTP 连接手机上的 ProxyPin，读取已捕获流量、主动发送或重放 HTTP(S) 请求，并只读查询代理状态与现有规则。

代码编写与执行留在 AI 客户端侧：本期 APK 不在设备上运行 Python 或 JavaScript。用户拿到 AI 给出的脚本后，自行在现有脚本设置页粘贴并验证。

当前 ProxyPin 已具备进程内 HTTP(S) 代理、拦截器链（hosts / rewrite / map / JS script / block / breakpoint）、HAR 历史存储、请求重放与 Android VPN 抓包。本功能在上述能力之上增加面向 AI 的 MCP 工具面，不替换现有 UI 操作路径。

## Glossary

- **System / ProxyPin**：本应用，含进程内 HTTP(S) 代理与 Android APK 客户端。
- **MCP Server**：运行在 Android APK 进程内、实现 Model Context Protocol 的服务端。
- **MCP Client**：连接 MCP Server 的外部 AI 工具（Claude Desktop、Cursor、OpenCode 等）。
- **Captured Session**：当前内存中的实时抓包会话，对应 UI 请求列表。
- **History Record**：已持久化的 HAR 风格历史记录，对应 `HistoryStorage`。
- **Traffic Record**：一条 HTTP(S) 请求/响应对，含 method、URL、headers、body、status、timing。
- **MCP Tool**：MCP 协议中可被 AI 调用的具名工具，对应 ProxyPin 的一项能力。
- **MCP Resource**：MCP 协议中可被 AI 读取的只读资源，例如流量列表或代理状态。
- **LAN Listener**：监听设备可达地址的 MCP HTTP 端口，供同一局域网的电脑连接。
- **Auth Token**：用户在 APK 中生成的访问令牌，MCP Client 连接时必须携带。

## Requirements

### Requirement 1: Android APK 内嵌 MCP 服务

**User Story:** AS Android 用户, I want ProxyPin APK 在本机提供 MCP 服务, so that 电脑上的 AI 客户端可以直接操作手机抓包数据。

#### Acceptance Criteria

1. WHEN 用户在 Android 设置中开启 MCP 服务, THE ProxyPin APK SHALL 在本进程启动 MCP Server。
2. WHEN MCP Server 启动成功, THE ProxyPin APK SHALL 在设置页展示监听地址、端口与当前连接状态。
3. WHEN 用户关闭 MCP 服务或退出应用导致进程结束, THE ProxyPin APK SHALL 停止 MCP Server 并释放监听端口。
4. IF MCP Server 绑定端口失败, THE ProxyPin APK SHALL 向用户展示失败原因并保持 MCP 服务为关闭状态。
5. WHERE 运行平台为 Android, THE ProxyPin APK SHALL 提供 MCP 服务开关；桌面端本期保持现有行为。

### Requirement 2: 局域网 HTTP 连接与鉴权

**User Story:** AS Android 用户, I want 电脑与手机在同一 Wi-Fi 下用带令牌的 HTTP 连接 MCP, so that 未授权设备无法读取我的抓包数据。

#### Acceptance Criteria

1. WHEN 用户首次开启 MCP 服务, THE ProxyPin APK SHALL 生成一组 Auth Token 并展示给用户。
2. WHEN MCP Client 发起连接, THE MCP Server SHALL 校验 Auth Token；仅令牌匹配时接受会话。
3. IF Auth Token 缺失或不匹配, THE MCP Server SHALL 拒绝该连接并记录一次失败事件。
4. WHEN MCP 服务开启, THE MCP Server SHALL 在配置端口上监听（默认 9100），使同一局域网内的电脑可以通过 HTTP 访问。
5. WHEN MCP Server 启动成功, THE ProxyPin APK SHALL 在设置页展示完整连接 URL（含 host、port 与路径）。
6. WHEN 用户点击重新生成令牌, THE ProxyPin APK SHALL 使旧令牌立即失效并展示新令牌。

### Requirement 3: AI 读取已捕获流量

**User Story:** AS AI 使用者, I want 通过 MCP 查询当前会话与历史流量, so that 我可以分析接口、定位问题并总结请求模式。

#### Acceptance Criteria

1. WHEN MCP Client 调用列出流量工具, THE MCP Server SHALL 返回当前 Captured Session 中的 Traffic Record 摘要列表，字段至少包含 requestId、method、URL、status、content-type、耗时与时间戳。
2. WHEN MCP Client 提供 requestId, THE MCP Server SHALL 返回该 Traffic Record 的请求头、请求体、响应头与响应体。
3. WHEN MCP Client 提供 URL、method、host、status 或关键字过滤条件, THE MCP Server SHALL 仅返回匹配的 Traffic Record。
4. WHEN 单条请求体或响应体超过用户在 MCP 设置中配置的上限（默认 65536 字节）, THE MCP Server SHALL 返回截断后的正文并标注已截断与原始长度。
5. WHEN MCP Client 查询 History Record, THE MCP Server SHALL 返回已持久化历史条目列表，并支持按条目 ID 读取其中的 Traffic Record。
6. IF 指定的 requestId 或历史条目不存在, THE MCP Server SHALL 返回明确的未找到错误。

### Requirement 4: AI 发送与重放流量

**User Story:** AS AI 使用者, I want 通过 MCP 发送新请求或重放已捕获请求, so that 我可以验证接口、复现缺陷或构造测试流量。

#### Acceptance Criteria

1. WHEN MCP Client 提供 method、URL、headers 与可选 body, THE MCP Server SHALL 通过 ProxyPin 代理通道发送该 HTTP(S) 请求。
2. WHEN 发送完成, THE MCP Server SHALL 返回响应 status、headers、body 与耗时，并将该次请求写入当前 Captured Session。
3. WHEN MCP Client 提供已存在的 requestId 请求重放, THE MCP Server SHALL 使用该 Traffic Record 的 method、URL、headers 与 body 重新发送。
4. WHEN MCP Client 在重放时提供覆盖字段, THE MCP Server SHALL 用覆盖值替换原 Traffic Record 中的对应字段后再发送。
5. IF 目标 URL 非法, THE MCP Server SHALL 返回失败原因且不发送该请求。
6. WHILE 代理服务未启动, THE MCP Server SHALL 拒绝发送/重放类工具调用，并提示用户先启动抓包代理。

### Requirement 5: AI 只读查询代理状态与规则

**User Story:** AS AI 使用者, I want 通过 MCP 查看代理状态和现有规则, so that 我可以结合流量给出改写或脚本建议，由用户自行粘贴验证。

#### Acceptance Criteria

1. WHEN MCP Client 查询代理状态, THE MCP Server SHALL 返回代理是否运行、监听端口、HTTPS 抓包是否开启。
2. WHEN MCP Client 查询脚本/重写/映射/拦截规则, THE MCP Server SHALL 返回当前已保存规则的摘要列表（id、name、url、enabled），不返回脚本或规则正文。
3. THE MCP Server SHALL 将规则新增、更新、删除、启用/禁用排除在 MCP 工具之外。
4. THE MCP Server SHALL 将导出 CA 私钥、修改系统 VPN 白名单排除在 MCP 工具之外。

### Requirement 6: 本期不在设备上执行代码

**User Story:** AS Android 用户, I want APK 内的 MCP 只操作流量数据, so that 设备上不运行 AI 提交的 Python 或 JavaScript。

#### Acceptance Criteria

1. THE MCP Server SHALL 将 Python 执行、JavaScript 执行类工具排除在 tools/list 之外。
2. WHEN MCP Client 调用未声明的代码执行工具, THE MCP Server SHALL 返回方法不存在错误。
3. THE ProxyPin APK SHALL 继续通过现有脚本设置页执行用户手动保存的 JS 拦截脚本。

### Requirement 7: MCP 工具与资源清单对 AI 可发现

**User Story:** AS AI 客户端, I want 通过标准 MCP 握手发现工具与资源, so that 无需特制 SDK 即可接入 ProxyPin。

#### Acceptance Criteria

1. WHEN MCP Client 完成初始化握手, THE MCP Server SHALL 返回符合 MCP 规范的 serverInfo 与能力声明。
2. WHEN MCP Client 请求 tools/list, THE MCP Server SHALL 返回全部已启用工具的名称、描述与 JSON Schema 入参。
3. WHEN MCP Client 请求 resources/list, THE MCP Server SHALL 返回可读取资源，至少包括当前会话流量索引与代理状态。
4. WHEN MCP Client 调用未声明工具, THE MCP Server SHALL 返回方法不存在错误。
5. THE MCP Server SHALL 使用 Streamable HTTP（含 SSE）作为 Android 上的远程传输，以便同一局域网的电脑连接。

### Requirement 8: Android 设置与状态可见

**User Story:** AS Android 用户, I want 在手机上开关 MCP 并看到连接说明, so that 我能把 AI 客户端配上并随时断开。

#### Acceptance Criteria

1. WHEN 用户打开 Android 设置中的 MCP 页面, THE ProxyPin APK SHALL 展示开关、端口（默认 9100）、Auth Token、流量正文截断上限与当前连接数。
2. WHEN MCP 服务开启, THE ProxyPin APK SHALL 展示可复制的连接配置文本（含 URL 与 token 使用说明）。
3. WHEN 有 MCP Client 处于已连接状态, THE ProxyPin APK SHALL 在 MCP 页面显示连接中。
4. WHEN 用户关闭 MCP 开关, THE ProxyPin APK SHALL 断开全部现有 MCP 会话。
5. WHEN 用户修改端口或正文截断上限, THE ProxyPin APK SHALL 将新值写入配置；端口变更在下次启动 MCP 服务时生效。
6. THE ProxyPin APK SHALL 将 MCP 开关、端口、Auth Token 与正文截断上限持久化到现有配置存储。
7. WHEN 应用进程启动且已持久化的 MCP 开关为开启, THE ProxyPin APK SHALL 自动启动 MCP Server。

### Requirement 9: 错误处理与审计

**User Story:** AS Android 用户, I want MCP 调用失败时有明确反馈并且关键操作可追溯, so that 我知道 AI 做了什么。

#### Acceptance Criteria

1. IF 工具执行失败, THE MCP Server SHALL 向 MCP Client 返回包含错误码与可读消息的 MCP 错误结果。
2. WHEN MCP Client 成功执行发送请求或重放, THE ProxyPin APK SHALL 追加一条审计记录，包含时间、工具名与摘要。
3. WHEN 用户打开 MCP 页面, THE ProxyPin APK SHALL 展示最近的审计记录列表。
4. IF 读取流量或发送请求过程中发生异常, THE MCP Server SHALL 捕获该异常并返回错误文本，保持代理服务继续运行。
