# 服务器对接文档

最后更新：2026-03-27

本文档是当前项目唯一有效的服务器对接文档。

## 1. 总体说明

当前设备支持 2 路 MQTT 连接：

- MQTT1：主服务器
  - 负责 `485` 数据上报
  - 负责 `SM4` 参数下发
  - 负责时间同步
  - 负责设备命令
  - 负责 OTA
- MQTT2：辅助服务器
  - 只负责 `485` 数据上报
  - 不处理校时
  - 不处理 `SM4`
  - 不处理 OTA
  - 不处理设备命令

如果服务器只想先跑通链路，只需要把 MQTT1 对接完整即可。

## 2. MQTT 连接要求

### 2.1 基本要求

- 协议：`MQTTS`
- 端口：默认建议 `8883`
- `Clean Session = false`
- 设备使用 CA 证书校验服务器证书
- CA 文件名：`rootCA.crt`

### 2.2 Client ID 规则

- MQTT1：`<IMEI>mqtts1`
- MQTT2：`<IMEI>mqtts2`

### 2.3 证书校验前提

证书校验模式要求设备时间有效。

也就是说：

- 如果设备 RTC 时间有效，可以直接建立 TLS 连接
- 如果设备 RTC 时间失效，TLS 证书校验可能失败
- 当前固件的时间同步走 MQTT1，所以首次出厂或 RTC 完全失效时，需要先保证设备有可用时间

这是 LuatOS 官方 `mqtts_ca` 示例本身的要求，不是本项目额外限制。

## 3. Topic 总表

### 3.1 设备上行

| 功能 | Topic | 说明 |
| --- | --- | --- |
| 实时数据上报 | `sys/{SN}/json/up/realTime` | 485 数据密文和 10 分钟状态密文都走这里 |
| 设备响应 / 主动请求 | `sys/{SN}/json/up/resp` | 只以 MQTT1 为准 |
| OTA 状态回包 | `sys/{SN}/ota/up/resport` | 只以 MQTT1 为准 |

### 3.2 设备下行

| 功能 | Topic | 说明 |
| --- | --- | --- |
| 设备命令 | `sys/{SN}/json/down/cmd` | 只发给 MQTT1 |
| 时间同步 | `sys/{SN}/json/down/resp` | 只发给 MQTT1 |
| OTA 下发 | `sys/{SN}/ota/down/update` | 只发给 MQTT1 |

### 3.3 服务器建议订阅

```text
sys/+/json/up/realTime
sys/+/json/up/resp
sys/+/ota/up/resport
```

鏌ヨ娴侀噺鍗″簭鍒楀彿锛?
```bash
mosquitto_pub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/123456/json/down/cmd" -m "{\"cmd\":\"get_sim_info\",\"request_id\":\"sim-20260327-001\"}"
```

## 4. 服务器最小实现

服务器最少需要做 3 件事：

1. 处理 `request_sm4`
2. 处理 `request_time`
3. 接收并解密 `realTime`

如果这 3 件事没做全，设备表现会是：

- 没回 `set_sm4`：`485` 数据和 10 分钟状态数据都会先缓存在 SD，不会上报
- 没回 `timeSync`：设备时间可能不准
- 没接 `realTime`：采集数据收不到

## 5. 时间同步

### 5.1 设备主动请求

设备只通过 MQTT1 主动请求时间。

Topic：

```text
sys/{SN}/json/up/resp
```

Payload 示例：

```json
{
  "cmd": "request_time",
  "request_id": "timereq-1-1774470000",
  "sn": "123456",
  "has_valid_time": false,
  "time": 1774470000
}
```

### 5.2 服务器回时间

Topic：

```text
sys/{SN}/json/down/resp
```

Payload 示例：

```json
{
  "cmd": "timeSync",
  "request_id": "timereq-1-1774470000",
  "serverTime": 1774470000,
  "timezone": "+08:00"
}
```

### 5.3 同步策略

- 设备上线后先请求一次
- 如果时间无效，每 60 秒重试一次
- 时间有效后，每 24 小时再同步一次
- 只以 MQTT1 为准

## 6. SM4 参数下发

### 6.1 设备主动请求 SM4

设备只通过 MQTT1 主动请求 SM4 参数。

Topic：

```text
sys/{SN}/json/up/resp
```

Payload 示例：

```json
{
  "cmd": "request_sm4",
  "request_id": "sm4req-1-1774470000",
  "sn": "123456",
  "has_local": true,
  "time": 1774470000
}
```

### 6.2 服务器下发 SM4

Topic：

```text
sys/{SN}/json/down/cmd
```

Payload 示例：

```json
{
  "cmd": "set_sm4",
  "request_id": "sm4-20260327-001",
  "key": "1234567890123456",
  "iv": "1234567890666666"
}
```

说明：

- `key` 支持 16 个普通字符，或 32 位 HEX
- `iv` 支持 16 个普通字符，或 32 位 HEX
- 当前加密模式固定为 `SM4-CBC + PKCS7`

## 7. 485 数据上报

### 7.1 上报 Topic

```text
sys/{SN}/json/up/realTime
```

### 7.2 Payload 说明

当前 `realTime` 的 payload 不是明文 JSON，而是：

1. 原始 485 数据
2. `SM4-CBC`
3. `PKCS7`
4. `HEX`

服务器收到后必须先解密，不能直接按 JSON 解析。

### 7.3 上发策略

当前策略是“尽可能往上发”：

- 原始 485 数据先写入 SD 持久化队列
- 断网、重启、重连后会自动继续补发
- 不要求服务器返回 ACK
- 只要 MQTT1 或 MQTT2 任一路发布成功，这条记录就会从本地队列删除

服务器侧需要注意：

- 可能收到重复数据
- 建议按业务字段自行去重

## 8. 设备命令

所有设备命令都只发给 MQTT1：

```text
sys/{SN}/json/down/cmd
```

所有命令回包都回到：

```text
sys/{SN}/json/up/resp
```

当前支持的命令如下：

| cmd | 说明 |
| --- | --- |
| `set_sm4` | 下发 SM4 key/iv |
| `get_device_status` | 查询电池、电阻温度、SIM 信息、SD 容量 |
| `get_sim_info` | 查询流量卡序列号(ICCID)等 SIM 信息 |
| `get_error_log` | 查询错误日志 |
| `backfill_data` | 按时间段补录历史数据 |
| `sensor_power` | 控制 GPIO16 传感器 12V 电源 |
| `set_sensor_power` | `sensor_power` 的兼容别名 |

### 8.1 查询 SIM 信息

下发 Topic：
```text
sys/{SN}/json/down/cmd
```

Payload 示例：
```json
{
  "cmd": "get_sim_info",
  "request_id": "sim-20260327-001"
}
```

设备回包 Topic：
```text
sys/{SN}/json/up/resp
```

回包示例：
```json
{
  "cmd": "get_sim_info",
  "request_id": "sim-20260327-001",
  "result": 0,
  "reason": "ok",
  "sn": "123456",
  "time": 1774590720,
  "imei": "868120000000001",
  "imsi": "460011234567890",
  "iccid": "89860012345678901234",
  "simid": 0,
  "mobile_status": 1
}
```

说明：
- `iccid` 就是流量卡序列号。
- `result = 0` 表示查询成功。
- `result = -1` 表示当前没有读到 `iccid`，例如 SIM 未就绪。

## 9. OTA

OTA 只走 MQTT1。

下发 Topic：

```text
sys/{SN}/ota/down/update
```

回包 Topic：

```text
sys/{SN}/ota/up/resport
```

## 10. mosquitto 示例

订阅设备响应：

```bash
mosquitto_sub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/+/json/up/resp" -v
```

订阅 485 上报：

```bash
mosquitto_sub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/+/json/up/realTime" -v
```

订阅 OTA 回包：

```bash
mosquitto_sub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/+/ota/up/resport" -v
```

下发时间同步：

```bash
mosquitto_pub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/123456/json/down/resp" -m "{\"cmd\":\"timeSync\",\"request_id\":\"timereq-1-1774470000\",\"serverTime\":1774470000,\"timezone\":\"+08:00\"}"
```

下发 SM4：

```bash
mosquitto_pub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/123456/json/down/cmd" -m "{\"cmd\":\"set_sm4\",\"request_id\":\"sm4-20260327-001\",\"key\":\"1234567890123456\",\"iv\":\"1234567890666666\"}"
```

## 11. Periodic Device Status

设备会通过 MQTT1 定时生成设备状态报文。

- Topic: `sys/{SN}/json/up/realTime`
- Frequency: 每 10 分钟整点一次
- QoS: `1`

原始状态 JSON 示例：
```json
{
  "SN": "ABCDEFGH",
  "timeStamp": "1659606483",
  "sendFrequency": 10,
  "tcase": 32.1,
  "batteryVoltage": 12.1,
  "cardMemory": 7235,
  "latitude": null,
  "longitude": null
}
```

上传格式说明：
- 写入 SD 的内容是上面的原始 JSON
- MQTT 上行前会继续复用现有 485 链路：`SM4-CBC + PKCS7 + HEX`
- 所以服务器订阅到的 `realTime` payload 不是明文 JSON，而是密文 HEX

SD 日志路径：
```text
/sd/log/status/YYYYMMDD/H.log
```

字段说明：
- `sendFrequency` 单位为分钟，当前固定为 `10`
- `tcase` 为板载温度，单位摄氏度
- `batteryVoltage` 为电池电压，单位伏特
- `cardMemory` 为 SD 卡总容量，单位 MB
- `latitude`、`longitude` 获取不到时为 `null`

兼容说明：
- 该状态报文与 485 上报共用 `sys/{SN}/json/up/realTime`
- 服务器需要先做 SM4 解密，再判断明文内容
- 如果解密后是包含 `sendFrequency`、`tcase`、`batteryVoltage`、`cardMemory` 的 JSON，则按设备状态处理
- 如果解密后不是这类状态 JSON，则按 485 业务数据处理
## 12. BUS 总线直发命令

服务器可以通过 MQTT1 直接下发数据到设备的 `BUS/485` 总线。

下发 Topic：
```text
sys/{SN}/json/down/cmd
```

回包 Topic：
```text
sys/{SN}/json/up/resp
```

命令字：
```text
bus_send
```

### 12.1 文本方式

```json
{
  "cmd": "bus_send",
  "request_id": "bus-001",
  "encoding": "text",
  "data": "hello",
  "append_crlf": true
}
```

说明：
- `encoding=text` 表示把 `data` 原样发到 UART1
- `append_crlf=true` 时，设备会自动追加 `\r\n`

### 12.2 HEX 方式

```json
{
  "cmd": "bus_send",
  "request_id": "bus-002",
  "encoding": "hex",
  "data": "010300000002C40B"
}
```

说明：
- `encoding=hex` 时，`data` 必须是 HEX 字符串
- 设备会先把 HEX 转成二进制，再发到 UART1

### 12.3 空闲要求

如果你希望“只有总线完全空闲时才允许发送”，可以加：

```json
{
  "cmd": "bus_send",
  "request_id": "bus-003",
  "encoding": "hex",
  "data": "010300000002C40B",
  "require_idle": true
}
```

说明：
- 回包只保留最核心字段：`cmd / request_id / result / reason / sn / time`
- 如果命令里带了总线目标信息，会额外回 `adress / u_cmd`
- 不再返回 `encoding / bytes / bus_busy / queue_pending / tx_queue_len` 这类调试字段

说明：
- `require_idle=true` 时，如果当前 BUSY 锁已被占用，或者 UART1 发送队列里还有未发数据，设备会直接拒绝
- 不带 `require_idle` 时，设备会先入发送队列，后续仍然按现有 BUSY 锁逻辑发送

### 12.4 回包说明

成功入队示例：

```json
{
  "cmd": "bus_send",
  "request_id": "bus-002",
  "result": 0,
  "reason": "queued",
  "sn": "123456",
  "time": 1775000000,
  "adress": 1,
  "u_cmd": "freq"
}
```

总线忙但允许排队示例：

```json
{
  "cmd": "bus_send",
  "request_id": "bus-004",
  "result": 0,
  "reason": "queued_busy",
  "sn": "123456",
  "time": 1775000001,
  "adress": 1,
  "u_cmd": "freq"
}
```

拒绝发送示例：

```json
{
  "cmd": "bus_send",
  "request_id": "bus-003",
  "result": -1,
  "reason": "bus_busy",
  "sn": "123456",
  "time": 1775000002,
  "adress": 1,
  "u_cmd": "freq"
}
```

### 12.5 设备侧行为

- 这条命令只接到 MQTT1
- 服务器下发的数据不会直接绕过 BUSY 锁发串口
- 设备只是先把数据放进 UART1 发送队列
- 真正 `uart.write()` 前，仍然会走现有的 BUSY 锁检测和抢占流程
- 所以这条接口适合远程调试、远程下发 485 指令，不会破坏当前总线仲裁逻辑
## 0. BUS(485) 总线设备推荐 JSON 格式

如果服务器需要通过设备的 `BUS/485` 去控制总线上挂载的 STM32 设备，推荐统一使用短字段的文本 JSON。

推荐原因：
- 文本格式方便调试
- STM32 侧容易解析
- 后续新增命令时不需要重做协议

推荐约定：
- 一条指令一行，结尾追加 `\\r\\n`
- MQTT 下发到设备时使用 `encoding=text`
- 总线 JSON 字段尽量短，不要太长太复杂

推荐的总线 JSON：

```json
{"adress":1,"cmd":"freq","v":60}
```

字段说明：
- `adress`：总线设备地址或设备号
- `cmd`：命令字
- `v`：参数值

推荐先保留这几个常用命令：

1. 修改上传频率

```json
{"adress":1,"cmd":"freq","v":60}
```

说明：
- `v` 建议直接用秒
- 例如 `60` 表示 60 秒上传一次

2. 重启设备

```json
{"adress":1,"cmd":"reboot"}
```

3. 读取当前配置

```json
{"adress":1,"cmd":"get"}
```

4. 恢复默认配置

```json
{"adress":1,"cmd":"reset"}
```

推荐的 STM32 应答 JSON：

成功：

```json
{"adress":1,"ok":1,"cmd":"freq"}
```

失败：

```json
{"adress":1,"ok":0,"cmd":"freq","err":1}
```

字段说明：
- `ok`：`1` 成功，`0` 失败
- `err`：错误码，建议使用数字

如果服务器通过 MQTT 下发到设备，再由设备转发到 UART1，推荐这样写：

修改上传频率：

```json
{
  "cmd": "bus_send",
  "request_id": "bus-freq-001",
  "encoding": "text",
  "data": "{\"adress\":1,\"cmd\":\"freq\",\"v\":60}",
  "append_crlf": true
}
```

重启设备：

```json
{
  "cmd": "bus_send",
  "request_id": "bus-reboot-001",
  "encoding": "text",
  "data": "{\"adress\":1,\"cmd\":\"reboot\"}",
  "append_crlf": true
}
```

建议：
- `cmd` 保持短小固定，例如 `freq / reboot / get / reset`
- 参数字段尽量统一，例如都用 `v`
- 不建议在总线 JSON 里塞太多说明性字段
- 如果后续还要加别的控制项，也尽量保持这个短字段风格
## 0. BUS(485) STM32 回包转 MQTT

如果总线上的 STM32 设备通过 BUS/485 回包，推荐也使用短字段文本 JSON。

推荐 STM32 回包：

成功：

```json
{"adress":1,"ok":1,"cmd":"freq"}
```

失败：

```json
{"adress":1,"ok":0,"cmd":"freq","err":1}
```

读取配置：

```json
{"adress":1,"ok":1,"cmd":"get","freq":60}
```

设备侧转发规则：
- 只要 BUS 收到的是这类短 JSON
- 并且包含 `adress` 和 `cmd`
- 设备就会把它转发到 MQTT1
- 转发 Topic：`sys/{SN}/json/up/resp`

转发后的 MQTT Payload 示例：

```json
{
  "cmd": "bus_recv",
  "u_cmd": "freq",
  "source": "bus",
  "adress": 1,
  "ok": 1,
  "sn": "123456",
  "time": 1775000100
}
```

说明：
- 顶层 `cmd` 固定为 `bus_recv`
- `u_cmd` 表示总线设备原始命令字
- `adress / ok / err / freq` 这类字段会直接保留，方便服务器直接取值
- 如果 BUS 收到的不是这类短 JSON，仍然走原来的 485 数据上报链路，不会进这条回包转发逻辑
## 0. BUS(485) 简化下发命令

为了方便服务器和 STM32 对接，`BUS/485` 现在支持两种下发方式：

1. 原始透传方式
自己拼好 `data`

2. 简化 JSON 方式
服务器直接传 `adress / u_cmd / v`

推荐优先使用第 2 种，最简单。

### 推荐下发格式

修改上传频率：

```json
{
  "cmd": "bus_send",
  "request_id": "bus-freq-001",
  "adress": 1,
  "u_cmd": "freq",
  "v": 60
}
```

设备重启：

```json
{
  "cmd": "bus_send",
  "request_id": "bus-reboot-001",
  "adress": 1,
  "u_cmd": "reboot"
}
```

读取配置：

```json
{
  "cmd": "bus_send",
  "request_id": "bus-get-001",
  "adress": 1,
  "u_cmd": "get"
}
```

### 设备内部实际发到 UART1 的内容

例如上面这条：

```json
{
  "cmd": "bus_send",
  "adress": 1,
  "u_cmd": "freq",
  "v": 60
}
```

设备会自动转成：

```json
{"adress":1,"cmd":"freq","v":60}
```

并自动追加 `\r\n` 后发到 `BUS/485`。

### 说明

- `adress`：总线地址
- `u_cmd`：总线设备命令字
- `v`：参数值
- 如果还要加别的参数，也可以继续放在同一层，设备会一起带到总线 JSON 里
- 如果服务器仍然想完全自己控制原始报文，也可以继续使用原来的 `data + encoding` 方式
