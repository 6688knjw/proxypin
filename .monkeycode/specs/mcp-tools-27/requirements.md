# Requirements Document

## Introduction

在 ProxyPin 内嵌 MCP Server 上提供完整 27 个流量工具。AI 客户端通过 `tools/list` 发现这些工具后，可读取当前抓包会话、分析鉴权与敏感信息、管理断点/重写/脚本，以及导入导出 HAR。

既有 `list_traffic` / `get_traffic` 等别名继续可用。本期不在设备上执行 Python 或 JavaScript 运行时。

## Glossary

- **MCP Tool**：MCP 协议中可被 AI 调用的具名工具。
- **Traffic Record**：一条 HTTP(S) 请求/响应对。
- **Breakpoint Rule**：按 URL 拦截请求或响应的断点规则。
- **Rewrite Rule**：请求/响应替换、修改或重定向规则。
- **HAR**：HTTP Archive 流量导出格式。

## Requirements

### Requirement 1: 27 个工具可发现

**User Story:** AS AI 客户端, I want tools/list 返回完整 27 个工具, so that 我可以按清单调用 ProxyPin 能力。

#### Acceptance Criteria

1. WHEN MCP Client 请求 tools/list, THE MCP Server SHALL 返回下列工具名称：get_request_list、get_request_detail、get_request_body、get_request_stats、search_requests、get_domain_summary、get_cookie_info、compare_requests、analyze_encrypted_content、replay_request、generate_code、add_breakpoint、remove_breakpoint、list_breakpoints、get_pending_intercepts、release_intercept、list_rewrite_rules、add_rewrite_rule、remove_rewrite_rule、list_scripts、get_script_content、create_or_update_script、find_sensitive_data、analyze_auth、extract_api_endpoints、export_har、import_har。
2. WHEN MCP Client 调用未声明工具, THE MCP Server SHALL 返回方法不存在错误。

### Requirement 2: 流量读取与分析

**User Story:** AS AI 使用者, I want 通过 MCP 列出、搜索和对比抓包记录, so that 我可以定位接口问题。

#### Acceptance Criteria

1. WHEN MCP Client 调用 get_request_list 或 search_requests, THE MCP Server SHALL 返回当前会话中匹配过滤条件的 Traffic Record 摘要。
2. WHEN MCP Client 提供 requestId 调用 get_request_detail, THE MCP Server SHALL 返回该记录的请求/响应头与截断后的正文。
3. WHEN MCP Client 调用 get_request_stats 或 get_domain_summary, THE MCP Server SHALL 按方法、状态码和 host 聚合当前会话。
4. IF requestId 不存在, THE MCP Server SHALL 返回 not_found 错误。

### Requirement 3: 断点、重写与脚本

**User Story:** AS AI 使用者, I want 通过 MCP 管理断点、重写规则和脚本, so that 我可以拦截并改写流量。

#### Acceptance Criteria

1. WHEN MCP Client 调用 add_breakpoint, THE MCP Server SHALL 将规则写入 RequestBreakpointManager 并持久化。
2. WHEN MCP Client 调用 release_intercept 并提供已暂停的 requestId, THE MCP Server SHALL 恢复对应请求或响应。
3. WHEN MCP Client 调用 add_rewrite_rule 或 create_or_update_script, THE MCP Server SHALL 将规则或脚本写入现有 Manager 并刷新配置。

### Requirement 4: HAR 与代码生成

**User Story:** AS AI 使用者, I want 导出 HAR 或生成 curl/Python/fetch, so that 我可以复现请求。

#### Acceptance Criteria

1. WHEN MCP Client 调用 generate_code, THE MCP Server SHALL 按 format 返回 curl、python 或 fetch 文本。
2. WHEN MCP Client 调用 export_har, THE MCP Server SHALL 返回当前会话（或指定 requestIds）的 HAR JSON。
3. WHEN MCP Client 调用 import_har 并提供合法 HAR JSON, THE MCP Server SHALL 将条目写入 HistoryStorage。
