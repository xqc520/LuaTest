# OTA 简明说明

最后更新：2026-04-03

这份文档只保留 OTA 对接必须知道的内容。

## 1. Topic

下发：

```text
sys/{SN}/ota/down/update
```

回包：

```text
sys/{SN}/ota/up/resport
```

说明：

- OTA 只走 MQTT1
- 回包 topic 固定是 `resport`

## 2. 推荐下发格式

服务器建议发最简单的 JSON：

```json
{
  "request_id": "ota-001",
  "url": "http://example.com/ota/firmware.bin",
  "md5": "d41d8cd98f00b204e9800998ecf8427e"
}
```

字段说明：

- `request_id`：请求编号，建议唯一
- `url`：升级包地址，必填
- `md5`：文件 MD5，可选；如果填写，设备会先做真校验

## 3. 设备处理流程

### 带 md5

1. 设备收到 OTA 请求
2. 检查 `url`
3. 回 `verify_start`
4. 临时下载升级包
5. 计算文件 MD5
6. 一致回 `verify_ok`
7. 然后回 `start`
8. 开始 OTA
9. 成功回 `success`
10. 失败回 `verify_failed` 或 `failed`

补充说明：

- 当前 `md5` 是真校验
- 带 `md5` 时，设备会多下载一次升级包用于校验

## 4. 回包字段

设备回包尽量简化，只保留这些：

```json
{
  "request_id": "ota-001",
  "status": "success",
  "message": "upgrade package downloaded",
  "sn": "123456789",
  "time": 1775188800
}
```

失败时可能多一个 `result_code`：

```json
{
  "request_id": "ota-001",
  "status": "failed",
  "message": "package download failed",
  "sn": "123456789",
  "time": 1775188810,
  "result_code": 4
}
```

## 5. 常见状态

- `invalid_payload`：下发内容不对
- `duplicate`：短时间重复下发
- `busy`：当前已有 OTA 在执行
- `verify_start`：开始校验
- `verify_ok`：MD5 校验通过
- `verify_failed`：MD5 校验失败
- `start`：开始正式 OTA
- `success`：升级成功，设备将自动重启
- `failed`：升级失败

## 6. mosquitto 示例

下发 OTA：

```bash
mosquitto_pub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/123456789/ota/down/update" -m "{\"request_id\":\"ota-001\",\"url\":\"http://example.com/ota/firmware.bin\",\"md5\":\"d41d8cd98f00b204e9800998ecf8427e\"}"
```

订阅回包：

```bash
mosquitto_sub -h 127.0.0.1 -p 8883 --cafile rootCA.crt -u admin -P 123456 -t "sys/+/ota/up/resport" -v
```
