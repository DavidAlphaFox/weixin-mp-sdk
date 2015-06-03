# 微信公众平台开发工具包

本项目实现了开发微信开发公众平台所需的 Haskell 函数库，及简单的命令行小工具。

## 功能

* 包装了大部分微信公众平台的大部分常用接口
* 提供 Yesod 的 subsite ，很方便地在 Yesod 工程项目中实现接收微信平台的各种消息通知，并作出回应。
* 支持在同一个 Yesod 工程中同时支持多个公众号的消息处理。
* 灵活的，可配置、模块化易扩展的消息响应逻辑。常见的响应逻辑只需配置文件即可实现，更复杂的逻辑则需增加 Haskell 代码实现。

## 数据库

SDK 代码本身没有 hard code 使用什么具体数据库。但目前代码结构(以及下一层的 persistent 库)决定了只支持 SQL 类型数据库。测试时使用的是 MySQL ，理论上 PostgreSQL, Sqlite 也是支持的。

## 开发环境

操作系统：Debian
编译器：GHC 7.8.4

### 主要依赖的 Haskell 库

本项目使用了许多第三方 Haskell 库

知名的 Haskell 库包括

* yesod 相关的一系列库
* wreq

我们内部自制的 Haskell 库

* yesod-helpers
